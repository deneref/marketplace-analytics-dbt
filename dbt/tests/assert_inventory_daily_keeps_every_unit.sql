-- fct_inventory_daily may only ADD rows of zeros to int_stock_daily — never drop or change a unit. Per day and per
-- bucket, the sum over the fact must equal the sum over the intermediate model for the rows the fact can key on
-- (warehouse_id resolved). This is the guard that the zero-fill adds nothing and the join drops nothing. Rows the
-- fact cannot key on are a different failure with its own test: assert_inventory_daily_excludes_no_units.
{{ config(severity='error') }}

{% set buckets = ['units_available', 'units_freeze', 'units_fit', 'units_quarantine', 'units_defect', 'units_expired', 'units_utilization'] %}

with from_fact as (

    select
        snapshot_date,
        {% for b in buckets -%}
        sum({{ b }})                                as {{ b }}{{ "," if not loop.last }}
        {% endfor %}
    from {{ ref('fct_inventory_daily') }}
    group by snapshot_date

),

from_int as (

    select
        snapshot_date,
        {% for b in buckets -%}
        sum({{ b }})                                as {{ b }}{{ "," if not loop.last }}
        {% endfor %}
    from {{ ref('int_stock_daily') }}
    where warehouse_id is not null
    group by snapshot_date

)

select
    coalesce(f.snapshot_date, i.snapshot_date)      as snapshot_date,
    {% for b in buckets -%}
    f.{{ b }}                                       as fact_{{ b }},
    i.{{ b }}                                       as int_{{ b }}{{ "," if not loop.last }}
    {% endfor %}
from from_fact as f
full outer join from_int as i
    on i.snapshot_date = f.snapshot_date
where f.snapshot_date is null
   or i.snapshot_date is null
   {% for b in buckets -%}
   or f.{{ b }} <> i.{{ b }}
   {% endfor %}
