#!/usr/bin/env bash
# Daily snapshot: catalogue + stocks from the Yandex Market Partner API → data/raw/ → Snowflake RAW.
# These two endpoints are point-in-time (no history in the API), so their history only exists if we take it
# every day. Orders are NOT here on purpose: orders-stats has full history and is refreshed by the weekly run.
#
#   bash ingest/daily.sh                 # today's offer-mappings + stocks, then load new files to Snowflake
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
run "stocks (stock snapshot)"             "$PY" ingest/yandex_market.py --report stocks
run "load new files to Snowflake RAW"     "$PY" ingest/load_to_snowflake.py

if [[ "${DBT:-0}" == "1" ]]; then
  run "dbt build staging" .venv/bin/dbt build --project-dir dbt --select staging
fi

echo "== $(date '+%F %H:%M:%S') daily end (status $status)"
exit $status
