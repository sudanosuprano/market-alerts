You are sending the trader's daily market heads-up to their phone. The trader is in Sydney (time zone Australia/Sydney) and trades NQ/MNQ (compares with ES), mainly in the Asia session and around the New York open (9:30am ET, the middle of the night in Sydney). The heads-up covers the NY TRADING DAY, not the Sydney calendar day: from the futures open at 6pm ET the evening before (covers the Asia session) to the 5pm ET close.

You are running on a GitHub Actions Linux runner in the repository root. Use `pwsh` to run the PowerShell scripts. Never print or write the value of NTFY_TOPIC anywhere: this repository is public.

Steps:
1. Run: pwsh ./gather-data.ps1 -Mode daily
   It prints that trading day's ForexFactory high-impact (red folder) events in Sydney and NY time, earnings (MAG7 = Magnificent 7, NQ = other Nasdaq-100 heavyweights, plus any $50B+ company), last night's after-close reports, OPEX (monthly OPEX week, 3rd-Friday expiry, quarterly quad witching, ES/NQ roll date), closures and early closes, holidays, and Warnings.
2. If Warnings show FF_STALE or FF_ERROR, do one or two web searches for that day's high-impact US economic events and times instead; data/future-events.json may also list them. If EARNINGS_ERROR, search for that day's major earnings.
3. Read data/news-log.txt (timestamps are Sydney time) and pick out ALERT lines from the last 24 hours. Mention at most the top 3 in one line each as "Overnight:".
4. Write a short plain-text message (no markdown, under 1,500 bytes) to reports/<NY trading day YYYY-MM-DD>-daily-phone.txt:
   Line 1: the single biggest thing that day, or "Quiet day: no red folder events".
   Then one line per red-folder event: "<Sydney time> <event> (<NY time>) fcst X prev Y".
   Then "Earnings:" with Mag 7 first marked with *, then NQ heavyweights, then others, each with before open / after close. Include last night's after-close Mag 7/NQ reporters as "Reported last night:".
   Then OPEX lines (OPEX week, OPEX day, quad witching, roll date), early close or holiday lines only if they apply.
   Then "Overnight:" lines if any.
   Facts only. No trade calls or predictions.
5. Send it: pwsh ./send-ntfy.ps1 -Title "Today: <ddd d MMM of the NY trading day>" -File reports/<that file> -Priority default -Tags sunrise
   Use -Priority high instead if there's a high-impact USD event (CPI, NFP, FOMC, PCE, GDP), a Mag 7 report, OPEX day, quad witching, a roll date or an early close.
6. Rebuild the dashboard: pwsh ./build-dashboard.ps1 -Refresh
7. Finish with a one-line summary saying whether the push sent. Don't commit; the workflow does that.
