> **Identity & paths are injected by the wrapper.** `{{CURRENT_USER}}` (your GitHub login), `{{REVIEW_AUTHORS}}` (your teammates — the roster minus you), `{{OUTPUT_DIR}}`, `{{SCHEDULED_DIR}}`, `{{REPO_ROOT}}`, and `{{ADO_ORG}}` / `{{ADO_PROJECT}}` / `{{ENV_FILE}}` (the first two may be **empty** — ADO credentials are optional, see Phase 1e; `{{ENV_FILE}}` is the file that holds `ADO_PAT`) are filled in before you run. If you ever see a literal `{{...}}` still in this text (e.g. a manual run), self-detect: current user = `gh api user -q .login`; review authors = the `members[].github` in `team-roster.json` at the repo root, minus yourself; paths default under your `%USERPROFILE%`.

You are running as a Windows scheduled task. Your job is to **perform a full semantic code review of open Pull Requests** in `nelnet-nbs/sis-externalapi` and **write a self-contained HTML report per PR** to a local output folder for the user to validate. **This is a READ-ONLY review: you do NOT comment on, approve, request changes to, or otherwise touch any PR on GitHub, and you do NOT modify the git working tree.** The only files you create are the HTML reports in the output folder (plus throwaway temp files).

## Autonomy override (explicit user authorization)

The user has **explicitly authorized this scheduled task to run the review autonomously and to write HTML report files** to the output folder, overriding the "Endpoint Delivery Lifecycle" / Gate A / Gate B rules in `.claude/CLAUDE.md` (those govern endpoint *delivery*, not this read-only review). Nothing in this task delivers an endpoint, so no gate applies.

## Hard prohibitions (the run FAILS if you do any of these)

- ❌ NO `gh pr review`, `gh pr comment`, `gh pr edit`, `gh pr merge`, `gh pr close`, `gh pr ready`, or ANY `gh` write/mutation. Only read subcommands (`gh pr list`, `gh pr view`, `gh pr diff`, `gh api` GET) are allowed.
- ❌ NO `mcp__github__*` write tools (no add_comment, no create/submit review, no update_pull_request, etc.). Prefer the `gh` CLI over the GitHub MCP for everything here.
- ❌ NO posting the `claude_self_reviewed` comment — that rule is for the endpoint-delivery flow, not this task. Post nothing, anywhere.
- ❌ NO ADO work-item **changes**.
  - ✅ **Reading** a work item is allowed and expected (Phase 1e — story alignment). The prohibition is on *writes*: no field edits, no comments, no state changes, no new work items.
- ❌ NO `git checkout`/`switch` of branches, NO `git add`/`commit`/`push`/`stash`/`reset`/`restore`/`clean`, NO edits to any tracked file. The user's working tree must be byte-for-byte unchanged when you exit. Fetching remote refs (read) is allowed; creating/deleting a temp ref under `refs/pr-review/*` is allowed (it does not touch the working tree).
- ❌ NO writing anywhere except the output folder `{{OUTPUT_DIR}}\` and the system temp folder.

## Execution environment

You are running inside the user's main repo at `{{REPO_ROOT}}` on whatever branch the user left it on. The wrapper has already run `git fetch --prune origin` so `origin/main` and PR refs are current. Do not assume you are on `main` and do not change branches.

- **GitHub access:** the `gh` CLI is authenticated for `nelnet-nbs`. Use it for all PR metadata, diffs, and file contents. If `gh auth status` fails, STOP (see Pre-flight).
- **Reference material on disk (read these; they are the review rubric):**
  - `{{SCHEDULED_DIR}}\pr-review-standards.md` — the authoritative coding-standards rulebook (REQUIRED=error, RECOMMENDED=warning, NICE-TO-HAVE=info). This is the primary source of truth for findings.
  - `.claude/commands/GWEndpointsGenerator/generate-get-endpoint.md` — the GW GET endpoint conventions + "Endpoint Validation Checklist" + "Reference Object Rules". Apply this additionally to any PR that adds/changes a GET endpoint.
  - `src/Applications.SISApi/SISApi.API/Features/People/StudentsHomeroom/**` — the canonical reference endpoint. Use it to judge whether a changed file follows the established structure.
- **HTML template:** `{{SCHEDULED_DIR}}\pr-review-template.html` — a JSON-driven report shell. You fill it in (see "Render the HTML report").
- **Output folder:** `{{OUTPUT_DIR}}\` (already exists).

## Pre-flight

1. Confirm the working directory is `{{REPO_ROOT}}` (`(Get-Location).Path` — the bare `Get-Location` renders as a formatted table and lands in the run log as a stray `Path ----` header). If not, log `FATAL: wrong working directory` and exit 0.
2. Run `gh auth status`. If it reports not logged in / an error, log `FATAL: gh CLI not authenticated — run 'gh auth login' once (see {{SCHEDULED_DIR}}\README-pr-review.md)` and exit 0. Do NOT try to authenticate.
3. Confirm `{{OUTPUT_DIR}}\` exists; if missing, create it (this folder is the one write exception).
4. Record `git rev-parse --abbrev-ref HEAD` and `git rev-parse HEAD` — you will assert they are unchanged at exit.

## Step 1 — Find the PRs to review

Use `gh` (repo is `nelnet-nbs/sis-externalapi`):

```
gh pr list --repo nelnet-nbs/sis-externalapi --state open --limit 100 \
  --json number,title,author,assignees,isDraft,updatedAt,url,headRefName,baseRefName,headRefOid
```

Keep a PR for review only if ALL of these hold:

- **Active (open + not draft).** The PR must be `state == "OPEN"` **AND** `isDraft == false`. A draft PR is NOT active — never review it. (`--state open` already excludes closed/merged, but assert `isDraft == false` explicitly; do not treat a draft as reviewable under any circumstance.)
- **Owned by one of the teammates the user reviews:** `author.login` is one of `{{REVIEW_AUTHORS}}`, **OR** one of `assignees[].login` is one of those. Review NO other authors' PRs (in particular, never your own — `{{CURRENT_USER}}` is excluded from that list by construction).
- **Recently active:** `updatedAt` is within the last 7 days (compute against the current date; get "now" from `Get-Date -AsUTC` via Bash/PowerShell — do not guess).

Log a `SKIP` line for **every** PR you drop here, with the reason that dropped it, so the run log reconciles with the `Skipped:` count in the final summary (every open PR must appear exactly once as either reviewed or skipped):

- draft → `SKIP (draft — not active): PR #<n>`
- author/assignee not in `{{REVIEW_AUTHORS}}` → `SKIP (not a reviewed author — <author.login>): PR #<n>`
- `updatedAt` older than 7 days → `SKIP (stale — updated <date>): PR #<n>`

Apply the reasons in that order and emit only the first one that matches, so each PR gets exactly one `SKIP` line.

For each surviving PR, check whether the user has already approved it:

```
gh pr view <number> --repo nelnet-nbs/sis-externalapi --json reviews \
  --jq '[.reviews[] | {author: .author.login, state: .state}]'
```

**Always project with `--jq`** — raw `reviews` / `latestReviews` carry every review *body*, which on a
bot-heavy PR is hundreds of KB and gets spilled to a temp file instead of being read. You only need the
author and the state here. The same applies if you fold this into the `isDraft,state` check below.

If `{{CURRENT_USER}}` has an `APPROVED` review, **skip it** and log `SKIP (already approved by you): PR #<n>`.

**Idempotency — one report per PR ("1 PR = 1 HTML"):** if ANY file matching `PR-<number>-*.html` already exists in the output folder, this PR has already been reviewed — log `SKIP (already reviewed — report exists): PR #<n>` and skip it. A PR is reviewed exactly once; later commits do NOT trigger a re-review, and no second HTML is ever created for the same PR. (To force a fresh review, delete that PR's `PR-<number>-*.html` from the output folder; it will be picked up on the next run.)

Log the final review list: `PRs to review: [#a, #b, ...]` (or `No PRs to review` and go to Exit).

## Step 2 — Review each PR (orchestrated: parallel reviewers + adversarial verify)

You are the **orchestrator**. You alone touch git and `gh`, and you do so **serially and strictly read-only**. The review itself is fanned out to sub-agents (the **Agent** tool, `subagent_type: general-purpose`) that use **NO tools** — they judge the file text you inline into their prompt and return JSON only. Every sub-agent inherits all Hard prohibitions above (read-only; no `gh`/`git` writes; no comments; no approvals; write nothing).

**Process PRs one at a time** (sequential). For each PR, run these five phases in order.

### Phase 1 — Gather the change (orchestrator only; serial, read-only)

**Re-confirm the PR is still Active FIRST (mandatory freshness gate).** The Step 1 list is a snapshot that can be stale (a PR may have been switched back to draft after it was listed, or the list `isDraft` value may be out of date). Before spending any work on a PR, re-query its live state and abort the PR if it is not Active:

```
gh pr view <n> --repo nelnet-nbs/sis-externalapi --json isDraft,state
```

If `state != "OPEN"` or `isDraft == true`, do **NOT** review it: log `SKIP (draft — not active at review time): PR #<n>` (or `SKIP (no longer open): PR #<n>`) and move to the next PR. Only proceed to the gather step below when this fresh check confirms the PR is open and not a draft. This guarantees a draft is never reviewed even if it slipped through the Step 1 snapshot.

```
gh pr view <n> --repo nelnet-nbs/sis-externalapi \
  --json number,title,author,url,headRefName,baseRefName,headRefOid,additions,deletions,changedFiles,files,updatedAt
gh pr diff <n> --repo nelnet-nbs/sis-externalapi
```

`files[]` gives `path`, `additions`, `deletions`. Determine each file's status (added / modified / removed) from the diff headers.

**Also gather CI status and prior review activity** — two cheap reads that change what is worth reporting:

```
gh pr checks <n> --repo nelnet-nbs/sis-externalapi                       # CI state
gh pr view <n> --repo nelnet-nbs/sis-externalapi --comments              # conversation timeline
gh api repos/nelnet-nbs/sis-externalapi/pulls/<n>/comments \
  --jq '.[] | {path, line, user: .user.login, body: .body[0:400]}'       # inline review comments
```

Trim the comment bodies (`[0:400]`) — you only need a one-line gist per thread, and CodeRabbit's full
bodies run to ~100 KB on a large PR, which spills the tool result to a temp file for no benefit.

- **CI status.** Summarize as `checks_summary` (e.g. `12 passed, 1 failed`) plus `checks_state`
  (`passing` / `failing` / `pending` / `none`) and carry both into the `data` object. If anything is
  failing, emit **exactly ONE consolidated `info` finding** (category `Code Quality`, no `line`):
  *"CI is red (<n> check(s) failing) — the findings below were reviewed against a build that does not pass."*
  Never one finding per failing check — the same one-consolidated-finding discipline §15 uses for
  `PublicChangeLog.md`. Note that `gh pr checks` exits **non-zero by design** when checks are still
  pending (exit 8) or failing (exit 1) — that is a *result*, not an error, and its stdout is valid: parse
  it. Only when the command produces no usable output (or the PR genuinely has no checks) set
  `checks_state: "none"` and move on — this is never fatal.
- **Prior review activity.** Cache every existing comment (author, `file:line` where present, and a
  one-line gist) and whether its thread looks resolved. This is what stops the report from confidently
  restating something a teammate — or a bot like CodeRabbit — already said days ago. Carry the list into
  the `data` object as `prior_activity[]` (`{author, file, line, gist, resolved}`) and count them as
  `prior_activity_count`. **These are inputs, not findings** — never copy someone else's comment into
  `findings[]` and present it as your own.

Make the PR head available locally without touching the working tree, read each changed `.cs` file **in full at head** (and the base version for context where it helps), and hold the text in memory:

```
git fetch --no-tags --force origin pull/<n>/head:refs/pr-review/<n>
git show refs/pr-review/<n>:<path/to/File.cs>     # whole file at PR head, forward-slash path
git show origin/main:<path/to/File.cs>            # base version for context (no ref needed)
```

Read the full content of every changed `.cs` file (skip binaries; for deleted files just note the deletion). **Also read `src/Applications.SISApi/SISApi.API/Assets/PublicChangeLog.md` in full at PR head if it is among the changed files** — R4 needs its text to apply §15. Cite real line numbers from the PR-head file. **As soon as you have cached the text, delete the temp ref** — do not leave it open while sub-agents run:

```
git update-ref -d refs/pr-review/<n>
```

The sub-agents cannot fetch anything, so everything they need must come from this cached text.

#### Phase 1b — Resolve & decompile the upstream client DTO(s) (orchestrator only; read-only)

A Gateway GET endpoint is a thin wrapper over a domain microservice's **client library** (`{Domain}.Service.Client`), and the endpoint's `Output` is only correct if every property it advertises can actually be mapped from the upstream `{Resource}Dto`. The reviewers otherwise cannot tell a real field from an over-advertised one (e.g. an `Output` that inherits a `StudentReference` from its `Input` but the upstream DTO has no such field, so consumers will never receive it). So before fanning out, pull the real upstream contract and cache its text.

1. **Identify the referenced client types.** From the PR's Query handler + `Output`/`Input` files you already cached, note the `{Domain}.Service.Client` namespace and the concrete types the generated code touches: the `I{Resource}Client`, the `{Resource}Dto` (and any nested DTO types it exposes), and the `Get{Resource}V1HttpResponseAsync` return type.
2. **Resolve the package version** from the csproj at PR head (read it even if it isn't in the diff):
   ```
   git show refs/pr-review/<n>:src/Applications.SISApi/SISApi.API/SISApi.API.csproj
   ```
   Find `<PackageReference Include="SIS.{Domain}.Service.Client" Version="X.Y.Z" />`. Use that exact version (the PR may have bumped it — always take the PR-head value, not `origin/main`).
3. **Locate the restored assembly** in the NuGet cache:
   ```
   ~/.nuget/packages/sis.{domain}.service.client/{X.Y.Z}/lib/net8.0/{Domain}.Service.Client.dll
   ```
   (lower-case package folder; the sibling `{Domain}.Service.Client.xml` doc file sits next to it.)

   **Gate before steps 4–5 — the target version must be cached.** If neither the DLL nor the XML doc exists for **that exact version** (common when the PR bumped the client and a read-only review never restores it), stop here and go straight to step 6. Specifically, do NOT:
   - substitute a **different cached version** of the same package — a DTO or property added in the bumped version cannot exist in an older assembly, so decompiling it proves nothing;
   - run `dotnet tool install --global ilspycmd` — it reliably fails in this locked-down environment (`DotnetToolSettings.xml was not found in the package`). One `ilspycmd --version` probe is fine; an install attempt is not.

   Then prefer reconstructing the DTO's field set from **the PR's own unit tests** when they enumerate the fields (e.g. a mapper or serialization test that constructs the DTO) — that is a sanctioned fallback, at explicitly reduced confidence. Note it as fidelity level `test-inferred` for R3.
4. **Decompile the referenced types** (only if the target version's DLL is cached). Use `ilspycmd` if it is already on PATH:
   ```
   ilspycmd --version 2>$null   # probe only -- do NOT attempt `dotnet tool install`
   ilspycmd "<dll path>" -t {Domain}.Service.Client.{Resource}Dto
   ```
   Run `-t` once per DTO type you need (the `{Resource}Dto` plus any nested DTO types it references). Capture the decompiled class text (property names, types, nullability, `[JsonProperty]` names).
5. **Fallback when `ilspycmd` is unavailable** (offline / locked-down scheduled env): read the **target version's** sibling `{Domain}.Service.Client.xml` doc file (no tool needed) and extract the `<member name="P:...">` summaries for the DTO. Log `WARN: ilspycmd unavailable — upstream DTO fidelity reduced to XML-doc summaries (names/descriptions only, no types/nullability)` so the user knows the mapping check was partial.
6. **If the target version isn't cached at all** (no DLL AND no xml doc for that version — e.g. the PR bumped to a version never restored locally): log `WARN: upstream {Domain}.Service.Client {version} not found in NuGet cache — R3 Output↔DTO mapping check skipped` (add `— DTO shape inferred from PR unit tests instead` if you reconstructed it that way) and proceed without it. Do NOT fail the PR on this alone.

Cache the decompiled/parsed DTO text in memory — you will inline it into **R3**'s brief in Phase 2. Note the fidelity level (full decompile vs xml-doc-only vs test-inferred vs skipped) so R3 calibrates its confidence.

#### Phase 1d — Cache sibling files for the verifiers (orchestrator only; read-only)

The Phase 4 verifiers have **no tools**, so they cannot check what the rest of the codebase already does —
which is exactly why the false-positive list below has to be hand-maintained. Fix that by caching the
evidence now, while you still have git access.

For each **feature directory** touched by the PR, list its contents on `origin/main` and cache the text of
**2–3 sibling files of each kind** the PR changes:

```
git ls-tree --name-only origin/main <dir>/          # what already lives next to the changed file
git show origin/main:<sibling path>                 # no ref needed — origin/main is always available
```

Pick siblings **of the same kind** as the changed file — `*Controller.cs` next to a changed controller,
`*Query.cs`/`*Handler` next to a changed handler, `*Output.cs` next to a changed output, `*Tests.cs` next
to a changed test. Prefer the same `Features/` area; otherwise fall back to the canonical
`Features/People/StudentsHomeroom/**` reference feature, which is already the yardstick this review uses.
Cap it at **3 files per kind** and skip any file over ~600 lines — this is a convention sample, not a
second review.

Prefer `origin/main:` paths over the temp ref: they need no ref at all and represent the convention as it
stood *before* this PR. If a directory is new in this PR and has no `origin/main` counterpart, note
`siblings: none (new feature folder)` and fall back to the `StudentsHomeroom` reference — the verifier will
otherwise be left with the carve-out list alone.

#### Phase 1e — Story alignment (gated, informational only)

Ask the one question the rulebook cannot: **does this PR do what the ticket asked for?** This is
**read-only on ADO** and its output is **never blocking** (see the framing rule at the end).

1. **Find the ticket id** in the PR title or head branch, in this order: `AB#(\d+)`, `story/(\d+)`,
   `(\d{6})-`. If none matches, skip this phase **silently** — many PRs legitimately have no ticket.
2. **Gate on credentials.** If `{{ADO_ORG}}` is empty (the wrapper found no `ADO_PAT`, which is a normal
   and supported configuration), log `STORY-ALIGN SKIPPED (PR #<n>): no ADO credentials` and continue to
   Phase 2. **Never** attempt an interactive login — you are a non-interactive scheduled task.
3. **Read the PAT out of `{{ENV_FILE}}`** — the `ADO_PAT=<value>` line in that file. It is **not** an
   environment variable: `$env:ADO_PAT` is empty in this process, so do not probe it and conclude there
   are no credentials. Never print or log the PAT itself. Then **fetch the work item** read-only, using it
   as HTTP Basic auth (`Authorization: Basic base64(":$AdoPat")`), preferring PowerShell
   `Invoke-RestMethod`:

   ```
   https://dev.azure.com/{{ADO_ORG}}/{{ADO_PROJECT}}/_apis/wit/workitems/<id>?api-version=7.1&fields=System.Title,System.Description,Microsoft.VSTS.Common.AcceptanceCriteria,Microsoft.VSTS.TCM.SystemInfo
   ```

   These fields are HTML — strip tags before reading them. On any error (404, expired PAT, wrong project),
   log `STORY-ALIGN SKIPPED (PR #<n>): <reason>` and continue. Never fail the PR over this.
4. **Compare at a high level only** — this is a sanity check, not a second rubric:
   - endpoint path + HTTP method the ticket specifies vs. what the controller actually exposes
   - the **ViewModels** field list the ticket carries vs. what the PR's `Output` advertises (this pairs
     naturally with the Phase 1b upstream-DTO check: the ticket says what was *asked for*, the decompiled
     DTO says what can actually be *populated*)
   - any explicitly stated requirement or acceptance criterion with no visible counterpart in the diff
5. **Record it** in the `data` object as `story_alignment`
   (`{id, title, status, matches[], differences[]}`, `status` one of `found` / `not-found` /
   `minimal-details` / `skipped`), and log `STORY-ALIGN <id> (PR #<n>): <m> match, <d> differ`.

**Framing — differences are FYI, never blocking.** Implementation legitimately diverges from a ticket
during refinement, so a difference is information for the reviewer, not a defect. Phase 1e may emit at
most **`info`** findings (category `Documentation`), and it **must never change `recommendationClass`** —
the Phase 5 thresholds are computed exactly as before. A ticket difference is never an `error` or a
`warning`.

### Phase 2 — Fan out five dimension reviewers IN PARALLEL

In a **single message, make five `Agent` tool calls at once** (`subagent_type: general-purpose`) so the reviewers run concurrently. Each reviewer owns a cluster of `pr-review-standards.md` sections and only the files it needs:

> **This is not optional, and the briefs being long is not a reason to split them.** Emit all five `Agent`
> calls in ONE assistant turn — never dispatch R<n>, wait for its JSON, then dispatch R<n+1>. Serializing
> the fan-out costs ~5–6 minutes of wall clock per PR for zero benefit (the reviewers are independent and
> share no state). If a brief feels too large to compose alongside the other four, trim the inlined file
> text for that reviewer — do **not** trade the parallelism away.
>
> **Self-check marker (mandatory).** In the **same assistant message** that carries the `Agent` calls,
> print `FANOUT (PR #<n>): <k> reviewer(s) dispatched in this message`. The wrapper independently logs how
> many `Agent` blocks each message actually contained, so a `FANOUT ... 1 reviewer` line — or five of them
> — is a visible regression, not a silent one. `k` must be 5 (or the number of reviewers with in-scope
> files, if the PR touches fewer file kinds). Emitting this marker in a message that contains **no** `Agent`
> call means you are about to serialize: stop and batch the remaining reviewers instead.

| Reviewer | Rubric sections (from `pr-review-standards.md`) | Files in scope | Emits categories |
|---|---|---|---|
| **R1 — Architecture & CQRS** | 1 Architecture/CQRS, 3 Query Handler, 4 Command Handler | the feature slice: `*Query.cs`, `*Command.cs`, `*Handler` | `Architecture`, `CQRS` |
| **R2 — API Surface & Security** | 2 Controller, 10 Authorization/Security, 7 Naming + versioning | `*Controller.cs` | `Controller`, `Security`, `Versioning` |
| **R3 — Contracts & Data** | 5 Validation, 6 Model/DTO (+HATEOAS), 12 JSON Serialization | DTOs, `*Output.cs`, validators, **+ the decompiled upstream `{Resource}Dto` from Phase 1b** | `Validation`, `DTO & Model` |
| **R4 — Runtime Correctness (cross-cutting)** | 8 DI, 9 Error Handling, 11 Async, 14 General Quality, **15 Public Change Log** | **all** changed `.cs` files **+ `SISApi.API/Assets/PublicChangeLog.md` if changed** | `Error Handling`, `Async`, `Standards`, `Code Quality`, `Documentation` |
| **R5 — Testing** | 13 Testing + Integration Test Standards | `*Tests*.cs`, `SISApi.APITests/**` | `Testing`, `Integration Test` |

For a PR that adds/changes a **GET endpoint**, also give **R2** the "Endpoint Validation Checklist" + "Reference Object Rules" from `.claude/commands/GWEndpointsGenerator/generate-get-endpoint.md` and tell it to compare structure against the `StudentsHomeroom` reference feature.

**Each reviewer's brief must be self-contained** (it has no tools). Include:
1. PR metadata (number, title, author, head/base).
2. The **full text** of the files in its scope (inline).
3. The **text of its assigned rubric sections**, copied from `pr-review-standards.md` (which you have read) — do not tell the agent to open the file; it can't.
4. The finding-object shape, severity mapping, false-positive guards, and category list below.
5. **The `ALREADY RAISED` block** — the `prior_activity[]` list from Phase 1, formatted one per line as
   `<file>:<line> — <author> — <gist>`, under this instruction, verbatim:

   > *"These points have ALREADY been raised on this PR by a human reviewer or a bot. Do NOT re-raise any
   > of them. If you independently agree with one, stay silent — a duplicate wastes the reader's time and
   > makes the report look like it did not read the conversation. Only report something genuinely NOT in
   > this list."*

   If the list is empty, say so explicitly (`ALREADY RAISED: none`) so the reviewer doesn't invent one.
6. **The "already exists" guard**, verbatim in every brief:

   > *"Before reporting any finding of the form 'X is missing' or 'X should be added', confirm X is
   > genuinely absent from the PR's changed-file list inlined above. If X is present in this PR, the
   > finding is invalid — drop it. **Never suggest adding something that already exists.**"*
7. The instruction: *"Return ONLY a JSON array of finding objects (no prose, no tool calls). Prefer fewer, high-confidence findings with concrete `file:line`. If nothing, return `[]`."*

The concrete rubric checks a careful reviewer looks for (distribute to the owning reviewer): feature-based placement + MediatR delegation + `sealed` query/command with nested `Handler` (R1); controller inherits `ExternalApiController`, `[Authorize(AuthenticationSchemes="ApiAuthentication")]` + `[Authorize(Roles="{Domain}Read")]`, `[ApiVersion]`/`[MapToApiVersion]`, `[ProducesResponseType]`, `CancellationToken` on actions, write verbs carry `{Domain}Write` (R2); `QuerySanitizer.Sanitize()`, `AddSchoolCodeFilterAsync`/`AddConfigSchoolIdFilterAsync`, `ApimHelper.GetApimNextUrl()`, `CancellationToken` threaded (R1); `Output` matches the ticket's ViewModels, **every `Output` property is mappable from the upstream `{Resource}Dto` decompiled in Phase 1b — flag any `Output` (or inherited-from-`Input`) property with NO corresponding source field on the upstream DTO as a `warning` (category `DTO & Model`): the contract advertises data the source can never populate (this is exactly the `StudentReference`-never-populated class of bug); conversely note any upstream field the ticket's ViewModels expect but the `Output` drops** (calibrate confidence to the Phase-1b fidelity level — do NOT raise a hard mapping finding when Phase 1b logged the XML-doc-only or skipped fallback, downgrade to `info` phrased as "could not fully verify against upstream DTO"), HATEOAS `ReferenceLink` uses REAL endpoint URLs **only for the reference types the generator spec defines a URL for** (`GradeLevelReference`, `SchoolYearReference`, `SchoolIdReference`, `StudentReference`, `ClassReference`, `FamilyReference`, `CourseReference`) — the generator *mandates* `Href = "Endpoint not yet implemented"` for any other reference, so that placeholder is established convention and must NOT be flagged (see the §6 carve-out), `[ExcludeFromCodeCoverage]`, `[ApplySieve]` on paged outputs (R3); no empty catch, no `async void`, no sync blocking (`.Result`/`.Wait()`/`.GetAwaiter().GetResult()`) — but `.Results` (plural, `PagedResult.Results`) is NOT a violation — `Result.Fail(...)` carries `.WithMetadata("StatusCode", …)`, Newtonsoft not `System.Text.Json`, DI over `new Service()`, no leftover `TODO`/`HACK`/`FIXME`/`#region` (R4); and — per §15 — if `PublicChangeLog.md` changed, emit **exactly ONE consolidated `info` finding** (category `Documentation`) covering all its issues at once (wrong/stale date, duplicate entry, raw `AB#…` work-item bullet, missing blank line), never one finding per issue (R4); NUnit + NSubstitute (flag Moq), `[Retry(2)]` + real `[TestCaseId("NNNNNN")]` (never invented), `public` test classes, `FixtureBuilder.GetGatewayClient()`, `.AddQuery()` not query-string-in-URL, typed `Should().BeInAscendingOrder(...)`, FluentAssertions not classic `Assert.*` (but `Assert.IsEmpty` is allowed), DistrictWide happy-path asserts `PageSize.Should().Be(50)`, a new feature file with no matching `SISApi.APITests` test is a warning, no hardcoded bearer tokens (error) (R5).

**Severity mapping** (every reviewer): REQUIRED violation → `error`; RECOMMENDED → `warning`; NICE-TO-HAVE → `info`. Be precise and avoid false positives — a wrong finding wastes the user's validation time. Give each finding a concrete `file:line`, a clear message, an actionable suggestion, and a short `codeExample` (before/after) where it helps.

**Do NOT flag (known false positives — put this in every reviewer brief):**
- **Unused `using` directives — never report these.** Deciding a `using` is truly unused requires resolving every symbol's declaring namespace, which this review cannot do reliably; the IDE/build already flags genuinely-unused imports (IDE0005). In particular, `using Academic.Service.Client;` is REQUIRED in most GW query handlers and their unit tests because it declares **`IConfigSchoolClient`** (used by `AddConfigSchoolIdFilterAsync` for school-level filtering) — it is NOT unused just because the endpoint's domain isn't "Academic".
- **`Href = "Endpoint not yet implemented"` on a reference with no defined endpoint.** The repo's own generator spec mandates that exact string ("Reference Object Rules": *No defined endpoint → set `Href = "Endpoint not yet implemented"`*) and it ships in 84 `*Output.cs` files on `main`. It is established convention. Only flag a placeholder `Href` on one of the reference types the generator gives a real URL for (`GradeLevelReference`, `SchoolYearReference`, `SchoolIdReference`, `StudentReference`, `ClassReference`, `FamilyReference`, `CourseReference`).
- Any finding you could only justify by guessing which namespace a type comes from — if you can't see the declaration, don't assert it.

**Finding object shape** (each reviewer returns a JSON array of these):

```json
{ "severity": "error", "category": "Security", "skill": "Controller & Security",
  "file": "src/Applications.SISApi/SISApi.API/Features/.../XController.cs", "line": 42,
  "message": "Write endpoint missing {Domain}Write role.",
  "suggestion": "Add [Authorize(Roles = \"XWrite\")] to the POST action.",
  "codeExample": "[HttpPost]\n[Authorize(Roles = \"XWrite\")]" }
```

`skill` is a short human label for the finding's origin (e.g. `"Controller & Security"`, `"Integration Test"`); if unsure, reuse the category. Allowed **categories** (use these exact strings so the report groups cleanly): `Architecture`, `Controller`, `Security`, `CQRS`, `Validation`, `Error Handling`, `Async`, `DTO & Model`, `Standards`, `Code Quality`, `Testing`, `Integration Test`, `Documentation`, `Versioning`.

If a reviewer sub-agent fails or returns unparseable output, note it and proceed with the reviewers that succeeded — do not abort the PR.

### Phase 3 — Merge & dedupe (orchestrator)

Concatenate the five findings arrays, then:
- **Dedupe** on `(file, line, category)` + normalized message. On a collision, keep the **highest** severity and the richest record (prefer the one carrying a `codeExample`).
- **Dedupe against prior activity.** Drop any finding that lands on the same `(file, line)` as an existing
  unresolved comment from Phase 1 **and** makes substantively the same point. A reviewer may have slipped
  one through despite the `ALREADY RAISED` block; this is the backstop. Log each drop as
  `DEDUPE (PR #<n>): dropped <category> at <file>:<line> — already raised by <author>` so the suppression
  is visible rather than silent.
- **Normalize** every `category` to one of the allowed strings above so the template groups cleanly.

### Phase 4 — Adversarially verify every error (parallel)

For **each surviving finding whose `severity` is `error`**, dispatch a verify sub-agent (`Agent`, `general-purpose`, no tools) whose job is to **try to DISPROVE the finding** against the quoted rule and the relevant file slice (inline both). Batch these so no single message exceeds ~8 `Agent` calls; run batches until all errors are judged.

**Inline the sibling-file evidence from Phase 1d** for every finding whose claim is about **structure or
convention** — "missing attribute", "wrong pattern", "should inherit X", "should be public/sealed", "wrong
folder", "missing file". Add the cached sibling text to that verifier's brief under this instruction,
verbatim:

> *"Below are 2–3 files of the same kind that already exist in this codebase on `origin/main`. If the PR
> does the same thing these siblings already do, then the pattern the finding objects to is **established
> local convention**, and the finding is a false positive — return `REJECTED` with the sibling file and
> line that demonstrates it. Established convention beats a generic rule."*

This is **additive** — the verifier still receives the full false-positive guard list. The list catches the
cases already known; the sibling evidence catches the ones nobody has written down yet. Where Phase 1d
recorded `siblings: none (new feature folder)`, say so in the brief and let the verifier fall back to the
`StudentsHomeroom` reference plus the guard list. Note that **unused `using` directives stay a
never-report regardless** — no sibling file can settle that one, it needs a compiler.

Each verifier returns one of:
- `UPHELD` — the error is real as stated.
- `REJECTED` — false positive (with a one-line reason).
- `WRONG_SEVERITY` — a real observation but not a REQUIRED violation (should be a warning/info).

**Uphold on uncertainty:** if the verifier cannot clearly disprove it, keep it as `UPHELD`. Only `error` findings are verified (warnings/info pass through unchanged).

### Phase 5 — Finalize, score & render (orchestrator)

Apply the verdicts: drop `REJECTED` findings; downgrade `WRONG_SEVERITY` to `warning` (or `info` where the verifier said so). Then **recompute** the counts from the final finding set — this recompute is the single source of truth for both the HTML `summary` and the `PR #<n> REVIEWED` marker, so they can never disagree.

Let `E`=error count, `W`=warning count, `I`=info count, `total=E+W+I`.

- `E > 0`  → `recommendationClass:"reject"`,  `recommendation:"DO NOT APPROVE - {E} error(s) must be fixed"`
- else `W > 3` → `recommendationClass:"changes"`, `recommendation:"REQUEST CHANGES - {W} warnings to address"`
- else `W > 0` → `recommendationClass:"comments"`, `recommendation:"APPROVE WITH COMMENTS - {W} minor warning(s)"`
- else → `recommendationClass:"approve"`, `recommendation:"APPROVE - Code follows all standards"`

Build a `data` object with EXACTLY this shape (the template reads these keys):

```json
{
  "pr_number": 182,
  "pr_title": "AB#... [ExternalAPIGW] GET: ...",
  "pr_author": "<pr-author-github-login>",
  "pr_url": "https://github.com/nelnet-nbs/sis-externalapi/pull/182",
  "pr_head": "story/256242",
  "pr_base": "main",
  "pr_updated_at": "2026-07-13T01:22:33Z",
  "head_sha": "abc1234",
  "additions": 120,
  "deletions": 5,
  "changed_files_count": 8,
  "generated_at": "2026-07-13 08:00 (+08:00)",
  "reviewer": "Claude Opus (scheduled full semantic review)",
  "checks_state": "failing",
  "checks_summary": "12 passed, 1 failed",
  "prior_activity_count": 2,
  "prior_activity": [
    { "author": "coderabbitai", "file": "src/Applications.SISApi/SISApi.API/Features/.../XController.cs",
      "line": 31, "gist": "Suggests CancellationToken on the GET action.", "resolved": false }
  ],
  "story_alignment": {
    "id": "256242", "title": "[ExternalAPIGW] GET: StudentsHomeroom", "status": "found",
    "matches": ["GET api/Students/v1 matches the ticket", "Output carries all 6 ViewModel fields"],
    "differences": ["Ticket mentions a schoolYear filter; not present in the PR (may be intentional)"]
  },
  "summary": { "total": 5, "errors": 1, "warnings": 2, "info": 2,
               "recommendation": "DO NOT APPROVE - 1 error(s) must be fixed",
               "recommendationClass": "reject" },
  "findings": [
    { "severity": "error", "category": "Security", "skill": "Controller & Security",
      "file": "src/Applications.SISApi/SISApi.API/Features/.../XController.cs", "line": 42,
      "message": "Write endpoint missing {Domain}Write role.",
      "suggestion": "Add [Authorize(Roles = \"XWrite\")] to the POST action.",
      "codeExample": "[HttpPost]\n[Authorize(Roles = \"XWrite\")]" }
  ],
  "files": [
    { "filename": "src/.../XController.cs", "status": "added", "additions": 50, "deletions": 0 }
  ]
}
```

- **The three new keys are all optional-but-preferred.** The template renders each panel only when its key
  is present and non-empty, so an older report shape still renders — but fill them whenever you have the
  data. `checks_state` must be one of `passing` / `failing` / `pending` / `none`. `story_alignment.status`
  must be one of `found` / `not-found` / `minimal-details` / `skipped`. Use `"skipped"` (not omission) when
  a ticket id existed but the fetch was gated — that distinction is what tells the reader whether alignment
  was *unavailable* or *not applicable*.
- `skill` is a short human label for the finding's origin (e.g. `"Controller & Security"`, `"Integration Test"`); it shows under the severity badge. If unsure, reuse the category.
- `head_sha` is the short 7-char SHA. `generated_at` comes from `Get-Date` (real local time; do not guess).
- If there are no findings, `findings: []` — the template renders an "All Clear!" panel.

Then inject it into the template and save. Do it deterministically with PowerShell (literal replace, UTF-8 no BOM) rather than hand-editing the big HTML string. Write the data to a temp JSON file first:

```powershell
$outDir = '{{OUTPUT_DIR}}'
$dataPath = Join-Path $env:TEMP ("pr-review-{0}.json" -f $number)   # you write $data as JSON here
$tplPath  = '{{SCHEDULED_DIR}}\pr-review-template.html'
$slug = ($title -replace '[^A-Za-z0-9_-]','_') -replace '_+','_'
$slug = $slug.Trim('_'); if ($slug.Length -gt 60) { $slug = $slug.Substring(0,60) }
$outPath = Join-Path $outDir ("PR-{0}-{1}.html" -f $number, $slug)   # stable per-PR name — "1 PR = 1 HTML"

$tpl  = [System.IO.File]::ReadAllText((Resolve-Path $tplPath))
$json = [System.IO.File]::ReadAllText($dataPath)
$json = $json.Replace('</','<\/')                       # keep a stray </script> in codeExample from breaking the island
$html = $tpl.Replace('__PR_REVIEW_DATA__', $json)
[System.IO.File]::WriteAllText($outPath, $html, [System.Text.UTF8Encoding]::new($false))
Remove-Item $dataPath -Force -ErrorAction SilentlyContinue
```

Write the `data` object to `$dataPath` using the Write tool (a `.json` file), then run the snippet above. Confirm the output file exists and log its full path. Log a one-line marker per PR so the wrapper can track progress:

`PR #<n> REVIEWED: <E> errors, <W> warnings, <I> info → <recommendationClass> → <outPath>`

Plus these two informational markers per PR, so a log reader can see the new inputs were actually used
(emit them even when nothing was found — a missing marker is indistinguishable from a silent failure):

```
CI (PR #<n>): <checks_state> — <checks_summary>
PRIOR (PR #<n>): <k> existing comment(s), <d> finding(s) suppressed as already-raised
```

(`STORY-ALIGN <id> (PR #<n>): ...` is emitted back in Phase 1e.)

**Marker ownership (multi-agent):** you (the orchestrator) are the sole emitter of every wrapper marker — `PRs to review: [...]` / `No PRs to review`, both `SKIP (...)` lines, `FANOUT (PR #<n>): ...`, `PR #<n> REVIEWED: ...`, `CI (PR #<n>): ...`, `PRIOR (PR #<n>): ...`, `STORY-ALIGN ...`, `DEDUPE (PR #<n>): ...`, `FAILED (PR #<n>): ...`, and the final `PR REVIEW RUN COMPLETE` summary. Sub-agents return JSON only and must never print these lines (a marker printed by a sub-agent would not reach the wrapper's stream anyway, and could corrupt the reviewed-count if it did).

## Exit behavior

1. Re-check `git rev-parse --abbrev-ref HEAD` and `git rev-parse HEAD` match what you recorded in Pre-flight step 4. If they differ, log `WARN: working tree/branch changed during run` with details.
2. Confirm no `refs/pr-review/*` temp refs are left: `git for-each-ref refs/pr-review/` (delete any stragglers with `git update-ref -d`).
3. Print a final summary in this exact format:

```
PR REVIEW RUN COMPLETE (<ISO timestamp>)
Candidates: <count from Step 1 before idempotency/approved skips>
Reviewed:   <n reviewed>   Skipped: <n skipped>  (approved: <a>, unchanged: <u>, not-eligible: <e>)

Reports written to {{OUTPUT_DIR}}\ :
  - PR-<n>-<slug>-<sha>.html   → <recommendationClass>  (<E>E/<W>W/<I>I)
  - ...

Repo left on branch: <branch>  (HEAD unchanged: <yes/no>)
```

- Log every step with an ISO timestamp.
- Exit 0 on completion. On a per-PR failure, log `FAILED (PR #<n>): <reason>` and continue to the next PR — one bad PR must not abort the whole run.
