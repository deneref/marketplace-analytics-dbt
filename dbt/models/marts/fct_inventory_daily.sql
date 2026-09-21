-- Stock of one SKU at one marketplace warehouse at the end of one day — the periodic-snapshot fact behind
-- "was this size in stock when people were buying", days in stock, stock-outs and days of cover.
-- Grain: snapshot_date × sku × warehouse_id, DENSE: one row for every report day × every sku × warehouse pair the
-- report has ever listed, from the day the pair first appeared. Three decisions make it, all checked on the raw
-- reports (scripts/check_stock_report_day.py, 06_пет-проект/16 and 17, 2026-09-15):
--   * snapshot_date is the end of that day, Moscow time — an order placed on day D is reserved in the row of D, so
--     "the stock buyers saw when ordering on D" is the row of D − 1. Demand joins here on ordered_date − 1, never on
--     delivered_date (an order is placed while the unit is in stock; the parcel arrives days later, often to a row
--     that already says 0). The report says nothing about intraday moves: a unit that sold out at 14:00 was "in stock"
--     for the whole day. fct_sales_daily (delivered_date) is the wrong table to join to this one.
--   * absence is zero: a pair the report does not list that day has nothing in any bucket. The report prints most
--     zero rows itself (more than half of its rows are 'Нет на складе') and, once a pair appears, keeps printing it
--     (185 of 186 pairs on every later report day); it never dropped a pair that still had units the day before.
--     The fill is therefore a guarantee, not a mechanism: is_reported tells a printed zero from a filled one. A day
--     WITHOUT a report is absent, not zero — a gap in the report is a gap here (re-request it by date).
--   * sku is the seller's code. The report prints the warehouse label (K4 for CAP-Bur-006) in SHOP_SKU and the seller's
--     code in ARTICLE; staging takes sku from ARTICLE, so no dim is needed to resolve a label and a label change can never
--     rewrite history here. reported_sku keeps the label for tracing a row back to the report.
-- Buckets are the report's and are NOT additive: units_fit ≈ units_available + units_freeze (sellable + reserved);
-- quarantine / defect / expired / utilization are separate piles that are not for sale. Occasionally the report shows
-- a reservation the day it left the good stock (fit short of available + freeze by 1–2), never the other way round,
-- so downstream reads one column and never sums across them. A unit in delivery is in no bucket: fit drops on
-- shipment and comes back on an unredeemed return.
-- A pair that never leaves the calendar makes "out of stock" ambiguous: before the first unit it is a card without a
-- delivery, after the last unit it may be sold out for good. last_stocked_date / next_stocked_date (units_fit > 0,
-- looking back / ahead within the pair) let reporting tell a stock-out inside the life of a pair from those two,
-- without a flag that BI would average into "share of warehouses without the sku". No is_out_of_stock here for that
-- reason: "in stock for a buyer" is sum(units_available) > 0 over warehouses, on the sku grain, in rpt_stock_days.
-- Not here: names (dim_products, dim_warehouses), demand (fct_order_lines by ordered_date, joined in reporting),
-- days of cover and velocity (ratios of two facts — reporting), stock value (no cost basis for stock yet), inflows
-- (a positive day-to-day change in fit is a delivery OR an unredeemed parcel coming back — not separable here).
-- Warehouse ids come from int_stock_daily (name → id via stg_ym__warehouses). A name that does not resolve has no id
-- to key on and its rows are EXCLUDED — there is no alias seed yet, so tests/assert_inventory_daily_excludes_no_units.sql
-- turns any excluded UNITS into a red build (an excluded row of zeros is tolerated and named by
-- assert_stock_warehouses_resolve). Two labels of one sku at one warehouse on one day are summed in int_stock_daily.
-- Table, not incremental: ~65 k rows for 20 months, rebuilt in seconds; the report of a past day never changes.

{{ config(materialized='table') }}

with stock as (

    select *
    from {{ ref('int_stock_daily') }}

),

keyed as (

    -- rows the fact can key on; the rest are counted by assert_inventory_daily_excludes_no_units
    select *
    from stock
    where warehouse_id is not null

),

report_days as (

    -- the calendar is the set of days a report exists for — from ALL rows, so a day whose only rows sit on an
    -- unresolved warehouse still counts as a report day; not dim_dates: a missing report must stay a hole
    select distinct snapshot_date
    from stock

),

pairs as (

    -- a sku × warehouse pair enters the calendar on the day the report first lists it and never leaves:
    -- after the last unit is gone the report keeps printing the pair as zeros, and would drop it only with the warehouse
    select
        sku,
        warehouse_id,
        min(snapshot_date)                                          as first_seen_date
    from keyed
    group by sku, warehouse_id

),

grid as (

    select
        d.snapshot_date,
        p.sku,
        p.warehouse_id
    from pairs as p
    inner join report_days as d
        on d.snapshot_date >= p.first_seen_date

),

filled as (

    select
        g.snapshot_date,
        g.sku,
        g.warehouse_id,
        k.reported_sku,
        k.snapshot_date is not null                                 as is_reported,
        coalesce(k.units_available, 0)                              as units_available,
        coalesce(k.units_freeze, 0)                                 as units_freeze,
        coalesce(k.units_fit, 0)                                    as units_fit,
        coalesce(k.units_quarantine, 0)                             as units_quarantine,
        coalesce(k.units_defect, 0)                                 as units_defect,
        coalesce(k.units_expired, 0)                                as units_expired,
        coalesce(k.units_utilization, 0)                            as units_utilization
    from grid as g
    left join keyed as k
        on  k.snapshot_date = g.snapshot_date
        and k.sku           = g.sku
        and k.warehouse_id  = g.warehouse_id

),

final as (

    select
        -- keys
        {{ dbt_utils.generate_surrogate_key(['snapshot_date', 'sku', 'warehouse_id']) }}
                                                                    as inventory_daily_key,
        snapshot_date,                                              -- end of this day, Moscow; demand of day D sees the row of D − 1
        sku,
        warehouse_id,
        reported_sku,                                               -- label as printed (K4); NULL on a filled row

        -- provenance
        is_reported,                                                -- FALSE = the report did not list the pair that day → zeros

        -- units, end of day. Pick one column; never add them up.
        units_available,                                            -- sellable right now
        units_freeze,                                               -- reserved for placed orders
        units_fit,                                                  -- good stock = available + reserved (VALID)
        units_quarantine,
        units_defect,
        units_expired,
        units_utilization,

        -- life of the pair, for reading a zero: NULL last = before the first delivery; NULL next = no unit ever again (so far)
        max(iff(units_fit > 0, snapshot_date, null)) over (
            partition by sku, warehouse_id
            order by snapshot_date
            rows between unbounded preceding and current row
        )                                                           as last_stocked_date,  -- latest day up to and including this one with good stock
        min(iff(units_fit > 0, snapshot_date, null)) over (
            partition by sku, warehouse_id
            order by snapshot_date
            rows between 1 following and unbounded following
        )                                                           as next_stocked_date,  -- first later day with good stock; NULL = none yet

        current_timestamp()                                         as dbt_updated_at
    from filled

)

select * from final
