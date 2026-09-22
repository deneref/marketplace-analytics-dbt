# Daily snapshot on the laptop (launchd)

`ingest/daily.sh` fetches today's catalogue (`offer-mappings`) and the warehouse list, requests the stock report
(`stocks-report`) for any of the last three closed days that are still missing, and loads the new files into
Snowflake RAW. launchd, the macOS scheduler, runs it every day at 09:15 local time. If the laptop was asleep, the
job runs when it wakes up; cron would skip it.

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

Set `DBT` to `1` in the plist's `EnvironmentVariables` to rebuild and test the staging layer after each load.

## Why not cron or GitHub Actions

cron on macOS skips runs while the laptop sleeps, and launchd catches up. GitHub Actions is where a production
schedule would go. It needs the API key and the Snowflake key in repository secrets, and it runs whether the laptop
is open or not. The script would stay the same.
