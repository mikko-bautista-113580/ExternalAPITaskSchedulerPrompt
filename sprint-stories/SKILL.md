---
name: sprint-stories
description: List the Azure DevOps user stories assigned to you (or a named teammate) in the current sprint as tab-separated rows — ID, Title, Type, State, Sprint, Parent Feature, Epic, ADO Link — ordered so the ones needing attention (PR) come first and Closed last. Use this whenever someone asks what they are working on this sprint, "what's assigned to me", "my stories", "my tickets", "what's in PR", "what's left in the sprint", "sprint status", "list my work items", "/sprint-stories", or wants a paste-ready sprint list for a spreadsheet or status update — even when they don't say "Azure DevOps" or "ADO".
---

# Sprint stories

Answers "what do I have this sprint, and where is each piece?" from Azure DevOps, in a shape that
pastes straight into a spreadsheet or a status update.

The output is deliberately plain tab-separated text rather than a markdown table: this list usually
ends up in the sprint calendar workbook or a Teams message, and TSV survives both.

## Defaults

Unless the request says otherwise:

| Input | Default |
|---|---|
| Assignee | `@Me` — whoever's PAT/MCP session is running |
| Project | `ColdFusion` |
| Team | `Modernization Team` |
| Sprint | the team's **current** iteration |
| Work item type | `User Story` |
| States | all of them, including Closed |

**The External API work does not live in the "External API" ADO project.** That project exists and
has a stub iteration called "Iteration 1" with no dates, so a query against it returns nothing and
looks like "you have no work". The `[ExternalAPIGW]` and `[AdmissionsMS]` stories live in
**ColdFusion**, area path `ColdFusion\Modernization Team`. If a query comes back empty, check this
first before telling the user their sprint is empty.

Honor overrides in the request: a named teammate (`[System.AssignedTo] = 'Display Name'`), a
specific sprint (swap `@CurrentIteration` for the literal path, e.g. `ColdFusion\2026\26.15`), a
state filter ("just the ones in PR"), or a title filter ("only the GW ones" → `[System.Title]
CONTAINS 'ExternalAPIGW'`).

## How to build the list

The ADO MCP exposes **consolidated** tools that take an `action` argument — `mcp__azure__wit_query`,
`mcp__azure__wit_work_item`, `mcp__azure__work`. Every call needs an explicit `project`, otherwise it
returns `Project selection cancelled.` and you have burned a round-trip.

**1. Get the IDs.** One WIQL query does the assignee + sprint filtering:

```
mcp__azure__wit_query  action=wiql  project=ColdFusion  team="Modernization Team"
SELECT [System.Id] FROM WorkItems
WHERE [System.TeamProject] = 'ColdFusion'
  AND [System.WorkItemType] = 'User Story'
  AND [System.AssignedTo] = @Me
  AND [System.IterationPath] = @CurrentIteration
ORDER BY [System.Id]
```

`@CurrentIteration` resolves against the `team` argument, so passing the team is what makes "current"
mean anything. If you need the sprint's dates or its exact path, `mcp__azure__work` with
`action=list_team_iterations` and `timeframe=current` gives them.

**2. Get the fields** in one batch — `action=get_batch` on `mcp__azure__wit_work_item`, asking for
`System.Id`, `System.Title`, `System.WorkItemType`, `System.State`, `System.IterationPath`. Don't
fetch work items one at a time; a 13-story sprint is one call, not thirteen.

**3. Walk up the hierarchy** with a link query, once per level. Parents come back as source/target
pairs:

```
mcp__azure__wit_query  action=wiql  project=ColdFusion
SELECT [System.Id] FROM WorkItemLinks
WHERE (Source.[System.Id] IN (<the story ids>))
  AND ([System.Links.LinkType] = 'System.LinkTypes.Hierarchy-Reverse')
MODE (MustContain)
```

`MODE (DoesNotMatter)` is rejected by this server — use `MustContain`. Rows where `rel` is `null` are
the sources echoed back; the real parent links are the rows with `rel = "System.LinkTypes.Hierarchy-Reverse"`.

Run the same query again with the Feature IDs to reach the Epic, then one `get_batch` over the
distinct Feature + Epic IDs for their titles. Two levels is the whole ladder here: Story → Feature →
Epic. Many stories share a parent (the MS and GW halves of one endpoint hang off the same Feature),
so de-duplicate before the batch call.

## Ordering

Sort by what still needs the user, not by ID:

1. **PR** — open PRs waiting on reviewers; this is what a status update is usually about
2. **Any other in-flight state** (Development, Review, Testing, Active…)
3. **Refined / New** — not started
4. **Closed / Resolved / Removed** — done, kept for the sprint-total picture

Within a group, ascending ID. If the user asks for something else ("group by feature", "hide the
closed ones"), do that instead — the ordering is a sensible default, not a rule.

## Output

One row per story, tab-separated, in a plain code block so nothing re-wraps. No header row unless
asked — the user is usually pasting these under an existing header.

Columns: `ID → Title → Type → State → Sprint → Parent Feature → Epic → ADO Link`

- **Sprint** — the leaf of the iteration path (`ColdFusion\2026\26.17` → `26.17`)
- **Parent Feature** — the Feature's **ID** only
- **Epic** — the Epic's **title** only
- **ADO Link** — the sprint-backlog deep link, which opens the item in the board context rather than
  a bare work-item page:
  `https://dev.azure.com/renweb/{project}/_sprints/backlog/{team}/{iteration path}?workitem={id}`
  URL-encode the team (`Modernization%20Team`) and turn the iteration path's backslashes into slashes
  (`ColdFusion\2026\26.17` → `ColdFusion/2026/26.17`).

Example row:

```
256278	[ExternalAPIGW] GET: Admissions - OAFormSchool Endpoint	User Story	PR	26.17	243071	Admissions	https://dev.azure.com/renweb/ColdFusion/_sprints/backlog/Modernization%20Team/ColdFusion/2026/26.17?workitem=256278
```

Add a one-line summary above the block — the sprint name and the state tally, e.g. *"26.17 — 13
stories: 6 PR, 3 Refined, 4 Closed"* — so the shape is readable without counting rows.

## When the MCP isn't there

Scheduled and headless runs sometimes come up without the ADO MCP (and `az` CLI has been broken on
these machines). The same three queries work over REST with the `ADO_PAT` from
`%USERPROFILE%\repos\.env` (override via `config.local.json` → `envFile`), Basic auth with an empty
username:

- WIQL: `POST https://dev.azure.com/renweb/ColdFusion/Modernization%20Team/_apis/wit/wiql?api-version=7.1`
  with `{"query": "<the WIQL above>"}`
- Fields: `GET .../_apis/wit/workitems?ids=<csv>&fields=<csv>&api-version=7.1`

Same steps, same output. Say plainly in the response which path was used, since the REST fallback
can't resolve `@Me` if the PAT belongs to someone else — resolve the assignee by display name there.

## What this doesn't do

Read-only, always. It never changes a work item's state, assignee, or iteration, never comments on a
ticket, and never touches git or GitHub. If the user wants a state moved after seeing the list, that
is a separate, explicit ask.
