You are running as a Windows scheduled task. Your job is to **scaffold the Gateway GET endpoint code locally** for **every** eligible active Azure DevOps ticket assigned to **you** — i.e. the identity that owns `ADO_PAT` (`@Me` resolves to whoever is running this). **Do not commit, do not push, do not open a PR.** Generate the files in the working tree on a **single** `story/...` branch and stop — the user reviews the modified/added files in their IDE and decides whether to commit + push, or discard.

**⚠️ The wrapper appends a "Runtime inputs" block to the END of this prompt. That block is AUTHORITATIVE for this run** — it carries the ADO org/project, the current sprint, the exact **target branch name**, the **branch mode** (`create`/`reuse`), and the **list of eligible tickets**. Use those IDs and that exact branch name. Do not re-derive the eligible set and do not invent a different branch name.

**All-tickets-one-branch policy.** Process **every** ticket in the Runtime inputs list, in ascending ID order, and put all of them on the **one** branch the wrapper assigned. The branch is named after every ticket it carries — a single ticket gives `story/{id}`, several give `story/{id1}_{id2}_{id3}` (ascending, underscore-separated). One branch means the user's eventual push is **one PR** covering the whole sprint's Gateway work instead of one PR per ticket.

- Never create a second branch mid-run, and never switch away from the assigned branch between tickets.
- A ticket that fails is **isolated**: log `TICKET {id} FAILED (<reason>)`, leave whatever it produced in place, and continue to the next ticket. One bad ticket must not abort the run or discard another ticket's work.
- Every ticket in the list must end with exactly one `TICKET {id} READY` or `TICKET {id} FAILED (<reason>)` line. The wrapper greps for these to report per-ticket progress; a ticket with no verdict is reported as a defect.

## Autonomy override (explicit user authorization)

The user has **explicitly authorized this scheduled task to run autonomously up to the point of a local commit**, overriding the following rules from `.claude/CLAUDE.md`:

- The "Endpoint Delivery Lifecycle" state machine — DO NOT apply
- Gate A (PROPOSED → APPROVED) — DO NOT pause for user approval; proceed directly to local implementation
- Gate B (READY → PUSHED) — **the gate stays closed**. You are NOT authorized to push or open a PR. Stop at READY.

Other rules from `.claude/CLAUDE.md` STILL APPLY: no rebase, no force-push, no branch-delete, ADO state ceiling stays where it is for **every ticket** you process (do not advance any story's state — the user will move them manually if/when they push).

Two narrow exceptions:
1. **Step 11 — test-case association**, which sets the automation fields (and `State`) on the **Test Case** work items the generated integration tests implement. Those are different work items from the tickets; the tickets' own state ceilings are untouched.
2. **`git merge --no-edit origin/main` in Step 3's `reuse` path only.** This is the single permitted merge: a fast-forward of the reused target branch up to `origin/main`, which the wrapper has already verified cannot conflict (it only selects `reuse` when `origin/main` is an ancestor). It is not a general licence to merge — no merging between story branches, no merging to bring in someone else's work, and if it conflicts you abort it rather than resolve it. The blanket no-merge rule still applies everywhere else.

## Hard prohibitions (the run FAILS if you do any of these)

- ❌ NO `git push` of any kind, to any remote, for any branch
- ❌ NO `gh pr create` / `mcp__github__create_pull_request` / opening a draft PR / publishing a PR
- ❌ NO ADO state changes **to the ticket** (or any story/Feature/task work item)
  - ✅ **Single carve-out:** Step 11 may PATCH the **automation fields of existing Test Case work items** in the **`Test Case Global Repo`** project (`AutomatedTestName`, `AutomatedTestStorage`, `AutomatedTestId`, `AutomationStatus`, and that test case's own `System.State` → `Automated`). That is the only ADO write permitted. It **creates no work items**, never touches the ticket, and never runs on a defaulted/invented TestCaseId.
- ❌ **NO `git add`, `git commit`, or any staging/commit operation.** The user wants to review the modified and added files in their IDE *before* any commit happens. Leave every generated file uncommitted in the working tree on the run's target branch.
- ❌ NO `git stash`, `git reset --hard`, `git restore`, `git clean`, or anything that could discard files. The user's uncommitted WIP and the files you just generated must all stay visible in the working tree.
- ❌ NO `git checkout main` (or any branch switch) after you've created the target branch. Stay on it at exit so the user finds their repo on that branch with every ticket's generated files visible.
- ❌ NO creating a second branch mid-run. All tickets share the one branch from the Runtime inputs block — that is what makes them a single PR.
- ❌ NO reverting, deleting, or `git checkout`-ing a file another ticket in this run generated or modified. A failing ticket cleans up **only its own** changes (and only via `Edit`).
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

## Step 1 — Confirm the ticket list from Runtime inputs

**The wrapper has already done the discovery.** It resolved the current sprint for project=`ColdFusion` / team=`Modernization Team`, ran the WIQL for `State = Active` AND `AssignedTo = @Me` AND `Title CONTAINS 'ExternalAPIGW'`, and handed you the resulting IDs + titles in the Runtime inputs block. It also already exited early (before any git work) if that set was empty — so if you are reading this, there is at least one ticket to do.

Your job here is **confirmation, not re-discovery**:

1. Read the ticket list from the Runtime inputs block. That is the set to process — all of it.
2. For each ticket, fetch `id`, `System.Title`, and the Domain/Resource info from the System Info / Technical Requirements fields (the full-fidelity fetch happens per-ticket in step 9a).
3. **Title filter (safety net):** confirm each `System.Title` still contains the literal string `ExternalAPIGW` (case-insensitive). If one does not, log `SKIP (not ExternalAPIGW): {id} - {title}` and drop it — but do not go looking for replacements.
4. Do **not** run your own iteration/WIQL query to expand or second-guess the list, and do **not** apply any "process one at a time" rule. Every ticket in the block gets processed this run.

### ⚠️ Azure DevOps MCP tool names — use the CONSOLIDATED tools

The ADO MCP server exposes a small set of **consolidated** tools that take an `action` argument. The older per-action names do **not** exist and calling them wastes a round-trip:

| Do NOT use (no longer exists) | Use instead |
|---|---|
| `work_list_iterations`, `work_list_team_iterations` | `mcp__azure__work` |
| `wit_query_by_wiql` | `mcp__azure__wit_query` with `action: "wiql"` **and** a `wiql` argument |
| `wit_get_work_item`, `wit_get_work_items_for_iteration`, `wit_get_work_item_type` | `mcp__azure__wit_work_item` |
| `testplan_list_test_suites`, `testplan_list_test_cases` | `mcp__azure__testplan` |
| `wiki_get_page_content` | `mcp__azure__wiki` |

**Never guess an `action` value.** A past run inferred `action: "by_wiql"` from the old tool name and got `Invalid enum value ... options: ["get","get_results","wiql"]`, then a second failure for a missing `wiql` argument. If a tool rejects your arguments with an invalid-enum or missing-argument error, `ToolSearch` for that tool's real schema **before** retrying — do not brute-force action names.

## Step 2 — Pre-flight

Run these read-only checks before touching the working tree:

1. Confirm `Get-Location` (or `pwd`) returns exactly `{{REPO_ROOT}}`. If not, log `FATAL: not running in user's main repo` and exit immediately.
2. Confirm `git rev-parse --abbrev-ref HEAD` returns `main`. If not, log `FATAL: not on main branch` and exit — the wrapper should have left you on main; if you're not, something is wrong.
3. Confirm `git rev-parse HEAD` matches `origin/main`. If not, log a warning and exit.
4. Record the list of currently-uncommitted files via `git status --porcelain` and stash that list in memory as **`WIP_BEFORE`**. You'll use it to attribute generated files per ticket (step 10) and at the end to verify the user's WIP was preserved.

## Step 3 — Get onto the target branch (ONCE, before any codegen)

Use the **exact branch name AND `Branch mode`** from the Runtime inputs block. The wrapper already resolved a safe name — it reuses an existing branch only when that is safe (origin/main is still an ancestor, so a merge cannot conflict), otherwise it hands you a unique `-2`/`-3` name. Do NOT invent a different name, and do NOT check branch existence yourself.

- **`create`** (the name is guaranteed free) — make it fresh off the latest `origin/main`:
  ```
  git checkout --no-track -b <targetBranch> origin/main
  ```
  Use `-b` (create-only), **never `-B`** — `-B` would reset/clobber a branch. **`--no-track` is REQUIRED**: branching off a remote-tracking ref otherwise makes git set the new branch's upstream to `origin/main`, which later breaks the user's `git push` (with `push.default=simple` git refuses because the local name ≠ upstream name `main`). `--no-track` leaves no upstream, so the user's first `git push -u origin HEAD` sets tracking correctly.

- **`reuse`** (continue on an existing branch the wrapper judged safe) — switch on WITHOUT resetting, then bring it up to date:
  ```
  git switch <targetBranch>
  git merge --no-edit origin/main
  ```
  The wrapper only picks `reuse` when `origin/main` is already an ancestor, so this should fast-forward cleanly. **If it reports a conflict anyway, do not resolve it** — `git merge --abort`, then `git checkout --no-track -b <targetBranch>-2 origin/main` (bump the suffix until unused) and continue there.

Log which branch you actually ended up on. **This branch carries every ticket in the run** — you create it once here and stay on it until exit.

## For each active ticket

Now loop over the tickets from the Runtime inputs block, **ascending by ID**, staying on the branch from Step 3. Steps 9–12 below run once **per ticket**.

**Per-ticket failure isolation.** If a ticket fails at any step, log `TICKET {id} FAILED (<reason>)`, leave whatever it already wrote on disk, and move to the next ticket. Specifically, when a ticket fails you must NOT: abort the run, `git checkout main`, create another branch, revert or delete another ticket's files, or undo another ticket's `.csproj` bump.

9. **Strict ticket parse (MANDATORY before any codegen — past runs scaffolded from reference files and silently invented properties / skipped test suites).** Do this *before* writing any file for this ticket. If any required artifact is missing or unparseable, log `TICKET {id} FAILED (ticket parse: <reason>)` and continue to the next ticket without writing anything for it. (The branch already exists from Step 3 — do not create or switch branches here.)

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
        - If it is an **ADO wiki link** (`/_wiki/wikis/.../{page}`), parse out the wiki + page path and fetch with `mcp__azure__wiki`.
        - If it is an **ADO test plan / suite link** (`/_testPlans/...`), parse the `planId` and `suiteId` and call `mcp__azure__testplan` (suite list, then case list) to enumerate every test case (capture each `TestCaseId`, `Title`, and the suite it lives in).
        - If it is a **related work item** (e.g. parent Test Case), call `mcp__azure__wit_work_item` and pull its Steps / Title.

        (These are the **consolidated** tool names from the mapping table above. The retired per-action names — `wiki_get_page_content`, `testplan_list_test_suites`, `testplan_list_test_cases`, `wit_get_work_item` — no longer exist; per that table's rule, `ToolSearch` the real schema before choosing an `action`.)
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
          Total: {n} test cases
        ```

        **The trailing `Total: {n} test cases` line is MANDATORY and must be the literal words `Total: <number> test cases`** — the wrapper greps for exactly that to report the mapped-case count in its milestone. Emit the header and this total verbatim in the shape above; do not reformat them.

        **Scope the `mcp__azure__testplan` call to the specific `suiteId`** you parsed from the Testing Considerations link, and request only the fields you need (`id`, `title`). Listing a whole plan returns tens of thousands of characters, overflows the tool-result limit, spills to a file on disk, and costs a recovery `Grep` — that happened on a past run with an 86,015-character payload.

        **If a `testplan` result still overflows, do not repeat the same call for the next ticket.** On 2026-08-03 three separate calls overflowed back-to-back (93,983 / 86,042 / 96,339 chars) before the agent switched strategy. After the *first* overflow, read the id/title pairs straight out of the spill file the tool names in its error message and use that path for the remaining tickets:
        `grep -oE '"(id|name)": *"?[^",]+' <spill-file>`

        If the ticket has NO Testing Considerations link AND no inline test-suite list, log `WARN (ticket {id}): no Testing Considerations link found — falling back to default suites from generate-get-endpoint.md` and proceed; do NOT fail the ticket on this alone. If a link exists but is unreachable / 404 / requires interactive auth, log `FAILED (ticket parse: Testing Considerations link unreachable: <url>)` and continue to the next ticket — do NOT silently substitute defaults when a link was explicitly provided.

10. **Scaffold the endpoint on the existing branch.** You are already on the run's target branch from Step 3 — **do not create, switch, or reset a branch here.** Follow `.claude/commands/GWEndpointsGenerator/generate-get-endpoint.md` exactly — that file is the **single authoritative codegen reference**. Do NOT invoke the `gw-endpoint-orchestrator`, `gw-endpoint-cloner-get`, `gw-build-fixer`, or `gw-pr-creator` skills. (`gw-test-associator` is no longer on this list — Step 11 now runs its script directly; see Step 11 for why the skill itself is still not *invoked*.) Read `.claude/commands/GWEndpointsGenerator/generate-get-endpoint.md` from disk and execute its Steps 1, 2, and 3 (Extract User Story Information → Generate Code Components → Generate Test Files) for the ticket id from Step 1. Apply its Integration Test Rules, Unit Test Rules, Reference Object Rules, and Endpoint Validation Checklist as-is.

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

       **This command usually fails in a scheduled headless run** — the credential provider cannot prompt, so the feed answers `401 (Unauthorized)` (seen twice on 2026-08-03). That is **not** grounds to declare the ticket blocked. Fall back to the local package cache, which the last authenticated `restore` already populated, and take the highest version directory there:
       `ls ~/.nuget/packages/sis.<domain>.service.client/ | sort -V | tail -5`
       Verify the types in that version's DLL per step 4 before bumping. Only if neither the feed nor the cache exposes a newer version may you follow step 5.
    3. **Bump the PackageReference** for that client in `SISApi.API.csproj` to the latest internal version, then `dotnet restore src/Applications.SISApi/Applications.SISApi.sln` from the repo root (restore reads the repo nuget.config, so it authenticates against the internal feed via the configured credential provider). This csproj bump is an expected local change — leave it **uncommitted** in the working tree like every other generated file.
    4. **Verify the required types now exist** before continuing codegen/build: locate the restored assembly at `~/.nuget/packages/sis.<domain>.service.client/<version>/lib/net8.0/*.Service.Client.dll` and grep for the exact type name(s) you need, e.g. `grep -aoE '{Resource}[A-Za-z0-9_]*' <dll> | sort -u`. Confirm the plain GET types are present — do NOT mistake a similarly-named sibling for the real type (e.g. `OARequestInfo*` GET types vs the unrelated `OARequestInfoTrack*` types). (`strings` is not installed on this Windows host — use `grep -a`.)

       If you need more than type *names* — exact DTO property names/types, or which DTO a `Get{Resource}V1Async` actually returns — load the assembly by reflection **from the build output**, not from the nuget cache: `src/Applications.SISApi/SISApi.API/bin/Debug/net9.0/<Domain>.Service.Client.dll`. Reflecting on the cache copy fails dependency resolution (its transitive deps are not side-by-side) and spilled a 198 KB `MethodInvocationException` on 2026-08-03. So: bump → `dotnet build` → reflect.

       **NSwag naming quirk — check the element type, do not trust the wrapper's name.** `PagedResultOf{Resource}Dto.Results` is not necessarily `List<{Resource}Dto>`; on 2026-08-03 `PagedResultOfOAFormCompletedDto.Results` was `List<OAFormCompletedDto2>`, and only `Dto2` matched the ticket spec. When two same-prefixed DTOs exist, reflect over `.Results` to resolve the real element type before mapping, and note it in the summary.
    5. **Only declare the ticket blocked if the LATEST version on the INTERNAL feed still lacks the types.** In that case log `TICKET {id} FAILED (upstream client missing: <package> <latest-internal-version> lacks <types>)`, note that the parent MS story's client NuGet has not been re-published yet, revert **only this ticket's own** csproj bump (via `Edit`, not a destructive git op), and continue. Never conclude "blocked" from a nuget.org-only check.

    6. **⚠️ Bumps are CUMULATIVE across tickets — never undo another ticket's work.** Several tickets in one run may each need a different `SIS.<Domain>.Service.Client` bumped in the same `SISApi.API.csproj`. That file therefore accumulates edits as the run proceeds. Rules: re-read the csproj immediately before each bump (it may already have changed since the last ticket); change only the one `PackageReference` line your ticket needs; and when reverting a blocked ticket's bump, restore that single line to the version it had *when your ticket started*, never `git checkout`/`git restore` the file (that would wipe the earlier tickets' bumps too).

    After the codegen steps are complete:
    - Build the solution to verify there are no compile errors: `dotnet build src/Applications.SISApi/Applications.SISApi.sln` from the repo root. If errors, fix them and rebuild; loop up to 5 times before giving up and recording the ticket as `TICKET {id} FAILED (build)`. Leave the fixes uncommitted in the working tree like everything else. **Build per ticket, not once at the end** — that is what keeps a broken ticket from sinking the others. If the build breaks and the errors are in a *previous* ticket's files rather than yours, that is cross-ticket interference: fix it (both tickets need a green build) and note it in the summary.
    - **Coverage gate — 100% line AND 100% branch REQUIRED.** After the build is green, run the generated tests with coverage and confirm the code you generated for this ticket hits **100% line coverage AND 100% branch coverage** (both sides of every `if`/ternary/null-check/`??`/switch arm exercised) — measured only over the classes this ticket adds (the `Query` handler, the `Output`/`Input`/nested DTOs and their mapping, any `Reference` classes, and any non-`[ExcludeFromCodeCoverage]` wiring), not the whole solution. The Controller carries `[ExcludeFromCodeCoverage]` per `generate-get-endpoint.md` and is correctly excluded — do NOT strip that attribute to game the number, and do NOT add `[ExcludeFromCodeCoverage]` to a handler/DTO-mapper to dodge coverage.
      1. Measure with coverlet: `dotnet test src/Applications.SISApi/Applications.SISApi.sln --filter "FullyQualifiedName~{FeatureName}" /p:CollectCoverage=true /p:CoverletOutputFormat=cobertura /p:Include="[SISApi.API]*{FeatureName}*"`. If the repo already wires a `coverlet.runsettings` or `--collect:"XPlat Code Coverage"` path, discover and use that instead of inventing flags. Read `line-rate` **and** `branch-rate` for each generated class from the emitted `coverage.cobertura.xml`; both must be `1` (100%).
      2. If any line or branch is uncovered, it means a scenario from the step-9c enumeration (or the `generate-get-endpoint.md` default suites) is missing — **add the test** (empty/404 path, each validation branch, each nullable-field branch of the Output mapping) and re-run until both rates are 100%. The added test must assert real behavior, not merely execute the line.
      3. If a specific branch is genuinely unreachable (a defensive guard no valid input can hit), do not silently fall short: leave a `// TODO(AB#{id}): <branch> uncovered — <why>`, and record the class + line + achieved line%/branch% in the ticket summary. A ticket below 100% coverage without a logged, justified exception is `TICKET {id} FAILED (coverage: <class> line=<x>% branch=<y>%)`.
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
    - Do **NOT** `git add`, `git stage`, or `git commit` anything. Per the Hard Prohibitions, every generated file must remain visible to the user as untracked or modified in the working tree on the target branch.
    - **Print a clean file-change summary to the log** so the user knows exactly what to review. Format:

        ```
        TICKET {id} FILES GENERATED (uncommitted on branch <targetBranch>):
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

        **⚠️ Attribute files to the RIGHT ticket — subtract TWO sets, not one.** Because every ticket shares one branch, `git status --porcelain` accumulates as the run proceeds: by ticket 3 it also lists tickets 1 and 2's files. Naively subtracting only the pre-run WIP would make each ticket claim all its predecessors' work.

        Maintain a running set **`ATTRIBUTED_SO_FAR`**, starting empty. For each ticket:
        1. Run `git status --porcelain`.
        2. Subtract **`WIP_BEFORE`** (the user's pre-existing WIP from pre-flight step 4 — theirs, not yours) **and** subtract **`ATTRIBUTED_SO_FAR`** (everything already credited to an earlier ticket this run).
        3. What remains is *this* ticket's file set — report exactly that under `TICKET {id} FILES GENERATED`.
        4. Add those entries to `ATTRIBUTED_SO_FAR` before starting the next ticket.

        One nuance: a file both tickets touch (`SISApi.API.csproj`, `Assets/PublicChangeLog.md`, `Extensions/DependencyInjectionExtensions.cs`, the regenerated `tools/apim-templates/**` nswag json) stays in `ATTRIBUTED_SO_FAR` after the first ticket claims it, so later tickets won't re-list it. That is correct for the per-ticket lists; the **final** summary's combined file list is the union of all of them plus these shared files, so nothing is lost.
    - **Sanity check (do not skip):** run `git status --porcelain`, subtract `WIP_BEFORE` **and** `ATTRIBUTED_SO_FAR` as above, and confirm the remaining entries match what `.claude/commands/GWEndpointsGenerator/generate-get-endpoint.md` says you should have produced for **this** ticket. If any expected file is missing, OR any unexpected file is present, log `TICKET {id} FAILED (file-set mismatch: <details>)`. Do NOT try to "clean up" by deleting files — the user will resolve it manually, and a delete could destroy another ticket's output.

11. **Associate this ticket's integration tests to their ADO test cases.** Once **this ticket's** build is green and its coverage gate has passed, link each `[TestCaseId("...")]`-annotated integration test method back to the ADO Test Case it implements, so the Test Case flips to `Automated` and points at the real method. This is the **only** ADO write this run performs (see the carve-out in Hard prohibitions) and it **updates existing test cases only — it never creates one**. Run it **once per ticket**, against that ticket's own integration-test file only — never re-run it for a file an earlier ticket already associated.

    **11a. Gate — run it only if ALL of these hold.** If any fails, log a WARN, skip the association, and go to step 12. A skipped association is **never** a ticket failure and never changes the `READY` verdict:

    - **The TestCaseIds are REAL — i.e. they came from the step-9c enumeration.** ⚠️ **If step 9c took the `WARN` path and the TestCaseIds were defaulted from `generate-get-endpoint.md`, do NOT associate.** Those are placeholder IDs the user is expected to fill in before pushing (step 10 logs `TestCaseIds defaulted (no Testing Considerations link)`); PATCHing them either 404s or, worse, writes automation fields onto an unrelated real work item. Skip and log `ASSOCIATE SKIPPED: TestCaseIds were defaulted, not enumerated from Testing Considerations`.
    - **Build green and coverage gate passed.** Never associate a red test — a Test Case marked `Automated` pointing at a failing method is worse than one left in `Design`. If the ticket is `FAILED (build)` or `FAILED (coverage: …)`, skip.
    - **`az` is authenticated** — check `az account show --query user.name -o tsv`. ⚠️ **You are a non-interactive scheduled task — do NOT run `az login`** (the `gw-test-associator` skill prompts the user to; you have no user to prompt). It would block on a browser prompt until the task times out. On failure/empty, skip and log `ASSOCIATE SKIPPED: az not authenticated — run 'az login --scope 499b84ac-1321-427f-aa17-267ca6975798/.default' and re-associate manually`.
    - **Every generated `[TestCaseId(...)]` maps 1:1 to an enumerated case** per the step-10 mapping. If any test method is tagged `TODO` in that mapping, skip the file and log which.

    **11b. Resolve the script — it is IN THIS REPO; do NOT use the plugin copy.** Use the first path that exists:

    ```powershell
    $assocCandidates = @(
        '{{REPO_ROOT}}\.claude\skills\_shared\scripts\AssociateTestScript.ps1',
        '{{REPO_ROOT}}\.windsurf\workflows\Development\AssociateTests\AssociateTestScript.ps1'
    )
    $assocScript = $assocCandidates | Where-Object { Test-Path $_ } | Select-Object -First 1
    ```

    ⚠️ **Do NOT substitute the sis-pdlc-plugin copy** (`…\resources\scripts\associate-test-scripts-to-testcases\associate-test-script.ps1`). It is *not* equivalent: it lacks the `SISApi\.APITests` branch in its service-name detection, so for a Gateway integration-test path it leaves `$serviceName` blank and exits 1 with *"Some variables (Filename, Classname, Namespace, ServiceName) are blank"*. Only the two in-repo copies above handle `SISApi.APITests`. Verified 2026-07-29. If neither exists, log `ASSOCIATE SKIPPED: AssociateTestScript.ps1 not found in repo` and continue — do **not** hand-roll the PATCH calls.

    **11c. Run it — once, on the generated integration test file.** Associate the **integration tier only** (`src/Applications.SISApi/SISApi.APITests/Features/…/…Tests.cs`). The unit tests under `SISApi.Tests/` are not associated.

    ```powershell
    & $assocScript -FilePath '<ABSOLUTE path to the SISApi.APITests .cs file>' -Mode 'Associate' -Org 'renweb' -Project 'Test Case Global Repo'
    ```

    - **`-FilePath` MUST be a full absolute path** starting with the drive letter. The script calls `Resolve-Path` and derives namespace + class from the file; a relative path makes it exit 1.
    - **`-Project` is `Test Case Global Repo`**, *not* `ColdFusion` — test cases live in that project. Keep the quotes (the space is URL-encoded by the script).
    - **Run it ONCE and wait for it to finish — do NOT re-run it.** Each run assigns a fresh `AutomatedTestId` GUID, and the script makes one sequential REST call per test case (allow up to 5 minutes). Interrupting or re-running just churns the work items.
    - This is the same command `.claude/skills/gw-test-associator/SKILL.md` documents — read that file if you need detail on the output format. Run the script **directly** rather than invoking the skill: the skill is written for an interactive session (it asks the user which file to pick and prompts for `az login`), neither of which works headless.

    **11d. Report.** The script prints an association phase and a validation table. Capture its `=== SUMMARY ===` counts and confirm every row shows `State = Automated` / `Automation Status = Automated` with no `ERROR`. Emit:

    ```
    ASSOCIATE {id}: <n> cases — <s> succeeded, <f> failed
    ```

    or `ASSOCIATE SKIPPED ({id}): <reason>`. Failures are **non-fatal**: log them, keep the generated code, surface them in the final summary, and do **not** retry more than once.

12. **Record this ticket's verdict, then move to the next ticket.** Do NOT push, commit, switch branches, or invoke `gw-pr-creator`. Stay on the run's target branch with all generated files visible in the working tree. Emit exactly one verdict line for this ticket:

    ```
    TICKET {id} READY (uncommitted on <targetBranch>; {N} files added, {M} files modified; coverage line={x}% branch={y}%)
    ```

    or, on any failure:

    ```
    TICKET {id} FAILED (<reason>)
    ```

    The literal prefix `TICKET {id} READY` / `TICKET {id} FAILED` is required — the wrapper greps for it to track per-ticket progress.

13. **Loop to the next ticket.** Repeat steps 9–12 for the next ticket in the Runtime inputs list (ascending ID), on the **same** branch. When every ticket has a verdict, run one final whole-solution `dotnet build src/Applications.SISApi/Applications.SISApi.sln` to confirm the tickets do not conflict with each other (shared files like `DependencyInjectionExtensions.cs`, `PublicChangeLog.md`, or the `.csproj` can interact). Log `FINAL BUILD: SUCCESS` or `FINAL BUILD: FAIL (<errors>)`. If it fails, fix it if you can and say which tickets were involved — do not revert anyone's work. Then move to the Exit Behavior section.

## Exit behavior

**Do NOT switch back to main** — the user wants their repo left on the target branch with every ticket's generated files visible in the working tree.

Print a final summary in this exact format (one line per ticket, in ascending ID order):

```
Processed: {id1}, {id2}, {id3}      ({n} of {n} tickets from Runtime inputs)

Result:
  - {id1}: READY (uncommitted; {N} added, {M} modified; coverage line=100% branch=100%)
  - {id2}: FAILED (ticket parse: <reason>)
  - {id3}: READY (uncommitted; {N} added, {M} modified; coverage line=100% branch=100%)
    (other possible verdicts per ticket:)
    FAILED (build) | FAILED (coverage: <class> line=<x>% branch=<y>%)
    FAILED (file-set mismatch: <details>) | FAILED (upstream client missing: <pkg> <ver> lacks <types>)
    SKIP (not ExternalAPIGW): <title>

FINAL BUILD: SUCCESS | FAIL (<errors>)

Test-case association (ADO 'Test Case Global Repo'):
  - {id1}: <s>/<n> associated
  - {id2}: SKIPPED — <reason>
  - {id3}: <s>/<n> associated

Upstream client bumps (uncommitted in SISApi.API.csproj):
  - <package> <old> → <new>   (needed by {id})     (or "none")

Repo is now on branch: <targetBranch>   (all {n} tickets share this ONE branch → ONE PR)
Files to review ({total} files across {n} tickets):
  <combined list, grouped by ticket, A=added M=modified, one per line>
  <shared files touched by more than one ticket, noted as such>

Next steps for the user:
  - To review:               git diff origin/main      (shows everything generated, all tickets)
  - To commit + push:        git add <files>
                             git commit -m "AB#{id1} AB#{id2} AB#{id3} [ExternalAPIGW] GET endpoints: <Resource1>, <Resource2>, <Resource3>"
                             git push -u origin HEAD
                             (use `git push -u origin HEAD` — it pushes to a same-named remote branch and sets upstream correctly; a plain `git push` may fail because this branch has no upstream yet)
                             (ADO links every AB#<id> in the commit message to its ticket — include ALL of them so each ticket gets the artifact link, not just the first)
  - To commit tickets separately instead:  git add <that ticket's files>; git commit -m "AB#{id} ..."   (repeat per ticket, then one push)
  - To associate skipped/failed test cases:  /gw-test-associator <path to the SISApi.APITests file>
                             (fill in the real TestCaseIds first if they were logged as defaulted)
  - To discard everything:   git checkout -- .; git clean -fd src/; git checkout main; git branch -D <targetBranch>
```

If a ticket produced nothing (failed at parse), still list it with its `FAILED` reason — a ticket silently missing from this summary is a defect.

- Log every step with an ISO timestamp.
- Exit with status 0 on completion. Failures should be logged with enough context to debug, not crash the run.
- The target branch and its uncommitted files stay in the user's main repo. Branch deletion and cleanup are the user's call — the wrapper will refuse to start a NEW run while a previous run's `story/*` branch still has uncommitted files (you don't need to enforce that yourself; the wrapper does).
- **Exit with status 0 even when some tickets failed.** A per-ticket failure is reported in the summary, not by crashing the run — the other tickets' work must survive.
