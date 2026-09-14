-- The loss half of rpt_sales_daily must hold exactly the lost units of fct_order_lines: the same units, on the same day
-- and sku, under the same filter. The filter and the two date bases are repeated here on purpose — they are the
-- DEFINITION of a loss row, and a guard that the view did not quietly widen, narrow or re-date it.
--
-- Folded to day × sku, deliberately: the view splits those units further by outcome, by loss_reason and by what the
-- buyer kept instead, and a split is only allowed to REDISTRIBUTE units within a day and sku. Folding proves exactly
-- that — if the classification lost a line, duplicated one, or moved units across dates, the totals stop matching —
-- without re-implementing the classification in its own test, which would prove nothing.
--
-- Units only, and both kinds of them (all lost units, and the defective subset). Money is NOT compared here: the rule
-- that decides which half a line's fees belong to cannot be restated in a test without copying it, and a copied rule
-- passes its own bugs. assert_rpt_sales_daily_fees_counted_once.sql checks the money from the other side instead —
-- every fee charged on a line the page shows appears in the page exactly once.
--
-- Every refused or returned unit is in scope, including the units of a line that kept the rest: miss those and a sku's
-- unredeemed rate is understated, which is the number the brand reads by product type.
-- Failing rows name the day and the sku; a row on one side only means the date basis diverged.

{{ config(severity='error') }}

with rpt as (

    select
        event_date,
        sku,
        sum(units_lost)                                     as units_lost,
        sum(units_lost_defect)                              as units_lost_defect
    from {{ ref('rpt_sales_daily') }}
    where outcome <> 'delivered'
    group by 1, 2

),

lines as (

    -- the same two branches as the view, each dated by its own event: a line with both kinds of loss (none in the
    -- history as of 2026-09-14) contributes to two dates, and dating both from the refusal is the mistake this catches
    select
        coalesce(rejected_date, {{ moscow_date('status_updated_at') }})  as event_date,
        sku,
        units_rejected                                      as units_lost,
        units_rejected_defect                               as units_lost_defect
    from {{ ref('fct_order_lines') }}
    where units_rejected > 0
      and not coalesce(is_test_order, false)

    union all

    select
        coalesce(returned_date, {{ moscow_date('status_updated_at') }})  as event_date,
        sku,
        units_returned                                      as units_lost,
        units_returned_defect                               as units_lost_defect
    from {{ ref('fct_order_lines') }}
    where units_returned > 0
      and not coalesce(is_test_order, false)

),

lines_daily as (

    select
        event_date,
        sku,
        sum(units_lost)                                     as units_lost,
        sum(units_lost_defect)                              as units_lost_defect
    from lines
    group by 1, 2

),

compared as (

    select
        coalesce(r.event_date, l.event_date)                        as event_date,
        coalesce(r.sku, l.sku)                                      as sku,
        r.sku is null                                               as missing_in_rpt,
        l.sku is null                                               as extra_in_rpt,
        r.units_lost        is distinct from l.units_lost            as d_units_lost,
        r.units_lost_defect is distinct from l.units_lost_defect     as d_units_defect
    from rpt as r
    full outer join lines_daily as l
        on  l.event_date is not distinct from r.event_date
        and l.sku = r.sku

)

select *
from compared
where missing_in_rpt
   or extra_in_rpt
   or d_units_lost
   or d_units_defect
