# intermediate: one job per model

This layer sits between staging (1:1 with the source, no joins) and marts (the business entities Looker reads).
Business meaning starts here. Staging models of the same source are joined back into an entity, long formats are
pivoted wide, and order-level amounts are allocated to lines. Renaming and casting belong to staging, and final
metrics belong to marts.

The models are views in schema `intermediate`. I didn't make them ephemeral, because I want every model to exist in
Snowflake so I can query it while debugging. I didn't make them tables either: only `dbt run` reads this layer, and
a view can't go stale. The cost is that a view is recomputed for every consumer (`int_order_lines` has two). At this
data size that takes seconds; with more data the heavy models would switch to `table`, which is one line of config.

Anything that depends on how the marketplace really fills its fields is checked against the data with the queries
in `analyses/` (for example `line_status_combinations.sql`), as well as against the API docs. The docs said REJECTED
covers cancellations. The data showed that cancelled orders have no events at all.

| model | grain | job |
|---|---|---|
| `int_order_lines` | order × line (`order_line_key`) | the order line as an analytical entity: line and order attributes, what happened to the units (events), the order's fees allocated to the line, and why returned units came back |
| `int_order_cancellations` | order (cancelled orders only) | why an order was cancelled, from a decision tree over substatus, real delivery date, the buyer's cancellation request and the pickup-point storage window; records which rule fired and whether it was an inference |
| `int_stock_daily` | snapshot_date × sku × warehouse_name | end-of-day stock from the stocks-on-warehouses report (history from 2025-01-08), buckets pivoted to columns, warehouse_id looked up in stg_ym__warehouses; no calendar fill |

I decided not to build `int_realization_lines` (the realization report pivoted to order × sku). The revenue
reconciliation (`analyses/revenue_reconciliation.sql`) showed that revenue can come from orders_stats
(`price_buyer_total + price_marketplace_total`). The realization report is only used as a benchmark, in
`tests/assert_revenue_matches_realization.sql`.

The loss reason takes two models. The reason itself belongs to the order, so it lives in `int_order_cancellations`
and is tested at order grain: one reason per order, an empty default branch, and the storage-window rules flagged as
inferences. Two things belong to the line and live in `int_order_lines`: which wins when the order's reason and the
line-level evidence disagree, and the rule that a reason is attached only to lines that lost units. The planned
`rpt_order_economics` will also read the order-grain model directly, without going through the line fact.

A quick check for this layer: if `fct_sales_daily` can be built from `int_order_lines` with one `group by`, the
model is right.
