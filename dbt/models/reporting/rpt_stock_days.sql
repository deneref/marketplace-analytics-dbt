-- The history pages: one row per day × sku for the availability heatmap, the "sales vs stock" series and the size
-- page. Thin on purpose: the stock and demand of the day from fct_stock_sku_daily, product attributes, the size
-- run of the colourway that morning, and ONE sku-level rate (velocity_recent from rpt_stock_sku) so that the loss of a
-- stockout day can be SUMmed in BI over any period. Everything about "now" lives in rpt_stock_sku (one row per
-- sku); nothing here is constant per sku except velocity_recent, and no column is NULL by design outside holes.
-- Grain: date_day × sku, ~31 k rows. View: a join and one window over the mart, nothing to cache.

{{ config(materialized='view') }}

with days as (

    select *
    from {{ ref('fct_stock_sku_daily') }}

),

products as (

    select
        *,
        count(distinct size) over (partition by model_colour_code)  as mcc_sizes_current_count  -- sizes the colourway has TODAY
    from {{ ref('dim_products') }}

),

sku_now as (

    select sku, velocity_recent
    from {{ ref('rpt_stock_sku') }}

),

size_grid as (

    -- the colourway's size run that morning: sizes (not skus — a re-created card is a second sku of one size).
    -- NULL on a hole, like every stock column
    select
        d.date_day,
        p.model_colour_code,
        count(distinct p.size)                                      as sizes_total_count,
        iff(count_if(d.is_in_stock is null) > 0, null,
            count(distinct iff(d.is_in_stock, p.size, null)))       as sizes_in_stock_count
    from days as d
    inner join products as p
        on p.sku = d.sku
    where p.model_colour_code is not null
    group by d.date_day, p.model_colour_code

),

final as (

    select
        d.stock_day_key,
        d.date_day,
        d.sku,

        p.product_name,
        p.product_type_code,
        p.product_type,
        p.model_code,
        p.model_name,
        p.model_colour_code,
        p.colour_name,
        p.size,
        p.size_order,
        p.collection,
        p.lifecycle_status,

        -- stock at the start of the day; NULL on a day without a report
        d.is_report_missing,
        d.units_available_sod,
        d.units_fit_sod,
        d.units_freeze_sod,
        d.units_unsellable_sod,
        d.units_fit_at_returns_sod,
        d.is_in_stock,
        d.is_stockout_day,                                          -- zero after the first delivery; NULL on a hole

        -- the colourway's size run that morning (sizes listed on the page that day: before XL's card existed, "full" = M + L)
        z.sizes_total_count,
        z.sizes_in_stock_count,
        p.mcc_sizes_current_count,
        z.sizes_in_stock_count = z.sizes_total_count                as is_full_size_run,     -- every size listed THAT DAY in stock
        z.sizes_in_stock_count = p.mcc_sizes_current_count          as is_full_current_run,  -- every size the colourway has TODAY in stock: the day a size share is a size share
        z.sizes_total_count > 1                                     as is_sized,             -- for sizeless items is_full_size_run ≡ is_in_stock: the size page filters on this
        case
            when d.is_report_missing then 'no_report'
            when d.is_in_stock       then 'in_stock'
            when d.is_stockout_day   then 'stockout'
            else                          'not_delivered'
        end                                                         as stock_state,          -- one dimension for the heatmap's colour

        -- demand during the day, by the day it was placed
        d.is_demand_known,                                          -- FALSE after the latest order data: zero here is "unknown", not "none"
        d.units_ordered,
        d.units_kept,
        d.units_unredeemed,
        d.units_returned,
        d.units_in_flight,
        d.units_cancelled,
        d.sku_orders_count,                                         -- NOT additive across skus

        -- additive 0/1 counters: the Snowflake connector hands Looker Studio a boolean it cannot SUM, and every
        -- ratio on the history pages is SUM(x) / SUM(y) over the period the reader picks
        iff(not d.is_report_missing, 1, 0)                          as report_day_n,
        iff(coalesce(d.is_in_stock, false), 1, 0)                   as in_stock_day_n,
        iff(coalesce(d.is_stockout_day, false), 1, 0)               as stockout_day_n,
        iff(coalesce(d.is_in_stock, false) and d.is_demand_known, 1, 0)
                                                                    as evidence_day_n,       -- a day that counts for a velocity
        iff(coalesce(d.is_in_stock, false) and d.is_demand_known, d.units_ordered, 0)
                                                                    as evidence_units_ordered,
        -- full-run counters use is_full_current_run: before XL's card existed, "M + L in stock" is not a day XL could have sold
        iff(coalesce(z.sizes_in_stock_count = p.mcc_sizes_current_count, false) and d.is_demand_known, 1, 0)
                                                                    as full_run_evidence_day_n,
        iff(coalesce(z.sizes_in_stock_count = p.mcc_sizes_current_count, false) and d.is_demand_known, d.units_ordered, 0)
                                                                    as full_run_units_ordered,
        sum(iff(coalesce(z.sizes_in_stock_count = p.mcc_sizes_current_count, false) and d.is_demand_known, d.units_ordered, 0))
            over (partition by p.model_colour_code, d.date_day)     as mcc_full_run_units_ordered,  -- the colourway's orders that day; NOT additive across sizes — size share = SUM(full_run_units_ordered) / SUM(this) with the mcc × size grouping

        -- the loss of the day at the sku's CURRENT rate (velocity_recent): SUM() over any period in BI. NULL on a
        -- hole, 0 in stock. For days older than 180 days it prices the past at today's rate — read as an index
        s.velocity_recent,
        iff(d.is_stockout_day, s.velocity_recent, iff(d.is_report_missing, null, 0))
                                                                    as expected_lost_units,

        d.latest_snapshot_date,
        d.latest_demand_date,
        d.is_latest_day
    from days as d
    left join products as p
        on p.sku = d.sku
    left join sku_now as s
        on s.sku = d.sku
    left join size_grid as z
        on  z.date_day = d.date_day
        and z.model_colour_code = p.model_colour_code

)

select * from final
