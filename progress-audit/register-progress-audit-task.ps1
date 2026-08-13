<#
.SYNOPSIS
    Register (or remove) the Windows Scheduled Task that runs the AI progress audit
    weekly on Monday at 08:00 (local time).

.DESCRIPTION
    Creates ONE task ("AIProgress-Audit") with a single weekly Monday trigger pointing at
    run-progress-audit.ps1. Mirrors the proven GW-PRReview config:
      - runs as the current user, InteractiveToken (so stored creds are readable)
      - IgnoreNew instance policy (a still-running audit is not doubled up)
      - StartWhenAvailable (a missed Monday runs when the machine comes back)

    Monday 08:00 is deliberate: it lands the audit at the start of the week the leads report on,
    and benefitED's phase windows are Monday-aligned.

    Registering a task at the root task-folder usually requires an ELEVATED PowerShell.
    Run this in a "Run as Administrator" pwsh window.

.EXAMPLE
    pwsh -File C:\neldevsrc\Github\ExternalAPITaskSchedulerPrompt\progress-audit\register-progress-audit-task.ps1
.EXAMPLE
    pwsh -File C:\neldevsrc\Github\ExternalAPITaskSchedulerPrompt\progress-audit\register-progress-audit-task.ps1 -RunNow
.EXAMPLE
    pwsh -File C:\neldevsrc\Github\ExternalAPITaskSchedulerPrompt\progress-audit\register-progress-audit-task.ps1 -DraftOnly   # scheduled runs draft, never publish
.EXAMPLE
    pwsh -File C:\neldevsrc\Github\ExternalAPITaskSchedulerPrompt\progress-audit\register-progress-audit-task.ps1 -Unregister
#>
param(
    [string]$TaskName = 'AIProgress-Audit',
    [string]$Time     = '08:00',
    [string]$Day      = 'Monday',
    [string]$Model    = '',        # '' => wrapper default (claude-opus-5). e.g. 'sonnet'.
    [switch]$DraftOnly,            # register the task so every scheduled run drafts and never publishes
    [switch]$RunNow,
    [switch]$Unregister
)

$WrapperPath = Join-Path $PSScriptRoot 'run-progress-audit.ps1'
# Working directory for the scheduled task: two levels above this folder. Cosmetic only -- the
# wrapper resolves the prompt, roadmaps, lib\ and the skills root from its own $PSScriptRoot, so
# this just needs to be a stable directory that exists.
$RepoRoot    = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)

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
# Microsoft Store build that resolves to a version-stamped WindowsApps path which the Store
# DELETES on every auto-update, leaving the task pointing at a missing file (0x80070002).
$pwshCandidates = @(
    "$env:ProgramFiles\PowerShell\7\pwsh.exe",
    (Join-Path $env:LOCALAPPDATA 'Microsoft\WindowsApps\pwsh.exe')
)
$pwshPath = $pwshCandidates | Where-Object { Test-Path $_ } | Select-Object -First 1
if (-not $pwshPath) { $pwshPath = (Get-Command pwsh -ErrorAction SilentlyContinue).Source }
if (-not $pwshPath) { throw "pwsh (PowerShell 7+) not found." }
if ($pwshPath -like '*\WindowsApps\Microsoft.PowerShell_*') {
    Write-Warning "Resolved a version-stamped Store path ($pwshPath); this breaks on the next PowerShell update. Install the PowerShell 7 MSI for a stable path."
}

# Action ---------------------------------------------------------------------
$modelArg  = if ($Model)     { " -Model $Model" } else { '' }
$draftArg  = if ($DraftOnly) { ' -DraftOnly' }    else { '' }
$arguments = "-ExecutionPolicy Bypass -NoProfile -File `"$WrapperPath`" -TaskName $TaskName$modelArg$draftArg"
$action    = New-ScheduledTaskAction -Execute $pwshPath -Argument $arguments -WorkingDirectory $RepoRoot

# Trigger: one weekly run --------------------------------------------------
$trigger = New-ScheduledTaskTrigger -Weekly -DaysOfWeek $Day -At ([datetime]::ParseExact($Time, 'HH:mm', $null))

# Principal: current user, interactive token ---------------------------------
$userId    = "$env:USERDOMAIN\$env:USERNAME"
$principal = New-ScheduledTaskPrincipal -UserId $userId -LogonType Interactive -RunLevel Limited

$settings = New-ScheduledTaskSettingsSet `
    -MultipleInstances IgnoreNew `
    -StartWhenAvailable `
    -AllowStartIfOnBatteries `
    -DontStopIfGoingOnBatteries `
    -ExecutionTimeLimit (New-TimeSpan -Hours 1)

$mode = if ($DraftOnly) { 'draft-only' } else { 'publish when clean' }
$description = "AI progress audit: score each team against their AI roadmap as of the run date and update the progress artifact ($mode; holds on any regression or overdue phase). $Day $Time."

Register-ScheduledTask -TaskName $TaskName `
    -Action $action -Trigger $trigger -Principal $principal -Settings $settings `
    -Description $description -Force | Out-Null

Write-Host "Registered scheduled task '$TaskName'." -ForegroundColor Green
Write-Host "  Runs as : $userId (InteractiveToken - only while you are logged on)"
Write-Host "  Command : $pwshPath $arguments"
Write-Host "  When    : $Day $Time (local time)"
Write-Host "  Mode    : $mode"
Write-Host ""
Write-Host "Verify:  Get-ScheduledTask -TaskName '$TaskName' | Get-ScheduledTaskInfo"
Write-Host "Run now: Start-ScheduledTask -TaskName '$TaskName'"
Write-Host "Logs:    $PSScriptRoot\logs\$TaskName\"

if ($RunNow) {
    Write-Host "`nTriggering a run now..." -ForegroundColor Cyan
    Start-ScheduledTask -TaskName $TaskName
    Write-Host "Started. Tail the newest log:" -ForegroundColor Cyan
    Write-Host "  Get-ChildItem `"$PSScriptRoot\logs\$TaskName`" | Sort LastWriteTime -Desc | Select -First 1 | %{ Get-Content -Wait `$_.FullName }"
}
