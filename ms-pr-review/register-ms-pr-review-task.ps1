<#
.SYNOPSIS
    Register (or remove) the Windows Scheduled Task that runs the SIS Services (microservices)
    PR review 6x/day on weekdays: 08:00, 10:00, 12:00, 14:00, 16:00, 18:00 (local time).

.DESCRIPTION
    Creates ONE task ("MS-PRReview") with six weekly (Mon-Fri) time triggers, all pointing
    at run-ms-pr-review.ps1. This is a SEPARATE task from the gateway "GW-PRReview" — the two
    run independently, target different repos, and write to different output folders.
      - runs as the current user, InteractiveToken (so gh's stored creds are readable)
      - IgnoreNew instance policy (a still-running slot is not doubled up)
      - StartWhenAvailable, don't stop on battery

    Registering a task at the root task-folder usually requires an ELEVATED PowerShell.
    Run this in a "Run as Administrator" pwsh window.

.EXAMPLE
    pwsh -File C:\neldevsrc\Github\TaskScheduler\ms-pr-review\register-ms-pr-review-task.ps1
.EXAMPLE
    pwsh -File C:\neldevsrc\Github\TaskScheduler\ms-pr-review\register-ms-pr-review-task.ps1 -RunNow      # register, then trigger once now
.EXAMPLE
    pwsh -File C:\neldevsrc\Github\TaskScheduler\ms-pr-review\register-ms-pr-review-task.ps1 -Model sonnet
.EXAMPLE
    pwsh -File C:\neldevsrc\Github\TaskScheduler\ms-pr-review\register-ms-pr-review-task.ps1 -Unregister
#>
param(
    [string]$TaskName   = 'MS-PRReview',
    [string[]]$Times    = @('08:00','10:00','12:00','14:00','16:00','18:00'),
    [string]$Model      = '',            # '' => wrapper default (opus). e.g. 'sonnet' to override.
    [switch]$RunNow,
    [switch]$Unregister
)

$RepoRoot    = 'c:\neldevsrc\Github\sis-services'
$WrapperPath = Join-Path $PSScriptRoot 'run-ms-pr-review.ps1'

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
$modelArg  = if ($Model) { " -Model $Model" } else { '' }
$arguments = "-ExecutionPolicy Bypass -NoProfile -File `"$WrapperPath`" -TaskName $TaskName$modelArg"
$action    = New-ScheduledTaskAction -Execute $pwshPath -Argument $arguments -WorkingDirectory $RepoRoot

# Triggers: one weekly (Mon-Fri) trigger per time slot -----------------------
$triggers = foreach ($t in $Times) {
    New-ScheduledTaskTrigger -Weekly `
        -DaysOfWeek Monday,Tuesday,Wednesday,Thursday,Friday `
        -At ([datetime]::ParseExact($t, 'HH:mm', $null))
}

# Principal: current user, interactive token (matches GW-PRReview) -----------
$userId    = "$env:USERDOMAIN\$env:USERNAME"
$principal = New-ScheduledTaskPrincipal -UserId $userId -LogonType Interactive -RunLevel Limited

# Settings (mirror the gateway task; 1h ceiling keeps runs inside their slot) -
$settings = New-ScheduledTaskSettingsSet `
    -MultipleInstances IgnoreNew `
    -StartWhenAvailable `
    -AllowStartIfOnBatteries `
    -DontStopIfGoingOnBatteries `
    -ExecutionTimeLimit (New-TimeSpan -Hours 1)

$description = "SIS Services (microservices): read-only PR review (Junie & Paul's open PRs) -> HTML reports in Downloads\PR Review MS. Weekdays 08/10/12/14/16/18."

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
Write-Host "Logs:    C:\neldevsrc\Github\TaskScheduler\ms-pr-review\logs\$TaskName\"

if ($RunNow) {
    Write-Host "`nTriggering a run now..." -ForegroundColor Cyan
    Start-ScheduledTask -TaskName $TaskName
    Write-Host "Started. Tail the newest log:" -ForegroundColor Cyan
    Write-Host "  Get-ChildItem `"C:\neldevsrc\Github\TaskScheduler\ms-pr-review\logs\$TaskName`" | Sort LastWriteTime -Desc | Select -First 1 | %{ Get-Content -Wait `$_.FullName }"
}
