-- The order line as an analytical entity.
-- Grain: order × line (order_line_key) — same as stg_ym__order_lines. Two lines of one order can share an SKU,
-- so sku is NOT the grain; fct_sales_daily aggregates to sku.
--
-- Three things exist here and nowhere upstream:
--   1. what happened to the units: units_rejected / units_returned from the line events → units_delivered, line_status
--   2. the order's fees allocated to the line, proportional to price_buyer_total (see `allocated`)
--   3. is_final — whether the order has reached a terminal status, so the delivered units are a fact, not a forecast
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

events as (

    -- one row per line: how many units came back and when
    select
        order_line_key,
        sum(iff(event_status = 'REJECTED', event_units, 0))         as units_rejected,
        sum(iff(event_status = 'RETURNED', event_units, 0))         as units_returned,
        max(iff(event_status = 'REJECTED', event_date, null))       as rejected_date,
        max(iff(event_status = 'RETURNED', event_date, null))       as returned_date,
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

        -- units
        l.units_ordered,
        coalesce(e.units_rejected, 0)                               as units_rejected,
        coalesce(e.units_returned, 0)                               as units_returned,
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

final as (

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

        -- terminal = everything except the in-flight statuses; keep in sync with stg_ym__orders accepted_values
        order_status not in ('PROCESSING', 'DELIVERY', 'PICKUP')    as is_final,

        units_ordered,
        units_rejected,
        units_returned,
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

)

select * from final
