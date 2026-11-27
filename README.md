# Market alerts

## Runs in the cloud (GitHub Actions), PC on or off
- **Dashboard:** https://sudanosuprano.github.io/market-alerts/ (add it to your phone's home screen)
- **Jobs** (`.github/workflows/`): news watcher about every 10 min · dashboard data hourly · week-ahead report Sunday 07:00 UTC (6pm Sydney in summer) · daily heads-up 21:00 UTC Sun–Thu (8am Sydney Mon–Fri in summer) · "Send test push" (run it by hand from the Actions tab).
- **Secrets** (repo Settings → Secrets → Actions): `NTFY_TOPIC` (your ntfy channel) and `CLAUDE_CODE_OAUTH_TOKEN` (from `claude setup-token`, valid about a year; rerun it and `gh secret set CLAUDE_CODE_OAUTH_TOKEN` when it expires).
- **Fed rate card** (top of the dashboard): the current target range from the New York Fed's official feed (refreshed every 6h) and the next FOMC decision from the list in `common.ps1`. Add the next year's meeting dates to that list when the Fed publishes them. The "market pricing" line comes from `data/fed-outlook.json`, which the Sunday task writes.
- Cloud jobs commit their results (data/, docs/, reports/), so run `git pull` before changing files here.
- The PC versions below are switched off (Windows tasks disabled, Claude app tasks paused) to avoid duplicate alerts. They still work if you turn them back on.

## Original PC setup

Pushes market news to your phone through the free **ntfy** app.

| What | When | How it runs |
|---|---|---|
| Breaking news (Bloomberg, CNBC, WSJ, FT, MarketWatch, Fed), filtered to market-moving only | Every 5 min while you're logged in to the PC | Windows Task Scheduler: `SUDDY News Watcher` → `news-watch.ps1` |
| Week-ahead report: red folder, earnings, OPEX, holidays | Sunday ~6pm | Claude scheduled task `suddy-weekly-market-report` (Claude app must be open) |
| Daily heads-up: next 24h | Weekdays ~8am | Claude scheduled task `suddy-daily-market-headsup` (Claude app must be open) |

| Dashboard: the whole week in one browser tab | Calendar refreshes hourly, news every 5 min, page reloads itself every 5 min | `dashboard.html`. Open it in your browser and pin the tab |

## Dashboard
Open `dashboard.html` (double-click it) and pin the tab or bookmark it. It shows Mon–Fri of the current NY trading week: red folder events (Sydney time, with NY time and session), earnings (gold = Mag 7, gold outline = Nasdaq-100 heavyweights), OPEX, quad witching and roll badges, holidays, breaking news and upcoming Mag 7 earnings. Below the current week, **Next 4 weeks** folds open week by week: big US releases (from `data\future-events.json`, which the Sunday task updates from official BLS/BEA/Fed schedules), earnings, OPEX, quad witching, roll dates and holidays (`gather-ahead.ps1`). Shared lists (NYSE holidays, Mag 7, OPEX rules) live in `common.ps1`. To rebuild it by hand: `.\build-dashboard.ps1 -Refresh`. Change the look in `dashboard-template.html`.

## Phone setup
1. Install **ntfy** (App Store or Play Store).
2. Tap **+**, subscribe to the topic in `config.json` (`topic`), server `ntfy.sh`.
3. Keep that name private. Anyone who has it can read your alerts.

## Turn on the AI news filter (one-time)
Without it the watcher uses a strict keyword filter that misses a lot. To enable the AI filter, install Claude Code and log in once:
```powershell
irm https://claude.ai/install.ps1 | iex
```
Then open a new terminal, run `claude`, and log in. The watcher then uses Haiku to score each new headline 1–10 for NQ/ES impact and pushes anything scoring 8 or higher (9 or higher arrives as high priority).

## Files
- `gather-data.ps1`: calendar data (ForexFactory feed, Nasdaq earnings, Nager.Date holidays, OPEX). The NYSE holiday list inside it runs to the end of 2027.
- `news-watch.ps1`: the watcher. Change `-MinScore` to get more or fewer alerts. `-DryRun` scores headlines without pushing.
- `send-ntfy.ps1`: sends a push.
- `reports\`: weekly and daily reports. `data\news-log.txt`: every alert, with its link.

Remove the watcher: `Unregister-ScheduledTask -TaskName 'SUDDY News Watcher' -Confirm:$false`
