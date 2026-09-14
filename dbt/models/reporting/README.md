# reporting — what Looker Studio reads

One wide view per dashboard page: the fact joined to its dimensions, so a page reads exactly one data source.
Not an extra layer for its own sake — it pays for two earlier decisions.

**The connector.** Snowflake's connector for Looker Studio does not push filters down for DATE / TIME /
TIMESTAMP columns, so the period control on a dashboard never narrows the query: the dataset must be small by
itself. Its 1M-row / 50MB quota is counted per data source, field names must be ASCII (values need not be), and
blends take at most five sources, aggregate each before joining, and cannot be reused across reports.

**Facts carry keys only.** Names and categories live in `dim_products` / `dim_warehouses` (a fact is
incremental; an attribute copied into it would freeze for rows outside the window). Something has to join them
back, and that is here.

Rules for every `rpt_*`:

- ratios are never stored — keep the numerator and the denominator as columns and let BI divide the sums; a
  stored `margin_pct` returns garbage under any grouping;
- no calendar columns — Looker Studio derives week and month from the date;
- grain stays the grain of the fact, and a singular test proves the view is the fact plus columns, nothing lost
  and nothing invented (`tests/assert_rpt_sales_daily_matches_fact.sql` is the pattern). The one allowed
  extension is a `union all` of two facts that share the columns, each half reconciled to its own fact by its own
  test and told apart by an explicit column — `rpt_sales_daily` does this with `outcome`
  (`assert_rpt_sales_daily_losses_match_lines.sql` is the second half). A `union all` may also SPLIT a fact row
  when the outcome is a property of the unit rather than of the row, and then the grain carries the columns that
  tell the parts apart (`rpt_sales_daily`: `outcome`, `loss_reason`, `kept_instead`);
- reporting does not compute business logic — the classification arrives ready from the facts. The single exception
  in the project is `rpt_sales_daily.kept_instead`, and it is allowed only because the comparison needs
  `dim_products`, which the facts do not carry by the «facts hold keys only» rule. Such an exception owes a test on
  the seam to the layer that decided the rest (`assert_rpt_sales_daily_kept_instead_covered.sql`);
- a reconciliation may repeat a FILTER or a date basis — that is the definition of the half it checks, and a guard
  that the view did not quietly re-draw it — but never a CLASSIFICATION: a copied rule passes its own bugs. So the
  money rule of `rpt_sales_daily` (which half pays a line's fees) is checked from the line side instead
  (`assert_rpt_sales_daily_fees_counted_once.sql`: every fee on a line the page shows appears exactly once), and a
  seam where the view derives what a fact decided is checked as a seam, against the fact's own flag
  (`assert_rpt_sales_daily_kept_instead_covered.sql`);
- views, not tables: the sources are small and every dashboard query scans the whole set anyway.

## Public and private

> **Under revision (2026-09-10).** An independent review showed the scheme below does not hold at this grain.
> 84 % of the rows carry a single unit, so `min(units_delivered)` in the public view *is* the count constant,
> and a single-unit row's revenue *is* one item's price — which is published on the marketplace. Looker Studio's
> own Record Count metric is not scaled at all and gives the true number of sales outright. Masking the numbers
> while publishing the same grain, the sku and the date does not hide the business. The likely fix is to publish
> a coarser grain (month × product type) rather than a masked copy of this view; until that is decided, treat the
> rest of this section as the intent, not the design.

Two Looker Studio reports read the same column set. The private one runs the brand and reads `rpt_*` with real
roubles. The public one is linked from a CV and reads `rpt_*_public`, where every money column is multiplied by
a secret constant and every count by a second one.

A constant, not an index (`revenue / revenue(base_month) * 100`): multiplication preserves the arithmetic —
`contribution_margin = revenue − fee_total − cogs` still holds, percentages and shares stay true — whereas an
index of revenue and an index of cost cannot be subtracted into a margin. Random per-row noise is worse than
either: it breaks the same arithmetic, `random()` is non-deterministic so published figures would move on every
refresh, and multiplicative noise averages out in aggregates, which is all a dashboard shows.

Two constants rather than one because **the brand's prices are public on the marketplace**: with counts left
real, `revenue / units_delivered` is an average selling price, and dividing it by the published price recovers
the multiplier. With money and counts scaled separately only their ratio leaks.

The constants come from `env_var()` with no default and never enter the repository (same pattern as the private
cost seed). Column names in `rpt_x` and `rpt_x_public` must be identical: the public report is a copy of the
private one with the data source swapped, and Looker breaks every widget when the schemas differ. For the same
reason `current_basic_price` is in neither — a real price standing next to masked money gives the constant away.

## Pages

| view | page | source | state |
|---|---|---|---|
| `rpt_sales_daily` | Pulse · SKU analytics · Drops — sales, and every unit that came back with what it cost (`outcome` = delivered / unredeemed / returned, plus `loss_reason` and `kept_instead`), so the page's margin is after losses and refusals can be read by product type | `fct_sales_daily` ∪ `fct_order_lines` (loss lines) + `dim_products` | written, being wired into Looker |
| `rpt_sales_daily_public` | the same, published | `rpt_sales_daily` | next |
| `rpt_order_economics` | Order economics: unredeemed parcels, returns, fee mix | `fct_order_lines` + `dim_products` | planned — needs a date basis for lines that were never delivered, and `fee_type` unpivoted |
| `rpt_inventory_turnover` | Separate report «Stock»: turnover by cluster | `fct_inventory_turnover_monthly` + `dim_products` | blocked — the report's `sku` is a warehouse label (K1…K5) for caps, not resolved to catalogue skus yet |
| `rpt_stock_days` | Separate report «Stock»: days of cover, size stock-outs | `fct_inventory_daily` + 30-day velocity from `fct_sales_daily` + `dim_products` | planned — restock is decided here, not on the sales pages; snapshots accumulate since 2026-09-03 |
