-- Unredeemed units whose reason is missing, once the newer source has had time to catch up.
-- Two ways a loss row ends up without a reason, and this test is the only thing that keeps them from growing quietly:
--   * 'not_in_source' — the order has not been pulled from the business-orders endpoint. That endpoint is loaded by
--     hand today (no scheduled catch-up), and orders_stats is refreshed weekly, so the gap opens by itself;
--   * 'unknown' — the order is there, but nothing in it explains the cancellation.
-- Both are honest values, not bugs; what is not acceptable is a growing share of them, because every such line is an
-- unredeemed parcel counted in the money and absent from the reason mix — the mix would drift without any number
-- looking wrong.
-- The grace period is 7 days after the last status change: fresher orders may legitimately be missing from a source
-- that is pulled in batches. Warn, because a stale pull is a to-do, not a broken build — promote to error once the
-- daily catch-up runs.

{{ config(severity='warn') }}

select
    order_id,
    order_line_key,
    sku,
    line_status,
    loss_reason,
    units_rejected,
    status_updated_at
from {{ ref('int_order_lines') }}
where loss_reason in ('unknown', 'not_in_source')
  and not coalesce(is_test_order, false)
  and status_updated_at < dateadd(day, -7, current_timestamp())
