# SIS External API - Coding Standards for PR Review

This document defines the coding standards for the `sis-externalapi` project. Rules are classified as:
- **REQUIRED** - Must be followed. Engine flags as **error**.
- **RECOMMENDED** - Should be followed in new code. Engine flags as **warning**.
- **NICE-TO-HAVE** - Good practice but not enforced. Engine flags as **info**.

---

## 1. Architecture: Vertical Slice / Feature-Based with CQRS

### Required Structure (REQUIRED)

New features MUST follow the feature-based folder structure:

```
Features/{Domain}/{Resource}/
├── {Resource}Controller.cs
├── Queries/
│   └── Get{Resource}Query.cs          (contains nested Handler class)
├── Command/
│   ├── Create{Resource}Command.cs     (contains nested Handler class)
│   ├── Update{Resource}Command.cs
│   ├── Patch{Resource}Command.cs
│   └── {Command}Validator.cs          (FluentValidation)
└── Shared/
    ├── {Resource}Input.cs             (request DTO)
    └── {Resource}Output.cs            (response DTO)
```

### Violations to Flag

- **error**: Files placed in root `Controllers/` or `Models/` instead of `Features/` (new code only)
- **warning**: Business logic placed directly in controllers instead of MediatR handlers
- **warning**: Query/Command classes without nested `Handler` class

---

## 2. Controller Standards

### Class Declaration (REQUIRED)

Controllers MUST:
- Inherit from `ExternalApiController`
- Have `[ApiVersion("1.0")]` (or appropriate version)
- Have `[ApiController]`
- Have `[Authorize(AuthenticationSchemes = "ApiAuthentication")]`
- Have `[Authorize(Roles = "{Domain}Read")]` at class level
- Use MediatR (`_mediator.Send()`) - no business logic in controllers

```csharp
[Route("/Academics/[Controller]")]
[ApiVersion("1.0")]
[ApiController]
[Authorize(AuthenticationSchemes = "ApiAuthentication")]
[Authorize(Roles = "AcademicsRead")]
public class AttendanceCodesController : ExternalApiController
```

### Recommended for New Code

- Have `[OpenApiTags("{Domain}", "{Resource}")]` for Swagger documentation (~50% adoption)
- Have `[ExcludeFromCodeCoverage]` on controller class (~1% adoption, but recommended going forward)

### Constructor Pattern

Controllers MUST inject `IMediator` (for new feature-based controllers) and call the base constructor:

```csharp
private readonly IMediator _mediator;

public AttendanceCodesController(
    ICustomServicePartitionClientFactory customServicePartitionClientFactory,
    IServiceConfiguration serviceConfiguration,
    IMediator mediator)
    : base(customServicePartitionClientFactory, serviceConfiguration)
{
    _mediator = mediator;
}
```

### Action Methods (REQUIRED)

- GET actions MUST have `[MapToApiVersion("1.0")]`
- All actions MUST have `[ProducesResponseType]` and `[ProducesDefaultResponseType]`
- All actions MUST accept `CancellationToken cancellationToken`
- POST/PUT/PATCH/DELETE actions MUST have `[Authorize(Roles = "{Domain}Write")]`
- Controllers MUST delegate to `_mediator.Send()` - no business logic in controllers

```csharp
[HttpGet]
[MapToApiVersion("1.0")]
[ProducesDefaultResponseType]
[ProducesResponseType(typeof(PagedResult<AttendanceCodesOutput>), StatusCodes.Status200OK)]
public async Task<PagedResult<AttendanceCodesOutput>> GetAttendanceCodes(
    [FromQuery] GetAttendanceCodesQuery request,
    CancellationToken cancellationToken)
{
    return await _mediator.Send(request, cancellationToken);
}
```

### Violations to Flag

- **error**: Not inheriting from `ExternalApiController`
- **error**: Missing `[Authorize]` attributes
- **error**: Write endpoints without `{Domain}Write` role authorization
- **warning**: Controllers with business logic (anything beyond `_mediator.Send()`)
- **warning**: Missing `CancellationToken` parameter
- **warning**: Missing `[ProducesResponseType]` attributes
- **info**: Missing `[MapToApiVersion]` on actions
- **info**: Missing `[OpenApiTags]` for Swagger documentation

---

## 3. Query Handler Standards (CQRS Read)

### Class Structure (REQUIRED)

Queries MUST:
- Be `sealed` classes
- Extend `SieveModel` and implement `IRequest<PagedResult<{Output}>>` for list queries
- Contain a nested `sealed class Handler` implementing `IRequestHandler<TRequest, TResponse>`

```csharp
public sealed class GetResourceQuery : SieveModel,
    IRequest<PagedResult<ResourceOutput>>
{
    public sealed class Handler :
        IRequestHandler<GetResourceQuery, PagedResult<ResourceOutput>>
    {
        // constructor injection + Handle method
    }
}
```

### Handler Implementation Pattern

Query handlers follow this sequence:

```csharp
public async Task<PagedResult<ResourceOutput>> Handle(
    GetResourceQuery request, CancellationToken cancellationToken)
{
    // 1. (RECOMMENDED) Sanitize input - only ~8% of handlers do this currently
    (request.Filters, request.Sorts) = QuerySanitizer.Sanitize(
        request.Filters, request.Sorts);

    // 2. (RECOMMENDED) Add school filter - ~53% of handlers do this
    request.Filters = await request.Filters.AddSchoolCodeFilterAsync(
        _userAccessor, _schoolClient, cancellationToken);

    // 3. (REQUIRED) Call service client with Sieve parameters
    var requestData = await _client.GetResourceHttpResponseAsync(
        request.Filters, request.Sorts, request.Page, request.PageSize,
        cancellationToken
    ).GetResponseData<PagedResultOfResourceDto>();

    // 4. (REQUIRED) Build APIM next-page URL
    var apimDomain = _serviceConfiguration.TryGetConfigurationValue(
        "ApplicationUri", "ApimUri");
    var nextPageUrl = ApimHelper.GetApimNextUrl(
        requestData.NextPage, apimDomain,
        _httpContextAccessor?.HttpContext?.Request?.GetDisplayUrl(),
        _httpContextAccessor?.HttpContext?.Request?.Query["api-version"]);

    // 5. (REQUIRED) Transform DTO to Output and return PagedResult
    return new PagedResult<ResourceOutput>
    {
        Results = requestData.Results
            .Select(x => new ResourceOutput(x, apimDomain)).ToList(),
        CurrentPage = requestData.CurrentPage,
        PageCount = requestData.PageCount,
        PageSize = requestData.PageSize,
        RowCount = requestData.RowCount,
        NextPage = string.IsNullOrEmpty(nextPageUrl) ? null : nextPageUrl
    };
}
```

### Dependencies

Required:
- `I{Resource}Client` - the microservice client
- `IServiceConfiguration` - for APIM domain
- `IHttpContextAccessor` - for current request URL

Recommended (for school filtering):
- `IConfigSchoolClient` - for school filter lookup (~53% of handlers inject this)
- `IUserAccessor` - for user claims extraction (~53% of handlers inject this)

### Violations to Flag

- **warning**: Queries not marked `sealed`
- **warning**: Missing `QuerySanitizer.Sanitize()` call (recommended for new handlers)
- **warning**: Missing school-level filter when `IUserAccessor`/`IConfigSchoolClient` are not injected
- **warning**: Missing `CancellationToken` parameter in Handle method
- ~~**info**: Unused `using` statements~~ — **NOT flagged by this review.** Reliable unused-using detection needs the compiler/IDE (IDE0005), not eyeballing namespaces. ⚠️ `using Academic.Service.Client;` is almost always REQUIRED even in non-Academic domains — it declares the shared `IConfigSchoolClient` used for school filtering — so never report it as unused.

---

## 4. Command Handler Standards (CQRS Write)

### Class Structure (REQUIRED)

Commands MUST:
- Be `sealed` classes
- Implement `IRequest<Result<{Output}>>` (using FluentResults)
- Use `[FromBody]` attribute for input properties
- Contain a nested `sealed class Handler`

```csharp
public sealed class CreateResourceCommand : IRequest<Result<ResourceOutput>>
{
    [FromBody]
    public ResourceInput Body { get; set; }

    public sealed class Handler :
        IRequestHandler<CreateResourceCommand, Result<ResourceOutput>>
    {
        // implementation
    }
}
```

### Error Handling in Commands (REQUIRED)

Errors MUST use `Result.Fail()` with `.WithMetadata("StatusCode", code)`:

```csharp
// Authorization errors
return Result.Fail<ResourceOutput>(
    new Error("403 Forbidden: You do not have write access.")
        .WithMetadata("StatusCode", 403));

// Validation errors
return Result.Fail<ResourceOutput>(
    new Error($"Invalid configSchoolId: '{id}'!")
        .WithMetadata("StatusCode", 400));
```

### Violations to Flag

- **warning**: Commands not marked `sealed`
- **warning**: `Result.Fail()` calls missing `.WithMetadata("StatusCode", ...)`
- **warning**: Commands not using `Result<T>` return type (FluentResults)

---

## 5. Validation Standards (FluentValidation)

### Validator Class Pattern (RECOMMENDED)

Commands SHOULD have a corresponding Validator:

```csharp
public sealed class CreateResourceCommandValidator :
    AbstractValidator<CreateResourceCommand>
{
    public CreateResourceCommandValidator()
    {
        RuleFor(x => x.Body)
            .NotNull()
            .WithMessage("Request body is required.");

        RuleFor(x => x.Body.Title)
            .NotNull().WithMessage("Title is required.")
            .NotEmpty().WithMessage("Title must not be empty.")
            .MaximumLength(50).WithMessage("Title must not exceed 50 characters.");
    }
}
```

### Violations to Flag

- **warning**: Validation rules missing `.WithMessage()` for user-facing error messages

---

## 6. Model / DTO Standards

### Output Models (REQUIRED)

- File: `{Resource}Output.cs` in `Shared/` folder
- MUST have a constructor accepting the service DTO + `apiDomain` string
- MUST generate HATEOAS reference links where applicable
- Mark with `[ExcludeFromCodeCoverage]`

```csharp
[ExcludeFromCodeCoverage]
public class ResourceOutput : ResourceInput
{
    public int Id { get; set; }

    public ResourceOutput(ResourceDto dto, string apiDomain)
    {
        Id = dto.Id;
        Name = dto.Name;
        if (dto.SchoolId > 0)
        {
            SchoolReference = new SchoolReference
            {
                SchoolId = dto.SchoolId,
                Link = new ReferenceLink
                {
                    Rel = "self",
                    Href = $"{apiDomain}/SchoolConfigurations?Filters=configSchoolId=={dto.SchoolId}"
                }
            };
        }
    }
}
```

### HATEOAS Links

Reference links SHOULD use real endpoint URLs wherever the target endpoint exists:

```csharp
// GOOD:
Href = $"{apiDomain}/Lesson/Unit/?Filters=Id=={dto.UnitId}"

// Sanctioned when no endpoint exists yet for that reference:
Href = "Endpoint not yet implemented"
```

**Carve-out — do NOT flag the sanctioned placeholder.** The repo's own generator spec
(`.claude/commands/GWEndpointsGenerator/generate-get-endpoint.md`, "Reference Object Rules":
*"No defined endpoint → set `Href = "Endpoint not yet implemented"`"*) **mandates** that exact string
for a reference whose endpoint does not exist, and it ships in 84 `*Output.cs` files across 15+ domains
on `main`. It is established local convention, not a defect — flagging it fires on essentially every new
endpoint slice and gets dismissed every time.

Flag it **only** when the generator spec defines a real Href for that reference type — `GradeLevelReference`,
`SchoolYearReference`, `SchoolIdReference`, `StudentReference`, `ClassReference`, `FamilyReference`,
`CourseReference` — and the PR used the placeholder anyway.

### Violations to Flag

- **warning**: Placeholder `Href` used for one of the reference types the generator spec defines a real URL for (see the carve-out above). A bare `"Endpoint not yet implemented"` on a reference with no defined endpoint is **NOT** a finding
- **info**: Output model missing `[ApplySieve]` attribute (~45% adoption, recommended for paged queries)

---

## 7. Naming Conventions

| Element | Convention | Example |
|---------|-----------|---------|
| Controllers | PascalCase (singular OR plural) | `TopicController`, `ClassesController` |
| Query classes | `Get{Resource}Query` | `GetTopicQuery` |
| Command classes | `{Action}{Resource}Command` | `CreateCalendarEventCommand` |
| Validators | `{Command}Validator` | `CreateCalendarEventCommandValidator` |
| Output DTOs | `{Resource}Output` | `TopicOutput` |
| Input DTOs | `{Resource}Input` | `TopicInput` |
| Service clients | `I{Resource}Client` | `ITopicClient` |
| Reference models | `{Entity}Reference` | `UnitReference` |
| Private fields | `_camelCase` | `_mediator`, `_client` |
| Namespaces | `SISApi.API.Features.{Domain}.{Resource}` | `SISApi.API.Features.Lesson.Topic` |

**Note:** Controller names use BOTH singular and plural in the codebase (e.g., `StaffController`, `ClassesController`). Either is acceptable.

### API Versioning

- Use `[ApiVersion("1.0")]` at class level
- Use `[MapToApiVersion("1.0")]` at action level
- API version passed as query parameter: `?api-version=1.0`

---

## 8. Dependency Injection Standards

### Constructor Injection (REQUIRED)

- All dependencies MUST be injected via constructor
- Store in `private readonly` fields with `_` prefix

```csharp
private readonly IMediator _mediator;
private readonly IResourceClient _client;

public Handler(IMediator mediator, IResourceClient client)
{
    _client = client;
    _serviceConfiguration = serviceConfiguration;
}
```

### Violations to Flag

- **warning**: Service instantiated with `new` instead of DI
- **info**: Missing null checks on constructor parameters (only ~50% of handlers use null checks)

---

## 9. Error Handling Standards

### Extension Methods (REQUIRED)

Use the established extension methods:
- `.GetResponseData<T>()` - deserialize or throw
- `.GetResult<T>()` - convert to FluentResult with status code mapping

### Violations to Flag

- **error**: Empty catch blocks (exceptions silently swallowed)
- **error**: `async void` methods
- **error**: Synchronous blocking calls (`.Result`, `.Wait()`, `.GetAwaiter().GetResult()`)
  - NOTE: `.Results` (plural, as in `PagedResult.Results`) is NOT a violation
- **warning**: `Result.Fail()` without `.WithMetadata("StatusCode", ...)`

---

## 10. Authorization & Security Standards

### Authentication (REQUIRED)

- External API calls: `[Authorize(AuthenticationSchemes = "ApiAuthentication")]`
- Developer portal: `[Authorize(AuthenticationSchemes = "ApimAuthentication")]`

### Role-Based Access (REQUIRED)

- Read operations: `[Authorize(Roles = "{Domain}Read")]` at class level
- Write operations: `[Authorize(Roles = "{Domain}Write")]` at action level

### School-Level Filtering (RECOMMENDED)

- Query handlers SHOULD add school filters based on user claims (~53% of handlers do this)
- Use `FilterExtensions.AddSchoolCodeFilterAsync()` or `AddConfigSchoolIdFilterAsync()`
- Requires `IUserAccessor` and `IConfigSchoolClient` to be injected

### Violations to Flag

- **error**: Endpoints without `[Authorize]` attributes
- **error**: Write endpoints without `{Domain}Write` role
- **warning**: Missing school-level filtering in new query handlers
- **warning**: Hardcoded user IDs or district IDs

---

## 11. Async / Await Standards

- All I/O operations MUST be async
- All handler methods SHOULD accept `CancellationToken cancellationToken`
- Pass `cancellationToken` to all downstream async calls
- Never use `.Result` or `.Wait()` (synchronous blocking)

### Violations to Flag

- **error**: Synchronous blocking calls (`.Result`, `.Wait()`, `.GetAwaiter().GetResult()`)
- **error**: `async void` methods (except event handlers)
- **warning**: Missing `CancellationToken` parameter

---

## 12. JSON Serialization Standards

Configured globally in `Startup.cs`:
- **Property naming**: camelCase (via `CamelCasePropertyNamesContractResolver`)
- **DateTime**: UTC (via `DateTimeZoneHandling.Utc`)
- **Null handling**: Ignore nulls (via `NullValueHandling.Ignore`)
- **Serializer**: Newtonsoft.Json (not System.Text.Json)

### Violations to Flag

- **warning**: Using `System.Text.Json` attributes (project uses Newtonsoft)

---

## 13. Testing Standards

### Test Framework

- **Unit Tests**: NUnit + NSubstitute + FluentAssertions
- **Integration Tests**: Feature-based test structure matching source. Use `WebApplicationFactory<T>` (or equivalent test fixture) + `HttpClient` to exercise endpoints end-to-end; assert on `HttpResponseMessage.StatusCode` (and body when relevant). Reference example: `nelnet-nbs/sis-externalapi#144`.

### Violations to Flag

- **warning**: Using Moq instead of NSubstitute

### Integration Test Standards (`SISApi.APITests/...`)

Standard pattern uses `FixtureBuilder.GetGatewayClient(ApiUrl.BaseUrl, ApiKey.X.Scopes).WithRoute(Method.GET, API_URL).Build().Execute()` followed by `Validators.ValidateStatusCode(...)`, `Validators.ValidateSchema<T>(...)`, and FluentAssertions. Reference: `GetStudentsHomeroomV1Tests.cs`.

- **warning**: Test class declared `internal class XxxTests` — must be `public class XxxTests`
- **warning**: Query string baked into URL — `WithRoute(Method.GET, $"{API_URL}?Filters=active==true")`. Use `.AddQuery("Filters", "active==true")` instead
- **warning**: Reflection-based property access for sort/filter assertions (`x.GetType().GetProperty(...)`). Use typed FluentAssertions: `Results.Should().BeInAscendingOrder(x => x.Id)`
- **warning**: Classic NUnit `Assert.AreEqual` / `Assert.LessOrEqual` / `Assert.IsTrue` / `Assert.That` in test bodies — use FluentAssertions `.Should().Be(...)`, `.Should().BeLessOrEqualTo(...)`, etc. (Note: `Assert.IsEmpty` is allowed — it's the standard for nullable-field checks.)
- **warning**: Sort test (method name `_Sort*_200`) missing `Should().BeInAscendingOrder(...)` / `Should().BeInDescendingOrder(...)` assertion
- **warning**: Test method has `[Retry(2)]` but no adjacent `[TestCaseId("NNNNNN")]`
- **warning**: New feature file (controller/command/query) added without a corresponding `SISApi.APITests` test in the same PR
- **info**: Fully-qualified `Newtonsoft.Json.JsonConvert.DeserializeObject` — add `using Newtonsoft.Json;` and use bare `JsonConvert`
- **info**: Any 200 test missing `response.Data.Should().NotBeNullOrEmpty()` (skipped for Filter/Sort/Pagination/Nullable/403/404 tests, where the focus is on a different assertion)
- **warning**: `*_DistrictWide*ReadAccess_200` or `*_DistrictWide*WriteAccess_200` basic happy-path test on a paged endpoint (`PagedResultTm<...>`) missing `pagedResult.PageSize.Should().Be(50)` — this is the project's standard default-page-size verification. Scoped to DistrictWide tests because SchoolSpecific equivalents skip it by convention (per-school data is variable)
- **error**: Hardcoded bearer token in integration test — pull tokens from fixtures / env vars

---

## 14. General Code Quality

### Violations to Flag

- **error**: Empty catch blocks
- **error**: `async void` methods
- **error**: Synchronous blocking (`.Result`, `.Wait()`)
- **warning**: `System.Text.Json` usage (use Newtonsoft)
- **warning**: Services created with `new` instead of DI
- **warning**: Placeholder strings in production code — but **not** the generator-mandated HATEOAS `Href = "Endpoint not yet implemented"`, which is established convention (see the §6 carve-out)
- **info**: `TODO`/`HACK`/`FIXME` comments
- **info**: `#region` blocks
- ~~**info**: Unused `using` statements~~ — NOT flagged by this review (compiler/IDE handles it; see §3 note re: `Academic.Service.Client` / `IConfigSchoolClient`)
- **info**: Missing `[ApplySieve]` on Output models used in paged queries

---

## 15. Public Change Log (`SISApi.API/Assets/PublicChangeLog.md`)

This file ships to consumers as the public FACTS API change log. Each entry MUST describe an endpoint/feature change in the canonical human-readable format, grouped under a date heading. **The date heading is the date the change lands (i.e. the current/merge date), not the date the branch was created.**

Two category subheadings are used:

```
## YYYY-MM-DD          (the current merge/release date — "today")

### Endpoint Additions

  * Added {Domain} > {Resource} GET Endpoint (version 1.0)

### Fixes

  * Fixed {Domain} > {Resource} {METHOD} Endpoint: {what changed} (version 1.0)
```

New endpoints go under `### Endpoint Additions` (`Added {Domain} > {Resource} {METHOD} Endpoint …`); bug fixes and behavior changes go under `### Fixes` (`Fixed {Domain} > {Resource} {METHOD} Endpoint: …`). Never leave the raw work-item title as the bullet under either.

### Date rule — existing entries keep their date; new changes are dated "today"

**Existing date headings and their bullets MUST NOT be re-dated.** A PR only adds an entry for *its own* change, dated to the day that change lands — the current/merge date ("today") **or later**, never an earlier/branch-creation date.

**There MUST be exactly one heading per date.** Do not emit two `## YYYY-MM-DD` headings for the same date (a common mistake is adding a fresh `### Fixes` block under a *new* copy of a date heading that already exists just below it for `### Endpoint Additions`). Resolve by one of:

- If the new change's land date differs from every existing heading (the normal case — "today" is later than the previous top entry), give it its **own new `## {today}` heading** at the top, with the appropriate `### Fixes` / `### Endpoint Additions` subheading. The pre-existing entry below keeps its original date untouched.
- If a heading for the land date **already exists**, add the new bullet under that existing heading's matching subheading (merge — do not create a second heading for the same date).

### How to Flag — ONE consolidated minor comment

Changelog problems are **minor / cosmetic**. Emit **exactly ONE `info` finding** for `PublicChangeLog.md` per PR (category `Documentation`), no matter how many of the issues below are present — do NOT raise a separate finding per issue. Anchor it at the first offending line, and in a single `message` + `suggestion` list every problem found so the developer fixes them in one pass.

Check for, and roll into that one comment, any of:

- **Wrong/stale date** — the new entry's `## YYYY-MM-DD` heading is earlier than the PR's current/merge date (commonly the branch-creation date left unchanged). The PR's own new entry MUST be dated to the day it lands ("today") or later. **Do NOT flag pre-existing entries below for being older — those correctly keep their original dates.**
- **Duplicate date heading** — two `## YYYY-MM-DD` headings for the **same date** (e.g. a new `### Fixes` block placed under a fresh copy of a date heading that already exists just below for `### Endpoint Additions`). There must be exactly one heading per date: either date the new entry to today (its own heading above the existing one) or merge its bullet under the existing same-date heading.
- **Duplicate entry** — the same endpoint documented more than once: a raw work-item bullet (`* AB#NNNNNN #NNNNNN [ExternalAPIGW] ...`) sitting alongside the proper canonical entry, and/or the same endpoint listed under more than one date heading. Each endpoint appears **once**, in canonical format.
- **Raw work-item text** used verbatim as a bullet (e.g. `Bug #283677 - [ExternalAPIGW] PATCH: People - reject non-RFC-6902 patch body with 400`) instead of the canonical `Fixed {Domain} > {Resource} {METHOD} Endpoint: … (version X.Y)` / `Added {Domain} > {Resource} … (version X.Y)` form.
- **Missing blank line** before a `### Endpoint Additions` / `### Fixes` subheading or between a date heading and its content (Markdown rendering).

Example consolidated comment (PR #187 — a PATCH fix landing 2026-07-17 above an existing 2026-07-15 additions entry):
> **message:** `PublicChangeLog.md: the new Fixes block introduces a second "## 2026-07-15" heading (duplicating the existing one below) and dates the fix earlier than its land date. Give the new fix its own "## 2026-07-17" heading (today), leave the existing 2026-07-15 Endpoint Additions entry unchanged, and rewrite the raw work-item bullet in canonical form.`
> **suggestion:** show the corrected top: `## 2026-07-17` → `### Fixes` → `* Fixed People > PersonBase PATCH Endpoint: now rejects non-RFC-6902 patch bodies with 400 (version 1.0)`, followed by the untouched `## 2026-07-15` → `### Endpoint Additions` block.
