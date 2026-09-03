"""
Load raw CSV / JSONL files from data/raw/ into Snowflake schema RAW, one table per report sheet.

Design choice: the raw layer keeps every column as VARCHAR plus _loaded_at and _source_file.
Typing, renaming, and de-duplication belong to dbt staging models — so a load can always be replayed.

Usage:
  python ingest/load_to_snowflake.py            # loads everything under data/raw not yet loaded
  python ingest/load_to_snowflake.py --reload   # truncates and reloads all

Env (.env): SNOWFLAKE_ACCOUNT, SNOWFLAKE_USER, SNOWFLAKE_PASSWORD, SNOWFLAKE_WAREHOUSE=dbt_wh,
            SNOWFLAKE_DATABASE=marketplace, SNOWFLAKE_RAW_SCHEMA=raw
"""
from __future__ import annotations

import argparse
import datetime as dt
import os
import pathlib
import re

import pandas as pd
import snowflake.connector
from dotenv import load_dotenv
from snowflake.connector.pandas_tools import write_pandas

load_dotenv()
RAW_DIR = pathlib.Path(__file__).resolve().parents[1] / "data" / "raw"
MANIFEST = RAW_DIR / "_loaded.txt"      # one loaded file path per line (git-ignored with data/)


def table_name(report_dir: str, file: pathlib.Path) -> str:
    """united_orders/<run>/<period>/Orders.csv → UNITED_ORDERS_ORDERS ; stock_snapshots/.../stocks.jsonl → STOCK_SNAPSHOTS"""
    sheet = re.sub(r"[^a-z0-9]+", "_", file.stem.lower()).strip("_")
    if report_dir == "stock_snapshots":
        return "STOCK_SNAPSHOTS"
    return f"{report_dir}_{sheet}".upper()


def read_any(file: pathlib.Path) -> pd.DataFrame:
    if file.suffix == ".jsonl":
        df = pd.read_json(file, lines=True, dtype=str)
    else:
        df = pd.read_csv(file, dtype=str, sep=None, engine="python")   # sep=None: sniff ',' vs ';'
    df.columns = [re.sub(r"[^A-Za-z0-9]+", "_", c).strip("_").upper() for c in df.columns]
    df["_LOADED_AT"] = dt.datetime.now(dt.timezone.utc).isoformat()
    df["_SOURCE_FILE"] = str(file.relative_to(RAW_DIR))
    return df.astype(str)


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--reload", action="store_true")
    a = ap.parse_args()

    loaded = set(MANIFEST.read_text().splitlines()) if MANIFEST.exists() and not a.reload else set()
    conn = snowflake.connector.connect(
        account=os.environ["SNOWFLAKE_ACCOUNT"], user=os.environ["SNOWFLAKE_USER"],
        password=os.environ["SNOWFLAKE_PASSWORD"], warehouse=os.environ.get("SNOWFLAKE_WAREHOUSE", "DBT_WH"),
        database=os.environ.get("SNOWFLAKE_DATABASE", "MARKETPLACE"), schema=os.environ.get("SNOWFLAKE_RAW_SCHEMA", "RAW"),
    )
    truncated: set[str] = set()
    files = sorted(p for p in RAW_DIR.rglob("*") if p.suffix in (".csv", ".jsonl"))
    for f in files:
        rel = str(f.relative_to(RAW_DIR))
        if rel in loaded:
            continue
        report_dir = f.relative_to(RAW_DIR).parts[0]
        tbl = table_name(report_dir, f)
        df = read_any(f)
        if a.reload and tbl not in truncated:
            conn.cursor().execute(f"create or replace table {tbl} ({', '.join(f'{c} varchar' for c in df.columns)})")
            truncated.add(tbl)
        ok, _, nrows, _ = write_pandas(conn, df, tbl, auto_create_table=True, overwrite=False, quote_identifiers=False)
        print(f"{rel} → {tbl}: {nrows} rows, ok={ok}")
        loaded.add(rel)
    MANIFEST.write_text("\n".join(sorted(loaded)))
    conn.close()


if __name__ == "__main__":
    main()
