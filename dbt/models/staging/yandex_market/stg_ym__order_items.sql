{{ config(materialized='view') }}

-- Staging rule: rename, cast, de-duplicate. No joins, no aggregation.
-- Column names below are EXPECTED; adjust to the real CSV header after the first download.

with src as (

    select * from {{ source_or_seed('united_orders_orders') }}

),

renamed as (

    select
        order_id::varchar                                   as order_id,
        offer_id::varchar                                   as sku,
        {{ dbt_utils.generate_surrogate_key(['order_id', 'offer_id']) }} as order_item_key,
        try_to_timestamp_ntz(order_created_at)              as ordered_at,
        try_to_date(order_created_at)                       as ordered_date,
        order_status::varchar                               as order_status,
        product_name::varchar                               as product_name,
        category::varchar                                   as category,
        try_to_number(quantity)                             as units,
        try_to_decimal(price, 18, 2)                        as unit_price,
        try_to_decimal(paid_by_customer, 18, 2)             as paid_by_customer,
        try_to_decimal(refund_amount, 18, 2)                as refund_amount,
        delivery_region::varchar                            as delivery_region,
        _loaded_at::timestamp_ntz                           as _loaded_at,
        _source_file::varchar                               as _source_file
    from src

),

deduplicated as (

    -- the same period can be exported more than once: keep the latest load
    select *
    from renamed
    qualify row_number() over (partition by order_item_key order by _loaded_at desc) = 1

)

select * from deduplicated
