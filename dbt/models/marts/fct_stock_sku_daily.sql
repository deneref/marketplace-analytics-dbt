-- One sku on one day: the stock a buyer could see at the START of the day and the demand that arrived DURING it.
-- This is the mart the old rpt_stock_days derived on the fly (its own comment called it "the one honest
-- alternative"); it is a mart now because two reporting views read it (rpt_stock_days, rpt_stock_sku) and because
-- the sku-grain rules below must be computed once, not once per BI query.
--
-- Grain: date_day × sku, DENSE over the calendar from the day after the sku's first stock report to the day after
-- the latest one. ~51 skus × ~620 days ≈ 31 k rows.
--   * stock at the start of day D = fct_inventory_daily for snapshot_date = D − 1 (a snapshot is the END of its day;
--     an order placed on D is reserved in the row of D — 06_пет-проект/16), summed over warehouses that are not
--     returns warehouses (units there are parcels on their way back, shown apart as units_fit_at_returns_sod);
--   * demand = fct_order_lines by ordered_date, the day the buyer acted. Never delivered_date;
--   * a day without a stock report is a visible hole: is_report_missing, stock columns NULL — not zero;
--   * a day after the latest ORDER data is a second kind of hole: is_demand_known = FALSE. The two sources refresh
--     separately (on 2026-09-15 stock ran 11 days ahead of orders) and a day "in stock, zero orders" must not be
--     counted as evidence of zero demand. Every window in rpt_stock_sku stops at latest_demand_date.
-- Table, not incremental: rebuilt in seconds, the past never changes.

{{ config(materialized='table') }}

with dates as (

    select date_day
    from {{ ref('dim_dates') }}

),

warehouses as (

    select warehouse_id, is_return_warehouse
    from {{ ref('dim_warehouses') }}

),

stock_by_sku as (

    -- one snapshot per sku per day: the network without returns warehouses
    select
        f.snapshot_date,
        f.sku,
        sum(iff(not coalesce(w.is_return_warehouse, false), f.units_available, 0))  as units_available,
        sum(iff(not coalesce(w.is_return_warehouse, false), f.units_fit, 0))        as units_fit,
        sum(iff(not coalesce(w.is_return_warehouse, false), f.units_freeze, 0))     as units_freeze,
        sum(iff(not coalesce(w.is_return_warehouse, false),
                coalesce(f.units_quarantine, 0) + coalesce(f.units_defect, 0)
              + coalesce(f.units_expired, 0) + coalesce(f.units_utilization, 0), 0))
                                                                                     as units_unsellable,
        sum(iff(coalesce(w.is_return_warehouse, false), f.units_fit, 0))            as units_fit_at_returns
    from {{ ref('fct_inventory_daily') }} as f
    left join warehouses as w
        on w.warehouse_id = f.warehouse_id
    group by f.snapshot_date, f.sku

),

latest_report as (

    select max(snapshot_date) as snapshot_date
    from stock_by_sku

),

demand as (

    -- five buckets that add up to units_ordered (kept / unredeemed / returned / in flight / cancelled)
    select
        ordered_date                                                as date_day,
        sku,
        sum(units_ordered)                                          as units_ordered,
        sum(iff(delivered_date is not null, units_delivered, 0))    as units_kept,          -- the fact's units_delivered is already net of rejected and returned; the yml proves the five buckets add up
        sum(units_rejected)                                         as units_unredeemed,
        sum(units_returned)                                         as units_returned,
        sum(iff(line_status = 'in_flight', units_delivered, 0))     as units_in_flight,
        sum(iff(line_status = 'cancelled',
                units_ordered - units_rejected - units_returned, 0)) as units_cancelled,
        count(distinct order_id)                                    as sku_orders_count
    from {{ ref('fct_order_lines') }}
    where not coalesce(is_test_order, false)
    group by ordered_date, sku

),

latest_demand as (

    -- the last day the order feed covers. max(ordered_date) is a proxy for the load watermark: at ~3 orders a day
    -- it lags the real watermark by a day at most. Capped at the day after the latest stock report so that one
    -- mis-dated line cannot turn weeks of "unknown" into "known zero". Replace by the ingest watermark when RAW
    -- carries one; the yml warns when it trails the stock report by more than 3 days.
    select max(d.date_day) as date_day
    from demand as d
    cross join latest_report as l
    where d.date_day <= l.snapshot_date + 1

),

sku_span as (

    select
        s.sku,
        min(s.snapshot_date) + 1                                    as first_day,
        l.snapshot_date + 1                                         as last_day
    from stock_by_sku as s
    cross join latest_report as l
    group by s.sku, l.snapshot_date

),

grid as (

    select d.date_day, s.sku
    from sku_span as s
    inner join dates as d
        on d.date_day between s.first_day and s.last_day

),

days as (

    select
        g.date_day,
        g.sku,
        s.snapshot_date is null                                     as is_report_missing,
        s.units_available                                           as units_available_sod,
        s.units_fit                                                 as units_fit_sod,
        s.units_freeze                                              as units_freeze_sod,
        s.units_unsellable                                          as units_unsellable_sod,
        s.units_fit_at_returns                                      as units_fit_at_returns_sod,
        s.units_available > 0                                       as is_in_stock,           -- NULL on a hole
        g.date_day <= ld.date_day                                   as is_demand_known,
        coalesce(m.units_ordered, 0)                                as units_ordered,
        coalesce(m.units_kept, 0)                                   as units_kept,
        coalesce(m.units_unredeemed, 0)                             as units_unredeemed,
        coalesce(m.units_returned, 0)                               as units_returned,
        coalesce(m.units_in_flight, 0)                              as units_in_flight,
        coalesce(m.units_cancelled, 0)                              as units_cancelled,
        coalesce(m.sku_orders_count, 0)                             as sku_orders_count,
        lr.snapshot_date                                            as latest_snapshot_date,
        ld.date_day                                                 as latest_demand_date,
        g.date_day = lr.snapshot_date + 1                           as is_latest_day
    from grid as g
    cross join latest_report as lr
    cross join latest_demand as ld
    left join stock_by_sku as s
        on  s.sku = g.sku
        and s.snapshot_date = g.date_day - 1
    left join demand as m
        on  m.sku = g.sku
        and m.date_day = g.date_day

),

final as (

    select
        {{ dbt_utils.generate_surrogate_key(["to_char(date_day, 'YYYY-MM-DD')", 'sku']) }} as stock_day_key,  -- to_char: the key must not depend on the session's DATE_OUTPUT_FORMAT
        *,
        -- the first morning with good stock anywhere: zeros before it are a card without a delivery, not a stockout
        min(iff(units_fit_sod > 0, date_day, null)) over (partition by sku)
                                                                    as first_stocked_date,
        -- a zero AFTER the first delivery; FALSE before it (a card without a delivery), NULL on a hole
        iff(is_report_missing, null,
            units_available_sod = 0
            and coalesce(date_day >= min(iff(units_fit_sod > 0, date_day, null)) over (partition by sku), false))
                                                                    as is_stockout_day
    from days

)

select * from final
