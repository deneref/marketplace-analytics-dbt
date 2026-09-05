{{ config(materialized='view') }}

-- Staging rule: rename, cast, de-duplicate. No joins, no aggregation.

with src as (

    select * from {{ source_or_seed('united_orders_orders') }}

),

renamed as (

    -- Real header of sheet orders_and_offers_transactions (verified 2026-09-03).
    -- One row per order × SKU × offer status; unit counts live in TRANSFERRED_FOR_DELIVERY / DELIVERED_OR_RETURNED.
    select
        order_id::varchar                                   as order_id,
        shop_sku::varchar                                   as sku,
        offer_status::varchar                               as offer_status,
        {{ dbt_utils.generate_surrogate_key(['order_id', 'shop_sku', 'offer_status']) }} as order_item_key,
        try_to_date(creation_date, 'DD.MM.YYYY')            as ordered_date,
        try_to_timestamp_ntz(status_changed, 'YYYY-MM-DD HH24:MI:SS') as status_changed_at,
        try_to_date(delivery_date, 'DD.MM.YYYY')            as delivered_date,
        offer_name::varchar                                 as product_name,
        try_to_number(transferred_for_delivery)             as units_shipped,
        try_to_number(delivered_or_returned)                as units_delivered_or_returned,
        try_to_decimal(billing_price, 18, 2)                as unit_price,
        try_to_decimal(buyer_payment_amount, 18, 2)         as paid_by_customer,
        try_to_decimal(refund_buyer_payment_amount, 18, 2)  as refund_amount,
        delivery_region::varchar                            as delivery_region,
        shipment_warehouse::varchar                         as shipment_warehouse,
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
