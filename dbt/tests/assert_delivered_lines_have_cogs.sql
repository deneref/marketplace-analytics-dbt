-- Every delivered line must find exactly one cost version by sku and delivered_date.
-- Zero versions → margin silently equals revenue for that line; two → double cost.
-- warn, not error: a new SKU listed before its cost row is added should not block the build.
{{ config(severity='warn') }}

with lines as (

    select order_line_key, sku, delivered_date, units_delivered
    from {{ ref('fct_order_lines') }}
    where units_delivered > 0

),

matched as (

    select
        l.order_line_key,
        l.sku,
        l.delivered_date,
        count(c.sku_cost_key) as cost_versions
    from lines as l
    left join {{ ref('stg_cogs__by_sku') }} as c
        on  c.sku = l.sku
        and l.delivered_date >= c.valid_from
        and l.delivered_date <= coalesce(c.valid_to, '9999-12-31'::date)
    group by 1, 2, 3

)

select *
from matched
where cost_versions <> 1
