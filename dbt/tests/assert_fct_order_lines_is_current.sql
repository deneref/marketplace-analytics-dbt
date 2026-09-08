-- The incremental window of fct_order_lines must be wide enough: every row in the fact must carry the same
-- state as its parent int_order_lines (a view — always current). A row here = an order that changed outside
-- the lookback window (late fee, late return event) and was NOT rewritten. Fix: widen
-- var fct_order_lines_lookback_days, or run with --full-refresh.
-- Row count equality is checked separately (dbt_utils.equal_rowcount in _marts__models.yml); this test is
-- about VALUES, which a row count cannot see.

select
    f.order_line_key,
    f.order_id,
    f.line_status                                   as fact_line_status,
    i.line_status                                   as current_line_status,
    f.units_delivered                               as fact_units_delivered,
    i.units_delivered                               as current_units_delivered,
    f.fee_total                                     as fact_fee_total,
    i.fee_total                                     as current_fee_total,
    f.status_updated_at                             as fact_status_updated_at,
    i.status_updated_at                             as current_status_updated_at
from {{ ref('fct_order_lines') }} as f
inner join {{ ref('int_order_lines') }} as i
    on i.order_line_key = f.order_line_key
where f.line_status        is distinct from i.line_status
   or f.units_delivered    is distinct from i.units_delivered
   or f.fee_total          is distinct from i.fee_total
   or f.status_updated_at  is distinct from i.status_updated_at
