{{ config(materialized='view') }}

-- Staging rule: rename, cast, UNNEST. No joins to other sources, no aggregation across records.
-- Grain: warehouse_id — one row per marketplace (FBY) warehouse ever seen, latest snapshot wins.
--
-- Why it exists: the stock report prints warehouse NAMES, orders and the old JSON snapshot carry warehouse IDS.
-- GET v2/warehouses is the marketplace's own list of both; ingest/daily.sh pulls it every morning and
-- int_stock_daily joins the report's name to the id here. A warehouse that disappears from the list (closed, renamed)
-- keeps its last row, flagged is_current = false, so historical stock rows still resolve.

with src as (

    select * from {{ source_or_seed('warehouses') }}

),

latest as (

    select *
    from src
    qualify row_number() over (partition by id order by snapshot_date desc, _loaded_at desc) = 1

),

renamed as (

    select
        id::integer                                                 as warehouse_id,
        name::varchar                                               as warehouse_name,
        parse_json(address):city::varchar                           as city,
        parse_json(address):street::varchar                         as street,
        parse_json(address):gps:latitude::float                     as latitude,
        parse_json(address):gps:longitude::float                    as longitude,
        snapshot_date::date                                         as last_seen_date,
        snapshot_date::date = max(snapshot_date::date) over ()      as is_current,          -- present in the latest pull
        _loaded_at::timestamp_ntz                                   as _loaded_at,
        _source_file::varchar                                       as _source_file
    from latest

)

select * from renamed
