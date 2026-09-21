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
--     (stock_reports/<run_date>/<reportDate>/stocks_on_warehouses.csv), and the report holds the stock at the END of
--     reportDate itself → snapshot_date = reportDate. The API docs say "the day before the date" and the first cross-check
--     (FIT 213 = 213 against the 2026-09-05 JSON snapshot) seemed to confirm it, but FIT does not move on an order — only
--     AVAILABLE → RESERVED does, and orders placed on day D (even at 23:00 MSK) are reserved in the report of reportDate = D
--     in 82–95 % of clean cases, in the neighbouring reports in 7–9 % (2026-09-15, scripts/check_stock_report_day.py).
--     Hence a report requested for today is a mid-day state, not a closed day: daily.sh asks for yesterday at most;
--   * warehouses come as NAMES; the id lives in stg_ym__warehouses and is joined in int_stock_daily (no joins in staging).
-- Bucket names follow the JSON endpoint's vocabulary so that docs and tests read the same: VALID → FIT, RESERVED → FREEZE,
-- AVAILABLE_FOR_ORDER → AVAILABLE. Not additive: FIT = AVAILABLE + FREEZE. int_stock_daily picks buckets explicitly.
-- SHOP_SKU is the label the warehouse prints (K1…K5 for the caps, 'dcmp-…' for a decommissioned card), ARTICLE is the
-- seller's code — the report carries both, unlike the turnover report. So sku = ARTICLE here and every model downstream
-- keys on the seller's code without touching dim_products; the label survives as reported_sku for tracing a row back to
-- the report. A rename, not a join — within the staging rule.

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
        try_to_date(report_date_str, 'YYYY-MM-DD')                              as snapshot_date,       -- the report is "as of the end of reportDate" (checked on orders, not on the docs)
        article::varchar                                            as sku,                -- seller's code (CAP-Bur-006), the key every model uses
        shop_sku::varchar                                           as reported_sku,       -- label as printed (K4); the report's own grain
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
        s.reported_sku,
        s.warehouse_name,
        st.value:type::varchar                                      as stock_type,
        {{ dbt_utils.generate_surrogate_key(['s.snapshot_date', 's.reported_sku', 's.warehouse_name', 'st.value:type']) }}
                                                                    as stock_level_key,
        coalesce(st.value:count::integer, 0)                        as units,
        (st.value is null)                                          as is_empty_stock,      -- listed at the warehouse, every bucket 0
        s._loaded_at,
        s._source_file
    from typed as s,
        lateral flatten(input => s.stocks, outer => true) as st

)

select * from levels
