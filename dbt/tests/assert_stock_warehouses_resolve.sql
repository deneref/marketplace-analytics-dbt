-- Every warehouse name the stock report prints should be a warehouse GET v2/warehouses lists — otherwise
-- int_stock_daily.warehouse_id is NULL and the rows fall out of any join on the id (fct_inventory_daily, dim_warehouses).
-- Warn, not error: a warehouse closed since (e.g. 'ЛО Парголово' in 2025) is legitimately absent from the current list,
-- and the fix is a row in a name-alias seed, not a broken build. Returns one row per unresolved name with its date range.
{{ config(severity='warn') }}

select
    warehouse_name,
    min(snapshot_date)  as first_seen,
    max(snapshot_date)  as last_seen,
    count(*)            as rows_affected
from {{ ref('int_stock_daily') }}
where warehouse_id is null
group by warehouse_name
order by last_seen desc
