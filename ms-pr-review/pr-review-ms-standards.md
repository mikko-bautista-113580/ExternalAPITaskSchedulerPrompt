# SIS Services (Microservices) - Coding Standards for PR Review

This document **operationalizes** the authoritative standard for the `sis-services` monorepo (40+
domain microservices):

> 📖 **THE STANDARD** — `sis-services/.architecture/microservices-architecture.md` (checked into the
> repo). That doc is the source of truth for every microservice. This rulebook exists only to (a) map
> its rules to review severities and (b) record real-world variance seen in merged PRs so the review
> stays precise. **Where this rulebook and the architecture doc disagree on what is REQUIRED, the
> architecture doc wins**, and a merged PR that breaks a REQUIRED rule is still a valid finding. The
> "observed variance / do-not-flag" notes below are false-positive guards only — they never downgrade a
> REQUIRED rule the doc states.

Rules are classified as:

- **REQUIRED** - Must be followed. Engine flags as **error**.
- **RECOMMENDED** - Should be followed in new code. Engine flags as **warning**.
- **NICE-TO-HAVE** - Good practice but not enforced. Engine flags as **info**.

> This is a MICROSERVICE rulebook, NOT the gateway (`sis-externalapi`) rulebook. Do **not** expect
> gateway-only constructs here: no `ExternalApiController`, no `ApiAuthentication`/`ApimAuthentication`
> scheme, no HATEOAS `ReferenceLink`/`ApimHelper`, no `I{Resource}Client` service clients. Microservice
> handlers own the data (EF `DbContext`) directly. **GET/list query handlers return `PagedResult<T>`
> directly** (verified in production); commands return `ActionResult<T>` (per the arch doc) — see §2/§3.

---

## 1. Repository & Service Structure

Each service is independently deployable and lives under `Services.{DomainName}/`. Standard layout:

```
Services.{DomainName}/
├── {DomainName}.Domain/           # Entities, interfaces, EF DbContext
├── {DomainName}.Service/          # API, Features, Controllers, Repositories
├── {DomainName}.Infrastructure/   # DI registration extensions
├── {DomainName}.Processor/        # Optional: background processing
└── {DomainName}.Tests/            # Unit + integration tests
```

- Service-to-service communication is via **Azure Service Bus**, **NOT** direct project references
  across services.

### Violations to Flag

- **warning**: A service directly referencing another service's project/assembly instead of
  communicating over Service Bus.
- **info**: New code placed in a layer that doesn't match its responsibility (e.g. EF entities in
  `.Service` instead of `.Domain`).

---

## 2. Architecture: Feature Folders + CQRS (REQUIRED)

Primary organization inside the `.Service` project is **feature folders**:

```
{DomainName}.Service/Features/{FeatureName}/
├── Commands/{ActionResource}/           # Write operations
│   ├── {Action}{Resource}Command.cs     (Command + NESTED Handler)
│   ├── {Action}{Resource}CommandValidator.cs
│   └── {Action}{Resource}Dto.cs
├── Queries/{GetResource}/               # Read operations
│   ├── Get{Resource}Query.cs            (Query + NESTED Handler)
│   ├── Get{Resource}QueryValidator.cs
│   └── {Resource}Dto.cs
├── Shared/                              # Feature-specific shared code
└── {Feature}Controller.cs              # Thin MediatR wrapper
```

### Key Rule (REQUIRED): nested Handler; return type depends on operation

Commands/Queries contain a **nested `Handler` class** (NOT a separate file). The **request** class is
`public`; only the **nested `Handler`** is `internal sealed` (the request itself may or may not be
`sealed` — both appear in the codebase, so do NOT flag a non-sealed request).

**The return type differs by operation — verified against real PRs, do NOT force one shape:**

- **GET / list queries → `PagedResult<{Dto}>` returned DIRECTLY** (NOT `ActionResult<T>`). This is
  what the architecture doc's own **Sieve / Pagination** section shows (`return result; //
  PagedResult<StudentDto>`), and it matches production across every service reviewed. The query
  extends `SieveModel` and implements `IRequest<PagedResult<{Dto}>>`; the controller action returns
  `Task<PagedResult<{Dto}>>`. (The doc's "Key Rule" line lumps queries in with commands under
  `ActionResult<T>`; the doc's Sieve section is the specific, authoritative case for paged queries.)

  ```csharp
  public class GetUserCashRegisterQueryV1 : SieveModel, IRequest<PagedResult<UserCashRegisterDto>>
  {
      internal sealed class Handler
          : IRequestHandler<GetUserCashRegisterQueryV1, PagedResult<UserCashRegisterDto>>
      {
          private readonly CashRegisterContext _context;
          private readonly ISieveService _sieveService;
          public Handler(CashRegisterContext context, ISieveService sieveService)
          { _context = context; _sieveService = sieveService; }

          public async Task<PagedResult<UserCashRegisterDto>> Handle(
              GetUserCashRegisterQueryV1 request, CancellationToken cancellationToken)
          {
              var q = _context.UserCashRegisters.AsNoTracking().Select(UserCashRegisterDto.Projection);
              return await _sieveService.GetPagedAsync(q, request, cancellationToken);
          }
      }
  }
  ```

- **Commands (Create/Update/Delete) → `ActionResult<{Dto}>`** (per the architecture reference), with
  FluentResults used for *internal* control flow (see §3). Example: `IRequest<ActionResult<SchoolYearDto>>`,
  `return new SchoolYearDto(entity);` (implicit conversion to `ActionResult<T>`).

  > ⚠️ No write/command PR was available when this rulebook was written — the command return shape
  > comes from the architecture doc, not a verified PR. When reviewing a command, **match the
  > neighboring commands in the same service** rather than hard-enforcing `ActionResult<T>`.

### Violations to Flag

- **error**: New feature code placed in a legacy root `Controllers/` / `Models/` layout instead of
  `Features/{FeatureName}/`.
- **warning**: Command/Query without a **nested** `Handler` class (separate handler file, or handler
  not nested inside the request).
- **warning**: Business logic placed directly in the controller instead of the MediatR handler.
- **info**: A GET query handler NOT returning `PagedResult<T>` (or a command return type that
  diverges from its neighbors) — confirm against sibling handlers before raising.

**Do NOT flag** (confirmed real patterns): a GET query returning `PagedResult<T>` (that is correct —
never demand `ActionResult<T>` for a query); a `public` (non-`sealed`) request class; a static
`Dto.Projection` expression vs an inline `.Select(x => new Dto{…})` (both fine).

---

## 3. Command Handlers & FluentResults for Internal Control Flow

**Applies to COMMANDS (writes), not GET queries** (queries return `PagedResult<T>` directly — see §2).
For commands: **HTTP concerns at the handler boundary → `ActionResult<T>`; business/validation control
flow inside private methods → FluentResults (`Result` / `Result<T>`).** Do not invert these.

```csharp
public async Task<ActionResult<EnrollmentDto>> Handle(
    EnrollStudentCommand request, CancellationToken cancellationToken)
{
    var validationResult = await ValidateEnrollment(request, cancellationToken);
    if (validationResult.IsFailed)
        return new BadRequestObjectResult(validationResult.Errors);   // map Result -> ActionResult

    // ... persist ...
    return new EnrollmentDto(enrollment);
}

private async Task<Result> ValidateEnrollment(EnrollStudentCommand request, CancellationToken ct)
{
    if (student is null)     return Result.Fail("Student not found");
    if (!student.IsActive)   return Result.Fail("Student is not active");
    return Result.Ok();
}
```

### Violations to Flag

- **warning**: A failed `Result` is ignored — `IsFailed` / `IsSuccess` not checked before proceeding.
- **warning**: Internal validation/business branching done by throwing/catching exceptions where a
  `Result` return would be the established pattern.
- **info**: A **command** handler returns a bare DTO/`Result<T>` to the HTTP layer instead of
  `ActionResult<T>` — confirm against neighboring commands in the same service. (Does NOT apply to
  queries, which correctly return `PagedResult<T>`.)

---

## 4. API Versioning (REQUIRED) — endpoint-level, NOT controller-level

Routes carry the version segment; each version maps to a **distinctly named** action so NSwag
generates separate client methods.

```csharp
[ApiController]
[Route("api/[Controller]/v{version:apiVersion}")]
[ApiVersion("1.0")]
[ApiVersion("2.0")]
public class SchoolYearController : ControllerBase
{
    [HttpPost]
    [MapToApiVersion("1.0")]
    public Task<ActionResult<SchoolYearDto>> CreateSchoolYearV1([FromBody] CreateSchoolYearCommandV1 cmd, CancellationToken ct)
        => _mediator.Send(cmd, ct);

    [HttpPost]
    [MapToApiVersion("2.0")]
    public Task<ActionResult<SchoolYearDto>> CreateSchoolYearV2([FromBody] CreateSchoolYearCommandV2 cmd, CancellationToken ct)
        => _mediator.Send(cmd, ct);
}
```

### Rules

- Route pattern: `api/[Controller]/v{version:apiVersion}/{action?}`.
- Version suffix (`V1`, `V2`) in **method names** → distinct NSwag client methods.
- Breaking changes require a **new** version; non-breaking changes (new optional field, new endpoint)
  may extend the existing version.
- Deprecated versions marked `[ApiVersion("1.0", Deprecated = true)]`.

### Deprecation — check the C# SOURCE, not generated clients

Every `.nswag` sets `ignoreObsoleteProperties: false`, so obsolete members still appear in generated
bindings and can look usable when they are not. Judge against the source. Indicators:

| Indicator | Where | Meaning |
| --- | --- | --- |
| `[ApiVersion("N.M", Deprecated = true)]` | Controller | Whole version deprecated. |
| `[Obsolete]` (bare) | Action | Deprecated, no replacement stated. |
| `[Obsolete("Use X instead")]` | Action | Deprecated; message names the replacement. |
| `[Obsolete]` on a DTO property | Request/response DTO | Field deprecated; a lower version may be needed. |
| `[Obsolete]` on an EF model property | Data model | Underlying field moved on; endpoint version is stale. |

### Violations to Flag

- **error**: New/changed endpoint missing `[ApiVersion]` on the controller or `[MapToApiVersion]` on
  the action when the controller declares multiple versions.
- **warning**: Multiple versions on a controller but action method names not suffixed with the
  version (`...V1`/`...V2`) — collides in NSwag client generation.
- **warning**: A breaking change (removed/renamed field, changed type/semantics) shipped on an
  existing version instead of a new one.
- **info**: New code consuming a member marked `[Obsolete]`; prefer the named replacement.

---

## 5. Controller Anatomy, Authorization & Security

### Controller shape (thin MediatR wrapper)

The controller is a thin wrapper: inject `IMediator`, delegate to `_mediator.Send(request, ct)`, no
business logic. The real, current shape (verified across `CashRegister`, `Admissions`):

```csharp
[Authorize]                                          // class-level (see note below)
[ApiVersion("1.0")]
[Route("api/[controller]/v{version:apiVersion}")]
[ApiController]
[ExcludeFromCodeCoverage]                            // common on MS controllers
public class UserCashRegisterController : AbstractMicroserviceController
{
    private readonly IMediator _mediator;
    public UserCashRegisterController(IMediator mediator) => _mediator = mediator;

    [HttpGet]
    [MapToApiVersion("1.0")]
    [ProducesDefaultResponseType]
    [ProducesResponseType(typeof(PagedResult<UserCashRegisterDto>), StatusCodes.Status200OK)]
    public async Task<PagedResult<UserCashRegisterDto>> GetUserCashRegisterV1(
        [FromQuery] GetUserCashRegisterQueryV1 request, CancellationToken cancellationToken)
        => await _mediator.Send(request, cancellationToken);
}
```

**Base class varies — do NOT hard-flag it:** newer controllers derive from
`AbstractMicroserviceController`; some (often older) use a **primary constructor**
(`public class XController(IMediator mediator)`) with no base class, or `ControllerBase`. Judge by the
service's own convention, not a single expected base type.

### Authorization

All microservices are protected by the internal authorization service using **JWT Bearer tokens**.

- Startup registers `services.RegisterAuthSettings(Configuration)` and
  `services.AddBearerTokenAuthentication(authSettings)`.
- An `AuthSettings` section (`AuthorityUrl`, `ClientId`, `Scope`) is configured.
- **The architecture doc REQUIRES `[Authorize]` at the controller class level** ("Every microservice
  must add `[Authorize]` to controllers"). This is the standard. Some older controllers omit it and
  lean on a global policy — that is a **deviation from the standard, not an alternative to it**.

### Violations to Flag

- **error** (REQUIRED by the doc): A new/changed controller with no `[Authorize]` at the class level
  and no explicit `[AllowAnonymous]`. This holds even if a global auth policy exists — the doc mandates
  the explicit attribute. (You may add a note that a global policy appears to cover it, but the missing
  `[Authorize]` is still the finding.) Only skip if the controller genuinely must be anonymous and says
  so with `[AllowAnonymous]` + a reason.
- **error**: Hardcoded credentials/tokens/connection strings, or hardcoded district/school/person IDs
  in production code.
- **warning**: A new service's startup missing `AddBearerTokenAuthentication()` /
  `RegisterAuthSettings()` wiring.
- **info**: `AuthSettings` values committed with real (non-placeholder) URLs/secrets.
- **info**: Missing `[ProducesResponseType]` / `[ProducesDefaultResponseType]` / `[ExcludeFromCodeCoverage]`
  on a new controller (present on recent PRs; treat as a nicety, not a blocker).

---

## 6. Multi-Tenancy (District-per-Database)

Current model is single-tenant, database-per-district:

1. Request carries the `x-districtCode` header.
2. Redis caches district → connection-string mappings.
3. `SIS.EFCore.RedisDistrict` resolves the connection string at runtime.
4. Each `DbContext` connects to the district-specific database.

Future direction: multi-tenant databases with `DistrictId` filtering (not all services migrated).

### Violations to Flag

- **error**: A cross-district data path that bypasses the district resolution (e.g. hardcoded/shared
  connection string, or a query that could read another district's data).
- **warning**: New query on a service already migrated to `DistrictId` filtering that omits the
  `DistrictId` predicate.

---

## 7. Activity Logging / Audit Trail (RECOMMENDED)

Auditable operations (Create, Update, Delete) SHOULD write an `ActivityLog`:

```csharp
_context.ActivityLogs.Add(new ActivityLog
{
    Type = "SchoolYear",
    Task = "CreateSchoolYear",
    Note = $"Created: {request.SchoolYear.YearName}",
    ModifiedBy = request.PersonId,
    ModifiedByDateTime = DateTime.Now,
    Source = "Academic -> CreateSchoolYearCommand"
});
```

### Violations to Flag

- **warning**: A Create/Update/Delete handler with no corresponding `ActivityLog` entry (where the
  service uses activity logging).
- **info**: `ActivityLog` present but missing `ModifiedBy` / `Source` context.

---

## 8. Data Access / Repository Pattern

- **Default**: use `DbContext` directly in handlers for simplicity.
- Use a **repository only** when: complex queries are reused across handlers, business logic needs
  encapsulation, or tests require mocking.

### Violations to Flag

- **info**: A repository introduced for a single trivial query (adds indirection without reuse).
- **warning**: Duplicated complex query logic across multiple handlers that should be shared.

---

## 9. Sieve — Filtering / Sorting / Pagination

Enable filtering/sorting with a **class-level** `[ApplySieve]`; do NOT decorate each property.

```csharp
using Sieve.Attributes;
using SIS.AspNetCore.EFCore.Sieve;

[ApplySieve]                         // class level — enables all properties
public class StudentDto
{
    public int StudentId { get; set; }
    public string LastName { get; set; }
}
```

Property-level `[Sieve(...)]` is only for overriding class behavior or custom filter names
(`[Sieve(CanFilter = true, Name = "customName")]`).

Pagination is offset-based via `Page`/`PageSize` on `SieveModel` (default **50**). Apply filtering +
sorting + pagination together with `GetPagedAsync`, returning `PagedResult<T>` (`CurrentPage`,
`PageSize`, `PageCount`, `RowCount`, auto-generated `NextPage`).

**Two paging abstractions exist — BOTH are correct, do NOT flag either:**

- `ISieveService.GetPagedAsync(queryable, sieveModel, ct)` — **3-arg** (no HttpRequest). Newer/simpler.
- `ISieveProcessor.GetPagedAsync(queryable, httpContext.Request, sieveModel, ct)` — **4-arg** (passes
  `IHttpContextAccessor.HttpContext.Request`, used when the next-page URL is built from the request).

The projected queryable is typically `_context.X.AsNoTracking().Select(Dto.Projection)` (a static
`Expression` on the DTO) **or** an inline `.Select(x => new Dto { … })` — both fine. School scoping,
when present, is applied to the queryable before paging (e.g.
`if (_requestContext.ConfigSchoolId != 0) q = q.Where(...)`).

```csharp
var result = await _sieveProcessor.GetPagedAsync(
    _context.Students.AsNoTracking(), httpRequest, sieveModel, cancellationToken);
return result;   // PagedResult<StudentDto>
```

### Violations to Flag

- **warning**: Every property decorated with `[Sieve(CanFilter..., CanSort...)]` individually instead
  of one class-level `[ApplySieve]`.
- **warning**: Manual `.Skip()/.Take()`/hand-rolled paging where `GetPagedAsync` is the pattern.
- **info**: Paged query not using `AsNoTracking()` on a read-only path.
- **info**: Paged DTO missing `[ApplySieve]`.

---

## 10. Validation (FluentValidation) — RECOMMENDED

Commands/Queries SHOULD have a matching `{Request}Validator` with user-facing messages.

### Violations to Flag

- **warning**: New command/query with meaningful input but no validator.
- **warning**: Validation rules without `.WithMessage(...)`.

---

## 11. Error Handling & Async (REQUIRED)

### Violations to Flag

- **error**: Empty catch blocks (exceptions silently swallowed).
- **error**: `async void` methods (except framework event handlers).
- **error**: Synchronous blocking on async — `.Result`, `.Wait()`, `.GetAwaiter().GetResult()`.
  - NOTE: `.Results` (plural, as in `PagedResult.Results`) is NOT a violation.
- **warning**: `SaveChangesAsync` / EF queries / downstream async calls not passed the
  `CancellationToken`.
- **warning**: Handler `Handle` method missing the `CancellationToken` parameter.

---

## 12. Naming Conventions

| Element | Convention | Example |
|---------|-----------|---------|
| Service folder | `Services.{DomainName}` (singular) | `Services.Academic` |
| Projects | `{DomainName}.{Layer}` | `Academic.Domain`, `Academic.Service` |
| Files | match the class name exactly | `CreateSchoolYearCommand.cs` |
| Commands | `{Action}{Resource}Command` | `CreateSchoolYearCommand` |
| Queries | `Get{Resource}Query` | `GetSchoolYearsQuery` |
| Validators | `{Request}Validator` | `CreateSchoolYearCommandValidator` |
| DTOs | `{Resource}Dto` / `Create{Resource}Dto` | `SchoolYearDto` |
| Async methods | suffix `Async` | `SaveChangesAsync` |
| Private fields | `_camelCase` | `_context`, `_logger` |

### Violations to Flag

- **warning**: File name not matching its primary class name.
- **warning**: Async method not suffixed `Async`.
- **info**: Private field without `_` prefix.

---

## 13. Dependency Injection

- All dependencies injected via constructor into `private readonly` fields.
- DI registration lives in the `{DomainName}.Infrastructure` extensions.

### Violations to Flag

- **warning**: Service/`DbContext`/client instantiated with `new` instead of injected.
- **info**: DI registrations added outside the `.Infrastructure` layer.

---

## 14. Testing — MS has TWO tiers (unit + integration)

> ⚠️ **This is the microservices pattern and it is NOT the gateway pattern.** Do NOT apply gateway
> rules here (no `FixtureBuilder.GetGatewayClient`, no required `[Retry(2)]`, no `public` test-class
> rule, no `PageSize.Should().Be(50)` rule). Verified across `Cafeteria` (#2903), `CashRegister`
> (#2776), `Admissions` (#2773), `Academic` (#1213).

A GET endpoint PR typically ships **both** of these:

| Tier | Location | Base fixture | Style |
| --- | --- | --- | --- |
| **Unit** (handler) | `{Service}.Tests/Features/{Feature}/Queries/…` | `UnitTestFixture` | in-memory `_context`, `HandleRequest(query)`, FluentAssertions, **no Verify, no `[TestCaseId]`** |
| **Integration** (API) | `{Service}.Tests/ApiTests/Features/{Feature}/Queries/…` | `ApiTest` | `IntegrationTestSdk` + **Verify snapshot** + `[TestCaseId]` + Faker/DataGenerator seeding |

Both fixture classes are **`internal`** — correct, do NOT flag.

### 14a. Integration tests (`{Service}.Tests/ApiTests`)

- Tests live in `{Service}.Tests/ApiTests/Features/{Feature}/Queries|Commands/` — mirroring the
  service's feature folders. NOT a separate legacy `*.IntegrationTests` project.
- Fixture class derives from the SDK base: `internal class Get{Resource}QueryV1Tests : ApiTest`.
  **`internal` is correct here — do NOT flag it.**
- Per-feature **test model** POCO `{Resource}DtoTm` lives in the test project's
  `Features/{Feature}/Shared/` folder and is `public class` — it is the deserialization target
  (`PagedResult<{Resource}DtoTm>`). ("Tm" = Test Model.)
- Imports: `IntegrationTestSdk.Builder/.Domain/.Helpers`, `FluentAssertions`, `VerifyNUnit`, `VerifyTests`.

### The canonical GET-list test shape

```csharp
internal class GetLunchOrdersStaffQueryV1Tests : ApiTest
{
    private VerifySettings _verifySettings;
    const string _ApiUrl = "api/LunchOrdersStaff/v1";

    public override async Task SetUp()
    { await base.SetUp(); _verifySettings = GetVerifierSettings(); }

    protected override VerifySettings GetVerifierSettings()
    {
        var settings = base.GetVerifierSettings();
        settings.ScrubMembers<LunchOrdersStaffDtoTm>(       // scrub volatile/identity fields
            dto => dto.Id, dto => dto.ItemNumber, dto => dto.SchoolCode, dto => dto.ConfigSchoolId);
        return settings;
    }

    [TestCaseId("277840")]
    public async Task GetLunchOrdersStaffV1_BasicRetrieval_200()
    {
        var helper = new LunchOrdersStaffHelper(Context);   // seed via EF Context
        await helper.GenerateAsync();

        var httpClientBuilder = HttpClientBuilder.GetClient(Client).WithRoute(HttpMethod.Get, _ApiUrl).Build();
        var httpResponse = await TestsHelper.Act<PagedResult<LunchOrdersStaffDtoTm>>(httpClientBuilder);

        Validators.ValidateStatusCode(httpResponse.StatusCode, HttpStatusCode.OK);
        httpResponse.ResponseDto.Results.Should().NotBeEmpty();
        await Verifier.Verify(httpResponse.ResponseDto, _verifySettings);   // snapshot -> *.verified.txt
    }
}
```

Key conventions:
- **Verify snapshot**: every test ends with `await Verifier.Verify(responseDto, _verifySettings)` and a
  paired `*.verified.txt` snapshot is committed. Non-deterministic values are scrubbed either via
  `settings.ScrubMembers<...Tm>(...)` or manually (e.g. `responseDto.NextPage = "{Scrubbed}"`).
- **Data seeding** goes through a seeding class that writes to the EF `Context` (not via the API). Its
  name and method vary by service — all are acceptable: `{Resource}Helper(Context).GenerateAsync()`
  (Cafeteria/Admissions/Academic; variants like `GenerateAsync(allowNulls: true)`) or a
  `{Resource}DataGenerator` with `GenerateXxx(Context)` (CashRegister). See §14c for the Faker/generator
  conventions.
- **Query params** use `.AddQuery("Filters", ...)` / `.AddQuery("Sorts", sortParam)` /
  `.AddQuery("PageSize", 2)` — NOT a query string baked into the route URL.
- **Assertions** are FluentAssertions (`.Should()...`) plus `Validators.ValidateStatusCode(...)`; sort
  tests assert `Results.Should().BeInAscendingOrder(x => x.Field)` / `BeInDescendingOrder(...)`.
- **`[TestCaseId("NNNNNN")]`** carries REAL ADO test-case IDs (never invented). It also doubles as a
  parameterized data source: `[TestCaseId("277842", "Id", TestName = "SortAscending_Id")]` (multiple
  attributes → one method covers several sort params).
- **Scenario coverage** for a GET-list endpoint typically includes: `_BasicRetrieval_200`, `_Filter_200`,
  ascending & descending `Sort`, `_Pagination_200`, `_EmptyDatabase_200`, `_NullableFields_200`, and the
  school-scoped variations. The school-scope naming depends on the scoping mechanism (both are real):
  filter-based → `_ConfigSchoolQueryExist_200` / `_...GreaterThanZero_200` / `_...DoesNotExist_200` /
  `_NegativeConfigSchoolQuery_200` / `_ZeroConfigSchoolQuery_200` /
  `_FilteredData(Exists|DoesNotExist)InConfigSchoolQuery_200`; header-based (`x-configSchoolId` via
  `IRequestContext`) → `_ConfigSchoolHeaderExist_200` / `_ConfigSchoolHeaderDoesNotExist_200` /
  `_NegativeConfigSchoolHeader_200` / `_ZeroConfigschoolHeader_200`. A simple endpoint with no school
  scoping (e.g. CashRegister) legitimately omits all of these — do not demand them.

### 14b. Unit tests (`{Service}.Tests/Features` — no `ApiTests` segment)

Handler-level unit tests live in `{Service}.Tests/Features/{Feature}/Queries/…` (note: NOT under
`ApiTests/`). They exercise the `Handler` directly against an in-memory context — **no HTTP, no Verify,
no `[TestCaseId]`**.

```csharp
internal class GetUserCashRegisterQueryTests : UnitTestFixture
{
    [Test]
    public async Task Handle_WithSorting_ReturnsSortedResults()
    {
        // Arrange
        var query = new GetUserCashRegisterQueryV1 { Sorts = "-Id", Page = 1, PageSize = 10 };
        _context.UserCashRegisters.AddRange(
            new() { Id = 1, RegisterName = "A" }, new() { Id = 3, RegisterName = "C" }, new() { Id = 2, RegisterName = "B" });
        await _context.SaveChangesAsync();

        // Act
        var paged = await HandleRequest(query);          // UnitTestFixture helper runs the handler

        // Assert
        paged.Results.Should().HaveCount(3);
        paged.Results.Should().BeInDescendingOrder(x => x.Id);
    }
}
```

Conventions: `internal class … : UnitTestFixture`; NUnit `[Test]`; method names `Handle_{Scenario}_{Expected}`;
seed via `_context.X.AddRange(...)` + `await _context.SaveChangesAsync()`; run via `await HandleRequest(query)`;
FluentAssertions (`Should().BeEquivalentTo(...)`, `BeInDescendingOrder(...)`, `HaveCount(...)`).

### 14c. Faker + data generators (`{Service}.Tests/ApiTests/Shared/...`)

Integration-test data is produced by **Bogus** fakers and seeded in bulk:

```csharp
public sealed class UserCashRegisterFaker : Faker<UserCashRegister>
{
    public UserCashRegisterFaker()
    {
        UseSeed(ApiTestConstants.BogusFakerSeedId);      // deterministic -> stable Verify snapshots
        RuleFor(x => x.Id, f => f.Random.Int(1, 1000));
        RuleFor(x => x.RegisterName, f => f.Company.CompanyName());
        // ...
    }
}
```

- Faker: `public sealed class {Entity}Faker : Faker<{Entity}>` in `ApiTests/Shared/Faker/`. **Must call
  `UseSeed(ApiTestConstants.BogusFakerSeedId)`** (or an explicit seed) — an unseeded Faker makes the
  Verify snapshot non-deterministic/flaky.
- Generator/Helper: seeds through `TestsHelpers.ExecuteConcurrentDatabaseOperationsAsync` +
  `TestsHelpers.BulkInsertDataAsync`, using `TestsHelpers.GenerateNewId(nameof(Entity))` for unique keys.

### Violations to Flag

- **warning**: New integration tests added to a legacy `*.IntegrationTests` project instead of
  `{Service}.Tests/ApiTests/Features/...`.
- **warning**: A new GET query shipped with an integration (`ApiTests`) test but **no handler unit
  test** under `{Service}.Tests/Features/...`, or vice-versa (the two tiers normally ship together).
- **warning**: A Bogus `Faker` that does not set a seed (`UseSeed(...)`) — Verify snapshots will be flaky.
- **warning**: New feature file (controller/command/query) added without a corresponding
  `{Service}.Tests/ApiTests` test in the same PR.
- **warning**: A GET-list test that does not call `await Verifier.Verify(...)` (breaks the snapshot
  convention), OR a new test method with no paired `*.verified.txt` committed.
- **warning**: Query string baked into the route URL — `WithRoute(HttpMethod.Get, $"{_ApiUrl}?Filters=...")`.
  Use `.AddQuery("Filters", "...")` instead.
- **warning**: `[TestCaseId(...)]` with a placeholder/invented ID (must be a real ADO test-case ID).
- **warning**: Non-deterministic field (e.g. `NextPage`, timestamps, identity IDs) left un-scrubbed so
  the Verify snapshot would be flaky.
- **warning**: Sort test missing `Should().BeInAscendingOrder(...)` / `BeInDescendingOrder(...)`.
- **warning**: Classic NUnit asserts (`Assert.AreEqual`, `Assert.IsTrue`, `Assert.That`, ...) in test
  bodies — use FluentAssertions `.Should()...`. (`Assert.IsEmpty` is acceptable.)
- **error**: Hardcoded bearer token / credentials in a test — auth comes from the `ApiTest` base
  fixture / `Client`.
- **error**: A committed `*.received.txt` (a Verify *failure* artifact that must never be checked in).

### Do NOT flag (MS test false positives)

- **`internal` test fixture classes** (`internal class ...Tests : ApiTest`) — this is the MS standard.
  (Contrast: the `{Resource}DtoTm` test-model POCO IS `public` — that's also correct.)
- **Missing `[Retry(2)]`** — retries are a gateway convention, not the MS convention. Do not require them.
- **Missing `PageSize.Should().Be(50)`** — that explicit assertion is a gateway rule; MS verifies paging
  through the Verify snapshot instead.
- **Cross-service naming drift** — test/seeding names vary by service and are all acceptable: test class
  `Get{X}QueryV1Tests` vs `Get{X}Tests` vs `{X}QueryTests`; seeding `{X}Helper` vs `{X}DataGenerator`;
  seeding method `GenerateAsync()` vs `Generate{X}(Context)`; query file `Get{X}Query.cs` (older) vs
  `Get{X}QueryV1.cs` in a `Queries/Get{X}/` subfolder (newer). Do not flag naming purely for not
  matching a sibling service — flag only within-service inconsistency.

---

## 15. Key Dependencies (context, not a checklist)

Shared `SIS.*` packages: `SIS.AspNetCore.App`, `SIS.EFCore.RedisDistrict`,
`SIS.ApplicationInsights.AspNetCore`, `SIS.ServiceBus`.
Standard: MediatR, FluentValidation, NSwag, Serilog, Sieve.

---

## Known False Positives — DO NOT FLAG

- **Unused `using` directives — never report these.** Reliable unused-using detection needs the
  compiler/IDE (IDE0005), not eyeballing namespaces. Do not assert a `using` is unused because the
  type "looks" foreign to the domain.
- **`internal sealed class Handler`** — the nested handler being `internal` is the **documented,
  correct** pattern here (do not flag it as "should be public").
- **`internal` integration-test fixtures** (`internal class ...Tests : ApiTest`) — also correct in MS
  (see §14). Do NOT flag them as "should be public". (The `{Resource}DtoTm` test-model POCO, however,
  is `public` — that's expected too.)
- **`ActionResult<T>` returned via implicit conversion from a DTO** (e.g. `return new SchoolYearDto(x);`)
  is correct — not a type mismatch.
- **`DateTime.Now`** in `ActivityLog` matches the documented example — do not flag it as "should be
  `UtcNow`" unless the surrounding service clearly standardizes on UTC.
- Any finding you can only justify by guessing which namespace a type comes from — if you can't see
  the declaration, don't assert it.

---

## Severity Mapping

REQUIRED violation → `error`; RECOMMENDED → `warning`; NICE-TO-HAVE → `info`.

**Finding categories** (use these exact strings so the report groups cleanly): `Architecture`,
`Feature Folders`, `Controller`, `CQRS`, `Handler`, `Versioning`, `Security`, `Multi-Tenancy`,
`Activity Log`, `Data Access`, `Sieve`, `Validation`, `Error Handling`, `Async`, `DTO & Model`,
`Naming`, `Dependency Injection`, `Testing`, `Integration Test`, `Code Quality`.
