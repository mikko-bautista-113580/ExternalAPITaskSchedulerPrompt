# ExternalAPI Task Scheduler Prompts

A collection of **headless Claude Code automations** run as Windows scheduled tasks against the
SIS External API codebases. Each subfolder is a self-contained job: a PowerShell wrapper that
launches `claude` headless on a prompt, a Markdown prompt (the "engine"), a register script that
creates/removes the Windows scheduled task, and per-run logs.

The four jobs fall into two families:

- **Endpoint generators** — read the Active sprint in Azure DevOps and write a working endpoint to
  a local `story/<id>` branch, left **uncommitted** for you to review and commit. They never
  commit, push, open a PR, or write back to ADO.
- **PR reviewers** — run a full semantic code review of open PRs and write a self-contained HTML
  report per PR. They are **strictly read-only** on GitHub and on your working tree; nothing is
  posted unless *you* click a button in the report. They review **your teammates' PRs — the team
  roster minus you** (see [Configuration](#configuration)).

All four jobs **auto-detect whoever runs them** — no per-user edits. Endpoint generators build for
your own ADO stories (`@Me`); PR reviewers detect your GitHub login (`gh api user -q .login`) and
review everyone else on the team. So Paul's checkout reviews Mikko + Junie, Junie's reviews Paul +
Mikko, and so on.

## Jobs

| Folder | Task | Type | Target repo | Output |
|---|---|---|---|---|
| [externalapi-gw/](externalapi-gw/) | `GW-MorningAutoPR-0700` | Endpoint generator (writes local branch) | `sis-externalapi` | Uncommitted `story/<id>` branch |
| [admission-ms/](admission-ms/) | `AdmissionMS-EndpointGen` | Endpoint generator (writes local branch) | `sis-services` (Admissions) | Uncommitted `story/<id>` branch |
| [gw-pr-review/](gw-pr-review/) | `GW-PRReview` | PR review (read-only → HTML) | `sis-externalapi` | `Downloads\PR Review\` |
| [ms-pr-review/](ms-pr-review/) | `MS-PRReview` | PR review (read-only → HTML) | `sis-services` | `Downloads\PR Review MS\` |

Each folder has its own README with full setup, tuning, and troubleshooting:

- [externalapi-gw/README-externalapi-gw.md](externalapi-gw/README-externalapi-gw.md)
- [admission-ms/README-admission-ms.md](admission-ms/README-admission-ms.md)
- [gw-pr-review/README-pr-review.md](gw-pr-review/README-pr-review.md)
- [ms-pr-review/README-ms-pr-review.md](ms-pr-review/README-ms-pr-review.md)

## Anatomy of a job

Every folder follows the same shape:

| File | Purpose |
|---|---|
| `run-*.ps1` | Wrapper: preflight (auth / clean tree), launches `claude` headless on the prompt, streams events to a timestamped log, verifies invariants. |
| `*-prompt.md` | The instructions Claude follows — the actual engine of the job. |
| `register-*-task.ps1` | Creates/removes the Windows scheduled task and its triggers. |
| `logs/<TaskName>/` | Per-run logs (last 30 kept). Grep `===` for the milestone view. Also holds the post-run `*.review.md` process reports (see below). |
| `*-standards.md`, `*-template.html` | (PR reviewers) the coding-standards rulebook and the JSON-driven HTML report shell. |

## Prerequisites

- **Claude CLI** installed at `%APPDATA%\npm\claude.cmd`.
- **PowerShell 7** (`pwsh`).
- **GitHub CLI** (`gh`) logged in and SSO-authorized for `nelnet-nbs` — required by the PR
  reviewers and by the endpoint generators' reference-PR lookup.
- **ADO credentials** in `%USERPROFILE%\repos\.env` (`ADO_PAT`, `ADO_ORG`, `ADO_PROJECT`) — required
  by the endpoint generators. Read scope only. (Override the location via `config.local.json` → `envFile`.)

See each job's README for the exact one-time setup.

## Configuration

Identity and paths are resolved at runtime, so a teammate just clones and registers — no script
edits. Three shared files at this repo root drive all four jobs:

| File | Committed? | Purpose |
|---|---|---|
| `team-roster.json` | yes | The team: one `{ "name", "github" }` per dev. **Add/remove a teammate = one line.** PR reviewers subtract the current user's `gh` login to get the review list; endpoint generators use it for the reference-PR authors. |
| `config.local.json` | **no** (git-ignored) | Per-machine paths (`repoExternalApi`, `repoServices`, `envFile`, `outputBase`). Copy `config.local.example.json` → `config.local.json` and edit **only if your checkout differs** from the defaults; `%USERPROFILE%` is expanded. Absent → USERPROFILE-based defaults (logged). |
| `lib/team.ps1` | yes | Shared PowerShell helpers (`Get-ReviewAuthors`, `Resolve-LocalConfig`, `Get-CurrentGitHubLogin`) dot-sourced by every wrapper. |

The wrappers inject the resolved identity/paths into each prompt via placeholders
(`{{CURRENT_USER}}`, `{{REVIEW_AUTHORS}}`, `{{REPO_ROOT}}`, `{{OUTPUT_DIR}}`, `{{ENV_FILE}}`, …).

## Common commands

Registering at the root task folder needs an **Administrator** PowerShell. Substitute the job's
`register-*.ps1` path:

```powershell
# register the task (and optionally fire one run immediately)
pwsh -File .\<job>\register-<job>-task.ps1
pwsh -File .\<job>\register-<job>-task.ps1 -RunNow

# run once manually, no scheduler (verbose log under logs\manual\)
pwsh -File .\<job>\run-<job>.ps1 -TaskName manual

# cheaper/faster model
pwsh -File .\<job>\run-<job>.ps1 -TaskName manual -Model sonnet

# remove the task
pwsh -File .\<job>\register-<job>-task.ps1 -Unregister
```

Wrappers default to the `opus` model (best for semantic work); pass `-Model sonnet` for
cheaper/faster runs.

## Post-run process review

Every job ends by reviewing **its own run**. After the wrapper writes `=== … run finished …`,
it calls the shared `Invoke-LogReview` (`lib/log-review.ps1`), which launches a second headless
`claude` (opus) on `lib/log-review-prompt.md`. That reviewer reads the run's log, finds where the
**automation process** (wrappers / prompts / standards) can be improved — timeouts, Windows/Unix
path mismatches, wasted rebuild cycles, `WARN`/`FATAL` lines, etc. — **validates** each fix against
the current source, and writes a markdown report next to the log
(`logs/<TaskName>/<TaskName>_<timestamp>.review.md`, git-ignored, last 30 kept).

- **It never commits.** Validated fixes are applied as **uncommitted** edits to this repo's own
  files (`*.ps1`, `*-prompt.md`, `*-standards.md`, `*-template.html`); you review `git diff` and
  commit. It never runs `git add`/`commit`/`push` and never touches the target repos.
- **It never stacks unreviewed edits.** If the automation tree already has pending changes, the
  reviewer degrades to **report-only** (recommends, changes nothing) so edits can't compound
  across back-to-back scheduled runs.
- **Validity is enforced twice:** the reviewer parse-checks any `.ps1` it edits, and the wrapper
  parse-gates the result — a changed script that doesn't parse is automatically reverted, so a
  broken script can never reach the next run.
- **Clean no-op runs are skipped** (no claude launched, exit 0, no warnings) to avoid cost.
- **New shared files:** `lib/log-review.ps1` (the `Invoke-LogReview` function) and
  `lib/log-review-prompt.md` (the reviewer engine) — dot-sourced by every wrapper, no per-job code.

## Safety guarantees

- **Endpoint generators are local-only:** create a local branch, write code, `dotnet build`.
  They never commit, push, open a PR, or mutate ADO, and they abort on a dirty working tree so
  un-reviewed work is never clobbered.
- **PR reviewers are read-only:** only `gh` read subcommands / GET, no working-tree writes beyond
  the HTML reports. Findings are posted to GitHub only when you click a button in the report.

> **Note on paths:** the wrappers resolve the scheduler folder from their own location
> (`$PSScriptRoot`) and target-repo / output / `.env` paths from `config.local.json` (see
> [Configuration](#configuration)), so a checkout works from wherever you clone it. Any absolute
> path still shown in a per-job README is illustrative — the defaults resolve under your
> `%USERPROFILE%` unless you override them.
