# externalapi-gw — sis-externalapi Gateway endpoint generator (scheduled)

Generates **Gateway (sis-externalapi)** endpoints from the Active sprint user stories,
once each weekday at **07:00** local time. It processes **every** eligible ticket in one run
and puts them all on **one** local branch named after all of them — `story/<id1>_<id2>_<id3>`
(IDs ascending) — with the generated files left **UNCOMMITTED** for you to review and commit.
One branch means your eventual push is **one PR** for the whole sprint's Gateway work. The job
never commits, pushes, opens a PR, or changes any ticket's state.

## Multi-ticket runs

The wrapper owns discovery and naming; the prompt just executes:

- **Discovery** — the wrapper resolves the current sprint, runs the WIQL (`Active` + `AssignedTo = @Me`
  + title contains `ExternalAPIGW`), fetches the titles, and appends an authoritative **Runtime inputs**
  block to the prompt with the sprint, the ticket list, the target branch, and the branch mode. If nothing
  is eligible it exits 0 before touching git.
- **Branch name** — one ticket → `story/<id>`; several → `story/<id1>_<id2>_<id3>`.
- **Branch mode** — `create` for a free name; `reuse` when the branch already exists and has *not* diverged
  from `origin/main` (safe to continue on top); otherwise a unique `story/<ids>-2`, `-3`, … So a re-run on the
  same ticket set continues the existing branch instead of aborting.
- **Per-ticket isolation** — each ticket gets its own strict ADO parse, codegen, `dotnet build`, 100% line +
  branch coverage gate, and test-case association. A ticket that fails is logged `TICKET <id> FAILED (<reason>)`
  and the run continues; it never discards another ticket's work. A final whole-solution build catches
  cross-ticket interference in shared files (`SISApi.API.csproj`, `PublicChangeLog.md`,
  `DependencyInjectionExtensions.cs`).
- **Progress** — grep the log for `===` to see per-ticket milestones, or `TICKET \d+ (READY|FAILED)` for verdicts.

⚠️ **Cost and time.** Roughly **~$14 and ~23 min per ticket** (observed), so a 3-ticket sprint is ~$43 / ~70 min.
The scheduled task allows **3 hours** (~6 tickets). That limit lives in `register-gw-task.ps1` and only takes
effect once you **re-register the task in an elevated pwsh** (see Deploy / manage below); verify with
`(Get-ScheduledTask -TaskName 'GW-MorningAutoPR-0700').Settings.ExecutionTimeLimit` → `PT3H`.

⚠️ **The wrapper refuses to start while the previous run's `story/*` branch still has uncommitted files.**
That is deliberate — it will not pile a new run's output onto work you haven't reviewed. Commit + push it,
or discard it (`git checkout -- .; git clean -fd src/; git checkout main; git branch -D <branch>`), then re-run.

**One ADO write** (Step 11): after the build and coverage gates pass, it associates the generated
integration tests to their ADO Test Cases — PATCHing only the *automation fields* of **existing**
Test Cases in the `Test Case Global Repo` project, via the repo's own
`.claude/skills/_shared/scripts/AssociateTestScript.ps1`. It creates no work items and never touches
the ticket. It is skipped — with a logged reason, never a failure — when the TestCaseIds were
defaulted rather than enumerated from Testing Considerations, when the build/coverage gate failed, or
when `az` isn't authenticated. Grep the log for `ASSOCIATE`. To enable it, log in once:

```powershell
az login --scope 499b84ac-1321-427f-aa17-267ca6975798/.default
```

To do it yourself afterwards: `/gw-test-associator <path to the SISApi.APITests file>`.

Relocated here from `c:\neldevsrc\Github\sis-externalapi\.scheduled` so all scheduled-task
artifacts live centrally under `ExternalAPITaskSchedulerPrompt\`. The original `.scheduled` folder in the repo
was left in place (this is a copy). `$RepoRoot` in the wrapper still points at the
sis-externalapi checkout that claude operates on; only the wrapper/prompt/logs/lock moved.

## Files
- `run-morning-gw.ps1` — wrapper: git pre-flight → launches claude on the prompt → streams
  events to a timestamped log. `$ScheduledDir` points at this folder (logs/prompt/lock live here).
- `morning-gw-prompt.md` — the generation prompt handed to claude.
- `register-gw-task.ps1` — (re)registers the `GW-MorningAutoPR-0700` scheduled task against
  this wrapper. Run in an **elevated** pwsh.
- `logs/GW-MorningAutoPR-0700/` — per-run logs (last 30 kept). History copied over from the
  old location.

## Deploy / manage
```powershell
# register (or re-point) the task — elevated pwsh
pwsh -File C:\neldevsrc\Github\ExternalAPITaskSchedulerPrompt\externalapi-gw\register-gw-task.ps1

# run it now
pwsh -File C:\neldevsrc\Github\ExternalAPITaskSchedulerPrompt\externalapi-gw\register-gw-task.ps1 -RunNow

# remove it
pwsh -File C:\neldevsrc\Github\ExternalAPITaskSchedulerPrompt\externalapi-gw\register-gw-task.ps1 -Unregister
```

## Verify
```powershell
Get-ScheduledTask -TaskName 'GW-MorningAutoPR-0700' | Get-ScheduledTaskInfo
Start-ScheduledTask -TaskName 'GW-MorningAutoPR-0700'   # run now
```

## Post-run process review

After each run finishes, the wrapper calls the shared `Invoke-LogReview` (`..\lib\log-review.ps1`),
which runs a second headless `claude` (`claude-opus-5`) on `..\lib\log-review-prompt.md` to review **this run's
log** for process improvements (timeouts, path mismatches, wasted cycles, `WARN`/`FATAL` lines, prompt
issues). It writes a report next to the log (`logs\<TaskName>\<TaskName>_<timestamp>.review.md`) and,
when the automation tree is clean, applies **validated, uncommitted** fixes to this repo's own files
for you to review with `git diff` and commit. It never commits/pushes, never edits the target repo,
degrades to report-only if edits are already pending, and reverts any edited `.ps1` that fails to
parse. See the repo-root `README.md` → "Post-run process review".
