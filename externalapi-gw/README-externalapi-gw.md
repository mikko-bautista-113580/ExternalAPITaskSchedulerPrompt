# externalapi-gw — sis-externalapi Gateway endpoint generator (scheduled)

Generates **Gateway (sis-externalapi)** endpoints from the Active sprint user stories,
once each weekday at **07:00** local time. Output is a local `story/<id>` branch with the
generated files left **UNCOMMITTED** for you to review and commit. The job never commits,
pushes, opens a PR, or writes to ADO.

Relocated here from `c:\neldevsrc\Github\sis-externalapi\.scheduled` so all scheduled-task
artifacts live centrally under `TaskScheduler\`. The original `.scheduled` folder in the repo
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
pwsh -File C:\neldevsrc\Github\TaskScheduler\externalapi-gw\register-gw-task.ps1

# run it now
pwsh -File C:\neldevsrc\Github\TaskScheduler\externalapi-gw\register-gw-task.ps1 -RunNow

# remove it
pwsh -File C:\neldevsrc\Github\TaskScheduler\externalapi-gw\register-gw-task.ps1 -Unregister
```

## Verify
```powershell
Get-ScheduledTask -TaskName 'GW-MorningAutoPR-0700' | Get-ScheduledTaskInfo
Start-ScheduledTask -TaskName 'GW-MorningAutoPR-0700'   # run now
```

## Post-run process review

After each run finishes, the wrapper calls the shared `Invoke-LogReview` (`..\lib\log-review.ps1`),
which runs a second headless `claude` (opus) on `..\lib\log-review-prompt.md` to review **this run's
log** for process improvements (timeouts, path mismatches, wasted cycles, `WARN`/`FATAL` lines, prompt
issues). It writes a report next to the log (`logs\<TaskName>\<TaskName>_<timestamp>.review.md`) and,
when the automation tree is clean, applies **validated, uncommitted** fixes to this repo's own files
for you to review with `git diff` and commit. It never commits/pushes, never edits the target repo,
degrades to report-only if edits are already pending, and reverts any edited `.ps1` that fails to
parse. See the repo-root `README.md` → "Post-run process review".
