# Scheduled PR Review (read-only → HTML)

Runs a **full semantic code review** of open PRs in `nelnet-nbs/sis-externalapi` **six times a
day on weekdays** (08:00, 10:00, 12:00, 14:00, 16:00, 18:00 local time) and writes a
self-contained HTML report per PR to `C:\Users\lbautist\Downloads\PR Review\`.

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
gh api user -q .login                            # should print: mikko-bautista-113580
gh pr list --repo nelnet-nbs/sis-externalapi --limit 1   # must succeed (proves SSO ok)
```

If the last command errors about SSO, open the URL it prints (or GitHub → Settings → your
token → "Configure SSO" → Authorize for `nelnet-nbs`). Creds persist in the OS keychain and
the scheduled task (InteractiveToken, same user) reuses them.

### 2. Register the scheduled task

Registering at the root task folder needs elevation. In an **Administrator** PowerShell 7:

```powershell
pwsh -File "C:\neldevsrc\Github\TaskScheduler\gw-pr-review\register-pr-review-task.ps1" -RunNow
```

`-RunNow` registers it and fires one run immediately so you can watch it. Tail the log:

```powershell
$d = "C:\neldevsrc\Github\TaskScheduler\gw-pr-review\logs\GW-PRReview"
Get-ChildItem $d | Sort LastWriteTime -Desc | Select -First 1 | %{ Get-Content -Wait $_.FullName }
```

Reports land in `C:\Users\lbautist\Downloads\PR Review\` as `PR-<number>-<slug>.html` (one per PR).

## What gets reviewed

A PR is reviewed only if:

- it is **not a draft**, and
- it is **authored by or assigned to** `junie-perez-110467` or `paul-gatchalian-110466`, and
- it was **updated in the last 7 days**, and
- you (`mikko-bautista-113580`) have **not already approved** it, and
- it hasn't been **reviewed yet** — no `PR-<number>-*.html` exists for it (**1 PR = 1 HTML**).

One report per PR: a PR is reviewed once and is **not** re-reviewed on later commits. The wrapper
also **skips launching Claude entirely** when every eligible open PR already has a report, so an
idle run costs nothing. To force a fresh review, delete that PR's HTML from the output folder.

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
- **Model** — default is `opus` (best for semantic review). For cheaper/faster runs register with
  `-Model sonnet`, or edit the `$Model` default in `run-pr-review.ps1`.
- **Authors, approval owner, 7-day window** — edit Step 1 of `pr-review-prompt.md`.
- **Rules / severities** — edit `pr-review-standards.md`.
- **Report look** — edit `pr-review-template.html` (CSS + render JS).

## Manual run (no scheduler)

```powershell
pwsh -File "C:\neldevsrc\Github\TaskScheduler\gw-pr-review\run-pr-review.ps1" -TaskName manual
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
- Read-only on the working tree — the wrapper records branch+HEAD before/after and warns if
  anything changed; the only writes are the HTML reports (+ throwaway temp JSON).
- No PR comments are ever posted by the task (the `claude_self_reviewed` rule in `.claude/CLAUDE.md`
  is for endpoint delivery, not this review).
