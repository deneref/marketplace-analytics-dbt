"""
Yandex Market Partner API → local CSV files.

Report flow (documented by Yandex): POST .../generate → GET v2/reports/info/{reportId} until DONE →
download the file (link is valid for 60 minutes) → unzip CSV sheets into data/raw/<report>/<run_date>/.

Usage:
  python ingest/yandex_market.py --report united-orders --from 2025-01-01 --to 2025-12-31
  python ingest/yandex_market.py --report goods-turnover --date 2026-09-06
  python ingest/yandex_market.py --report stocks           # JSON endpoint, not a report — superseded by stocks-report (2026-09-14)
  python ingest/yandex_market.py --report warehouses       # FBY warehouses: id ↔ name (the stock report prints names)
  python ingest/yandex_market.py --report stocks-report --date 2025-06-01            # stock report for a PAST date (reportDate)
  python ingest/yandex_market.py --report stocks-report --from 2025-01-08 --to 2026-09-01 --step 7   # weekly backfill
  python ingest/yandex_market.py --report offer-mappings   # catalogue: category, vendor, dimensions, prices (JSON)
  python ingest/yandex_market.py --report orders-stats --from 2025-01-01 --to 2025-06-30   # order history (JSON)
  python ingest/yandex_market.py --report business-orders --from 2025-01-01 --to 2026-09-12  # cancellation reason + real delivery date (JSON, 30-day windows)
  python ingest/yandex_market.py --report shows-sales --from 2026-06-06 --to 2026-09-03    # daily funnel per SKU
  python ingest/yandex_market.py --report goods-realization --date 2025-03                 # monthly financial report

Env (.env): YM_API_KEY, YM_BUSINESS_ID, YM_CAMPAIGN_ID
"""
from __future__ import annotations

import argparse
import datetime as dt
import io
import json
import os
import pathlib
import sys
import time
import zipfile

import requests

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
from dotenv import load_dotenv

load_dotenv()
BASE = "https://api.partner.market.yandex.ru/v2"
HEADERS = {"Api-Key": os.environ["YM_API_KEY"], "Content-Type": "application/json"}
RAW_DIR = pathlib.Path(__file__).resolve().parents[1] / "data" / "raw"   # git-ignored


def _check(r: requests.Response) -> dict:
    if not r.ok:  # surface the API's own error message, not just the status code
        raise RuntimeError(f"{r.status_code} {r.request.method} {r.url}\n{r.text[:2000]}")
    return r.json()


def _post(path: str, body: dict, params: dict | None = None) -> dict:
    return _check(requests.post(f"{BASE}/{path}", headers=HEADERS, json=body, params=params, timeout=60))


def _get(path: str, params: dict | None = None) -> dict:
    return _check(requests.get(f"{BASE}/{path}", headers=HEADERS, params=params, timeout=60))


def wait_for_report(report_id: str, poll_s: int = 5, timeout_s: int = 900) -> str:
    """Poll report status until DONE; return the download URL."""
    deadline = time.time() + timeout_s
    while time.time() < deadline:
        info = _get(f"reports/info/{report_id}")["result"]
        status = info.get("status")
        if status == "DONE":
            return info["file"]
        if status == "FAILED":
            raise RuntimeError(f"report {report_id} failed: {info}")
        time.sleep(poll_s)
    raise TimeoutError(f"report {report_id} not ready after {timeout_s}s")


def download_zip(url: str, target_dir: pathlib.Path) -> list[pathlib.Path]:
    """Download the ZIP (CSV per sheet) and extract; returns extracted file paths.
    goods-realization ignores the CSV format and returns an XLSX (itself a zip) — keep it whole and tidy it to CSVs."""
    target_dir.mkdir(parents=True, exist_ok=True)
    r = requests.get(url, timeout=300)
    content = r.content
    if not zipfile.is_zipfile(io.BytesIO(content)):   # seen once in a 600-report run: the file host answered with something else
        raise RuntimeError(f"download is not a zip (HTTP {r.status_code}, {len(content)} bytes): {content[:300]!r}")
    out: list[pathlib.Path] = []
    with zipfile.ZipFile(io.BytesIO(content)) as zf:
        if "[Content_Types].xml" in zf.namelist():          # it's an .xlsx, not a bundle of CSVs
            xlsx = target_dir / "report.xlsx"
            xlsx.write_bytes(content)
            from realization_to_csv import convert       # same directory
            return convert(xlsx)
        for name in zf.namelist():
            dest = target_dir / pathlib.Path(name).name
            dest.write_bytes(zf.read(name))
            out.append(dest)
    return out


def report_united_orders(date_from: str, date_to: str, run_date: str) -> list[pathlib.Path]:
    body = {"businessId": int(os.environ["YM_BUSINESS_ID"]), "dateFrom": date_from, "dateTo": date_to}
    res = _post("reports/united-orders/generate", body, params={"format": "CSV", "language": "EN"})["result"]
    print(f"united-orders {date_from}..{date_to}: reportId={res['reportId']} "
          f"eta={res.get('estimatedGenerationTime', 0) / 1000:.0f}s", file=sys.stderr)
    url = wait_for_report(res["reportId"])
    return download_zip(url, RAW_DIR / "united_orders" / run_date / f"{date_from}_{date_to}")


def report_goods_turnover(date: str, run_date: str) -> list[pathlib.Path]:
    body = {"campaignId": int(os.environ["YM_CAMPAIGN_ID"]), "date": date}
    res = _post("reports/goods-turnover/generate", body, params={"format": "CSV", "language": "EN"})["result"]
    url = wait_for_report(res["reportId"])
    return download_zip(url, RAW_DIR / "goods_turnover" / run_date / date)


def report_shows_sales(date_from: str, date_to: str, run_date: str) -> list[pathlib.Path]:
    """Daily funnel per SKU: shows → clicks → cart → orders → delivered, with conversions. 1 request / 10 min without a plan."""
    body = {"businessId": int(os.environ["YM_BUSINESS_ID"]), "campaignId": int(os.environ["YM_CAMPAIGN_ID"]),
            "dateFrom": date_from, "dateTo": date_to, "grouping": "OFFERS"}
    res = _post("reports/shows-sales/generate", body, params={"format": "CSV", "language": "EN"})["result"]
    url = wait_for_report(res["reportId"])
    return download_zip(url, RAW_DIR / "shows_sales" / run_date / f"{date_from}_{date_to}")


def report_goods_realization(year_month: str, run_date: str) -> list[pathlib.Path]:
    """Monthly financial report (delivered / unredeemed / returned / lost, prices, VAT). year_month = 'YYYY-MM'."""
    year, month = (int(x) for x in year_month.split("-"))
    body = {"campaignId": int(os.environ["YM_CAMPAIGN_ID"]), "year": year, "month": month}
    res = _post("reports/goods-realization/generate", body, params={"reportFormat": "CSV", "language": "EN"})["result"]
    url = wait_for_report(res["reportId"])
    return download_zip(url, RAW_DIR / "goods_realization" / run_date / year_month)


def report_stocks_on_warehouses(report_date: str, run_date: str) -> list[pathlib.Path]:
    """Stock per SKU × warehouse as a report (POST reports/stocks-on-warehouses/generate), unlike `stocks` (JSON, today only).
    Docs: `reportDate` is FBY/LaaS-only and the report holds the stock of the day BEFORE report_date; no history
    depth is documented (the 90-day limit is stated for united-orders / turnover / movement, not here) — this mode
    exists to test how far back it really goes. 1 request / 2 min without a plan."""
    body = {"campaignId": int(os.environ["YM_CAMPAIGN_ID"]), "reportDate": report_date}
    res = _post("reports/stocks-on-warehouses/generate", body, params={"format": "CSV"})["result"]
    print(f"stocks-report reportDate={report_date}: reportId={res['reportId']} "
          f"eta={res.get('estimatedGenerationTime', 0) / 1000:.0f}s", file=sys.stderr)
    url = wait_for_report(res["reportId"], timeout_s=300)   # normally DONE in ~10 s; a report stuck longer is re-requested by the caller
    files = download_zip(url, RAW_DIR / "stock_reports" / run_date / report_date)
    for f in files:
        lines = f.read_text(encoding="utf-8", errors="replace").splitlines()
        print(f"  {f.name}: {max(len(lines) - 1, 0)} data rows", file=sys.stderr)
    return files


def report_stocks_on_warehouses_range(date_from: str, date_to: str, step_days: int, run_date: str) -> list[pathlib.Path]:
    """Walk reportDate from date_from to date_to every step_days, sleeping between calls to respect the 1 / 2 min limit."""
    d, end = dt.date.fromisoformat(date_from), dt.date.fromisoformat(date_to)
    files: list[pathlib.Path] = []
    while d <= end:
        day = d.isoformat()
        done = list((RAW_DIR / "stock_reports").glob(f"*/{day}/stocks_on_warehouses.csv"))
        if done:                                     # restartable: a date already pulled (any run_date) is skipped
            print(f"stocks-report reportDate={day}: already have {done[0]}", file=sys.stderr)
        else:
            for attempt in range(1, 4):              # expected failures: the 1 / 2 min rate limit, a report stuck in PENDING, a bad download
                try:
                    files += report_stocks_on_warehouses(day, run_date)
                    break
                except (RuntimeError, TimeoutError) as e:
                    retryable = isinstance(e, TimeoutError) or any(x in str(e) for x in ("429", "420", "LIMIT", "not a zip"))
                    if attempt == 3 or not retryable:
                        raise
                    print(f"  retry {attempt}/3 after 130s: {str(e)[:120]}", file=sys.stderr)
                    time.sleep(130)
            time.sleep(125)
        d += dt.timedelta(days=step_days)
    return files


def stocks_snapshot(run_date: str) -> pathlib.Path:
    """Current stock levels per SKU/warehouse (paginated JSON). Saved as newline-delimited JSON."""
    campaign = os.environ["YM_CAMPAIGN_ID"]
    target = RAW_DIR / "stock_snapshots" / run_date
    target.mkdir(parents=True, exist_ok=True)
    out = target / "stocks.jsonl"
    page_token, n = None, 0
    with out.open("w", encoding="utf-8") as fh:
        while True:
            params = {"limit": 200}
            if page_token:
                params["page_token"] = page_token
            data = _post(f"campaigns/{campaign}/offers/stocks", {}, params=params)["result"]
            for w in data.get("warehouses", []):
                for offer in w.get("offers", []):
                    fh.write(json.dumps({"snapshot_date": run_date, "warehouse_id": w.get("warehouseId"), **offer},
                                        ensure_ascii=False) + "\n")
                    n += 1
            page_token = data.get("paging", {}).get("nextPageToken")
            if not page_token:
                break
    print(f"stocks: {n} rows → {out}", file=sys.stderr)
    return out


def warehouses_snapshot(run_date: str) -> pathlib.Path:
    """FBY warehouses of the marketplace (GET v2/warehouses): id, name, address. Names are what the stock report prints
    in its WAREHOUSE column, ids are what the orders carry — this is the bridge. 100 requests / hour, tiny payload."""
    target = RAW_DIR / "warehouses" / run_date
    target.mkdir(parents=True, exist_ok=True)
    out = target / "warehouses.jsonl"
    res = _get("warehouses", params={"campaignId": os.environ["YM_CAMPAIGN_ID"]})["result"]
    items = res.get("warehouses", []) if isinstance(res, dict) else res
    with out.open("w", encoding="utf-8") as fh:
        for w in items:
            fh.write(json.dumps({"snapshot_date": run_date, **w}, ensure_ascii=False) + "\n")
    print(f"warehouses: {len(items)} rows → {out}", file=sys.stderr)
    return out


def _paginated_jsonl(path: str, body: dict, out: pathlib.Path, key: str, extra: dict) -> pathlib.Path:
    """POST a paginated JSON endpoint (limit/page_token) and write result[key] items as JSONL."""
    out.parent.mkdir(parents=True, exist_ok=True)
    page_token, n = None, 0
    with out.open("w", encoding="utf-8") as fh:
        while True:
            params = {"limit": 200}
            if page_token:
                params["page_token"] = page_token
            data = _post(path, body, params=params)["result"]
            for item in data.get(key, []):
                fh.write(json.dumps({**extra, **item}, ensure_ascii=False) + "\n")
                n += 1
            page_token = data.get("paging", {}).get("nextPageToken")
            if not page_token:
                break
    print(f"{key}: {n} rows → {out}", file=sys.stderr)
    return out


def offer_mappings(run_date: str) -> pathlib.Path:
    """Catalogue snapshot: one row per offer with its Market category, vendor, dimensions, prices."""
    business = os.environ["YM_BUSINESS_ID"]
    return _paginated_jsonl(f"businesses/{business}/offer-mappings", {},
                            RAW_DIR / "offer_mappings" / run_date / "offer_mappings.jsonl",
                            "offerMappings", {"snapshot_date": run_date})


def orders_stats(date_from: str, date_to: str, run_date: str) -> pathlib.Path:
    """Order history as JSON (POST campaigns/{id}/stats/orders): items, order-level commissions, payments, region.
    Docs state no history limit for this endpoint — use it to reach beyond the 90-day report window."""
    campaign = os.environ["YM_CAMPAIGN_ID"]
    return _paginated_jsonl(f"campaigns/{campaign}/stats/orders", {"dateFrom": date_from, "dateTo": date_to},
                            RAW_DIR / "orders_stats" / run_date / f"{date_from}_{date_to}.jsonl",
                            "orders", {})


def business_orders(date_from: str, date_to: str, run_date: str, window_days: int = 30) -> list[pathlib.Path]:
    """Orders WITH the cancellation reason (POST v1/businesses/{businessId}/orders) — one JSONL per window.

    Why this exists next to orders-stats. `stats/orders` carries neither `substatus` nor a delivery date, so every
    unredeemed parcel arrives as CANCELLED_IN_DELIVERY and "never collected" cannot be told from "refused at the
    counter". This endpoint carries three things that settle it: `substatus` (the reason as the marketplace records
    it), `delivery.dates.realDeliveryDate` (documented as the day the goods reached the PICKUP POINT for self-pickup,
    or the buyer for courier delivery — so its presence proves the parcel arrived), and `cancelRequested` (the buyer
    pressed cancel themselves). Also `delivery.type` (PICKUP / DELIVERY / POST), `delivery.dispatchType` and per-unit
    `items[].itemStatuses`.

    Constraints (checked against the spec and one probe on 2026-09-12):
      * the window is capped at 30 days by creation date and `creationDateTo` is EXCLUSIVE — hence the stepping below;
      * 50 orders per page, forward-scrolling pager (`nextPageToken` → `page_token`), 10 000 responses/hour;
      * the response is a bare {orders, paging} — NOT wrapped in `result` like the v2 endpoints, so this cannot reuse
        _paginated_jsonl;
      * getOrders refuses orders cancelled more than 30 days ago and points here for older ones; the probe confirmed
        this method does serve them (January 2025 returned the same two cancelled orders orders_stats has).
    No status filter on purpose: delivered orders are wanted too, both for `realDeliveryDate` (our sales date is a
    proxy today) and so the reason columns cover the whole order history.
    """
    business = os.environ["YM_BUSINESS_ID"]
    url = f"https://api.partner.market.yandex.ru/v1/businesses/{business}/orders"
    start, end = dt.date.fromisoformat(date_from), dt.date.fromisoformat(date_to)
    out_dir = RAW_DIR / "business_orders" / run_date
    out_dir.mkdir(parents=True, exist_ok=True)
    files: list[pathlib.Path] = []

    while start < end:
        stop = min(start + dt.timedelta(days=window_days), end)          # exclusive upper bound
        out = out_dir / f"{start.isoformat()}_{stop.isoformat()}.jsonl"
        body = {"dates": {"creationDateFrom": start.isoformat(), "creationDateTo": stop.isoformat()}}
        page_token, n, page = None, 0, 0
        with out.open("w", encoding="utf-8") as fh:
            while True:
                params = {"limit": 50}
                if page_token:
                    params["page_token"] = page_token
                data = _check(requests.post(url, headers=HEADERS, json=body, params=params, timeout=60))
                batch = data.get("orders", [])
                for o in batch:
                    fh.write(json.dumps(o, ensure_ascii=False) + "\n")
                    n += 1
                page += 1
                page_token = (data.get("paging") or {}).get("nextPageToken")
                if not page_token or not batch:
                    break
                if page > 60:                                            # ~3 000 orders in one month: not our volume
                    raise RuntimeError(f"{out.name}: more than 60 pages, refusing to loop")
                time.sleep(0.2)
        print(f"business-orders {start}..{stop} (exclusive): {n} orders, {page} page(s) → {out}", file=sys.stderr)
        files.append(out)
        start = stop
    return files


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--report", required=True, choices=["united-orders", "goods-turnover", "stocks", "offer-mappings", "orders-stats",
                                                    "shows-sales", "goods-realization", "stocks-report", "business-orders"])
    ap.add_argument("--step", type=int, default=7, help="stocks-report with --from/--to: days between reportDates")
    ap.add_argument("--from", dest="date_from")
    ap.add_argument("--to", dest="date_to")
    ap.add_argument("--date")
    a = ap.parse_args()
    run_date = dt.date.today().isoformat()

    if a.report == "united-orders":
        if not (a.date_from and a.date_to):
            sys.exit("--from and --to are required (max 1 year per request)")
        files = report_united_orders(a.date_from, a.date_to, run_date)
    elif a.report == "goods-turnover":
        files = report_goods_turnover(a.date or run_date, run_date)
    elif a.report == "shows-sales":
        if not (a.date_from and a.date_to):
            sys.exit("--from and --to are required")
        files = report_shows_sales(a.date_from, a.date_to, run_date)
    elif a.report == "goods-realization":
        if not a.date:
            sys.exit("--date YYYY-MM is required")
        files = report_goods_realization(a.date, run_date)
    elif a.report == "stocks-report":
        if a.date_from and a.date_to:
            files = report_stocks_on_warehouses_range(a.date_from, a.date_to, a.step, run_date)
        elif a.date:
            files = report_stocks_on_warehouses(a.date, run_date)
        else:
            sys.exit("--date YYYY-MM-DD (one reportDate) or --from/--to [--step N] are required")
    elif a.report == "offer-mappings":
        files = [offer_mappings(run_date)]
    elif a.report == "warehouses":
        files = [warehouses_snapshot(run_date)]
    elif a.report == "orders-stats":
        if not (a.date_from and a.date_to):
            sys.exit("--from and --to are required")
        files = [orders_stats(a.date_from, a.date_to, run_date)]
    elif a.report == "business-orders":
        if not (a.date_from and a.date_to):
            sys.exit("--from and --to are required (the API caps one request at 30 days; this steps through them)")
        files = business_orders(a.date_from, a.date_to, run_date)
    else:
        files = [stocks_snapshot(run_date)]
    for f in files:
        print(f)


if __name__ == "__main__":
    main()
