"""
Generate synthetic demo data with the same shape as the RAW tables, so the whole dbt project
(`dbt build --vars '{"use_demo_seeds": true}'`) runs without API access and without exposing real sales.

Writes: dbt/seeds/demo_united_orders_orders.csv, demo_united_orders_services.csv,
        demo_goods_turnover.csv, demo_stock_snapshots.csv, demo_cogs_by_sku.csv

Column names mirror ingest/load_to_snowflake.py normalisation (UPPER_SNAKE). Adjust once the real
CSV headers are known — keep the two in sync.
"""
from __future__ import annotations

import csv
import datetime as dt
import math
import pathlib
import random

random.seed(42)
OUT = pathlib.Path(__file__).resolve().parents[1] / "dbt" / "seeds"
OUT.mkdir(parents=True, exist_ok=True)

START, END = dt.date(2025, 1, 1), dt.date(2025, 12, 31)
CATEGORIES = {"t-shirts": 12, "hoodies": 8, "caps": 5, "accessories": 5}
WAREHOUSES = ["WH-MSK-1", "WH-SPB-1"]
STATUSES = ["DELIVERED"] * 85 + ["CANCELLED"] * 8 + ["RETURNED"] * 7
LOADED_AT = "2026-01-05T10:00:00+00:00"

# --- products -------------------------------------------------------------------------------------
skus: list[dict] = []
for cat, n in CATEGORIES.items():
    for i in range(1, n + 1):
        base = {"t-shirts": 2400, "hoodies": 5200, "caps": 1800, "accessories": 1200}[cat]
        skus.append({
            "sku": f"{cat[:3].upper()}-{i:03d}",
            "name": f"{cat.rstrip('s').title()} #{i}",
            "category": cat,
            "price": round(base * random.uniform(0.8, 1.3), -1),
            "cost": None,  # filled below
            "popularity": random.lognormvariate(0, 0.6),
        })
for s in skus:
    s["cost"] = round(s["price"] * random.uniform(0.35, 0.55), 0)


def season(d: dt.date) -> float:
    """Mild seasonality: peaks in Nov–Dec, dip in Jan–Feb."""
    return 1 + 0.35 * math.sin((d.timetuple().tm_yday - 60) / 365 * 2 * math.pi)


# --- orders & services ---------------------------------------------------------------------------
orders, services = [], []
order_seq = 100000
d = START
while d <= END:
    n_orders = max(0, int(random.gauss(6 * season(d), 2)))
    for _ in range(n_orders):
        order_seq += 1
        oid = f"ORD-{order_seq}"
        status = random.choice(STATUSES)
        created = dt.datetime.combine(d, dt.time(random.randint(8, 22), random.randint(0, 59)))
        lines = random.choices(skus, weights=[s["popularity"] for s in skus], k=random.choice([1, 1, 1, 2, 2, 3]))
        order_total = 0.0
        region = random.choice(["Moscow", "Saint Petersburg", "Kazan", "Novosibirsk", "Yekaterinburg"])
        for s in lines:
            qty = random.choice([1, 1, 1, 2])
            discount = round(s["price"] * random.choice([0, 0, 0.05, 0.10, 0.15]), 2)
            paid = round((s["price"] - discount) * qty, 2)
            refund = paid if status == "RETURNED" else 0.0
            if status != "CANCELLED":
                order_total += paid
            orders.append({
                "ORDER_ID": oid, "ORDER_CREATED_AT": created.isoformat(sep=" "), "ORDER_STATUS": status,
                "OFFER_ID": s["sku"], "PRODUCT_NAME": s["name"], "CATEGORY": s["category"],
                "QUANTITY": qty, "PRICE": s["price"], "DISCOUNT": discount * qty,
                "PAID_BY_CUSTOMER": paid, "REFUND_AMOUNT": refund,
                "DELIVERY_REGION": region,
                "_LOADED_AT": LOADED_AT, "_SOURCE_FILE": "demo",
            })
        if status != "CANCELLED":
            for svc, share in (("COMMISSION", 0.15), ("LOGISTICS", 0.06), ("PAYMENT_PROCESSING", 0.013)):
                services.append({"ORDER_ID": oid, "SERVICE_TYPE": svc,
                                 "SERVICE_AMOUNT": round(-order_total * share, 2),
                                 "_LOADED_AT": LOADED_AT, "_SOURCE_FILE": "demo"})
    d += dt.timedelta(days=1)

# --- stock snapshots (daily) & marketplace turnover report (monthly) ------------------------------
stock = {(w, s["sku"]): random.randint(20, 120) for w in WAREHOUSES for s in skus}
snapshots, turnover = [], []
sold_by_day: dict[tuple[dt.date, str], int] = {}
for o in orders:
    if o["ORDER_STATUS"] != "CANCELLED":
        key = (dt.date.fromisoformat(o["ORDER_CREATED_AT"][:10]), o["OFFER_ID"])
        sold_by_day[key] = sold_by_day.get(key, 0) + int(o["QUANTITY"])

d = START
month_sales: dict[str, list[int]] = {s["sku"]: [] for s in skus}
while d <= END:
    for (w, sku), qty in list(stock.items()):
        sold = sold_by_day.get((d, sku), 0) // len(WAREHOUSES)
        stock[(w, sku)] = max(0, qty - sold)
        if d.day == 1 or stock[(w, sku)] < 10:          # monthly replenishment + safety restock
            stock[(w, sku)] += random.randint(30, 80)
        snapshots.append({"SNAPSHOT_DATE": d.isoformat(), "WAREHOUSE_ID": w, "SKU": sku,
                          "COUNT": stock[(w, sku)], "STOCK_TYPE": "AVAILABLE",
                          "_LOADED_AT": LOADED_AT, "_SOURCE_FILE": "demo"})
    for s in skus:
        month_sales[s["sku"]].append(sold_by_day.get((d, s["sku"]), 0))
    next_day = d + dt.timedelta(days=1)
    if next_day.month != d.month:                        # last day of month → marketplace-style report
        for s in skus:
            units = sum(month_sales[s["sku"]][-d.day:])
            avg_daily = units / d.day
            total_stock = sum(stock[(w, s["sku"])] for w in WAREHOUSES)
            turnover.append({
                "REPORT_DATE": d.isoformat(), "WAREHOUSE": "ALL", "SKU": s["sku"], "PRODUCT_NAME": s["name"],
                "CATEGORY": s["category"], "STOCK_UNITS": total_stock,
                "AVG_DAILY_SALES_UNITS": round(avg_daily, 3),
                "TURNOVER_DAYS": round(total_stock / avg_daily, 1) if avg_daily else "",
                "STORAGE_FEE": round(total_stock * 1.2 * d.day, 2),
                "RECOMMENDATION": "OK" if avg_daily and total_stock / avg_daily < 60 else "REDUCE_STOCK",
                "_LOADED_AT": LOADED_AT, "_SOURCE_FILE": "demo",
            })
    d = next_day

cogs = [{"SKU": s["sku"], "VALID_FROM": START.isoformat(), "UNIT_COST": s["cost"]} for s in skus]


def write(name: str, rows: list[dict]) -> None:
    path = OUT / f"{name}.csv"
    with path.open("w", newline="", encoding="utf-8") as fh:
        w = csv.DictWriter(fh, fieldnames=list(rows[0].keys()))
        w.writeheader()
        w.writerows(rows)
    print(f"{path.name}: {len(rows)} rows")


write("demo_united_orders_orders", orders)
write("demo_united_orders_services", services)
write("demo_goods_turnover", turnover)
write("demo_stock_snapshots", snapshots)
write("demo_cogs_by_sku", cogs)
