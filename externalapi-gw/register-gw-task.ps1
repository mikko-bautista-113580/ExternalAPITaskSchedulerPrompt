<#
.SYNOPSIS
    Register (or remove) the Windows Scheduled Task that generates sis-externalapi (Gateway)
    endpoints from Active sprint user stories, once each weekday at 07:00 (local time).

.DESCRIPTION
    Creates ONE task ("GW-MorningAutoPR-0700") with a single weekly (Mon-Fri) 07:00 trigger
    pointing at run-morning-gw.ps1. This is SEPARATE from "MS-PRReview" / "GW-PRReview" and from
    the per-MS generator tasks (e.g. "AdmissionMS-EndpointGen").
      - runs as the current user, InteractiveToken (so az/gh stored creds are readable)
      - IgnoreNew instance policy (a still-running slot is not doubled up)
      - StartWhenAvailable, don't stop on battery
      - 1-hour execution ceiling

    LOCAL-ONLY: the job creates a local git branch + code in c:\neldevsrc\Github\sis-externalapi
    and leaves the changes UNCOMMITTED for you to review and commit. It never commits, pushes,
    opens a PR, or writes to ADO.

    NOTE: this task was relocated out of the repo (c:\neldevsrc\Github\sis-externalapi\.scheduled)
    into the central TaskScheduler folder. Re-running this registers the task against the NEW
    wrapper path, overwriting any prior registration that pointed at the old .scheduled location.

    Registering a task at the root task-folder usually requires an ELEVATED PowerShell.
    Run this in a "Run as Administrator" pwsh window.

.EXAMPLE
    pwsh -File C:\neldevsrc\Github\TaskScheduler\externalapi-gw\register-gw-task.ps1
.EXAMPLE
    pwsh -File C:\neldevsrc\Github\TaskScheduler\externalapi-gw\register-gw-task.ps1 -RunNow
.EXAMPLE
    pwsh -File C:\neldevsrc\Github\TaskScheduler\externalapi-gw\register-gw-task.ps1 -Unregister
#>
param(
    [string]$TaskName   = 'GW-MorningAutoPR-0700',
    [string[]]$Times    = @('07:00'),
    [switch]$RunNow,
    [switch]$Unregister
)

$RepoRoot    = 'c:\neldevsrc\Github\sis-externalapi'
$WrapperPath = Join-Path $PSScriptRoot 'run-morning-gw.ps1'

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

$pwshPath = (Get-Command pwsh -ErrorAction SilentlyContinue).Source
if (-not $pwshPath) { throw "pwsh (PowerShell 7+) not found on PATH." }

# Action ---------------------------------------------------------------------
$arguments = "-ExecutionPolicy Bypass -NoProfile -File `"$WrapperPath`" -TaskName $TaskName"
$action    = New-ScheduledTaskAction -Execute $pwshPath -Argument $arguments -WorkingDirectory $RepoRoot

# Triggers: one weekly (Mon-Fri) trigger per time slot (07:00 only by default) ---
$triggers = foreach ($t in $Times) {
    New-ScheduledTaskTrigger -Weekly `
        -DaysOfWeek Monday,Tuesday,Wednesday,Thursday,Friday `
        -At ([datetime]::ParseExact($t, 'HH:mm', $null))
}

# Principal: current user, interactive token ---------------------------------
$userId    = "$env:USERDOMAIN\$env:USERNAME"
$principal = New-ScheduledTaskPrincipal -UserId $userId -LogonType Interactive -RunLevel Limited

# Settings (mirror the PR-review tasks; 1h ceiling keeps runs inside their slot) -
$settings = New-ScheduledTaskSettingsSet `
    -MultipleInstances IgnoreNew `
    -StartWhenAvailable `
    -AllowStartIfOnBatteries `
    -DontStopIfGoingOnBatteries `
    -ExecutionTimeLimit (New-TimeSpan -Hours 1)

$description = "sis-externalapi Gateway: generate endpoints (LOCAL branch + code, left UNCOMMITTED for review) for Active sprint user stories. No commit/push/PR/ADO writes. Weekdays 07:00."

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
Write-Host "Logs:    C:\neldevsrc\Github\TaskScheduler\externalapi-gw\logs\$TaskName\"

if ($RunNow) {
    Write-Host "`nTriggering a run now..." -ForegroundColor Cyan
    Start-ScheduledTask -TaskName $TaskName
    Write-Host "Started. Tail the newest log:" -ForegroundColor Cyan
    Write-Host "  Get-ChildItem `"C:\neldevsrc\Github\TaskScheduler\externalapi-gw\logs\$TaskName`" | Sort LastWriteTime -Desc | Select -First 1 | %{ Get-Content -Wait `$_.FullName }"
}
