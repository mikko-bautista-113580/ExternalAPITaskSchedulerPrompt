# team.ps1 — shared identity + path resolution for the scheduler projects.
#
# Dot-source from any wrapper:   . "$PSScriptRoot\..\lib\team.ps1"
#
# Single source of truth:
#   team-roster.json        (committed)      — the team members + GitHub logins
#   config.local.json       (git-ignored)    — per-machine repo/output paths
#   config.local.example.json (committed)    — template for the above
#
# All functions are read-only. Warnings go to the warning stream (captured by the
# wrappers' 2>&1 logging); nothing here mutates state.

$script:TeamLibDir  = $PSScriptRoot                       # ...\lib
$script:RepoRootDir = Split-Path -Parent $script:TeamLibDir   # repo root (parent of lib\)

function Get-TeamRoster {
    <#  Returns the array of roster members ({ name, github }). Throws if missing/malformed. #>
    param([string]$RosterPath = (Join-Path $script:RepoRootDir 'team-roster.json'))
    if (-not (Test-Path $RosterPath)) { throw "team-roster.json not found at $RosterPath" }
    $data = Get-Content $RosterPath -Raw | ConvertFrom-Json
    if (-not $data.members) { throw "team-roster.json has no 'members' array ($RosterPath)" }
    return @($data.members)
}

function Get-CurrentGitHubLogin {
    <#  Auto-detect who is running this: the authenticated GitHub login. #>
    $login = (gh api user -q .login 2>$null | Out-String).Trim()
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($login)) {
        throw "Could not resolve current GitHub login via 'gh api user -q .login'. Is gh authenticated for nelnet-nbs? Fix: gh auth login"
    }
    return $login
}

function Get-ReviewAuthors {
    <#  The teammates whose PRs the current user should review = roster minus self.
        If the current login isn't in the roster, returns the FULL roster (and warns) so
        the run never silently reviews no one. #>
    param(
        [string]$CurrentLogin = (Get-CurrentGitHubLogin),
        [object[]]$Roster     = (Get-TeamRoster)
    )
    $all = @($Roster | ForEach-Object { $_.github })
    if ($all -notcontains $CurrentLogin) {
        Write-Warning "Current GitHub login '$CurrentLogin' is not in team-roster.json; reviewing ALL roster members."
        return $all
    }
    return @($all | Where-Object { $_ -ne $CurrentLogin })
}

function Resolve-LocalConfig {
    <#  Per-machine paths: config.local.json merged over USERPROFILE-based defaults.
        %USERPROFILE% (and any %VAR%) in the JSON is expanded. #>
    param([string]$ConfigPath = (Join-Path $script:RepoRootDir 'config.local.json'))
    $defaults = [ordered]@{
        repoExternalApi = 'c:\neldevsrc\Github\sis-externalapi'
        repoServices    = 'c:\neldevsrc\Github\sis-services'
        envFile         = (Join-Path $env:USERPROFILE 'repos\.env')
        outputBase      = (Join-Path $env:USERPROFILE 'Downloads')
    }
    $cfg = [ordered]@{}
    foreach ($k in $defaults.Keys) { $cfg[$k] = $defaults[$k] }

    if (Test-Path $ConfigPath) {
        $local = Get-Content $ConfigPath -Raw | ConvertFrom-Json
        foreach ($k in @($defaults.Keys)) {
            $v = $local.$k
            if ($v) { $cfg[$k] = [Environment]::ExpandEnvironmentVariables([string]$v) }
        }
    } else {
        Write-Warning "config.local.json not found at $ConfigPath; using defaults (repos: $($defaults.repoExternalApi) / $($defaults.repoServices), env: $($defaults.envFile), output: $($defaults.outputBase))."
    }
    return [pscustomobject]$cfg
}
