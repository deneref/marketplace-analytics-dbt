{{ config(materialized='view') }}

-- Staging rule: rename, cast, UNNEST. No joins to other sources, no aggregation across records.
-- Grain: snapshot_date × sku × warehouse_id × stock_type. RAW has one row per offer × warehouse per daily
-- snapshot with STOCKS as a JSON array [{type, count}]; lateral flatten turns each element into a row.
-- Offers with no stock come as STOCKS = '[]' — outer flatten keeps them as one row with stock_type NULL
-- and units 0, so "listed at the warehouse but out of stock" survives into fct_inventory_daily.
-- Stock types are NOT additive: FIT = AVAILABLE + FREEZE (sellable or reserved). Do not sum across types —
-- int_stock_daily picks FIT and AVAILABLE explicitly.

with src as (

    select * from {{ source_or_seed('stock_snapshots') }}

),

latest as (

    -- the same day can be snapshotted more than once: keep the latest load per offer × warehouse × day,
    -- and do it BEFORE flattening — after flattening every type of a re-exported row would survive
    select *
    from src
    qualify row_number() over (
        partition by snapshot_date, offerid, warehouse_id
        order by _loaded_at desc
    ) = 1

),

levels as (

    select
        s.snapshot_date::date                    as snapshot_date,
        s.offerid::varchar                       as sku,
        s.warehouse_id::integer                  as warehouse_id,
        st.value:type::varchar                   as stock_type,
        {{ dbt_utils.generate_surrogate_key(['s.snapshot_date', 's.offerid', 's.warehouse_id', 'st.value:type']) }}
                                                 as stock_level_key,
        coalesce(st.value:count::integer, 0)     as units,
        (st.value is null)                       as is_empty_stock,
        try_to_timestamp_tz(s.updatedat::varchar) as stock_updated_at,
        s._loaded_at::timestamp_ntz              as _loaded_at,
        s._source_file::varchar                  as _source_file
    from latest as s,
        lateral flatten(input => parse_json(s.stocks), outer => true) as st

)

select * from levels
