"""
Yandex Market Partner API → local CSV files.

Report flow (documented by Yandex): POST .../generate → GET v2/reports/info/{reportId} until DONE →
download the file (link is valid for 60 minutes) → unzip CSV sheets into data/raw/<report>/<run_date>/.

Usage:
  python ingest/yandex_market.py --report united-orders --from 2025-01-01 --to 2025-12-31
  python ingest/yandex_market.py --report goods-turnover --date 2026-09-06
  python ingest/yandex_market.py --report stocks           # JSON endpoint, not a report
  python ingest/yandex_market.py --report offer-mappings   # catalogue: category, vendor, dimensions, prices (JSON)
  python ingest/yandex_market.py --report orders-stats --from 2025-01-01 --to 2025-06-30   # order history (JSON)
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
    content = requests.get(url, timeout=300).content
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


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--report", required=True, choices=["united-orders", "goods-turnover", "stocks", "offer-mappings", "orders-stats",
                                                    "shows-sales", "goods-realization"])
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
    elif a.report == "offer-mappings":
        files = [offer_mappings(run_date)]
    elif a.report == "orders-stats":
        if not (a.date_from and a.date_to):
            sys.exit("--from and --to are required")
        files = [orders_stats(a.date_from, a.date_to, run_date)]
    else:
        files = [stocks_snapshot(run_date)]
    for f in files:
        print(f)


if __name__ == "__main__":
    main()
