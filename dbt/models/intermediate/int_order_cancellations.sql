-- Why an order was cancelled, as far as the marketplace's own fields allow. Grain: order, cancelled orders only.
--
-- The question "could the brand have prevented this loss" has no column anywhere. stats/orders reports every
-- unredeemed parcel as CANCELLED_IN_DELIVERY with no reason at all; the business-orders endpoint does carry a reason,
-- but its substatus alone misleads — USER_CHANGED_MIND ("cancelled for personal reasons") sits on orders whose parcel
-- had already reached the pickup point and where nobody pressed cancel. So the reason is a decision over three fields
-- (order_substatus, real_delivery_date, is_cancel_requested) plus the storage window, and this is the only place that
-- makes it. Counts, and what each value covers, are in the yml; here is why the rules stand in this order:
--   1. a STATED not-collected — PICKUP_EXPIRED (the warehouse's own expiry event) or
--      USER_HAS_NO_TIME_TO_PICKUP_ORDER (the buyer saying they will not come). Both are statements about collection,
--      and both beat the mere fact of a cancellation request, which says nothing about why;
--   2. a STATED delivery failure — nobody chose anything, the parcel did not get there;
--   3. a payment substatus — the order died at checkout: unpaid, wrong payment method, a forgotten bonus. Above the
--      cancellation request on purpose: many of these do carry a request, and "abandoned at payment" is the more
--      specific fact. Nothing was shipped, so these never reach a loss row;
--   4. a cancellation request from the buyer — a decision made remotely, wherever the parcel was. Deliberately ABOVE
--      the explicit refusal substatuses: USER_REFUSED_PRODUCT with a request and no arrival is a buyer changing their
--      mind before delivery, not a refusal at a counter;
--   5. a STATED refusal (USER_REFUSED_PRODUCT / USER_REFUSED_QUALITY) on an arrived parcel — the only case where the
--      marketplace itself says the buyer held the goods and handed them back;
--   6. no arrival and nothing above → 'unknown'. Someone ended the order and the data does not say who;
--   7. the parcel arrived, no request, and the order ended within the storage window → 'refused_at_handover';
--   8. later than the window → 'not_collected'.
--
-- Rules 7 and 8 are an INFERENCE, and reason_is_inferred marks exactly those rows. What they rest on: a parcel ends
-- inside the storage window only if something happened, and that something is either the buyer at the counter or the
-- shop — and the shop does not cancel here. What they do NOT rest on: any record of a visit, because the marketplace
-- keeps none. Two independent checks say the window is the right instrument: PICKUP_EXPIRED never appears before day 8
-- (n=118, days 8/9/10/15/16 only), and FULL_NOT_RANSOM — the marketplace's own "fully unbought" — is concentrated in
-- days 0–4 (70 of 86). But FULL_NOT_RANSOM states the OUTCOME, not the reason, which is why it is left to the window
-- rules rather than read as a stated refusal.
-- The substatuses allowed to reach rules 7–8 are NOT a closed set here: a value the marketplace has never sent before
-- would fall through and become the headline number silently. tests/assert_cancellation_substatuses_known.sql is what
-- notices; the accepted_values test on stg_ym__business_orders.order_substatus is what notices a new value at all.
--
-- The window: var pickup_storage_days (7 — the marketplace's official period at a branded outlet). Applied to every
-- channel except courier, where arrival already means the goods were in the buyer's hands. Lockers keep a parcel 2
-- days and a post office 5, but nothing in this source marks either — dispatch_type does not (see
-- stg_ym__business_orders) — so a single window is used and the yml states what that costs.
--
-- What this model deliberately does not know: whether anything was shipped (that is orders_stats.order_status, and
-- int_order_lines only attaches a reason to lines whose units really came back), and partially unredeemed orders —
-- they are not cancelled at all, so the marketplace states no reason for them and their reason comes from the
-- line-level evidence in int_order_lines.

/*
cancelled order
│
├─1─ substatus ∈ {PICKUP_EXPIRED, USER_HAS_NO_TIME_TO_PICKUP_ORDER} ──► not_collected      │ fact
│
├─2─ substatus ∈ {DELIVERY_SERVICE_UNDELIVERED, DAMAGED_BOX, LOST, …} ─► delivery_failed   │ fact
│
├─3─ substatus ∈ {USER_NOT_PAID, RESERVATION_EXPIRED, …} ─────────────► not_paid           │ fact
│
├─4─ cancelRequested = TRUE ──────────────────────────────────────────► cancelled_by_buyer │ fact
│
├─5─ substatus ∈ {USER_REFUSED_PRODUCT, USER_REFUSED_QUALITY}
│      И realDeliveryDate filled.   ─────────────────────────────────► refused_at_handover │ fact
│
├─6─ realDeliveryDate empty ──────────────────────────────────────────► unknown            │  —
│
├─7─ delivered, courier (storage window is empyt) ────────────────────► refused_at_handover│ guess
│
├─8─ delivered, days in storage ≤ 7 ──────────────────────────────────► refused_at_handover│ guess
│
└─9─ delivered, days in storage > 7 ──────────────────────────────────► not_collected      │ guess

 */                                                       

{#- Substatus groups in ONE place: the tree and the inference flag are both read off reason_rule, so they cannot
    disagree, and a new value from the marketplace has one file to be classified in. Keep in sync with the
    accepted_values test on stg_ym__business_orders.order_substatus, which warns when a new value appears. -#}
{% set stated_not_collected_substatuses = ['PICKUP_EXPIRED', 'USER_HAS_NO_TIME_TO_PICKUP_ORDER'] %}
{% set stated_failure_substatuses = [
    'DELIVERY_SERVICE_UNDELIVERED', 'DELIVERY_SERVICE_FAILED', 'DELIVERY_PROBLEMS', 'DELIVERY_NOT_MANAGED_REGION',
    'WAREHOUSE_FAILED_TO_SHIP', 'DAMAGED_BOX', 'SERVICE_FAULT', 'LOST', 'SORTING_CENTER_LOST',
    'DELIVERY_SERVICE_LOST', 'CANCELLED_COURIER_NOT_FOUND'
] %}
{% set payment_substatuses = ['USER_NOT_PAID', 'RESERVATION_EXPIRED', 'USER_WANTED_ANOTHER_PAYMENT_METHOD',
                              'USER_FORGOT_TO_USE_BONUS'] %}
{% set stated_refusal_substatuses = ['USER_REFUSED_PRODUCT', 'USER_REFUSED_QUALITY'] %}

with cancellations as (

    select *
    from {{ ref('stg_ym__business_orders') }}
    where order_status_coarse = 'CANCELLED'

),

measured as (

    select
        order_id,
        order_substatus,
        coalesce(is_cancel_requested, false)                            as is_cancel_requested,   -- absent = no request on record, never "unknown → maybe"
        delivery_type,
        dispatch_type,
        is_test_order,
        real_delivery_date,
        order_updated_at                                                as cancelled_at,
        real_delivery_date is not null                                  as parcel_arrived,

        -- days the parcel sat before the order ended. NULL when no arrival was recorded; 0 means the order ended the
        -- day the parcel arrived. Both clocks are the marketplace's own: cancelled_at equals
        -- orders_stats.status_updated_at to the second, while the warehouse books the returned units days later.
        datediff(day, real_delivery_date, {{ moscow_date('order_updated_at') }})
                                                                        as days_at_pickup,

        -- the window this row is judged against: null for courier orders, where arrival already is handover
        iff(delivery_type = 'DELIVERY', null, {{ var('pickup_storage_days', 7) }})
                                                                        as storage_days_allowed

    from cancellations

),

ruled as (

    -- WHICH rule fired, decided once. The reason and the "is this an inference" flag are both read off this column,
    -- so they cannot drift apart, and one order can be audited without re-reading the CASE.
    select
        *,
        case
            when order_substatus in ({{ "'" ~ stated_not_collected_substatuses | join("', '") ~ "'" }})
                                                                                              then 'stated_not_collected'
            when order_substatus in ({{ "'" ~ stated_failure_substatuses | join("', '") ~ "'" }})
                                                                                              then 'stated_failure'
            when order_substatus in ({{ "'" ~ payment_substatuses | join("', '") ~ "'" }})     then 'payment_abandoned'
            when is_cancel_requested                                                          then 'buyer_request'
            when order_substatus in ({{ "'" ~ stated_refusal_substatuses | join("', '") ~ "'" }})
                 and parcel_arrived                                                           then 'stated_refusal'
            when not parcel_arrived                                                           then 'no_evidence'
            when storage_days_allowed is null                                                 then 'arrival_is_handover'
            when days_at_pickup <= storage_days_allowed                                       then 'within_storage_window'
            else                                                                                   'after_storage_window'
        end                                                             as reason_rule
    from measured

),

final as (

    select
        order_id,
        order_substatus,                                                -- carried raw: the reason is a reading of it, not a replacement
        is_cancel_requested,
        delivery_type,
        dispatch_type,
        is_test_order,
        real_delivery_date,
        cancelled_at,
        parcel_arrived,
        days_at_pickup,
        storage_days_allowed,
        reason_rule,

        case reason_rule
            when 'stated_not_collected'  then 'not_collected'
            when 'stated_failure'        then 'delivery_failed'
            when 'payment_abandoned'     then 'not_paid'
            when 'buyer_request'         then 'cancelled_by_buyer'
            when 'stated_refusal'        then 'refused_at_handover'
            when 'no_evidence'           then 'unknown'
            when 'arrival_is_handover'   then 'refused_at_handover'
            when 'within_storage_window' then 'refused_at_handover'
            when 'after_storage_window'  then 'not_collected'
        end                                                             as cancellation_reason,

        -- TRUE when the verdict came from the window rules rather than from a statement or the buyer's request.
        -- A number built on these rows is a floor with a story, not a measurement — reporting must be able to say
        -- "of which inferred".
        reason_rule in ('within_storage_window', 'after_storage_window', 'arrival_is_handover')
                                                                        as reason_is_inferred
    from ruled

)

select * from final
