You are building a week-ahead market report for the coming US trading week and pushing it to the trader's phone. The trader is in Sydney (time zone Australia/Sydney). They analyse NQ, compare with ES, execute on MNQ, use a 4-hour PO3 strategy, and trade mainly the Asia and New York open sessions. They also use this report to prep a Sunday weekly-analysis video.

You are running on a GitHub Actions Linux runner in the repository root. Use `pwsh` to run the PowerShell scripts. The environment already has SUDDY_TZ, NTFY_TOPIC and the Claude token set. Never print or write the value of NTFY_TOPIC anywhere: this repository is public.

Steps:
1. Run: pwsh ./gather-data.ps1 -Mode weekly
   It prints a data pack (also saved to data/weekly-data.md): ForexFactory high-impact (red folder) events with Sydney and NY times; earnings tagged MAG7 (Magnificent 7) and NQ (other Nasdaq-100 heavyweights) plus any $50B+ company; upcoming Mag 7 earnings dates for the next 9 weeks; OPEX (3rd-Friday monthly OPEX, quarterly quad witching, ES/NQ roll date); US market closures and early closes; US and AU public holidays; and a Warnings section.
2. Fix gaps from the Warnings section with web searches:
   - FF_STALE or FF_ERROR: find the week's high-impact USD events (CPI, PPI, NFP, FOMC, Fed chair speeches, GDP, PCE, retail sales, ISM, JOLTS, jobless claims if flagged high, etc.) plus other high-impact currencies, with times. Convert to Sydney time and note them as "from web search, verify on ForexFactory".
   - EARNINGS_ERROR: search for the week's major earnings.
   - NYSE_LIST_OUTDATED: check nyse.com holidays and say in the report that common.ps1 needs updating.
3. Do 2-4 quick web searches for context: the biggest market-moving stories of the past week, and anything scheduled this week that isn't on the economic calendar (Fed speakers, FOMC blackout period, Treasury auctions, tariff deadlines, elections, big product events, index rebalances, VIX expiry). Only keep what plausibly moves NQ/ES. If the Mag 7 look-ahead is empty but earnings season is near, search for confirmed Mag 7 dates.
4. Update data/future-events.json, the dashboard's look-ahead list of major scheduled US releases for the next 5 weeks (from this coming Monday). Read the current file first and keep its exact JSON format:
   {"updated":"YYYY-MM-DD","note":"...","events":[{"date":"YYYY-MM-DD","timeET":"HH:MM" (24h New York time),"title":"...","impact":"High","status":"confirmed" or "verify","source":"..."}]}
   Cover: Non-Farm Payrolls, CPI, PPI, FOMC decisions (and minutes), Core PCE, GDP, retail sales, ISM manufacturing and services, JOLTS, and the Fed chair's scheduled testimony or major speeches. Check each against official schedules (bls.gov, bea.gov, census.gov, federalreserve.gov, ismworld.org). Use "confirmed" only when an official schedule gives the date, otherwise "verify". Remove dates that have passed, fix any that changed, set "updated" to today's date, and write valid UTF-8 JSON.
5. Write the full report in markdown to reports/<Monday date YYYY-MM-DD>-weekly.md with these sections:
   - Headline: one or two sentences on the week's biggest risk events.
   - Day-by-day calendar (Mon-Fri): every red-folder event with Sydney time first and NY time in brackets. Mark which ones land in the Asia session or around the NY open (9:30am ET). Then earnings for that day: before-open and after-close names, Mag 7 first in bold, then NQ heavyweights.
   - OPEX and expiries: whether this is OPEX week (3rd Friday), quad witching (Mar/Jun/Sep/Dec), the ES/NQ roll date, and the next OPEX date if none this week.
   - Further ahead: the big releases from future-events.json for the following 4 weeks, and Mag 7 earnings coming up.
   - Holidays and session changes: US market closures and early closes, US bank holidays, Australian public holidays (national ones, plus NSW and VIC state ones labelled as such).
   - Last week in 5 bullets, then what to watch this week.
   - Footer: "Not financial advice. Calendar data: ForexFactory, Nasdaq, Nager.Date, BLS/BEA/Federal Reserve schedules."
   Keep it factual. No trade calls, no directional predictions presented as advice, no hype.
6. Write a phone version as plain text (no markdown, no tables) to reports/<same date>-weekly-phone.txt, under 3,500 bytes. Format: one line per day such as "TUE: 12:30am CPI (8:30a ET) | AMC: *NVDA, CRM", then lines for OPEX/roll and holidays, then the top 2-3 things to watch. Sydney times. Mark Mag 7 with *.
7. Send it: pwsh ./send-ntfy.ps1 -Title "Week ahead: <Mon date e.g. 30 Nov>" -File reports/<same date>-weekly-phone.txt -Priority default -Tags calendar
8. Rebuild the dashboard: pwsh ./build-dashboard.ps1 -Refresh
9. Finish with a short summary: files written, whether the push sent, what changed in future-events.json, and anything you filled in by web search. Don't commit; the workflow does that.
If the push fails, say so clearly and don't retry more than twice.
