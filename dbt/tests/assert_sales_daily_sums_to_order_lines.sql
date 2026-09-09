-- The aggregate is derived from the fact, never the other way round: every measure of fct_sales_daily must equal the
-- sum of the same column over fct_order_lines under the sales filter (received, units kept, not a test order).
-- The filter is repeated here on purpose — this test is the guard that the definition of "a sale" did not drift
-- between the two models. A row = a day × sku where some measure differs (or exists on one side only).
{{ config(severity='error') }}

{% set measures = [
    'units_delivered', 'revenue',
    'fee_commission', 'fee_delivery', 'fee_boost', 'fee_payment_transfer', 'fee_agency',
    'fee_crossregional', 'fee_return_processing', 'fee_loyalty', 'fee_total', 'bid_fee',
    'cogs', 'cogs_estimated', 'contribution_margin',
] %}

with from_lines as (

    select
        delivered_date,
        sku,
        count(distinct order_id)                    as sku_orders_count,
        {% for m in measures -%}
        sum({{ m }})                                as {{ m }}{{ "," if not loop.last }}
        {% endfor %}
    from {{ ref('fct_order_lines') }}
    where delivered_date is not null
      and units_delivered > 0
      and not coalesce(is_test_order, false)
    group by 1, 2

),

from_daily as (

    select
        delivered_date,
        sku,
        sku_orders_count,
        {% for m in measures -%}
        {{ m }}{{ "," if not loop.last }}
        {% endfor %}
    from {{ ref('fct_sales_daily') }}

)

select
    coalesce(d.delivered_date, l.delivered_date)    as delivered_date,
    coalesce(d.sku, l.sku)                          as sku,
    d.sku_orders_count                              as daily_sku_orders_count,
    l.sku_orders_count                              as lines_sku_orders_count,
    {% for m in measures -%}
    d.{{ m }}                                       as daily_{{ m }},
    l.{{ m }}                                       as lines_{{ m }}{{ "," if not loop.last }}
    {% endfor %}
from from_daily as d
full outer join from_lines as l
    on  l.delivered_date = d.delivered_date
    and l.sku            = d.sku
where d.sku is null
   or l.sku is null
   or d.sku_orders_count is distinct from l.sku_orders_count
   {% for m in measures -%}
   or d.{{ m }} is distinct from l.{{ m }}
   {% endfor %}
