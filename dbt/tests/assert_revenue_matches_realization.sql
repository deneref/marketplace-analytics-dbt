-- Revenue in the fact reconciles to the marketplace's monthly realization report (delivered appendix):
-- price_total for delivered units (before returns — the report lists returns separately) vs
-- total_before_discount, per report month. Observed gap on 2025-01…2026-08: −0.7 % overall, 0…−2.5 % by month
-- (analyses/revenue_reconciliation.sql). Tolerance 3 %; a breach is a heads-up that the marketplace changed
-- how it compensates discounts, or that a load is incomplete — hence warn, not error.
-- Orders are matched one by one, then grouped by the report's month, so month borders do not create noise.
-- The current month is skipped: its report does not exist yet.
{{ config(severity='warn') }}

with realization as (

    select
        order_id,
        min(report_month)                                           as report_month,
        sum(total_before_discount)                                  as realization_total
    from {{ ref('stg_ym__realization_lines') }}
    where event_type = 'delivered'
    group by 1

),

fact as (

    -- delivered share before returns: what the report calls "delivered"
    select
        order_id,
        sum(price_total * div0(units_ordered - units_rejected, units_ordered))    as fact_total
    from {{ ref('fct_order_lines') }}
    where delivered_date is not null
      and not is_test_order
    group by 1

),

monthly as (

    select
        r.report_month,
        count(*)                                                    as orders,
        count_if(f.order_id is null)                                as orders_missing_in_fact,
        sum(r.realization_total)                                    as realization_total,
        sum(f.fact_total)                                           as fact_total,
        div0(sum(f.fact_total) - sum(r.realization_total), sum(r.realization_total)) as gap_share
    from realization as r
    left join fact as f
        on f.order_id = r.order_id
    group by 1

)

select *
from monthly
where abs(gap_share) > 0.03
   or orders_missing_in_fact > 0
