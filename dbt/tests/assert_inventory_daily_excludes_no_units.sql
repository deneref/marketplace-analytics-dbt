-- fct_inventory_daily keys on warehouse_id and therefore drops int_stock_daily rows whose warehouse name did not
-- resolve to an id. A dropped row of zeros changes nothing and is only listed by assert_stock_warehouses_resolve
-- (warn); a dropped row WITH units is stock the fact no longer sees — this test names it and fails the build.
-- The fix is the name match in int_stock_daily (there is no alias seed yet).
{{ config(severity='error') }}

select
    warehouse_name,
    snapshot_date,
    sku,
    units_fit,
    units_available,
    units_freeze,
    units_quarantine,
    units_defect,
    units_expired,
    units_utilization
from {{ ref('int_stock_daily') }}
where warehouse_id is null
  and units_fit + units_available + units_freeze + units_quarantine + units_defect + units_expired + units_utilization > 0
order by snapshot_date desc
