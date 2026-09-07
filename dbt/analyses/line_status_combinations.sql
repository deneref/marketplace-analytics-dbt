-- Which combinations of order status × line events actually occur, and what int_order_lines makes of them.
-- Run with `dbt compile` and paste into Snowflake (or `dbt show --select line_status_combinations`).
-- Every row should have an obviously right line_status; a row that looks wrong means the case in
-- int_order_lines needs another branch.

select
    order_status,
    is_final,
    units_rejected > 0                                  as has_rejected,
    units_returned > 0                                  as has_returned,
    units_rejected + units_returned >= units_ordered    as all_units_back,
    line_status,
    count(*)                                            as lines,
    count(distinct order_id)                            as orders
from {{ ref('int_order_lines') }}
group by all
order by order_status, has_rejected, has_returned, all_units_back
