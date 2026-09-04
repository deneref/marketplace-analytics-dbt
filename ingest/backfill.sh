#!/usr/bin/env bash
# One-off historical backfill from the Yandex Market Partner API into data/raw/.
#
#   bash ingest/backfill.sh            # everything below, in order
#   bash ingest/backfill.sh history    # orders-stats JSON 2025-01-01..today (no 90-day limit) + offer-mappings
#   bash ingest/backfill.sh orders     # united-orders report (fees per order; 90 days without a plan)
#   bash ingest/backfill.sh turnover   # goods-turnover monthly snapshots
#   bash ingest/backfill.sh funnel     # shows-sales, one request for the last 90 days
#   bash ingest/backfill.sh finance    # goods-realization, month by month, newest first
#
# API limits (docs, checked 2026-09-03):
#   united-orders: max 1 year per request. Without a paid analytics plan ("Лайт"/no plan)
#   only the last 90 days are available and only 1 report can generate at a time;
#   goods-turnover is rate-limited to 1 request / 2 min without a plan.
#   So: requests run sequentially, sleep between them, and a failed chunk does NOT stop the run.
set -u -o pipefail
cd "$(dirname "$0")/.."           # repo root, so .env and data/ resolve
PY="${PYTHON:-python}"
SLEEP="${SLEEP:-125}"             # seconds between requests (rate limit is 1 / 2 min)
WHAT="${1:-all}"
TODAY=$(date +%F)
LOG="data/raw/backfill_$TODAY.log"
mkdir -p data/raw

run() {                            # run <label> <args...>: log, continue on error
  echo "== $(date '+%H:%M:%S') $1" | tee -a "$LOG"
  if "$PY" ingest/yandex_market.py "${@:2}" 2>&1 | tee -a "$LOG"; then
    echo "   ok" | tee -a "$LOG"
  else
    echo "   FAILED (likely outside the 90-day window without a plan) — continuing" | tee -a "$LOG"
  fi
  sleep "$SLEEP"
}

if [[ "$WHAT" == "all" || "$WHAT" == "history" ]]; then
  # JSON endpoints: no report queue, no 2-minute limit — short pauses only.
  SAVE_SLEEP=$SLEEP; SLEEP=5
  run "offer-mappings (catalogue)" --report offer-mappings
  q_from=2025-01-01
  while [[ "$q_from" < "$TODAY" ]]; do
    q_to=$("$PY" -c "import datetime as d; f=d.date.fromisoformat('$q_from'); m=f.month+2; y=f.year+(m>12); m=m-12 if m>12 else m; import calendar; print(min(d.date(y,m,calendar.monthrange(y,m)[1]), d.date.fromisoformat('$TODAY')))")
    run "orders-stats $q_from..$q_to" --report orders-stats --from "$q_from" --to "$q_to"
    q_from=$("$PY" -c "import datetime as d; print(d.date.fromisoformat('$q_to')+d.timedelta(days=1))")
  done
  SLEEP=$SAVE_SLEEP
fi

if [[ "$WHAT" == "all" || "$WHAT" == "orders" ]]; then
  # Half-year chunks: well under the 1-year cap and small enough to download comfortably.
  run "orders 2025 H1"  --report united-orders --from 2025-01-01 --to 2025-06-30
  run "orders 2025 H2"  --report united-orders --from 2025-07-01 --to 2025-12-31
  run "orders 2026 YTD" --report united-orders --from 2026-01-01 --to "$TODAY"
fi

if [[ "$WHAT" == "all" || "$WHAT" == "turnover" ]]; then
  # Turnover is a point-in-time report: one snapshot per month, taken on the last day of the month.
  # Newest first, so that the months most likely to be available land before any 90-day failures.
  for ym in 2026-08 2026-07 2026-06 2026-05 2026-04 2026-03 2026-02 2026-01 \
            2025-12 2025-11 2025-10 2025-09 2025-08 2025-07 2025-06 2025-05 2025-04 2025-03 2025-02 2025-01; do
    last=$("$PY" -c "import calendar,sys; y,m=map(int,'$ym'.split('-')); print(f'{y}-{m:02d}-{calendar.monthrange(y,m)[1]}')")
    run "turnover $last" --report goods-turnover --date "$last"
  done
  run "turnover today ($TODAY)" --report goods-turnover --date "$TODAY"
fi

if [[ "$WHAT" == "all" || "$WHAT" == "funnel" ]]; then
  from90=$("$PY" -c "import datetime as d; print(d.date.fromisoformat('$TODAY')-d.timedelta(days=89))")
  run "shows-sales $from90..$TODAY" --report shows-sales --from "$from90" --to "$TODAY"
fi

if [[ "$WHAT" == "all" || "$WHAT" == "finance" ]]; then
  # Monthly financial report; docs mention no 90-day limit — newest first, stops being useful once months start failing.
  for ym in 2026-08 2026-07 2026-06 2026-05 2026-04 2026-03 2026-02 2026-01 \
            2025-12 2025-11 2025-10 2025-09 2025-08 2025-07 2025-06 2025-05 2025-04 2025-03 2025-02 2025-01; do
    run "goods-realization $ym" --report goods-realization --date "$ym"
  done
fi

echo "== done; files:" | tee -a "$LOG"
find data/raw -type f ! -name '*.log' ! -name '.DS_Store' | sort | tee -a "$LOG"
