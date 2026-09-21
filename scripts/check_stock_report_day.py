"""Which day does the stocks-on-warehouses report describe?  (2026-09-15)

Runs on local RAW only (data/raw/stock_reports, orders_stats, business_orders), no Snowflake.
Answers three questions:
  1. gaps: which reportDates between the first and the last download are missing;
  2. offset: an order placed on day D moves AVAILABLE → RESERVED — in the report of WHICH reportDate does it show?
     (found: reportDate = D, i.e. the report is the stock at the END of reportDate, not the day before as the API docs say);
  3. rule check: with snapshot_date = reportDate, AVAILABLE in the report of D−1 covers the units ordered on D in 97 %.

    python scripts/check_stock_report_day.py
"""
import glob, json, pathlib, sys
from datetime import timedelta
import numpy as np, pandas as pd

RAW = pathlib.Path(__file__).resolve().parents[1] / "data" / "raw"
K = {"K1": "CAP-Bur-007", "K2": "CAP-Gr-007", "K3": "CAP-Gr-006", "K4": "CAP-Bur-006", "K5": "CAP-Bg-006"}  # caps: warehouse label → sku
BUCKETS = ["VALID", "RESERVED", "AVAILABLE_FOR_ORDER", "QUARANTINE", "UTILIZATION", "DEFECT", "EXPIRED"]


def load_stock() -> pd.DataFrame:
    frames = []
    for f in sorted(glob.glob(str(RAW / "stock_reports" / "*" / "*" / "stocks_on_warehouses.csv"))):
        df = pd.read_csv(f, dtype=str)
        df["run_date"], df["report_date"] = f.split("/")[-3], f.split("/")[-2]
        frames.append(df)
    st = pd.concat(frames, ignore_index=True)
    for c in BUCKETS:
        st[c] = pd.to_numeric(st[c], errors="coerce").fillna(0).astype(int)
    st = st.sort_values("run_date").drop_duplicates(["report_date", "SHOP_SKU", "WAREHOUSE"], keep="last")
    st["report_date"] = pd.to_datetime(st["report_date"])
    st["sku"] = st.SHOP_SKU.map(lambda s: K.get(s, s))
    print(f"stock report: {len(frames)} files, {st.report_date.nunique()} reportDates, {len(st)} rows after dedupe")
    return st


def load_orders() -> pd.DataFrame:
    rows = []
    for f in sorted(glob.glob(str(RAW / "orders_stats" / "*" / "*.jsonl"))):
        for line in open(f):
            o = json.loads(line)
            if o.get("fake"):
                continue
            for it in o["items"]:
                rows.append(dict(order_id=o["id"], order_date=o["creationDate"], sku=it["shopSku"], units=it["count"], run=f.split("/")[-2]))
    od = pd.DataFrame(rows).sort_values("run").drop_duplicates(["order_id", "sku"], keep="last")
    od["order_date"] = pd.to_datetime(od.order_date)
    print(f"orders_stats: {len(od)} lines, {od.order_id.nunique()} orders, {od.order_date.min().date()} … {od.order_date.max().date()}")
    return od


def gaps(st: pd.DataFrame) -> None:
    days = sorted(st.report_date.dt.date.unique())
    missing = sorted(set(days[0] + timedelta(d) for d in range((days[-1] - days[0]).days + 1)) - set(days))
    runs: list[list] = []
    for d in missing:
        if runs and (d - runs[-1][1]).days == 1:
            runs[-1][1] = d
        else:
            runs.append([d, d])
    print(f"\n[1] reportDate {days[0]} … {days[-1]}: {len(days)} present, {len(missing)} missing:",
          [(str(a), str(b), (b - a).days + 1) for a, b in runs])
    per_day = st.groupby("report_date").size()
    zero = st[BUCKETS].sum(axis=1) == 0
    print(f"    rows/day min {per_day.min()} median {int(per_day.median())} max {per_day.max()}; all-zero rows {zero.mean():.0%}")


def offset(st: pd.DataFrame, od: pd.DataFrame) -> pd.DataFrame:
    sk = st.groupby(["sku", "report_date"]).agg(avail=("AVAILABLE_FOR_ORDER", "sum"), res=("RESERVED", "sum"), fit=("VALID", "sum")).reset_index()
    sk = sk.sort_values("report_date")
    g = sk.groupby("sku")
    sk["prev"] = g.report_date.shift(1)
    for c in ["res", "avail", "fit"]:
        sk["d_" + c] = sk[c] - g[c].shift(1)
    sk = sk[(sk.report_date - sk.prev).dt.days == 1]                     # consecutive reportDates only
    ou = od.groupby(["sku", "order_date"]).units.sum().reset_index()
    print("\n[2] an order placed on day D shows up in the report of which reportDate?")
    print(f"    {'reportDate':<12}{'order-days':>11}{'Δavail<0':>10}{'Δres>0':>8}{'pure days':>11}{'Δres==units':>13}")
    for off in range(-2, 3):
        m = sk.merge(ou.assign(report_date=ou.order_date + pd.Timedelta(days=off)), on=["sku", "report_date"])
        pure = m[m.d_fit == 0]
        print(f"    {'D' + format(off, '+d'):<12}{len(m):>11}{(m.d_avail < 0).mean():>10.0%}{(m.d_res > 0).mean():>8.0%}{len(pure):>11}{(pure.d_res == pure.units).mean():>13.0%}")
    base = sk.merge(ou, left_on=["sku", "report_date"], right_on=["sku", "order_date"], how="left")
    base = base[base.units.isna()]
    print(f"    baseline, days without an order for the sku (n={len(base)}): Δavail<0 {(base.d_avail < 0).mean():.1%}, Δres>0 {(base.d_res > 0).mean():.1%}")
    return sk


def rule_check(st: pd.DataFrame, od: pd.DataFrame) -> None:
    sk = st.groupby(["sku", "report_date"]).agg(avail=("AVAILABLE_FOR_ORDER", "sum"), fit=("VALID", "sum"))
    days = set(sk.index.get_level_values(1))

    def look(sku, d, col):
        d = pd.Timestamp(d)
        if d not in days:
            return np.nan                                                # no report that day → unknown
        return sk[col].get((sku, d), 0)                                  # report exists, sku absent → 0

    print("\n[3] rule 'stock before an order on D = report of D−1' (snapshot_date = reportDate):")
    for lag, label in [(1, "report D−1 (new rule)"), (0, "report D (old rule's 'day before')")]:
        a = od.apply(lambda r: look(r.sku, r.order_date - pd.Timedelta(days=lag), "avail"), axis=1)
        known = a.notna()
        viol = od[known & (a < od.units)]
        extra = ""
        if lag == 1:
            fit_b = viol.apply(lambda r: look(r.sku, r.order_date - pd.Timedelta(days=1), "fit"), axis=1)
            fit_d = viol.apply(lambda r: look(r.sku, r.order_date, "fit"), axis=1)
            extra = f"; of which FIT grew on D (same-day inflow) {int((fit_d > fit_b).sum())}, sku not listed on D−1 (launch) {int((fit_b == 0).sum())}"
        print(f"    {label}: avail < units in {len(viol)} of {int(known.sum())} lines ({len(viol) / known.sum():.1%}){extra}")


if __name__ == "__main__":
    st, od = load_stock(), load_orders()
    gaps(st)
    offset(st, od)
    rule_check(st, od)
