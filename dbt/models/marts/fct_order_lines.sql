-- The order line as a FACT: one row per order × line, everything the business asks about a sold (or not sold)
-- unit — what was ordered, what was received, what the buyer paid, what the marketplace kept.
-- Grain: order × line (order_line_key) — identical to int_order_lines. A mart adds no joins here; it adds the
-- final money columns and the date basis, and it is the one place that decides what "revenue" means.
--
--   * a sale happens on the day the buyer RECEIVED the order → delivered_date; orders_stats has no delivery date,
--     but the status does not move after delivery (returns arrive as line events only), so status_updated_at of a
--     DELIVERED / PARTIALLY_DELIVERED order is the moment of receipt; checked against the realization report's
--     delivered_date in analyses/revenue_reconciliation.sql (block `dates`);
--   * revenue = price_buyer_total + price_marketplace_total, the price before marketplace-funded discounts —
--     picked by reconciliation with the realization report (−0.7 % over 20 months), not by the API docs;
--     recognised for delivered units only, restated when a return comes in (units_delivered drops → revenue drops);
--   * fees are NOT scaled by delivery: the marketplace charges them whether or not the buyer collected the parcel,
--     so an unredeemed line has revenue 0 and fees > 0 — that is the cost of unredeemed orders, not a bug;
--   * keys only (sku, warehouse_id, dates) — names and categories come from dim_products / dim_warehouses.
--
-- Incremental: `delete+insert` keyed by ORDER, not by line. The unit of change in the source is the order —
-- a late fee (RETURN_PROCESSING a month after delivery) or a return event re-allocates fees across all lines of
-- the order — so the whole order is rewritten. The lookback window covers status changes AND late events:
-- returns do not move status_updated_at, so the window must be wider than the return period plus logistics
-- (var fct_order_lines_lookback_days, default 30). tests/assert_fct_order_lines_is_current.sql catches rows that
-- the window failed to refresh; on a logic change run with --full-refresh.
-- At today's size (2.5k lines) a table would rebuild in seconds; incremental is here to show the pattern and
-- the tests that make it safe.

{{ config(
    materialized='incremental',
    incremental_strategy='delete+insert',
    unique_key='order_id',
    on_schema_change='append_new_columns'
) }}

with lines as (

    select *
    from {{ ref('int_order_lines') }}

    {% if is_incremental() %}
    -- everything that changed since the last run, plus a window back for late fees and return events
    where status_updated_at >= (
        select dateadd(day, -{{ var('fct_order_lines_lookback_days', 30) }}, max(status_updated_at))
        from {{ this }}
    )
    {% endif %}

),

final as (

    select
        -- keys
        order_line_key,
        order_id,
        line_index,
        sku,
        market_sku,
        warehouse_id,

        -- dates (role-playing on dim_dates)
        ordered_date,
        -- date of receipt: the status timestamp of a delivered order, in the marketplace's (Moscow) wall clock.
        -- RETURNED = delivered, then fully returned; its status timestamp is the return, so for those orders
        -- delivered_date is an upper bound (the exact date is only in the realization report). Their revenue is 0,
        -- so fct_sales_daily is unaffected — only "orders received per day" counts shift slightly.
        iff(order_status in ('DELIVERED', 'PARTIALLY_DELIVERED', 'RETURNED'),
            to_date(to_timestamp_ntz(convert_timezone('Europe/Moscow', status_updated_at))),
            null)                                                   as delivered_date,
        rejected_date,
        returned_date,
        status_updated_at,

        -- order attributes (low-cardinality, kept on the fact — no junk dimension)
        order_status,
        line_status,
        is_final,
        payment_type,
        delivery_region_id,
        delivery_region_name,
        is_test_order,
        returned_stock_type,

        -- units
        units_ordered,
        units_rejected,
        units_returned,
        units_delivered,

        -- price of the line as ordered
        price_buyer_total,                                          -- paid by the buyer after all discounts (= realization total_after_discount)
        price_marketplace_total,                                    -- marketplace-funded discount, compensated to the seller
        cashback_total,                                             -- Plus points inside price_marketplace_total; informational
        price_buyer_total + coalesce(price_marketplace_total, 0)    as price_total,   -- price before marketplace discounts (= realization total_before_discount)

        -- revenue: the delivered share of price_total; 0 until delivered, restated on returns
        round((price_buyer_total + coalesce(price_marketplace_total, 0))
              * div0(units_delivered, units_ordered), 2)            as revenue,

        -- fees allocated to the line (int_order_lines), positive = charged, negative = reversal
        fee_commission,
        fee_delivery,
        fee_boost,
        fee_payment_transfer,
        fee_agency,
        fee_crossregional,
        fee_return_processing,
        fee_loyalty,
        fee_total,
        bid_fee,

        -- contribution before COGS; COGS joins in fct_sales_daily (private seed, by sku × validity date)
        round((price_buyer_total + coalesce(price_marketplace_total, 0))
              * div0(units_delivered, units_ordered), 2) - fee_total   as margin_before_cogs,

        current_timestamp()                                         as dbt_updated_at

    from lines

)

select * from final
