-- kept_instead answers "what did the buyer keep instead of this item", and the answer is split between two layers on
-- purpose: WHETHER the order kept anything is int_order_lines' is_order_partly_kept (the same flag that makes the reason
-- 'refused_at_handover'), WHICH thing they kept is derived in the view, because only there are dim_products' model and
-- size available. This test is the seam between the two, and it exists because the seam has already leaked once: a guard
-- written with coalesce() collapsed to a single branch and silently turned 22 of the 55 labelled lines into nulls, which
-- no other test could see — the units were still there, only the label was gone.
--
-- The claim: per day and sku, the refused units of every line whose order kept something carry a label. Stated in units
-- rather than in lines so it can be read against the page's own measure, and grouped rather than totalled so a failure
-- names something to look at (the view has no line key to compare on — it is already aggregated).
-- Sums are enough to prove full coverage, not only to compare magnitudes: a label REQUIRES the upstream flag (first
-- branch of the CASE), so the labelled units are a subset of the flagged ones and equality of the sums is equality of
-- the sets — a missing label cannot be masked by a spurious one.
-- What it does not check: whether the label is the RIGHT one of the four. That classification is restated nowhere, by
-- design, so a wrong label is caught by reading the data.
--
-- A failure means one of two things: the null-collapse above came back, or the two definitions of "kept something"
-- drifted apart. They can: int counts units_delivered without asking whether the order was ever received, so an
-- in-flight order (units_delivered is a FORECAST there) or a fully unredeemed order with a partly refused line would be
-- partly kept upstream and have nothing kept here. Neither exists in the data as of 2026-09-14 (55 lines both ways,
-- zero disagreement), which is why this is an error and not a warning: today it holds exactly, and the day it stops the
-- definitions need reconciling, not a looser test.

{{ config(severity='error') }}

with rpt as (

    select
        event_date,
        sku,
        coalesce(sum(iff(kept_instead is not null, units_lost, 0)), 0)   as units_labelled
    from {{ ref('rpt_sales_daily') }}
    where outcome = 'unredeemed'
    group by 1, 2

),

lines as (

    -- the loss half's own date basis for refused units, repeated as a definition guard
    select
        coalesce(rejected_date, {{ moscow_date('status_updated_at') }})  as event_date,
        sku,
        coalesce(sum(units_rejected), 0)                                as units_partly_kept
    from {{ ref('fct_order_lines') }}
    where units_rejected > 0
      and not coalesce(is_test_order, false)
      and coalesce(is_order_partly_kept, false)
    group by 1, 2

),

compared as (

    select
        coalesce(r.event_date, l.event_date)                as event_date,
        coalesce(r.sku, l.sku)                              as sku,
        coalesce(r.units_labelled, 0)                       as units_labelled,
        coalesce(l.units_partly_kept, 0)                    as units_partly_kept
    from rpt as r
    full outer join lines as l
        on  l.event_date is not distinct from r.event_date
        and l.sku = r.sku

)

select *
from compared
where units_labelled is distinct from units_partly_kept
