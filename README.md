# Marketplace analytics with dbt on Snowflake

Sales, failed-delivery and restock analytics for *one of yours*, a small apparel brand I co-founded. We sell through
a large Russian marketplace. The data comes from the seller API, is loaded into Snowflake with Python, modelled in dbt
and shown in Looker Studio.

I built it around two questions we kept running into:
1. Which products make money once marketplace fees and failed sales (parcels never collected, refused, returned) are counted?
2. What to put back into production, and in which sizes, when a batch takes about two months and cash is limited?

Dashboard: [Marketplace Sales & Restock Analytics](https://lookerstudio.google.com/reporting/d80f9514-94fd-4404-9113-d71d71c5398e?hl=en).
The data is real. It was frozen on September 17, 2026 and is published with the business owner's permission.

![Sales overview](docs/dashboard.png)

## Architecture

```
Seller API (JSON endpoints + async reports) ──ingest/──▶ Snowflake RAW (append-only, every column documented)
  │
  └─▶ staging        13 models (12 marketplace endpoints + 1 cost-of-goods sheet):
  │                  typed, deduplicated, JSON flattened; 1:1 with the source
  │
  └─▶ intermediate
  │     int_order_lines ─────────────── order line + its share of the order's fees + what happened to every unit
  │     int_order_cancellations ─────── why an order failed (inferred; the API has no reason field)
  │     int_stock_daily ─────────────── end-of-day stock per sku × warehouse
  │
  └─▶ marts
  │     fct_order_lines ─────────────── one row per line sold: prices, fees, COGS, margin (incremental)
  │     fct_sales_daily ─────────────── delivered sales by day × sku
  │     fct_inventory_daily ─────────── stock by day × sku × warehouse, calendar filled
  │     fct_stock_sku_daily ─────────── per sku per day: stock in the morning, demand during the day
  │     fct_inventory_turnover_monthly ─ the marketplace's own monthly turnover & storage report, as is
  │     dim_products · dim_warehouses · dim_dates ── products, warehouses, calendar
  │
  └─▶ reporting      one view per dashboard page
        rpt_sales_daily ──▶ Sales:    margin after failed sales, loss reasons
        rpt_stock_sku ────▶ Restock:  velocity, cover, what to reproduce and in which sizes
        rpt_stock_days ───▶ History:  availability heatmap, seasonality, size runs
              └─▶ Looker Studio
```

![dbt lineage](docs/dag.png)

27 models · 460+ generic data tests · 24 singular reconciliation tests · 5 unit tests.

## What's inside

### Revenue

Each order line carries several price fields, and the API docs describe them wrong: the "marketplace" field is
documented as coupons only. The marketplace pays the seller according to a monthly settlement report, so I matched
1,405 delivered orders over 20 months against that report (`analyses/revenue_reconciliation.sql`) and tried four
candidate formulas. The buyer price equals the report's after-discount total exactly. Buyer price plus the
marketplace-funded discount matches the before-discount total, which is what the seller gets paid on, within 0.7 %.
That sum is revenue here. `tests/assert_revenue_matches_realization.sql` repeats the check on every build
and warns if a month drifts by more than 3 %.

### Fee allocation

Fees come per order. `int_order_lines` splits them across lines pro rata and puts the rounding remainder on one
line; `tests/assert_fees_allocation_sums.sql` checks that the lines add up to the order total to 0.01 ₽.

### Failed sales

About 30 % of orders are never collected, and the marketplace charges fees on them anyway. `rpt_sales_daily` puts
sale rows and failed-sale rows (revenue 0, margin = −fees) in one table, dated by the day the sale or the failure
happened. Margin after failed sales is then a plain SUM. Both halves are reconciled to their fact tables, and a
test catches any fee counted twice or missed.

### Why orders fail

The API has no reason field. `int_order_cancellations` works the reason out with a decision tree over order
substatus, delivery date and the pickup-point storage window. Some rules are guesses, and the model marks which.

### Restock velocity

A SKU with zero stock sells nothing. Divide its sales by calendar days and the items that most need restocking look
unpopular, so I count sales per in-stock day instead. `fct_stock_sku_daily` fills in the calendar; a day with no
stock report is marked missing, which is different from zero stock. `rpt_stock_sku` shrinks each SKU's
decay-weighted rate toward a type × size prior (gamma-Poisson). Even a SKU with little history gets an estimate
and an interval. In a backtest this did 25 % better than my old cascade, which fell back from the last 180 days to
lifetime sales and then to the type average. Restock candidates are flagged against the production lead time.
Unit tests cover the maths.

### Incremental loading

`fct_order_lines` is incremental with a restatement window. Statuses, returns and late fees can change an order weeks
later. Orders from the last 30 days are rewritten whole on each run (`delete+insert` by `order_id`).

### Raw-layer docs

`scripts/gen_sources_yml.py` holds a description for each raw column and writes the sources yaml from it; `load_to_snowflake.py` pushes the same text into Snowflake column comments. `--check` fails when a new
column shows up undocumented.

Each layer has its own README (`dbt/models/*/README.md`) with the decisions made there and the options I dropped.

## Known limitations

- Contribution margin leaves out fixed costs, and part of the cost of goods is estimated (`cogs_estimated`).
- In joint promotions the marketplace refunds the full discount on the order and then takes the seller's share back
  as a separate charge to the bonus balance. That charge is not in the order data and I haven't loaded it yet.
  Revenue is right, but contribution margin is probably overstated for November 2025 – June 2026. In those months
  the marketplace-funded discount went from its usual ~20 % of revenue to ~44 %. My rough estimate of the
  overstatement is 40–70 % of that period's margin. The low end counts only the discount above the usual level,
  the high end counts all of the marketplace-funded discount.
- The stock pages rank batches in units; today's stock is not yet netted off the batch size.

## Run it

The seller data is private, so the models need your own Snowflake with RAW loaded.

```bash
python -m venv .venv && source .venv/bin/activate && pip install -r requirements.txt
cp dbt/profiles.example.yml ~/.dbt/profiles.yml     # Snowflake, key-pair auth via env vars
python ingest/yandex_market.py --report orders-stats --from 2025-01-01 --to 2025-06-30   # needs a seller API token
python ingest/load_to_snowflake.py
cd dbt && dbt deps && dbt build
```

CI (`.github/workflows/dbt_ci.yml`) runs `dbt parse` on every push with no warehouse. A synthetic-seed path exists
(`--vars '{"use_demo_seeds": true}'`, `seeds_gen/`), but it covers 5 of 13 sources so far; CI reports the gap.

## What I would change for production

Per-developer schemas and a `prod` target; `dbt build --select state:modified+` on pull requests; a least-privilege
service role; scheduled ingestion in an orchestrator instead of launchd; alerts on freshness and test failures;
SCD2 snapshots of the catalogue.
