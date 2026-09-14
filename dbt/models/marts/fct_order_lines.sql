-- The order line as a FACT: one row per order × line, everything the business asks about a sold (or not sold)
-- unit — what was ordered, what was received, what the buyer paid, what the marketplace kept.
-- Grain: order × line (order_line_key) — identical to int_order_lines. The mart adds the final money columns and
-- the date basis, and it is the one place that decides what "revenue" and "margin" mean. Its only join is the
-- unit-cost lookup: cost of goods is a measure of the sale (Kimball's retail fact carries extended cost next to
-- extended price), so it lands at the finest grain and fct_sales_daily stays one group by over this table.
--
--   * a sale happens on the day the buyer RECEIVED the order → delivered_date; orders_stats has no delivery date,
--     but the status does not move after delivery (returns arrive as line events only), so status_updated_at of a
--     DELIVERED / PARTIALLY_DELIVERED order is the moment of receipt; checked against the realization report's
--     delivered_date in analyses/revenue_reconciliation.sql (block `dates`);
--   * revenue = price_buyer_total + price_marketplace_total, the price before marketplace-funded discounts —
--     picked by reconciliation with the realization report (−0.7 % over 20 months), not by the API docs;
--     recognised for delivered units only and only once received (in-flight lines carry a forecast units_delivered
--     but no delivered_date → revenue 0), restated when a return comes in (units_delivered drops → revenue drops);
--   * fees are NOT scaled by delivery: the marketplace charges them whether or not the buyer collected the parcel,
--     so an unredeemed line has revenue 0 and fees > 0 — that is the cost of unredeemed orders, not a bug;
--   * cogs = units_delivered × unit_cost of the version valid on delivered_date (stg_finance__unit_costs). Versioned
--     by date, not by batch: the data has no batch per unit, so a line is costed at the batch that was current when
--     it was received — an accepted approximation. An undelivered line has cogs 0 and a negative margin equal to
--     its fees. cogs_estimated flags the part of cogs that rests on a planned (not actual) cost, so BI can show
--     how much of the margin is an estimate;
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
-- A new cost file restates cogs on EVERY line, not only recent ones: when stg_finance__unit_costs was loaded after
-- the last run, the incremental filter widens to all rows and the whole table is rewritten (delete+insert by order_id
-- handles that); tests/assert_fct_order_lines_is_current.sql compares cogs with the current cost version as well.
--
-- loss_reason is the third thing the window cannot keep current, and for a different reason. The window is anchored to
-- max(status_updated_at) in THIS table — the last 30 days of ORDER LIFE, not of loads — and that boundary only moves
-- forward, while the reason comes from a second source loaded on its own schedule: a reason arriving today for an order
-- cancelled in January 2025 belongs to a row the window will never look at again. Hence the third condition below.
-- What no predicate can cover: a change to the reason tree or to var pickup_storage_days — nothing is reloaded then,
-- the view changes and the table does not. Such a change, and the first release of these columns, must be followed by
-- --full-refresh; assert_fct_order_lines_is_current.sql is what turns a forgotten one into a red test.
-- One invariant holds the scheme together: EVERY condition in the filter must be true for a whole ORDER, never for one
-- of its lines — delete+insert keyed by order_id deletes all lines of every order it touches, so a condition true for
-- one line and false for its sibling would delete the sibling and never insert it back. The three conditions here
-- qualify because status_updated_at and the business-orders row are order-grained (the latter rests on
-- unique(order_id) in stg_ym__business_orders — without that test the join in int_order_lines would also fan out),
-- and the cost condition widens to everything.

{{ config(
    materialized='incremental',
    incremental_strategy='delete+insert',
    unique_key='order_id',
    on_schema_change='append_new_columns'
) }}

with lines as (

    select
        *,
        -- date of receipt: the status timestamp of a delivered order, in the marketplace's (Moscow) wall clock.
        -- RETURNED = delivered, then fully returned; its status timestamp is the return, so for those orders
        -- delivered_date is an upper bound (the exact date is only in the realization report). Their revenue is 0,
        -- so fct_sales_daily is unaffected — only "orders received per day" counts shift slightly.
        iff(order_status in ('DELIVERED', 'PARTIALLY_DELIVERED', 'RETURNED'),
            {{ moscow_date('status_updated_at') }},
            null)                                                   as delivered_date
    from {{ ref('int_order_lines') }}

    {% if is_incremental() %}
    {#- Both anchors are coalesced: an EXISTING but EMPTY table (an aborted run, a manual truncate) has max() = null,
        every comparison would be null, no row would be selected — and the table would stay empty on every run after
        that. With the fallbacks the next run rebuilds it. -#}
    {%- set watermark -%}
        coalesce((select dateadd(day, -{{ var('fct_order_lines_lookback_days', 30) }}, max(status_updated_at))
                  from {{ this }}), '1900-01-01'::timestamp_tz)
    {%- endset -%}
    {%- set last_run -%}
        coalesce((select max(convert_timezone('UTC', dbt_updated_at)::timestamp_ntz) from {{ this }}),
                 '1900-01-01'::timestamp_ntz)
    {%- endset -%}
    -- everything that changed since the last run, plus a window back for late fees and return events …
    where status_updated_at >= {{ watermark }}
    -- … or everything, when the cost file was reloaded after the last run (cogs changes on every line)
    or (select max(_loaded_at) from {{ ref('stg_finance__unit_costs') }}) > {{ last_run }}
    -- … or the orders whose REASON arrived later than the last run. Per order, not "widen to everything" like the cost
    -- condition above: the business-orders source is pulled regularly, so a max()-based form would make every run a
    -- full rebuild. An order with no row in that source yet is picked up by this the moment one appears. Read from
    -- staging, like the cost timestamp above, so no technical column has to travel through the analytical layer;
    -- _loaded_at there is written per FILE at read time and is UTC (ingest/load_to_snowflake.py), the same basis as
    -- dbt_updated_at.
    or order_id in (
        select order_id
        from {{ ref('stg_ym__business_orders') }}
        where _loaded_at > {{ last_run }}
    )
    {% endif %}

),

unit_costs as (

    select sku, valid_from, valid_to, unit_cost, cost_basis, is_estimate, sku_cost_key
    from {{ ref('stg_finance__unit_costs') }}

),

-- the cost version valid on the day of receipt; undelivered lines have no delivered_date and get no cost
costed as (

    select
        l.*,
        c.sku_cost_key,
        c.unit_cost,
        c.cost_basis,
        c.is_estimate                                               as is_cost_estimate
    from lines as l
    left join unit_costs as c
        on  c.sku = l.sku
        and l.delivered_date >= c.valid_from
        and l.delivered_date <= coalesce(c.valid_to, '9999-12-31'::date)

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
        sku_cost_key,                                               -- cost version that priced this line (null until delivered)

        -- dates (role-playing on dim_dates)
        ordered_date,
        delivered_date,                                             -- see `lines`
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
        is_order_partly_kept,                                       -- the order kept some units AND rejected some: the parcel was opened (int_order_lines)
        -- WHY the refused units were refused (int_order_cancellations + the line-level evidence). Null wherever
        -- nothing was refused — including returned lines, whose reason lives in the returns API and is not ingested.
        -- Combine it with units_rejected, fee_total and contribution_margin only, never with revenue: a fully lost
        -- line has revenue 0, but a line that lost SOME of its units keeps the revenue of the rest (line_status
        -- partially_delivered — one line in the whole history so far), so "revenue by loss reason" returns a small
        -- plausible number rather than an obvious zero. A share of losses is taken of the units that came back.
        loss_reason,
        loss_reason_is_inferred,                                    -- the reason rests on the storage-window inference, not on a statement (int_order_cancellations)

        -- units
        units_ordered,
        units_rejected,
        units_returned,
        units_rejected_defect,                                      -- units that came back unsellable (warehouse booked them DEFECT): a lower bound,
        units_returned_defect,                                      -- stockType is filled only after processing. Their cost is written off NOWHERE yet.
        units_delivered,

        -- price of the line as ordered
        price_buyer_total,                                          -- paid by the buyer after all discounts (= realization total_after_discount)
        price_marketplace_total,                                    -- marketplace-funded discount, compensated to the seller
        cashback_total,                                             -- Plus points inside price_marketplace_total; informational
        price_buyer_total + coalesce(price_marketplace_total, 0)    as price_total,   -- price before marketplace discounts (= realization total_before_discount)

        -- revenue: the delivered share of price_total, recognised on receipt — 0 while the order is in flight
        -- (PROCESSING / DELIVERY / PICKUP carry units_delivered = units_ordered as a forecast, is_final = false),
        -- restated on returns
        iff(delivered_date is not null,
            round((price_buyer_total + coalesce(price_marketplace_total, 0))
                  * div0(units_delivered, units_ordered), 2),
            0)                                                      as revenue,

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

        -- cost of goods: delivered units at the unit cost valid on delivered_date. Like revenue, 0 while in flight
        -- (no delivered_date → no cost version → unit_cost null), restated on returns
        unit_cost,                                                  -- per unit, RUB — reference, not additive
        cost_basis,                                                 -- batch_actual | supply_allocated
        coalesce(is_cost_estimate, false)                           as is_cost_estimate,
        round(units_delivered * coalesce(unit_cost, 0), 2)          as cogs,
        iff(coalesce(is_cost_estimate, false),
            round(units_delivered * coalesce(unit_cost, 0), 2), 0)  as cogs_estimated,   -- the part of cogs resting on a planned cost

        -- contribution: revenue − fees − cogs. Negative for unredeemed lines (fees, no revenue) — the price of невыкуп;
        -- for in-flight lines it is −fees for now and becomes final on receipt
        iff(delivered_date is not null,
            round((price_buyer_total + coalesce(price_marketplace_total, 0))
                  * div0(units_delivered, units_ordered), 2),
            0)
            - fee_total
            - round(units_delivered * coalesce(unit_cost, 0), 2)    as contribution_margin,

        current_timestamp()                                         as dbt_updated_at

    from costed

)

select * from final
