-- The incremental window of fct_order_lines must be wide enough: every row in the fact must carry the same
-- state as its parent int_order_lines (a view — always current). A row here = an order that changed outside
-- the lookback window (late fee, late return event) and was NOT rewritten. Fix: widen
-- var fct_order_lines_lookback_days, or run with --full-refresh.
-- Row count equality is checked separately (dbt_utils.equal_rowcount in _marts__models.yml); this test is
-- about VALUES, which a row count cannot see.
-- The same for cost: a reloaded cost file must reprice every line — the fact's unit_cost must equal the version
-- currently valid on the line's delivered_date (the incremental filter widens to all rows on a cost reload).

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
    i.status_updated_at                             as current_status_updated_at,
    f.unit_cost                                     as fact_unit_cost,
    c.unit_cost                                     as current_unit_cost
from {{ ref('fct_order_lines') }} as f
inner join {{ ref('int_order_lines') }} as i
    on i.order_line_key = f.order_line_key
left join {{ ref('stg_finance__unit_costs') }} as c
    on  c.sku = f.sku
    and f.delivered_date >= c.valid_from
    and f.delivered_date <= coalesce(c.valid_to, '9999-12-31'::date)
where f.line_status        is distinct from i.line_status
   or f.units_delivered    is distinct from i.units_delivered
   or f.fee_total          is distinct from i.fee_total
   or f.status_updated_at  is distinct from i.status_updated_at
   or f.unit_cost          is distinct from c.unit_cost
