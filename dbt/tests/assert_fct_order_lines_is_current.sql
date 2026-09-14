-- Every row of fct_order_lines must carry the same state as its parent int_order_lines (a view — always current).
-- A row here means the fact is stale, and `diagnosis` says in which way, because the fix differs:
--   missing_in_fact  — the line exists in the view and not in the table: no predicate selected it (an old order that
--                      only now appeared in the source). Fix: --full-refresh;
--   missing_in_int   — the opposite: the table keeps a line the view no longer produces. Fix: --full-refresh;
--   stale_reason     — loss_reason diverged: either the business-orders load was not picked up, or the reason tree /
--                      var pickup_storage_days changed, which reloads nothing and no predicate can notice.
--                      Fix: --full-refresh. Do NOT widen the lookback window, it has nothing to do with this;
--   stale_cost       — a reloaded cost file did not reprice the line. Fix: --full-refresh;
--   stale_status     — the order changed outside the lookback window (late fee, late return event).
--                      Fix: widen var fct_order_lines_lookback_days, or --full-refresh.
-- full outer join, not inner: a line present on one side only is exactly the class an inner join cannot see, and
-- dbt_utils.equal_rowcount does not see it either — one lost and one extra row cancel out in a count.
-- Row count equality is checked separately (dbt_utils.equal_rowcount in _marts__models.yml); this test is
-- about VALUES, which a row count cannot see.
-- The same for cost: a reloaded cost file must reprice every line — the fact's unit_cost must equal the version
-- currently valid on the line's delivered_date (the incremental filter widens to all rows on a cost reload).
-- And the same for the loss reason, which is the case the window cannot cover on its own: it comes from a second
-- source loaded on its own schedule, and it also changes when the reason tree or var pickup_storage_days changes —
-- and THAT reloads nothing at all, so no incremental predicate can notice it. This comparison is the only thing that
-- does. A row here after a threshold change is expected, and the fix is the same: --full-refresh.

select
    coalesce(f.order_line_key, i.order_line_key)    as order_line_key,
    coalesce(f.order_id, i.order_id)                as order_id,
    case
        when f.order_line_key is null                                       then 'missing_in_fact'
        when i.order_line_key is null                                       then 'missing_in_int'
        when f.loss_reason is distinct from i.loss_reason
             or f.loss_reason_is_inferred is distinct from i.loss_reason_is_inferred then 'stale_reason'
        when f.unit_cost is distinct from c.unit_cost                        then 'stale_cost'
        else                                                                     'stale_status'
    end                                             as diagnosis,
    f.line_status                                   as fact_line_status,
    i.line_status                                   as current_line_status,
    f.units_delivered                               as fact_units_delivered,
    i.units_delivered                               as current_units_delivered,
    f.fee_total                                     as fact_fee_total,
    i.fee_total                                     as current_fee_total,
    f.status_updated_at                             as fact_status_updated_at,
    i.status_updated_at                             as current_status_updated_at,
    f.unit_cost                                     as fact_unit_cost,
    c.unit_cost                                     as current_unit_cost,
    f.loss_reason                                   as fact_loss_reason,
    i.loss_reason                                   as current_loss_reason,
    f.loss_reason_is_inferred                       as fact_loss_reason_is_inferred,
    i.loss_reason_is_inferred                       as current_loss_reason_is_inferred
from {{ ref('fct_order_lines') }} as f
full outer join {{ ref('int_order_lines') }} as i
    on i.order_line_key = f.order_line_key
left join {{ ref('stg_finance__unit_costs') }} as c
    on  c.sku = f.sku
    and f.delivered_date >= c.valid_from
    and f.delivered_date <= coalesce(c.valid_to, '9999-12-31'::date)
where f.order_line_key is null
   or i.order_line_key is null
   or f.line_status        is distinct from i.line_status
   or f.units_delivered    is distinct from i.units_delivered
   or f.fee_total          is distinct from i.fee_total
   or f.status_updated_at  is distinct from i.status_updated_at
   or f.unit_cost          is distinct from c.unit_cost
   or f.loss_reason        is distinct from i.loss_reason
   or f.loss_reason_is_inferred is distinct from i.loss_reason_is_inferred
