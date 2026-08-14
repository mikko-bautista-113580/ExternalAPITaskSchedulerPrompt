<#
.SYNOPSIS
    Audit the AI progress artifact against each team's published AI roadmap and update it.

.DESCRIPTION
    Computes -- deterministically, in PowerShell -- where each team is EXPECTED to be on the
    trigger date according to roadmaps.json, then launches claude headless to judge where they
    ACTUALLY are, rescore, and update the artifact.

    Publish gate: the prompt writes audit-result.json BEFORE touching the artifact. A run may
    publish only when no score falls and no phase exit criterion is overdue. Anything else drops
    to draft-and-report. This wrapper re-checks that JSON afterwards and logs MISMATCH if the
    prompt published on a dirty result.

.EXAMPLE
    pwsh -File .\progress-audit\run-progress-audit.ps1 -TaskName manual -DraftOnly
.EXAMPLE
    pwsh -File .\progress-audit\run-progress-audit.ps1 -TaskName manual -Notes "Russell committed the 3 staged skills; Mel published the FAM roadmap"
#>
param(
    [string]$TaskName = 'manual',
    # Pinned to Claude Opus 5 (semantic judgement against exit criteria). 'sonnet' for cheaper runs.
    [string]$Model    = 'claude-opus-5',
    # Free-text details for this run. Treated as authoritative by the prompt -- it's the user reporting.
    [string]$Notes    = '',
    # Local snapshot of the current artifact page (browser "Save as -> Webpage, HTML only").
    # claude.ai artifacts are auth-gated and client-rendered, so WebFetch alone returns an empty
    # body and the run holds at Step 1. Defaults to artifact-snapshot.html beside this script.
    [string]$ArtifactHtml = '',
    # Compute + draft, never publish. Use for dry runs and for the first Artifact-tool check.
    [switch]$DraftOnly
)

$ErrorActionPreference = 'Continue'

# Task Scheduler decodes native output with the OEM code page; force UTF-8 so the log is readable.
# Guarded: the setter throws when no console is attached, and that must never abort the run.
try { [Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false) } catch { }

$ScheduledDir = $PSScriptRoot

# Shared per-machine path resolution (outputBase). Same contract as the other jobs.
. "$ScheduledDir\..\lib\team.ps1"
$cfg = Resolve-LocalConfig

$RoadmapsFile = Join-Path $ScheduledDir 'roadmaps.json'
$PromptFile   = Join-Path $ScheduledDir 'progress-audit-prompt.md'
$LogDir       = Join-Path $ScheduledDir 'logs'
$ClaudeCmd    = "$env:APPDATA\npm\claude.cmd"
$OutputDir    = Join-Path $cfg.outputBase 'AI Progress Audit'
# Root of the repo holding the committed team skills the audit counts (the folders roadmaps.json
# names in skillsPath). Prefer config.local.json's skillsRoot -- this job also ships in a standalone
# checkout, where the skills are NOT above this folder and no derived path can be right.
# Otherwise derive it THREE levels up, which is the skills-repo root when this automation is checked
# out inside that repo. Deriving only TWO levels was the original bug: it stopped one short, so every
# skillsPath resolved under the wrong root ('.claude\.claude\<team>') -- a path that never exists.
# Glob then returned nothing, every team read as "no skills committed", and real scores were dragged
# down with no visible error. The preflight below now logs each resolution so it cannot recur silently.
$RepoRoot     = if ($cfg.skillsRoot) { $cfg.skillsRoot }
                else { Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $ScheduledDir)) }

# Read path for the artifact. A local snapshot beats WebFetch, which cannot see an auth-gated
# claude.ai artifact -- it returns only the page header and the disclaimer.
if (-not $ArtifactHtml) { $ArtifactHtml = Join-Path $ScheduledDir 'artifact-snapshot.html' }
$ArtifactSnapshot = if (Test-Path $ArtifactHtml) { (Resolve-Path $ArtifactHtml).Path } else { '' }

$TaskLogDir = Join-Path $LogDir $TaskName
if (-not (Test-Path $TaskLogDir)) { New-Item -ItemType Directory -Path $TaskLogDir -Force | Out-Null }

$Timestamp  = Get-Date -Format 'yyyyMMdd_HHmmss'
$LogFile    = Join-Path $TaskLogDir "${TaskName}_$Timestamp.log"
$ResultFile = Join-Path $TaskLogDir "${TaskName}_$Timestamp.audit-result.json"

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

Write-Log "=== progress-audit run started (task=$TaskName, model=$Model, draftOnly=$($DraftOnly.IsPresent)) ==="
Write-Log "Roadmaps: $RoadmapsFile"
Write-Log "Repo:     $RepoRoot"
Write-Log "Output:   $OutputDir"
Write-Log "Log:      $LogFile"
Write-Log "Tail this log live:  Get-Content -Wait -Path `"$LogFile`""

# ---- pre-flight ------------------------------------------------------------
if (-not (Test-Path $ClaudeCmd))    { Write-Log "FATAL: claude CLI not found at $ClaudeCmd"; exit 1 }
if (-not (Test-Path $PromptFile))   { Write-Log "FATAL: prompt file not found at $PromptFile"; exit 1 }
if (-not (Test-Path $RoadmapsFile)) { Write-Log "FATAL: roadmaps.json not found at $RoadmapsFile"; exit 1 }
if (-not (Test-Path $OutputDir))    { New-Item -ItemType Directory -Path $OutputDir -Force | Out-Null; Write-Log "Created output dir $OutputDir" }

try {
    $roadmaps = Get-Content $RoadmapsFile -Raw | ConvertFrom-Json
} catch {
    Write-Log "FATAL: roadmaps.json is not valid JSON -- $_"
    exit 1
}
if (-not $roadmaps.artifact.url) { Write-Log "FATAL: roadmaps.json has no artifact.url"; exit 1 }

# Every non-null skillsPath must actually exist under $RepoRoot. A wrong root is INVISIBLE to the
# model -- Glob just returns nothing and the team reads as "no skills committed", which quietly
# lowers a real score. Not fatal (a team may legitimately have none yet), but it must be loud.
foreach ($t in $roadmaps.teams) {
    if (-not $t.skillsPath) { continue }
    $sp = Join-Path $RepoRoot ($t.skillsPath -replace '/', '\')
    if (Test-Path $sp) {
        $n = @(Get-ChildItem $sp -Filter 'SKILL.md' -Recurse -File -ErrorAction SilentlyContinue).Count
        Write-Log "Skills:   $($t.team) -> $sp ($n SKILL.md)"
    } else {
        Write-Log "WARN: $($t.team) skillsPath '$($t.skillsPath)' does not exist under $RepoRoot -- committed-skill evidence will count ZERO for this team. Set 'skillsRoot' in config.local.json to the ai-resources checkout, or fix the path in roadmaps.json."
    }
}

if ($ArtifactSnapshot) {
    Write-Log "Snapshot: $ArtifactSnapshot"
} else {
    Write-Log "WARN: no artifact snapshot at $ArtifactHtml -- the run falls back to WebFetch, which returns an empty body for auth-gated claude.ai artifacts and ends in 'HOLD: artifact unreadable'."
}

# ---- date math: the deterministic half -------------------------------------
# Everything below is arithmetic on roadmaps.json. The model never computes an expected phase.
$Today            = Get-Date
$TodayIso         = $Today.ToString('yyyy-MM-dd')
$IsoWeek          = [System.Globalization.ISOWeek]::GetWeekOfYear($Today)
$IsoYear          = [System.Globalization.ISOWeek]::GetYear($Today)
$CheckpointLabel  = '{0} {1}' -f $Today.Day, $Today.ToString('MMM')

function Get-ExpectedPhase {
    <#  Which phase should this team be in today, and how does today sit against its window?
        Handles both roadmap dialects: explicit start/end dates, and anchor-relative week numbers.
        Returns a flat object the caller renders into the prompt table. #>
    param([object]$Team, [datetime]$Now)

    $out = [ordered]@{
        team = $Team.team; lead = $Team.lead
        expectedPhase = $null; expectedPhaseName = ''
        windowStart = ''; windowEnd = ''
        daysRemaining = $null; daysOverdue = 0
        weekIndex = $null; basis = ''; note = ''
        phaseCount = 0; pointsPerPhase = 0
    }

    if (-not $Team.phases -or @($Team.phases).Count -eq 0) {
        $out.basis = 'no-roadmap'
        $out.note  = 'No roadmap on record -- report as unscored.'
        return [pscustomobject]$out
    }

    $phases = @($Team.phases)

    # Roadmaps do NOT all have five phases (FAM has two), so a fixed points-per-phase would cap a
    # short roadmap below 100%. Precedence: explicit per-team override, else an even split of 100
    # across that team's own phases. Every team's score therefore means "percent of YOUR plan done".
    $out.phaseCount     = $phases.Count
    $out.pointsPerPhase = if ($Team.pointsPerPhase) { [int]$Team.pointsPerPhase } else { [math]::Round(100 / $phases.Count) }

    if ($Team.anchorDate) {
        # --- week-relative dialect (IMPACT, QUICKPAY) ---
        $anchor = [datetime]::ParseExact($Team.anchorDate, 'yyyy-MM-dd', $null)
        $week   = [math]::Floor(($Now.Date - $anchor.Date).TotalDays / 7) + 1
        $out.weekIndex = $week
        $out.basis = "week $week since anchor $($Team.anchorDate)"
        if (-not $Team.anchorConfirmed) { $out.note = 'ANCHOR UNCONFIRMED -- expected phase may be wrong for this team.' }

        $match = $phases | Where-Object {
            $week -ge $_.weekStart -and ($null -eq $_.weekEnd -or $week -le $_.weekEnd)
        } | Select-Object -First 1
        if (-not $match) {
            # Before week 1, or in a gap: clamp to the nearest sensible phase.
            $match = if ($week -lt 1) { $phases[0] } else { $phases[-1] }
        }
        $out.expectedPhase     = $match.n
        $out.expectedPhaseName = $match.name
        $out.windowStart       = "week $($match.weekStart)"
        $out.windowEnd         = if ($null -eq $match.weekEnd) { 'onward' } else { "week $($match.weekEnd)" }
        if ($null -ne $match.weekEnd) {
            $endDate = $anchor.Date.AddDays(($match.weekEnd * 7) - 1)
            $out.daysRemaining = [int]($endDate - $Now.Date).TotalDays
            if ($out.daysRemaining -lt 0) { $out.daysOverdue = [math]::Abs($out.daysRemaining); $out.daysRemaining = 0 }
        }
        return [pscustomobject]$out
    }

    # --- explicit-date dialect (benefitED) ---
    $out.basis = 'explicit calendar windows'
    $match = $phases | Where-Object {
        $s = if ($_.start) { [datetime]::ParseExact($_.start, 'yyyy-MM-dd', $null) } else { [datetime]::MinValue }
        $e = if ($_.end)   { [datetime]::ParseExact($_.end,   'yyyy-MM-dd', $null) } else { [datetime]::MaxValue }
        $Now.Date -ge $s.Date -and $Now.Date -le $e.Date
    } | Select-Object -First 1

    if (-not $match) {
        # Between windows (e.g. a weekend gap) or past the last one: take the next upcoming phase,
        # else the final phase.
        $upcoming = $phases | Where-Object {
            $_.start -and ([datetime]::ParseExact($_.start, 'yyyy-MM-dd', $null)).Date -gt $Now.Date
        } | Select-Object -First 1
        $match = if ($upcoming) { $upcoming } else { $phases[-1] }
        $out.note = 'Today falls between phase windows; showing the next phase.'
    }

    $out.expectedPhase     = $match.n
    $out.expectedPhaseName = $match.name
    $out.windowStart       = if ($match.start) { $match.start } else { '(open)' }
    $out.windowEnd         = if ($match.end)   { $match.end }   else { 'onward' }
    if ($match.end) {
        $endDate = [datetime]::ParseExact($match.end, 'yyyy-MM-dd', $null)
        $out.daysRemaining = [int]($endDate.Date - $Now.Date).TotalDays
        if ($out.daysRemaining -lt 0) { $out.daysOverdue = [math]::Abs($out.daysRemaining); $out.daysRemaining = 0 }
    }
    return [pscustomobject]$out
}

$expected = foreach ($t in $roadmaps.teams) { Get-ExpectedPhase -Team $t -Now $Today }

Write-Milestone '>' "Trigger date $TodayIso (ISO week $IsoYear-W$IsoWeek, checkpoint '$CheckpointLabel')"
Write-Log "Expected position by roadmap:"
foreach ($e in $expected) {
    if ($e.basis -eq 'no-roadmap') {
        Write-Log ("  {0,-10} {1,-16} NO ROADMAP -- unscored" -f $e.team, $e.lead)
    } else {
        $timing = if ($e.daysOverdue -gt 0) { "OVERDUE by $($e.daysOverdue)d" } elseif ($null -ne $e.daysRemaining) { "$($e.daysRemaining)d left" } else { 'open-ended' }
        Write-Log ("  {0,-10} {1,-16} phase {2}/{3} ({4}) window {5}..{6}  {7}  {8}pts/phase  [{9}]" -f `
            $e.team, $e.lead, $e.expectedPhase, $e.phaseCount, $e.expectedPhaseName, $e.windowStart, $e.windowEnd, $timing, $e.pointsPerPhase, $e.basis)
        if ($e.note) { Write-Log ("             WARN: {0}" -f $e.note) }
    }
}

# Render the table the prompt receives. Plain text: the prompt quotes it back in its report.
$expectedTable = ($expected | ForEach-Object {
    if ($_.basis -eq 'no-roadmap') {
        "| {0} | {1} | - | - | - | - | no roadmap on record |" -f $_.team, $_.lead
    } else {
        $timing = if ($_.daysOverdue -gt 0) { "OVERDUE by $($_.daysOverdue) days" } elseif ($null -ne $_.daysRemaining) { "$($_.daysRemaining) days remaining" } else { 'open-ended' }
        $note   = if ($_.note) { $_.note } else { $_.basis }
        "| {0} | {1} | Phase {2} of {3} | {4} | {5}..{6} | {7} pts/phase | {8} ({9}) |" -f `
            $_.team, $_.lead, $_.expectedPhase, $_.phaseCount, $_.expectedPhaseName, `
            $_.windowStart, $_.windowEnd, $_.pointsPerPhase, $timing, $note
    }
}) -join "`n"

# ---- concurrency guard -----------------------------------------------------
$LockFile = Join-Path $ScheduledDir '.progress-audit.lock'
if (Test-Path $LockFile) {
    $lockAge = (Get-Date) - (Get-Item $LockFile).LastWriteTime
    if ($lockAge.TotalMinutes -lt 60) {
        Write-Log "ABORT: another progress-audit run is in progress (lock age $([math]::Round($lockAge.TotalMinutes,1)) min). Exiting."
        exit 0
    }
    Write-Log "WARN: stale lock (age $([math]::Round($lockAge.TotalHours,1))h) -- removing and proceeding."
    Remove-Item -Force $LockFile -ErrorAction SilentlyContinue
}
"$TaskName $Timestamp PID=$PID" | Out-File -FilePath $LockFile -Encoding utf8

$exitCode = 0
$runStart = Get-Date
$script:TotalCostUsd = 0.0

try {
    # ----- stream-json event parser (same shape as the PR-review wrapper) ----
    $script:m = @{ Fetched = $false; Published = $false; Held = $false }

    function Format-ToolUseSummary {
        param($name, $input)
        if ($null -eq $input) { return "$name (no input)" }
        switch ($name) {
            'Bash'       { return "Bash: $(($input.command -replace '\s+', ' ') -replace '^(.{0,160}).*', '$1')" }
            'PowerShell' { return "PowerShell: $(($input.command -replace '\s+', ' ') -replace '^(.{0,160}).*', '$1')" }
            'Read'       { return "Read: $($input.file_path)" }
            'Write'      { return "Write: $($input.file_path)" }
            'Edit'       { return "Edit: $($input.file_path)" }
            'Glob'       { return "Glob: $($input.pattern)" }
            'Grep'       { return "Grep: $($input.pattern)" }
            'WebFetch'   { return "WebFetch: $($input.url)" }
            'Artifact'   { return "Artifact: action=$($input.action) file=$($input.file_path) url=$($input.url)" }
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
                    if ($block.type -eq 'tool_use') {
                        if ($block.name -eq 'WebFetch' -and -not $script:m.Fetched) {
                            $script:m.Fetched = $true; Write-Milestone '>' "Reading the current artifact..."
                        }
                        if ($block.name -eq 'Artifact' -and $block.input.action -ne 'list') {
                            $script:m.Published = $true; Write-Milestone 'v' "Artifact publish call issued."
                        }
                    }
                    if ($block.type -eq 'text' -and $block.text) {
                        # The status vocabulary contains two-word values ('On track', 'At risk',
                        # 'No roadmap'), so a bare (\S+) captured only 'On' and pushed 'track' into
                        # the message. Match the two-word forms first (either spelling), and keep
                        # (\S+) as the last branch so an unexpected word still logs a milestone.
                        foreach ($mm in [regex]::Matches($block.text, '(?mi)^\s*STATUS:\s*(On[- ]track|At[- ]risk|No[- ]roadmap|\S+)\s+(.+)$')) {
                            Write-Milestone 'i' "$($mm.Groups[1].Value) - $($mm.Groups[2].Value.Trim())"
                        }
                        if ($block.text -match '(?m)^\s*HOLD:\s*(.+)$') {
                            $script:m.Held = $true; Write-Milestone '!' "HOLD - $($Matches[1].Trim())"
                        }
                    }
                }
            }
            if ($ev.type -eq 'result') {
                $dur = [math]::Round($ev.duration_ms / 1000, 1)
                if ($null -ne $ev.total_cost_usd) { $script:TotalCostUsd = [double]$ev.total_cost_usd }
                if ($ev.subtype -eq 'success') {
                    Write-Milestone 'v' "DONE - duration ${dur}s, cost `$$($ev.total_cost_usd)"
                } else {
                    Write-Milestone 'X' "FAILED - subtype=$($ev.subtype), duration ${dur}s"
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
                # thinking_tokens carries no payload and fires every couple of seconds -- pure noise.
                elseif ($ev.subtype -eq 'thinking_tokens') { }
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
            'rate_limit_event' { Write-Log "[claude:info] rate_limit_event" }
            'tool_progress'    { Write-Log "[claude:info] tool_progress" }
            default { Write-Log "[claude:event:$($ev.type)] (no formatter)" }
        }
    }

    Write-Milestone '>' "Launching claude (model=$Model) for the roadmap audit..."

    $Prompt = Get-Content $PromptFile -Raw
    # .Replace() is literal -- no regex/backslash/$ pitfalls with Windows paths.
    $Prompt = $Prompt.Replace('{{TODAY}}',            $TodayIso)
    $Prompt = $Prompt.Replace('{{ISO_WEEK}}',         "$IsoYear-W$IsoWeek")
    $Prompt = $Prompt.Replace('{{CHECKPOINT_LABEL}}', $CheckpointLabel)
    $Prompt = $Prompt.Replace('{{EXPECTED_TABLE}}',   $expectedTable)
    $Prompt = $Prompt.Replace('{{TRIGGER_NOTES}}',    $(if ($Notes) { $Notes } else { '(none supplied)' }))
    $Prompt = $Prompt.Replace('{{ARTIFACT_URL}}',     $roadmaps.artifact.url)
    # When there is no snapshot, say WHY in the prompt. Left as a bare '(none)', the model went
    # source-diving -- it read this wrapper and grepped it to work out whether a read route existed,
    # spending tool calls to rediscover what the preflight WARN already knows.
    $Prompt = $Prompt.Replace('{{ARTIFACT_HTML}}',    $(if ($ArtifactSnapshot) { $ArtifactSnapshot } else { '(none this run - no snapshot file exists at ' + $ArtifactHtml + '. Route 1 is unavailable and WebFetch returns an empty body for this auth-gated page, so expect to hold at Step 1. Do not go looking for the file or for the wrapper source.)' }))
    $Prompt = $Prompt.Replace('{{POINTS_PER_PHASE}}', [string]$roadmaps.artifact.pointsPerPhase)
    $Prompt = $Prompt.Replace('{{ROADMAPS_FILE}}',    $RoadmapsFile)
    $Prompt = $Prompt.Replace('{{RESULT_FILE}}',      $ResultFile)
    $Prompt = $Prompt.Replace('{{OUTPUT_DIR}}',       $OutputDir)
    $Prompt = $Prompt.Replace('{{SCHEDULED_DIR}}',    $ScheduledDir)
    $Prompt = $Prompt.Replace('{{REPO_ROOT}}',        $RepoRoot)
    $Prompt = $Prompt.Replace('{{DRAFT_ONLY}}',       $(if ($DraftOnly) { 'YES -- do NOT publish under any circumstance this run' } else { 'no' }))

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

    # ---- publish gate: verify what the prompt claims against what it did ----
    if (-not (Test-Path $ResultFile)) {
        Write-Milestone 'X' "No audit-result.json written -- cannot verify the publish gate."
        Write-Log "WARN: expected $ResultFile. Treat this run's artifact state as UNVERIFIED."
    } else {
        try {
            $result = Get-Content $ResultFile -Raw | ConvertFrom-Json
            $regressions = @()
            $overdue     = @()
            foreach ($t in $result.teams) {
                if ($null -ne $t.scoreBefore -and $null -ne $t.scoreAfter -and $t.scoreAfter -lt $t.scoreBefore) {
                    $regressions += "$($t.team) $($t.scoreBefore)% -> $($t.scoreAfter)%"
                }
                if ($t.overdueExitCriteria -and @($t.overdueExitCriteria).Count -gt 0) {
                    $overdue += "$($t.team): $(@($t.overdueExitCriteria) -join '; ')"
                }
                # Nulls are normal (unscored team / no roadmap) -- render them as '-' so the line
                # does not collapse to "  ->   expected P2 / actual P".
                $dash = { param($v) if ($null -eq $v -or "$v" -eq '') { '-' } else { "$v" } }
                Write-Log ("  RESULT {0,-10} {1,-12} {2} -> {3}  expected P{4} / actual P{5}" -f `
                    $t.team, $t.status, (& $dash $t.scoreBefore), (& $dash $t.scoreAfter), `
                    (& $dash $t.expectedPhase), (& $dash $t.actualPhase))
            }
            $clean = ($regressions.Count -eq 0 -and $overdue.Count -eq 0)
            # scored= matters: with zero scores "clean=True" is vacuous, not a healthy run.
            $scored = @($result.teams | Where-Object { $null -ne $_.scoreAfter }).Count
            Write-Log "Gate: scored=$scored/$(@($result.teams).Count) clean=$clean regressions=$($regressions.Count) overdue=$($overdue.Count) published=$($result.published)"
            $teamTotal = @($result.teams).Count
            if ($scored -eq 0) { Write-Log "WARN: no team was scored this run -- 'clean' says nothing about team health." }
            elseif ($scored -lt $teamTotal) { Write-Log "WARN: only $scored of $teamTotal teams were scored -- 'clean' covers the scored teams only, not the run." }
            foreach ($r in $regressions) { Write-Log "  REGRESSION $r" }
            foreach ($o in $overdue)     { Write-Log "  OVERDUE    $o" }

            if ($DraftOnly -and $result.published) {
                Write-Milestone 'X' "MISMATCH: -DraftOnly was set but the run reports published=true."
            } elseif ((-not $clean) -and $result.published) {
                Write-Milestone 'X' "MISMATCH: run published on a DIRTY result (regressions/overdue present). Roll back from the artifact version picker."
            } elseif ($clean -and -not $result.published -and -not $DraftOnly) {
                Write-Milestone 'i' "Clean result but nothing published -- check the run's HOLD reason: $($result.holdReason)"
            } elseif ($result.published) {
                Write-Milestone 'v' "Published on a clean result."
            } else {
                Write-Milestone 'i' "Held as draft: $($result.holdReason)"
            }
        } catch {
            Write-Milestone 'X' "audit-result.json is unreadable -- $_"
        }
    }

    # .md too: on a hold with no readable page the report is the ONLY output, and filtering to
    # *.html left the wrapper log with no record that anything was produced at all.
    $drafts = Get-ChildItem $OutputDir -File -ErrorAction SilentlyContinue |
        Where-Object { $_.Extension -in '.html', '.md' -and $_.LastWriteTime -ge $runStart }
    if ($drafts) {
        Write-Log "Draft/report files written this run:"
        $drafts | Sort-Object Name | ForEach-Object { Write-Log "  $($_.FullName)" }
    }

    $wallDur = [math]::Round(((Get-Date) - $runStart).TotalSeconds, 1)
    Write-Milestone '$' ("Run cost: `${0:N6}, duration {1}s" -f $script:TotalCostUsd, $wallDur)

} finally {
    Remove-Item -Force $LockFile -ErrorAction SilentlyContinue
    Write-Log "Lock released."
}

Write-Log "=== progress-audit run finished (task=$TaskName exit=$exitCode) ==="

# keep last 30 logs + results per task
foreach ($pat in @("${TaskName}_*.log", "${TaskName}_*.audit-result.json")) {
    Get-ChildItem $TaskLogDir -Filter $pat -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending |
        Select-Object -Skip 30 |
        Remove-Item -Force -ErrorAction SilentlyContinue
}

# --- post-run process-improvement review (report + uncommitted patches; never commits) ---
. "$ScheduledDir\..\lib\log-review.ps1"
Invoke-LogReview -LogFile $LogFile -TaskName $TaskName -ScheduledDir $ScheduledDir `
    -TargetRepo $RepoRoot -ClaudeCmd $ClaudeCmd -ExitCode $exitCode

exit $exitCode
