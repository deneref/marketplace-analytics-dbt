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
| `fct_order_lines` | order × line (`order_line_key`) | incremental, 30-day window on `status_updated_at`; `delete+insert` by `order_id` (the unit of change is the order) or `merge` by `order_line_key` |
| `fct_order_fees` | order × fee_type | table — unallocated truth for reconciliations |
| `fct_sales_daily` | delivered day × sku | table, one `group by` over `fct_order_lines`; only delivered units |
| `fct_inventory_daily` | snapshot_date × sku × warehouse_id | table — `days_of_cover`, `is_out_of_stock` |
| `fct_inventory_turnover_monthly` | month × sku × macroregion | table — the marketplace's report as is, no own turnover |
| `dim_products`, `dim_warehouses`, `dim_dates` | sku / warehouse_id / date_day | table |
| `snap_offers` | sku × version | snapshot (YAML), `check` strategy, `hard_deletes: new_record` |

No `fct_orders`: an order is `fct_order_lines` grouped by `order_id`.

Public views live in `models/reporting/rpt_*`: one wide table per dashboard page (fact joined to its dimensions),
indexed metrics only (base month = var `base_month`), ratios left to Looker Studio calculated fields.
