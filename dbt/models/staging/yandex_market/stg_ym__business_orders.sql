{{ config(materialized='view') }}

-- Staging rule: rename, cast. No joins, no aggregation, no business logic — the tree that turns these columns into
-- "why was this parcel not bought" lives in int_order_cancellations, and so does the storage window it needs.
-- Grain: order. One row per marketplace order, latest load wins.
--
-- Why a second order source exists at all: orders_stats carries neither a cancellation reason nor any delivery date,
-- so an unredeemed parcel there is only CANCELLED_IN_DELIVERY, and "the buyer never collected it" cannot be told
-- from "the buyer stood at the counter and handed it back". Three columns here separate those: order_substatus,
-- real_delivery_date and is_cancel_requested. Money, the fine-grained order status and the per-unit REJECTED /
-- RETURNED events stay with orders_stats, whose figures reconcile with the realization report — see the yml for the
-- division of labour and for the counts this model was checked against (as of 2026-09-12).
--
-- Two traps, both handled by naming rather than by warnings:
--   1. this source's status is a COARSER vocabulary (DELIVERED covers delivered, partially delivered and returned;
--      CANCELLED covers all three kinds of cancellation) → carried as order_status_coarse, never as order_status;
--   2. order_substatus is a processing STAGE on live orders and a cancellation REASON on cancelled ones — one column,
--      two meanings, told apart only by order_status_coarse. A model-level test pins that assumption.
-- Columns that exist under the same name in stg_ym__orders / stg_ym__order_lines are prefixed (order_updated_at,
-- order_warehouse_id): the values are close but not identical, and a silent swap in a join would move dates and
-- warehouses. payment_type keeps its name — it is the same thing in both sources, and a singular test compares them.

with src as (

    select * from {{ source_or_seed('business_orders') }}

),

latest as (

    -- Windows abut by creation date (creationDateTo is exclusive), so one backfill writes each order once; a re-run
    -- or a future catch-up writes it again, hence the same dedup rule as stg_ym__orders. _loaded_at is stamped per FILE
    -- at read time in UTC (ingest/load_to_snowflake.py), so it does order two run folders correctly; the tie-break is
    -- for files read within the same timestamp — updateDate, the source's own "last change", decides then.
    select *
    from src
    qualify row_number() over (
        partition by orderid
        order by _loaded_at desc, try_to_timestamp_tz(updatedate) desc nulls last, _source_file desc
    ) = 1

),

parsed as (

    -- one parse per row instead of seven in the select list; try_ so that a truncated JSON nulls the column
    -- instead of failing every query against this view
    select
        *,
        try_parse_json(delivery)                                as delivery_json
    from latest

),

renamed as (

    select
        orderid::varchar                                        as order_id,
        programtype::varchar                                    as program_type,         -- FBY on every order so far

        -- status and reason
        status::varchar                                         as order_status_coarse,   -- see trap 1 in the header
        substatus::varchar                                      as order_substatus,       -- stage on live orders, reason on cancelled ones
        try_to_boolean(cancelrequested)                         as is_cancel_requested,   -- the BUYER pressed cancel

        -- timestamps. Both carry a +03:00 offset and a variable number of fractional digits (four shapes in the
        -- history); try_to_timestamp_tz eats all of them.
        try_to_timestamp_tz(creationdate)                       as ordered_at,
        try_to_timestamp_tz(updatedate)                         as order_updated_at,      -- the status clock: equals orders_stats.status_updated_at to the second on 2 331 of 2 346 shared orders, the rest changed after that source was last pulled

        -- delivery. BusinessOrderDeliveryDatesDTO types all three dates as ISO (`format: date`), and every value in
        -- the data is ISO. (The DD-MM-YYYY variant belongs to the campaign-scoped orders DTO, not to this endpoint —
        -- do not "defend" against it here: a mask that matches nothing only hides the switch it pretends to catch.
        -- What catches it is the delivered-order test in the yml, which fails when the column goes empty.)
        delivery_json:type::varchar                             as delivery_type,         -- PICKUP | DELIVERY | POST
        delivery_json:dispatchType::varchar                     as dispatch_type,         -- MARKET_BRANDED_OUTLET | UNKNOWN; NOT a pickup-vs-courier flag, see the yml
        delivery_json:deliveryServiceId::varchar                as delivery_service_id,
        delivery_json:warehouseId::varchar                       as order_warehouse_id,   -- warehouse the order shipped FROM, order-level
        try_to_date(delivery_json:dates.fromDate::varchar, 'YYYY-MM-DD')    as planned_delivery_from_date,
        coalesce(
            try_to_date(delivery_json:dates.toDate::varchar, 'YYYY-MM-DD'),
            try_to_date(delivery_json:dates.fromDate::varchar, 'YYYY-MM-DD')             -- documented: an absent toDate means fromDate
        )                                                       as planned_delivery_to_date,
        try_to_date(delivery_json:dates.realDeliveryDate::varchar, 'YYYY-MM-DD')
                                                                as real_delivery_date,    -- day the goods reached the PICKUP POINT (self-pickup) or the buyer (courier) — NOT the day of purchase, see the yml

        -- payment
        paymenttype::varchar                                    as payment_type,          -- PREPAID | POSTPAID
        paymentmethod::varchar                                  as payment_method,        -- YANDEX | BOUND_CARD_ON_DELIVERY | SBP | BNPL_* | …
        try_to_boolean(fake)                                    as is_test_order,

        _loaded_at::timestamp_ntz                               as _loaded_at,
        _source_file::varchar                                   as _source_file
    from parsed

)

select * from renamed

-- Not carried, on purpose:
--   * ITEMS — the order lines, including instances[].cis (Chestny Znak marking codes) and offerName. The unit-level
--     truth is orders_stats' items[].details, which the models already use; carrying the array here would parse a
--     VARIANT of marking codes on every dashboard query for a cross-check nobody reads. When line-level statuses are
--     needed (they are the only per-line source for orders younger than the last orders_stats pull), they get their
--     own model, stg_ym__business_order_items, as the layer's one-array-one-model rule requires.
--   * NOTES — the buyer's instructions to the courier: checked, and they contain personal data (phone numbers, door
--     codes, "оставить у двери"). Personal data with no analytical use does not enter a modelled layer; RAW keeps it.
--   * PRICES — order-level {payment, subsidy}. Revenue is built from orders_stats, which reconciles with the
--     realization report (−0.7 % over 20 months); a second, unreconciled money column invites the wrong sum.
--   * DELIVERY.serviceName — 'Самовывоз' / 'Доставка', one-to-one with delivery_type (checked on every order).
--   * DELIVERY.dates.fromTime / toTime — the promised time window, '00:00:00' on all but a handful of courier orders.
--   * BUYERTYPE — PERSON everywhere and already in stg_ym__orders; SOURCEPLATFORM — MARKET everywhere;
--     CAMPAIGNID — constant; EXTERNALORDERID — identical to order_id; DELIVERY.deliveryPartnerType — YANDEX_MARKET.
