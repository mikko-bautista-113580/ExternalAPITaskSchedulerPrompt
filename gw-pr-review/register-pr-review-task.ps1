<#
.SYNOPSIS
    Register (or remove) the Windows Scheduled Task that runs the SIS External API
    PR review 6x/day on weekdays: 08:00, 10:00, 12:00, 14:00, 16:00, 18:00 (local time).

.DESCRIPTION
    Creates ONE task ("GW-PRReview") with six weekly (Mon-Fri) time triggers, all pointing
    at run-pr-review.ps1. Mirrors the proven GW-MorningAutoPR-0700 config:
      - runs as the current user, InteractiveToken (so gh's stored creds are readable)
      - IgnoreNew instance policy (a still-running slot is not doubled up)
      - StartWhenAvailable, don't stop on battery

    Registering a task at the root task-folder usually requires an ELEVATED PowerShell.
    Run this in a "Run as Administrator" pwsh window.

.EXAMPLE
    pwsh -File C:\neldevsrc\Github\TaskScheduler\gw-pr-review\register-pr-review-task.ps1
.EXAMPLE
    pwsh -File C:\neldevsrc\Github\TaskScheduler\gw-pr-review\register-pr-review-task.ps1 -RunNow      # register, then trigger once now
.EXAMPLE
    pwsh -File C:\neldevsrc\Github\TaskScheduler\gw-pr-review\register-pr-review-task.ps1 -Model sonnet
.EXAMPLE
    pwsh -File C:\neldevsrc\Github\TaskScheduler\gw-pr-review\register-pr-review-task.ps1 -Unregister
#>
param(
    [string]$TaskName   = 'GW-PRReview',
    [string[]]$Times    = @('08:00','10:00','12:00','14:00','16:00','18:00'),
    [string]$Model      = '',            # '' => wrapper default (claude-opus-5). e.g. 'sonnet' to override.
    [switch]$RunNow,
    [switch]$Unregister
)

$RepoRoot    = 'c:\neldevsrc\Github\sis-externalapi'
$WrapperPath = Join-Path $PSScriptRoot 'run-pr-review.ps1'

if ($Unregister) {
    if (Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue) {
        Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
        Write-Host "Removed scheduled task '$TaskName'." -ForegroundColor Yellow
    } else {
        Write-Host "No scheduled task named '$TaskName' found." -ForegroundColor Yellow
    }
    return
}

if (-not (Test-Path $WrapperPath)) { throw "Wrapper not found at $WrapperPath" }

# Resolve a STABLE pwsh.exe. Do NOT use (Get-Command pwsh).Source directly: for the
# Microsoft Store build that resolves to a version-stamped WindowsApps path
# (…\Microsoft.PowerShell_7.6.3.0_x64…\pwsh.exe) which the Store DELETES on every auto-update,
# leaving the scheduled task pointing at a missing file (fails with 0x80070002). Prefer paths
# that survive updates: the MSI install, then the unversioned WindowsApps execution alias.
$pwshCandidates = @(
    "$env:ProgramFiles\PowerShell\7\pwsh.exe",
    (Join-Path $env:LOCALAPPDATA 'Microsoft\WindowsApps\pwsh.exe')
)
$pwshPath = $pwshCandidates | Where-Object { Test-Path $_ } | Select-Object -First 1
if (-not $pwshPath) {
    # Last resort: whatever's on PATH (may be a volatile versioned Store path).
    $pwshPath = (Get-Command pwsh -ErrorAction SilentlyContinue).Source
}
if (-not $pwshPath) { throw "pwsh (PowerShell 7+) not found." }
if ($pwshPath -like '*\WindowsApps\Microsoft.PowerShell_*') {
    Write-Warning "Resolved a version-stamped Store path ($pwshPath); this breaks on the next PowerShell update. Install the PowerShell 7 MSI for a stable path."
}

# Action ---------------------------------------------------------------------
$modelArg  = if ($Model) { " -Model $Model" } else { '' }
$arguments = "-ExecutionPolicy Bypass -NoProfile -File `"$WrapperPath`" -TaskName $TaskName$modelArg"
$action    = New-ScheduledTaskAction -Execute $pwshPath -Argument $arguments -WorkingDirectory $RepoRoot

# Triggers: one weekly (Mon-Fri) trigger per time slot -----------------------
$triggers = foreach ($t in $Times) {
    New-ScheduledTaskTrigger -Weekly `
        -DaysOfWeek Monday,Tuesday,Wednesday,Thursday,Friday `
        -At ([datetime]::ParseExact($t, 'HH:mm', $null))
}

# Principal: current user, interactive token (matches GW-MorningAutoPR-0700) --
$userId    = "$env:USERDOMAIN\$env:USERNAME"
$principal = New-ScheduledTaskPrincipal -UserId $userId -LogonType Interactive -RunLevel Limited

# Settings (mirror the existing task; 1h ceiling keeps runs inside their slot) -
$settings = New-ScheduledTaskSettingsSet `
    -MultipleInstances IgnoreNew `
    -StartWhenAvailable `
    -AllowStartIfOnBatteries `
    -DontStopIfGoingOnBatteries `
    -ExecutionTimeLimit (New-TimeSpan -Hours 1)

$description = "SIS External API: read-only PR review (teammates' open PRs, auto-detected per user) -> HTML reports in Downloads\PR Review. Weekdays 08/10/12/14/16/18."

Register-ScheduledTask -TaskName $TaskName `
    -Action $action -Trigger $triggers -Principal $principal -Settings $settings `
    -Description $description -Force | Out-Null

Write-Host "Registered scheduled task '$TaskName'." -ForegroundColor Green
Write-Host "  Runs as : $userId (InteractiveToken - only while you are logged on)"
Write-Host "  Command : $pwshPath $arguments"
Write-Host "  Times   : $($Times -join ', ')  (Mon-Fri, local time)"
Write-Host ""
Write-Host "Verify:  Get-ScheduledTask -TaskName '$TaskName' | Get-ScheduledTaskInfo"
Write-Host "Run now: Start-ScheduledTask -TaskName '$TaskName'"
Write-Host "Logs:    C:\neldevsrc\Github\TaskScheduler\gw-pr-review\logs\$TaskName\"

if ($RunNow) {
    Write-Host "`nTriggering a run now..." -ForegroundColor Cyan
    Start-ScheduledTask -TaskName $TaskName
    Write-Host "Started. Tail the newest log:" -ForegroundColor Cyan
    Write-Host "  Get-ChildItem `"C:\neldevsrc\Github\TaskScheduler\gw-pr-review\logs\$TaskName`" | Sort LastWriteTime -Desc | Select -First 1 | %{ Get-Content -Wait `$_.FullName }"
}
