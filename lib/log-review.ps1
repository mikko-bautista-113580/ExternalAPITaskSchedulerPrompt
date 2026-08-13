# log-review.ps1 — shared post-run "process-improvement" reviewer for the scheduler jobs.
#
# Dot-source from a wrapper, then call once at the very end (after the log-retention block,
# before the final `exit $exitCode`):
#
#   . "$ScheduledDir\..\lib\log-review.ps1"
#   Invoke-LogReview -LogFile $LogFile -TaskName $TaskName -ScheduledDir $ScheduledDir `
#       -TargetRepo $RepoRoot -ClaudeCmd $ClaudeCmd -ExitCode $exitCode
#
# What it does: reads the run's own log, asks claude (Claude Opus 5) to find where the AUTOMATION
# process (wrappers / prompts / standards) can be improved, VALIDATES each fix against the
# current source, applies validated fixes as UNCOMMITTED edits to the automation repo, and
# writes a markdown report next to the log. It NEVER commits/pushes and NEVER touches the
# target repo. See lib\log-review-prompt.md for the reviewer instructions.

$script:LogReviewLibDir = $PSScriptRoot   # ...\lib

function Invoke-LogReview {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$LogFile,      # the just-completed run log
        [Parameter(Mandatory)][string]$TaskName,     # e.g. MS-PRReview
        [Parameter(Mandatory)][string]$ScheduledDir, # the project folder (…\ms-pr-review)
        [Parameter(Mandatory)][string]$TargetRepo,   # sis-services / sis-externalapi — OFF-LIMITS
        [Parameter(Mandatory)][string]$ClaudeCmd,    # %APPDATA%\npm\claude.cmd
        [int]$ExitCode = 0,
        [string]$Model = 'claude-opus-5',
        [int]$WaitSeconds = 120                       # max wait for the log to finish writing
    )

    $AutomationRepoRoot = Split-Path -Parent $ScheduledDir

    # The automation folder is not necessarily the git root -- it may be a subfolder of a larger
    # repo. `git status --porcelain` paths are always repo-root-relative, so resolve the real root
    # and scope every query to the automation subtree.
    $GitRoot = & git -C $AutomationRepoRoot rev-parse --show-toplevel 2>$null
    $GitRoot = if ($GitRoot) { (Resolve-Path ($GitRoot -replace '/','\')).Path } else { $AutomationRepoRoot }

    $PromptFile         = Join-Path $script:LogReviewLibDir 'log-review-prompt.md'
    $ReportPath         = ($LogFile -replace '\.log$', '') + '.review.md'
    $TraceFile          = ($LogFile -replace '\.log$', '') + '.review.trace.log'
    $TaskLogDir         = Split-Path -Parent $LogFile

    # Local logger: mirror the wrapper's bracketed format, append to the same run log.
    function Write-RvLog {
        param([string]$Message)
        $line = "[{0}] [log-review] {1}" -f (Get-Date -Format 'yyyy-MM-ddTHH:mm:ssK'), $Message
        Write-Host $line -ForegroundColor DarkCyan
        Add-Content -Path $LogFile -Value $line -Encoding utf8 -ErrorAction SilentlyContinue
    }

    # keep last 30 review reports/traces per task (mirrors the log-retention rule)
    function Prune-Reviews {
        foreach ($pat in @('*.review.md', '*.review.trace.log')) {
            Get-ChildItem $TaskLogDir -Filter $pat -ErrorAction SilentlyContinue |
                Sort-Object LastWriteTime -Descending |
                Select-Object -Skip 30 |
                Remove-Item -Force -ErrorAction SilentlyContinue
        }
    }

    Write-RvLog "=== post-run process review starting (task=$TaskName, exit=$ExitCode) ==="

    if (-not (Test-Path $PromptFile)) { Write-RvLog "SKIP: reviewer prompt not found at $PromptFile"; return }
    if (-not (Test-Path $ClaudeCmd))  { Write-RvLog "SKIP: claude CLI not found at $ClaudeCmd"; return }

    # ---- 1. wait for the log to be COMPLETE ----------------------------------
    # Chained after the run, the completion marker is already present; poll anyway so the
    # reviewer is safe to run standalone. Complete = "run finished" marker, OR a terminal
    # "Lock released." following a no-work / clean-exit / FATAL line (early-exit wrappers).
    function Test-LogComplete {
        param([string]$Path)
        if (-not (Test-Path $Path)) { return $false }
        $tail = @(Get-Content -Path $Path -Tail 60 -ErrorAction SilentlyContinue)
        if ($tail.Count -eq 0) { return $false }
        if ($tail -match 'run finished \(task=') { return $true }
        $joined = $tail -join "`n"
        if (($tail -match 'Lock released\.') -and ($joined -match 'nothing to|Exiting cleanly|FATAL')) { return $true }
        return $false
    }
    $waited = 0
    while (-not (Test-LogComplete -Path $LogFile) -and $waited -lt $WaitSeconds) {
        Start-Sleep -Seconds 5; $waited += 5
    }
    if (-not (Test-LogComplete -Path $LogFile)) {
        Write-RvLog "SKIP: log not complete after ${WaitSeconds}s — not reviewing a partial log."
        return
    }

    $logText = Get-Content -Path $LogFile -Raw -ErrorAction SilentlyContinue
    if (-not $logText) { Write-RvLog "SKIP: log is empty."; return }

    # ---- 2. no-work skip (cost guard) ----------------------------------------
    # Only skip a truly clean no-op: exit 0, the run cost $0 (claude never launched), no
    # problem signals. Keyed on the wrapper's authoritative end-of-run cost milestone
    # ("Run cost: $0.000000  (claude launched: no)") — NOT on the word "launching", because
    # the skip milestone literally says "Not launching claude", which a naive substring match
    # would misread as a launch. Failed runs and any run with WARN/FATAL/errors are always reviewed.
    $costZero    = ($logText -match 'claude launched:\s*no') -or ($logText -match 'Run cost:\s*\$?0\.0+(\s|,|$)')
    $hadProblems = $logText -match 'WARN:|FATAL|FAILED|\[claude:tool<-ERROR\]|Exit code [1-9]|exit code [1-9]'
    if ($ExitCode -eq 0 -and $costZero -and -not $hadProblems) {
        Write-RvLog "No-work run (cost `$0, no problems) — nothing to review; no report generated, claude not launched."
        Prune-Reviews
        return
    }

    # ---- 3. compounding guard: only auto-apply on a clean automation tree ----
    # If the automation repo already has pending (uncommitted) changes, run REPORT-ONLY so
    # unreviewed edits can't stack across back-to-back scheduled runs.
    $pending = @(git -C $GitRoot status --porcelain -- $AutomationRepoRoot 2>$null)
    $applyMode = if ($pending.Count -gt 0) { 'report-only' } else { 'apply' }
    if ($applyMode -eq 'report-only') {
        Write-RvLog "Automation tree has $($pending.Count) pending change(s) — running REPORT-ONLY (no auto-patch) to avoid compounding."
    } else {
        Write-RvLog "Automation tree clean — running in APPLY mode (validated fixes -> uncommitted edits)."
    }

    # ---- 4. build prompt + launch claude -------------------------------------
    $Prompt = Get-Content $PromptFile -Raw
    $Prompt = $Prompt.Replace('{{LOG_FILE}}',              $LogFile)
    $Prompt = $Prompt.Replace('{{TASK_NAME}}',             $TaskName)
    $Prompt = $Prompt.Replace('{{AUTOMATION_REPO_ROOT}}',  $AutomationRepoRoot)
    $Prompt = $Prompt.Replace('{{SCHEDULED_DIR}}',         $ScheduledDir)
    $Prompt = $Prompt.Replace('{{TARGET_REPO}}',           $TargetRepo)
    $Prompt = $Prompt.Replace('{{REPORT_PATH}}',           $ReportPath)
    $Prompt = $Prompt.Replace('{{APPLY_MODE}}',            $applyMode)

    Write-RvLog "Launching claude (model=$Model, mode=$applyMode) to review this run's log..."
    "" | Set-Content -Path $TraceFile -Encoding utf8 -ErrorAction SilentlyContinue

    Push-Location $AutomationRepoRoot
    try {
        $Prompt | & $ClaudeCmd `
            --print `
            --verbose `
            --dangerously-skip-permissions `
            --model $Model `
            --output-format stream-json `
            --input-format text 2>&1 |
            ForEach-Object {
                Add-Content -Path $TraceFile -Value $_ -Encoding utf8 -ErrorAction SilentlyContinue
                # light surfacing of the final result line into the run log
                if ($_ -match '"type"\s*:\s*"result"') {
                    if ($_ -match '"subtype"\s*:\s*"([^"]+)"') { Write-RvLog "claude result: $($Matches[1])" }
                    if ($_ -match '"total_cost_usd"\s*:\s*([0-9.]+)') { Write-RvLog "claude cost: `$$($Matches[1])" }
                }
            }
        $rc = $LASTEXITCODE
        Write-RvLog "claude (reviewer) exited with code $rc"
    } catch {
        Write-RvLog "EXCEPTION launching reviewer: $_"
    } finally {
        Pop-Location
    }

    # ---- 5. validity net: parse-gate any .ps1 the reviewer changed -----------
    # The prompt tells the agent to parse-check its own edits; this is a hard backstop.
    # Any changed/added .ps1 that fails to parse is reverted so a broken script can never
    # reach the next scheduled run.
    if ($applyMode -eq 'apply') {
        $changed = @(git -C $GitRoot status --porcelain -- $AutomationRepoRoot 2>$null)
        foreach ($entry in $changed) {
            # porcelain: "XY path" (path may be quoted / renamed "old -> new")
            $path = ($entry.Substring(3)).Trim('"')
            if ($path -match '->') { $path = ($path -split '->')[-1].Trim().Trim('"') }
            if ($path -notmatch '\.ps1$') { continue }
            $full = Join-Path $GitRoot $path
            if (-not (Test-Path $full)) { continue }
            $errs = $null
            [System.Management.Automation.Language.Parser]::ParseFile($full, [ref]$null, [ref]$errs) | Out-Null
            if ($errs -and $errs.Count -gt 0) {
                $status = $entry.Substring(0,2)
                if ($status -match '\?\?') {
                    Remove-Item -Force $full -ErrorAction SilentlyContinue   # new file — delete
                } else {
                    git -C $GitRoot checkout -- $path 2>$null                 # tracked — revert
                }
                Write-RvLog "REVERTED $path — reviewer edit had $($errs.Count) parse error(s); not letting a broken script through."
            }
        }
    }

    if (Test-Path $ReportPath) { Write-RvLog "Report: $ReportPath" }
    else { Write-RvLog "WARN: reviewer did not produce a report at $ReportPath" }

    $touched = @(git -C $GitRoot status --porcelain -- $AutomationRepoRoot 2>$null)
    if ($touched.Count -gt 0 -and $applyMode -eq 'apply') {
        Write-RvLog "Uncommitted change(s) applied (review with 'git -C $AutomationRepoRoot diff'; nothing was committed)."
    }

    Prune-Reviews
    Write-RvLog "=== post-run process review finished (task=$TaskName) ==="
}
