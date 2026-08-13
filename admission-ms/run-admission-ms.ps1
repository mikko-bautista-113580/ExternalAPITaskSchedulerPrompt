param(
    [string]$TaskName = 'manual',
    # Model passed to the claude CLI. Pinned to Claude Opus 5 (best for full-impl + build).
    # Pass 'sonnet' for cheaper/faster runs.
    [string]$Model = 'claude-opus-5'
)

$ErrorActionPreference = 'Continue'

# ============================================================================
#  PER-MS CONFIG  --  to clone this generator for another microservice, copy
#  the whole folder and change ONLY this block (name, service dir, title marker).
# ============================================================================
$MsName        = 'admission-ms'                 # folder + log/lock identity
$ServiceRel    = 'src\Services.Admissions'       # service dir under the repo
$TitleMarker   = 'AdmissionsMS'                   # story-title tag that scopes this MS ([AdmissionsMS]); must NOT match GW stories ([ExternalAPIGW] ... Admissions ...)
# ============================================================================

$Repo          = 'nelnet-nbs/sis-services'
$ScheduledDir  = $PSScriptRoot   # this folder — logs/prompt/lock live alongside the wrapper

# Shared path resolution (per-machine repo/env paths) + roster (reference-PR authors).
. "$ScheduledDir\..\lib\team.ps1"
$cfg           = Resolve-LocalConfig

$RepoRoot      = $cfg.repoServices
$ServiceDir    = Join-Path $RepoRoot $ServiceRel
$LogDir        = Join-Path $ScheduledDir 'logs'
$PromptFile    = Join-Path $ScheduledDir "$MsName-prompt.md"
$ClaudeCmd     = "$env:APPDATA\npm\claude.cmd"
$EnvFile       = $cfg.envFile
$LockFile      = Join-Path $ScheduledDir ".$MsName.lock"
$AdoTeam       = 'Modernization Team'

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

Write-Log "=== $MsName endpoint-gen run started (task=$TaskName, model=$Model) ==="
Write-Log "Repo:     $RepoRoot ($Repo)"
Write-Log "Service:  $ServiceDir"
Write-Log "Log:      $LogFile"
Write-Log "Tail this log live:  Get-Content -Wait -Path `"$LogFile`""

# ---- pre-flight ------------------------------------------------------------
if (-not (Test-Path $ClaudeCmd))  { Write-Log "FATAL: claude CLI not found at $ClaudeCmd"; exit 1 }
if (-not (Test-Path $PromptFile)) { Write-Log "FATAL: prompt file not found at $PromptFile"; exit 1 }
if (-not (Test-Path $RepoRoot))   { Write-Log "FATAL: repo directory not found at $RepoRoot"; exit 1 }
if (-not (Test-Path $EnvFile))    { Write-Log "FATAL: env file not found at $EnvFile (needs ADO_PAT/ADO_ORG/ADO_PROJECT)"; exit 1 }

# ---- load creds from ~/repos/.env (same file shared-ado-connect uses) ------
$envMap = @{}
Get-Content $EnvFile | ForEach-Object {
    $t = $_.Trim()
    if ($t -and -not $t.StartsWith('#') -and $t.Contains('=')) {
        $k, $v = $t -split '=', 2
        $envMap[$k.Trim()] = $v.Trim().Trim('"').Trim("'")
    }
}
$AdoPat     = $envMap['ADO_PAT']
$AdoOrg     = if ($envMap['ADO_ORG'])     { $envMap['ADO_ORG'] }     else { 'renweb' }
$AdoProject = if ($envMap['ADO_PROJECT']) { $envMap['ADO_PROJECT'] } else { 'ColdFusion' }
if (-not $AdoPat) { Write-Log "FATAL: ADO_PAT not present in $EnvFile"; exit 1 }

$AuthHeader = @{ Authorization = 'Basic ' + [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes(":$AdoPat")) }
$OrgUrl     = "https://dev.azure.com/$AdoOrg"

function Invoke-Ado {
    param([string]$Url, [string]$Method = 'GET', $Body = $null)
    $args = @{ Uri = $Url; Method = $Method; Headers = $AuthHeader; ContentType = 'application/json' }
    if ($Body) { $args.Body = ($Body | ConvertTo-Json -Depth 6) }
    return Invoke-RestMethod @args
}

Set-Location $RepoRoot

# ---- concurrency guard -----------------------------------------------------
if (Test-Path $LockFile) {
    $lockAge = (Get-Date) - (Get-Item $LockFile).LastWriteTime
    if ($lockAge.TotalMinutes -lt 90) {
        Write-Log "ABORT: another $MsName run is in progress (lock age $([math]::Round($lockAge.TotalMinutes,1)) min). Exiting."
        exit 0
    }
    Write-Log "WARN: stale lock (age $([math]::Round($lockAge.TotalHours,1))h) -- removing and proceeding."
    Remove-Item -Force $LockFile -ErrorAction SilentlyContinue
}
"$TaskName $Timestamp PID=$PID" | Out-File -FilePath $LockFile -Encoding utf8

$exitCode = 0
# Cost + duration tracking (defined before the try so the finally block can always
# report them, even on an early 'nothing to generate' exit where claude never launches => $0).
$script:TotalCostUsd   = 0.0
$script:ClaudeLaunched = $false
$runStart              = Get-Date
try {
    # ---- ADO discovery pre-check (skip-if-nothing-to-do) -------------------
    # Resolve the CURRENT sprint for the team, then find Active MS user stories.
    Write-Milestone '>' "Resolving current sprint for team '$AdoTeam' ($AdoOrg/$AdoProject)..."
    $iterPath = $null; $iterName = $null
    try {
        $teamEnc = [uri]::EscapeDataString($AdoTeam)
        $iterUrl = "$OrgUrl/$AdoProject/$teamEnc/_apis/work/teamsettings/iterations?`$timeframe=current&api-version=7.1"
        $iter = Invoke-Ado -Url $iterUrl
        if ($iter.value -and $iter.value.Count -gt 0) {
            $iterPath = $iter.value[0].path
            $iterName = $iter.value[0].name
            Write-Milestone 'v' "Current sprint: '$iterName'  (iteration path: $iterPath)"
        } else {
            Write-Log "WARN: no current iteration returned for team '$AdoTeam'."
        }
    } catch {
        Write-Log "FATAL: ADO current-iteration query failed: $_"
        Write-Log "       Check ADO_PAT scope (Work Items Read) in $EnvFile and team name '$AdoTeam'."
        exit 1
    }
    if (-not $iterPath) { Write-Milestone 'i' "No current sprint -- nothing to generate."; exit 0 }

    # WIQL: Active User Stories in the current sprint, tagged this MS, AND assigned to
    # the PAT owner (you). @Me resolves to the authenticated identity behind ADO_PAT.
    # Rule: assigned-to-me + Active => proceed; otherwise skip.
    $wiql = @"
SELECT [System.Id] FROM WorkItems
WHERE [System.TeamProject] = '$AdoProject'
  AND [System.WorkItemType] = 'User Story'
  AND [System.State] = 'Active'
  AND [System.AssignedTo] = @Me
  AND [System.IterationPath] = '$iterPath'
  AND [System.Title] CONTAINS '$TitleMarker'
ORDER BY [System.Id] ASC
"@
    Write-Milestone '>' "Querying Active '$TitleMarker' user stories assigned to you in the sprint..."
    $ids = @()
    try {
        $wiqlUrl = "$OrgUrl/$AdoProject/_apis/wit/wiql?api-version=7.1"
        $res = Invoke-Ado -Url $wiqlUrl -Method 'POST' -Body @{ query = $wiql }
        $ids = @($res.workItems | ForEach-Object { $_.id }) | Sort-Object
    } catch {
        Write-Log "FATAL: WIQL query failed: $_"
        exit 1
    }

    if ($ids.Count -eq 0) {
        Write-Milestone 'i' "No Active '$TitleMarker' user stories assigned to you in sprint '$iterName' -- nothing to generate."
        exit 0
    }

    # Pull titles/states for logging + to hand to the prompt.
    $stories = @()
    try {
        $fields = 'System.Id,System.Title,System.State,System.WorkItemType'
        $wiUrl  = "$OrgUrl/$AdoProject/_apis/wit/workitems?ids=$($ids -join ',')&fields=$fields&api-version=7.1"
        $wi = Invoke-Ado -Url $wiUrl
        $stories = @($wi.value | ForEach-Object {
            [pscustomobject]@{ Id = $_.id; Title = $_.fields.'System.Title'; State = $_.fields.'System.State' }
        })
    } catch {
        Write-Log "WARN: could not fetch story titles (continuing with IDs only): $_"
        $stories = @($ids | ForEach-Object { [pscustomobject]@{ Id = $_; Title = ''; State = 'Active' } })
    }
    foreach ($s in $stories) { Write-Log "  Active story #$($s.Id): $($s.Title)" }

    # Desired branch name: one per run. Single story -> story/<id>;
    # multiple -> story/<id1>_<id2>_... (IDs sorted ascending).
    $desired    = 'story/' + ($ids -join '_')
    $branchName = $desired
    $branchMode = 'create'   # 'create' = fresh branch off origin/main; 'reuse' = continue on existing
    Write-Milestone '>' "Desired branch: $desired  (stories: $($ids -join ', '))"

    # ---- git-clean guard (SAFETY: never clobber uncommitted work) ----------
    # NB: a previous run leaves generated files UNCOMMITTED on the story branch
    # (the user reviews + commits). So if you have not yet committed/stashed that
    # work, the tree is dirty and this run correctly aborts rather than clobber it.
    $branchBefore = (git rev-parse --abbrev-ref HEAD 2>&1).Trim()
    # TrimEnd (not Trim): porcelain lines are ' M path' for unstaged edits, and a leading-space strip
    # on the first line makes it read as 'M path' (staged) in the log.
    $dirty = (git status --porcelain 2>&1 | Out-String).TrimEnd()
    if ($dirty) {
        Write-Milestone 'X' "ABORT: working tree is dirty on '$branchBefore' -- refusing to touch it. Review/commit/stash and re-run."
        Write-Log "Uncommitted changes:`n$dirty"
        exit 0
    }
    Write-Log "Working tree clean. Current branch: $branchBefore"

    Write-Log "Fetching origin (prune) ..."
    # Fetch helper: logs the interesting output but collapses the '- [deleted]' prune lines into a
    # single count (this repo prunes 100+ refs per run, which drowned the rest of the log).
    function Invoke-GitFetchPrune {
        $out     = git fetch --prune origin 2>&1
        $code    = $LASTEXITCODE
        $deleted = 0
        foreach ($l in $out) {
            if ("$l" -match '^\s*-\s*\[deleted\]') { $deleted++ } else { Write-Log "[git fetch] $l" }
        }
        if ($deleted -gt 0) { Write-Log "[git fetch] pruned $deleted deleted remote ref(s)." }
        return $code
    }
    # Ref-deletion is TRANSACTIONAL: a single un-acquirable '<ref>.lock' aborts the whole prune, so a
    # blind retry replays the identical failure. Observed 2026-08-12: both passes reported the same
    # lock ('refs/remotes/origin/bug/295788-duplicate-oa-cc-sda.lock') and the same 112 refs left
    # unpruned, i.e. the leftover lock is STALE (a crashed/killed earlier git), not self-clearing.
    # Clear only demonstrably-stale locks: '*.lock' under .git/refs/remotes/origin older than 10 min.
    # A lock a live git just created is younger than that and is left alone (retry then behaves as
    # before, and the log says which case it was). These shadow remote-tracking refs only -- the very
    # next fetch regenerates them; nothing under the working tree is touched.
    function Clear-StaleRefLocks {
        $refDir = Join-Path $RepoRoot '.git\refs\remotes\origin'
        if (-not (Test-Path $refDir)) { Write-Log "[git fetch] no refs/remotes/origin dir -- skipping stale-lock sweep."; return }
        $cutoff = (Get-Date).AddMinutes(-10)
        $stale  = @(Get-ChildItem -LiteralPath $refDir -Filter '*.lock' -Recurse -File -ErrorAction SilentlyContinue |
                    Where-Object { $_.LastWriteTime -lt $cutoff })
        if ($stale.Count -eq 0) { Write-Log "[git fetch] no stale (>10 min) ref locks under refs/remotes/origin -- leaving them alone."; return }
        foreach ($f in $stale) {
            Write-Log "[git fetch] removing stale ref lock (age $([math]::Round(((Get-Date) - $f.LastWriteTime).TotalHours,1))h): $($f.FullName)"
            Remove-Item -Force -LiteralPath $f.FullName -ErrorAction SilentlyContinue
        }
    }
    $fetchExit = Invoke-GitFetchPrune
    if ($fetchExit -ne 0) {
        Write-Log "WARN: git fetch failed (exit=$fetchExit) -- clearing stale ref locks and retrying once."
        Clear-StaleRefLocks
        $fetchExit = Invoke-GitFetchPrune
    }
    if ($fetchExit -ne 0) { Write-Log "WARN: git fetch still failing (exit=$fetchExit) -- continuing on cached refs." }

    # ---- resolve a usable branch: REUSE the existing one if safe, else a UNIQUE new one ----
    # Policy (replaces the old "branch exists -> skip"): if the desired branch already exists,
    # reuse it when it is safe to continue on -- i.e. it has NOT diverged from origin/main
    # (origin/main is still an ancestor of its tip), so adding work / merging origin/main cannot
    # conflict. If it HAS diverged (conflict risk), or only a remote branch of that name exists,
    # fall back to the next unique name story/<ids>-2, -3, ... so we never clobber or fight an
    # existing branch. The actual checkout/switch is done by Claude per the mode (see the prompt).
    function Test-RefExists {
        param([string]$ref)
        git rev-parse --verify --quiet $ref > $null 2>&1
        return ($LASTEXITCODE -eq 0)
    }
    function Test-BranchTaken {
        param([string]$name)
        return ((Test-RefExists "refs/heads/$name") -or (Test-RefExists "refs/remotes/origin/$name"))
    }
    function Get-UniqueBranch {
        param([string]$base)
        $n = 2
        while (Test-BranchTaken "$base-$n") { $n++ }
        return "$base-$n"
    }

    if (Test-RefExists "refs/heads/$desired") {
        # Local branch exists. Reuse it unless it has GENUINELY diverged from origin/main -- i.e. only
        # when NEITHER is an ancestor of the other (a real merge-conflict risk). If the branch is merely
        # behind main, ahead of main, or equal, one is an ancestor of the other and a merge/ff is clean
        # -> safe to reuse. True divergence -> fall back to a unique name.
        git merge-base --is-ancestor "refs/heads/$desired" origin/main 2>$null; $branchInMain = ($LASTEXITCODE -eq 0)
        git merge-base --is-ancestor origin/main "refs/heads/$desired" 2>$null; $mainInBranch = ($LASTEXITCODE -eq 0)
        if ($branchInMain -or $mainInBranch) {
            $branchName = $desired
            $branchMode = 'reuse'
            Write-Milestone 'i' "Branch '$desired' exists and has not diverged from origin/main -- REUSING it (continue work on top)."
        } else {
            $branchName = Get-UniqueBranch $desired
            $branchMode = 'create'
            Write-Milestone 'i' "Branch '$desired' has diverged from origin/main (conflict risk) -- creating UNIQUE branch '$branchName' instead."
        }
    } elseif (Test-RefExists "refs/remotes/origin/$desired") {
        # Only a remote branch of that name exists; avoid implying a link -- use a unique local name.
        $branchName = Get-UniqueBranch $desired
        $branchMode = 'create'
        Write-Milestone 'i' "Remote 'origin/$desired' exists but no local branch -- creating UNIQUE branch '$branchName'."
    } else {
        Write-Milestone 'v' "Branch '$desired' is free -- will create it fresh off origin/main."
    }
    Write-Milestone '>' "Target branch: $branchName  (mode: $branchMode)"

    # ---- build the story context block appended to the prompt --------------
    $storyLines = ($stories | ForEach-Object { "- #$($_.Id) [$($_.State)] $($_.Title)" }) -join "`n"
    $contextBlock = @"

---
## Runtime inputs (supplied by the wrapper -- authoritative for THIS run)

- Microservice: ``$MsName``  (service dir ``$ServiceRel``, title tag ``$TitleMarker``)
- ADO org/project: ``$AdoOrg`` / ``$AdoProject``
- Current sprint: ``$iterName`` (iteration path: ``$iterPath``)
- Target branch: ``$branchName``
- Branch mode: ``$branchMode``  ('create' = make this fresh branch off origin/main with ``git checkout origin/main -b $branchName``, never ``-B``; 'reuse' = continue on the EXISTING branch with ``git switch $branchName`` -- do NOT reset it -- then follow Step 2's reuse/conflict handling.)
- Active user stories to implement this run:
$storyLines

Implement an endpoint for EACH story above, all on the single branch ``$branchName`` (respecting the branch mode above).
Re-fetch each story's full detail from ADO before coding -- including the ``Microsoft.VSTS.TCM.SystemInfo`` (Technical Requirements) field.
Leave the generated files UNCOMMITTED on the branch -- do not commit or push.
"@

    # ---- launch claude -----------------------------------------------------
    $script:m = @{ AdoSeen=$false; GitSeen=$false; BuildSeen=$false; Generated=0; BuildOk=$null; AgentsDispatched=0 }

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
            'Edit'       { return "Edit: $($toolInput.file_path)" }
            'Glob'       { return "Glob: $($toolInput.pattern)" }
            'Grep'       { return "Grep: $($toolInput.pattern)$(if ($toolInput.path) { " in $($toolInput.path)" })$(if ($toolInput.glob) { " (glob=$($toolInput.glob))" })" }
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
        # Error text is the one thing a post-run review actually needs in full. The flat 250-char cap
        # truncated the 2026-08-12 ADO failure to '"message": "VS4...' -- the agent burned a retry and
        # the log could not say why. Give error-SHAPED results a wider window; everything else keeps
        # the compact cap so the log stays readable.
        $cap = if ($text -match 'Exception|Invoke-RestMethod:|error CS\d|VS\d{6}|fatal:|is not recognized|Command timed out') { 1200 } else { 250 }
        if ($text.Length -gt $cap) { $text = $text.Substring(0, $cap) + '...' }
        return $text
    }
    function Track-Milestones {
        param($ev)
        try {
            if ($ev.type -eq 'assistant') {
                foreach ($block in $ev.message.content) {
                    if ($block.type -eq 'tool_use' -and ($block.name -eq 'Bash' -or $block.name -eq 'PowerShell')) {
                        $cmd = $block.input.command
                        if ($cmd -match 'dev\.azure\.com|az\s+boards|wiql|workitems' -and -not $script:m.AdoSeen) {
                            $script:m.AdoSeen = $true; Write-Milestone '>' "Reading ADO work-item detail..."
                        }
                        if ($cmd -match 'git\s+(checkout|switch)' -and -not $script:m.GitSeen) {
                            $script:m.GitSeen = $true; Write-Milestone '>' "Creating the story branch..."
                        }
                        if ($cmd -match 'dotnet\s+build' -and -not $script:m.BuildSeen) {
                            $script:m.BuildSeen = $true; Write-Milestone '>' "Building the service..."
                        }
                    }
                    if ($block.type -eq 'tool_use' -and ($block.name -eq 'Agent' -or $block.name -eq 'Task')) {
                        $script:m.AgentsDispatched++
                        $sub = if ($block.input.subagent_type) { $block.input.subagent_type } else { 'agent' }
                        $desc = if ($block.input.description) { $block.input.description } else { '' }
                        Write-Milestone '>' "Dispatched sub-agent #$($script:m.AgentsDispatched) [$sub] $desc"
                    }
                    if ($block.type -eq 'text' -and $block.text) {
                        $txt = $block.text
                        foreach ($mm in [regex]::Matches($txt, 'STORY (\d+) GENERATED:\s*([^\r\n]+)')) {
                            $script:m.Generated++
                            Write-Milestone 'v' "Story #$($mm.Groups[1].Value) generated - $($mm.Groups[2].Value.Trim())"
                        }
                        foreach ($mm in [regex]::Matches($txt, '(?m)^\s*BUILD:\s*(SUCCESS|FAIL)')) {
                            $script:m.BuildOk = ($mm.Groups[1].Value -eq 'SUCCESS')
                            Write-Milestone $(if ($script:m.BuildOk) { 'v' } else { 'X' }) "Build result: $($mm.Groups[1].Value)"
                        }
                    }
                }
            }
            if ($ev.type -eq 'result') {
                $dur = [math]::Round($ev.duration_ms / 1000, 1)
                if ($null -ne $ev.total_cost_usd) { $script:TotalCostUsd = [double]$ev.total_cost_usd }
                if ($ev.subtype -eq 'success') {
                    Write-Milestone 'v' "DONE - duration ${dur}s, cost `$$($ev.total_cost_usd), stories generated: $($script:m.Generated)"
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
                elseif ($ev.subtype -eq 'thinking_tokens') { }  # per-delta token-accounting heartbeat -- carries no payload; suppress (was ~45% of the log)
                else { Write-Log "[claude:system] $($ev.subtype)" }
            }
            'assistant' {
                foreach ($block in $ev.message.content) {
                    switch ($block.type) {
                        'text'     { ($block.text -split "`r?`n") | Where-Object { $_ -ne '' } | ForEach-Object { Write-Log "[claude] $_" } }
                        'tool_use' { Write-Log "[claude:tool->] $(Format-ToolUseSummary -name $block.name -toolInput $block.input)" }
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

    Write-Milestone 'v' "Pre-flight passed (ADO reachable, sprint resolved, tree clean, origin fetched)."
    Write-Milestone '>' "Launching claude (model=$Model) to generate endpoint(s) on $branchName..."

    # Reference-PR authors = the teammates whose merged endpoint PRs are the canonical file-set
    # template (roster minus you). gh may be unavailable in the scheduled env — fall back to the
    # full roster rather than failing the build (the prompt also has committed exemplars).
    try {
        $meLogin    = Get-CurrentGitHubLogin
        $refAuthors = @(Get-ReviewAuthors -CurrentLogin $meLogin)
    } catch {
        $refAuthors = @(Get-TeamRoster | ForEach-Object { $_.github })
        Write-Log "Reference authors: gh login unavailable ($_); using full roster."
    }
    Write-Log "Reference-PR authors: $($refAuthors -join ', ')"

    $Prompt = (Get-Content $PromptFile -Raw) + "`n" + $contextBlock
    # Fill path/identity placeholders (literal .Replace — safe for Windows paths).
    $Prompt = $Prompt.Replace('{{REFERENCE_AUTHORS}}', ($refAuthors -join ', '))
    $Prompt = $Prompt.Replace('{{REPO_ROOT}}',     $RepoRoot)
    $Prompt = $Prompt.Replace('{{SCHEDULED_DIR}}', $ScheduledDir)
    $Prompt = $Prompt.Replace('{{ENV_FILE}}',      $EnvFile)
    $script:ClaudeLaunched = $true
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

    # ---- report what was produced (left UNCOMMITTED on the branch) ---------
    $branchAfter = (git rev-parse --abbrev-ref HEAD 2>&1).Trim()
    git rev-parse --verify --quiet "refs/heads/$branchName" > $null 2>&1
    if ($LASTEXITCODE -eq 0) {
        $changed = (git status --porcelain 2>&1 | Out-String).TrimEnd()   # TrimEnd: keep the ' M' status column intact
        Write-Milestone 'v' "Branch '$branchName' created; generated files left UNCOMMITTED for your review."
        if ($branchAfter -ne $branchName) {
            Write-Milestone 'X' "NOTE: expected to be left on '$branchName' but HEAD is '$branchAfter'. Check the log."
        }
        if ($changed) {
            Write-Log "Uncommitted changes on '$branchName' (review then commit yourself):`n$changed"
        } else {
            Write-Log "WARN: branch exists but working tree shows no changes -- generation may have failed."
        }
        Write-Milestone 'i' "Review:  git -C $RepoRoot status   |   git -C $RepoRoot diff"
    } else {
        Write-Milestone 'X' "Branch '$branchName' was NOT created -- see log above (ambiguous story / build failure / error)."
    }
    # Intentionally DO NOT commit, push, or switch branches. The repo is left on the
    # story branch with the generated changes staged in the working tree for the user.

} finally {
    # ---- always surface this run's cost + wall-clock duration (early exit => $0) ----
    $wallDur = [math]::Round(((Get-Date) - $runStart).TotalSeconds, 1)
    Write-Milestone '$' ("Run cost: `${0:N6}, duration {1}s  (claude launched: {2})" -f $script:TotalCostUsd, $wallDur, $(if ($script:ClaudeLaunched) { 'yes' } else { 'no' }))
    Remove-Item -Force $LockFile -ErrorAction SilentlyContinue
    Write-Log "Lock released."
}

Write-Log "=== $MsName endpoint-gen run finished (task=$TaskName exit=$exitCode) ==="

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
