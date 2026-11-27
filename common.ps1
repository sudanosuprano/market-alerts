# Shared by all the scripts. Dot-source it: . (Join-Path $PSScriptRoot 'common.ps1')
# Works on Windows PowerShell 5.1 (your PC) and PowerShell 7 on Linux (GitHub Actions).

# Time zones. On GitHub the server clock is UTC, so SUDDY_TZ=Australia/Sydney is set there.
function Get-Tz([string[]]$ids) {
  foreach ($id in $ids) { try { return [TimeZoneInfo]::FindSystemTimeZoneById($id) } catch {} }
  throw "No time zone found for $($ids -join ', ')"
}
$tzLocal = if ($env:SUDDY_TZ) { Get-Tz @($env:SUDDY_TZ, 'AUS Eastern Standard Time') } else { [TimeZoneInfo]::Local }
$tzNY    = Get-Tz @('Eastern Standard Time', 'America/New_York')
function Get-LocalNow { [TimeZoneInfo]::ConvertTime([DateTimeOffset]::UtcNow, $tzLocal) }

# Cache freshness. File times can't be trusted on GitHub (a checkout resets them), so each cache
# file gets a small "<file>.stamp" holding the UTC time it was fetched.
function Test-Fresh([string]$file, [double]$minutes) {
  $st = "$file.stamp"
  if (-not (Test-Path $file) -or -not (Test-Path $st)) { return $false }
  try { return ([DateTimeOffset]::UtcNow - [DateTimeOffset]::Parse((Get-Content $st -Raw).Trim())).TotalMinutes -lt $minutes } catch { return $false }
}
function Set-Stamp([string]$file) { [DateTimeOffset]::UtcNow.ToString('o') | Out-File "$file.stamp" -Encoding ascii }

# ntfy settings: environment variables (GitHub secrets) win over config.json (your PC)
function Get-NtfyConfig {
  $cfgFile = Join-Path $PSScriptRoot 'config.json'
  $cfg = if (Test-Path $cfgFile) { Get-Content $cfgFile -Raw | ConvertFrom-Json } else { [pscustomobject]@{ server = 'https://ntfy.sh'; topic = $null; clickUrl = $null } }
  if ($env:NTFY_TOPIC) { $cfg.topic = $env:NTFY_TOPIC }
  if (-not $cfg.server) { $cfg.server = 'https://ntfy.sh' }
  if (-not $cfg.topic) { throw 'No ntfy topic: set NTFY_TOPIC or create config.json' }
  $cfg
}

# NYSE/Nasdaq closures and 1pm ET early closes. CME equity futures (NQ/ES/MNQ) trade a shortened
# session on these days. Verify against nyse.com each year.
$nyse = @{
  '2026-01-01'='CLOSED New Year';'2026-01-19'='CLOSED MLK Day';'2026-02-16'="CLOSED Presidents' Day";'2026-04-03'='CLOSED Good Friday'
  '2026-05-25'='CLOSED Memorial Day';'2026-06-19'='CLOSED Juneteenth';'2026-07-03'='CLOSED Independence Day (observed)'
  '2026-09-07'='CLOSED Labor Day';'2026-11-26'='CLOSED Thanksgiving';'2026-11-27'='EARLY CLOSE 1pm ET (day after Thanksgiving)'
  '2026-12-24'='EARLY CLOSE 1pm ET (Christmas Eve)';'2026-12-25'='CLOSED Christmas'
  '2027-01-01'='CLOSED New Year';'2027-01-18'='CLOSED MLK Day';'2027-02-15'="CLOSED Presidents' Day";'2027-03-26'='CLOSED Good Friday'
  '2027-05-31'='CLOSED Memorial Day';'2027-06-18'='CLOSED Juneteenth (observed)';'2027-07-05'='CLOSED Independence Day (observed)'
  '2027-09-06'='CLOSED Labor Day';'2027-11-25'='CLOSED Thanksgiving';'2027-11-26'='EARLY CLOSE 1pm ET (day after Thanksgiving)'
  '2027-12-24'='CLOSED Christmas (observed)'
}

# Magnificent 7 and other Nasdaq-100 heavyweights: always listed, whatever the market-cap cut-off
$mag7 = 'AAPL','MSFT','NVDA','AMZN','GOOGL','GOOG','META','TSLA'
$nqHeavy = 'AVGO','COST','NFLX','AMD','PLTR','ASML','CSCO','ADBE','QCOM','INTU','TXN','AMAT','MU','LRCX','KLAC','PANW','ARM','INTC','PEP','TMUS','ISRG','AMGN','BKNG','SBUX','CRWD','MRVL','SNPS','CDNS','ADI','PDD','MELI','ABNB','SHOP','APP','TEAM','DDOG','ORCL','CRM'

# Monthly OPEX = 3rd Friday. Mar/Jun/Sep/Dec = quad witching. If that Friday is a market holiday,
# expiry moves to Thursday. ES/NQ roll to the next contract 8 days before quad witching.
function Get-Opex([int]$y, [int]$m) {
  $f = [datetime]::new($y, $m, 15); while ($f.DayOfWeek -ne 'Friday') { $f = $f.AddDays(1) }
  if ($nyse.ContainsKey($f.ToString('yyyy-MM-dd')) -and $nyse[$f.ToString('yyyy-MM-dd')] -like 'CLOSED*') { $f = $f.AddDays(-1) }
  $f
}
