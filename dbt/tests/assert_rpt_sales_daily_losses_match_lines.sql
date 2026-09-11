-- The loss half of rpt_sales_daily (outcome = unredeemed / returned) must be exactly the fully-returned lines of
-- fct_order_lines, aggregated: same units that came back, same fees, same margin — grouped by the same day and
-- sku, under the same filter. The filter is repeated here on purpose: it is the definition of a loss row, and a
-- guard that the view did not quietly widen it (say, to partially delivered lines, which already sit inside
-- the delivered rows with their full fees and would then be counted twice).
-- Failing rows name the day, sku and outcome; a row on one side only means the date basis diverged.

{{ config(severity='error') }}

with rpt as (

    select event_date, sku, outcome, units_lost, fee_total, fee_boost, contribution_margin
    from {{ ref('rpt_sales_daily') }}
    where outcome in ('unredeemed', 'returned')

),

lines as (

    select
        coalesce(
            iff(line_status = 'returned', returned_date, rejected_date),
            {{ moscow_date('status_updated_at') }}
        )                                       as event_date,
        sku,
        line_status                             as outcome,
        sum(units_rejected + units_returned)    as units_lost,
        sum(fee_total)                          as fee_total,
        sum(fee_boost)                          as fee_boost,
        sum(contribution_margin)                as contribution_margin
    from {{ ref('fct_order_lines') }}
    where line_status in ('unredeemed', 'returned')
      and not coalesce(is_test_order, false)
    group by 1, 2, 3

),

compared as (

    select
        coalesce(r.event_date, l.event_date)     as event_date,
        coalesce(r.sku, l.sku)                   as sku,
        coalesce(r.outcome, l.outcome)           as outcome,
        r.sku is null                            as missing_in_rpt,
        l.sku is null                            as extra_in_rpt,
        r.units_lost          is distinct from l.units_lost          as d_units_lost,
        r.fee_total           is distinct from l.fee_total           as d_fee_total,
        r.fee_boost           is distinct from l.fee_boost           as d_fee_boost,
        r.contribution_margin is distinct from l.contribution_margin as d_margin
    from rpt as r
    full outer join lines as l
        on  l.event_date is not distinct from r.event_date
        and l.sku = r.sku
        and l.outcome = r.outcome

)

select *
from compared
where missing_in_rpt
   or extra_in_rpt
   or d_units_lost
   or d_fee_total
   or d_fee_boost
   or d_margin
