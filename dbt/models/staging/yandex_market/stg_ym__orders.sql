{{ config(materialized='view') }}

-- Staging rule: rename, cast. No joins, no unnesting here — the nested arrays of the same RAW row are unnested
-- in their own models: stg_ym__order_lines (ITEMS), stg_ym__order_line_events (items[].details),
-- stg_ym__order_fees (COMMISSIONS), stg_ym__order_payments (PAYMENTS).
-- Grain: order. One row per marketplace order, latest load wins.

with src as (

    select * from {{ source_or_seed('orders_stats') }}

),

latest as (

    -- the same quarter can be exported more than once: keep the latest load per order
    select *
    from src
    qualify row_number() over (partition by id order by _loaded_at desc) = 1

),

renamed as (

    select
        id::varchar                                             as order_id,
        partnerorderid::varchar                                 as partner_order_id,
        try_to_date(creationdate, 'YYYY-MM-DD')                 as ordered_date,
        try_to_timestamp_tz(statusupdatedate)                   as status_updated_at,   -- ISO 8601 with +03:00 offset
        status::varchar                                         as order_status,
        paymenttype::varchar                                    as payment_type,        -- PREPAID | POSTPAID
        buyertype::varchar                                      as buyer_type,          -- PERSON so far
        currency::varchar                                       as currency,            -- RUR so far
        fake::boolean                                           as is_test_order,
        parse_json(deliveryregion):id::integer                  as delivery_region_id,
        parse_json(deliveryregion):name::varchar                as delivery_region_name,
        parse_json(subsidies)                                   as subsidies_json,      -- [{operationType, type, amount}], not unnested yet
        _loaded_at::timestamp_ntz                               as _loaded_at,
        _source_file::varchar                                   as _source_file
    from latest

)

select * from renamed
