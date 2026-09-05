{{ config(materialized='view') }}

-- Staging rule: rename, cast, UNNEST. No joins to other sources, no aggregation across records.
-- Grain: order × line × event (position in ITEMS). RAW has one row per order with ITEMS as a JSON array;
-- lateral flatten turns each element into a row. Order-level fields (status, payment type, region)
-- live in stg_ym__orders — join them in intermediate, not here.

with src as (

    select * from {{ source_or_seed('orders_stats') }}

),

latest as (

    -- the same quarter can be exported more than once: keep the latest load per ORDER,
    -- and do it BEFORE flattening — after flattening every line of a re-exported order would survive
    select *
    from src
    qualify row_number() over (partition by id order by _loaded_at desc) = 1

),

lines as (

    select
        o.id::varchar                        as order_id,
        i.index::integer                     as line_index,
        {{ dbt_utils.generate_surrogate_key(['o.id', 'i.index', 'd.index']) }} as order_line_event_key,
        {{ dbt_utils.generate_surrogate_key(['o.id', 'i.index']) }}  as order_line_key,
        d.index::integer            as event_index,
        d.value:itemStatus::varchar as event_status,     -- REJECTED | RETURNED
        d.value:itemCount::int      as event_units,
        d.value:updateDate::date    as event_date,
        d.value:stockType::varchar  as stock_type,
        o._loaded_at::timestamp_ntz as _loaded_at,
        o._source_file::varchar     as _source_file
    from latest as o,
        lateral flatten(input => parse_json(o.items))  as i,
        lateral flatten(input => i.value:details)      as d

)
select * from lines
