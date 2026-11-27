<#
  Registers the breaking-news watcher with Windows Task Scheduler: every 5 minutes, hidden, only while you're logged in.
  Run again to update it. To remove it:
    Unregister-ScheduledTask -TaskName 'SUDDY News Watcher' -Confirm:$false
#>
param([int]$EveryMinutes = 5)
$script = Join-Path $PSScriptRoot 'news-watch.ps1'
$taskArgs = "--headless powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$script`""
$action  = New-ScheduledTaskAction -Execute 'conhost.exe' -Argument $taskArgs -WorkingDirectory $PSScriptRoot
$trigger = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(1) -RepetitionInterval (New-TimeSpan -Minutes $EveryMinutes)
$settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -DontStopIfGoingOnBatteries -AllowStartIfOnBatteries -MultipleInstances IgnoreNew -ExecutionTimeLimit (New-TimeSpan -Minutes 4)
Register-ScheduledTask -TaskName 'SUDDY News Watcher' -Action $action -Trigger $trigger -Settings $settings -Description 'Pushes market-moving headlines to phone via ntfy' -Force | Out-Null

# Dashboard calendar data: refresh every hour (ForexFactory, Nasdaq earnings, holidays)
$dash = Join-Path $PSScriptRoot 'build-dashboard.ps1'
$action2  = New-ScheduledTaskAction -Execute 'conhost.exe' -Argument "--headless powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$dash`" -Refresh" -WorkingDirectory $PSScriptRoot
$trigger2 = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(2) -RepetitionInterval (New-TimeSpan -Hours 1)
$settings2 = New-ScheduledTaskSettingsSet -StartWhenAvailable -DontStopIfGoingOnBatteries -AllowStartIfOnBatteries -MultipleInstances IgnoreNew -ExecutionTimeLimit (New-TimeSpan -Minutes 10)
Register-ScheduledTask -TaskName 'SUDDY Dashboard Data' -Action $action2 -Trigger $trigger2 -Settings $settings2 -Description 'Refreshes the market week dashboard data hourly' -Force | Out-Null

Get-ScheduledTask -TaskName 'SUDDY*' | Select-Object TaskName, State

