"""
Generate synthetic demo data with the same shape as the RAW tables, so the whole dbt project
(`dbt build --vars '{"use_demo_seeds": true}'`) runs without API access and without exposing real sales.

Writes: dbt/seeds/demo_united_orders_orders.csv, demo_united_orders_services.csv,
        demo_goods_turnover.csv, demo_stock_reports.csv, demo_warehouses.csv, demo_cogs_by_sku.csv

Column names = the real report headers (verified against the first download, 2026-09-03), restricted to the
columns staging actually uses. Keep in sync with dbt/models/staging/yandex_market/_ym__sources.yml.
"""
from __future__ import annotations

import csv
import json
import datetime as dt
import math
import pathlib
import random
import zlib

random.seed(42)
OUT = pathlib.Path(__file__).resolve().parents[1] / "dbt" / "seeds"
OUT.mkdir(parents=True, exist_ok=True)

START, END = dt.date(2025, 1, 1), dt.date(2025, 12, 31)
CATEGORIES = {"t-shirts": 12, "hoodies": 8, "caps": 5, "accessories": 5}
WAREHOUSES = [147, 172]                       # numeric warehouse ids, like orders and GET v2/warehouses
WAREHOUSE_NAMES = {147: "Демо-склад Москва", 172: "Демо-склад Санкт-Петербург"}   # the stock REPORT prints names
REGIONS = ["Москва", "Санкт-Петербург", "Казань", "Новосибирск", "Екатеринбург"]
# (offer_status on the order-line sheet, order_status on the per-order services sheet)
STATUSES = [("Delivered to buyer", "Delivered")] * 85 + [("Cancelled", "Canceled during processing")] * 8 \
         + [("Return received in warehouse", "Full return accepted at warehouse")] * 7
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
        offer_status, order_status = random.choice(STATUSES)
        created = dt.datetime.combine(d, dt.time(random.randint(8, 22), random.randint(0, 59)))
        delivered = d + dt.timedelta(days=random.randint(1, 4))
        lines = random.choices(skus, weights=[s["popularity"] for s in skus], k=random.choice([1, 1, 1, 2, 2, 3]))
        order_total = 0.0
        region = random.choice(REGIONS)
        for s in lines:
            qty = random.choice([1, 1, 1, 2])
            discount = round(s["price"] * random.choice([0, 0, 0.05, 0.10, 0.15]), 2)
            paid = round((s["price"] - discount) * qty, 2)
            refund = paid if order_status.startswith("Full return") else ""
            if not order_status.startswith("Canceled"):
                order_total += paid
            orders.append({
                "ORDER_ID": oid, "CREATION_DATE": created.strftime("%d.%m.%Y"), "ORDER_TYPE": "Sale to individual",
                "SHOP_SKU": s["sku"], "OFFER_NAME": s["name"],
                "BILLING_PRICE": s["price"], "TRANSFERRED_FOR_DELIVERY": qty,
                "DELIVERED_OR_RETURNED": qty if not order_status.startswith("Canceled") else 0,
                "DELIVERY_DATE": delivered.strftime("%d.%m.%Y") if not order_status.startswith("Canceled") else "",
                "OFFER_STATUS": offer_status,
                "STATUS_CHANGED": (created + dt.timedelta(days=random.randint(1, 5))).strftime("%Y-%m-%d %H:%M:%S"),
                "SHIPMENT_WAREHOUSE": "Яндекс.Маркет (Софьино)", "DELIVERY_REGION": region,
                "BUYER_PAYMENT_AMOUNT": paid if not order_status.startswith("Canceled") else "",
                "REFUND_BUYER_PAYMENT_AMOUNT": refund,
                "_LOADED_AT": LOADED_AT, "_SOURCE_FILE": "demo",
            })
        if not order_status.startswith("Canceled"):
            fees = {"SALE_COMMISSION": 0.15, "BUYER_DELIVERY": 0.05, "CROSSREGIONAL_DELIVERY": 0.01,
                    "BUYER_PAYMENT_ACCEPT": 0.005, "BUYER_PAYMENT_TRANSFER": 0.008, "LOYALTY_PROGRAM": 0.02,
                    "BOOST": 0.0, "INSTALLMENT": 0.0, "WAREHOUSE_PROCESSING": 0.0}
            amounts = {k: round(order_total * v, 2) for k, v in fees.items()}
            total_fee = round(sum(amounts.values()), 2)
            services.append({
                "ORDER_ID": oid, "ORDER_STATUS": order_status, "CREATION_DATE": created.strftime("%d.%m.%Y"),
                "ORDER_TYPE": "Sale to individual",
                "SUMMARY_COMMISSION": total_fee, "SUM_BILLING_PRICE_OF_ITEMS": round(order_total, 2),
                "INCOME_WITHOUT_SERVICES": round(order_total - total_fee, 2),
                "BUYER_PAYMENT": round(order_total, 2), "BUYER_PAYMENT_STATUS": "Transferred",
                **amounts, "_LOADED_AT": LOADED_AT, "_SOURCE_FILE": "demo",
            })
    d += dt.timedelta(days=1)

# --- stock snapshots (daily) & marketplace turnover report (monthly) ------------------------------
stock = {(w, s["sku"]): random.randint(20, 120) for w in WAREHOUSES for s in skus}
snapshots, turnover = [], []
sold_by_day: dict[tuple[dt.date, str], int] = {}
for o in orders:
    if o["OFFER_STATUS"] != "Cancelled":
        key = (dt.datetime.strptime(o["CREATION_DATE"], "%d.%m.%Y").date(), o["SHOP_SKU"])
        sold_by_day[key] = sold_by_day.get(key, 0) + int(o["TRANSFERRED_FOR_DELIVERY"])

d = START
month_sales: dict[str, list[int]] = {s["sku"]: [] for s in skus}
while d <= END:
    for (w, sku), qty in list(stock.items()):
        sold = sold_by_day.get((d, sku), 0) // len(WAREHOUSES)
        stock[(w, sku)] = max(0, qty - sold)
        if d.day == 1 or stock[(w, sku)] < 10:          # monthly replenishment + safety restock
            stock[(w, sku)] += random.randint(30, 80)
        # same shape as the stocks-on-warehouses REPORT (wide, one row per SKU × warehouse; the date is NOT a column:
        # the report requested with reportDate = d + 1 holds the stock at the end of day d, and staging reads the
        # reportDate from the folder in _SOURCE_FILE — hence the path below)
        qty = stock[(w, sku)]
        snapshots.append({
            "SHOP_SKU": sku, "ARTICLE": sku, "MARKET_SKU": 100000000000 + zlib.crc32(sku.encode()) % 10**9,
            "PRODUCT_NAME": next(s["name"] for s in skus if s["sku"] == sku),
            "VALID": qty, "RESERVED": 0, "AVAILABLE_FOR_ORDER": qty,
            "QUARANTINE": 0, "UTILIZATION": 0, "DEFECT": 0, "EXPIRED": 0,
            "LENGTH": 0, "WIDTH": 0, "HEIGHT": 0, "WEIGHT": 0,
            "WAREHOUSE": WAREHOUSE_NAMES[w],
            "SELLING_STATUS": "Продажи идут" if qty > 0 else "Нет на складе", "RECOMMENDATIONS": "",
            "TURNOVER": "Нет продаж",
            "_LOADED_AT": LOADED_AT,
            "_SOURCE_FILE": f"demo/stock_reports/{(d + dt.timedelta(days=1)).isoformat()}/stocks_on_warehouses.csv",
        })
    for s in skus:
        month_sales[s["sku"]].append(sold_by_day.get((d, s["sku"]), 0))
    next_day = d + dt.timedelta(days=1)
    if next_day.month != d.month:                        # last day of month → marketplace-style report
        for s in skus:
            units = sum(month_sales[s["sku"]][-d.day:])
            avg_daily = units / d.day
            total_stock = sum(stock[(w, s["sku"])] for w in WAREHOUSES)
            for w, macro in zip(WAREHOUSES, ("Москва", "Санкт-Петербург")):
                wh_stock = stock[(w, s["sku"])]
                wh_avg = avg_daily / len(WAREHOUSES)
                turnover.append({
                    # no report-date column in the real file: the date lives in the path, i.e. in _SOURCE_FILE
                    "MACROREGION_NAME": macro, "CATEGORY": "Одежда, обувь и аксессуары",
                    "SHOP_SKU": s["sku"], "MARKET_SKU": 100000000000 + zlib.crc32(s["sku"].encode()) % 10**9, "OFFER_NAME": s["name"],
                    "LENGTH": 350, "WIDTH": 250, "HEIGHT": 40, "VOLUME": 3.5,
                    "TURNOVER": round(wh_stock / wh_avg, 6) if wh_avg else "Нет продаж",
                    "AMOUNT": "-", "MARKET_RECOMMENDATION": "",
                    "AVG_SOLD_VOLUME": round(wh_avg * 3.5, 6), "AVG_SOLD_ITEMS": round(wh_avg, 6),
                    "AVG_SOLD_VOLUME_ON_STOCK": round(wh_stock * 3.5), "ITEMS_ON_STOCK": wh_stock,
                    "_LOADED_AT": LOADED_AT, "_SOURCE_FILE": f"demo/goods_turnover/{d.isoformat()}/turnover.csv",
                })
    d = next_day

# same layout as data/raw/cogs/<date>/by_sku.csv (see dbt/models/staging/finance/_finance__sources.yml); one version per SKU
cogs = [{
    "SKU": s["sku"], "PRODUCT_NAME": s["name"], "BATCH_LABEL": "Партия 1", "BATCH_PERIOD": START.strftime("%Y"),
    "BATCH_UNITS": 100, "VALID_FROM": START.isoformat(), "VALID_TO": "",
    "UNIT_COST": s["cost"], "CURRENCY": "RUB",
    "COST_MATERIALS": round(s["cost"] * 0.3, 2), "COST_MANUFACTURING": round(s["cost"] * 0.5, 2),
    "COST_PRINT": round(s["cost"] * 0.1, 2), "COST_LABEL": 0, "COST_PACKAGING": round(s["cost"] * 0.05, 2),
    "COST_SHIPPING": round(s["cost"] - round(s["cost"] * 0.3, 2) - round(s["cost"] * 0.5, 2)
                           - round(s["cost"] * 0.1, 2) - round(s["cost"] * 0.05, 2), 2), "COST_OTHER": 0,
    "COST_BASIS": "batch_actual", "IS_ESTIMATE": "false", "HAS_COST_BREAKDOWN": "true", "SKU_IN_CATALOGUE": "true",
    "SOURCE_FILE": "demo", "SOURCE_SHEET": "demo", "NOTE": "",
    "_LOADED_AT": LOADED_AT, "_SOURCE_FILE": "demo/cogs/2026-01-05/by_sku.csv",
} for s in skus]


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
write("demo_stock_reports", snapshots)
# GET v2/warehouses, flattened by ingest/yandex_market.py: one row per warehouse, address kept as JSON text
write("demo_warehouses", [{
    "SNAPSHOT_DATE": END.isoformat(), "ID": w, "NAME": WAREHOUSE_NAMES[w],
    "ADDRESS": json.dumps({"city": WAREHOUSE_NAMES[w].split()[-1], "street": "Демо", "number": "1",
                           "gps": {"latitude": 55.75, "longitude": 37.62}}, ensure_ascii=False),
    "_RAW_JSON": json.dumps({"id": w, "name": WAREHOUSE_NAMES[w]}, ensure_ascii=False),
    "_LOADED_AT": LOADED_AT, "_SOURCE_FILE": f"demo/warehouses/{END.isoformat()}/warehouses.jsonl",
} for w in WAREHOUSES])
write("demo_cogs_by_sku", cogs)
