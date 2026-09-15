#!/usr/bin/env bash
# Daily snapshot: catalogue + warehouses + yesterday's stock from the Yandex Market Partner API → data/raw/ → Snowflake RAW.
# Catalogue and warehouses are point-in-time (no history in the API), so their history only exists if we take it
# every day; the stock report has history (reportDate), the daily run just keeps it current.
# Orders are NOT here on purpose: orders-stats has full history and is refreshed by the weekly run.
#
#   bash ingest/daily.sh                 # today's offer-mappings + warehouses + yesterday's stock, then load new files to Snowflake
#   DBT=1 bash ingest/daily.sh           # …and rebuild + test the staging layer afterwards
#
# Scheduled on the laptop by launchd (scripts/launchd/com.marketplace-analytics.daily.plist); logs in logs/daily/.
set -u -o pipefail
cd "$(dirname "$0")/.."                       # repo root: .env, .venv, data/, dbt/
PY="${PYTHON:-.venv/bin/python}"
TODAY=$(date +%F)
mkdir -p logs/daily
LOG="logs/daily/$TODAY.log"
exec >>"$LOG" 2>&1
echo "== $(date '+%F %H:%M:%S') daily start"

set -a; source .env; set +a                   # YM_* and SNOWFLAKE_* for the scripts (and dbt, which reads env_var())

status=0
run() {                                       # run <label> <cmd...>: log, continue on error, remember failure
  echo "-- $(date '+%H:%M:%S') $1"
  if "${@:2}"; then echo "   ok"; else echo "   FAILED (exit $?)"; status=1; fi
}

run "offer-mappings (catalogue snapshot)" "$PY" ingest/yandex_market.py --report offer-mappings
sleep 5
run "warehouses (id ↔ name)"              "$PY" ingest/yandex_market.py --report warehouses
sleep 5
# Stock: the 'stocks-on-warehouses' REPORT; reportDate = D holds the stock at the end of D − 1. Replaced the
# offers/stocks JSON endpoint on 2026-09-14: the report can be requested for any past date, so a missed day is one
# request away, not lost. Hence a 3-day window, not a single date: already-downloaded dates are skipped (normally this
# is ONE request, for today), and a day the report was not ready for at 10:00 MSK (seen 2026-09-15) or a day the job
# did not run at all (2026-09-14) is picked up by the next morning's run. Path: data/raw/stock_reports/.
run "stocks-report (last 3 days, missing only)" "$PY" ingest/yandex_market.py --report stocks-report \
    --from "$(date -v-2d +%F)" --to "$TODAY"
run "load new files to Snowflake RAW"     "$PY" ingest/load_to_snowflake.py

if [[ "${DBT:-0}" == "1" ]]; then
  run "dbt build staging" .venv/bin/dbt build --project-dir dbt --select staging
fi

echo "== $(date '+%F %H:%M:%S') daily end (status $status)"
exit $status
