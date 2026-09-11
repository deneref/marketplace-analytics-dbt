-- The sales page of the dashboard: one wide row per day × sku × outcome, the facts joined to their product
-- attributes. Two kinds of rows share the columns:
--   * outcome = 'delivered'  — fct_sales_daily as is: units received, revenue and margin recognised on the day
--     the buyer received the goods (event_date = delivered_date);
--   * outcome = 'unredeemed' / 'returned' — the cost of parcels that came back: lines of fct_order_lines whose
--     units_delivered ended at zero, aggregated to the day the units were received back by the warehouse
--     (event_date = rejected_date / returned_date, falling back to the order's status change when the event
--     carries no date — about 7 % of events). Revenue 0, cogs 0, fee_total > 0, contribution_margin = −fee_total.
--     Partially unredeemed lines are NOT here a second time: they keep units_delivered > 0, so they are already
--     inside fct_sales_daily with their full, unscaled fees.
-- The union lives in reporting, not in the mart: fct_sales_daily stays a table of sales ("a sale is a delivered
-- unit"), and a dashboard page reads one source. With it the page's margin is the margin AFTER unredeemed and
-- returned parcels — SUM(contribution_margin) over all rows — while the margin of what was sold is the same sum
-- filtered to outcome = 'delivered'. Losses are recognised later than sales (a parcel sits unclaimed, then
-- travels back), so the last two or three weeks of any period undercount losses more than they undercount sales.
-- dim_products is one row per sku, so the join cannot fan out. unique(sales_daily_key) is what proves it — and
-- it is the ONLY guard: the reconciliation tests below cannot see a fan-out. Note these tests have no scheduled
-- run yet (CI is dbt parse plus a build on demo seeds; the daily job selects staging), so they prove it when
-- dbt test is run by hand.
--
-- Why this layer exists at all. The Snowflake connector for Looker Studio does not push filters down for
-- DATE / TIME / TIMESTAMP columns, so the date control on a dashboard never narrows the query — the dataset
-- has to be small by itself. Its 1M-row / 50MB quota is counted per data source, and blends take at most five
-- sources, aggregate each one before joining and cannot be reused across reports. Add our own rule that facts
-- carry keys only, and a dashboard reading fct_sales_daily directly would be a chart of SKU codes. Hence one
-- wide view per dashboard page, joined here rather than in the BI tool.
--
-- What is deliberately NOT here:
--   * ratios (margin %, fee share, average price, estimated-cost share) — the numerator and the denominator
--     are both columns and BI divides the sums; a stored ratio returns garbage under any grouping;
--   * calendar attributes (week, month, weekday) — Looker Studio derives them from event_date, so this
--     page needs no dim_dates;
--   * days without sales — the table is sparse (about 5 % of the day × sku cells are filled) and BI draws
--     the zeros. Skus that never sold at all are absent by definition: this is a sales table, and "what never
--     sold" is a question for the assortment page, which starts from dim_products;
--   * dbt_updated_at — no widget needs it, and a third date column makes Looker Studio pick the wrong default
--     date range dimension;
--   * current_basic_price — the brand's prices are public on the marketplace, and the columns here must match
--     rpt_sales_daily_public one for one (the public report is a copy of this one with the data source
--     swapped). A real price next to masked money recovers the multiplier by division;
--   * the fee mix broken out by type — that is the "order economics" page, and it needs fee_type unpivoted
--     into rows, not eight parallel metrics. fee_boost is the exception: promotion is the one cost the brand
--     changes day to day, so it is carried next to the total (and is part of it, not on top);
--   * market_category_name — one-to-one with product_type, which is already here (a singular test checks it).
--
-- Column names are ASCII only: the connector rejects anything else in field names.
--
-- View, not table: the source is a 1.2k-row table and every dashboard query scans the whole set anyway.

{{ config(materialized='view') }}

with sales as (

    select
        delivered_date                                                      as event_date,
        sku,
        'delivered'                                                         as outcome,
        units_delivered,
        0                                                                   as units_lost,
        sku_orders_count,
        lines_count,
        revenue,
        fee_total,
        fee_boost,
        cogs,
        cogs_estimated,
        contribution_margin
    from {{ ref('fct_sales_daily') }}

),

losses as (

    -- one row per day × sku × outcome for parcels that came back in full. Money is passed through from the
    -- lines, not recomputed: revenue and cogs are already 0 there (units_delivered = 0 after restatement) and
    -- contribution_margin is already −fee_total; the yml test proves it stays so.
    select
        coalesce(
            iff(line_status = 'returned', returned_date, rejected_date),
            {{ moscow_date('status_updated_at') }}
        )                                                                   as event_date,
        sku,
        line_status                                                         as outcome,
        0                                                                   as units_delivered,
        sum(units_rejected + units_returned)                                as units_lost,
        count(distinct order_id)                                            as sku_orders_count,
        count(*)                                                            as lines_count,
        sum(revenue)                                                        as revenue,
        sum(fee_total)                                                      as fee_total,
        sum(fee_boost)                                                      as fee_boost,
        sum(cogs)                                                           as cogs,
        sum(cogs_estimated)                                                 as cogs_estimated,
        sum(contribution_margin)                                            as contribution_margin
    from {{ ref('fct_order_lines') }}
    where line_status in ('unredeemed', 'returned')
      and not coalesce(is_test_order, false)
    group by 1, 2, 3

),

events as (

    select * from sales
    union all
    select * from losses

),

products as (

    select * from {{ ref('dim_products') }}

),

final as (

    select
        -- keys and grain
        {{ dbt_utils.generate_surrogate_key(['e.event_date', 'e.sku', 'e.outcome']) }} as sales_daily_key,
        e.event_date,                                                       -- delivered: day of receipt; losses: day the units came back
        e.sku,
        e.outcome,                                                          -- delivered | unredeemed | returned

        -- product attributes: the reason this layer exists
        p.product_name,
        p.product_type_code,
        p.product_type,                                                     -- the dashboard's main axis
        p.model_code,
        p.model_name,
        p.model_colour_code,                                                -- colourway: the level at which a restock is decided
        p.colour_name,
        p.size,
        p.size_order,                                                       -- without it Looker sorts L, M, S, XL
        p.collection,
        p.lifecycle_status,
        p.launch_date,

        -- days since the model launched: the axis for a drop cohort ("units sold by day N after launch"),
        -- which is readable at this volume where a time series is not — the brand sells a median of three
        -- units a day, so day-to-day movement is mostly noise. Checked against the data: of 1 469 sold lines
        -- none precede their model's launch_date, so this is never negative today. It is null when the model
        -- has no launch_date in the product_models seed (SH-012 and SH-013 today, neither sold yet) — the
        -- relationships test does NOT catch that, the seed row exists with an empty date.
        -- CAVEAT: launch_date in the seed is a proxy — the model's first ORDER date — while event_date is
        -- the day of receipt, so day 0 never occurs (observed range 1…577) and the offset is the delivery lag.
        -- Replacing a proxy with a real launch date moves that model's cohort onto a different basis.
        -- For loss rows it is the days from launch to the day the parcel came back — informational only.
        datediff(day, p.launch_date, e.event_date)                        as days_since_launch,

        p.is_in_catalogue,                                                  -- filter: include withdrawn cards or not

        -- units
        e.units_delivered,                                                  -- 0 on loss rows
        e.units_lost,                                                       -- units that came back (unredeemed or returned); 0 on delivered rows
        e.sku_orders_count,                                                 -- orders containing this sku today; NOT additive across skus
        e.lines_count,

        -- money, all RUB. Delivered rows: recognised on delivered_date and restated on returns. Loss rows: fees only.
        e.revenue,
        e.fee_total,
        e.fee_boost,                                                         -- promotion, inside fee_total — not added on top
        e.cogs,
        e.cogs_estimated,                                                   -- part of cogs resting on a planned cost; share = cogs_estimated / cogs in BI
        e.contribution_margin                                                -- revenue − fee_total − cogs; on loss rows = −fee_total

    from events as e
    left join products as p
        on p.sku = e.sku
    -- left, not inner: the fact already carries a relationships test to dim_products at severity error, and a
    -- view feeding a dashboard should not silently drop a day of sales the moment a new sku outruns the catalogue
    -- snapshot. A missing row surfaces as null attributes, which the not_null tests below report.

)

select * from final
