param(
    [string]$TaskName = 'manual',
    # Model passed to the claude CLI. Pinned to Claude Opus 5 (best for full semantic
    # review). Pass 'sonnet' if you want cheaper/faster runs across the 6 daily slots.
    [string]$Model = 'claude-opus-5'
)

$ErrorActionPreference = 'Continue'

# Under Task Scheduler (-NoProfile, no interactive console) the console decodes native-command
# output with the OEM code page (cp437), so UTF-8 from gh/claude lands in the log as mojibake
# ("Γ£ô" for "✓", "ΓÇö" for "—"). Force UTF-8 so the log is readable. Guarded: the setter throws
# when no console is attached, and that must never abort the run.
try { [Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false) } catch { }

$ScheduledDir = $PSScriptRoot   # this folder — automation files live alongside the wrapper

# Shared identity + path resolution (roster minus self, per-machine paths).
. "$ScheduledDir\..\lib\team.ps1"
$cfg = Resolve-LocalConfig

$RepoRoot     = $cfg.repoExternalApi
$LogDir       = Join-Path $ScheduledDir 'logs'
$PromptFile   = Join-Path $ScheduledDir 'pr-review-prompt.md'
$TemplateFile = Join-Path $ScheduledDir 'pr-review-template.html'
$ClaudeCmd    = "$env:APPDATA\npm\claude.cmd"
$OutputDir    = Join-Path $cfg.outputBase 'PR Review'

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

# ---- credentials from ~/repos/.env (parsed once; both consumers are below) --
# GITHUB_TOKEN -> SAML/SSO fallback for gh (see the repo-scoped probe below).
# ADO_PAT      -> OPTIONAL story-alignment check only.
# The review itself needs no ADO access. When ~/repos/.env supplies ADO_PAT we ALSO
# hand the prompt the org/project so Phase 1e can read the PR's ticket and sanity-check
# that the PR built what was asked for (read-only; informational; never blocking).
# A missing PAT is a SUPPORTED configuration -- warn and pass empty placeholders so the
# prompt's gate skips that phase cleanly. NEVER make this fatal: it would break every
# existing install that has no ADO_PAT.
$AdoOrg = ''; $AdoProject = ''; $GhPat = ''
$EnvFile = $cfg.envFile
if (Test-Path $EnvFile) {
    $envMap = @{}
    Get-Content $EnvFile | ForEach-Object {
        $t = $_.Trim()
        if ($t -and -not $t.StartsWith('#') -and $t.Contains('=')) {
            $k, $v = $t -split '=', 2
            $envMap[$k.Trim()] = $v.Trim().Trim('"').Trim("'")
        }
    }
    if ($envMap['GITHUB_TOKEN']) { $GhPat = $envMap['GITHUB_TOKEN'] }
    if ($envMap['ADO_PAT']) {
        $AdoOrg     = if ($envMap['ADO_ORG'])     { $envMap['ADO_ORG'] }     else { 'renweb' }
        $AdoProject = if ($envMap['ADO_PROJECT']) { $envMap['ADO_PROJECT'] } else { 'ColdFusion' }
        Write-Log "ADO creds found -- story-alignment enabled ($AdoOrg/$AdoProject)."
    } else {
        Write-Log "WARN: no ADO_PAT in $EnvFile -- story-alignment check will be skipped (review is unaffected)."
    }
} else {
    Write-Log "WARN: env file not found at $EnvFile -- story-alignment check will be skipped (review is unaffected)."
}

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
    Write-Log "       then authorize the token for the 'nelnet-nbs' org SSO. See $ScheduledDir\README-pr-review.md."
    exit 1
}

# ---- SAML SSO probe: can the active credential actually reach the repo? -----
# 'gh auth status' only proves a token EXISTS; it does NOT prove that token is still
# SSO-authorized for nelnet-nbs. In the 2026-08-24 10:00 run the keyring token passed
# 'gh auth status' but every repo-scoped call -- git fetch, all 3 'gh pr list' pre-check
# attempts, and the agent's own REST + GraphQL calls -- returned HTTP 403 "Resource
# protected by organization SAML enforcement". The pre-check therefore could not prove
# "nothing to do", so a full claude launch ($0.78) was spent discovering 0 reviewable PRs.
# Probe once with a cheap repo-scoped read and, on failure, fall back to GITHUB_TOKEN from
# the env file (a classic PAT keeps its SSO grant; the agent proved this fallback works).
# Setting GH_TOKEN here fixes git fetch, the pre-check, AND the claude child process, which
# inherits this environment -- so the agent no longer has to rediscover the fallback itself.
# gh reports the SAML 403 as a human-readable message AND repeats the same text as a raw JSON
# body -- ~1.1 KB on one line in the 2026-08-25 run. The post-run log review reads the whole log,
# so cap it: 500 chars keeps the actionable part (the .../sso?authorization_request=... URL) and
# drops the duplicated JSON.
function Format-GhProbeError {
    param([string]$text)
    $t = ($text.Trim() -replace '\s+', ' ')
    if ($t.Length -gt 500) { $t = $t.Substring(0, 500) + '...' }
    return $t
}
$ghProbe = gh api 'repos/nelnet-nbs/sis-externalapi' --jq '.full_name' 2>&1 | Out-String
if ($LASTEXITCODE -ne 0) {
    Write-Log ("WARN: 'gh auth status' passed but the repo-scoped probe failed -- " + (Format-GhProbeError $ghProbe))
    if ($GhPat) {
        $env:GH_TOKEN = $GhPat
        $env:GITHUB_TOKEN = $GhPat
        $ghProbe = gh api 'repos/nelnet-nbs/sis-externalapi' --jq '.full_name' 2>&1 | Out-String
        if ($LASTEXITCODE -eq 0) {
            Write-Log "Fell back to GITHUB_TOKEN from $EnvFile -- repo access restored ($($ghProbe.Trim()))."
        } else {
            Remove-Item Env:GH_TOKEN     -ErrorAction SilentlyContinue
            Remove-Item Env:GITHUB_TOKEN -ErrorAction SilentlyContinue
            Write-Log ("WARN: GITHUB_TOKEN from $EnvFile cannot reach the repo either -- " + (Format-GhProbeError $ghProbe))
            Write-Log "       Fix once (interactively): authorize the token for the 'nelnet-nbs' org SSO. See $ScheduledDir\README-pr-review.md."
        }
    } else {
        Write-Log "       No GITHUB_TOKEN in $EnvFile to fall back to. Fix once (interactively): re-authorize the gh token for the 'nelnet-nbs' org SSO."
    }
}

# ---- identity: who is running this, and whose PRs they review --------------
# reviewAuthors = team roster minus the current user (auto-detected via gh).
try {
    $meLogin       = Get-CurrentGitHubLogin
    $reviewAuthors = @(Get-ReviewAuthors -CurrentLogin $meLogin)
    # rosterAuthors = the FULL roster, self INCLUDED. Not a review filter -- it is only
    # used as a convention reference (recently merged roster PRs seed the sibling picker).
    $rosterAuthors = @((Get-TeamRoster) | ForEach-Object { $_.github })
    Write-Log "Current user (gh): $meLogin"
    Write-Log "Reviewing PRs by:  $($reviewAuthors -join ', ')"
    Write-Log "Convention refs:   $($rosterAuthors -join ', ') (merged PRs; self included)"
} catch {
    Write-Milestone 'X' "Could not resolve identity from roster/gh -- aborting."
    Write-Log "FATAL: $_"
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
        # $reviewAuthors computed above (roster minus current user).
        # gh fails transiently (network stall / SSO / rate limit). A single failure here used to
        # fall straight through to a full claude launch that then found nothing to do (~11 min,
        # ~$0.59). Retry a few times, and keep gh's stderr instead of discarding it with 2>$null
        # so the log says WHY the pre-check failed.
        $openJson = $null
        foreach ($attempt in 1..3) {
            $ghRaw    = gh pr list --repo nelnet-nbs/sis-externalapi --state open --limit 100 --json number,author,assignees,isDraft,updatedAt 2>&1
            $ghExit   = $LASTEXITCODE
            $ghErr    = (@($ghRaw | Where-Object { $_ -is [System.Management.Automation.ErrorRecord] }) | ForEach-Object { $_.ToString() }) -join ' '
            $openJson = (@($ghRaw | Where-Object { $_ -isnot [System.Management.Automation.ErrorRecord] }) -join "`n").Trim()
            if ($ghExit -eq 0 -and $openJson) { break }
            Write-Log "Pre-check: 'gh pr list' attempt $attempt/3 failed (exit=$ghExit)$(if ($ghErr) { ' -- ' + $ghErr })"
            $openJson = $null
            if ($attempt -lt 3) { Start-Sleep -Seconds 5 }
        }
        if ($openJson) {
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
            Write-Log "WARN: Pre-check: 'gh pr list' failed on all 3 attempts; launching claude and letting the prompt decide (a launch may be spent on nothing)."
        }
    } catch {
        Write-Log "Pre-check error (non-fatal): $_  -- launching claude anyway."
    }

    # Fetch is read-only w.r.t. the working tree; makes origin/main + PR refs current for the
    # claude launch. Deliberately AFTER the pre-check and skipped on a no-op run: the pre-check
    # reads only `gh pr list` (network) and local report filenames, so it has no dependency on
    # local refs. Fetching first made every skip run pay for a fetch nothing consumed -- and on
    # 2026-08-25 10:00 it also spilled a 4-line SAML-403 failure cascade into a run whose very
    # next line was "nothing new to review". Matches the ms-pr-review sibling.
    # $null = never attempted (no-op run); $true/$false = origin refs are/aren't current. Both
    # consumers below (the pre-flight milestone and {{FETCH_STATUS}}) run only when NOT skipping.
    $fetchOk = $null
    if (-not $skipClaude) {
        Write-Log "Fetching origin (prune) ..."
        git fetch --prune origin 2>&1 | ForEach-Object { Write-Log "[git fetch] $_" }
        $fetchOk = ($LASTEXITCODE -eq 0)
        if (-not $fetchOk) { Write-Log "WARN: git fetch failed (exit=$LASTEXITCODE) -- continuing; gh calls may still work." }
    }

    # ----- stream-json event parser (detailed log + PR-review milestones) ---
    # FanoutClaim/FanoutSeen: the orchestrator prints "FANOUT (PR #n): <k> reviewer(s) dispatched in this
    # message" before Phase 2. Comparing that claim against the per-message Agent-block count turns a
    # serialized fan-out into a greppable WARN instead of a note nobody reads (see Track-Milestones).
    $script:m = @{ GhSeen=$false; GitSeen=$false; ReviewListSeen=$false; Reviewed=0; AgentsDispatched=0; FanoutClaim=0; FanoutSeen=0 }
    $script:TotalCostUsd = 0.0

    # NOTE: the parameter is $toolInput, NOT $input. `$input` is a PowerShell automatic variable
    # (the pipeline enumerator) and it silently shadows a same-named parameter -- the bound value
    # is replaced by an EMPTY, non-null enumerator, so every summary logged as a bare
    # "PowerShell: " / "Read: " with the arguments stripped. Do not rename it back.
    function Format-ToolUseSummary {
        param($name, $toolInput)
        if ($null -eq $toolInput) { return "$name (no input)" }
        switch ($name) {
            'Bash'       { return "Bash: $(($toolInput.command -replace '\s+', ' ') -replace '^(.{0,160}).*', '$1')" }
            'PowerShell' { return "PowerShell: $(($toolInput.command -replace '\s+', ' ') -replace '^(.{0,160}).*', '$1')" }
            'Read'       { return "Read: $($toolInput.file_path)" }
            'Write'      { return "Write: $($toolInput.file_path)" }
            'Glob'       { return "Glob: $($toolInput.pattern)" }
            'Grep'       { return "Grep: $($toolInput.pattern)" }
            'TodoWrite'  { return "TodoWrite: $((($toolInput.todos) | ForEach-Object { '[' + $_.status[0] + '] ' + $_.content }) -join ' | ')" }
            { $_ -eq 'Agent' -or $_ -eq 'Task' } {
                $sub = if ($toolInput.subagent_type) { $toolInput.subagent_type } else { 'agent' }
                $desc = if ($toolInput.description) { $toolInput.description } elseif ($toolInput.prompt) { ($toolInput.prompt -replace '\s+', ' ') -replace '^(.{0,100}).*', '$1' } else { '' }
                return "Agent[$sub]: $desc"
            }
            default {
                $json = ($toolInput | ConvertTo-Json -Compress -ErrorAction SilentlyContinue) -replace '\s+', ' '
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
                # How many Agent blocks THIS message carried. Phase 2 must fan out all five reviewers in
                # ONE message; the 2026-08-18 run dispatched them one-per-message (~1 min of dead wall
                # clock each, ~5 min of a 12-min run). Per-message batch size makes that visible without
                # doing timestamp arithmetic across the "Dispatched sub-agent #N" lines.
                $agentBatch = 0
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
                        $agentBatch++
                        $sub = if ($block.input.subagent_type) { $block.input.subagent_type } else { 'agent' }
                        $desc = if ($block.input.description) { $block.input.description } else { '' }
                        Write-Milestone '>' "Dispatched sub-agent #$($script:m.AgentsDispatched) [$sub] $desc"
                    }
                    if ($block.type -eq 'text' -and $block.text) {
                        $txt = $block.text
                        # Remember how many reviewers the orchestrator SAYS it batched, so the
                        # per-message Agent count below can contradict it. A new FANOUT line starts a
                        # new fan-out (next PR), so reset the dispatched-so-far counter with it.
                        if ($txt -match 'FANOUT \(PR #\d+\):\s*(\d+)\s*reviewer') {
                            $script:m.FanoutClaim = [int]$Matches[1]; $script:m.FanoutSeen = 0
                        }
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
                if ($agentBatch -gt 0) {
                    # Serialized only while the claimed batch is still incomplete -- once FanoutSeen has
                    # caught up to the claim, a lone Agent call is a Phase 4 verifier and legitimate.
                    $serialized = ($agentBatch -eq 1 -and $script:m.FanoutClaim -ge 2 -and $script:m.FanoutSeen -lt $script:m.FanoutClaim)
                    $script:m.FanoutSeen += $agentBatch
                    if ($serialized) {
                        Write-Log ("WARN: fan-out SERIALIZED -- FANOUT marker claimed {0} reviewer(s) but this message carried 1 Agent call ({1}/{0} dispatched so far). Each split costs ~1 min of dead wall clock; see Phase 2 in pr-review-prompt.md." -f $script:m.FanoutClaim, $script:m.FanoutSeen)
                    } else {
                        Write-Log "Sub-agent fan-out batch: $agentBatch dispatched in one message (Phase 2 must be 5; a lone Phase 4 verifier legitimately is 1)."
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
                # 'thinking_tokens' is a contentless per-delta token-accounting heartbeat -- it was
                # 122 of the 343 lines (36%) in the 2026-08-10 run, and the post-run log-review reads
                # the whole file, so the noise costs tokens on every run. Siblings already suppress it.
                elseif ($ev.subtype -eq 'thinking_tokens') { }
                else { Write-Log "[claude:system] $($ev.subtype)" }
            }
            'assistant' {
                foreach ($block in $ev.message.content) {
                    switch ($block.type) {
                        'text'     { ($block.text -split "`r?`n") | Where-Object { $_ -ne '' } | ForEach-Object { Write-Log "[claude] $_" } }
                        'tool_use' { Write-Log "[claude:tool->] $(Format-ToolUseSummary -name $block.name -toolInput $block.input)" }
                        # Redacted/empty thinking blocks carry no text -- logging them emitted 17 bare
                        # "[claude:thinking]" lines in the 2026-08-10 run. Only log when there is text.
                        'thinking' { $t = ($block.thinking -replace "`r?`n", ' ').Trim(); if ($t) { if ($t.Length -gt 200) { $t = $t.Substring(0,200)+'...' }; Write-Log "[claude:thinking] $t" } }
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
            # benign informational events -- logged plainly, no "(no formatter)" noise
            'rate_limit_event' { Write-Log "[claude:info] rate_limit_event" }
            'tool_progress'    { Write-Log "[claude:info] tool_progress" }
            default { Write-Log "[claude:event:$($ev.type)] (no formatter)" }
        }
    }

    $exitCode = 0
    if ($skipClaude) {
        Write-Log "Skipping claude launch -- nothing new to review (all eligible PRs already have a report)."
    } else {
        # Report what actually happened. The 2026-08-24 10:00 run printed the unconditional
        # "Pre-flight passed (gh authenticated, origin fetched)" milestone directly under a
        # failed git fetch and three failed 'gh pr list' attempts -- the one line a human
        # skims said the opposite of the truth.
        if ($fetchOk) {
            Write-Milestone 'v' "Pre-flight passed (gh authenticated, origin fetched)."
        } else {
            Write-Milestone '!' "Pre-flight DEGRADED: gh authenticated but 'git fetch origin' failed -- PR refs may be stale (see WARN above)."
        }
        Write-Milestone '>' "Launching claude (model=$Model) for read-only PR review..."

        $Prompt = Get-Content $PromptFile -Raw
        # Fill identity/path placeholders so the prompt reflects whoever is running.
        # .Replace() is literal (no regex/backslash/$ pitfalls with Windows paths).
        $Prompt = $Prompt.Replace('{{REVIEW_AUTHORS}}', ($reviewAuthors -join ', '))
        # Full roster INCLUDING the current user -- deliberately different from {{REVIEW_AUTHORS}}.
        # Used only to find recently merged roster PRs as a convention reference, never to pick
        # which PRs get reviewed (your own open PRs are still never reviewed).
        $Prompt = $Prompt.Replace('{{ROSTER_AUTHORS}}', ($rosterAuthors -join ', '))
        $Prompt = $Prompt.Replace('{{CURRENT_USER}}',   $meLogin)
        $Prompt = $Prompt.Replace('{{OUTPUT_DIR}}',     $OutputDir)
        $Prompt = $Prompt.Replace('{{SCHEDULED_DIR}}',  $ScheduledDir)
        $Prompt = $Prompt.Replace('{{REPO_ROOT}}',      $RepoRoot)
        # Empty when no ADO_PAT -- the prompt's Phase 1e gate checks for exactly that.
        $Prompt = $Prompt.Replace('{{ADO_ORG}}',        $AdoOrg)
        $Prompt = $Prompt.Replace('{{ADO_PROJECT}}',    $AdoProject)
        # Where the PAT actually lives. Phase 1e reads ADO_PAT out of this file itself (same pattern as
        # the admission-ms / morning-gw prompts). Without it the agent probes $env:ADO_PAT, finds it
        # empty, and skips story-alignment even though the wrapper just logged "ADO creds found".
        $Prompt = $Prompt.Replace('{{ENV_FILE}}',       $EnvFile)
        # Did the pre-flight fetch above actually work? Without this the prompt asserted "the wrapper has
        # already run git fetch --prune so PR refs are current" unconditionally, so in a DEGRADED run the
        # agent re-ran `git fetch origin pull/<n>/head` and hit the same SAML 403 (exit 128), then had to
        # re-plan onto `gh api .../contents?ref=<sha>` mid-review. Hand it the truth up front.
        $Prompt = $Prompt.Replace('{{FETCH_STATUS}}',   $(if ($fetchOk) { 'ok' } else { 'failed' }))
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

# --- post-run process-improvement review (report + uncommitted patches; never commits) ---
. "$ScheduledDir\..\lib\log-review.ps1"
Invoke-LogReview -LogFile $LogFile -TaskName $TaskName -ScheduledDir $ScheduledDir `
    -TargetRepo $RepoRoot -ClaudeCmd $ClaudeCmd -ExitCode $exitCode

exit $exitCode
