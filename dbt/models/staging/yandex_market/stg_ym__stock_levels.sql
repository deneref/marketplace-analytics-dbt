{{ config(materialized='view') }}

-- Staging rule: rename, cast, UNNEST. No joins to other sources, no aggregation across records.
-- Grain: snapshot_date × sku × warehouse_name × stock_type — one row per stock bucket that holds units,
-- plus one NULL-type row when a SKU is listed at a warehouse with nothing in any bucket.
--
-- Source: the 'stocks-on-warehouses' REPORT (stock_reports), one wide row per SHOP_SKU × WAREHOUSE with the buckets as
-- columns. It replaced the offers/stocks JSON snapshot on 2026-09-14 because it can be requested for any past date
-- (daily history backfilled from 2025-01-08) and holds END-OF-DAY stock. The output keeps the shape of the old model —
-- buckets as rows, same type names, same NULL-row convention — so int_stock_daily did not have to change its pivot.
--
-- Two things the report does differently, both handled here:
--   * the date is not a column: the request date is the folder in _SOURCE_FILE
--     (stock_reports/<run_date>/<reportDate>/stocks_on_warehouses.csv), and the report holds the stock of the day
--     BEFORE reportDate (verified against the 2026-09-05 JSON snapshot: VALID = FIT to the unit) → snapshot_date = reportDate − 1;
--   * warehouses come as NAMES; the id lives in stg_ym__warehouses and is joined in int_stock_daily (no joins in staging).
-- Bucket names follow the JSON endpoint's vocabulary so that docs and tests read the same: VALID → FIT, RESERVED → FREEZE,
-- AVAILABLE_FOR_ORDER → AVAILABLE. Not additive: FIT = AVAILABLE + FREEZE. int_stock_daily picks buckets explicitly.
-- Caps come under their warehouse SKU (K1…K5), exactly as in the turnover report — resolved via dim_products.warehouse_sku
-- in the mart, not here.

{#- report column → stock_type as the JSON endpoint named it (getStocks WarehouseStockType) -#}
{% set buckets = {
    'valid':               'FIT',
    'available_for_order': 'AVAILABLE',
    'reserved':            'FREEZE',
    'quarantine':          'QUARANTINE',
    'defect':              'DEFECT',
    'expired':             'EXPIRED',
    'utilization':         'UTILIZATION'
} %}

with src as (

    select * from {{ source_or_seed('stock_reports') }}

),

dated as (

    select
        *,
        split_part(_source_file, '/', -2)                           as report_date_str      -- …/<reportDate>/stocks_on_warehouses.csv (same trick as stg_ym__turnover_report)
    from src

),

latest as (

    -- the same reportDate can be downloaded more than once (a re-run, the daily job after the backfill):
    -- keep the latest load per sku × warehouse × reportDate, BEFORE unnesting
    select *
    from dated
    qualify row_number() over (
        partition by report_date_str, shop_sku, warehouse
        order by _loaded_at desc
    ) = 1

),

typed as (

    select
        try_to_date(report_date_str, 'YYYY-MM-DD') - 1                          as snapshot_date,       -- the report is "as of the end of the day before reportDate"
        shop_sku::varchar                                           as sku,
        warehouse::varchar                                          as warehouse_name,
        -- buckets with units, as [{type, count}] — the same shape the JSON endpoint had, so the flatten below is identical
        array_construct_compact(
            {% for col, stock_type in buckets.items() -%}
            iff(coalesce(try_to_number({{ col }}), 0) > 0,
                object_construct('type', '{{ stock_type }}', 'count', try_to_number({{ col }})),
                null){{ "," if not loop.last }}
            {% endfor -%}
        )                                                           as stocks,
        _loaded_at::timestamp_ntz                                   as _loaded_at,
        _source_file::varchar                                       as _source_file
    from latest

),

levels as (

    select
        s.snapshot_date,
        s.sku,
        s.warehouse_name,
        st.value:type::varchar                                      as stock_type,
        {{ dbt_utils.generate_surrogate_key(['s.snapshot_date', 's.sku', 's.warehouse_name', 'st.value:type']) }}
                                                                    as stock_level_key,
        coalesce(st.value:count::integer, 0)                        as units,
        (st.value is null)                                          as is_empty_stock,      -- listed at the warehouse, every bucket 0
        s._loaded_at,
        s._source_file
    from typed as s,
        lateral flatten(input => s.stocks, outer => true) as st

)

select * from levels
