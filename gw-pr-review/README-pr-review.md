# Scheduled PR Review (read-only → HTML)

Runs a **full semantic code review** of open PRs in `nelnet-nbs/sis-externalapi` **six times a
day on weekdays** (08:00, 10:00, 12:00, 14:00, 16:00, 18:00 local time) and writes a
self-contained HTML report per PR to `%USERPROFILE%\Downloads\PR Review\`.

**Runs as whoever checked it out.** The reviewer is auto-detected via `gh api user -q .login`,
and the PRs reviewed are **your teammates' — the team roster minus you**. So Paul's machine reviews
Mikko + Junie, Junie's reviews Paul + Mikko, and so on. See [Configuration](#configuration) below.

The review is done by Claude reading the **whole changed files** against
`pr-review-standards.md` + `generate-get-endpoint.md`, instead of regex checks on the diff.

**The scheduled task never touches the PRs or your git working tree.** No comments, no approvals,
no branch switches, no commits. The only thing it writes is the HTML reports. In the report, each
finding has a **"Comment on PR"** button (posts an inline comment to that code line via the GitHub
API when *you* click it) and a **"Copy comment"** button (clipboard only).

## Files

| File | Purpose |
|------|---------|
| `pr-review-prompt.md`         | The review instructions Claude follows (the engine). |
| `pr-review-standards.md`      | Coding-standards rulebook. REQUIRED=error, RECOMMENDED=warning, NICE-TO-HAVE=info. |
| `pr-review-template.html`     | JSON-driven HTML report shell. Claude injects findings JSON at the `__PR_REVIEW_DATA__` sentinel. |
| `run-pr-review.ps1`           | Wrapper: checks `gh` auth, fetches origin (read-only), runs headless `claude`, logs, verifies nothing changed. |
| `register-pr-review-task.ps1` | Creates/removes the Windows scheduled task (6 weekday triggers). |
| `logs/GW-PRReview/`           | Per-run logs. Grep `===` for the at-a-glance milestone view. |

## One-time setup

### 1. Authenticate the GitHub CLI (required)

The task runs headless, so `gh` must already be logged in and SSO-authorized for `nelnet-nbs`.
Do this once in a normal terminal:

```powershell
gh auth login          # GitHub.com  ->  HTTPS  ->  Login with a web browser
```

Then authorize the resulting token for the org's SAML SSO (nelnet-nbs uses SSO):

```powershell
gh auth status                                   # confirm you're logged in
gh api user -q .login                            # prints YOUR login; must match your entry in team-roster.json
gh pr list --repo nelnet-nbs/sis-externalapi --limit 1   # must succeed (proves SSO ok)
```

If the last command errors about SSO, open the URL it prints (or GitHub → Settings → your
token → "Configure SSO" → Authorize for `nelnet-nbs`). Creds persist in the OS keychain and
the scheduled task (InteractiveToken, same user) reuses them.

### 2. Register the scheduled task

Registering at the root task folder needs elevation. In an **Administrator** PowerShell 7:

```powershell
pwsh -File "C:\neldevsrc\Github\ExternalAPITaskSchedulerPrompt\gw-pr-review\register-pr-review-task.ps1" -RunNow
```

`-RunNow` registers it and fires one run immediately so you can watch it. Tail the log:

```powershell
$d = "C:\neldevsrc\Github\ExternalAPITaskSchedulerPrompt\gw-pr-review\logs\GW-PRReview"
Get-ChildItem $d | Sort LastWriteTime -Desc | Select -First 1 | %{ Get-Content -Wait $_.FullName }
```

Reports land in `%USERPROFILE%\Downloads\PR Review\` as `PR-<number>-<slug>.html` (one per PR).

## What the review takes into account

Beyond the standards rulebook and the Phase 1b upstream-DTO check, each PR is read with three pieces of
context — ported from the interactive `/sis-pdlc-plugin:p3-review-pr` skill, which had them and this job
didn't:

| Input | Why | Where it shows |
|---|---|---|
| **Prior review activity** — existing comment threads, human and bot (CodeRabbit et al.) | Stops the report restating something already said. Reviewers are told not to re-raise; Phase 3 drops duplicates as a backstop. | *Prior review activity* panel; `PRIOR (PR #n)` in the log |
| **CI status** (`gh pr checks`) | A red build changes how much the findings are worth. Adds **one** consolidated `info` finding, never one per check. | `CI` badge in the report header; `CI (PR #n)` in the log |
| **Story alignment** (optional — needs `ADO_PAT`) | Asks the one thing a rulebook can't: *did this PR build what the ticket asked for?* Pairs naturally with Phase 1b — the ticket says what was *wanted*, the decompiled DTO says what can actually be *populated*. | *Story alignment* panel; `STORY-ALIGN` in the log |

**Story alignment is informational and never blocking.** It emits at most `info` findings and cannot change
the recommendation banner — implementation legitimately diverges from a ticket during refinement. If
`ADO_PAT` is absent the phase is skipped with a logged reason and everything else runs normally; **ADO
credentials are optional and this job worked without them before.**

False positives also get a second defence: for structural findings ("missing attribute", "wrong pattern"),
the orchestrator now inlines **2–3 sibling files of the same kind** from `origin/main` into the verifier's
brief (falling back to the canonical `StudentsHomeroom` feature for a brand-new folder). If the PR matches
what the codebase already does, that's established local convention and the finding is rejected with the
sibling file as evidence. The hand-maintained false-positive list is **unchanged** — the evidence check is
additive. (Unused `using` directives remain a never-report: no sibling file can settle that, it needs a
compiler.)

Those siblings are also picked with an eye on **recency**. Before scanning a folder, the orchestrator
asks GitHub for the PRs the roster — Paul, Junie **and you** — merged into `sis-externalapi` in the last
90 days, keeps the two closest to the PR's `Features/` area, and prefers *their* files as the sibling
sample. A sibling sourced that way is tagged `(from #<n>, merged by <author> <date>)` and the verifier is
told to weigh a tagged sibling above an untagged one: it is code this team reviewed and merged recently,
not just old code sitting nearby. The lookup is capped (4 `gh` read calls, 6 extra files), fully
read-only, and non-fatal — if it finds nothing it logs `REFPR (PR #n): none in last 90d` and the plain
`origin/main` scan carries the review. This is the **only** place merged PRs are consulted at all;
what gets *reviewed* is still open PRs only.

## What gets reviewed

A PR is reviewed only if:

- it is **not a draft**, and
- it is **authored by or assigned to one of your teammates** (the team roster minus you — see
  [Configuration](#configuration)), and
- it was **updated in the last 7 days**, and
- **you have not already approved** it (your `gh` login is auto-detected), and
- it hasn't been **reviewed yet** — no `PR-<number>-*.html` exists for it (**1 PR = 1 HTML**).

One report per PR: a PR is reviewed once and is **not** re-reviewed on later commits. The wrapper
also **skips launching Claude entirely** when every eligible open PR already has a report, so an
idle run costs nothing. To force a fresh review, delete that PR's HTML from the output folder.

## Configuration

Identity and paths are **auto-detected per user** — nobody edits the scripts. Two files at the
automation root (`ExternalAPITaskSchedulerPrompt\`) drive the sibling projects:

| File | Committed? | Purpose |
|------|-----------|---------|
| `team-roster.json`          | yes | The team: one `{ "name", "github" }` per dev. **Add a teammate = one line here.** The reviewer's own login (from `gh api user -q .login`) is subtracted to get the review list. |
| `config.local.json`         | no (git-ignored) | Per-machine paths (`repoExternalApi`, `repoServices`, `envFile`, `outputBase`). Copy `config.local.example.json` → `config.local.json` and edit **only if your checkout differs** from the defaults; otherwise paths resolve under your `%USERPROFILE%`. |
| `lib/team.ps1`              | yes | Shared PowerShell helpers (`Get-ReviewAuthors`, `Resolve-LocalConfig`, …) dot-sourced by every wrapper. |

The wrapper computes `reviewAuthors = roster − you` and injects the resolved logins/paths into the
prompt (the `{{REVIEW_AUTHORS}}` / `{{CURRENT_USER}}` / `{{OUTPUT_DIR}}` placeholders) before launch.

### Optional: enable the story-alignment check

Entirely opt-in. Add to `%USERPROFILE%\repos\.env` (the same file the other jobs use — if you already run
`admission-ms`, it's already there and nothing more is needed):

```
ADO_PAT=<PAT with Work Items: Read>
ADO_ORG=renweb
ADO_PROJECT=ColdFusion
```

`Work Items: Read` is all it needs — the check is strictly read-only. Without these the wrapper logs
`WARN: no ADO_PAT … story-alignment check will be skipped (review is unaffected)` and the review runs
exactly as it did before.

## Reading a report

- **Recommendation banner** (approve / approve-with-comments / request-changes / reject) uses
  these thresholds: any error → reject; >3 warnings → request changes; ≥1 warning →
  comments; otherwise approve.
- **✅ Approve this PR** (under the recommendation banner) submits an **approving review** to the
  PR on GitHub, with an optional approval comment — so reviewing the diff yourself is optional. Uses
  the same browser-stored token as the comment button. (GitHub won't let you approve your own PR.)
- Findings are grouped by category and sorted error → warning → info.
- **💬 Comment on PR** posts that finding straight to GitHub as an **inline comment on the exact
  code line** (falls back to a general PR comment when a finding has no line). It uses the GitHub
  REST API directly from the browser — no n8n, no server. The first click asks once for a GitHub
  token (fine-grained PAT with *Pull requests: Read and write* on the repo, or a classic `repo`
  token); the token is kept only in your browser's `localStorage`, never written into the report
  file. *You* click, so nothing is posted without your action.
- **📋 Copy comment** copies a ready-to-paste markdown comment (file:line + issue + suggestion +
  code) to your clipboard. Nothing is sent anywhere — useful if a CORS policy blocks the direct post.
- **✕ Dismiss** hides a finding you disagree with (remembered per PR+SHA in the browser).

## Tuning

Everything below is edit-a-file; no rebuild.

- **Times / days** — re-run `register-pr-review-task.ps1` with `-Times '09:00','13:00',...`.
- **Model** — pinned to `claude-opus-5` (best for semantic review). For cheaper/faster runs register
  with `-Model sonnet`, or edit the `$Model` default in `run-pr-review.ps1`.
- **Authors, approval owner, 7-day window** — edit Step 1 of `pr-review-prompt.md`.
- **Rules / severities** — edit `pr-review-standards.md`.
- **Report look** — edit `pr-review-template.html` (CSS + render JS).

## Manual run (no scheduler)

```powershell
pwsh -File "C:\neldevsrc\Github\ExternalAPITaskSchedulerPrompt\gw-pr-review\run-pr-review.ps1" -TaskName manual
# or a specific model:
pwsh -File "...\run-pr-review.ps1" -TaskName manual -Model sonnet
```

## Troubleshooting

| Symptom | Fix |
|---------|-----|
| Log says `gh CLI not authenticated` | Redo step 1; confirm `gh pr list --repo nelnet-nbs/sis-externalapi` works. |
| `SSO`/`403` errors from `gh` | Authorize your token for the `nelnet-nbs` org (step 1). |
| Task never fires | It's InteractiveToken — you must be logged on. Suspend/sleep pauses timers. Check `Get-ScheduledTask -TaskName GW-PRReview | Get-ScheduledTaskInfo`. |
| Nothing reviewed | Likely all eligible PRs already have a report (1 PR = 1 HTML), or none match the filter — see the log's final summary. |
| Runs overlap | Can't: task uses `IgnoreNew` and the wrapper holds a 90-min lock (`.pr-review.lock`). |

## Remove

```powershell
pwsh -File "...\register-pr-review-task.ps1" -Unregister
```

## Guarantees

- Read-only on GitHub (only `gh` read subcommands / `gh api` GET).
- Read-only on ADO — the story-alignment check only *reads* a work item. No field edits, no comments, no
  state changes, no new work items.
- Read-only on the working tree — the wrapper records branch+HEAD before/after and warns if
  anything changed; the only writes are the HTML reports (+ throwaway temp JSON).
- No PR comments are ever posted by the task (the `claude_self_reviewed` rule in `.claude/CLAUDE.md`
  is for endpoint delivery, not this review).

## Post-run process review

After each run finishes, the wrapper calls the shared `Invoke-LogReview` (`..\lib\log-review.ps1`),
which runs a second headless `claude` (`claude-opus-5`) on `..\lib\log-review-prompt.md` to review **this run's
log** for process improvements (timeouts, path mismatches, wasted cycles, `WARN`/`FATAL` lines, prompt
issues). It writes a report next to the log (`logs\<TaskName>\<TaskName>_<timestamp>.review.md`) and,
when the automation tree is clean, applies **validated, uncommitted** fixes to this repo's own files
for you to review with `git diff` and commit. It never commits/pushes, never edits the target repo,
degrades to report-only if edits are already pending, and reverts any edited `.ps1` that fails to
parse. See the repo-root `README.md` → "Post-run process review".
