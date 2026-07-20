You are running as a Windows scheduled task. Your job is to **scaffold the Gateway GET endpoint code locally** for the next eligible active Azure DevOps ticket assigned to **you** — i.e. the identity that owns `ADO_PAT` (use `[System.AssignedTo] = @Me` in WIQL; `@Me` resolves to whoever is running this). **Do not commit, do not push, do not open a PR.** Generate the files in the working tree on a new `story/{id}` branch and stop — the user reviews the modified/added files in their IDE and decides whether to commit + push, or discard.

**Single-ticket-per-run policy.** Process AT MOST ONE eligible ticket per scheduled run. If the user has multiple active ExternalAPIGW tickets, pick the one with the lowest work-item ID and skip the rest with `SKIPPED (queued — process one at a time)`. This keeps the working tree readable and avoids piling uncommitted files from multiple tickets onto one branch.

## Autonomy override (explicit user authorization)

The user has **explicitly authorized this scheduled task to run autonomously up to the point of a local commit**, overriding the following rules from `.claude/CLAUDE.md`:

- The "Endpoint Delivery Lifecycle" state machine — DO NOT apply
- Gate A (PROPOSED → APPROVED) — DO NOT pause for user approval; proceed directly to local implementation
- Gate B (READY → PUSHED) — **the gate stays closed**. You are NOT authorized to push or open a PR. Stop at READY.

Other rules from `.claude/CLAUDE.md` STILL APPLY: no merge/rebase/force-push, no branch-delete, ADO state ceiling stays where it is (do not advance ADO state — the user will move it manually if/when they push).

## Hard prohibitions (the run FAILS if you do any of these)

- ❌ NO `git push` of any kind, to any remote, for any branch
- ❌ NO `gh pr create` / `mcp__github__create_pull_request` / opening a draft PR / publishing a PR
- ❌ NO ADO work-item state changes
- ❌ **NO `git add`, `git commit`, or any staging/commit operation.** This is the policy change: the user wants to review the modified and added files in their IDE *before* any commit happens. Leave every generated file uncommitted in the working tree on the new `story/{id}` branch.
- ❌ NO `git stash`, `git reset --hard`, `git restore`, `git clean`, or anything that could discard files. The user's uncommitted WIP and the files you just generated must all stay visible in the working tree.
- ❌ NO `git checkout main` after you've created `story/{id}`. Stay on `story/{id}` at exit so the user finds their repo on that branch with the generated files visible.
- ❌ NO `claude_self_reviewed` PR comments (no PR exists to comment on).

## Execution environment

You are running directly inside the user's main repo at `{{REPO_ROOT}}` (NOT a worktree). The wrapper has already:
- `cd`-ed into the repo
- `git fetch origin main` and fast-forwarded local `main` to `origin/main`
- Verified `git status` is clean for tracked files (the user's WIP is in untracked / .mcp.json — wrapper records the WIP file list at start)

What this means for you:
- The repo state is real and visible to the user in their IDE — be careful, every branch switch and file write is something the user sees.
- The user's WIP (modified `.mcp.json`, untracked `.scheduled/`, possibly others) MUST be preserved. Use explicit `git add <path>` for each generated file. NEVER `git add -A` or `git add .`.
- The Azure DevOps MCP is configured via the live `.mcp.json` in the repo — you may READ from it (query tickets, test plans, wiki). **GitHub API / `gh` CLI access is NOT required for this task** — the scheduled-task environment often lacks SAML-authorized credentials, so do not depend on `mcp__github__*` tools or `gh`. Use git-native commands (`git ls-remote`, `git branch`) for any remote/local branch existence checks. Writes to GitHub are forbidden anyway per the Hard Prohibitions.

## Step 1 — Check for an active ticket FIRST (before any git pre-flight)

**Do this before anything else.** Query ADO for an eligible ticket up front so the run exits cheaply when there is nothing to work on — no point running the git pre-flight, switching branches, or touching the working tree if the user has no active ExternalAPIGW ticket in the current iteration.

1. Use the Azure DevOps MCP to find the current iteration for project=`ColdFusion`, team=`Modernization Team` (use `mcp__azure__work_list_iterations` or `mcp__azure__work_list_team_iterations` with `timeFrame=current`).
2. List work items in that iteration where `AssignedTo` = `@Me` (the ADO PAT owner — whoever is running this) AND `State` = "Active" (use `mcp__azure__wit_get_work_items_for_iteration` or `mcp__azure__wit_query_by_wiql`).
3. For each work item, fetch `id`, `System.Title`, and Domain/Resource info from the System Info / Technical Requirements fields.
4. **Title filter (REQUIRED):** Keep only work items where `System.Title` contains the literal string `ExternalAPIGW` (case-insensitive). Log each discarded ticket as `SKIP (not ExternalAPIGW): {id} - {title}`.

**If no matching ExternalAPIGW tickets remain, log `No active ExternalAPIGW tickets found in current iteration` and exit cleanly with status 0 — do NOT run the git pre-flight (Step 2), do NOT switch branches, and do NOT modify the working tree.** There is nothing to do this run.

## Step 2 — Pre-flight (only once an eligible ticket has been found)

Run these read-only checks only after Step 1 has found at least one eligible ticket:

1. Confirm `Get-Location` (or `pwd`) returns exactly `{{REPO_ROOT}}`. If not, log `FATAL: not running in user's main repo` and exit immediately.
2. Confirm `git rev-parse --abbrev-ref HEAD` returns `main`. If not, log `FATAL: not on main branch` and exit — the wrapper should have left you on main; if you're not, something is wrong.
3. Confirm `git rev-parse HEAD` matches `origin/main`. If not, log a warning and exit.
4. Record the list of currently-uncommitted files via `git status --porcelain` and stash that list in memory. You'll use it at the end to verify the user's WIP was preserved.

## For each active ticket

For each ticket `{id}` with title `{title}`:

7. **Skip-if-branch-already-exists check** (READ-only, git-native — no GitHub API needed). Run BOTH of:
   - `git branch --list story/{id}` (local)
   - `git ls-remote --heads origin story/{id}` (origin)

   If EITHER returns a result, the branch is already in use (a prior run, an in-flight push, an open PR, or a recently-merged-but-not-deleted PR). Log `SKIP: branch story/{id} already exists locally and/or on origin — leave it for user review` and continue to the next ticket. Do NOT recreate or modify the branch.

   Edge case: a closed/merged PR whose branch was deleted on origin will NOT be detected by `git ls-remote`. That's acceptable — the upstream "ticket must be Active in current iteration" filter (Step 1) catches it, because a merged ticket should no longer be Active. If you ever observe a merged-but-still-Active ticket, the ADO state is the bug, not this check.

8. _(Consolidated into step 7 — no separate local-only check needed.)_

9. **Strict ticket parse (MANDATORY before any codegen — past runs scaffolded from reference files and silently invented properties / skipped test suites).** Do this *before* creating the branch. If any required artifact is missing or unparseable, log `FAILED (ticket parse: <reason>)` and continue to the next ticket without creating the branch.

    9a. **Full-fidelity ticket fetch.** Call `mcp__azure__wit_get_work_item` with `id={id}`, `expand=All`, and explicitly include all of these in the `fields` parameter so nothing is truncated:
        - `System.Title`
        - `System.Description`
        - `Microsoft.VSTS.TCM.SystemInfo` (Technical Requirements / System Info — primary source of truth)
        - `Microsoft.VSTS.TCM.ReproSteps` (sometimes holds the spec instead)
        - `Microsoft.VSTS.Common.AcceptanceCriteria`
        - any `*.TestingConsiderations` / `*.TestingNotes` field surfaced by the work-item type (call `mcp__azure__wit_get_work_item_type` once per work-item-type if uncertain)
        Also fetch related links and attachments (`relations`) so you can resolve a Testing Considerations URL if it is referenced rather than inlined.

    9b. **Parse and ECHO the ViewModels — the ticket is the only source of truth.** Inside `Microsoft.VSTS.TCM.SystemInfo` (fall back to `ReproSteps` only if `SystemInfo` is empty), locate the `ViewModels` (sometimes `View Models`) section. Each ViewModel block names a class (e.g. `ProgressionReadyCountOutput`, `GradeBreakdownOutput`) and lists its properties as `PropertyName [Type] NOT NULL|NULL`. Before generating any C# file, **print the parsed structure to the log** in this exact form so the user can audit it:

        ```
        TICKET {id} VIEWMODELS PARSED:
          ClassName: ProgressionReadyCountOutput
            - SchoolId            [SchoolIdReference]      NOT NULL
            - AcademicYear        [AcademicYearReference]  NOT NULL
            - ByGrade             [List<GradeBreakdownOutput>] NULL
          ClassName: GradeBreakdownOutput
            - GradeLevel          [GradeLevelReference]    NOT NULL
            - ReadyCount          [int]                    NOT NULL
        TICKET {id} QUERY PARAMETERS PARSED:
          - schoolId   [int]    required
          - schoolYear [string] optional
        ```

        If the ViewModels section is missing, empty, or unparseable, log `FAILED (ticket parse: no ViewModels)` and continue to the next ticket. Do NOT guess properties from the reference endpoint.

    9c. **Resolve the Testing Considerations link and enumerate ALL test suites.** Inside the ticket body, scan `Microsoft.VSTS.TCM.SystemInfo`, `Microsoft.VSTS.TCM.ReproSteps`, `System.Description`, and `Microsoft.VSTS.Common.AcceptanceCriteria` for a `Testing Considerations` heading or a hyperlink labelled `Testing Considerations` / `Test Cases` / `Test Suite`. Also walk `relations` for `Hyperlink` / `ArtifactLink` entries pointing at an ADO test plan or wiki page. For each link found:
        - If it is an **ADO wiki link** (`/_wiki/wikis/.../{page}`), parse out the wiki + page path and fetch with `mcp__azure__wiki_get_page_content`.
        - If it is an **ADO test plan / suite link** (`/_testPlans/...`), parse the `planId` and `suiteId` and call `mcp__azure__testplan_list_test_suites` + `mcp__azure__testplan_list_test_cases` to enumerate every test case (capture each `TestCaseId`, `Title`, and the suite it lives in).
        - If it is a **related work item** (e.g. parent Test Case), call `mcp__azure__wit_get_work_item` and pull its Steps / Title.
        - If it is a plain URL outside ADO, fetch it with `WebFetch` and extract the suite/case list.

        Print the enumerated suites in this exact form so the user can audit:

        ```
        TICKET {id} TEST SUITES ENUMERATED (source: <wiki|testplan|workitem|webfetch> @ <url>):
          Suite: Smoke
            - TC######  Happy-path 200 with valid schoolId
            - TC######  ...
          Suite: Auth
            - TC######  401 when token missing
            - TC######  403 when scope missing
          Suite: Validation
            - TC######  400 when schoolId < 1
          Suite: NotFound
            - TC######  404 when schoolId has no records
        ```

        If the ticket has NO Testing Considerations link AND no inline test-suite list, log `WARN (ticket {id}): no Testing Considerations link found — falling back to default suites from generate-get-endpoint.md` and proceed; do NOT fail the ticket on this alone. If a link exists but is unreachable / 404 / requires interactive auth, log `FAILED (ticket parse: Testing Considerations link unreachable: <url>)` and continue to the next ticket — do NOT silently substitute defaults when a link was explicitly provided.

10. **Create the branch, then scaffold inside it.** Run `git checkout --no-track -b story/{id} origin/main` to create and switch to the new branch from a fresh `origin/main` reference. The branch starts clean (no leftover state from prior runs). **The `--no-track` flag is REQUIRED** — without it, branching off a remote-tracking ref (`origin/main`) makes git set the new branch's upstream to `origin/main`. That later breaks the user's `git push` (with `push.default=simple` git refuses because the local name `story/{id}` ≠ upstream name `main`). `--no-track` leaves the branch with no upstream, so the user's first `git push -u origin HEAD` sets tracking correctly. After branching, follow `.claude/commands/GWEndpointsGenerator/generate-get-endpoint.md` exactly — that file is the **single authoritative codegen reference**. Do NOT invoke the `gw-endpoint-orchestrator`, `gw-endpoint-cloner-get`, `gw-build-fixer`, `gw-test-associator`, or `gw-pr-creator` skills. Read `.claude/commands/GWEndpointsGenerator/generate-get-endpoint.md` from disk and execute its Steps 1, 2, and 3 (Extract User Story Information → Generate Code Components → Generate Test Files) for the ticket id from Step 1. Apply its Integration Test Rules, Unit Test Rules, Reference Object Rules, and Endpoint Validation Checklist as-is.

    **DTO source-of-truth (CRITICAL — past runs got this wrong):** When generating the Input, Output, and any nested DTO/output classes, the property names, types, nullability, and required-ness MUST come from the **parsed ViewModels you echoed in step 9b**, NOT from the StudentsHomeroom reference pattern. The StudentsHomeroom files are reference only for *structure* (file layout, ExcludeFromCodeCoverage attribute, constructor pattern, namespace shape) — they are NOT the source of properties. Concretely:

    - Use the exact ViewModel list from step 9b. If a property appears in your generated file but NOT in the step-9b echo, REMOVE it. If a property appears in step 9b but NOT in your generated file, ADD it. No exceptions, no "the reference had it so I kept it."
    - Generate **one C# class per ViewModel block** in `Features/{FolderName}/{FeatureName}/Shared/`. For each property line, emit the exact PropertyName and Type, marking nullable when the spec says `NULL` and non-nullable (or `required`) when it says `NOT NULL`. Reference types (e.g. `AcademicYearReference`, `SchoolIdReference`, `GradeLevelReference`) come from `SISApi.API/Models/References/` — create the reference class if it doesn't exist.
    - If the ViewModel includes a `List<NestedType>` field (e.g. `ByGrade [List<GradeBreakdownOutput>]`), the nested type MUST also be present as its own ViewModel block — generate it as a sibling class file in `Shared/`.
    - The Output class does NOT need to inherit from Input when the ViewModel section shows them as independent structures (single-object response, non-Sieve query params). Override the `## Endpoint Validation Checklist > DTOs > "Output inherits from Input"` rule from `generate-get-endpoint.md` whenever the ticket's ViewModels clearly model them as separate.
    - **Final diff-check before writing:** open each generated DTO file, list its public properties, and diff against the step-9b echo. Print `DTO DIFF for {ClassName}: OK` or `DTO DIFF for {ClassName}: MISMATCH (<details>)` to the log. A `MISMATCH` means stop and fix the file before moving on.

    **Test-coverage source-of-truth:** When generating integration/unit tests, the suites and test cases you cover MUST come from the **Testing Considerations enumeration you echoed in step 9c**. After the codegen step:
    - Build a mapping of `enumerated TestCaseId → generated test method name` and print it to the log. Every TestCaseId from step 9c MUST appear in the mapping with a non-empty test-method name; tag any missing case `TODO`. Conversely, every `[TestCaseId("...")]` attribute in the generated test files MUST come from the step-9c enumeration — no invented IDs.
    - If step 9c produced no enumeration (the `WARN` path), fall back to the default suites and TestCaseIds prescribed by `.claude/commands/GWEndpointsGenerator/generate-get-endpoint.md` — and clearly log `TestCaseIds defaulted (no Testing Considerations link)` so the user knows to fill them in before pushing.

    **MS client-library dependency (NuGet) — resolve via the INTERNAL feed BEFORE concluding a ticket is blocked.** Gateway GET endpoints are thin wrappers over the domain microservice's client library (e.g. `SIS.Admissions.Service.Client`, referenced in `src/Applications.SISApi/SISApi.API/SISApi.API.csproj`). The generated Query/Output/Controller reference client types such as `I{Resource}Client`, `{Resource}Dto`, `Get{Resource}V1HttpResponseAsync`. If those types are not present in the currently-referenced package version the build fails. Handle it like this — do NOT give up after only checking nuget.org:

    1. **The internal `NbsDevPackages` feed is authoritative, NOT nuget.org.** SIS client packages are published to `https://pkgs.dev.azure.com/nbsdev/_packaging/NbsDevPackages/nuget/v3/index.json`, configured in `src/Applications.SISApi/nuget.config`. nuget.org **lags** and may cap several versions behind (a past run saw `8.0.155` on nuget.org while the internal feed already had `8.0.160` with the needed types). ALWAYS discover versions through the repo's nuget.config, never nuget.org alone.
    2. **Find the latest published version** on the internal feed:
       `dotnet package search SIS.<Domain>.Service.Client --exact-match --configfile src/Applications.SISApi/nuget.config --format json`
       (append `--prerelease` only if no stable version exposes the types). Take the highest version the INTERNAL feed returns.
    3. **Bump the PackageReference** for that client in `SISApi.API.csproj` to the latest internal version, then `dotnet restore src/Applications.SISApi/Applications.SISApi.sln` from the repo root (restore reads the repo nuget.config, so it authenticates against the internal feed via the configured credential provider). This csproj bump is an expected local change — leave it **uncommitted** in the working tree like every other generated file.
    4. **Verify the required types now exist** before continuing codegen/build: locate the restored assembly at `~/.nuget/packages/sis.<domain>.service.client/<version>/lib/net8.0/*.Service.Client.dll` and grep for the exact type name(s) you need, e.g. `grep -aoE '{Resource}[A-Za-z0-9_]*' <dll> | sort -u`. Confirm the plain GET types are present — do NOT mistake a similarly-named sibling for the real type (e.g. `OARequestInfo*` GET types vs the unrelated `OARequestInfoTrack*` types).
    5. **Only declare the ticket blocked if the LATEST version on the INTERNAL feed still lacks the types.** In that case log `FAILED (upstream client missing: <package> <latest-internal-version> lacks <types>)`, note that the parent MS story's client NuGet has not been re-published yet, revert the csproj bump (via `Edit`, not a destructive git op) so the tree is clean, and continue. Never conclude "blocked" from a nuget.org-only check.

    After the codegen steps are complete:
    - Build the solution to verify there are no compile errors: `dotnet build src/Applications.SISApi/Applications.SISApi.sln` from the repo root. If errors, fix them and rebuild; loop up to 5 times before giving up and recording the ticket as `FAILED (build)`. Leave the fixes uncommitted in the working tree like everything else.
    - **Coverage gate — 100% line AND 100% branch REQUIRED.** After the build is green, run the generated tests with coverage and confirm the code you generated for this ticket hits **100% line coverage AND 100% branch coverage** (both sides of every `if`/ternary/null-check/`??`/switch arm exercised) — measured only over the classes this ticket adds (the `Query` handler, the `Output`/`Input`/nested DTOs and their mapping, any `Reference` classes, and any non-`[ExcludeFromCodeCoverage]` wiring), not the whole solution. The Controller carries `[ExcludeFromCodeCoverage]` per `generate-get-endpoint.md` and is correctly excluded — do NOT strip that attribute to game the number, and do NOT add `[ExcludeFromCodeCoverage]` to a handler/DTO-mapper to dodge coverage.
      1. Measure with coverlet: `dotnet test src/Applications.SISApi/Applications.SISApi.sln --filter "FullyQualifiedName~{FeatureName}" /p:CollectCoverage=true /p:CoverletOutputFormat=cobertura /p:Include="[SISApi.API]*{FeatureName}*"`. If the repo already wires a `coverlet.runsettings` or `--collect:"XPlat Code Coverage"` path, discover and use that instead of inventing flags. Read `line-rate` **and** `branch-rate` for each generated class from the emitted `coverage.cobertura.xml`; both must be `1` (100%).
      2. If any line or branch is uncovered, it means a scenario from the step-9c enumeration (or the `generate-get-endpoint.md` default suites) is missing — **add the test** (empty/404 path, each validation branch, each nullable-field branch of the Output mapping) and re-run until both rates are 100%. The added test must assert real behavior, not merely execute the line.
      3. If a specific branch is genuinely unreachable (a defensive guard no valid input can hit), do not silently fall short: leave a `// TODO(AB#{id}): <branch> uncovered — <why>`, and record the class + line + achieved line%/branch% in the ticket summary. A ticket below 100% coverage without a logged, justified exception is `FAILED (coverage: <class> line=<x>% branch=<y>%)`.
      4. **KNOWN BRANCH-COVERAGE TRAP — the `GetApimNextUrl` null-conditional chain + NSubstitute auto-mock (this is the #1 reason a GET handler lands at ~87% branch, not 100%).** Every list/paged GET Query handler contains two null-conditional chains inside the `ApimHelper.GetApimNextUrl(...)` call:

         ```csharp
         _httpContextAccessor?.HttpContext?.Request?.GetDisplayUrl(),
         _httpContextAccessor?.HttpContext?.Request?.Query["api-version"]
         ```

         Each `?.` is a branch point (null → short-circuit vs. not-null → continue), so each chain has **three** branch points: the accessor, `HttpContext`, and `Request`. The trap: **NSubstitute auto-mocks abstract/interface return types.** `Substitute.For<IHttpContextAccessor>().HttpContext` returns a non-null substitute `HttpContext` by default, whose `.Request` is likewise a non-null substitute — *without you configuring anything*. So every "happy path" test silently exercises only the **not-null** side of all three `?.`, and the three null-short-circuit branches stay uncovered. A handler with otherwise-perfect tests will sit at branch-rate `0.875` (7/8) purely because of the `HttpContext == null` branch nobody hit.

         To close it, add **three dedicated tests**, one nulling each level of the chain (in addition to a full-chain-non-null test that sets up a real `HttpContext`/`Request`/`QueryCollection`, plus the null-and-non-null `NextPage` tests that cover the `string.IsNullOrEmpty(nextPageUrl) ? null : nextPageUrl` ternary):
         - **Accessor null** — construct the handler with `null` for the `IHttpContextAccessor` argument, then `Handle(...)`.
         - **`HttpContext` null** — `_mockHttpContextAccessor.HttpContext.Returns((HttpContext)null);` (accessor present, its context null — this is the branch the auto-mock hides).
         - **`Request` null** — a substitute `HttpContext` whose `mockHttpContext.Request.Returns((HttpRequest)null);`, wired via `_mockHttpContextAccessor.HttpContext.Returns(mockHttpContext);`.

         Each asserts `result.NextPage Is.Null` (the chain yields a null display-url, so `GetApimNextUrl` returns empty → `NextPage` null). That takes the handler to 100% branch.

      5. **Pinpointing WHICH branch is unhit (do this instead of guessing when branch-rate < 1).** cobertura's per-line `condition-coverage` is aggregated and hard to map to a specific `?.`. Re-run with coverlet's **json** format and read the `Branches` array directly — each entry has `Line`, `Offset`, `Path`, `Hits`; the `Path` whose `Hits == 0` is the uncovered edge, and offsets in ascending order map to the `?.` points left-to-right:

         ```
         dotnet test --filter "FullyQualifiedName~{FeatureName}" \
           -p:CollectCoverage=true -p:CoverletOutputFormat=json \
           -p:CoverletOutput=./TestResults/j/cov.json \
           -p:Include="[SISApi.API]*{FeatureName}*"
         ```

         Then read `cov.json` → `<module> → <file> → <class> → <method>.Branches[]`. An entry like `Offset 298, Path 0, Hits 0` on the `GetApimNextUrl` line is the middle `?.` (the `HttpContext == null` short-circuit) never taken — fix it with the "`HttpContext` null" test above and re-measure.
    - Do **NOT** `git add`, `git stage`, or `git commit` anything. Per the Hard Prohibitions, every generated file must remain visible to the user as untracked or modified in the working tree on `story/{id}`.
    - **Print a clean file-change summary to the log** so the user knows exactly what to review. Format:

        ```
        TICKET {id} FILES GENERATED (uncommitted on branch story/{id}):
          A  src/Applications.SISApi/SISApi.API/Features/People/{FeatureName}/Queries/Get{FeatureName}V1Query.cs
          A  src/Applications.SISApi/SISApi.API/Features/People/{FeatureName}/Shared/{FeatureName}Input.cs
          A  src/Applications.SISApi/SISApi.API/Features/People/{FeatureName}/Shared/{FeatureName}Output.cs
          A  src/Applications.SISApi/SISApi.API/Features/People/{FeatureName}/{FeatureName}Controller.cs
          A  src/Applications.SISApi/SISApi.API/Models/References/AcademicYearReference.cs
          A  src/Applications.SISApi/SISApi.APITests/Features/People/{FeatureName}/...
          A  src/Applications.SISApi/SISApi.Tests/Features/People/{FeatureName}/...
          M  src/Applications.SISApi/SISApi.API/Assets/PublicChangeLog.md
          M  src/Applications.SISApi/SISApi.API/Extensions/DependencyInjectionExtensions.cs
        ```

        Generate the list by running `git status --porcelain` and **excluding the user's pre-existing WIP** (the snapshot you recorded in pre-flight step 4). The user's WIP entries are theirs, not yours — do not include them in the summary.
    - **Sanity check (do not skip):** run `git status --porcelain`, subtract the pre-existing WIP, and confirm the remaining entries match what `.claude/commands/GWEndpointsGenerator/generate-get-endpoint.md` says you should have produced. If any expected file is missing, OR any unexpected file is present, log `FAILED (file-set mismatch: <details>)`. Do NOT try to "clean up" by deleting files — the user will resolve it manually.

11. **STOP HERE.** Do NOT push, commit, switch branches, or invoke `gw-pr-creator`. Stay on `story/{id}` with all generated files visible in the working tree. Log: `READY (uncommitted): branch story/{id} created off origin/main; {N} files added, {M} files modified; coverage line={x}% branch={y}% — awaiting user review`.

12. **Single-ticket policy reminder:** after processing the chosen ticket, **do NOT loop to the next ticket** (per the single-ticket-per-run policy at the top of this prompt). Move to the Exit Behavior section.

## Exit behavior

**Do NOT switch back to main** — the user wants their repo left on `story/{id}` with the generated files visible in the working tree.

Print a final summary in this exact format:

```
Processed: {chosen-id}
Skipped queued (one-at-a-time policy): {list of other-active-ids, comma-separated, or "none"}

Result:
  - {chosen-id}: READY (uncommitted on story/{id}; {N} added, {M} modified)
    OR
  - {chosen-id}: SKIPPED (PR already exists on origin)
  - {chosen-id}: SKIPPED (branch story/{id} already exists locally)
  - {chosen-id}: FAILED (ticket parse: <reason>)
  - {chosen-id}: FAILED (build)
  - {chosen-id}: FAILED (coverage: <class> line=<x>% branch=<y>%)
  - {chosen-id}: FAILED (file-set mismatch: <details>)
  - {chosen-id}: FAILED ({short reason})

Repo is now on branch: story/{chosen-id}  (or "main" if no ticket was processed)
Files to review:
  <list each generated file path, A=added, M=modified, one per line>

Next steps for the user:
  - To review:               git diff origin/main      (shows everything generated)
  - To commit + push:        git add <files>; git commit -m "AB#{id} [ExternalAPIGW] GET: {Domain} - {Resource} Endpoint"; git push -u origin HEAD
                             (use `git push -u origin HEAD` — it pushes to a same-named remote branch and sets upstream correctly; a plain `git push` may fail because this branch has no upstream yet)
  - To discard:              git checkout -- .; git clean -fd src/; git checkout main; git branch -D story/{id}
```

- Log every step with an ISO timestamp.
- Exit with status 0 on completion. Failures should be logged with enough context to debug, not crash the run.
- The `story/{id}` branch and its uncommitted files stay in the user's main repo. Branch deletion and cleanup are the user's call — the wrapper will refuse to start a NEW run while a previous run's `story/*` branch still has uncommitted files (you don't need to enforce that yourself; the wrapper does).
