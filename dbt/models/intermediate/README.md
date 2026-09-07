# intermediate — one job per model

Between staging (1:1 with the source, no joins) and marts (business entities Looker reads). This is where the
business meaning appears: staging models of the same source are joined back into an entity, long formats are
pivoted wide, order-level amounts are allocated to lines. Nothing here is renamed or re-typed (that is staging's
job) and nothing here is a final metric (that is marts').

Materialized as views in schema `intermediate`. Not ephemeral, so every model exists in Snowflake and can be
queried while debugging (ephemeral would inline it as a CTE into each mart and errors would surface there).
Not tables, because nothing but `dbt run` reads this layer and a view cannot go stale. The trade-off: a view is
recomputed by every consumer — `int_order_lines` has two — so on a larger volume the heavy models switch to
`table` (one line of config); at this size it is seconds.

Derivations that depend on how the marketplace actually fills its fields are checked against the data with the
queries in `analyses/` (e.g. `line_status_combinations.sql`), not only against the API docs — the docs said
REJECTED covers cancellations, the data showed cancelled orders carry no events at all.

| model | grain | job |
|---|---|---|
| `int_order_lines` | order × line (`order_line_key`) | the order line as an analytical entity: line + order attributes + what happened to the units (events) + the order's fees allocated to the line |
| `int_stock_daily` | snapshot_date × sku × warehouse_id | stock types pivoted to columns; no calendar fill |

Conditional, decided after the revenue reconciliation (see project README):
`int_realization_lines` (realization report pivoted to order × sku) only if revenue is taken from the
realization report rather than from orders_stats.

Rule of thumb: if `fct_sales_daily` can be built from `int_order_lines` with one `group by`, the model is right.
