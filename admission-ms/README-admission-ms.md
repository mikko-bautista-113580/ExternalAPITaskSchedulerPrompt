# admission-ms — local Admissions-MS endpoint generator (scheduled)

A headless automation that runs **weekdays at 07:00**, reads the **current ADO sprint**, finds
**Active** user stories tagged for the **Admissions MS**, and generates a working endpoint on a
**local git branch** in `Services.Admissions` — following the team's vertical-slice / CQRS
conventions and building to green. The generated code is left **uncommitted on the branch** so you
review the diff and commit it yourself.

It is a sibling of `ms-pr-review`, but where PR-review is strictly read-only, this one deliberately
**creates a branch and writes code**. It is **LOCAL-ONLY**:

> ✅ create local branch · write code · `dotnet build` · associate API tests to their ADO test cases
> ❌ never commit · never `git push` · never open a PR · never write to a story/Feature work item

> **Per-MS by design.** This folder is the Admissions instance. To add a generator for another
> microservice, copy the whole folder (e.g. to `people-ms`) and change the small **PER-MS CONFIG**
> block at the top of the wrapper (`$MsName`, `$ServiceRel`, `$TitleMarker`), plus `$TaskName` in the
> register script and the exemplar paths in the prompt.

## Files

| File | Purpose |
|---|---|
| `run-admission-ms.ps1` | Wrapper. Loads creds, resolves the current sprint, finds Active Admissions stories, guards a clean working tree, launches Claude headless, reports the branch/diff, rotates logs. |
| `admission-ms-prompt.md` | The prompt Claude follows: analyze story → branch → generate → build → associate test cases (no commit). |
| `register-admission-ms-task.ps1` | Creates/removes the `AdmissionMS-EndpointGen` scheduled task (Mon–Fri 07:00). |
| `reference/facts-sis-schema-tables.md` | FACTS SIS **table catalog** (~670 KB) — every documented table with columns, PK, **FK targets**, triggers, plus per-group "Key FK targets" cross-reference summaries. Used to resolve *which table an entity joins to in order to reach `ConfigSchoolID`*. Grep-only (too big to read whole). |
| `logs/AdmissionMS-EndpointGen/` | Per-run logs (last 30 kept). |

## How it decides what to build

1. **Current sprint** — resolved live each run via the ADO REST *current iteration* for team
   **`Modernization Team`** (org `renweb`, project `ColdFusion`). Always tracks the live sprint.
2. **Admissions stories assigned to you** — a WIQL query for `WorkItemType = 'User Story'`,
   `State = 'Active'`, `AssignedTo = @Me`, in that iteration, whose **title contains `Admissions`**
   (title-tag filter; matches the team's `[AdmissionsMS]` convention). `@Me` resolves to the identity
   that owns `ADO_PAT` — i.e. **whoever is running this** — so each dev generates for their own stories.
   **Rule: assigned to you + Active → proceed; otherwise skip.**
3. **Branch name** — one branch per run built from the story IDs (sorted ascending):
   - single story → `story/<id>`
   - multiple → `story/<id1>_<id2>_<id3>` (all endpoints generated on that one branch)
   - **Reuse-or-unique:** if that branch already exists, the wrapper **reuses** it when it's safe to
     continue on (it hasn't diverged from `origin/main`), and otherwise falls back to the next
     **unique** name `story/<ids>-2`, `-3`, … so a re-run never clobbers or fights an existing branch.
     The chosen name + a `create`/`reuse` mode are passed to Claude, which checks out accordingly
     (`-b` fresh, or `git switch` + merge `origin/main` for reuse; a merge conflict during reuse
     triggers the unique-branch fallback).
4. **Skip conditions** (no Claude launch): no current sprint, no matching Active story, or the working
   tree is dirty (safety abort). *An existing branch no longer skips the run — it is reused or a unique
   branch is created (see above).*

## One-time setup

1. **Credentials** — `%USERPROFILE%\repos\.env` (override via `config.local.json` → `envFile`) must define:
   ```
   ADO_PAT=<PAT with Work Items: Read>
   ADO_ORG=renweb
   ADO_PROJECT=ColdFusion
   ```
   (Same file used by the `shared-ado-connect` skill. **`Work Items: Read` is still all the PAT needs** —
   the one ADO write, Step 5's test-case association, authenticates separately via `az account get-access-token`,
   not the PAT.)
2. **Claude CLI** — installed at `%APPDATA%\npm\claude.cmd`.
   **`az` login (optional).** Step 5 associates the generated API tests to their ADO test cases and needs a
   valid `az` session; the task is non-interactive and will **never** prompt for login. If no session exists
   the association is skipped with a logged reason and everything else still runs. To enable it, log in once:
   ```powershell
   az login --scope 499b84ac-1321-427f-aa17-267ca6975798/.default
   ```
3. **Register the task** (elevated pwsh):
   ```powershell
   pwsh -File C:\neldevsrc\Github\TaskScheduler\admission-ms\register-admission-ms-task.ps1
   ```

## Running / testing manually

```powershell
# Full end-to-end run right now (not via the scheduler), verbose log under logs\manual\
pwsh -File C:\neldevsrc\Github\TaskScheduler\admission-ms\run-admission-ms.ps1 -TaskName manual

# Register + trigger one run immediately
pwsh -File C:\neldevsrc\Github\TaskScheduler\admission-ms\register-admission-ms-task.ps1 -RunNow

# Cheaper/faster model
pwsh -File ...\run-admission-ms.ps1 -TaskName manual -Model sonnet

# Remove the task
pwsh -File ...\register-admission-ms-task.ps1 -Unregister
```

## Reading the output

- **Log:** newest file in `logs\<TaskName>\`. Grep `===` for milestones (sprint resolved, branch,
  build result, DONE). Tail live:
  ```powershell
  Get-ChildItem "C:\neldevsrc\Github\TaskScheduler\admission-ms\logs\AdmissionMS-EndpointGen" |
    Sort LastWriteTime -Desc | Select -First 1 | %{ Get-Content -Wait $_.FullName }
  ```
- **Test-case association:** grep the log for `ASSOCIATE` — one line per feature, either
  `ASSOCIATE <Feature>: <n> cases — <s> succeeded, <f> failed (...)` or
  `ASSOCIATE SKIPPED (<Feature>): <reason>`. A skip is expected and harmless when the tests carry only
  `[TestCaseId("000")]` placeholders or `az` isn't logged in. To do it yourself afterwards, run
  `/sis-pdlc-plugin:p2-associate-testscript` on the API test file.
- **The work:** left **uncommitted** on the `story/...` branch in `c:\neldevsrc\Github\sis-services`,
  which the run leaves checked out. Review and commit yourself:
  ```powershell
  git -C c:\neldevsrc\Github\sis-services status
  git -C c:\neldevsrc\Github\sis-services diff
  # when satisfied:
  git -C c:\neldevsrc\Github\sis-services add -A
  git -C c:\neldevsrc\Github\sis-services commit -m "AB#<id> [AdmissionsMS] ..."
  ```

## Safety guarantees

- **Never touches a dirty tree** — if you have uncommitted changes, the run aborts before doing
  anything. (This also means you must review + commit or stash the previous run's output before the
  next run can proceed — by design, so un-reviewed work is never clobbered.)
- **You commit, not the automation** — generated code is left as uncommitted changes on its own
  local branch; you review the diff and decide what to keep.
- **Reuse-or-unique branch** — a re-run for a story set whose branch already exists will *reuse* that
  branch when it's safe (no divergence from `origin/main`), or create a unique `story/<ids>-N` branch
  when reusing would conflict. Either way an existing branch is never reset or clobbered.
- **No commit / no remote / no story mutation** — nothing is committed, pushed, or written to a story,
  Feature, or task. The **one** ADO write is Step 5's test-case association: it PATCHes only the
  *automation fields* (`AutomatedTestName`/`Storage`/`Id`, `AutomationStatus`, `State`) of **existing**
  Test Cases in the `Test Case Global Repo` project. It creates no work items, is skipped entirely for
  `[TestCaseId("000")]` placeholders, for red tests, for `scaffold` stories, and when `az` isn't
  authenticated — and a skip is logged, never a run failure.
- **Strict EF-safety gate** — `EFModel/*` and `AdmissionsContext` map to the shared production DB, so
  the prompt forbids guessed/breaking schema changes: prefer zero EF edits, additive-and-non-breaking
  only, must reflect the real schema, must still build green, and every EF touch is reported in the
  summary for you to confirm. (Added after the 2026-07-15 run introduced an `OAAlumniField.OA`
  navigation — legitimate, but exactly the kind of change that must be flagged, not made silently.)

## Standards Claude follows

- Authoritative: `sis-services/.architecture/microservices-architecture.md`.
- Operationalized rulebook + false-positive carve-outs: `ms-pr-review/pr-review-ms-standards.md`.
- **Reference PR (live, per run):** the latest merged endpoint PR by **one of your teammates**
  (the team roster minus you, from `team-roster.json`), looked up via `gh pr list`
  and matched to the story's operation type. Its file list is the **completeness checklist** — it is
  what guarantees the generator ships the full test surface, not just the production files.
- **Database shape:** the story's `sis-sql-schema` link (live DDL, authoritative) backed by the local
  `reference/facts-sis-schema-tables.md` catalog for FK/join lookups the story doesn't link.
- Exemplar slices copied for shape (fallback if `gh` is unavailable): `Features/OAEmergencyPickupField/`
  & `Features/OAAddressField/` (GET/list, incl. their full API-test tier) and `Features/OARequestInfoTrack/`
  (upsert/command).

### Technical Requirements (System Info) is the authoritative spec

Each story's **`Microsoft.VSTS.TCM.SystemInfo`** field ("Technical Requirements (System Info)") is the
ground-truth contract and the prompt now parses it strictly — it carries the exact controller name +
route, the MediatR method/query type names, the **complete DTO field list** (with types/nullability),
the `sis-sql-schema` table link, business rules, and validators. It **overrides** inference from the
title/description. (The 2026-07-15 run fetched only Description + Acceptance Criteria, so it missed the
`ConfigSchoolId [short] NOT NULL` field the System Info explicitly required — the ADO fetch now pulls
`SystemInfo` + `ReproSteps` and treats ViewModels as the DTO contract.)

- **Test case IDs** come from the story's **Testing Considerations** (`Custom.TestingConsiderations`)
  test-suite link — parse `planId`/`suiteId` from the `Test Case Global Repo` `_testPlans` URL, list the
  suite, and map test-case titles → methods. Fallbacks: `TestedBy` relations, then a "Test Cases" child
  task's comments. If nothing is linked for a scenario, use the literal **`[TestCaseId("000")]`** — never
  an invented or sequential ID.
- **`ConfigSchoolId` is DTO-only** — never added as an EF Model column; it's projected through the
  entity's navigation chain (null-safe, `(short)0` fallback), e.g. `e.OA.ConfigSchool.ConfigSchoolID`.
  If an entity has **no** navigation path to `ConfigSchool`, `ConfigSchoolId` is **omitted from the DTO
  entirely** (property + projection + Sieve) rather than shipped as a placeholder-`0` filterable field
  that would silently break filters; the omission is flagged loudly and the story marked `scaffold`
  pending a design decision (a defined `memberid -> ConfigSchool` mapping).
- **The join path is looked up, not guessed** — `reference/facts-sis-schema-tables.md` (see *Files*) is
  the schema catalog the prompt greps to answer *"which table does this entity join to for
  `ConfigSchoolID`?"*. `dbo.ConfigSchool` is the tenancy root (PK `SchoolCode`, surrogate
  `ConfigSchoolID smallint`), so a valid path is any **real, single-valued** FK chain landing on it —
  canonically `dbo.<OA*Field> --onlineappid--> dbo.OA --SchoolCode--> dbo.ConfigSchool`. The prompt's
  join-path ladder walks the chain hop by hop, rejects one-to-many/ambiguous hops, confirms against the
  story's live `sis-sql-schema` link (which wins over the snapshot), and only then permits either the
  projection or the omission. The resolved path (or `NONE (omitted)`) is logged in each story's analysis
  line. This is what separates a proven omission (`dbo.OARequestInfo`: PK `requestid`, only `memberid`,
  and `dbo.OAMember` has no `ConfigSchool` link at all) from a missed navigation.
- **Canonical 15 GET test scenarios** — `BasicRetrieval`, `Filter`, `AscendingSort`, `DescendingSort`,
  `Pagination`, `FilteredDataNotExist`, `EmptyDatabase`, `NullableFields`, and the six `ConfigSchool*` /
  `FilteredData*ConfigSchoolQuery*` cases.

These patterns are ported from the mature **`ms-clone`** skill in `sis-externalapi`
(`.claude/skills/ms-clone/`), adapted to the Admissions service (which, unlike the Academic `ms-clone`
reference, does not scope by `ConfigSchoolId` in the handler — Admissions' own reference PR wins).

### Both test tiers are required

A finished GET endpoint in the reference PRs ships **~25+ files per feature**, not ~4. The generator
must produce BOTH:

- **Unit** — `Admissions.Tests/Features/<Feature>/Queries/Get<Feature>QueryV1Tests.cs`.
- **API / integration (was being skipped)** — `Admissions.Tests/ApiTests/Features/<Feature>/…`:
  the `Get<Feature>QueryV1Tests.cs`, a `Shared/<Feature>DtoTm.cs`, an `ApiTests/Helpers/<Feature>Helper.cs`
  seeder, an `ApiTests/Shared/Faker/<Feature>EndpointFakerV1.cs`, and the committed `*.verified.txt`
  snapshots.

The API tier runs against an **in-memory host** with a deterministic Bogus seed, so its snapshots are
produced fully locally: run the tests → Verify emits `*.received.txt` → approve to `*.verified.txt` →
re-run green. (A 2026-07-15 run generated unit tests only, wrongly assuming snapshots need a live
service — the prompt now spells out this local approve loop and marks a unit-only slice as incomplete.)

### A snapshot cannot witness a scrubbed field — assertions are mandatory

Non-deterministic members (identity PKs, timestamps, `NextPage`, and `ConfigSchoolId`) are **scrubbed**
before `Verifier.Verify`, so they render as `{Scrubbed}`. That means a filter/sort/tenancy test which
asserts only the status code plus the snapshot **would still pass if the filter were ignored entirely**.
The prompt now carries a per-scenario assertion table (e.g. `ZeroConfigSchoolQuery` must assert
`AllSatisfy(x => x.ConfigSchoolId.Should().Be(0))`), warns that `AllSatisfy` passes vacuously on an
empty collection so it must be paired with `NotBeEmpty()`, derives the scrub list from the data instead
of a hardcoded list, and logs a `SCRUB-ASSERT CHECK` per scrubbed member — a `MISSING` blocks the `full`
verdict. (Raised in review of PR #3123 against two generated ApiTest files.)

### Reduced scenario sets are legitimate — when justified in code and in the summary

A feature ships fewer than the canonical 15 scenarios when its schema can't support them: no
`ConfigSchoolId` path drops cases 9–15, and no nullable DTO fields drops case 8. That is correct rather
than under-coverage **only if** the reason is recorded both as an in-code `// NOTE(AB#<id>)` and in the
run summary (`SCENARIOS: <Feature> — <k> of 15 (<reason>)`). Review of PR #3123 accepted
`OAStandardReportingType`'s 9 of 15 precisely because the in-code NOTE explained it.

### Tenancy through a junction table (the fan-out pattern)

Not every entity reaches `dbo.ConfigSchool` by a single-valued FK chain. When it carries a bare, non-FK
id (`memberid`, …), the link is often a **junction table keyed on that same column** — which an
FK-only walk never finds, because there is no FK to follow. The ladder now searches for one explicitly
(both in the schema catalog and in `EFModel/`, where the entity + `DbSet` often already exist), and it
cross-checks the **ADO test suite**: a suite containing `ConfigSchool*` scenarios or
`Sort*_ConfigSchoolId` cases is the PO stating that `ConfigSchoolId` must be a filterable/sortable DTO
field, so a "no path" conclusion contradicting it must be resolved, not shipped.

Where the junction is one-to-many, `ConfigSchoolId` is still exposed — the endpoint mirrors production
and returns **one row per (entity × school)**. Because that projection is no longer 1:1 with the base
entity, the DTO's `Projection` is typed over a small `Shared/<Feature>Source.cs` join row instead of the
entity, and the handler joins in LINQ. Omitting `ConfigSchoolId` is now an explicit last resort
requiring **two** agreeing signals (ladder *and* suite).

> Added after AB#256329: a run omitted `ConfigSchoolId` and shipped `scaffold` because `memberid` had no
> FK — missing `dbo.OAInquiryBySchool`, which was already in `EFModel/` with a `DbSet`. The story lost
> its `full` status and all 19 of its ADO test cases stayed `Not Automated`.

### Conventions the prompt pins

- **File-scoped namespaces in every new file** (`namespace X;`, not a braced block). New files will
  differ from older block-scoped exemplars; that divergence is intentional and pre-existing files are
  not reformatted. (Raised in review of PR #3123 on a new `EFModel/` entity.)
- **Composite PKs are recorded, not "fixed."** When a table's PK is composite with no surrogate `Id`
  (e.g. `OAFormCompleted` = `FormSchoolID` + `studentid`), the generator reports the PK shape in the
  summary and never invents an `Id`. Pagination checkers that key overlap on a single `Id` report a
  false overlap on such tables — hand-verification on PR #3123 showed real overlap of 0, so the prompt
  explicitly forbids adding a tie-break to satisfy a mis-keyed checker.

## Tuning

- **Schedule:** edit `-Times` in `register-admission-ms-task.ps1` (default `@('07:00')`) and re-register.
- **Story filter / MS identity:** edit the **PER-MS CONFIG** block (`$MsName`, `$ServiceRel`,
  `$TitleMarker`) and `$AdoTeam` in `run-admission-ms.ps1`.
- **Model:** wrapper defaults to `opus`; pass `-Model sonnet` to the wrapper or register script.

## Troubleshooting

| Symptom | Fix |
|---|---|
| `FATAL: ADO_PAT not present` | Add `ADO_PAT` (+`ADO_ORG`/`ADO_PROJECT`) to `~/repos/.env`. |
| `ADO current-iteration query failed` | PAT expired or lacks *Work Items: Read*, or team name changed. |
| `ABORT: working tree is dirty` | Review/commit/stash your changes (incl. a prior run's output), then re-run. |
| `Branch ... REUSING it` / `... UNIQUE branch` | Expected: the desired branch existed, so it was reused (safe) or a unique `-N` branch was made. Delete the local branch first if you want a clean regen under the original name. |
| `BUILD: FAIL` in the log | Story was ambiguous or code needs manual finishing — branch kept with `// TODO(AB#..)` markers. |

## Post-run process review

After each run finishes, the wrapper calls the shared `Invoke-LogReview` (`..\lib\log-review.ps1`),
which runs a second headless `claude` (opus) on `..\lib\log-review-prompt.md` to review **this run's
log** for process improvements (timeouts, path mismatches, wasted cycles, `WARN`/`FATAL` lines, prompt
issues). It writes a report next to the log (`logs\<TaskName>\<TaskName>_<timestamp>.review.md`) and,
when the automation tree is clean, applies **validated, uncommitted** fixes to this repo's own files
for you to review with `git diff` and commit. It never commits/pushes, never edits the target repo,
degrades to report-only if edits are already pending, and reverts any edited `.ps1` that fails to
parse. See the repo-root `README.md` → "Post-run process review".
