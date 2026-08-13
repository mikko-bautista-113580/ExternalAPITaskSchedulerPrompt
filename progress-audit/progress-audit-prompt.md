> **Dates and paths are injected by the wrapper.** `{{TODAY}}`, `{{ISO_WEEK}}`, `{{CHECKPOINT_LABEL}}`, `{{EXPECTED_TABLE}}`, `{{TRIGGER_NOTES}}`, `{{ARTIFACT_URL}}`, `{{ARTIFACT_HTML}}`, `{{POINTS_PER_PHASE}}`, `{{ROADMAPS_FILE}}`, `{{RESULT_FILE}}`, `{{OUTPUT_DIR}}`, `{{SCHEDULED_DIR}}`, `{{REPO_ROOT}}`, `{{DRAFT_ONLY}}`. If you ever see a literal `{{...}}` still in this text (a hand-run), stop and report it — do **not** guess a date. The expected-phase table is computed in PowerShell from `roadmaps.json`; **treat it as ground truth and never recompute it yourself.**

You are running as a scheduled task. Your job is to **audit the AI progress artifact against each team's published AI roadmap as of {{TODAY}}**, rescore each team, and update the page — but only when nothing has regressed.

The question you are answering for each team is exactly this: *by today's date, where does their roadmap say they should be, where are they actually, and is that on track?*

## Hard prohibitions (the run FAILS if you do any of these)

- ❌ NO `git add` / `commit` / `push` / `checkout` / `switch` / `stash` / `reset` / `restore` / `clean`. The working tree must be byte-for-byte unchanged when you exit.
- ❌ NO edits to any file in `{{REPO_ROOT}}` — including `roadmaps.json`. You **read** the repo; you never write to it.
- ❌ NO writing anywhere except `{{OUTPUT_DIR}}\`, `{{RESULT_FILE}}`, and the system temp folder.
- ❌ NO ADO or GitHub **writes** of any kind. No comments, no work items, no PRs.
- ❌ NO publishing when the gate below says hold. `{{DRAFT_ONLY}}` set to anything but `no` means **never publish this run**, whatever the gate says.
- ❌ NO inventing evidence. If you cannot verify something, the team does not get credit for it — say so in the report.

## Draft-only flag

`Draft only this run: {{DRAFT_ONLY}}`

## Step 1 — Read the current page

Read the page by the first route that works, in this order:

1. **Local snapshot** — `Local artifact snapshot: {{ARTIFACT_HTML}}`. If that is a real path (not `(none ...)`), `Read` it. This is the reliable route: the artifact is auth-gated and client-rendered, so a plain HTTP fetch never sees the rendered page.
2. **Artifact tool** — if an Artifact tool is available in this session, use its read/list capability on `{{ARTIFACT_URL}}`. Log whether the tool exists either way; that answers the repo's open question about headless availability.
3. **`WebFetch {{ARTIFACT_URL}}`** — last resort.

Extract, per lead: current score, the three checkpoint labels and their per-checkpoint values, the roadmap meter percentages, and the status of each phase. This is your `scoreBefore` for every team.

**Retry policy.** Retry twice only when the failure looks *transient* — a timeout, a 5xx, a dropped connection. A fetch that **succeeds but returns an empty body** (only the `Claude Artifact` header and the "user-generated and unverified" disclaimer) is deterministic auth-gating: retrying is pure cost, so fail over to the next route immediately and do not retry it.

If no route yields the page, write `{{RESULT_FILE}}` with `"published": false` and `"holdReason": "could not read the current artifact"`, log `HOLD: artifact unreadable`, name in the report which routes were tried, and exit 0. **Never** publish a page you could not read first.

## Step 2 — Expected position (given to you, do not recompute)

Computed in PowerShell from `{{ROADMAPS_FILE}}` for {{TODAY}} — ISO week {{ISO_WEEK}}, checkpoint label `{{CHECKPOINT_LABEL}}`:

| Team | Lead | Expected phase | Name | Window | Points/phase | Timing |
|---|---|---|---|---|---|---|
{{EXPECTED_TABLE}}

A row flagged `ANCHOR UNCONFIRMED` means the team states relative weeks and the anchor date is a guess. Say so in the report for that team and **do not mark them Behind on anchor evidence alone** — a wrong anchor, not the team, may be the problem.

## Step 3 — Actual position (evidence)

Read `{{ROADMAPS_FILE}}` for each team's phase `exit` criteria. For each team, work out the highest phase whose exit criteria are **fully met**, plus how far into the next one they are. Evidence, in order of weight:

1. **`{{TRIGGER_NOTES}}`** — details supplied at trigger time. This is the user reporting; treat anything it states as authoritative and let it override weaker evidence. If it says a criterion is met, it is met.

   > Notes for this run: {{TRIGGER_NOTES}}

2. **Committed skills in this repo.** For each team with a non-null `skillsPath`, count `SKILL.md` files under `{{REPO_ROOT}}\<skillsPath>` (use Glob, read none of them). A skill committed to the repo is evidence for "consolidated into a shared library" and "each member has ≥1 merged team skill"; a skill that exists only on someone's machine is not. Teams with `skillsPath: null` skip this evidence — do not substitute a guess.
3. **The page's own narrative cells** — what the leads reported at the last checkpoint, from Step 1.

Anything a phase's exit criteria require that you find **no** evidence for is unmet. Unmet criteria in a phase whose window has already closed go into `overdueExitCriteria`.

## Step 4 — Score and status

**Score** = that team's **Points/phase** (from the table above) × (fully completed phases) + part-credit for the phase in progress, rounded to the nearest 5 so the arithmetic stays legible. A team with no roadmap is not scored — it gets `null` and the page keeps its em dash.

> **Points/phase is per team, not global.** Roadmaps have different lengths — five phases for IMPACT, QUICKPAY and benefitED, two for FAM — so each team's points are an even split of 100 across *their own* phases. Every score therefore means "percent of your own plan completed". It does **not** mean two teams at the same number are at the same maturity, and the page must not imply that. Never apply one team's points-per-phase to another.

**Status**, one of:

| Status | When |
|---|---|
| `Ahead` | Actual phase is higher than expected. |
| `On track` | Actual phase equals expected, window still open, no overdue criteria. |
| `At risk` | Actual phase equals expected, but less than a quarter of the window remains with exit criteria still unmet. |
| `Behind` | Actual phase is lower than expected, **or** the window has closed with unmet criteria. |
| `No roadmap` | No phases on record. |

Emit one line per team, exactly this shape, so the wrapper can log it:

```
STATUS: <On track|At risk|Behind|Ahead|No-roadmap> <Team> — phase <actual> vs expected <expected>, <score>%
```

## Step 5 — Write the result file FIRST

Before touching the artifact, write `{{RESULT_FILE}}`:

```json
{
  "generatedAt": "{{TODAY}}",
  "isoWeek": "{{ISO_WEEK}}",
  "checkpoint": "{{CHECKPOINT_LABEL}}",
  "published": false,
  "holdReason": "",
  "teams": [
    { "team": "IMPACT", "lead": "Leo", "status": "On track",
      "scoreBefore": 25, "scoreAfter": 30,
      "expectedPhase": 2, "actualPhase": 2,
      "overdueExitCriteria": [],
      "derivation": "one sentence of arithmetic",
      "evidence": ["what moved it, and from where"] }
  ]
}
```

Set `"published": true` **only after** a publish actually succeeds, then rewrite the file.

## Step 6 — The publish gate

Compute: **clean** = no team has `scoreAfter < scoreBefore` **and** no team has a non-empty `overdueExitCriteria`.

- **Clean, and `{{DRAFT_ONLY}}` is `no`** → update the artifact (Step 7), then rewrite `{{RESULT_FILE}}` with `"published": true`.
- **Otherwise** → publish nothing. Write the proposed page to `{{OUTPUT_DIR}}\ai-progress-{{TODAY}}.html` and log:

  ```
  HOLD: <the regression or overdue criteria, named>
  ```

  A hold is a normal outcome, not a failure — exit 0. Bad news gets a human read before it goes on the page; that is the whole point of the gate.

## Step 7 — Update the page (only when the gate passes)

Fetch the current HTML, edit it, and republish with the Artifact tool passing `url: {{ARTIFACT_URL}}` so it updates in place and keeps its version history. Save a copy to `{{OUTPUT_DIR}}\ai-progress-{{TODAY}}.html` either way.

**You may change only these regions.** Everything else — the narrative cells, the roadmap sections, the takeaways, the CSS — is human-written and read-only unless the evidence directly contradicts it:

| Region | Selector | What changes |
|---|---|---|
| Score figure and delta | `.score-now`, `.score-delta` | New score; delta recomputed against the oldest checkpoint still shown. |
| Score trace | `.track .bar` (3 bars) | Rolling window — see below. |
| Status chip | `.score-basis` | Add the status: `On track · scored on the <TEAM> roadmap`. |
| Roadmap meter | `.rm-now`, `.rm-cap`, `.rm-seg` | Percentage, caption, and per-segment fill/tag for that team's roadmap section. |
| Derivation note | the `.scale-note` beginning `How the N% is derived` | Rewrite to this run's arithmetic. |
| Phase chips | `.phase-state`, `.rm-seg .rm-tag` | `Complete` / `Current state` / `Ahead`, plus `Overdue` when a window closed with unmet criteria. |
| Checkpoint columns | `.cell .stamp`, `.spine .tick` | Rolling window — see below. |
| Footer date range | `footer span` | Extend the end date to {{CHECKPOINT_LABEL}}. |

**Rolling three-checkpoint window.** The layout is built for exactly three checkpoint columns (`.lead` and `.spine` are `repeat(3, ...)` grids) and each score trace holds exactly three bars. Never add a fourth — it breaks the grid.

- **New ISO week** (no column labelled `{{CHECKPOINT_LABEL}}` exists): drop the oldest column, shift the other two left, and add `{{CHECKPOINT_LABEL}}` as the new rightmost column carrying `is-latest`. Do the same to the three bars in every `.track`. The dropped checkpoint survives in this run's audit report — that is the history of record.
- **Same ISO week** (a column already carries `{{CHECKPOINT_LABEL}}`): refresh that column in place. Shift nothing.

For a team whose narrative you have no new evidence for, carry the previous cell text forward unchanged rather than inventing an update. Write `Carried forward — no new evidence this run.` in the report instead.

## Step 8 — The audit report

Write `{{OUTPUT_DIR}}\ai-progress-audit-{{TODAY}}.md`:

- Header: trigger date, ISO week, checkpoint label, draft-only flag, published or held.
- The expected-vs-actual table from Steps 2–4, one row per team, with the status and the score arithmetic spelled out.
- What moved and why, per team, naming the evidence.
- Anything you could not verify, and what would settle it.
- Any checkpoint dropped from the rolling window this run, with its values, so the history is recoverable.
- Any `ANCHOR UNCONFIRMED` team, flagged for the lead to confirm.

## Final summary

End with:

```
Checkpoint: {{CHECKPOINT_LABEL}} ({{ISO_WEEK}})
Teams scored: N   Held: yes|no
Published: yes|no
Report: <path>
```
