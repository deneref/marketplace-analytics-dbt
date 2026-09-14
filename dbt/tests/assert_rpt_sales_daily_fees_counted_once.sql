-- Every fee the marketplace charged on a line the page shows must appear on the page EXACTLY ONCE, and under the right
-- sku.
--
-- This is the one check of the money rule that does not restate it. The view decides, per line, whether its fees sit in
-- the sales half or in the loss half: fees are not scaled by delivery, so a line already counted as a sale pays its full
-- fees there and its loss row carries units with zero money. A reconciliation that repeated that condition would pass
-- any bug copied into both places. So this test ignores the halves entirely: per sku, it sums the fees of the whole view
-- and compares them with the fees of every line the view is supposed to show — a line that was delivered and kept
-- something (it is in fct_sales_daily) or a line that lost units (it is in the loss half), each line once, whichever
-- half it landed in.
--
-- Per sku rather than in total, for two reasons: a grand total lets a fee counted twice on one line cancel a fee lost on
-- another, and a failing total names nothing to look at. Not per DAY, because the two halves date the same line
-- differently by design (receipt against the parcel's return) — the day is pinned by
-- assert_rpt_sales_daily_losses_match_lines.sql, which reconciles the UNITS per day and sku.
--
-- What it catches: a line whose fees are counted twice (the money condition widened past fct_sales_daily's filter), a
-- line whose fees are counted nowhere (it narrowed — the bug this test was written after: `units_delivered = 0` instead
-- of the complement of the sales filter drops the fees of a line whose units_delivered is an unreceived FORECAST; no
-- line in the history is in that state, so no money was ever actually lost, and this is what keeps it that way), and
-- fees attached to the wrong sku.
-- What it cannot catch: fees on the wrong DAY within a sku, and a line that is neither a sale nor a loss and is
-- therefore shown nowhere by design (160 lines / 4 ₽ as of 2026-09-14 — orders cancelled before shipment and orders
-- still in flight; the marketplace charges almost nothing for a parcel it never shipped).
--
-- fee_boost is checked next to fee_total because it is a part of it, not an addition, and a wrong sign or a double count
-- there changes the one cost the brand steers day to day.

{{ config(severity='error') }}

with rpt as (

    select
        sku,
        coalesce(sum(fee_total), 0)                         as fee_total,
        coalesce(sum(fee_boost), 0)                         as fee_boost
    from {{ ref('rpt_sales_daily') }}
    group by 1

),

lines as (

    select
        sku,
        coalesce(sum(fee_total), 0)                         as fee_total,
        coalesce(sum(fee_boost), 0)                         as fee_boost
    from {{ ref('fct_order_lines') }}
    where not coalesce(is_test_order, false)
      and (
            -- shown as a sale (fct_sales_daily's filter, verbatim)
            (delivered_date is not null and units_delivered > 0)
            -- or shown as a loss
            or units_rejected + units_returned > 0
          )
    group by 1

),

compared as (

    select
        coalesce(r.sku, l.sku)                                      as sku,
        r.sku is null                                               as missing_in_rpt,
        l.sku is null                                               as extra_in_rpt,
        r.fee_total is distinct from l.fee_total                     as d_fee_total,
        r.fee_boost is distinct from l.fee_boost                     as d_fee_boost,
        r.fee_total                                                 as fee_total_in_rpt,
        l.fee_total                                                 as fee_total_in_lines,
        r.fee_boost                                                 as fee_boost_in_rpt,
        l.fee_boost                                                 as fee_boost_in_lines
    from rpt as r
    full outer join lines as l
        on l.sku = r.sku

)

select *
from compared
where missing_in_rpt
   or extra_in_rpt
   or d_fee_total
   or d_fee_boost
