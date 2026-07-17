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
  posted unless *you* click a button in the report.

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
| `logs/<TaskName>/` | Per-run logs (last 30 kept). Grep `===` for the milestone view. |
| `*-standards.md`, `*-template.html` | (PR reviewers) the coding-standards rulebook and the JSON-driven HTML report shell. |

## Prerequisites

- **Claude CLI** installed at `%APPDATA%\npm\claude.cmd`.
- **PowerShell 7** (`pwsh`).
- **GitHub CLI** (`gh`) logged in and SSO-authorized for `nelnet-nbs` — required by the PR
  reviewers and by the endpoint generators' reference-PR lookup.
- **ADO credentials** in `C:\Users\lbautist\repos\.env` (`ADO_PAT`, `ADO_ORG`, `ADO_PROJECT`) —
  required by the endpoint generators. Read scope only.

See each job's README for the exact one-time setup.

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

## Safety guarantees

- **Endpoint generators are local-only:** create a local branch, write code, `dotnet build`.
  They never commit, push, open a PR, or mutate ADO, and they abort on a dirty working tree so
  un-reviewed work is never clobbered.
- **PR reviewers are read-only:** only `gh` read subcommands / GET, no working-tree writes beyond
  the HTML reports. Findings are posted to GitHub only when you click a button in the report.

> **Note on paths:** the per-job READMEs reference an older location
> (`C:\neldevsrc\Github\TaskScheduler\...`). This repo now lives at
> `C:\neldevsrc\Github\ExternalAPITaskSchedulerPrompt\`; adjust paths accordingly when copying
> commands.
