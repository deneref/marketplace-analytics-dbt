# Daily snapshot on the laptop (launchd)

`ingest/daily.sh` takes today's catalogue (`offer-mappings`) and stock (`stocks`) snapshots and loads new files
into Snowflake RAW. launchd (macOS's scheduler) runs it every day at 09:15 local time; if the laptop was asleep,
the job runs at the next wake — cron would just skip it.

## Install (once)

```bash
cd "<repo root>"
sed "s|__REPO__|$(pwd)|g" scripts/launchd/com.marketplace-analytics.daily.plist \
  > ~/Library/LaunchAgents/com.marketplace-analytics.daily.plist
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.marketplace-analytics.daily.plist
launchctl kickstart -k gui/$(id -u)/com.marketplace-analytics.daily     # run it right now to check
tail -f logs/daily/$(date +%F).log
```

## Operate

```bash
launchctl print gui/$(id -u)/com.marketplace-analytics.daily | head -20   # state, last exit code
launchctl kickstart -k gui/$(id -u)/com.marketplace-analytics.daily      # run now
launchctl bootout gui/$(id -u)/com.marketplace-analytics.daily           # uninstall
```

Set `DBT` to `1` in the plist's `EnvironmentVariables` to also rebuild and test the staging layer after the load.

## Why not cron / GitHub Actions

- cron on macOS skips runs while the laptop sleeps; launchd catches up.
- GitHub Actions is the target for the "real" schedule (weekend 2 in the plan): it needs the API key and the
  Snowflake key in repository secrets and runs whether the laptop is open or not. The script is the same.
