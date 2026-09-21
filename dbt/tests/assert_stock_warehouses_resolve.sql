-- Every warehouse name the stock report prints should be a warehouse GET v2/warehouses lists — otherwise
-- int_stock_daily.warehouse_id is NULL and the rows fall out of any join on the id (fct_inventory_daily, dim_warehouses).
-- Warn, not error: a warehouse closed since is legitimately absent from the current list (stg_ym__warehouses keeps
-- every id ever seen, so in practice only a RENAMED warehouse fails here), and an empty unresolved row breaks nothing.
-- Units on an unresolved name are a different matter: fct_inventory_daily cannot key them and excludes them, and
-- tests/assert_inventory_daily_excludes_no_units.sql turns that into an error. There is no alias seed yet — the fix
-- today is to extend the name match in int_stock_daily. Returns one row per unresolved name with its date range.
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
