<#
  Gathers the hard data for the SUDDY market alerts and writes it as markdown.
    -Mode weekly : the upcoming US trading week (Mon-Fri, New York time)
    -Mode daily  : the next ~24 hours from now (covers today's Asia session and the next NY session)
  Sources (free, no keys):
    ForexFactory calendar feed  https://nfs.faireconomy.media/ff_calendar_thisweek.json
    Nasdaq earnings calendar    https://api.nasdaq.com/api/calendar/earnings?date=YYYY-MM-DD
    Nager.Date public holidays  https://date.nager.at/api/v3/PublicHolidays/YEAR/COUNTRY
  OPEX dates and the NYSE holiday list are computed / kept below.
  Output: data\<mode>-data.md (also printed).
#>
param(
  [ValidateSet('weekly','daily')][string]$Mode = 'weekly',
  [double]$MinMarketCapBillions = 50,
  [datetime]$AsOf,
  [ValidateSet('next','current')][string]$Week = 'next',   # weekly mode: the coming week, or the week in progress (dashboard)
  [switch]$Quiet
)
$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$root = $PSScriptRoot
$dataDir = Join-Path $root 'data'
New-Item -ItemType Directory -Force $dataDir | Out-Null

. (Join-Path $PSScriptRoot 'common.ps1')   # time zones, NYSE holidays, Mag 7 list, OPEX rules, cache helpers
$nowUtc  = if ($AsOf) { [DateTimeOffset]::new($AsOf) } else { [DateTimeOffset]::UtcNow }   # -AsOf is for testing other dates
$nowNY   = [TimeZoneInfo]::ConvertTime($nowUtc, $tzNY)
$nowLoc  = [TimeZoneInfo]::ConvertTime($nowUtc, $tzLocal)

function Format-Local([DateTimeOffset]$t) { [TimeZoneInfo]::ConvertTime($t, $tzLocal).ToString('ddd d MMM h:mmtt') }
function Format-NY([DateTimeOffset]$t)    { [TimeZoneInfo]::ConvertTime($t, $tzNY).ToString('ddd h:mmtt') + ' ET' }

# ---- Window --------------------------------------------------------------
if ($Mode -eq 'weekly') {
  # Next Monday in New York (today if it's Monday). With -Week current, Mon-Fri use this week's Monday.
  $d = $nowNY.Date
  if ($Week -eq 'current' -and $d.DayOfWeek -notin 'Saturday','Sunday') { $d = $d.AddDays(1 - [int]$d.DayOfWeek) }
  while ($d.DayOfWeek -ne 'Monday') { $d = $d.AddDays(1) }
  $nyDates = 0..4 | ForEach-Object { $d.AddDays($_) }
  $winStart = [DateTimeOffset]::new($d.AddDays(-1), $tzNY.GetUtcOffset($d.AddDays(-1)))   # Sunday 00:00 ET (Asia open is Sunday evening ET)
  $winEnd   = [DateTimeOffset]::new($d.AddDays(5), $tzNY.GetUtcOffset($d.AddDays(5)))     # Saturday 00:00 ET
  $title = "Week of $($d.ToString('ddd d MMM yyyy')) (NY time)"
} else {
  # The NY trading day this heads-up is for. At 8am Sydney it's the previous afternoon in New York,
  # so +12h lands on the coming trading day. Weekends roll to Monday.
  $target = $nowNY.AddHours(12).Date
  while ($target.DayOfWeek -in 'Saturday','Sunday') { $target = $target.AddDays(1) }
  $nyDates = @($target)
  # Full futures trading day: 6pm ET the evening before (Globex open, covers the Asia session) to 5pm ET close
  $prev = $target.AddDays(-1)
  $winStart = [DateTimeOffset]::new($prev.AddHours(18), $tzNY.GetUtcOffset($prev.AddHours(18)))
  $winEnd   = [DateTimeOffset]::new($target.AddHours(17), $tzNY.GetUtcOffset($target.AddHours(17)))
  $title = "Trading day $($target.ToString('ddd d MMM')) (NY): $(Format-Local $winStart) to $(Format-Local $winEnd) Sydney time"
}


$out = New-Object System.Collections.Generic.List[string]
$warn = New-Object System.Collections.Generic.List[string]
# Structured copy of everything, for the dashboard
$j = [ordered]@{
  generated = $nowUtc.ToString('o'); mode = $Mode; title = $title
  days = @($nyDates | ForEach-Object { $_.ToString('yyyy-MM-dd') })
  events = New-Object System.Collections.Generic.List[object]
  earnings = New-Object System.Collections.Generic.List[object]
  opex = New-Object System.Collections.Generic.List[object]
  holidays = New-Object System.Collections.Generic.List[object]
  mag7Ahead = @(); nextOpex = $null; warnings = $warn; ffStale = $false
}
function Get-Session([DateTimeOffset]$t) {
  $h = [TimeZoneInfo]::ConvertTime($t, $tzNY).Hour
  if ($h -ge 18 -or $h -lt 3) { 'Asia' } elseif ($h -lt 8) { 'London' } elseif ($h -lt 12) { 'NY open' } else { 'NY pm' }
}
function Get-NYDay([DateTimeOffset]$t) {
  # Trading day an event belongs to: anything from 6pm ET counts toward the next day
  $n = [TimeZoneInfo]::ConvertTime($t, $tzNY); $dd = $n.Date; if ($n.Hour -ge 18) { $dd = $dd.AddDays(1) }
  while ($dd.DayOfWeek -in 'Saturday','Sunday') { $dd = $dd.AddDays(1) }
  $dd.ToString('yyyy-MM-dd')
}
$out.Add("# Market data pack: $Mode")
$out.Add("$title")
$out.Add("Generated $(Format-Local $nowUtc) local ($($tzLocal.Id)). Local times first, NY time in brackets.")
$out.Add('')

# ---- 1. ForexFactory high-impact (red folder) ----------------------------
$out.Add('## Red folder (high impact) events')
try {
  # The feed is rate limited (a few requests per 5 min), so keep a 15-minute cache.
  $cache = Join-Path $dataDir 'ff_cache.json'
  if (-not (Test-Fresh $cache 15)) {
    try {
      $raw = (Invoke-WebRequest 'https://nfs.faireconomy.media/ff_calendar_thisweek.json' -UseBasicParsing -TimeoutSec 30).Content
      [IO.File]::WriteAllText($cache, $raw); Set-Stamp $cache
    } catch {
      if (-not (Test-Path $cache)) { throw }
      $warn.Add("FF_CACHE: live feed failed ($($_.Exception.Message)); using cached copy from $((Get-Item $cache).LastWriteTime).")
    }
  }
  $ff = [IO.File]::ReadAllText($cache) | ConvertFrom-Json
  $all = foreach ($e in $ff) { $e | Add-Member -NotePropertyName t -NotePropertyValue ([DateTimeOffset]::Parse($e.date)) -PassThru }
  $latest = ($all | Measure-Object -Property t -Maximum).Maximum
  if ($latest -lt $winStart) {
    $warn.Add("FF_STALE: the ForexFactory feed still shows the previous week (latest event $($latest.ToString('yyyy-MM-dd'))). Red-folder events for this window must be found by web search.")
    $out.Add('_Feed has not rolled over to this week yet. See warnings._')
    $j.ffStale = $true
  } else {
    $hi = $all | Where-Object { $_.impact -eq 'High' -and $_.t -ge $winStart -and $_.t -lt $winEnd } | Sort-Object t
    if (-not $hi) { $out.Add('None in this window.') }
    foreach ($e in $hi) {
      $fc = if ($e.forecast) { " | fcst $($e.forecast)" } else { '' }
      $pv = if ($e.previous) { " | prev $($e.previous)" } else { '' }
      $out.Add("- $(Format-Local $e.t) ($(Format-NY $e.t)) **$($e.country)** $($e.title)$fc$pv")
    }
    $med = $all | Where-Object { $_.impact -eq 'Medium' -and $_.country -eq 'USD' -and $_.t -ge $winStart -and $_.t -lt $winEnd } | Sort-Object t
    if ($med) {
      $out.Add(''); $out.Add('USD orange folder (medium), for reference:')
      foreach ($e in $med) { $out.Add("- $(Format-Local $e.t) ($(Format-NY $e.t)) $($e.title)") }
    }
    foreach ($e in (@($hi) + @($med) | Where-Object { $_ })) {
      $j.events.Add([ordered]@{
        day = Get-NYDay $e.t; impact = $e.impact; country = $e.country; title = $e.title
        forecast = $e.forecast; previous = $e.previous; session = Get-Session $e.t
        local = [TimeZoneInfo]::ConvertTime($e.t, $tzLocal).ToString('ddd h:mmtt'); ny = (Format-NY $e.t)
        sort = $e.t.ToUnixTimeSeconds()
      })
    }
  }
} catch { $warn.Add("FF_ERROR: $($_.Exception.Message)") }
$out.Add('')

# ---- 2. Earnings -----------------------------------------------------------
$out.Add("## Earnings (market cap >= `$$MinMarketCapBillions B)")
$hdr = @{ 'User-Agent' = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64)'; 'Accept' = 'application/json' }
$earnCache = @{}
function Get-Earnings([datetime]$day) {
  $k = $day.ToString('yyyy-MM-dd')
  if (-not $earnCache.ContainsKey($k)) {
    $r = Invoke-RestMethod "https://api.nasdaq.com/api/calendar/earnings?date=$k" -Headers $hdr -TimeoutSec 30
    $earnCache[$k] = @(@($r.data.rows) | Where-Object { $_ } | ForEach-Object {
      $cap = 0; [double]::TryParse(($_.marketCap -replace '[\$,]',''), [ref]$cap) | Out-Null
      $_ | Add-Member -NotePropertyName cap -NotePropertyValue $cap -PassThru -Force
    })
  }
  $earnCache[$k]
}
function Format-Earnings($rows, [string]$onlyTime) {
  $pick = $rows | Where-Object { ($_.cap -ge $MinMarketCapBillions * 1e9) -or ($mag7 + $nqHeavy -contains $_.symbol) }
  if ($onlyTime) { $pick = $pick | Where-Object { $_.time -eq $onlyTime } }
  $pick = $pick | Sort-Object @{ e = { if ($mag7 -contains $_.symbol) { 0 } elseif ($nqHeavy -contains $_.symbol) { 1 } else { 2 } } }, @{ e = 'cap'; Descending = $true }
  foreach ($x in $pick) {
    $when = switch ($x.time) { 'time-pre-market' {'before open'} 'time-after-hours' {'after close'} default {'time TBC'} }
    $tag = if ($mag7 -contains $x.symbol) { '**MAG7** ' } elseif ($nqHeavy -contains $x.symbol) { '**NQ** ' } else { '' }
    "$tag$($x.symbol) ($when, `$$([math]::Round($x.cap/1e9))B)"
  }
}
$out.Add('MAG7 = Magnificent 7. NQ = other Nasdaq-100 heavyweights. Others are any company worth $' + $MinMarketCapBillions + 'B+.')
if ($Mode -eq 'daily') {
  # Last night's after-close reports move the Asia session and the open
  $prevDay = $nyDates[0].AddDays(-1); while ($prevDay.DayOfWeek -in 'Saturday','Sunday') { $prevDay = $prevDay.AddDays(-1) }
  try {
    $l = Format-Earnings (Get-Earnings $prevDay) 'time-after-hours'
    $out.Add("- Reported after close $($prevDay.ToString('ddd d MMM')) NY (moves Asia + the open): $(if ($l) { $l -join ', ' } else { 'none' })")
  } catch { $warn.Add("EARNINGS_ERROR $($prevDay.ToString('yyyy-MM-dd')): $($_.Exception.Message)") }
}
foreach ($day in $nyDates) {
  try {
    $rowsDay = Get-Earnings $day
    $l = Format-Earnings $rowsDay
    $out.Add("- $($day.ToString('ddd d MMM')) NY: $(if ($l) { $l -join ', ' } else { 'none' })")
    foreach ($x in ($rowsDay | Where-Object { ($_.cap -ge $MinMarketCapBillions * 1e9) -or ($mag7 + $nqHeavy -contains $_.symbol) })) {
      $j.earnings.Add([ordered]@{
        day = $day.ToString('yyyy-MM-dd'); symbol = $x.symbol; name = $x.name; capB = [math]::Round($x.cap/1e9)
        time = switch ($x.time) { 'time-pre-market' {'BMO'} 'time-after-hours' {'AMC'} default {'TBC'} }
        tag = if ($mag7 -contains $x.symbol) { 'MAG7' } elseif ($nqHeavy -contains $x.symbol) { 'NQ' } else { '' }
      })
    }
  } catch { $warn.Add("EARNINGS_ERROR $($day.ToString('yyyy-MM-dd')): $($_.Exception.Message)") }
}
if ($Mode -eq 'weekly') {
  # Look ahead 9 weeks for Magnificent 7 dates (future dates on Nasdaq can be estimates).
  # 45 requests, so the result is cached for 12 hours.
  $aheadFile = Join-Path $dataDir 'mag7-ahead.json'
  $ahead = @()
  if (-not $AsOf -and (Test-Fresh $aheadFile 720)) {
    $ahead = @(Get-Content $aheadFile -Raw | ConvertFrom-Json | ForEach-Object { $_ })
  } else {
    $d2 = $nyDates[-1].AddDays(3)
    for ($i = 0; $i -lt 45; $i++) {
      $day = $d2.AddDays([math]::Floor($i / 5) * 7 + ($i % 5))
      try { $ahead += Get-Earnings $day | Where-Object { $mag7 -contains $_.symbol } | ForEach-Object { "$($_.symbol) $($day.ToString('ddd d MMM'))" } } catch {}
      Start-Sleep -Milliseconds 300
    }
    ConvertTo-Json -InputObject @($ahead) | Out-File $aheadFile -Encoding utf8
    if (-not $AsOf) { Set-Stamp $aheadFile }
  }
  $j.mag7Ahead = @($ahead)
  $out.Add("- Coming up (next 9 weeks, Mag 7 only; may be estimated dates): $(if ($ahead) { $ahead -join ', ' } else { 'none scheduled yet' })")
}
$out.Add('')

# ---- 3. OPEX ------------------------------------------------------------------
# Monthly OPEX = 3rd Friday. Mar/Jun/Sep/Dec = quad witching (stock + index options, index futures expire).
# If that Friday is a market holiday, expiry moves to Thursday. ES/NQ roll to the next contract 8 days before quad witching (the Thursday a week earlier).
$out.Add('## Options expiry (OPEX)')
$months = @($nyDates | ForEach-Object { "$($_.Year)-$($_.Month)" }) + @("$($nyDates[0].AddMonths(1).Year)-$($nyDates[0].AddMonths(1).Month)") | Select-Object -Unique
$opexLines = @(); $next = $null
foreach ($ym in $months) {
  $y, $m = $ym -split '-'; $ox = Get-Opex ([int]$y) ([int]$m); $quad = ([int]$m % 3 -eq 0)
  $roll = $ox.AddDays(-8)
  if (-not $next -and $ox -ge $nyDates[0]) { $next = $ox; $nextQuad = $quad }
  $weekStart = $ox.AddDays(-[int]$ox.DayOfWeek + 1)   # Monday of OPEX week
  foreach ($day in $nyDates) {
    $dk = $day.ToString('yyyy-MM-dd')
    if ($day -eq $ox) {
      $opexLines += "- $($day.ToString('ddd d MMM')): **$(if ($quad) {'QUAD WITCHING'} else {'MONTHLY OPEX'})** today$(if ($quad) {' (quarterly stock + index options and index futures expire)'} else {' (3rd Friday)'})"
      $j.opex.Add([ordered]@{ day = $dk; kind = $(if ($quad) {'quad'} else {'monthly'}); label = $(if ($quad) {'Quad witching'} else {'Monthly OPEX'}) })
    }
    elseif ($day -ge $weekStart -and $day -lt $ox) {
      if ($Mode -eq 'daily') { $opexLines += "- $($day.ToString('ddd d MMM')): $(if ($quad) {'quad witching'} else {'monthly OPEX'}) week, expiry $($ox.ToString('ddd d MMM'))" }
    }
    if ($quad -and $day -eq $roll) {
      $opexLines += "- $($day.ToString('ddd d MMM')): **ES/NQ ROLL DATE** - volume moves to the next quarterly contract (check your MNQ contract month)"
      $j.opex.Add([ordered]@{ day = $dk; kind = 'roll'; label = 'ES/NQ roll date' })
    }
  }
}
$opexLines = $opexLines | Select-Object -Unique
if ($opexLines) { $opexLines | ForEach-Object { $out.Add($_) } }
else { $out.Add('No monthly OPEX this window (0DTE/weekly options still expire daily).') }
$out.Add("Next monthly OPEX: $($next.ToString('ddd d MMM yyyy'))$(if ($nextQuad) {' (QUAD WITCHING)'})")
$j.nextOpex = [ordered]@{ day = $next.ToString('yyyy-MM-dd'); quad = [bool]$nextQuad }
# Next ES/NQ roll date (8 days before the next quad witching), so it's always visible
$qm = [datetime]::new($nyDates[0].Year, $nyDates[0].Month, 1); $nextRoll = $null
while (-not $nextRoll) { if ($qm.Month % 3 -eq 0) { $r8 = (Get-Opex $qm.Year $qm.Month).AddDays(-8); if ($r8 -ge $nyDates[0]) { $nextRoll = $r8 } }; $qm = $qm.AddMonths(1) }
$out.Add("Next ES/NQ roll date: $($nextRoll.ToString('ddd d MMM yyyy'))")
$out.Add('')

# ---- 4. Holidays ------------------------------------------------------------
$out.Add('## Holidays')
$lastKnown = ($nyse.Keys | Sort-Object | Select-Object -Last 1)
if ($nyDates[-1].ToString('yyyy-MM-dd') -gt $lastKnown) { $warn.Add('NYSE_LIST_OUTDATED: the NYSE holiday list in gather-data.ps1 ends at ' + $lastKnown + '. Check nyse.com and tell the user to update it.') }
$hitUS = foreach ($day in $nyDates) { $k = $day.ToString('yyyy-MM-dd'); if ($nyse.ContainsKey($k)) {
  $j.holidays.Add([ordered]@{ day = $k; country = 'US market'; name = $nyse[$k] })
  "- US market: $($day.ToString('ddd d MMM')) $($nyse[$k])" } }
$locStart = [TimeZoneInfo]::ConvertTime($winStart, $tzLocal).Date
$locEnd   = [TimeZoneInfo]::ConvertTime($winEnd, $tzLocal).Date
$hitBank = @()
foreach ($c in 'US','AU') {
  try {
    $years = @($locStart.Year, $locEnd.Year) | Select-Object -Unique
    foreach ($y in $years) {
      $hol = Invoke-RestMethod "https://date.nager.at/api/v3/PublicHolidays/$y/$c" -TimeoutSec 30
      foreach ($h in $hol) {
        $hd = [datetime]::ParseExact($h.date, 'yyyy-MM-dd', $null)
        if ($hd -ge $locStart.AddDays(-1) -and $hd -le $locEnd) {
          $where = if ($h.global) { 'nationwide' } else { ($h.counties -join ', ') }
          $line = "- $c bank/public holiday: $($hd.ToString('ddd d MMM')) $($h.name) ($where)"
          if ($hitBank -notcontains $line) { $j.holidays.Add([ordered]@{ day = $hd.ToString('yyyy-MM-dd'); country = "$c bank holiday"; name = "$($h.name) ($where)" }) }
          $hitBank += $line
        }
      }
    }
  } catch { $warn.Add("HOLIDAY_ERROR $c`: $($_.Exception.Message)") }
}
$all = @($hitUS) + @($hitBank | Select-Object -Unique) | Where-Object { $_ }
if ($all) { $all | ForEach-Object { $out.Add($_) } } else { $out.Add('None in this window.') }
$out.Add('')

# ---- Warnings ---------------------------------------------------------------
$out.Add('## Warnings')
if ($warn.Count) { $warn | ForEach-Object { $out.Add("- $_") } } else { $out.Add('None. All sources loaded.') }

$base = if ($Mode -eq 'weekly' -and $Week -eq 'current') { 'week-current' } else { $Mode }
$out -join "`r`n" | Out-File -FilePath (Join-Path $dataDir "$base-data.md") -Encoding utf8
$j.warnings = @($warn)
ConvertTo-Json -InputObject $j -Depth 6 | Out-File -FilePath (Join-Path $dataDir "$base-data.json") -Encoding utf8
if (-not $Quiet) { $out -join "`n" }

