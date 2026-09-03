-- Reconciliation: own turnover (orders + stock snapshots) vs the marketplace's turnover report, per SKU, ±10 %.
-- Rows returned = SKUs outside tolerance = test failure. Document the systematic differences in README.
{{ config(severity='warn', enabled=false) }}

select
    own.sku,
    own.turnover_days           as own_turnover_days,
    mp.turnover_days            as marketplace_turnover_days
from {{ ref('fct_inventory_turnover_monthly') }} own
join {{ ref('stg_ym__turnover_report') }} mp
  on mp.sku = own.sku
 and date_trunc('month', mp.report_date) = own.month
where abs(own.turnover_days - mp.turnover_days) > 0.10 * mp.turnover_days
