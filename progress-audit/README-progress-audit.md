# progress-audit — AI progress artifact auditor

Scores each team against **their own published AI roadmap, as of the date the audit runs**, and
writes the result back to the shared progress page. A third job family alongside the endpoint
generators and PR reviewers: a **reporter**. It reads this repo and publishes outside it, and it
never touches a target repo at all.

| | |
|---|---|
| Task | `AIProgress-Audit` |
| Schedule | Monday 08:00 (local), weekly |
| Reads | `roadmaps.json`, `SKILL.md` counts under each team's `skillsPath`, the live artifact |
| Writes | The artifact (gated), `Downloads\AI Progress Audit\`, `logs\<TaskName>\` |
| Never | commits, pushes, edits this repo, or writes to ADO/GitHub |

## The idea

Every roadmap has dates. benefitED states them outright (Phase 2 = 10–28 Aug); IMPACT and QUICKPAY
state relative weeks. So *"where should this team be today?"* is arithmetic, and only *"where are
they actually?"* needs judgement. The job splits exactly along that line:

- **`run-progress-audit.ps1` computes** the expected phase per team, in PowerShell, from
  `roadmaps.json`. Deterministic, logged, reproducible. The model is handed the answer and told not
  to recompute it.
- **`progress-audit-prompt.md` judges** the actual position from evidence, scores it, and decides
  whether the result is safe to publish.

## One-time setup

1. **Claude CLI** at `%APPDATA%\npm\claude.cmd`, **PowerShell 7** (`pwsh`) — same prerequisites as
   the other jobs in this folder.
2. **Confirm the anchor dates** (see below). Do this before you trust any IMPACT or QUICKPAY number.
3. **Save an artifact snapshot** — without one the run cannot read the page and holds at Step 1. See
   [Reading the artifact](#reading-the-artifact). Publishing is manual either way — see
   [Publishing is manual](#publishing-is-manual--there-is-no-artifact-tool-headless).
4. Register the task from an **elevated** pwsh:

   ```powershell
   pwsh -File .\progress-audit\register-progress-audit-task.ps1
   ```

## Commands

```powershell
# dry run — compute and draft, publish nothing
pwsh -File .\progress-audit\run-progress-audit.ps1 -TaskName manual -DraftOnly

# real run
pwsh -File .\progress-audit\run-progress-audit.ps1 -TaskName manual

# point at a saved copy of the page (see "Reading the artifact" below)
pwsh -File .\progress-audit\run-progress-audit.ps1 -TaskName manual -DraftOnly `
    -ArtifactHtml .\progress-audit\artifact-snapshot.html

# supply details for this run (they outrank every other evidence source)
pwsh -File .\progress-audit\run-progress-audit.ps1 -TaskName manual `
    -Notes "Russell committed the 3 staged skills; Leo's team wrote the definition of done"

# cheaper model
pwsh -File .\progress-audit\run-progress-audit.ps1 -TaskName manual -Model sonnet

# register so every SCHEDULED run drafts and never publishes
pwsh -File .\progress-audit\register-progress-audit-task.ps1 -DraftOnly

# remove the task
pwsh -File .\progress-audit\register-progress-audit-task.ps1 -Unregister
```

## roadmaps.json — the file you actually maintain

Everything date-related lives here. **When a roadmap changes, edit this file — never the prompt or
the wrapper.** Two dialects are supported and detected automatically:

| Dialect | Fields | Used by |
|---|---|---|
| Explicit windows | `start`, `end` (`yyyy-MM-dd`) | benefitED |
| Anchor-relative | `anchorDate` + `weekStart`, `weekEnd` | IMPACT, QUICKPAY |

Each phase carries an `exit` array — the criteria that decide whether it counts as done. Those
strings are what the audit judges evidence against, so **write them as things you could check**, not
as aspirations. A team with `"phases": []` (FAM today) is reported as `No roadmap` and left unscored;
add a phases array and scoring starts on the next run with no other change.

### ⚠ Anchor dates need confirming

IMPACT and QUICKPAY state relative weeks, so week 1 needs a real date. Both are currently
`"anchorDate": "2026-07-21"` with `"anchorConfirmed": false` — **a default taken from the page's
first checkpoint, not from the teams.** A wrong anchor shifts every expected-phase calculation for
that team.

Ask Leo and Luis when their week 1 began, set the date, and flip `anchorConfirmed` to `true`. Until
then the audit flags those rows and is instructed not to mark them `Behind` on anchor evidence alone.

### skillsPath

`.claude/BenefitEd` and `.claude/Impact` are known. QUICKPAY and FAM are `null` — no folder for them
was found in this repo — so those teams simply skip the committed-skill evidence. Fill the paths in
when you know them; do not guess, because a wrong path reads as "no skills committed" and drags a
score down.

Each path is resolved against the **skills root** and the wrapper now logs the resolution up front:

```
Skills:   IMPACT -> C:\...\ai-resources\.claude\Impact (15 SKILL.md)
WARN: QUICKPAY skillsPath '...' does not exist under ... -- committed-skill evidence will count ZERO
```

Read those lines on every run. A root that resolves nowhere is otherwise **invisible** — `Glob`
simply returns nothing, so the team reads as "no skills committed" and its score drops for a reason
that has nothing to do with the team. (This is not hypothetical: the root was previously derived two
levels up instead of three, so every `skillsPath` resolved to `.claude\.claude\<team>` and every
team's skill evidence counted zero.)

The root is derived from this folder's own location (three levels up) — correct whenever this
automation is checked out **inside** the skills repo. If you run it from a **standalone** checkout the
skills are not above it, so point at them explicitly in `config.local.json`:

```json
{ "skillsRoot": "c:\\neldevsrc\\Github\\ai-resources" }
```

## Reading the artifact

**`WebFetch` cannot read the artifact.** Confirmed on the 2026-08-10 run: all three attempts came
back with only the `Claude Artifact` header and the "user-generated and unverified" disclaimer. The
page is auth-gated and client-rendered, so an unauthenticated HTTP fetch never sees the rendered
body — and with no `scoreBefore`, every team goes unscored and the run holds.

Save the page once and the job reads it locally:

1. Open the artifact, **Save as → Webpage, HTML only**.
2. Save it as `progress-audit\artifact-snapshot.html` (the default the wrapper looks for), or pass
   any path with `-ArtifactHtml`.

Refresh the snapshot before each real run — a stale one gives stale `scoreBefore` values. The
wrapper logs `Snapshot: <path>` when it finds one and a `WARN:` when it doesn't.

## The publish gate

**Publishes only if nothing regresses.** The prompt writes `audit-result.json` before touching the
artifact; the run may publish only when no `scoreAfter < scoreBefore` and no team has a non-empty
`overdueExitCriteria`. Otherwise it writes the proposed HTML plus a report, logs `HOLD: <reason>`,
and exits 0. A hold is a normal outcome.

The wrapper re-reads that JSON afterwards and logs `MISMATCH` if a publish happened on a dirty
result — the same both-sides enforcement the shared log reviewer uses for its parse gate. If you see
`MISMATCH`, roll back from the artifact's version picker.

## Rolling three-checkpoint window

The page's `.lead` and `.spine` grids are `repeat(3, …)` and every score trace holds three bars, so
the audit maintains **exactly three** checkpoint columns:

- **New ISO week** → drop the oldest, shift left, add today's as the rightmost.
- **Same ISO week** → refresh today's column in place.

**Dropped checkpoints survive only in the audit reports.** Keep `Downloads\AI Progress Audit\` if you
want the long history; logs here rotate at 30 runs.

## Output

The wrapper lists every `.html` and `.md` file written under `Downloads\AI Progress Audit\` during the
run, so the log always names what came out of it — on a Step 1 hold that is the report alone.

| Path | What |
|---|---|
| `logs\<TaskName>\<TaskName>_<ts>.log` | Full run log. Grep `===` for milestones, `RESULT` for the per-team scores. |
| `logs\<TaskName>\<TaskName>_<ts>.audit-result.json` | The gate's evidence: before/after scores, status, overdue criteria per team. |
| `logs\<TaskName>\<TaskName>_<ts>.review.md` | Post-run process review (shared `Invoke-LogReview`). |
| `Downloads\AI Progress Audit\ai-progress-<date>.html` | The proposed page, published or not. Skipped when Step 1 could not read the current page — there is nothing to base an edit on. |
| `Downloads\AI Progress Audit\ai-progress-audit-<date>.md` | The report: expected vs actual, what moved, what couldn't be verified. |

## Publishing is manual — there is no Artifact tool headless

**Settled on the 2026-08-13 run.** The wrapper launches `claude --print
--dangerously-skip-permissions`, and in that mode **no Artifact tool is exposed** — the run probed
the tool registry both by keyword and by explicit `select:Artifact` and got nothing back. So Step 7's
publish path cannot execute in this harness at all, even on a clean gate with the draft flag off.

The job still earns its keep — it computes, drafts and reports — but **publishing is a human step**:
open the drafted HTML from `Downloads\AI Progress Audit\` in an interactive session and publish it
with `url:` pointing at the existing artifact. The prompt now holds with
`HOLD: no Artifact tool in this session` instead of pretending it published.

## Troubleshooting

| Symptom | Cause / fix |
|---|---|
| `FATAL: roadmaps.json is not valid JSON` | Trailing comma or a stray comment — the file is strict JSON; `_comment` keys are the way to annotate. |
| `HOLD: artifact unreadable` | No read route worked. Expected when there is no snapshot — see [Reading the artifact](#reading-the-artifact) and save one. The whole run is then near-worthless: only teams scoreable from repo data alone get a number, so refresh the snapshot rather than letting it recur. |
| `HOLD: no Artifact tool in this session` | Working as designed — headless cannot publish. Publish the drafted HTML by hand. |
| `WARN: only N of M teams were scored` | Usually `HOLD: artifact unreadable` upstream — `clean=True` on that run says nothing about the unscored teams. |
| `No audit-result.json written` | The run died before Step 5. The artifact was not touched — check the log's last `[claude]` lines. |
| Every team reads `Behind` | Almost always a wrong `anchorDate`, or a `skillsPath` pointing at nothing. Check the expected-position block at the top of the log. |
| A team's score fell and the run held | Working as designed. Read the report, decide whether the drop is real, and re-run with `-Notes` if evidence was missed. |
| `MISMATCH` in the log | The prompt published on a dirty result. Roll back from the artifact version picker and open an issue against the prompt. |
