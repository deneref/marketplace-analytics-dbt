# marts

The models here are written by hand. A few decisions shape all of them.

- A sale happens on the day the buyer receives the order. The day it was placed doesn't count. `delivered_date =
  date(status_updated_at)` for DELIVERED / PARTIALLY_DELIVERED. The status doesn't change on returns, so this is the
  moment of receipt; I checked it against `delivered_date` in the realization report. Undelivered and in-flight
  lines are not sales.
- Returns and cancellations are restated instead of being booked as separate events. There is one row per line, and
  `line_status` and `units_delivered` are overwritten on every run.
- Revenue comes from a reconciliation against the realization report over 20 months
  (`analyses/revenue_reconciliation.sql`). The API docs got it wrong. `revenue = price_buyer_total +
  price_marketplace_total`, which is approximately the report's `total_before_discount`. `price_buyer_total` equals
  `total_after_discount` exactly. Cashback and coupon subsidies are already inside MARKETPLACE.
- Facts carry only keys (`sku`, `warehouse_id`, dates) and no product or warehouse names. In an incremental table a
  name would freeze for rows outside the window. Names and categories live in `dim_products` / `dim_warehouses`,
  and the reporting layer joins them.
- Fees are allocated in proportion to `price_buyer_total` (see `int_order_lines`).

| model | grain | materialization |
|---|---|---|
| `fct_order_lines` | order × line (`order_line_key`) | incremental, 30-day window on `status_updated_at` (all rows when the cost file was reloaded); `delete+insert` by `order_id`, since an order changes as a whole. Holds revenue, allocated fees, `cogs` (unit cost of the version valid on `delivered_date`, from `stg_finance__unit_costs`) and `contribution_margin`. This is the P&L line |
| ~~`fct_order_fees`~~ | | dropped on 09.09. Allocated `fee_*` add up to the order's fees exactly (tests/assert_fees_allocation_sums.sql), so this table would only duplicate `stg_ym__order_fees`. Reconcile against staging, and unpivot in reporting if BI needs `fee_type` as a dimension |
| `fct_sales_daily` | delivered day × sku | table, one `group by` over `fct_order_lines` (incl. `cogs`, `cogs_estimated`, `contribution_margin`). Delivered units only, so this is the margin of what was sold. The cost of unredeemed and returned lines stays in `fct_order_lines` |
| `fct_inventory_daily` | snapshot_date × sku × warehouse_id | table, dense over report days × pairs since first seen (a missing pair is zero, see `is_reported`). `snapshot_date` is the end of the day, Moscow time, so demand on day D reads the row for D − 1. `units_*` buckets don't add up across each other. `last_/next_stocked_date` show where a stock-out sits in the life of a pair. There is no `is_out_of_stock` (BI would average it over warehouses) and no days of cover; ratios are in `rpt_stock_days` |
| `fct_stock_sku_daily` | date_day × sku | table, dense over `dim_dates` from the day after the sku's first report to the day after the latest one. Stock at the start of the day is `fct_inventory_daily` for D − 1, summed over warehouses that aren't for returns. Demand for the day comes from `fct_order_lines` by `ordered_date`, in five buckets that add up. Two gaps are marked: `is_report_missing` (stock is NULL) and `is_demand_known = false` (after the last day of the order feed). `is_stockout_day` means zero stock after `first_stocked_date`. Read by `rpt_stock_sku` and `rpt_stock_days` (v3, 2026-09-17) |
| `fct_inventory_turnover_monthly` | month × sku × macroregion | table, the marketplace's own report as is; I don't compute turnover myself |
| `dim_products` | sku | table: the last-seen catalogue, the parsed SKU code and seeds (types, colours, models) |
| `dim_warehouses` | warehouse_id | table: the marketplace's list plus seed `warehouse_attributes` (turnover cluster; role: fulfillment / oversized / returns). `is_return_warehouse` keeps parcels on their way back out of "in stock" |
| `dim_dates` | date_day | table, `dbt_utils.date_spine` from 2025-01-01 to today + 2 months, with ISO weeks. Dense views (`rpt_stock_days`) join to it, so a missing day shows up as a gap |
| ~~`snap_offers`~~ | sku × version | not built yet: an SCD2 snapshot of the catalogue (`check` strategy, `hard_deletes: new_record`). Until then `dim_products` reads the last-seen catalogue |

There is no `fct_orders`. To get orders, group `fct_order_lines` by `order_id`.

The dashboard reads `models/reporting/rpt_*`, one wide model per page (a fact joined to its dimensions). Ratios are
left to Looker Studio and computed as ratios of sums; `models/reporting/README.md` has the details.
