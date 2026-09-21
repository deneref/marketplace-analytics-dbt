# marts — written by hand, on purpose
Decisions that shape every model here (2026-09-08):

- **A sale happens on the day the buyer receives the order**, not the day it was placed. `delivered_date =
  date(status_updated_at)` for DELIVERED / PARTIALLY_DELIVERED (the status does not move on returns, so it is the
  moment of receipt; checked against the realization report's `delivered_date`). Undelivered and in-flight lines
  are not sales.
- **Returns and cancellations are restated**, not booked as events: one row per line, `line_status` and
  `units_delivered` overwritten on every run.
- **Revenue is defined by reconciliation**, not by the API docs (`analyses/revenue_reconciliation.sql`, 20 months):
  `revenue = price_buyer_total + price_marketplace_total` ≈ the realization report's `total_before_discount`
  (−0.7 % overall, 0…−2.5 % by month). `price_buyer_total` equals `total_after_discount` exactly; cashback and
  coupon subsidies are inside MARKETPLACE, not on top of it. Reconciliation test: 3 % per month, `warn`.
- **Facts carry keys only** (`sku`, `warehouse_id`, dates) — no product or warehouse names: in an incremental table
  they would freeze for rows outside the window. Names and categories live in `dim_products` / `dim_warehouses`;
  the reporting layer joins them.
- Allocation base stays `price_buyer_total` (see `int_order_lines`).

`fct_order_lines` is the worked example (model + `_marts__models.yml` + two singular tests); the other marts follow
its shape: header comment with grain and decisions → `config` → one CTE per input → `final` with columns grouped
by role (keys, dates, attributes, units, money) → yml with a description that states the grain and the money
definitions, generic tests on the grain key and on arithmetic, a singular test for anything that compares two
models.

Minimum set:

| model | grain | materialization |
|---|---|---|
| `fct_order_lines` | order × line (`order_line_key`) | incremental, 30-day window on `status_updated_at` (all rows when the cost file was reloaded); `delete+insert` by `order_id` (the unit of change is the order). Carries revenue, allocated fees, `cogs` (unit cost of the version valid on `delivered_date`, from `stg_finance__unit_costs`) and `contribution_margin` — the P&L line |
| ~~`fct_order_fees`~~ | — | dropped (09.09): allocated `fee_*` sum to the order's fees exactly (tests/assert_fees_allocation_sums.sql), so it would duplicate `stg_ym__order_fees`; reconcile against staging, unpivot in reporting if BI needs `fee_type` as a dimension |
| `fct_sales_daily` | delivered day × sku | table, one `group by` over `fct_order_lines` (incl. `cogs`, `cogs_estimated`, `contribution_margin`); only delivered units — the margin of what was SOLD; the cost of unredeemed / returned lines stays in `fct_order_lines` |
| `fct_inventory_daily` | snapshot_date × sku × warehouse_id | table — dense over report days × pairs since first seen (absence = zero, `is_reported`); `snapshot_date` = END of day Moscow, demand of day D reads the row of D − 1; `units_*` buckets non-additive; `last_/next_stocked_date` frame a stock-out inside the life of a pair. No `is_out_of_stock` (BI would average it over warehouses), no days of cover — ratios live in `rpt_stock_days` |
| `fct_stock_sku_daily` | date_day × sku | table — dense over `dim_dates` from the day after the sku's first report to the day after the latest; stock at START of day = `fct_inventory_daily` of D − 1 summed over non-returns warehouses; demand of the day from `fct_order_lines` by `ordered_date` in five buckets that add up; two explicit holes: `is_report_missing` (stock NULL) and `is_demand_known = false` (after the order feed's last day). `is_stockout_day` = zero after `first_stocked_date`. Read by `rpt_stock_sku` and `rpt_stock_days` (v3, 2026-09-17) |
| `fct_inventory_turnover_monthly` | month × sku × macroregion | table — the marketplace's report as is, no own turnover |
| `dim_products` | sku | table — last-seen catalogue + parsed SKU code + seeds (types, colours, models) |
| `dim_warehouses` | warehouse_id | table — marketplace list + seed `warehouse_attributes` (turnover cluster, role: fulfillment / oversized / returns); `is_return_warehouse` excludes parcels on their way back from "in stock" |
| `dim_dates` | date_day | table — `dbt_utils.date_spine` from 2025-01-01 to today + 2 months, ISO weeks; dense views (`rpt_stock_days`) join to it so a missing day is a visible hole |
| `snap_offers` | sku × version | snapshot (YAML), `check` strategy, `hard_deletes: new_record` |

No `fct_orders`: an order is `fct_order_lines` grouped by `order_id`.

Public views live in `models/reporting/rpt_*`: one wide table per dashboard page (fact joined to its dimensions),
indexed metrics only (base month = var `base_month`), ratios left to Looker Studio calculated fields.
