<#
  Data for the dashboard's "Next 4 weeks" section: the 4 NY trading weeks after the current one.
    - Major scheduled US releases from data\future-events.json (kept up to date by the Sunday Claude task)
    - Earnings: Mag 7, Nasdaq-100 heavyweights, and any $50B+ company (Nasdaq calendar, cached 12h per day)
    - Monthly OPEX, quad witching, ES/NQ roll date
    - US market closures/early closes, US and AU bank holidays
  Output: data\ahead-data.json
#>
param([int]$Weeks = 4, [double]$MinMarketCapBillions = 50)
$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$root = $PSScriptRoot
$dataDir = Join-Path $root 'data'
. (Join-Path $root 'common.ps1')
$nowNY = [TimeZoneInfo]::ConvertTime([DateTimeOffset]::UtcNow, $tzNY)
$warn = @()

# Monday of the current dashboard week (weekends look at the coming week), then the next N weeks
$d = $nowNY.Date
if ($d.DayOfWeek -in 'Saturday','Sunday') { while ($d.DayOfWeek -ne 'Monday') { $d = $d.AddDays(1) } } else { $d = $d.AddDays(1 - [int]$d.DayOfWeek) }
$firstMon = $d.AddDays(7)
$days = for ($w = 0; $w -lt $Weeks; $w++) { for ($i = 0; $i -lt 5; $i++) { $firstMon.AddDays($w * 7 + $i) } }

# ---- Earnings (disk cache, 12h)
$cacheDir = Join-Path $dataDir 'earnings-cache'; New-Item -ItemType Directory -Force $cacheDir | Out-Null
$hdr = @{ 'User-Agent' = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64)'; 'Accept' = 'application/json' }
$earnings = @()
foreach ($day in $days) {
  $k = $day.ToString('yyyy-MM-dd'); $f = Join-Path $cacheDir "$k.json"
  try {
    if (-not (Test-Fresh $f 720)) {
      $r = Invoke-RestMethod "https://api.nasdaq.com/api/calendar/earnings?date=$k" -Headers $hdr -TimeoutSec 30
      ConvertTo-Json -InputObject @(@($r.data.rows) | Where-Object { $_ }) -Depth 3 | Out-File $f -Encoding utf8
      Set-Stamp $f
      Start-Sleep -Milliseconds 250
    }
    foreach ($x in @(Get-Content $f -Raw | ConvertFrom-Json | ForEach-Object { $_ })) {
      if (-not $x) { continue }
      $cap = 0; [double]::TryParse(($x.marketCap -replace '[\$,]',''), [ref]$cap) | Out-Null
      $tag = if ($mag7 -contains $x.symbol) { 'MAG7' } elseif ($nqHeavy -contains $x.symbol) { 'NQ' } else { '' }
      if ($tag -or $cap -ge $MinMarketCapBillions * 1e9) {
        $earnings += [ordered]@{ day = $k; symbol = $x.symbol; name = $x.name; capB = [math]::Round($cap/1e9); tag = $tag
          time = switch ($x.time) { 'time-pre-market' {'BMO'} 'time-after-hours' {'AMC'} default {'TBC'} } }
      }
    }
  } catch { $warn += "Earnings $k`: $($_.Exception.Message)" }
}

# ---- OPEX, quad witching, roll
$opex = @()
$months = $days | ForEach-Object { [datetime]::new($_.Year, $_.Month, 1) } | Select-Object -Unique
foreach ($m in $months) {
  $ox = Get-Opex $m.Year $m.Month; $quad = ($m.Month % 3 -eq 0)
  if ($days -contains $ox) { $opex += [ordered]@{ day = $ox.ToString('yyyy-MM-dd'); kind = $(if ($quad) {'quad'} else {'monthly'}); label = $(if ($quad) {'Quad witching'} else {'Monthly OPEX'}) } }
  if ($quad -and ($days -contains $ox.AddDays(-8))) { $opex += [ordered]@{ day = $ox.AddDays(-8).ToString('yyyy-MM-dd'); kind = 'roll'; label = 'ES/NQ roll date' } }
}

# ---- Holidays
$holidays = @()
foreach ($day in $days) { $k = $day.ToString('yyyy-MM-dd'); if ($nyse.ContainsKey($k)) { $holidays += [ordered]@{ day = $k; country = 'US market'; name = $nyse[$k] } } }
$first = $days[0]; $last = $days[-1].AddDays(2)
foreach ($c in 'US','AU') {
  foreach ($y in (@($first.Year, $last.Year) | Select-Object -Unique)) {
    try {
      $hc = Join-Path $dataDir "holidays-$c-$y.json"
      if (-not (Test-Path $hc)) { (Invoke-WebRequest "https://date.nager.at/api/v3/PublicHolidays/$y/$c" -UseBasicParsing -TimeoutSec 30).Content | Out-File $hc -Encoding utf8 }
      foreach ($h in (Get-Content $hc -Raw | ConvertFrom-Json)) {
        $hd = [datetime]::ParseExact($h.date, 'yyyy-MM-dd', $null)
        if ($hd -ge $first.AddDays(-1) -and $hd -le $last) {
          $where = if ($h.global) { 'nationwide' } else { ($h.counties -join ', ') }
          $holidays += [ordered]@{ day = $h.date; country = "$c bank holiday"; name = "$($h.name) ($where)" }
        }
      }
    } catch { $warn += "Holidays $c $y`: $($_.Exception.Message)" }
  }
}

# ---- Major scheduled releases (Claude-maintained)
$events = @(); $evUpdated = $null
$fe = Join-Path $dataDir 'future-events.json'
if (Test-Path $fe) {
  $doc = [IO.File]::ReadAllText($fe).TrimStart([char]0xFEFF) | ConvertFrom-Json; $evUpdated = $doc.updated
  foreach ($e in $doc.events) {
    $dt = [datetime]::ParseExact("$($e.date) $($e.timeET)", 'yyyy-MM-dd HH:mm', $null)
    if ($dt.Date -lt $first -or $dt.Date -gt $days[-1]) { continue }
    $t = [DateTimeOffset]::new($dt, $tzNY.GetUtcOffset($dt))
    $events += [ordered]@{ day = $e.date; title = $e.title; impact = $e.impact; status = $e.status; source = $e.source
      local = [TimeZoneInfo]::ConvertTime($t, $tzLocal).ToString('ddd h:mmtt'); ny = $t.ToString('h:mmtt') + ' ET'; sort = $t.ToUnixTimeSeconds() }
  }
} else { $warn += 'future-events.json missing: the Sunday task creates it.' }

$out = [ordered]@{
  generated = [DateTimeOffset]::UtcNow.ToString('o'); eventsUpdated = $evUpdated
  weeks = @(for ($w = 0; $w -lt $Weeks; $w++) { $firstMon.AddDays($w * 7).ToString('yyyy-MM-dd') })
  events = $events; earnings = $earnings; opex = $opex; holidays = @($holidays | Sort-Object { $_.day }); warnings = $warn
}
ConvertTo-Json -InputObject $out -Depth 5 | Out-File (Join-Path $dataDir 'ahead-data.json') -Encoding utf8
