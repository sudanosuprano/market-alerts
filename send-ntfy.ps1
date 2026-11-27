<#
  Sends a push notification to your phone through ntfy (https://ntfy.sh).
  Your private channel name is in config.json. Anyone who knows it can read the alerts, so don't share it.
  Usage:
    .\send-ntfy.ps1 -Title "Weekly report" -File reports\2026-11-30-weekly.txt
    .\send-ntfy.ps1 -Title "Test" -Message "hello"
  ntfy messages over 4 KB arrive as an attachment, so keep the phone version short.
#>
param(
  [Parameter(Mandatory)][string]$Title,
  [string]$Message,
  [string]$File,
  [ValidateSet('min','low','default','high','urgent')][string]$Priority = 'default',
  [string]$Tags = 'chart_with_upwards_trend'
)
$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
. (Join-Path $PSScriptRoot 'common.ps1')
$cfg = Get-NtfyConfig   # NTFY_TOPIC env var (GitHub secret) or config.json (PC)
if ($File) { $Message = [IO.File]::ReadAllText((Resolve-Path $File)) }
if (-not $Message) { throw 'Give -Message or -File.' }
$bytes = [Text.Encoding]::UTF8.GetBytes($Message)
if ($bytes.Length -gt 4000) { Write-Warning "Message is $($bytes.Length) bytes; ntfy will deliver it as an attachment." }
# Header values must be ASCII
$asciiTitle = -join ($Title.ToCharArray() | Where-Object { [int]$_ -lt 128 })
$headers = @{ 'Title' = $asciiTitle; 'Priority' = $Priority; 'Tags' = $Tags }
if ($cfg.clickUrl) { $headers['Click'] = $cfg.clickUrl }
$r = Invoke-RestMethod -Method Post -Uri "$($cfg.server)/$($cfg.topic)" -Body $bytes -Headers $headers -ContentType 'text/plain; charset=utf-8'
"Sent to ntfy (id $($r.id))."
