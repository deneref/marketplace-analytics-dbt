-- The order line as an analytical entity.
-- Grain: order × line (order_line_key) — same as stg_ym__order_lines. Two lines of one order can share an SKU,
-- so sku is NOT the grain; fct_sales_daily aggregates to sku.
--
-- Four things exist here and nowhere upstream:
--   1. what happened to the units: units_rejected / units_returned from the line events → units_delivered, line_status
--   2. the order's fees allocated to the line, proportional to price_buyer_total (see `allocated`)
--   3. is_final — whether the order has reached a terminal status, so the delivered units are a fact, not a forecast
--   4. loss_reason — WHY the units that came back came back, for the lines where something came back. The order-level
--      reason is decided in int_order_cancellations; what this model adds is the priority between it and the evidence
--      only visible at line grain, and the rule that a reason is attached ONLY to lines that actually lost units.
-- Everything else is staging columns placed side by side.
--
-- Allocation base: price_buyer_total share within the order. For delivery fees this is a simplification (the
-- marketplace bills delivery by dimensions, not by price) — accepted on purpose; fct_order_fees keeps the
-- unallocated truth and tests/assert_fees_allocation_sums.sql checks nothing is lost or created.

{#- fee types → column names. Add a type here when the accepted_values test on stg_ym__order_fees warns about a new one. -#}
{% set fee_columns = {
    'FEE':                       'fee_commission',
    'DELIVERY_TO_CUSTOMER':      'fee_delivery',
    'AUCTION_PROMOTION':         'fee_boost',
    'PAYMENT_TRANSFER':          'fee_payment_transfer',
    'AGENCY':                    'fee_agency',
    'CROSSREGIONAL_DELIVERY':    'fee_crossregional',
    'RETURN_PROCESSING':         'fee_return_processing',
    'LOYALTY_PARTICIPATION_FEE': 'fee_loyalty',
} %}

with lines as (

    select * from {{ ref('stg_ym__order_lines') }}

),

orders as (

    select * from {{ ref('stg_ym__orders') }}

),

cancellations as (

    -- one row per CANCELLED order: the reason and whether it rests on an inference. Absent for every order that was
    -- not cancelled — including partially unredeemed ones, whose reason comes from the line-level evidence below.
    select
        order_id,
        cancellation_reason,
        reason_is_inferred
    from {{ ref('int_order_cancellations') }}

),

business_orders as (

    -- order attributes from the newer source, taken from STAGING rather than through int_order_cancellations: that
    -- model keeps only cancelled orders, and real_delivery_date on a DELIVERED order is the interesting one — the gap
    -- to delivered_date is how long the parcel waited at the counter (37 % of buyers collect the day it arrives).
    -- The flag is what separates "the order has no reason" from "the order is not in this source yet".
    select
        order_id,
        order_substatus,
        real_delivery_date,
        true                                                        as is_in_business_orders
    from {{ ref('stg_ym__business_orders') }}

),

events as (

    -- one row per line: how many units came back and when
    select
        order_line_key,
        sum(iff(event_status = 'REJECTED', event_units, 0))         as units_rejected,
        sum(iff(event_status = 'RETURNED', event_units, 0))         as units_returned,
        max(iff(event_status = 'REJECTED', event_date, null))       as rejected_date,
        max(iff(event_status = 'RETURNED', event_date, null))       as returned_date,
        -- units that came back unsellable. stockType is filled only after the marketplace warehouse has processed
        -- the parcel, so a unit still in transit counts as neither FIT nor DEFECT: these two are a lower bound
        -- (51 of 817 returned units carry no stockType at all today).
        sum(iff(event_status = 'REJECTED' and stock_type = 'DEFECT', event_units, 0)) as units_rejected_defect,
        sum(iff(event_status = 'RETURNED' and stock_type = 'DEFECT', event_units, 0)) as units_returned_defect,
        max(iff(event_status = 'RETURNED', stock_type, null))       as returned_stock_type   -- FIT / DEFECT / EXPIRED
    from {{ ref('stg_ym__order_line_events') }}
    group by 1

),

order_fees as (

    -- one row per order: fees pivoted by type. Negative amounts are reversals and are summed as-is.
    select
        order_id,
        {% for fee_type, col in fee_columns.items() -%}
        sum(iff(fee_type = '{{ fee_type }}', fee_amount, 0))        as {{ col }}_order,
        {% endfor -%}
        sum(fee_amount)                                             as fee_total_order
    from {{ ref('stg_ym__order_fees') }}
    group by 1

),

joined as (

    select
        l.order_line_key,
        l.order_id,
        l.line_index,
        l.sku,
        l.market_sku,
        l.product_name,
        l.warehouse_id,
        l.warehouse_name,

        -- order attributes
        o.ordered_date,
        o.status_updated_at,
        o.order_status,
        o.payment_type,
        o.delivery_region_id,
        o.delivery_region_name,
        o.is_test_order,

        -- the newer source: order attributes, and the reason (null unless the order was cancelled). Prefixed with
        -- order_ where a line-level counterpart exists, so a join can never quietly swap them.
        b.order_substatus,
        b.real_delivery_date,
        coalesce(b.is_in_business_orders, false)                     as is_in_business_orders,
        c.cancellation_reason                                       as order_cancellation_reason,
        c.reason_is_inferred                                        as order_reason_is_inferred,

        -- units
        l.units_ordered,
        coalesce(e.units_rejected, 0)                               as units_rejected,
        coalesce(e.units_returned, 0)                               as units_returned,
        coalesce(e.units_rejected_defect, 0)                        as units_rejected_defect,
        coalesce(e.units_returned_defect, 0)                        as units_returned_defect,
        e.rejected_date,
        e.returned_date,
        e.returned_stock_type,

        -- money on the line
        l.price_buyer_per_item,
        l.price_buyer_total,
        l.price_marketplace_total,
        l.cashback_total,
        l.bid_fee,

        -- share of the line in the order, the allocation base. One base per ORDER, never mixed within it:
        -- by price when the order has a price, by units when it is free (full discount) — otherwise the shares
        -- of one order would not sum to 1.
        case
            when sum(l.price_buyer_total) over (partition by l.order_id) > 0
                then coalesce(l.price_buyer_total, 0) / sum(l.price_buyer_total) over (partition by l.order_id)
            else l.units_ordered / sum(l.units_ordered) over (partition by l.order_id)
        end                                                         as fee_share,

        -- the line that absorbs the rounding residual: the most expensive one, ties broken by position
        row_number() over (
            partition by l.order_id
            order by l.price_buyer_total desc nulls last, l.line_index
        ) = 1                                                       as is_anchor_line,

        {% for fee_type, col in fee_columns.items() -%}
        coalesce(f.{{ col }}_order, 0)                              as {{ col }}_order,
        {% endfor -%}
        coalesce(f.fee_total_order, 0)                              as fee_total_order

    from lines as l
    left join orders as o
        on o.order_id = l.order_id
    left join events as e
        on e.order_line_key = l.order_line_key
    left join order_fees as f
        on f.order_id = l.order_id
    left join cancellations as c
        on c.order_id = l.order_id
    left join business_orders as b
        on b.order_id = l.order_id

),

rounded as (

    -- naive allocation. Sums per order can now be off by up to ±0.005 × lines.
    select
        *,
        {% for fee_type, col in fee_columns.items() -%}
        round({{ col }}_order * fee_share, 2)                       as {{ col }}_rounded,
        {% endfor -%}
        round(fee_total_order * fee_share, 2)                       as fee_total_rounded
    from joined

),

allocated as (

    -- largest-remainder: every line keeps its rounded amount except the anchor line, which takes
    -- order amount − sum of the others. Sum per order now equals the order's fee exactly.
    select
        *,
        {% for fee_type, col in fee_columns.items() -%}
        iff(is_anchor_line,
            {{ col }}_order - (sum({{ col }}_rounded) over (partition by order_id) - {{ col }}_rounded),
            {{ col }}_rounded)                                      as {{ col }},
        {% endfor -%}
        iff(is_anchor_line,
            fee_total_order - (sum(fee_total_rounded) over (partition by order_id) - fee_total_rounded),
            fee_total_rounded)                                      as fee_total
    from rounded

),

classified as (

    select
        order_line_key,
        order_id,
        line_index,
        sku,
        market_sku,
        product_name,
        warehouse_id,
        warehouse_name,

        ordered_date,
        status_updated_at,
        order_status,
        payment_type,
        delivery_region_id,
        delivery_region_name,
        is_test_order,
        order_substatus,                                            -- raw marketplace substatus (any order; a stage on live ones)
        real_delivery_date,                                         -- day the parcel reached the pickup point / the buyer
        is_in_business_orders,
        order_cancellation_reason,
        order_reason_is_inferred,

        -- terminal = everything except the in-flight statuses; keep in sync with stg_ym__orders accepted_values
        order_status not in ('PROCESSING', 'DELIVERY', 'PICKUP')    as is_final,

        units_ordered,
        units_rejected,
        units_returned,
        units_rejected_defect,
        units_returned_defect,
        -- cancelled-before-shipment orders carry no line events, so the subtraction alone would count them as delivered
        iff(order_status in ('CANCELLED_BEFORE_PROCESSING', 'CANCELLED_IN_PROCESSING'),
            0,
            units_ordered - units_rejected - units_returned)        as units_delivered,
        rejected_date,
        returned_date,
        returned_stock_type,

        -- line_status. Verified against the data (analyses/line_status_combinations.sql, 2026-09-07):
        --   * cancellations before shipment carry NO line events — nothing was shipped, nothing to reject —
        --     so they are recognised by order status alone, first;
        --   * REJECTED events appear only on unredeemed parcels (CANCELLED_IN_DELIVERY / PARTIALLY_DELIVERED);
        --   * order status is NOT updated on returns (DELIVERED orders with a full RETURNED event exist) —
        --     returns are known from events only;
        --   * no line has both REJECTED and RETURNED events.
        -- Re-run the analysis when the accepted_values test on order_status warns about a new status.
        case
            when order_status in ('CANCELLED_BEFORE_PROCESSING', 'CANCELLED_IN_PROCESSING')
                                                                                  then 'cancelled'
            when order_status in ('PROCESSING', 'DELIVERY', 'PICKUP')            then 'in_flight'
            when units_returned  >= units_ordered                                 then 'returned'
            when units_rejected  >= units_ordered                                 then 'unredeemed'
            when units_rejected + units_returned > 0                              then 'partially_delivered'
            else 'delivered'
        end                                                         as line_status,

        price_buyer_per_item,
        price_buyer_total,
        price_marketplace_total,
        cashback_total,
        bid_fee,

        fee_share,
        {% for fee_type, col in fee_columns.items() -%}
        {{ col }},
        {% endfor -%}
        fee_total

    from allocated

),

order_context as (

    -- Order-level context: what happened to the OTHER lines of the same order. One thing only is derived here, and it
    -- is the evidence that the parcel was opened: if the order kept at least one unit and REJECTED at least one, the
    -- buyer stood at the pickup point with the parcel open and handed part of it back. That makes the refusal a
    -- judgement about the item (fit, cut, colour) rather than a no-show — the two cases the marketplace lumps into
    -- CANCELLED_IN_DELIVERY. Rejections only, not returns: a return happens after the whole order was received, so it
    -- says nothing about a refusal at the counter, and counting it here would label post-purchase returns as refusals.
    -- 47 orders / 55 lines as of 2026-09-14. NOT proof: a multi-parcel order could deliver one parcel and lose another in transit,
    -- and the lost line would look refused — units_rejected_defect is the hint that this happened.
    select
        *,
        sum(units_delivered) over (partition by order_id)                   as order_units_delivered,
        sum(units_rejected + units_returned) over (partition by order_id)   as order_units_lost,
        sum(units_rejected) over (partition by order_id)                    as order_units_rejected,
        sum(units_delivered) over (partition by order_id) > 0
            and sum(units_rejected) over (partition by order_id) > 0
                                                                            as is_order_partly_kept
    from classified

),

final as (

    -- WHY the units that came back came back. Two sources of truth meet here, and the priority between them is the
    -- whole point of doing this at line grain:
    --   * the order-level reason from int_order_cancellations — available only for CANCELLED orders, i.e. for parcels
    --     that came back in full;
    --   * the line-level evidence — the order kept some units and lost others, so the parcel was opened and this line
    --     was handed back on purpose. It WINS, and not only because evidence beats inference: a partially unredeemed
    --     order is not cancelled at all, so the marketplace states no reason for it and cancellation_reason is null.
    -- A reason is attached ONLY to lines that actually lost units: an order-level attribute smeared over the lines the
    -- buyer kept is how a dashboard ends up reporting "refusals" on sold goods.
    -- Returned lines get no reason: a return happens after receipt and the buyer's own stated reason for it
    -- (DOES_NOT_FIT / BAD_QUALITY / WRONG_ITEM) lives in the returns API, which is not ingested — null here is
    -- honest, 'unknown' would pretend the question was asked.
    select
        *,
        case
            when units_rejected = 0                     then null       -- nothing was refused: nothing to explain here.
                                                                        -- Covers returns too — a return happens after
                                                                        -- receipt and its stated reason lives in the
                                                                        -- returns API, not ingested; 'unknown' would
                                                                        -- pretend the question had been asked
            when is_order_partly_kept                   then 'refused_at_handover'
            when not is_in_business_orders              then 'not_in_source'
            else coalesce(order_cancellation_reason, 'unknown')
        end                                                             as loss_reason,

        -- Does this line's reason rest on the storage-window inference? FALSE for the line-level evidence (the parcel
        -- was demonstrably opened). NULL wherever there is no reason to speak of — no refusal, or a reason we do not
        -- have: 'false' there would read as "rests on a statement", which is exactly the dishonesty this flag exists
        -- to prevent.
        case
            when units_rejected = 0                     then null
            when is_order_partly_kept                   then false
            when not is_in_business_orders              then null
            when coalesce(order_cancellation_reason, 'unknown') = 'unknown' then null   -- 'unknown' is the absence of a reason, not a reason resting on a statement
            else order_reason_is_inferred
        end                                                             as loss_reason_is_inferred
    from order_context

)

select * from final
