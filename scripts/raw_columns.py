"""
List the columns every RAW table gets from ingest/load_to_snowflake.py, using only the local files in data/raw/
(no warehouse needed). Same naming rules as the loader: CSV headers / JSONL keys → [A-Z0-9_], upper-case,
plus _LOADED_AT, _SOURCE_FILE and (JSONL) _RAW_JSON.

Usage:
  python scripts/raw_columns.py                 # JSON {TABLE: [columns…]} to stdout
  python scripts/raw_columns.py --check dbt/models/staging/yandex_market/_ym__sources.yml
                                                # compare with the source yaml: missing / extra columns per table
"""
from __future__ import annotations

import json
import pathlib
import re
import sys

RAW_DIR = pathlib.Path(__file__).resolve().parents[1] / "data" / "raw"


def table_name(report_dir: str, file: pathlib.Path) -> str:
    """Mirror of ingest/load_to_snowflake.table_name (not imported: that module needs pandas + snowflake)."""
    if file.suffix == ".jsonl":
        return report_dir.upper()
    sheet = re.sub(r"[^a-z0-9]+", "_", file.stem.lower()).strip("_")
    return f"{report_dir}_{sheet}".upper()


def norm(c: str) -> str:
    return re.sub(r"[^A-Za-z0-9]+", "_", c).strip("_").upper()


def raw_columns() -> dict[str, list[str]]:
    cols: dict[str, dict[str, None]] = {}
    for f in sorted(p for p in RAW_DIR.rglob("*") if p.suffix in (".csv", ".jsonl")):
        tbl = table_name(f.relative_to(RAW_DIR).parts[0], f)
        found = cols.setdefault(tbl, {})
        if f.suffix == ".jsonl":
            keys: set[str] = set()
            with f.open(encoding="utf-8") as fh:
                for line in fh:
                    if line.strip():
                        keys.update(json.loads(line).keys())
            for k in sorted(keys):
                found[norm(k)] = None
            found["_RAW_JSON"] = None
        else:
            with f.open(encoding="utf-8") as fh:
                header = fh.readline().rstrip("\n")
            sep = ";" if header.count(";") > header.count(",") else ","
            for c in header.split(sep):
                if c:
                    found[norm(c)] = None
        found["_LOADED_AT"] = None
        found["_SOURCE_FILE"] = None
    return {t: list(c) for t, c in cols.items()}


def check(yaml_path: pathlib.Path, cols: dict[str, list[str]]) -> int:
    import yaml

    src = yaml.safe_load(yaml_path.read_text(encoding="utf-8"))
    tables = {t["identifier"].upper(): [c["name"].upper() for c in t.get("columns", [])]
              for s in src["sources"] for t in s["tables"]}
    rc = 0
    for tbl, real in cols.items():
        if tbl not in tables:
            print(f"{tbl}: not in yaml")
            rc = 1
            continue
        missing = [c for c in real if c not in tables[tbl]]
        extra = [c for c in tables[tbl] if c not in real]
        if missing or extra:
            rc = 1
        print(f"{tbl}: {len(real)} columns in data, {len(tables[tbl])} in yaml"
              + (f"; missing in yaml: {missing}" if missing else "")
              + (f"; not in data: {extra}" if extra else ""))
    for tbl in tables:
        if tbl not in cols:
            print(f"{tbl}: in yaml but no local data")
    return rc


if __name__ == "__main__":
    cols = raw_columns()
    if len(sys.argv) > 2 and sys.argv[1] == "--check":
        sys.exit(check(pathlib.Path(sys.argv[2]), cols))
    print(json.dumps(cols, ensure_ascii=False, indent=2))
