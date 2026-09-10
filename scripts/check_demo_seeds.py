#!/usr/bin/env python3
"""Which sources still have no synthetic stand-in.

`macros/source_or_seed.sql` swaps every source for a seed named demo_<table> when the project runs with
--vars '{"use_demo_seeds": true}'. A source without its seed is not a warning inside dbt — it is a parse
error that stops the whole build, so this script lists the gap before dbt ever runs.

Reports, never fails: while seeds_gen/generate_demo_seeds.py is unfinished the gap is expected, and a red
cross on every push says nothing new. Turn `MISSING_IS_AN_ERROR` on (or just run
`dbt parse --vars '{"use_demo_seeds": true}'` in CI again) once the generator covers every source.

Run locally: python3 scripts/check_demo_seeds.py
"""
from __future__ import annotations

import os
import pathlib
import re
import sys

MISSING_IS_AN_ERROR = False

ROOT = pathlib.Path(__file__).resolve().parents[1]
MODELS = ROOT / "dbt" / "models"
SEEDS = ROOT / "dbt" / "seeds"

CALL = re.compile(r"source_or_seed\(\s*'([^']+)'")


def main() -> int:
    wanted: dict[str, list[str]] = {}
    for sql in sorted(MODELS.rglob("*.sql")):
        for table in CALL.findall(sql.read_text(encoding="utf-8")):
            wanted.setdefault(table, []).append(sql.relative_to(ROOT).as_posix())

    have = {p.stem[len("demo_"):] for p in SEEDS.glob("demo_*.csv")}
    missing = {t: m for t, m in sorted(wanted.items()) if t not in have}

    lines = [f"Sources behind `source_or_seed()`: {len(wanted)} — demo seeds present: {len(wanted) - len(missing)}"]
    if missing:
        lines += ["", "| missing seed | needed by |", "| --- | --- |"]
        lines += [f"| `demo_{t}.csv` | {', '.join(sorted({pathlib.PurePath(p).stem for p in m}))} |"
                  for t, m in missing.items()]
        lines += ["", "Written by `seeds_gen/generate_demo_seeds.py`. Until every source has one,",
                  "`dbt build --vars '{\"use_demo_seeds\": true}'` cannot parse the project."]
    else:
        lines += ["", "Every source has a demo seed — the demo path can be built and tested in CI.",
                  "Time to make it blocking: see the comment in `.github/workflows/dbt_ci.yml`."]

    report = "\n".join(lines)
    print(report)

    summary = os.environ.get("GITHUB_STEP_SUMMARY")
    if summary:
        with open(summary, "a", encoding="utf-8") as fh:
            fh.write("## Demo seeds\n\n" + report + "\n")
    if missing and os.environ.get("GITHUB_ACTIONS"):
        names = ", ".join(f"demo_{t}" for t in missing)
        print(f"::notice title=Demo seeds missing ({len(missing)})::{names}")

    return 1 if (missing and MISSING_IS_AN_ERROR) else 0


if __name__ == "__main__":
    sys.exit(main())
