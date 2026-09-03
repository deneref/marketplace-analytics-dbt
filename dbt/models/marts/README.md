# marts — written by hand, on purpose

Spec: `06_пет-проект/02_модель_данных.md` (section 3). Minimum set:

- `fct_order_items` — incremental, `unique_key='order_item_key'`, `incremental_strategy='merge'`, 14-day lookback window
- `fct_sales_daily` — day × SKU: units, gross/net revenue, marketplace fees, refunds, COGS, contribution margin
- `fct_inventory_turnover_monthly` — month × SKU: own turnover from orders + stock snapshots, benchmarked against the marketplace report
- `dim_products`

Public views live in `models/reporting/rpt_*` and expose only indexed metrics (base month = var `base_month`).
