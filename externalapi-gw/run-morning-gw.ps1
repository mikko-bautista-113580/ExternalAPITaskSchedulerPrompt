param(
    [string]$TaskName = 'manual'
)

$ErrorActionPreference = 'Continue'

$ScheduledDir  = $PSScriptRoot   # this folder — logs/prompt/lock live alongside the wrapper

# Shared path resolution (per-machine repo/env paths). $RepoRoot still points at the
# sis-externalapi checkout that claude operates on; only the scheduler-side artifacts live here.
. "$ScheduledDir\..\lib\team.ps1"
$cfg           = Resolve-LocalConfig
$RepoRoot      = $cfg.repoExternalApi
$LogDir        = Join-Path $ScheduledDir 'logs'
$PromptFile    = Join-Path $ScheduledDir 'morning-gw-prompt.md'
$ClaudeCmd     = "$env:APPDATA\npm\claude.cmd"
$TokenFile     = Join-Path $env:USERPROFILE '.claude\github-mcp-token.txt'

# ---- ADO pre-check config (mirrors admission-ms: check for an eligible ticket
#      BEFORE any git branch switching, so the run exits cheaply when there is
#      nothing to work on). --------------------------------------------------
$EnvFile       = $cfg.envFile   # same file shared-ado-connect uses (ADO_PAT/ADO_ORG/ADO_PROJECT)
$AdoTeam       = 'Modernization Team'
$TitleMarker   = 'ExternalAPIGW'                    # story-title tag that scopes this task

$TaskLogDir = Join-Path $LogDir $TaskName
if (-not (Test-Path $TaskLogDir)) { New-Item -ItemType Directory -Path $TaskLogDir -Force | Out-Null }

$Timestamp = Get-Date -Format 'yyyyMMdd_HHmmss'
$LogFile   = Join-Path $TaskLogDir "${TaskName}_$Timestamp.log"

function Write-Log {
    param([string]$Message)
    $line = "[{0}] {1}" -f (Get-Date -Format 'yyyy-MM-ddTHH:mm:ssK'), $Message
    # Write-Host bypasses the success stream and shows up in the console immediately
    # (Write-Output can be buffered when piped). Add-Content writes to the log file
    # synchronously so `Get-Content -Wait` tails see every line in real time.
    Write-Host $line
    Add-Content -Path $LogFile -Value $line -Encoding utf8
}

Write-Log "=== morning-gw run started (task=$TaskName) ==="
Write-Log "Repo: $RepoRoot"
Write-Log "Log:  $LogFile"
Write-Log "Tail this log live:  Get-Content -Wait -Path `"$LogFile`""

if (-not (Test-Path $ClaudeCmd))  { Write-Log "FATAL: claude CLI not found at $ClaudeCmd"; exit 1 }
if (-not (Test-Path $PromptFile)) { Write-Log "FATAL: prompt file not found at $PromptFile"; exit 1 }
if (-not (Test-Path $RepoRoot))   { Write-Log "FATAL: repo directory not found at $RepoRoot"; exit 1 }
if (-not (Test-Path $EnvFile))    { Write-Log "FATAL: env file not found at $EnvFile (needs ADO_PAT/ADO_ORG/ADO_PROJECT for the ticket pre-check)"; exit 1 }

# ---- load creds from ~/repos/.env (same file shared-ado-connect uses) -------
# Used only for the read-only ADO ticket pre-check below. Claude still talks to
# ADO through the repo's .mcp.json at run time; this is just so the wrapper can
# decide up front whether there is anything to do.
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

if (-not $env:GITHUB_MCP_TOKEN) {
    if (Test-Path $TokenFile) {
        $env:GITHUB_MCP_TOKEN = (Get-Content $TokenFile -Raw).Trim()
        Write-Log "Loaded GITHUB_MCP_TOKEN from $TokenFile"
    } else {
        Write-Log "WARN: GITHUB_MCP_TOKEN not set and $TokenFile not found; GitHub MCP may fail"
    }
}

Set-Location $RepoRoot

# Concurrency guard: refuse to run if another instance is mid-flight on this repo.
# A lock is considered STALE (and removed) if EITHER the PID it records is no longer
# alive, OR it is older than 2h. The PID check matters because claude can hard-crash
# (e.g. exit 0xC0000142) and take this wrapper's process down with it before the
# finally block releases the lock -- without the PID check that orphaned lock would
# block every run for 2h.
$LockFile = Join-Path $ScheduledDir '.morning-gw.lock'
if (Test-Path $LockFile) {
    $lockAge = (Get-Date) - (Get-Item $LockFile).LastWriteTime
    $lockPid = $null
    $lockText = (Get-Content $LockFile -Raw -ErrorAction SilentlyContinue)
    if ($lockText -match 'PID=(\d+)') { $lockPid = [int]$Matches[1] }
    $pidAlive = $false
    if ($lockPid) { $pidAlive = [bool](Get-Process -Id $lockPid -ErrorAction SilentlyContinue) }

    if ($pidAlive -and $lockAge.TotalHours -lt 2) {
        Write-Log "ABORT: another scheduled run is already in progress (lock $LockFile, PID=$lockPid alive, age $([math]::Round($lockAge.TotalMinutes,1)) min). Exiting without doing anything."
        exit 0
    }
    if (-not $pidAlive) {
        Write-Log "WARN: stale lock file (PID=$lockPid not running, age $([math]::Round($lockAge.TotalMinutes,1)) min) -- removing and proceeding"
    } else {
        Write-Log "WARN: stale lock file (age $([math]::Round($lockAge.TotalHours,1))h) -- removing and proceeding"
    }
    Remove-Item -Force $LockFile -ErrorAction SilentlyContinue
}
"$TaskName $Timestamp PID=$PID" | Out-File -FilePath $LockFile -Encoding utf8

try {
    # ---- ADO discovery pre-check (skip-if-nothing-to-do) --------------------
    # Mirrors admission-ms: resolve the CURRENT sprint for the team, then look for
    # an Active ticket tagged '$TitleMarker' assigned to you. If there is nothing
    # eligible, exit 0 NOW -- before switching branches or touching the working
    # tree. This is why the branch switch no longer happens as the very first step.
    Write-Log "Resolving current sprint for team '$AdoTeam' ($AdoOrg/$AdoProject)..."
    $iterPath = $null; $iterName = $null
    try {
        $teamEnc = [uri]::EscapeDataString($AdoTeam)
        $iterUrl = "$OrgUrl/$AdoProject/$teamEnc/_apis/work/teamsettings/iterations?`$timeframe=current&api-version=7.1"
        $iter = Invoke-Ado -Url $iterUrl
        if ($iter.value -and $iter.value.Count -gt 0) {
            $iterPath = $iter.value[0].path
            $iterName = $iter.value[0].name
            Write-Log "Current sprint: '$iterName'  (iteration path: $iterPath)"
        } else {
            Write-Log "WARN: no current iteration returned for team '$AdoTeam'."
        }
    } catch {
        Write-Log "FATAL: ADO current-iteration query failed: $_"
        Write-Log "       Check ADO_PAT scope (Work Items Read) in $EnvFile and team name '$AdoTeam'."
        exit 1
    }
    if (-not $iterPath) { Write-Log "No current sprint -- nothing to do this run. Exiting without touching git."; exit 0 }

    # WIQL: Active work items in the current sprint, title-tagged '$TitleMarker',
    # AND assigned to the PAT owner (you). @Me resolves to the authenticated
    # identity behind ADO_PAT. Rule: assigned-to-me + Active + ExternalAPIGW => proceed.
    $wiql = @"
SELECT [System.Id] FROM WorkItems
WHERE [System.TeamProject] = '$AdoProject'
  AND [System.State] = 'Active'
  AND [System.AssignedTo] = @Me
  AND [System.IterationPath] = '$iterPath'
  AND [System.Title] CONTAINS '$TitleMarker'
ORDER BY [System.Id] ASC
"@
    Write-Log "Querying Active '$TitleMarker' tickets assigned to you in the sprint..."
    $eligibleIds = @()
    try {
        $wiqlUrl = "$OrgUrl/$AdoProject/_apis/wit/wiql?api-version=7.1"
        $res = Invoke-Ado -Url $wiqlUrl -Method 'POST' -Body @{ query = $wiql }
        $eligibleIds = @($res.workItems | ForEach-Object { $_.id }) | Sort-Object
    } catch {
        Write-Log "FATAL: WIQL query failed: $_"
        exit 1
    }

    if ($eligibleIds.Count -eq 0) {
        Write-Log "No Active '$TitleMarker' tickets assigned to you in sprint '$iterName' -- nothing to do this run."
        Write-Log "Exiting cleanly WITHOUT switching branches or modifying the working tree."
        exit 0
    }
    Write-Log ("Eligible '$TitleMarker' ticket(s) found: {0} -- proceeding with git pre-flight." -f ($eligibleIds -join ', '))

    Write-Log "Capturing pre-run WIP snapshot (so we can verify nothing was clobbered) ..."
    $wipBefore = git status --porcelain 2>&1
    Write-Log ("WIP before:`n" + ($wipBefore -join "`n"))

    $currentBranch = (git rev-parse --abbrev-ref HEAD 2>&1).Trim()
    Write-Log "Current branch before run: $currentBranch"

    # NEW POLICY: the prompt leaves files uncommitted on a story/* branch for user review.
    # Before starting a new run, refuse if the previous run's branch still has uncommitted
    # work — otherwise we'd either clobber it or pile new files on top.
    if ($currentBranch -like 'story/*') {
        $dirty = git status --porcelain -- ':!.mcp.json' ':!.scheduled' 2>&1 | Where-Object { $_ -ne '' }
        if ($dirty) {
            Write-Log "ABORT: repo is on '$currentBranch' with uncommitted files outside .mcp.json/.scheduled/."
            Write-Log "       The previous run's output has not been reviewed yet. Exiting without running claude."
            Write-Log "       To unblock: review the files, then either"
            Write-Log "         (a) git add <files>; git commit -m '<msg>'; git push -u origin $currentBranch  (commit + push), or"
            Write-Log "         (b) git checkout -- .; git clean -fd src/; git checkout main; git branch -D $currentBranch  (discard)"
            $dirty | ForEach-Object { Write-Log "       dirty: $_" }
            exit 0
        }
        Write-Log "Repo is on '$currentBranch' but clean -- switching back to main to start fresh."
        git checkout main 2>&1 | ForEach-Object { Write-Log "[git checkout main] $_" }
        if ($LASTEXITCODE -ne 0) {
            Write-Log "FATAL: could not check out main (exit=$LASTEXITCODE). Aborting."
            exit 1
        }
        $currentBranch = 'main'
    }

    Write-Log "Fetching origin/main ..."
    git fetch origin main 2>&1 | ForEach-Object { Write-Log "[git fetch] $_" }
    if ($LASTEXITCODE -ne 0) {
        Write-Log "FATAL: git fetch origin main failed (exit=$LASTEXITCODE)"
        exit 1
    }

    if ($currentBranch -ne 'main') {
        Write-Log "Switching to main (will preserve WIP across the switch since WIP files are not in conflict with main) ..."
        git checkout main 2>&1 | ForEach-Object { Write-Log "[git checkout main] $_" }
        if ($LASTEXITCODE -ne 0) {
            Write-Log "FATAL: could not check out main (exit=$LASTEXITCODE). Aborting without running claude."
            exit 1
        }
    }

    Write-Log "Fast-forwarding main to origin/main ..."
    git merge --ff-only origin/main 2>&1 | ForEach-Object { Write-Log "[git merge --ff-only] $_" }
    if ($LASTEXITCODE -ne 0) {
        Write-Log "WARN: ff-merge failed; main may already be up-to-date or have local commits. Continuing."
    }

    $Prompt = Get-Content $PromptFile -Raw
    # Fill path placeholders (literal .Replace — safe for Windows paths). Identity is resolved
    # inside the prompt via ADO @Me (the PAT owner), so no login substitution is needed here.
    $Prompt = $Prompt.Replace('{{REPO_ROOT}}',     $RepoRoot)
    $Prompt = $Prompt.Replace('{{SCHEDULED_DIR}}', $ScheduledDir)
    $Prompt = $Prompt.Replace('{{ENV_FILE}}',      $EnvFile)
    Write-Log "Invoking claude directly in main repo (no worktree) ..."
    Write-Log "Streaming claude events to log (stream-json -> parsed). Tail with: Get-Content -Wait `"$LogFile`""

    # --------------------------------------------------------------------------
    # Stream-JSON event parser + milestone tracker.
    # Each JSON event from `claude --output-format stream-json` is converted into
    # both (a) a detailed log line (prefix `[claude:...]`) for debugging and
    # (b) at most one milestone line (prefix `===`) for at-a-glance status.
    # Grep `===` in the log for the clean summary view.
    # --------------------------------------------------------------------------

    # Mutable tracker that records whether each milestone has fired (one-shot).
    $script:milestones = @{
        AdoConnected         = $false
        GitHubConnected      = $false
        IterationFound       = $false
        TicketsQueried       = $false
        TicketFetchStarted   = $false   # first wit_get_work_item call
        TicketParsed         = $false   # "VIEWMODELS PARSED" emitted
        TestSuitesStarted    = $false   # first testplan_list_test_cases call
        TestSuitesEnumerated = $false   # "TEST SUITES ENUMERATED" emitted
        BranchCreated        = $false
        CodegenStarted       = $false   # first Write to src/...
        BuildStarted         = $false
        BuildResult          = $null   # 'success' / 'failed' / $null
        FileWriteCount       = 0
        FileWriteNextReport  = 5        # emit a "wrote N files" milestone at 5, 10, 15, ...
        ChosenTicketId       = $null
        BranchName           = $null
    }

    function Write-Milestone {
        param([string]$icon, [string]$message)
        $line = "{0}    === {1} {2}" -f (Get-Date -Format 'yyyy-MM-ddTHH:mm:ssK'), $icon, $message
        Write-Host $line -ForegroundColor Cyan
        Add-Content -Path $LogFile -Value $line -Encoding utf8
    }

    function Track-Milestones {
        param($ev)
        try {
            # ---- assistant tool_use blocks → "starting X" signals ----
            if ($ev.type -eq 'assistant') {
                foreach ($block in $ev.message.content) {
                    if ($block.type -eq 'tool_use') {
                        $toolName = $block.name
                        $input    = $block.input

                        # Connection milestones are deferred to the tool_result side so we know they
                        # actually succeeded, not just that claude tried.

                        # "Checking ticket..." — first call to wit_get_work_item / wit_get_work_items_for_iteration
                        if (-not $script:milestones.TicketFetchStarted -and
                            ($toolName -eq 'mcp__azure__wit_get_work_item' -or
                             $toolName -eq 'mcp__azure__wit_get_work_items_for_iteration' -or
                             $toolName -eq 'mcp__azure__wit_query_by_wiql')) {
                            $script:milestones.TicketFetchStarted = $true
                            Write-Milestone '→' "Checking ticket(s) in current iteration..."
                        }

                        # "Checking test suites..." — first call to testplan_list_test_cases or testplan_list_test_suites
                        if (-not $script:milestones.TestSuitesStarted -and
                            ($toolName -eq 'mcp__azure__testplan_list_test_cases' -or
                             $toolName -eq 'mcp__azure__testplan_list_test_suites' -or
                             $toolName -eq 'mcp__azure__wiki_get_page_content')) {
                            $script:milestones.TestSuitesStarted = $true
                            Write-Milestone '→' "Checking test suites from Testing Considerations..."
                        }

                        if ($toolName -eq 'Bash' -and $input.command) {
                            $cmd = $input.command
                            if ($cmd -match '^\s*git checkout -b (story/\S+)') {
                                $br = $Matches[1]
                                if (-not $script:milestones.BranchCreated) {
                                    $script:milestones.BranchCreated = $true
                                    $script:milestones.BranchName    = $br
                                    Write-Milestone '→' "Creating branch $br"
                                }
                            }
                            if ($cmd -match 'dotnet\s+build' -and -not $script:milestones.BuildStarted) {
                                $script:milestones.BuildStarted = $true
                                Write-Milestone '→' "Building solution (dotnet build)..."
                            }
                        }

                        if ($toolName -eq 'Write' -and $input.file_path) {
                            $script:milestones.FileWriteCount++
                            if (-not $script:milestones.CodegenStarted -and
                                ($input.file_path -like '*src\Applications.SISApi*' -or
                                 $input.file_path -like '*src/Applications.SISApi*')) {
                                $script:milestones.CodegenStarted = $true
                                Write-Milestone '→' "Generating endpoint files..."
                            }
                            # Periodic running counter so the user sees codegen progress, not silence
                            if ($script:milestones.FileWriteCount -ge $script:milestones.FileWriteNextReport) {
                                Write-Milestone '→' "Wrote $($script:milestones.FileWriteCount) files so far..."
                                $script:milestones.FileWriteNextReport += 5
                            }
                        }
                    }

                    # Assistant TEXT often signals phase transitions (e.g., the prompt asks claude
                    # to echo "TICKET {id} VIEWMODELS PARSED" and "TEST SUITES ENUMERATED" markers).
                    if ($block.type -eq 'text' -and $block.text) {
                        $txt = $block.text
                        if (-not $script:milestones.TicketParsed -and $txt -match 'TICKET\s+(\d+)\s+VIEWMODELS PARSED') {
                            $script:milestones.TicketParsed   = $true
                            $script:milestones.ChosenTicketId = $Matches[1]
                            Write-Milestone '✓' "Ticket $($Matches[1]) parsed (ViewModels OK)"
                        }
                        if (-not $script:milestones.TestSuitesEnumerated -and $txt -match 'TICKET\s+(\d+)\s+TEST SUITES ENUMERATED') {
                            $script:milestones.TestSuitesEnumerated = $true
                            $tcMatch = [regex]::Match($txt, 'Total:\s+(\d+)\s+test cases')
                            $count = if ($tcMatch.Success) { $tcMatch.Groups[1].Value } else { '?' }
                            Write-Milestone '✓' "Test suites enumerated ($count test cases mapped)"
                        }
                    }
                }
            }

            # ---- tool_result blocks → "X succeeded / failed" signals ----
            if ($ev.type -eq 'user') {
                foreach ($block in $ev.message.content) {
                    if ($block.type -ne 'tool_result') { continue }

                    # We need the matching tool_use to know which tool this result is for.
                    # The stream-json doesn't always inline the name on the result side, so
                    # we infer from the previous tool_use call. Cheap heuristic: keep a tiny
                    # rolling map keyed by tool_use_id.
                    $resultText = Format-ToolResultPreview -content $block.content
                    $isError    = $block.is_error -eq $true

                    # Connection milestones — best-effort detection from the result content shape
                    if (-not $script:milestones.AdoConnected -and -not $isError -and
                        ($resultText -match 'iteration|workitem|iterations|workItems|ADO|renweb' -or
                         $resultText -match '"path"\s*:\s*"\\\\?ColdFusion')) {
                        $script:milestones.AdoConnected = $true
                        Write-Milestone '✓' "Connected to Azure DevOps (renweb)"
                    }
                    if (-not $script:milestones.GitHubConnected -and -not $isError -and
                        ($resultText -match 'pull_request|pulls|nelnet-nbs|"head":\s*\{' -or
                         $resultText -match '"head_repository"')) {
                        $script:milestones.GitHubConnected = $true
                        Write-Milestone '✓' "Connected to GitHub (nelnet-nbs/sis-externalapi)"
                    }

                    # Build result detection
                    if ($script:milestones.BuildStarted -and $null -eq $script:milestones.BuildResult) {
                        if ($resultText -match 'Build succeeded' -or
                            ($resultText -match '\b0 Error\(s\)' -and $resultText -notmatch 'Build FAILED')) {
                            $script:milestones.BuildResult = 'success'
                            $warnMatch = [regex]::Match($resultText, '(\d+)\s+Warning\(s\)')
                            $warns = if ($warnMatch.Success) { $warnMatch.Groups[1].Value } else { '?' }
                            Write-Milestone '✓' "Build succeeded (warnings: $warns)"
                        }
                        elseif ($resultText -match 'Build FAILED' -or
                                $resultText -match '\b[1-9]\d*\s+Error\(s\)') {
                            $script:milestones.BuildResult = 'failed'
                            $errMatch  = [regex]::Match($resultText, '(\d+)\s+Error\(s\)')
                            $errs = if ($errMatch.Success) { $errMatch.Groups[1].Value } else { '?' }
                            Write-Milestone '✗' "Build failed (errors: $errs) — claude will attempt to fix and retry"
                        }
                    }
                }
            }

            # ---- final result event ----
            if ($ev.type -eq 'result') {
                $sub  = $ev.subtype
                $cost = $ev.total_cost_usd
                $dur  = [math]::Round($ev.duration_ms / 1000, 1)
                $writeCount = $script:milestones.FileWriteCount
                if ($sub -eq 'success') {
                    Write-Milestone '✓' "DONE — duration ${dur}s, cost `$$cost, files written: $writeCount"
                } else {
                    Write-Milestone '✗' "FAILED — subtype=$sub, duration ${dur}s, files written: $writeCount"
                }
            }
        } catch {
            # Never let milestone tracking crash the main parser
            Write-Log "[milestone-tracker-err] $_"
        }
    }

    function Format-ToolUseSummary {
        param($name, $input)
        if ($null -eq $input) { return "$name (no input)" }
        switch ($name) {
            'Bash'       { return "Bash: $(($input.command -replace '\s+', ' ') -replace '^(.{0,160}).*', '$1')" }
            'Read'       { return "Read: $($input.file_path)$(if ($input.offset) { " offset=$($input.offset) limit=$($input.limit)" })" }
            'Write'      { return "Write: $($input.file_path) ($(($input.content -split '\n').Count) lines)" }
            'Edit'       { return "Edit: $($input.file_path)" }
            'Glob'       { return "Glob: $($input.pattern)$(if ($input.path) { " in $($input.path)" })" }
            'Grep'       { return "Grep: $($input.pattern)$(if ($input.glob) { " (glob=$($input.glob))" })" }
            'PowerShell' { return "PowerShell: $(($input.command -replace '\s+', ' ') -replace '^(.{0,160}).*', '$1')" }
            'TodoWrite'  { return "TodoWrite: $((($input.todos) | ForEach-Object { '[' + $_.status[0] + '] ' + $_.content }) -join ' | ')" }
            'Skill'      { return "Skill: $($input.skill)$(if ($input.args) { " args=$($input.args -replace '\s+', ' ' -replace '^(.{0,80}).*','$1')" })" }
            'Agent'      { return "Agent: subagent_type=$($input.subagent_type) desc=$($input.description)" }
            'WebFetch'   { return "WebFetch: $($input.url)" }
            'WebSearch'  { return "WebSearch: $($input.query)" }
            default {
                $json = ($input | ConvertTo-Json -Compress -Depth 3 -ErrorAction SilentlyContinue) -replace '\s+', ' '
                if ($json.Length -gt 200) { $json = $json.Substring(0, 200) + '...' }
                return "$name $json"
            }
        }
    }

    function Format-ToolResultPreview {
        param($content)
        if ($null -eq $content) { return '(empty)' }
        $text = if ($content -is [array]) {
            ($content | ForEach-Object {
                if ($_.type -eq 'text') { $_.text } else { ($_ | ConvertTo-Json -Compress -Depth 2) }
            }) -join ' '
        } elseif ($content -is [string]) { $content } else { $content | ConvertTo-Json -Compress -Depth 2 }
        $text = $text -replace '\s+', ' '
        if ($text.Length -gt 250) { $text = $text.Substring(0, 250) + '...' }
        return $text
    }

    function Process-ClaudeEvent {
        param([string]$line)
        if ([string]::IsNullOrWhiteSpace($line)) { return }
        try {
            # NOTE: -Depth was added to ConvertFrom-Json in PowerShell 6+. PS 5.1 rejects it.
            # Drop it so the wrapper works under both Windows PowerShell 5.1 (powershell.exe)
            # and PowerShell 7+ (pwsh.exe). The default depth is plenty for stream-json events.
            $ev = $line | ConvertFrom-Json -ErrorAction Stop
        } catch {
            # Not JSON (could be stderr from npx/node) — log raw with a tag
            Write-Log "[claude:raw] $line"
            return
        }
        # Update at-a-glance milestones before emitting the detailed line(s)
        Track-Milestones -ev $ev
        switch ($ev.type) {
            'system' {
                if ($ev.subtype -eq 'init') {
                    $toolCount = if ($ev.tools) { ($ev.tools).Count } else { 0 }
                    Write-Log "[claude:init] model=$($ev.model) cwd=$($ev.cwd) tools=$toolCount session=$($ev.session_id)"
                } else {
                    Write-Log "[claude:system] $($ev.subtype)"
                }
            }
            'assistant' {
                foreach ($block in $ev.message.content) {
                    switch ($block.type) {
                        'text' {
                            ($block.text -split "`r?`n") | Where-Object { $_ -ne '' } |
                                ForEach-Object { Write-Log "[claude] $_" }
                        }
                        'tool_use' {
                            Write-Log "[claude:tool->] $(Format-ToolUseSummary -name $block.name -input $block.input)"
                        }
                        'thinking' {
                            $t = ($block.thinking -replace "`r?`n", ' ')
                            if ($t.Length -gt 200) { $t = $t.Substring(0, 200) + '...' }
                            Write-Log "[claude:thinking] $t"
                        }
                        default {
                            Write-Log "[claude:assistant:?] $($block.type)"
                        }
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
                if ($r.Length -gt 500) { $r = $r.Substring(0, 500) + '...' }
                Write-Log "[claude:DONE] subtype=$($ev.subtype) duration=$($ev.duration_ms)ms cost=`$$($ev.total_cost_usd)"
                Write-Log "[claude:final] $r"
            }
            default {
                Write-Log "[claude:event:$($ev.type)] (no formatter)"
            }
        }
    }

    Write-Milestone '✓' "Wrapper pre-flight passed (on main, fetched origin/main)"
    Write-Milestone '→' "Launching claude (model=claude-opus-4-7)..."

    $exitCode = 0
    try {
        $Prompt | & $ClaudeCmd `
            --print `
            --verbose `
            --dangerously-skip-permissions `
            --model claude-opus-4-7 `
            --output-format stream-json `
            --input-format text 2>&1 |
            ForEach-Object { Process-ClaudeEvent -line $_ }
        $exitCode = $LASTEXITCODE
    } catch {
        Write-Log "EXCEPTION: $_"
        Write-Milestone '✗' "claude crashed with exception: $_"
        $exitCode = 1
    }

    Write-Log "claude exited with code $exitCode"

    # NEW POLICY: do NOT switch back to main. The prompt leaves generated files
    # uncommitted on story/{id} for the user to review. Switching back to main here
    # would either carry the files over (contaminating main) or strand the user on
    # main with hidden uncommitted state on the story branch. Just log where we are.
    $finalBranch = (git rev-parse --abbrev-ref HEAD 2>&1).Trim()
    Write-Log "Repo left on branch: $finalBranch (per leave-uncommitted-for-review policy)"

    Write-Log "Post-run WIP snapshot:"
    $wipAfter = git status --porcelain 2>&1
    Write-Log ("WIP after:`n" + ($wipAfter -join "`n"))

    # Sanity-check: every file in wipBefore should still be in wipAfter (untouched).
    # If claude accidentally staged or modified the user's WIP, surface it loudly.
    $wipBeforeSet = $wipBefore | Where-Object { $_ -ne '' } | Sort-Object -Unique
    $wipAfterSet  = $wipAfter  | Where-Object { $_ -ne '' } | Sort-Object -Unique
    $missing = $wipBeforeSet | Where-Object { $_ -notin $wipAfterSet }
    if ($missing) {
        Write-Log "WARN: WIP entries present before the run are no longer present after -- possible clobber:"
        $missing | ForEach-Object { Write-Log "  MISSING: $_" }
    } else {
        Write-Log "WIP preserved correctly."
    }

    Write-Log "Branches created in this run (refs/heads/story/*) since fetch:"
    git for-each-ref --sort=-committerdate --format='%(refname:short) %(committerdate:iso8601) %(subject)' refs/heads/story/ 2>&1 |
        ForEach-Object { Write-Log "  $_" }

} finally {
    Remove-Item -Force $LockFile -ErrorAction SilentlyContinue
    Write-Log "Lock released."
}

Write-Log "=== morning-gw run finished (task=$TaskName exit=$exitCode) ==="

Get-ChildItem $TaskLogDir -Filter "${TaskName}_*.log" |
    Sort-Object LastWriteTime -Descending |
    Select-Object -Skip 30 |
    Remove-Item -Force -ErrorAction SilentlyContinue

# --- post-run process-improvement review (report + uncommitted patches; never commits) ---
. "$ScheduledDir\..\lib\log-review.ps1"
Invoke-LogReview -LogFile $LogFile -TaskName $TaskName -ScheduledDir $ScheduledDir `
    -TargetRepo $RepoRoot -ClaudeCmd $ClaudeCmd -ExitCode $exitCode

exit $exitCode
