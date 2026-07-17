param(
    [string]$TaskName = 'manual',
    # Model alias passed to the claude CLI. 'opus' = latest Opus (best for full semantic
    # review). Switch to 'sonnet' if you want cheaper/faster runs across the 6 daily slots.
    [string]$Model = 'opus'
)

$ErrorActionPreference = 'Continue'

$RepoRoot     = 'c:\neldevsrc\Github\sis-externalapi'
$ScheduledDir = 'C:\neldevsrc\Github\TaskScheduler\gw-pr-review'   # automation files (moved out of the repo)
$LogDir       = Join-Path $ScheduledDir 'logs'
$PromptFile   = Join-Path $ScheduledDir 'pr-review-prompt.md'
$TemplateFile = Join-Path $ScheduledDir 'pr-review-template.html'
$ClaudeCmd    = "$env:APPDATA\npm\claude.cmd"
$OutputDir    = 'C:\Users\lbautist\Downloads\PR Review'

$TaskLogDir = Join-Path $LogDir $TaskName
if (-not (Test-Path $TaskLogDir)) { New-Item -ItemType Directory -Path $TaskLogDir -Force | Out-Null }

$Timestamp = Get-Date -Format 'yyyyMMdd_HHmmss'
$LogFile   = Join-Path $TaskLogDir "${TaskName}_$Timestamp.log"

function Write-Log {
    param([string]$Message)
    $line = "[{0}] {1}" -f (Get-Date -Format 'yyyy-MM-ddTHH:mm:ssK'), $Message
    Write-Host $line
    Add-Content -Path $LogFile -Value $line -Encoding utf8
}

function Write-Milestone {
    param([string]$icon, [string]$message)
    $line = "{0}    === {1} {2}" -f (Get-Date -Format 'yyyy-MM-ddTHH:mm:ssK'), $icon, $message
    Write-Host $line -ForegroundColor Cyan
    Add-Content -Path $LogFile -Value $line -Encoding utf8
}

Write-Log "=== pr-review run started (task=$TaskName, model=$Model) ==="
Write-Log "Repo:   $RepoRoot"
Write-Log "Output: $OutputDir"
Write-Log "Log:    $LogFile"
Write-Log "Tail this log live:  Get-Content -Wait -Path `"$LogFile`""

# ---- pre-flight (wrapper side) --------------------------------------------
if (-not (Test-Path $ClaudeCmd))    { Write-Log "FATAL: claude CLI not found at $ClaudeCmd"; exit 1 }
if (-not (Test-Path $PromptFile))   { Write-Log "FATAL: prompt file not found at $PromptFile"; exit 1 }
if (-not (Test-Path $TemplateFile)) { Write-Log "FATAL: HTML template not found at $TemplateFile"; exit 1 }
if (-not (Test-Path $RepoRoot))     { Write-Log "FATAL: repo directory not found at $RepoRoot"; exit 1 }
if (-not (Test-Path $OutputDir))    { New-Item -ItemType Directory -Path $OutputDir -Force | Out-Null; Write-Log "Created output dir $OutputDir" }

Set-Location $RepoRoot

# gh must be authenticated for nelnet-nbs. Fail fast with an actionable message.
$ghOk = $false
try {
    $ghStatus = gh auth status 2>&1 | Out-String
    if ($LASTEXITCODE -eq 0) { $ghOk = $true }
    Write-Log ("gh auth status:`n" + $ghStatus.Trim())
} catch {
    Write-Log "gh auth status threw: $_"
}
if (-not $ghOk) {
    Write-Milestone 'X' "gh CLI not authenticated -- aborting."
    Write-Log "FATAL: gh CLI is not authenticated for nelnet-nbs."
    Write-Log "       Fix once (interactively): gh auth login  (choose GitHub.com > HTTPS > browser)"
    Write-Log "       then authorize the token for the 'nelnet-nbs' org SSO. See C:\neldevsrc\Github\TaskScheduler\gw-pr-review\README-pr-review.md."
    exit 1
}

# ---- concurrency guard -----------------------------------------------------
$LockFile = Join-Path $ScheduledDir '.pr-review.lock'
if (Test-Path $LockFile) {
    $lockAge = (Get-Date) - (Get-Item $LockFile).LastWriteTime
    if ($lockAge.TotalMinutes -lt 90) {
        Write-Log "ABORT: another pr-review run is in progress (lock age $([math]::Round($lockAge.TotalMinutes,1)) min). Exiting."
        exit 0
    }
    Write-Log "WARN: stale lock (age $([math]::Round($lockAge.TotalHours,1))h) -- removing and proceeding."
    Remove-Item -Force $LockFile -ErrorAction SilentlyContinue
}
"$TaskName $Timestamp PID=$PID" | Out-File -FilePath $LockFile -Encoding utf8

try {
    # Read-only guarantee: record branch + HEAD; assert unchanged at exit.
    $branchBefore = (git rev-parse --abbrev-ref HEAD 2>&1).Trim()
    $headBefore   = (git rev-parse HEAD 2>&1).Trim()
    Write-Log "Branch before: $branchBefore   HEAD before: $headBefore"

    # Fetch is read-only w.r.t. the working tree; makes origin/main + PR refs current.
    Write-Log "Fetching origin (prune) ..."
    git fetch --prune origin 2>&1 | ForEach-Object { Write-Log "[git fetch] $_" }
    if ($LASTEXITCODE -ne 0) { Write-Log "WARN: git fetch failed (exit=$LASTEXITCODE) -- continuing; gh calls may still work." }

    # Snapshot existing reports so we can report just this run's output.
    $reportsBefore = @{}
    Get-ChildItem $OutputDir -Filter 'PR-*.html' -ErrorAction SilentlyContinue |
        ForEach-Object { $reportsBefore[$_.Name] = $_.LastWriteTime }
    $runStart = Get-Date

    # --- "1 PR = 1 HTML": skip launching claude if every eligible open PR already has a report ---
    # Conservative pre-check (draft + author/assignee + <=7d + has-report). It only PREVENTS a
    # launch when it's certain there's nothing to do; the prompt still owns the full filter
    # (incl. skip-if-you-approved). Any gh/parse error falls through to launching claude.
    $skipClaude = $false
    try {
        $reviewAuthors = @('junie-perez-110467','paul-gatchalian-110466')
        $openJson = gh pr list --repo nelnet-nbs/sis-externalapi --state open --limit 100 --json number,author,assignees,isDraft,updatedAt 2>$null
        if ($LASTEXITCODE -eq 0 -and $openJson) {
            $openPrs = $openJson | ConvertFrom-Json
            $reviewed = @{}
            Get-ChildItem $OutputDir -Filter 'PR-*.html' -ErrorAction SilentlyContinue |
                ForEach-Object { if ($_.Name -match '^PR-(\d+)-') { $reviewed[[int]$Matches[1]] = $true } }
            $cutoff = (Get-Date).AddDays(-7)
            $todo = @($openPrs | Where-Object {
                (-not $_.isDraft) -and
                (($reviewAuthors -contains $_.author.login) -or (@($_.assignees.login) | Where-Object { $reviewAuthors -contains $_ })) -and
                ([datetime]$_.updatedAt -ge $cutoff) -and
                (-not $reviewed.ContainsKey([int]$_.number))
            })
            if ($todo.Count -eq 0) {
                $skipClaude = $true
                Write-Milestone 'i' "No un-reviewed eligible PRs -- every one already has a report. Not launching claude (1 PR = 1 HTML)."
            } else {
                Write-Milestone '>' "Un-reviewed candidate PR(s): $(($todo.number | Sort-Object) -join ', ')"
            }
        } else {
            Write-Log "Pre-check: 'gh pr list' failed or returned nothing; launching claude and letting the prompt decide."
        }
    } catch {
        Write-Log "Pre-check error (non-fatal): $_  -- launching claude anyway."
    }

    # ----- stream-json event parser (detailed log + PR-review milestones) ---
    $script:m = @{ GhSeen=$false; GitSeen=$false; ReviewListSeen=$false; Reviewed=0; AgentsDispatched=0 }
    $script:TotalCostUsd = 0.0

    function Format-ToolUseSummary {
        param($name, $input)
        if ($null -eq $input) { return "$name (no input)" }
        switch ($name) {
            'Bash'       { return "Bash: $(($input.command -replace '\s+', ' ') -replace '^(.{0,160}).*', '$1')" }
            'PowerShell' { return "PowerShell: $(($input.command -replace '\s+', ' ') -replace '^(.{0,160}).*', '$1')" }
            'Read'       { return "Read: $($input.file_path)" }
            'Write'      { return "Write: $($input.file_path)" }
            'Glob'       { return "Glob: $($input.pattern)" }
            'Grep'       { return "Grep: $($input.pattern)" }
            'TodoWrite'  { return "TodoWrite: $((($input.todos) | ForEach-Object { '[' + $_.status[0] + '] ' + $_.content }) -join ' | ')" }
            { $_ -eq 'Agent' -or $_ -eq 'Task' } {
                $sub = if ($input.subagent_type) { $input.subagent_type } else { 'agent' }
                $desc = if ($input.description) { $input.description } elseif ($input.prompt) { ($input.prompt -replace '\s+', ' ') -replace '^(.{0,100}).*', '$1' } else { '' }
                return "Agent[$sub]: $desc"
            }
            default {
                $json = ($input | ConvertTo-Json -Compress -ErrorAction SilentlyContinue) -replace '\s+', ' '
                if ($json.Length -gt 200) { $json = $json.Substring(0, 200) + '...' }
                return "$name $json"
            }
        }
    }
    function Format-ToolResultPreview {
        param($content)
        if ($null -eq $content) { return '(empty)' }
        $text = if ($content -is [array]) {
            ($content | ForEach-Object { if ($_.type -eq 'text') { $_.text } else { ($_ | ConvertTo-Json -Compress) } }) -join ' '
        } elseif ($content -is [string]) { $content } else { $content | ConvertTo-Json -Compress }
        $text = $text -replace '\s+', ' '
        if ($text.Length -gt 250) { $text = $text.Substring(0, 250) + '...' }
        return $text
    }
    function Track-Milestones {
        param($ev)
        try {
            if ($ev.type -eq 'assistant') {
                foreach ($block in $ev.message.content) {
                    if ($block.type -eq 'tool_use' -and ($block.name -eq 'Bash' -or $block.name -eq 'PowerShell')) {
                        $cmd = $block.input.command
                        if ($cmd -match '\bgh\s' -and -not $script:m.GhSeen) {
                            $script:m.GhSeen = $true; Write-Milestone '>' "Querying GitHub via gh CLI..."
                        }
                        if ($cmd -match 'git\s+(fetch|show|rev-parse)' -and -not $script:m.GitSeen) {
                            $script:m.GitSeen = $true; Write-Milestone '>' "Reading PR files via git..."
                        }
                    }
                    # Stage 4: orchestrator fans out review/verify sub-agents. Sub-agent
                    # internals don't stream, so surface the dispatch itself as a milestone.
                    if ($block.type -eq 'tool_use' -and ($block.name -eq 'Agent' -or $block.name -eq 'Task')) {
                        $script:m.AgentsDispatched++
                        $sub = if ($block.input.subagent_type) { $block.input.subagent_type } else { 'agent' }
                        $desc = if ($block.input.description) { $block.input.description } else { '' }
                        Write-Milestone '>' "Dispatched sub-agent #$($script:m.AgentsDispatched) [$sub] $desc"
                    }
                    if ($block.type -eq 'text' -and $block.text) {
                        $txt = $block.text
                        if (-not $script:m.ReviewListSeen -and $txt -match 'PRs to review:\s*(.+)') {
                            $script:m.ReviewListSeen = $true; Write-Milestone '>' "PRs to review: $($Matches[1].Trim())"
                        }
                        if ($txt -match 'No PRs to review') { Write-Milestone 'i' "No PRs to review this run." }
                        foreach ($mm in [regex]::Matches($txt, 'PR #(\d+) REVIEWED:\s*([^\r\n]+)')) {
                            $script:m.Reviewed++
                            Write-Milestone 'v' "PR #$($mm.Groups[1].Value) reviewed - $($mm.Groups[2].Value.Trim())"
                        }
                        # Fallback: pick up the final "Reviewed:   N" summary line so the DONE
                        # milestone count is right even if per-PR markers weren't emitted verbatim.
                        if ($txt -match '(?m)^\s*Reviewed:\s+(\d+)\b') { $script:m.Reviewed = [int]$Matches[1] }
                    }
                }
            }
            if ($ev.type -eq 'result') {
                $dur = [math]::Round($ev.duration_ms / 1000, 1)
                if ($null -ne $ev.total_cost_usd) { $script:TotalCostUsd = [double]$ev.total_cost_usd }
                if ($ev.subtype -eq 'success') {
                    Write-Milestone 'v' "DONE - duration ${dur}s, cost `$$($ev.total_cost_usd), PRs reviewed: $($script:m.Reviewed), sub-agents dispatched: $($script:m.AgentsDispatched)"
                } else {
                    Write-Milestone 'X' "FAILED - subtype=$($ev.subtype), duration ${dur}s, cost `$$($ev.total_cost_usd)"
                }
            }
        } catch { Write-Log "[milestone-err] $_" }
    }
    function Process-ClaudeEvent {
        param([string]$line)
        if ([string]::IsNullOrWhiteSpace($line)) { return }
        try { $ev = $line | ConvertFrom-Json -ErrorAction Stop }
        catch { Write-Log "[claude:raw] $line"; return }
        Track-Milestones -ev $ev
        switch ($ev.type) {
            'system' {
                if ($ev.subtype -eq 'init') { Write-Log "[claude:init] model=$($ev.model) cwd=$($ev.cwd) session=$($ev.session_id)" }
                else { Write-Log "[claude:system] $($ev.subtype)" }
            }
            'assistant' {
                foreach ($block in $ev.message.content) {
                    switch ($block.type) {
                        'text'     { ($block.text -split "`r?`n") | Where-Object { $_ -ne '' } | ForEach-Object { Write-Log "[claude] $_" } }
                        'tool_use' { Write-Log "[claude:tool->] $(Format-ToolUseSummary -name $block.name -input $block.input)" }
                        'thinking' { $t = ($block.thinking -replace "`r?`n", ' '); if ($t.Length -gt 200) { $t = $t.Substring(0,200)+'...' }; Write-Log "[claude:thinking] $t" }
                        default    { Write-Log "[claude:assistant:?] $($block.type)" }
                    }
                }
            }
            'user' {
                foreach ($block in $ev.message.content) {
                    if ($block.type -eq 'tool_result') {
                        $tag = if ($block.is_error) { 'tool<-ERROR' } else { 'tool<-' }
                        Write-Log "[claude:$tag] $(Format-ToolResultPreview -content $block.content)"
                    }
                }
            }
            'result' {
                $r = if ($ev.result) { ($ev.result -replace "`r?`n", ' ') } else { '(none)' }
                if ($r.Length -gt 500) { $r = $r.Substring(0,500)+'...' }
                Write-Log "[claude:DONE] subtype=$($ev.subtype) duration=$($ev.duration_ms)ms cost=`$$($ev.total_cost_usd)"
                Write-Log "[claude:final] $r"
            }
            default { Write-Log "[claude:event:$($ev.type)] (no formatter)" }
        }
    }

    $exitCode = 0
    if ($skipClaude) {
        Write-Log "Skipping claude launch -- nothing new to review (all eligible PRs already have a report)."
    } else {
        Write-Milestone 'v' "Pre-flight passed (gh authenticated, origin fetched)."
        Write-Milestone '>' "Launching claude (model=$Model) for read-only PR review..."

        $Prompt = Get-Content $PromptFile -Raw
        try {
            $Prompt | & $ClaudeCmd `
                --print `
                --verbose `
                --dangerously-skip-permissions `
                --model $Model `
                --output-format stream-json `
                --input-format text 2>&1 |
                ForEach-Object { Process-ClaudeEvent -line $_ }
            $exitCode = $LASTEXITCODE
        } catch {
            Write-Log "EXCEPTION: $_"
            Write-Milestone 'X' "claude crashed: $_"
            $exitCode = 1
        }
        Write-Log "claude exited with code $exitCode"
    }

    # ---- read-only guarantee check ----
    $branchAfter = (git rev-parse --abbrev-ref HEAD 2>&1).Trim()
    $headAfter   = (git rev-parse HEAD 2>&1).Trim()
    if ($branchAfter -ne $branchBefore -or $headAfter -ne $headBefore) {
        Write-Milestone 'X' "WARNING: branch/HEAD changed during run! before=$branchBefore@$headBefore after=$branchAfter@$headAfter"
    } else {
        Write-Log "Read-only guarantee OK: still on $branchAfter @ $headAfter."
    }
    # Any leftover temp refs the review created?
    $strayRefs = git for-each-ref --format='%(refname)' refs/pr-review/ 2>&1 | Where-Object { $_ -like 'refs/pr-review/*' }
    if ($strayRefs) {
        Write-Log "Cleaning leftover temp refs: $($strayRefs -join ', ')"
        $strayRefs | ForEach-Object { git update-ref -d $_ 2>&1 | Out-Null }
    }

    # ---- report this run's output ----
    $newReports = Get-ChildItem $OutputDir -Filter 'PR-*.html' -ErrorAction SilentlyContinue |
        Where-Object { $_.LastWriteTime -ge $runStart -or -not $reportsBefore.ContainsKey($_.Name) -or $reportsBefore[$_.Name] -ne $_.LastWriteTime }
    if ($newReports) {
        Write-Log "Reports written/updated this run:"
        $newReports | Sort-Object Name | ForEach-Object { Write-Log "  $($_.FullName)" }
        Write-Milestone 'v' "$($newReports.Count) report(s) in $OutputDir"
    } else {
        Write-Log "No new report files this run (nothing to review, or all eligible PRs already have a report)."
    }

    # ---- always surface this run's cost + wall-clock duration (skip / abort => $0) ----
    $wallDur = [math]::Round(((Get-Date) - $runStart).TotalSeconds, 1)
    Write-Milestone '$' ("Run cost: `${0:N6}, duration {1}s  (claude launched: {2})" -f $script:TotalCostUsd, $wallDur, $(if ($skipClaude) { 'no' } else { 'yes' }))

} finally {
    Remove-Item -Force $LockFile -ErrorAction SilentlyContinue
    Write-Log "Lock released."
}

Write-Log "=== pr-review run finished (task=$TaskName exit=$exitCode) ==="

# keep last 30 logs per task
Get-ChildItem $TaskLogDir -Filter "${TaskName}_*.log" |
    Sort-Object LastWriteTime -Descending |
    Select-Object -Skip 30 |
    Remove-Item -Force -ErrorAction SilentlyContinue

exit $exitCode
