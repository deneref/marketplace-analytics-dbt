{{ config(materialized='view') }}

-- Staging rule: rename, cast, unnest. One model for the five appendices of the monthly "Отчёт по реализации"
-- (goods-realization report): same grain in every appendix — one row per order line per report month — and ~30
-- shared columns; only the unit count and the event date differ by appendix. Union here (dbt guide: identical
-- sources split into tables may be unioned in staging), with the appendix-specific columns mapped to event_*.
-- Grain: report_month × event_type × partner_order_id × shop_sku (verified unique on 2026-09-05).
-- Not carried over: ORDER_ID (arrives in scientific notation — PARTNER_ORDER_ID is the same number as text),
-- B2B fields, УПД/УКД, waybills, invoices, customs — all empty for this seller.

with shipped as (

    select
        'shipped'                          as event_type,
        units_shipped                   as event_units,
        shipped_date                    as event_date,
        null                            as redeemed_amount,
        report_month,
        partner_order_id,
        shop_sku,
        warehouse_sku,
        offer_name,
        order_type,
        payment_method,
        vat_rate,
        order_date,
        shipped_date,
        delivered_date,
        price_before_discount,
        discount_marketplace_promo,
        discount_sber_spasibo,
        discount_yandex_plus,
        price_after_discount,
        total_before_discount,
        total_discount,
        total_after_discount,
        total_vat,
        _loaded_at,
        _source_file
    from {{ source_or_seed('goods_realization_shipped') }}

),

delivered as (

    select
        'delivered'                          as event_type,
        units_delivered                 as event_units,
        delivered_date                  as event_date,
        null                            as redeemed_amount,
        report_month,
        partner_order_id,
        shop_sku,
        warehouse_sku,
        offer_name,
        order_type,
        payment_method,
        vat_rate,
        order_date,
        shipped_date,
        delivered_date,
        price_before_discount,
        discount_marketplace_promo,
        discount_sber_spasibo,
        discount_yandex_plus,
        price_after_discount,
        total_before_discount,
        total_discount,
        total_after_discount,
        total_vat,
        _loaded_at,
        _source_file
    from {{ source_or_seed('goods_realization_delivered') }}

),

unredeemed as (

    select
        'unredeemed'                          as event_type,
        units_unredeemed                as event_units,
        unredeemed_received_date        as event_date,
        redeemed_amount                 as redeemed_amount,
        report_month,
        partner_order_id,
        shop_sku,
        warehouse_sku,
        offer_name,
        order_type,
        payment_method,
        vat_rate,
        order_date,
        shipped_date,
        delivered_date,
        price_before_discount,
        discount_marketplace_promo,
        discount_sber_spasibo,
        discount_yandex_plus,
        price_after_discount,
        total_before_discount,
        total_discount,
        total_after_discount,
        total_vat,
        _loaded_at,
        _source_file
    from {{ source_or_seed('goods_realization_unredeemed') }}

),

returned as (

    select
        'returned'                          as event_type,
        units_returned                  as event_units,
        return_received_date            as event_date,
        redeemed_amount                 as redeemed_amount,
        report_month,
        partner_order_id,
        shop_sku,
        warehouse_sku,
        offer_name,
        order_type,
        payment_method,
        vat_rate,
        order_date,
        shipped_date,
        delivered_date,
        price_before_discount,
        discount_marketplace_promo,
        discount_sber_spasibo,
        discount_yandex_plus,
        price_after_discount,
        total_before_discount,
        total_discount,
        total_after_discount,
        total_vat,
        _loaded_at,
        _source_file
    from {{ source_or_seed('goods_realization_returned') }}

),

lost as (

    select
        'lost'                          as event_type,
        units_shipped                   as event_units,
        lost_received_date              as event_date,
        null                            as redeemed_amount,
        report_month,
        partner_order_id,
        shop_sku,
        warehouse_sku,
        offer_name,
        order_type,
        payment_method,
        vat_rate,
        order_date,
        shipped_date,
        delivered_date,
        price_before_discount,
        discount_marketplace_promo,
        discount_sber_spasibo,
        discount_yandex_plus,
        price_after_discount,
        total_before_discount,
        total_discount,
        total_after_discount,
        total_vat,
        _loaded_at,
        _source_file
    from {{ source_or_seed('goods_realization_lost') }}

),

unioned as (

    select * from shipped
    union all select * from delivered
    union all select * from unredeemed
    union all select * from returned
    union all select * from lost

),

deduplicated as (

    -- a month can be re-exported: keep the latest load per row
    select *
    from unioned
    qualify row_number() over (
        partition by report_month, event_type, partner_order_id, shop_sku
        order by _loaded_at desc
    ) = 1

),

renamed as (

    select
        {{ dbt_utils.generate_surrogate_key(['report_month', 'event_type', 'partner_order_id', 'shop_sku']) }}
                                                            as realization_line_key,
        report_month::varchar                               as report_month,          -- 'YYYY-MM'
        event_type::varchar                                 as event_type,
        partner_order_id::varchar                           as order_id,              -- = stg_ym__orders.order_id
        shop_sku::varchar                                   as sku,
        warehouse_sku::varchar                              as warehouse_sku,
        offer_name::varchar                                 as product_name,
        order_type::varchar                                 as order_type,
        payment_method::varchar                             as payment_method,
        vat_rate::varchar                                   as vat_rate,
        try_to_date(order_date, 'DD.MM.YYYY')               as ordered_date,
        try_to_date(shipped_date, 'DD.MM.YYYY')             as shipped_date,
        try_to_date(delivered_date, 'DD.MM.YYYY')           as delivered_date,
        try_to_date(event_date, 'DD.MM.YYYY')               as event_date,
        try_to_number(event_units, 10, 0)                   as event_units,
        try_to_decimal(price_before_discount, 18, 2)        as price_before_discount,
        try_to_decimal(discount_marketplace_promo, 18, 2)   as discount_marketplace_promo,
        try_to_decimal(discount_sber_spasibo, 18, 2)        as discount_sber_spasibo,
        try_to_decimal(discount_yandex_plus, 18, 2)         as discount_yandex_plus,
        try_to_decimal(price_after_discount, 18, 2)         as price_after_discount,
        try_to_decimal(total_before_discount, 18, 2)        as total_before_discount,
        try_to_decimal(total_discount, 18, 2)               as total_discount,
        try_to_decimal(total_after_discount, 18, 2)         as total_after_discount,
        try_to_decimal(total_vat, 18, 2)                    as total_vat,
        try_to_decimal(redeemed_amount, 18, 2)              as redeemed_amount,
        _loaded_at::timestamp_ntz                           as _loaded_at,
        _source_file::varchar                               as _source_file
    from deduplicated

)

select * from renamed
