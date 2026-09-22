# reporting: what Looker Studio reads

There is one wide model per dashboard page, with the fact already joined to its dimensions, so each page reads a
single data source.

Two constraints shaped this layer.

The first is the Snowflake connector for Looker Studio. It doesn't push filters down for DATE / TIME / TIMESTAMP
columns, so the period control on a dashboard never narrows the query, and the dataset has to be small on its own.
The 1M-row / 50MB quota is counted per data source. Field names must be ASCII (values can be anything). Blends take
at most five sources, aggregate each one before joining, and can't be reused across reports.

The second is that facts carry only keys. Names and categories live in `dim_products` / `dim_warehouses`, because a
fact is incremental and an attribute copied into it would freeze for rows outside the window. They get joined back
here.

## Pages

The dashboard has six pages: Sales overview, Failed deliveries & returns, Restock, Stock & seasonality, Size mix,
About & methodology. It reads a frozen extract of these models with data as of 2026-09-17.

| model | pages | built from | materialization |
|---|---|---|---|
| `rpt_sales_daily` | Sales overview, Failed deliveries & returns | `fct_sales_daily` ∪ loss lines of `fct_order_lines`, + `dim_products` | view · event day × sku × `outcome` × `loss_reason` × `kept_instead` |
| `rpt_stock_sku` | Restock | `fct_stock_sku_daily` + `dim_products` | table · one row per sku, as of the latest stock report |
| `rpt_stock_days` | Stock & seasonality, Size mix | `fct_stock_sku_daily` + `dim_products` + `rpt_stock_sku` (velocity only) | view · day × sku |

### rpt_sales_daily

Sales, plus the units that didn't stay sold and what they cost. `outcome` is delivered, unredeemed or returned.
Loss rows have revenue 0 and margin = −fees and are dated by the day the units came back. That way a single
`SUM(contribution_margin)` gives the margin after failed sales. `loss_reason` says why a unit was lost (inferred in
`int_order_cancellations`). `kept_instead` says what the buyer kept from the same order when they refused part of it.

### rpt_stock_sku

The numbers a restock decision needs, each with the evidence behind it:

- stock now and days at zero;
- `velocity_recent`: the sku's decay-weighted sales, shrunk toward a type × size prior (gamma-Poisson), together
  with the prior, the weight of the sku's own data and a posterior interval;
- `velocity_restock`: the same estimator for the season the batch will land in. Its base is `velocity_now`, the
  sku's strength against its type's month curve brought to now, so a sku at zero since spring does not carry a
  spring rate into a winter batch;
- the size ratio to M within the colourway, kept share, cover days, missed sales over 90 days, units sold over the
  batch horizon, and `is_restock_candidate`.

Every sku gets a number, since the page ranks skus and a NULL can't be ranked. When the evidence is thin, the label
says so (`*_basis`). It's a table because the aggregates over the dense grid would otherwise be recomputed by every
widget, and two widgets could end up seeing two different states of the fact. Vars: `restock_lead_days`,
`restock_horizon_days`, `velocity_half_life_days`, `velocity_prior_units`, `season_prior_units`,
`index_prior_units`, `kept_prior_units`, `velocity_min_units`, `season_index_clamp`,
`season_min_coverage`. The method and the backtest
are in the model description.

### rpt_stock_days

Stock at the start of the day, demand during it, and the colourway's size run that morning. It also has additive
0/1 counters (`report_day_n`, `stockout_day_n`, full-run days and units, …), so any rate on the page can be computed
in BI as a ratio of sums. The sales lost on a stockout day, at the sku's current rate, are a column too, so they sum
over any period. Current-state numbers are in `rpt_stock_sku`, not here.

## Rules for rpt_* models

- Ratios are not stored. The numerator and the denominator are columns, and BI divides the sums. A stored
  `margin_pct` gives wrong numbers as soon as it's grouped. The one exception is a per-sku rate in a
  one-row-per-sku model (`rpt_stock_sku.velocity_recent`), where nothing aggregates it.
- No calendar columns. Looker Studio derives week and month from the date.
- The grain is the grain of the fact. A singular test checks that the view is the fact plus extra columns, with no
  rows lost or added (`tests/assert_rpt_sales_daily_matches_fact.sql`). One extension is allowed: a `union all` of
  two facts with the same columns, told apart by an explicit column, with each half reconciled to its own fact
  (`rpt_sales_daily` uses `outcome`; `assert_rpt_sales_daily_losses_match_lines.sql` checks the second half). A
  union may also split one fact row in two when the outcome belongs to units within the row. Then the grain includes
  the columns that tell the parts apart (`outcome`, `loss_reason`, `kept_instead`).
- Business logic stays in the facts, and classifications arrive ready-made. The exception is
  `rpt_sales_daily.kept_instead`: comparing what was refused with what was kept needs `dim_products`, and facts
  don't carry it. An exception like this needs a test on the join (`assert_rpt_sales_daily_kept_instead_covered.sql`)
  and a unit test on a fixture.
- A reconciliation test may repeat a filter but must not copy a classification. A filter or a date basis defines
  which half is being checked. A copied rule would pass along its own bugs. So the rule that decides which half of
  `rpt_sales_daily` carries a line's fees is checked from the line side: `assert_rpt_sales_daily_fees_counted_once.sql`
  makes sure each fee on a line shown on the page appears once.
- Gaps in the data stay visible. The calendar is filled in the mart (`fct_stock_sku_daily`) with `is_report_missing`
  and `is_demand_known` flags. A day without a stock report is NULL, never zero, and drops out of both the numerator
  and the denominator of a rate. Days after the last day of the order feed are handled the same way.
- Estimates that BI can't compute go here (`rpt_stock_sku`: decay-weighted evidence, shrinkage to type × size, the
  arrival window from last year). Each one has a unit test for its rule (`rpt_stock_sku_shrinks_to_the_prior`,
  `…_never_delivered_gets_the_prior`, `…_age_counts_in_stock_days`, `…_size_ratio_within_colourway`,
  `…_season_from_last_year_window`, `…_restock_base_is_brought_to_now`, `…_orphan_and_stale_type_keep_a_base`).
- Views by default. The sources are small, and every dashboard query scans the whole set anyway. A table only makes
  sense when several widgets would recompute the same window logic (`rpt_stock_sku`).

## Publishing real data

The public dashboard shows the brand's real figures, with the business owner's permission. I tried two cheaper
options first and dropped both.

- Masking with constants (money × k, counts × m). This breaks at the day × sku grain. 84 % of rows hold one unit, so
  a row's revenue is the price of one item, and that price is public on the marketplace. Looker's Record Count isn't
  scaled at all.
- A synthetic copy of the data. Keeping the generator consistent with the models turned into a second project. The
  synthetic stock data disagreed with `rpt_stock_sku` in seven places, so the page contradicted its own methodology.

What limits the exposure is the scope of the numbers: contribution margin leaves out fixed costs, part of the cost
of goods is estimated (`cogs_estimated`), and the data is a frozen extract.

## Not built

| model | would serve | why not yet |
|---|---|---|
| `rpt_order_economics` | fees on failed deliveries by payment type, region, warehouse | needs `fee_type` unpivoted; the reason model `int_order_cancellations` is ready for it |
| `rpt_inventory_turnover` | the marketplace's turnover by cluster | the report's `sku` for caps is a warehouse label (K1…K5) that isn't mapped to catalogue skus yet |
