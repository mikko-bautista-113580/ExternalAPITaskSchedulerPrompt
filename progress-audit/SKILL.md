---
name: progress-audit
description: Audit the AI progress artifact against each team's published AI roadmap as of today's date, rescore every team, and update the page — publishing only when nothing regresses. Works out where each team should be by the trigger date (IMPACT, QUICKPAY and benefitED have dated roadmaps in roadmaps.json), compares that to evidence of where they actually are, and reports a status like "Mel — on track based on AI roadmap". Accepts free-text details as arguments, which override weaker evidence. Use when the user says "run the progress audit", "audit the AI progress page", "update the progress artifact", "weekly roadmap audit", "/progress-audit", or supplies a weekly update for the leads' page.
---

# AI progress audit

Audits [the AI progress artifact](https://claude.ai/code/artifact/43208fc4-a808-448d-80ce-066b61f67b93)
against each team's roadmap **as of the date the audit is triggered**, and writes the answer back to
the page.

The trigger date *is* the input. Run it on 11 August and it asks what benefitED's Phase 2 (10–28 Aug)
should have produced by day 2; run it on 1 September and it asks why Phase 2 closed on 28 August with
criteria unmet. Nothing else needs to be supplied — though anything you do supply wins.

## How to run it

**Scheduled or headless** (the normal path — the wrapper does the date arithmetic in PowerShell so
the model never guesses a date):

```powershell
# dry run: compute, draft, publish nothing
pwsh -File .\ExternalAPITaskSchedulerPrompt\progress-audit\run-progress-audit.ps1 -TaskName manual -DraftOnly

# real run
pwsh -File .\ExternalAPITaskSchedulerPrompt\progress-audit\run-progress-audit.ps1 -TaskName manual

# with details for this run
pwsh -File .\ExternalAPITaskSchedulerPrompt\progress-audit\run-progress-audit.ps1 -TaskName manual `
    -Notes "Russell committed the 3 staged skills; Mel published the FAM roadmap"
```

**Interactively** (invoking this skill directly): read
[`progress-audit-prompt.md`](progress-audit-prompt.md) and follow it, resolving the placeholders
yourself from `roadmaps.json` and today's date. Treat every prohibition in that file as binding —
particularly the publish gate. If the user supplied arguments, they are the `{{TRIGGER_NOTES}}`.

## What it does

1. Reads the current artifact — every score becomes a `scoreBefore`.
2. Takes the **expected** phase per team, computed in PowerShell from the dated windows in
   [`roadmaps.json`](roadmaps.json). The model never recomputes this.
3. Establishes the **actual** phase from evidence: your trigger notes first, then `SKILL.md` files
   committed under each team's `skillsPath`, then the page's own narrative.
4. Scores at 20 points per completed phase plus part-credit, rounded to 5, and assigns a status —
   `On track` / `At risk` / `Behind` / `Ahead` / `No roadmap`.
5. Writes `audit-result.json`, then passes it through the publish gate.
6. Updates the page, or holds and drafts.

## The publish gate

**Publishes only if nothing regresses.** If any score would fall, or any phase window has closed with
exit criteria unmet, the run publishes nothing: it writes the proposed HTML plus a report explaining
the regression and logs `HOLD: <reason>`. A hold is a normal outcome — bad news gets a human read
before it reaches the page.

The wrapper re-reads `audit-result.json` after the run and logs `MISMATCH` if a publish happened on a
dirty result, so the gate is enforced from both sides.

## What it will not do

1. No writes to this repo — including `roadmaps.json`. Roadmap changes are a human edit, always.
2. No `git` mutations of any kind; the working tree is unchanged on exit.
3. No ADO or GitHub writes.
4. No rewriting the leads' narrative cells, the roadmap sections, or the takeaways. It changes scores,
   statuses, derivation notes, meters, phase chips and checkpoint columns — nothing else.
5. No inventing evidence. Unverifiable means no credit, stated plainly in the report.

## Rolling three-checkpoint window

The page's grid holds exactly three checkpoint columns and each score trace exactly three bars. A run
in a new ISO week drops the oldest, shifts left, and adds today's as the rightmost; a second run in
the same week refreshes that column in place. **Dropped checkpoints survive only in the audit
reports** under `logs/<TaskName>/` and `Downloads\AI Progress Audit\` — that is the history of record.

## Files

| File | Purpose |
|---|---|
| `roadmaps.json` | Phase windows, exit criteria and evidence paths per team. **Edit this when a roadmap changes.** |
| `progress-audit-prompt.md` | The engine — what the audit actually does. |
| `run-progress-audit.ps1` | Wrapper: date arithmetic, placeholder injection, headless launch, publish gate. |
| `register-progress-audit-task.ps1` | Registers the weekly Windows scheduled task. |
| `README-progress-audit.md` | Setup, tuning, troubleshooting. |

## Before you trust the numbers

Two teams state relative weeks rather than dates, so `roadmaps.json` carries a guessed
`anchorDate` for IMPACT and QUICKPAY with `anchorConfirmed: false`. Until a lead confirms them,
those teams' expected phases may be wrong, and the audit says so rather than marking them Behind.
FAM has no roadmap at all and stays unscored by design.
