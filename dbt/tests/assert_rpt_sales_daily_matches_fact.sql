-- The delivered half of the reporting view must be the fact plus columns: same rows, same money, nothing lost
-- or invented by the join. The view's key is event_date + sku + outcome + loss_reason + kept_instead, so the fact side
-- rebuilds it with the literal 'delivered' and two nulls — a delivered row has nothing to explain and nothing kept
-- instead (generate_surrogate_key substitutes its own placeholder for a null, identically on both sides). A full outer join on that key catches a row only in the fact (an inner join or a filter
-- crept in), a delivered row only in the view (the union invented one), and a row on both sides whose measures
-- moved (someone recomputed something here instead of passing it through). Loss rows are out of scope here —
-- assert_rpt_sales_daily_losses_match_lines.sql reconciles them to fct_order_lines.
-- It does NOT catch a fan-out: duplicate keys in the view each match the single fact row with equal measures
-- and every delta stays zero — unique(sales_daily_key) in the yml is the guard for that.
-- Comparison is `is distinct from`, not a coalesced subtraction: null and zero are different answers, and a
-- coalesce introduced in the view would otherwise pass unnoticed. Failing rows name the offending key.

{{ config(severity='error') }}

with rpt as (

    select * from {{ ref('rpt_sales_daily') }}
    where outcome = 'delivered'

),

fct as (

    -- the fact's own key (delivered_date + sku) is replaced by the view's (event_date + sku + outcome)
    select
        {{ dbt_utils.generate_surrogate_key(['delivered_date', 'sku', "'delivered'",
                                             'cast(null as varchar)', 'cast(null as varchar)']) }} as sales_daily_key,
        * exclude (sales_daily_key)
    from {{ ref('fct_sales_daily') }}

),

compared as (

    select
        coalesce(r.sales_daily_key, f.sales_daily_key)   as sales_daily_key,
        r.sales_daily_key is null                        as missing_in_rpt,
        f.sales_daily_key is null                        as extra_in_rpt,
        r.units_delivered     is distinct from f.units_delivered     as d_units,
        r.sku_orders_count    is distinct from f.sku_orders_count    as d_orders,
        r.lines_count         is distinct from f.lines_count         as d_lines,
        r.revenue             is distinct from f.revenue             as d_revenue,
        r.fee_total           is distinct from f.fee_total           as d_fee_total,
        r.fee_boost           is distinct from f.fee_boost           as d_fee_boost,
        r.cogs                is distinct from f.cogs                as d_cogs,
        r.cogs_estimated      is distinct from f.cogs_estimated      as d_cogs_estimated,
        r.contribution_margin is distinct from f.contribution_margin as d_margin

    from rpt as r
    full outer join fct as f
        on f.sales_daily_key = r.sales_daily_key

)

select *
from compared
where missing_in_rpt
   or extra_in_rpt
   or d_units
   or d_orders
   or d_lines
   or d_revenue
   or d_fee_total
   or d_fee_boost
   or d_cogs
   or d_cogs_estimated
   or d_margin
