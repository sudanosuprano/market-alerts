<#
  Breaking-news watcher. Run every few minutes (Windows Task Scheduler does this, see install-watcher.ps1).
  1. Pulls headlines from Bloomberg, CNBC, MarketWatch, WSJ, FT and the Fed (free RSS feeds).
  2. Keeps only headlines it hasn't seen before.
  3. Asks Claude (Haiku, headless Claude Code) to score each one for impact on NQ/ES.
     If Claude Code isn't logged in, it falls back to a strict keyword filter.
  4. Pushes anything scoring >= MinScore to your phone through ntfy.
  Log: data\news-log.txt.   State: data\seen.json, data\alerted.json
#>
param(
  [int]$MinScore = 8,          # 1-10. 8 = clearly market-moving. Lower it for more alerts.
  [int]$MaxAgeHours = 3,       # ignore stories older than this
  [switch]$DryRun,             # score and log, but don't push
  [switch]$Backfill            # one-off: score everything still in the feeds (up to 7 days) for the dashboard; no pushes
)
if ($Backfill) { $MaxAgeHours = 168 }
$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$root = $PSScriptRoot
$dataDir = Join-Path $root 'data'
New-Item -ItemType Directory -Force $dataDir | Out-Null
. (Join-Path $root 'common.ps1')
$logFile = Join-Path $dataDir 'news-log.txt'
# Log times are Sydney time (SUDDY_TZ on GitHub, the PC's clock at home)
function Write-Log($m) { "$((Get-LocalNow).ToString('yyyy-MM-dd HH:mm:ss')) $m" | Out-File $logFile -Append -Encoding utf8 }

# Single instance
$lock = Join-Path $dataDir 'watch.lock'
if ((Test-Path $lock) -and ((Get-Date) - (Get-Item $lock).LastWriteTime).TotalMinutes -lt 10) { return }
Set-Content $lock $PID
try {

$feeds = [ordered]@{
  'Bloomberg'   = 'https://feeds.bloomberg.com/markets/news.rss'
  'Bloomberg Tech' = 'https://feeds.bloomberg.com/technology/news.rss'
  'Bloomberg Politics' = 'https://feeds.bloomberg.com/politics/news.rss'
  'Bloomberg Economics' = 'https://feeds.bloomberg.com/economics/news.rss'
  'CNBC'        = 'https://www.cnbc.com/id/100003114/device/rss/rss.html'
  'CNBC Markets'= 'https://www.cnbc.com/id/20910258/device/rss/rss.html'
  'CNBC Tech'   = 'https://www.cnbc.com/id/19854910/device/rss/rss.html'
  'CNBC Energy' = 'https://www.cnbc.com/id/19836768/device/rss/rss.html'
  'MarketWatch' = 'https://feeds.content.dowjones.io/public/rss/mw_topstories'
  'WSJ Markets' = 'https://feeds.content.dowjones.io/public/rss/RSSMarketsMain'
  'FT Markets'  = 'https://www.ft.com/markets?format=rss'
  'Federal Reserve' = 'https://www.federalreserve.gov/feeds/press_monetary.xml'
}

# ---- Load state
$seenFile = Join-Path $dataDir 'seen.json'
$alertFile = Join-Path $dataDir 'alerted.json'
$firstRun = -not (Test-Path $seenFile)
$seen = @{}
if (-not $firstRun -and -not $Backfill) { foreach ($k in (Get-Content $seenFile -Raw | ConvertFrom-Json)) { $seen[$k] = $true } }
$alerted = @(); if (Test-Path $alertFile) { $alerted = @(Get-Content $alertFile -Raw | ConvertFrom-Json) }
if ($Backfill) { $firstRun = $false; $alerted = @() }   # rescoring old stories: don't treat them as repeats

function Get-Text($node) { if ($null -eq $node) { '' } elseif ($node -is [string]) { $node } else { $node.InnerText } }
function Get-Key($s) { ($s.ToLower() -replace '[^a-z0-9 ]','' -replace '\s+',' ').Trim() }

# ---- Fetch
$cutoff = [DateTimeOffset]::UtcNow.AddHours(-$MaxAgeHours)
$new = New-Object System.Collections.Generic.List[object]
foreach ($src in $feeds.Keys) {
  try {
    $resp = Invoke-WebRequest $feeds[$src] -UseBasicParsing -TimeoutSec 20 -UserAgent 'Mozilla/5.0 (Windows NT 10.0; Win64; x64)'
    $ms = New-Object IO.MemoryStream; $resp.RawContentStream.CopyTo($ms)
    $xml = New-Object Xml.XmlDocument; $xml.LoadXml(([Text.Encoding]::UTF8.GetString($ms.ToArray())).TrimStart([char]0xFEFF))
    foreach ($it in $xml.SelectNodes('//item')) {
      $title = (Get-Text $it.title).Trim()
      if (-not $title) { continue }
      $key = Get-Key $title
      if ($seen.ContainsKey($key)) { continue }
      $seen[$key] = $true
      $pub = $null; try { $pub = [DateTimeOffset]::Parse((Get-Text $it.pubDate).Trim()) } catch {}
      if ($pub -and $pub -lt $cutoff) { continue }
      $desc = ((Get-Text $it.description) -replace '<[^>]+>','').Trim()
      if ($desc.Length -gt 220) { $desc = $desc.Substring(0,220) + '...' }
      $new.Add([pscustomobject]@{ id = $new.Count + 1; source = $src; title = $title; summary = $desc; link = (Get-Text $it.link).Trim(); pub = $pub })
    }
  } catch { Write-Log "FEED_ERROR $src : $($_.Exception.Message)" }
}

# Save seen (cap size)
$keys = @($seen.Keys); if ($keys.Count -gt 4000) { $keys = $keys[-4000..-1] }
if (-not $Backfill) { ConvertTo-Json -InputObject $keys -Compress | Out-File $seenFile -Encoding utf8 }  # backfill must not hide fresh stories from the live watcher

if ($firstRun) { Write-Log "FIRST_RUN: stored $($keys.Count) existing headlines, no alerts sent."; return }
if ($new.Count -eq 0) { return }
Write-Log "NEW $($new.Count) headlines"

# ---- Score with Claude
function Find-Claude {
  $c = Get-Command claude -ErrorAction SilentlyContinue
  if ($c) { return $c.Source }
  foreach ($p in "$env:USERPROFILE\.local\bin\claude.exe") { if (Test-Path $p) { return $p } }
  return $null
}
$claude = Find-Claude
$results = $null
if ($claude) {
 $results = @()
 # Score in batches so a big backlog (backfill) stays within one prompt's comfort zone
 for ($b = 0; $b -lt $new.Count; $b += 70) {
  $batch = $new[$b..([math]::Min($b + 69, $new.Count - 1))]
  $recent = ($alerted | Select-Object -Last 25 | ForEach-Object { "- $($_.headline)" }) -join "`n"
  $list = ($batch | ForEach-Object { "[$($_.id)] ($($_.source)) $($_.title) -- $($_.summary)" }) -join "`n"
  $prompt = @"
You filter breaking news for a futures day trader who trades NQ (Nasdaq-100 futures) and watches ES (S&P 500 futures).
Score each headline 1-10 for how likely it is to move NQ/ES or a top Nasdaq-100 stock in the next hours to days.
10 = market-wide shock (surprise Fed move, war escalation, major tariff action, crash/circuit breaker, a mega-cap CEO ousted or reinstated, huge M&A, government shutdown).
8-9 = clearly market-moving (Fed chair/governor signals a policy shift, big surprise in a data release, mega-cap earnings shock or guidance cut, major antitrust/regulatory ruling on a mega-cap, big China/chip export news, large geopolitical event, major bank or credit stress).
5-7 = notable but routine (normal earnings, analyst notes, sector moves, scheduled data in line with forecast).
1-4 = not market-moving (personal finance, lifestyle, opinion pieces, small caps, market wraps describing moves that already happened, "stocks rise/fall" recaps).
He also wants HEAVY gold and oil news, even if it doesn't touch NQ/ES. Score gold/oil stories on the same scale, but only give 8+ to big shocks: surprise OPEC+ output decisions, Strait of Hormuz or other major supply disruption, attacks on major oil infrastructure, sanctions that cut a big producer's exports, US SPR emergency releases, central-bank gold buying or selling on a historic scale, gold or oil making a record high or a crash-sized move. Routine inventory reports, analyst price targets, daily price moves and commodity market wraps score 1-5.
Start the "alert" text with "GOLD:" or "OIL:" when the story is mainly about gold or oil.
If several headlines below cover the same story, score only the most informative one and give the others 1.
Already alerted recently (score a repeat 1 unless it is a materially new development):
$recent
Headlines:
$list
Reply with ONLY a JSON array, no prose, one object per headline scoring 7 or more:
[{"id":1,"score":9,"alert":"<max 90 chars: what happened>","why":"<max 110 chars: why it matters for NQ/ES, or for gold/oil>"}]
If none score 7+, reply [].
"@
  $work = Join-Path $dataDir 'claude-work'; New-Item -ItemType Directory -Force $work | Out-Null
  Push-Location $work
  try {
    Remove-Item Env:CLAUDECODE -ErrorAction SilentlyContinue
    $raw = ($prompt | & $claude -p --model haiku --max-turns 1 2>&1 | Out-String)
    if ($LASTEXITCODE -ne 0) { throw "claude exit $LASTEXITCODE : $raw" }
    $json = [regex]::Match($raw, '\[[\s\S]*\]').Value
    # PowerShell 5.1 returns a JSON array as one object; the extra pipeline unrolls it
    $got = @(($json | ConvertFrom-Json) | ForEach-Object { $_ })
    $results += $got
    # Later batches should know what this one already flagged
    foreach ($g in ($got | Where-Object { $_.score -ge $MinScore })) { $alerted += [pscustomobject]@{ time = (Get-Date).ToString('s'); score = $g.score; headline = $g.alert } }
  } catch { Write-Log "CLAUDE_ERROR: $($_.Exception.Message)"; $results = $null; break }
  finally { Pop-Location }
 }
 # Drop the provisional entries; they are added properly when pushed below
 if ($null -ne $results) { $alerted = @($alerted | Where-Object { $results.alert -notcontains $_.headline }) }
}

if ($null -eq $results) {
  # Keyword fallback: strict, so it errs toward silence
  $big = 'nvidia|apple|microsoft|amazon|alphabet|google|meta|tesla|broadcom|netflix|amd|tsmc|openai'
  $rules = @(
    @{ p = '\b(fed|fomc|powell)\b.*\b(cut|hike|emergency|surprise|rate)'; s = 9 },
    @{ p = '\b(tariff|export ban|export control|sanction)'; s = 8 },
    @{ p = "($big).*\b(ceo|chief executive)\b.*\b(resign|ousted|fired|steps down|reinstated|returns|departs)"; s = 9 },
    @{ p = "($big).*\b(acquire|acquisition|merger|antitrust|break ?up|probe)"; s = 8 },
    @{ p = '\b(opec)\b.*\b(surprise|cut|hike|boost|slash)|\b(hormuz|oil embargo|spr release|strategic petroleum)'; s = 9 },
    @{ p = '\b(gold|oil|crude|brent)\b.*\b(record high|all-time high|plunge|crash|soar)'; s = 9 },
    @{ p = '\b(circuit breaker|trading halt|flash crash|market crash)'; s = 10 },
    @{ p = '\b(war|invasion|missile|strike on|ceasefire)\b'; s = 8 },
    @{ p = '\b(shutdown|default|downgrade)\b.*\b(government|us|treasury|credit)'; s = 8 },
    @{ p = '\b(bank failure|bank run)\b|\bbanks?\b.*\b(collapse|fails|seized)'; s = 9 }
  )
  # Skip explainers, opinion and personal-finance pieces, and only push 9+ without AI
  $noise = '\?|^(why|how|what|should|is|are|can|will)\b|\b(my|i''m|we''re|opinion|video|newsletter|podcast|explainer)\b'
  $results = foreach ($n in $new) {
    if ($n.title -match $noise -or $n.link -match '/(videos|newsletters|opinion)/') { continue }
    $best = 0; foreach ($r in $rules) { if ($n.title -match $r.p -and $r.s -gt $best) { $best = $r.s } }
    if ($best -ge [math]::Max($MinScore, 9)) { [pscustomobject]@{ id = $n.id; score = $best; alert = $n.title; why = '(keyword match, AI filter offline)' } }
  }
  if (-not $claude) { Write-Log 'NO_CLAUDE: used keyword filter' }
}

# ---- Dashboard-only: notable stories just under the push threshold (7/10). Never pushed.
foreach ($r in ($results | Where-Object { [int]$_.score -ge 7 -and [int]$_.score -lt $MinScore })) {
  $item = $new | Where-Object { $_.id -eq [int]$r.id } | Select-Object -First 1
  if (-not $item) { continue }
  $pubIso = if ($item.pub) { $item.pub.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ') } else { [DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ') }
  Write-Log "NOTE [$($r.score)] $($r.alert) | $($item.link) | pub=$pubIso"
}

# ---- Push
foreach ($r in ($results | Where-Object { $_.score -ge $MinScore } | Sort-Object score -Descending)) {
  $item = $new | Where-Object { $_.id -eq [int]$r.id } | Select-Object -First 1
  if (-not $item) { continue }
  $local = (Get-LocalNow).ToString('h:mmtt ddd')
  $msg = "$($r.why)`n`n$($item.source), $local`n$($item.title)"
  $prio = if ([int]$r.score -ge 9) { 'high' } else { 'default' }
  $pubIso = if ($item.pub) { $item.pub.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ') } else { [DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ') }
  Write-Log "ALERT [$($r.score)] $($r.alert) | $($item.link) | pub=$pubIso"
  if (-not $DryRun -and -not $Backfill) {
    try {
      $cfg = Get-NtfyConfig
      $title = -join ("[$($r.score)/10] $($r.alert)".ToCharArray() | Where-Object { [int]$_ -lt 128 })
      $h = @{ Title = $title; Priority = $prio; Tags = 'rotating_light' }
      if ($item.link) { $h['Click'] = $item.link }
      Invoke-RestMethod -Method Post -Uri "$($cfg.server)/$($cfg.topic)" -Body ([Text.Encoding]::UTF8.GetBytes($msg)) -Headers $h -ContentType 'text/plain; charset=utf-8' | Out-Null
    } catch { Write-Log "PUSH_ERROR: $($_.Exception.Message)" }
  }
  $alerted += [pscustomobject]@{ time = (Get-Date).ToString('s'); score = $r.score; headline = $r.alert }
}
$alerted = @($alerted | Select-Object -Last 50)
if (-not $Backfill) { ConvertTo-Json -InputObject $alerted | Out-File $alertFile -Encoding utf8 }

} finally {
  Remove-Item $lock -ErrorAction SilentlyContinue
  # Keep the dashboard's news panel current (local only, takes a second)
  try { & (Join-Path $root 'build-dashboard.ps1') } catch { Write-Log "DASHBOARD_ERROR: $($_.Exception.Message)" }
}
