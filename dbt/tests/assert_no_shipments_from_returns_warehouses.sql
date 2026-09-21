-- rpt_stock_days counts "in stock" over fulfillment warehouses only, on the premise that a returns warehouse
-- (dim_warehouses.is_return_warehouse) never ships to a buyer. If an order line ever ships from one, the premise is
-- wrong and the page understates what buyers could order. Warn; one row per warehouse with the lines concerned.
{{ config(severity='warn') }}

select
    w.warehouse_id,
    w.warehouse_name,
    count(*)                                                        as lines_shipped,
    min(l.ordered_date)                                             as first_order,
    max(l.ordered_date)                                             as last_order
from {{ ref('fct_order_lines') }} as l
inner join {{ ref('dim_warehouses') }} as w
    on w.warehouse_id = l.warehouse_id
where w.is_return_warehouse
  and not coalesce(l.is_test_order, false)
group by w.warehouse_id, w.warehouse_name
