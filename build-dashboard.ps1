<#
  Builds dashboard.html: the whole trading week on one page.
  Reads data\week-current-data.json (made by: gather-data.ps1 -Mode weekly -Week current)
  and the breaking-news alerts in data\news-log.txt. Local only, no internet needed.
  -Refresh also re-gathers the week's data first (used by the hourly task).
#>
param([switch]$Refresh)
$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot
$dataDir = Join-Path $root 'data'
if ($Refresh) {
  & (Join-Path $root 'gather-data.ps1') -Mode weekly -Week current -Quiet
  try { & (Join-Path $root 'gather-ahead.ps1') } catch { Write-Warning "gather-ahead failed: $($_.Exception.Message)" }
}
$aheadFile = Join-Path $dataDir 'ahead-data.json'
$ahead = if (Test-Path $aheadFile) { [IO.File]::ReadAllText($aheadFile).TrimStart([char]0xFEFF) } else { 'null' }

$weekFile = Join-Path $dataDir 'week-current-data.json'
$week = if (Test-Path $weekFile) { [IO.File]::ReadAllText($weekFile).TrimStart([char]0xFEFF) } else { 'null' }

# Breaking-news alerts from the last 3 days
$news = @()
$log = Join-Path $dataDir 'news-log.txt'
if (Test-Path $log) {
  $cut = [DateTimeOffset]::Now.AddDays(-7)
  foreach ($l in [IO.File]::ReadAllLines($log)) {
    if ($l -match '^(\d{4}-\d\d-\d\d \d\d:\d\d:\d\d) (?:ALERT|NOTE) \[(\d+)\] (.*?)(?: \| (https?://\S+))?(?: \| pub=(\S+))?$') {
      # Prefer the article's publish time; older log lines only have the time it was logged
      $t = if ($matches[5]) { [DateTimeOffset]::Parse($matches[5]) } else { [DateTimeOffset]::new([datetime]::ParseExact($matches[1], 'yyyy-MM-dd HH:mm:ss', $null)) }
      if ($t -ge $cut) { $news += [ordered]@{ t = $t.ToString('o'); score = [int]$matches[2]; text = $matches[3]; link = $matches[4] } }
    }
  }
}
# Same story can be logged more than once (tests, re-runs): keep the newest per headline
$seenText = @{}; $newsOut = @()
foreach ($n in ($news | Sort-Object { $_.t } -Descending)) {
  $k = if ($n.link) { ($n.link -split '\?')[0].ToLower() } else { $n.text.ToLower() }
  if (-not $seenText[$k]) { $seenText[$k] = 1; $newsOut += $n }
}
$newsJson = ConvertTo-Json -InputObject @($newsOut | Select-Object -First 200) -Depth 3
$reports = Get-ChildItem (Join-Path $root 'reports') -Filter '*-weekly.md' -ErrorAction SilentlyContinue | Sort-Object Name -Descending | Select-Object -First 1
$reportHref = if ($reports) { 'reports/' + $reports.Name } else { '' }

$template = [IO.File]::ReadAllText((Join-Path $root 'dashboard-template.html'))
$html = $template.Replace('/*WEEK_DATA*/null', $week).Replace('/*AHEAD_DATA*/null', $ahead).Replace('/*NEWS_DATA*/[]', $newsJson).Replace('/*REPORT_HREF*/', $reportHref).Replace('/*BUILT_AT*/', [DateTimeOffset]::UtcNow.ToString('o'))
[IO.File]::WriteAllText((Join-Path $root 'dashboard.html'), $html, (New-Object Text.UTF8Encoding $false))

# On GitHub: also publish to docs\ (served by GitHub Pages) with the latest Sunday report next to it
if ($env:GITHUB_ACTIONS -eq 'true') {
  $docs = Join-Path $root 'docs'; New-Item -ItemType Directory -Force (Join-Path $docs 'reports') | Out-Null
  [IO.File]::WriteAllText((Join-Path $docs 'index.html'), $html, (New-Object Text.UTF8Encoding $false))
  if ($reports) { Copy-Item $reports.FullName (Join-Path $docs "reports/$($reports.Name)") -Force }
  if (-not (Test-Path (Join-Path $docs '.nojekyll'))) { New-Item -ItemType File (Join-Path $docs '.nojekyll') | Out-Null }
}
