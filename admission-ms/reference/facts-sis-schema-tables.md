# FACTS SIS Database Schema — Table Reference

This file is the detailed table catalog for the FACTS SIS database, extracted from `architecture.md` to keep that file focused on architecture. It documents every table provided so far, organized by schema, with columns, keys, foreign keys, triggers, and per-schema cross-reference summaries.

**How to use this file**: when the user asks about a specific table ("what columns does X have?", "which tables FK to Y?", "what's the difference between A and B?"), search this file for the table or schema name. Each schema has a cross-reference summary table at the end of its section for quick scanning when you only know what a table does, not its name.

**Conventions used throughout**:
- "Temporal table" means the table uses SQL Server system-versioning (`GENERATED ALWAYS AS ROW START/END` with `PERIOD FOR SYSTEM_TIME`) on its `ModifiedOnUTC` / `ModifiedOnUTCmax` columns, enabling point-in-time history queries.
- Foreign-key targets are written `schema.Table`. Self-referencing FKs are noted as "self".
- All SQL is MSSQL dialect. Datasource is always `#DSN#`; parameterize inputs with `<cfqueryparam>`.

The high-level schema map, multi-tenancy rules, and the short "Core FACTS tables" orientation list live in `architecture.md`.

---

### `aca` schema tables

The `aca` schema holds standards-based grading and attendance-conversion data.

#### `aca.AttendanceAbsenceConversionHistory`
Audit log of absence-conversion runs. One row per run per school/grade-level/date-range.

| Column | Type | Notes |
|---|---|---|
| `HistoryID` | int IDENTITY | PK |
| `ConfigSchoolID` | smallint | FK → `ConfigSchool`; indexed |
| `RunDate` | smalldatetime | Defaults to `GETUTCDATE()` |
| `GradeLevel` | nvarchar(50) | Grade level targeted by the run |
| `StartDate` / `EndDate` | date | Date window of the conversion |

---

#### `aca.CourseLevelAssignmentStandardGradeMap`
Maps a numeric assignment grade to a standards score at the **course-level** scope. Used when the grade map is shared across all classes at a given course level.

| Column | Type | Notes |
|---|---|---|
| `CourseLevelAssignmentStandardGradeMapId` | int IDENTITY | PK |
| `CourseLevelId` | int | FK → `dbo.CourseLevel.CourseLevelID` (CASCADE DELETE); indexed |
| `AssignmentGrade` | decimal(9,4) | Raw numeric grade; unique together with `CourseLevelId` |
| `StandardsGrade` | smallint | Mapped standards score |

---

#### `aca.GbkAssignmentsStandardMM`
Many-to-many link between gradebook assignments and standards. Each row tags one assignment/class/assessment combination with one standard.

| Column | Type | Notes |
|---|---|---|
| `ClassID` | int | PK (composite) |
| `AssessmentID` | int | PK (composite) |
| `AssignmentID` | int | PK (composite) |
| `StandardID` | int | PK (composite); FK → `aca.Standard.StandardID` |

FK to `dbo.GbkAssignments(AssessmentID, ClassID, AssignmentID)` with `ON UPDATE CASCADE`.

---

#### `aca.GbkAssignmentStandardGrade`
Per-student standard grade on a specific gradebook assignment. One row per student × class × assessment × assignment × standard.

| Column | Type | Notes |
|---|---|---|
| `GbkAssignmentStandardGradeId` | int IDENTITY | Unique (non-clustered); use for single-row lookups |
| `ClassID` | int | PK (composite); FK → `dbo.Classes` |
| `AssessmentID` | int | PK (composite) |
| `AssignmentID` | int | PK (composite) |
| `StandardID` | int | PK (composite); FK → `aca.Standard` |
| `StudentID` | int | PK (composite); FK → `dbo.Person` |
| `StudentGrade` | decimal(9,4) | Raw grade earned |
| `Notes` | nvarchar(max) | Optional teacher note; nullable |

FK to `dbo.GbkAssignments(AssessmentID, ClassID, AssignmentID)` with `ON UPDATE CASCADE`.

---

#### `aca.GbkAssignmentStandardGradeMap`
Maps a numeric assignment grade to a standards score at the **class** scope. Use this table when the grade map is customized per class (as opposed to `CourseLevelAssignmentStandardGradeMap` which is per course level).

| Column | Type | Notes |
|---|---|---|
| `GbkAssignmentStandardGradeMapId` | int IDENTITY | PK |
| `ClassId` | int | FK → `dbo.Classes.ClassID` (CASCADE DELETE); indexed |
| `AssignmentGrade` | decimal(9,4) | Raw numeric grade; unique together with `ClassId` |
| `StandardsGrade` | smallint | Mapped standards score |

---

#### Grade-map lookup pattern
When resolving a student's standards score from a raw assignment grade, check the class-level map first, then fall back to the course-level map:

```sql
-- 1. Class-level map (aca.GbkAssignmentStandardGradeMap)
SELECT TOP 1 StandardsGrade
FROM aca.GbkAssignmentStandardGradeMap WITH (NOLOCK)
WHERE ClassId = <cfqueryparam cfsqltype="cf_sql_integer" value="#ClassID#">
  AND AssignmentGrade = <cfqueryparam cfsqltype="cf_sql_decimal" value="#RawGrade#">

-- 2. Course-level fallback (aca.CourseLevelAssignmentStandardGradeMap)
SELECT TOP 1 StandardsGrade
FROM aca.CourseLevelAssignmentStandardGradeMap WITH (NOLOCK)
WHERE CourseLevelId = <cfqueryparam cfsqltype="cf_sql_integer" value="#CourseLevelID#">
  AND AssignmentGrade = <cfqueryparam cfsqltype="cf_sql_decimal" value="#RawGrade#">
```

---

#### `aca.Standard`
Master standards registry. Every standard-related table in the `aca` schema FK-references this table.

| Column | Type | Notes |
|---|---|---|
| `StandardID` | int IDENTITY | PK |
| `StandardPathID` | int | FK → `aca.StandardPath` (CASCADE); indexed |
| `Identifier` | nvarchar(128) | Short code; indexed; defaults to `''` |
| `Description` | nvarchar(4000) | Full text of the standard |
| `SortOrder` | int | Display order; defaults to 0 |
| `Source` | nvarchar(1000) | Origin/publisher; nullable |
| `StandardLevel` | int | Depth in the path hierarchy; auto-maintained by trigger |
| `OtherSystemID` | int | Cross-reference to external system; indexed |
| `Hidden` | bit | Hides from UI when `1` |
| `ShowOnReportCard` | bit | Controls report card visibility |

**Trigger** `TR_aca_Standard_InsertUpdate` (AFTER INSERT, UPDATE): walks `aca.StandardPath` via a recursive CTE to keep `StandardLevel` in sync with the path hierarchy depth.

---

#### `aca.LearningStandard`
Ed-Fi / interoperability mapping of an `aca.Standard` row to an external standard identifier.

| Column | Type | Notes |
|---|---|---|
| `LearningStandardID` | int IDENTITY | PK |
| `SISStandardID` | int | FK → `aca.Standard.StandardID` |
| `Description` | nvarchar(1024) | Required description |
| `LearningStandardIdentifier` | nvarchar(60) | External identifier (required) |
| `LearningStandardItemCode` | nvarchar(60) | Optional item code |
| `LearningStandardCategoryDescriptorID` | uniqueidentifier | Category descriptor; nullable |
| `LearningStandardScopeDescriptorID` | uniqueidentifier | Scope descriptor; nullable |
| `ParentLearningStandardID` | nvarchar(60) | Parent standard reference; nullable |
| `SuccessCriteria` | nvarchar(150) | Optional success criteria |

---

#### `aca.LearningObjective`
Self-referencing hierarchy of learning objectives (Ed-Fi model). Independent of `aca.Standard` — no FK to it.

| Column | Type | Notes |
|---|---|---|
| `LearningObjectiveID` | int IDENTITY | PK |
| `Namespace` | nvarchar(255) | Required namespace |
| `LearningObjectiveIdentifier` | nvarchar(60) | Required; unique together with `Namespace` |
| `Objective` | nvarchar(60) | Required label |
| `Description` | nvarchar(1024) | Optional full text |
| `Nomenclature` | nvarchar(100) | Optional naming convention hint |
| `SuccessCriteria` | nvarchar(150) | Optional |
| `ParentLearningObjectiveID` | int | Self-FK → `aca.LearningObjective`; nullable |

---

#### `aca.GbkStandardSummary`
Calculated per-student standard average per class per term. Updated by the gradebook grading engine.

| Column | Type | Notes |
|---|---|---|
| `GbkStandardSummaryId` | int IDENTITY | PK (clustered) |
| `ClassID` | int | FK → `dbo.Classes` (CASCADE); part of unique key |
| `StudentID` | int | FK → `dbo.Person` (CASCADE); part of unique key |
| `TermID` | int | Part of unique key |
| `StandardID` | int | FK → `aca.Standard` (CASCADE); part of unique key |
| `Average` | decimal(9,4) | Computed average grade for the standard |

Unique constraint on `(ClassID, StudentID, TermID, StandardID)`.

---

#### `aca.SBGTermGrade`
Standards-Based Grading term grade — the official letter/descriptor grade given to a student for a standard in a class term. Distinct from the numeric `Average` in `GbkStandardSummary`.

| Column | Type | Notes |
|---|---|---|
| `SbgTermGradeId` | int IDENTITY | Unique (non-clustered); use for single-row lookups |
| `ClassID` | int | PK (composite); FK → `dbo.Classes` |
| `StudentID` | int | PK (composite); FK → `dbo.Person` |
| `TermID` | int | PK (composite) |
| `StandardID` | int | PK (composite); FK → `aca.Standard` |
| `Grade` | nvarchar(10) | Letter/descriptor grade; nullable |
| `Comment` | nvarchar(1000) | Teacher comment; nullable |

---

#### `aca.GbkLessonPlanStandardMM`
Links a class's lesson plan entry (by date) to one or more standards. Represents the standard(s) addressed on a given day.

| Column | Type | Notes |
|---|---|---|
| `ClassID` | int | PK (composite); FK → `dbo.Classes` |
| `StandardID` | int | PK (composite); FK → `aca.Standard` |
| `PlanDate` | datetime | PK (composite); defaults to `GETDATE()` |

---

#### `aca.MasterLessonPlanStandardMM`
Links a master lesson plan entry (course + staff + day) to a standard. Mirrors `GbkLessonPlanStandardMM` at the course/master-plan level rather than the class/date level.

| Column | Type | Notes |
|---|---|---|
| `CourseID` | int | PK (composite) |
| `StaffID` | int | PK (composite) |
| `Day` | int | PK (composite) |
| `StandardID` | int | PK (composite); FK → `aca.Standard` |

FK to `dbo.MasterLessonPlan(CourseID, StaffID, Day)` with `ON UPDATE CASCADE`.

---

#### `aca.PersonStandardizedTest`
Header record for one standardized test event for a person. Syncs to legacy `dbo.TestData` via three triggers.

| Column | Type | Notes |
|---|---|---|
| `PersonStandardizedTestID` | int IDENTITY | PK |
| `PersonID` | int | FK → `dbo.Person` (CASCADE) |
| `StandardizedTestConfigurationID` | int | FK → `aca.StandardizedTestConfiguration` (CASCADE) |
| `TestDate` | datetime | Date of the test |
| `GradeLevel` | nvarchar(50) | Grade level at time of test; nullable |
| `ExcludeFromTranscript` | bit | Defaults to `0` |
| `TestNote` | nvarchar(255) | Optional note |
| `LegacyTestDataID` | int | Cross-reference to `dbo.TestData`; set by insert trigger |

**Triggers** (AFTER INSERT / UPDATE / DELETE): keep `dbo.TestData` in sync. On INSERT, creates a `dbo.TestData` row (when `LegacyTestID` is set on the test config) and back-fills `LegacyTestDataID`. On UPDATE, propagates changed fields. On DELETE, removes the linked `dbo.TestData` row.

---

#### `aca.PersonStandardizedTestScore`

> **Note**: SQL DDL not provided — table exists as a referenced dependency of `aca.PersonStandardizedTest`. Document columns here when the schema becomes available.

---

#### `aca.StaffSectionAssociation`
Ed-Fi-style association between a staff member and a course section, including date range and classroom position.

| Column | Type | Notes |
|---|---|---|
| `StaffSectionAssociationId` | int IDENTITY | Part of composite PK |
| `SectionIdentifier` | nvarchar(255) | Part of composite PK |
| `StaffId` | int | Part of composite PK; FK → `dbo.Person`; indexed |
| `SessionId` | int | FK → `cnfg.Session`; indexed |
| `LocalCourseId` | int | FK → `crse.CourseCore`; indexed |
| `BeginDate` | date | Required start date |
| `EndDate` | date | Nullable end date |
| `ClassroomPositionDescriptorId` | uniqueidentifier | Required role descriptor |
| `HighlyQualifiedTeacher` | bit | Defaults to `0` |
| `PercentageContribution` | decimal(9,4) | Nullable |
| `TeacherStudentDataLinkExclusion` | bit | Defaults to `0`; nullable |

Note: FKs reference `cnfg.Session` and `crse.CourseCore` — two schemas beyond `aca` and `dbo`.

---

#### `aca.StandardCoursesMM`
Many-to-many link between standards and courses. Both FKs cascade on delete and update.

| Column | Type | Notes |
|---|---|---|
| `StandardID` | int | PK (composite); FK → `aca.Standard` (CASCADE) |
| `CourseID` | int | PK (composite); FK → `crse.CourseCore` (CASCADE) |

---

#### `aca.StandardizedTestConfiguration`
Master configuration record for a standardized test type. Scoped to a school or district-wide (when `ConfigSchoolID` is NULL). Syncs to legacy `dbo.TestConfig` via three triggers.

| Column | Type | Notes |
|---|---|---|
| `StandardizedTestConfigurationID` | int IDENTITY | PK |
| `ConfigSchoolID` | smallint | FK → `dbo.ConfigSchool`; NULL = district-wide |
| `TestName` | nvarchar(50) | Display name |
| `ShowOnTranscript` | bit | Defaults to `0` |
| `LegacyTestID` | int | Cross-reference to `dbo.TestConfig.TestID`; set by insert trigger |

**Triggers** (AFTER INSERT / UPDATE / DELETE): keep `dbo.TestConfig` in sync. On INSERT, creates a `dbo.TestConfig` row and back-fills `LegacyTestID`. On UPDATE, propagates `TestName`, `ShowOnTranscript`, and school/district-wide flag changes. On DELETE, removes the linked `dbo.TestConfig` row.

---

#### `aca.StandardizedTestAssessment`
Ed-Fi Assessment entity — describes a standardized test instrument (not a student result). Identified by `(Namespace, AssessmentIdentifier)`.

| Column | Type | Notes |
|---|---|---|
| `StandardizedTestAssessmentId` | int IDENTITY | PK |
| `AssessmentIdentifier` | nvarchar(60) | Required; unique with `Namespace` |
| `Namespace` | nvarchar(255) | Required; defaults to `'Unknown'` |
| `AssessmentTitle` | nvarchar(255) | Required display name |
| `AssessmentFamily` | nvarchar(60) | Optional family grouping |
| `AssessmentForm` | nvarchar(60) | Optional form variant |
| `AssessmentVersion` | int | Optional version number |
| `AdaptiveAssessment` | bit | Defaults to `0` |
| `AssessmentCategoryDescriptorId` | uniqueidentifier | Optional category descriptor |
| `EducationOrganizationId` | int | Optional org reference |
| `MaxRawScore` | decimal(19,5) | Optional max score |
| `Nomenclature` | nvarchar(100) | Optional |
| `RevisionDate` | date | Optional |

All child assessment tables below FK into this table via `StandardizedTestAssessmentId`.

---

#### `aca.StandardizedTestAssessmentAcademicSubject`
Academic subjects covered by an assessment. One row per assessment × subject descriptor.

| Column | Type | Notes |
|---|---|---|
| `StandardizedTestAssessmentAcademicSubjectId` | int IDENTITY | PK (non-clustered) |
| `StandardizedTestAssessmentId` | int | FK → `aca.StandardizedTestAssessment`; clustered unique with `AcademicSubjectDescriptorId` |
| `AcademicSubjectDescriptorId` | uniqueidentifier | Required |

---

#### `aca.StandardizedTestAssessmentContentStandard`
Content standard metadata for an assessment (publication info, mandating org). One row per assessment (unique clustered on `StandardizedTestAssessmentId`).

| Column | Type | Notes |
|---|---|---|
| `StandardizedTestAssessmentContentStandardId` | int IDENTITY | PK (non-clustered) |
| `StandardizedTestAssessmentId` | int | FK → `aca.StandardizedTestAssessment`; unique clustered |
| `Title` | nvarchar(75) | Required |
| `BeginDate` / `EndDate` | date | Effective date range; nullable |
| `PublicationDate` | date | Nullable |
| `PublicationYear` | smallint | Nullable |
| `PublicationStatusDescriptorId` | uniqueidentifier | Nullable |
| `MandatingEducationOrganizationId` | bigint | FK → `cnfg.EducationOrganization`; nullable |
| `URI` | nvarchar(255) | Nullable |
| `Version` | nvarchar(50) | Nullable |

---

#### `aca.StandardizedTestAssessmentGradeLevelsMM`
Grade levels for which an assessment is applicable. One row per assessment × grade level.

| Column | Type | Notes |
|---|---|---|
| `StandardizedTestAssessmentId` | int | PK (composite); FK → `aca.StandardizedTestAssessment` |
| `SISGradeLevelId` | int | PK (composite); FK → `dbo.GradeLevels`; indexed |

---

#### `aca.StandardizedTestAssessmentPlatformType`
Delivery platforms supported by an assessment (e.g. paper, online). One row per assessment × platform descriptor.

| Column | Type | Notes |
|---|---|---|
| `StandardizedTestAssessmentPlatformTypeID` | int IDENTITY | PK |
| `StandardizedTestAssessmentID` | int | FK → `aca.StandardizedTestAssessment`; unique with `PlatformTypeDescriptorID` |
| `PlatformTypeDescriptorID` | uniqueidentifier | Required |

---

#### `aca.StandardizedTestAssessmentProgram`
Programs associated with an assessment. One row per assessment × program.

| Column | Type | Notes |
|---|---|---|
| `StandardizedTestAssessmentProgramId` | int IDENTITY | PK |
| `StandardizedTestAssessmentId` | int | FK → `aca.StandardizedTestAssessment` |
| `ProgramId` | int | FK → `prgm.Program` |

---

#### `aca.StandardizedTestAssessmentScore`
Score result metadata for an assessment — defines the reporting method, score range, and data type. One row per assessment × reporting method (unique clustered).

| Column | Type | Notes |
|---|---|---|
| `StandardizedTestAssessmentScoreId` | int IDENTITY | PK (non-clustered) |
| `StandardizedTestAssessmentId` | int | FK → `aca.StandardizedTestAssessment`; unique clustered with `AssessmentReportingMethodDescriptorId` |
| `AssessmentReportingMethodDescriptorId` | uniqueidentifier | Required |
| `MinimumScore` / `MaximumScore` | nvarchar(35) | Nullable |
| `ResultDatatypeTypeDescriptorId` | uniqueidentifier | Nullable |

---

#### `aca.StandardizedTestAssessmentSection`
Links an assessment to a specific course section and school year (Ed-Fi section reference).

| Column | Type | Notes |
|---|---|---|
| `StandardizedTestAssessmentSectionID` | int IDENTITY | PK |
| `StandardizedTestAssessmentID` | int | FK → `aca.StandardizedTestAssessment`; part of unique key |
| `SISCourseID` | int | FK → `crse.CourseCore`; part of unique key |
| `SchoolYearID` | int | FK → `dbo.SchoolYear`; part of unique key |
| `EdFiSectionID` | int | FK → `crse.EdFiSection`; part of unique key |

Unique constraint on `(SISCourseID, SchoolYearID, EdFiSectionID, StandardizedTestAssessmentID)`.

---

#### `aca.StandardPath`
Hierarchical tree of standard path nodes (folders/groups). Each node belongs to a school (`ConfigSchoolID`) and may have a parent. Root nodes have `ParentPathID = NULL`. `aca.Standard` rows point to a `StandardPath` leaf.

| Column | Type | Notes |
|---|---|---|
| `StandardPathID` | int IDENTITY | PK |
| `ConfigSchoolID` | smallint | FK → `dbo.ConfigSchool` (CASCADE); indexed; auto-propagated from parent by trigger |
| `ParentPathID` | int | Self-FK → `aca.StandardPath`; NULL = root; indexed |
| `Name` | nvarchar(1000) | Required; indexed |
| `Description` | nvarchar(4000) | Nullable |
| `SortOrder` | int | Defaults to 0 |
| `OtherSystemID` | int | Cross-reference; indexed; defaults to 0 |
| `StandardPathLevel` | int | Depth from root; auto-maintained by trigger; indexed |
| `Hidden` | bit | Defaults to `0` |
| `ShowOnReportCard` | bit | Defaults to `0` |
| `CalculationMethodType` | smallint | Defaults to 0 |

**Check constraint** `CK_aca_StandardPath_CheckParentPathID`: calls `aca.CheckStandardCycle(ParentPathID)` to prevent circular references.

**Trigger** `TR_aca_StandardPath_InsertUpdate` (AFTER INSERT, UPDATE): uses two recursive CTEs — one to propagate `ConfigSchoolID` down from the parent root, and one to keep `StandardPathLevel` in sync with hierarchy depth.

---

#### `aca.StandardPathTermGrade`
Per-student computed term grade rolled up to a standard path node (rather than an individual standard). Supports report-card display of path-level aggregate grades.

| Column | Type | Notes |
|---|---|---|
| `StandardPathTermGradeId` | int IDENTITY | PK |
| `StandardPathId` | int | FK → `aca.StandardPath`; indexed |
| `ClassId` | int | FK → `dbo.Classes`; indexed |
| `StudentId` | int | FK → `dbo.Person`; indexed |
| `LegacyTermId` | smallint | Term reference (legacy ID) |
| `Grade` | decimal(9,4) | Computed path-level grade |

Unique constraint on `(StandardPathId, ClassId, StudentId, LegacyTermId)`.

---

#### `aca.StandardSkillSetMM`
Many-to-many link between standards and skill-set skills (`dbo.SS_Skills`). Allows a standard to be mapped to one or more existing skill-set entries.

| Column | Type | Notes |
|---|---|---|
| `StandardID` | int | PK (composite); FK → `aca.Standard` |
| `SkillID` | int | PK (composite); FK → `dbo.SS_Skills` |

---

#### `aca.StandardizedTestConfigurationScore`
Defines the named score slots (up to 20) for a test configuration. Each row is one score label at a given `SortOrder` position. Syncs to `dbo.TestConfig.Score1Label`…`Score20Label` via three triggers.

| Column | Type | Notes |
|---|---|---|
| `StandardizedTestConfigurationID` | int | PK (composite); FK → `aca.StandardizedTestConfiguration` (CASCADE) |
| `SortOrder` | int | PK (composite); 1–20; maps to `Score{N}Label` columns in `dbo.TestConfig` |
| `ScoreName` | nvarchar(50) | Label for this score slot |

**Triggers** (AFTER INSERT / UPDATE / DELETE): for each changed row, updates the matching `Score{N}Label` column in `dbo.TestConfig` (using `SortOrder` as `N`). DELETE sets the label to `''`; INSERT/UPDATE sets it to `ScoreName`.

---

#### `aca.StudentAcademicRecord`
Ed-Fi student academic record — cumulative and session-level credit/GPA summary per student per session. One row per student × session (unique).

| Column | Type | Notes |
|---|---|---|
| `StudentAcademicRecordID` | int IDENTITY | PK |
| `StudentID` | int | FK → `dbo.Person`; part of unique key |
| `SessionID` | int | FK → `cnfg.Session`; indexed; part of unique key |
| `CumulativeEarnedCredits` / `CumulativeAttemptedCredits` | decimal(9,3) | Nullable |
| `CumulativeEarnedCreditConversion` / `CumulativeAttemptedCreditConversion` | decimal(9,2) | Nullable |
| `CumulativeEarnedCreditTypeDescriptorID` / `CumulativeAttemptedCreditTypeDescriptorID` | uniqueidentifier | Nullable |
| `CumulativeGradePointsEarned` | decimal(18,4) | Nullable |
| `CumulativeGradePointAverage` | decimal(18,4) | Nullable |
| `GradeValueQualifier` | nvarchar(80) | Nullable |
| `ProjectedGraduationDate` | date | Nullable |
| `SessionEarnedCredits` / `SessionAttemptedCredits` | decimal(9,3) | Nullable |
| `SessionEarnedCreditConversion` / `SessionAttemptedCreditConversion` | decimal(9,2) | Nullable |
| `SessionEarnedCreditTypeDescriptorID` / `SessionAttemptedCreditTypeDescriptorID` | uniqueidentifier | Nullable |
| `SessionGradePointsEarned` | decimal(18,4) | Nullable |
| `SessionGradePointAverage` | decimal(18,4) | Nullable |

---

#### `aca.StudentAcademicRecordDiploma`
Diploma award records linked to a student academic record. One row per diploma type × award date per record (unique).

| Column | Type | Notes |
|---|---|---|
| `StudentAcademicRecordDiplomaID` | int IDENTITY | PK |
| `StudentAcademicRecordID` | int | FK → `aca.StudentAcademicRecord`; part of unique key |
| `DiplomaAwardDate` | date | Required; part of unique key |
| `DiplomaTypeDescriptorID` | uniqueidentifier | Required; part of unique key |
| `DiplomaLevelDescriptorID` | uniqueidentifier | Nullable |
| `CTECompleter` | bit | Defaults to `0` |
| `DiplomaDescription` | nvarchar(80) | Nullable |
| `DiplomaAwardExpiresDate` | date | Nullable |
| `AchievementTitle` / `AchievementCategorySystem` | nvarchar | Nullable |
| `AchievementCategoryDescriptorID` | uniqueidentifier | Nullable |
| `IssuerName` / `IssuerOriginURL` | nvarchar | Nullable |
| `Criteria` / `CriteriaURL` / `EvidenceStatement` / `ImageURL` | nvarchar | Nullable |

---

#### `aca.StudentStandardizedTestAssessment`
Header record for one student's sitting of an Ed-Fi standardized assessment. All `StudentAssessment*` child tables FK to this row.

| Column | Type | Notes |
|---|---|---|
| `StudentStandardizedTestAssessmentID` | int IDENTITY | PK |
| `StandardizedTestAssessmentID` | int | FK → `aca.StandardizedTestAssessment`; indexed |
| `SISStudentID` | int | FK → `dbo.Person`; indexed |
| `SchoolYearID` | int | FK → `dbo.SchoolYear`; indexed |
| `GradeLevelDescriptorId` | uniqueidentifier | Required grade level at time of sitting |
| `AdministrationDate` / `AdministrationEndDate` | datetime2 | Nullable test window |
| `AdministrationLanguageDescriptorID` | uniqueidentifier | Nullable |
| `AdministrationEnvironmentDescriptorID` | uniqueidentifier | Nullable |
| `AssessedMinutes` | int | Nullable |
| `EventCircumstanceDescriptorID` | uniqueidentifier | Nullable |
| `EventDescription` | nvarchar(1024) | Nullable |
| `PlatformTypeDescriptorID` | uniqueidentifier | Nullable |
| `ReasonNotTestedDescriptorID` | uniqueidentifier | Nullable |
| `RetestIndicatorDescriptorID` | uniqueidentifier | Nullable |
| `ReportedSchoolIdentifier` | nvarchar(60) | Nullable |
| `SerialNumber` | nvarchar(60) | Nullable |

---

#### `aca.StudentAssessmentAccommodation`
Records testing accommodations granted to a student for a specific standardized test sitting.

| Column | Type | Notes |
|---|---|---|
| `StudentAssessmentAccommodationID` | int IDENTITY | PK |
| `StandardizedTestAssessmentID` | int | FK → `aca.StandardizedTestAssessment`; indexed |
| `StudentStandardizedTestAssessmentID` | int | FK → `aca.StudentStandardizedTestAssessment`; indexed |
| `AccommodationDescriptorID` | uniqueidentifier | Required; unique (non-clustered) |

---

#### `aca.StudentAssessmentItem`
Individual item responses within a student's standardized test sitting. One row per item per sitting.

| Column | Type | Notes |
|---|---|---|
| `StudentAssessmentItemID` | int IDENTITY | PK |
| `StudentStandardizedTestAssessmentID` | int | FK → `aca.StudentStandardizedTestAssessment`; indexed |
| `IdentificationCode` | nvarchar(60) | Item identifier; unique (non-clustered) |
| `AssessmentItemResultDescriptorID` | uniqueidentifier | Required |
| `AssessmentResponse` | nvarchar(255) | Nullable |
| `DescriptiveFeedback` | nvarchar(1024) | Nullable |
| `ResponseIndicatorDescriptorID` | uniqueidentifier | Nullable |
| `RawScoreResult` | decimal(19,5) | Nullable |
| `TimeAssessed` | nvarchar(30) | Nullable |

---

#### `aca.StudentAssessmentPerformanceLevel`
Performance level achieved by a student on an assessment, per reporting method. Multiple rows per sitting are possible (one per reporting method × performance level descriptor).

| Column | Type | Notes |
|---|---|---|
| `StudentAssessmentPerformanceLevelID` | int IDENTITY | Part of composite PK |
| `AssessmentReportingMethodDescriptorID` | uniqueidentifier | Part of composite PK |
| `PerformanceLevelDescriptorID` | uniqueidentifier | Part of composite PK |
| `StandardizedTestAssessmentID` | int | FK → `aca.StandardizedTestAssessment`; indexed |
| `StudentStandardizedTestAssessmentID` | int | FK → `aca.StudentStandardizedTestAssessment`; indexed |
| `PerformanceLevelIndicatorName` | nvarchar(60) | Nullable |

---

#### `aca.StudentAssessmentPeriod`
Assessment period (window) associated with a student's test sitting. One row per sitting (unique clustered on `StudentStandardizedTestAssessmentID`).

| Column | Type | Notes |
|---|---|---|
| `StudentAssessmentPeriodID` | int IDENTITY | PK (non-clustered) |
| `StudentStandardizedTestAssessmentID` | int | FK → `aca.StudentStandardizedTestAssessment`; unique clustered |
| `AssessmentPeriodDescriptorID` | uniqueidentifier | Required |
| `BeginDate` / `EndDate` | date | Nullable window dates |

---

#### `aca.StudentAssessmentScoreResult`
Overall score result for a student's test sitting, per reporting method. One row per sitting (unique on `StudentStandardizedTestAssessmentID`).

| Column | Type | Notes |
|---|---|---|
| `StudentAssessmentScoreResultID` | int IDENTITY | Part of composite PK |
| `AssessmentReportingMethodDescriptorID` | uniqueidentifier | Part of composite PK |
| `StudentStandardizedTestAssessmentID` | int | FK → `aca.StudentStandardizedTestAssessment`; unique (non-clustered) |
| `Result` | nvarchar(35) | Score value as string |
| `ResultDatatypeTypeDescriptorID` | uniqueidentifier | Required |

---

#### `aca.StudentAssessmentStudentObjectiveAssessment`
Sub-assessment (objective) results within a student's test sitting. Identified by `(StudentAssessmentStudentObjectiveAssessmentID, IdentificationCode)`.

| Column | Type | Notes |
|---|---|---|
| `StudentAssessmentStudentObjectiveAssessmentID` | int IDENTITY | Part of composite PK |
| `IdentificationCode` | nvarchar(60) | Part of composite PK; unique (non-clustered) |
| `StudentStandardizedTestAssessmentID` | int | FK → `aca.StudentStandardizedTestAssessment`; indexed |
| `AssessmentIdentifier` | nvarchar(60) | Defaults to `''` |
| `Namespace` | nvarchar(255) | Defaults to `''` |
| `AssessedMinutes` | int | Nullable |
| `AdministrationDate` / `AdministrationEndDate` | datetime2 | Nullable |

---

#### `aca.StudentAssessmentStudentObjectiveAssessmentPerformanceLevel`
Performance level for a specific sub-assessment within a sitting. One row per sitting × item code × reporting method × performance level (unique clustered).

| Column | Type | Notes |
|---|---|---|
| `StudentAssessmentStudentObjectiveAssessmentPerformanceLevelID` | int IDENTITY | PK (non-clustered) |
| `StudentStandardizedTestAssessmentID` | int | FK → `aca.StudentStandardizedTestAssessment`; indexed |
| `IdentificationCode` | nvarchar(60) | Sub-assessment item code |
| `AssessmentReportingMethodDescriptorID` | uniqueidentifier | Required |
| `PerformanceLevelDescriptorID` | uniqueidentifier | Required |
| `PerformanceLevelIndicatorName` | nvarchar(60) | Nullable |

Unique clustered on `(StudentStandardizedTestAssessmentID, IdentificationCode, AssessmentReportingMethodDescriptorID, PerformanceLevelDescriptorID)`.

---

#### `aca.StudentAssessmentStudentObjectiveAssessmentScoreResult`
Score result for a specific sub-assessment within a sitting. One row per sub-assessment × reporting method (unique on `StudentAssessmentStudentObjectiveAssessmentID + IdentificationCode + AssessmentReportingMethodDescriptorID`).

| Column | Type | Notes |
|---|---|---|
| `StudentAssessmentStudentObjectiveAssessmentScoreResultID` | int IDENTITY | PK |
| `StudentAssessmentStudentObjectiveAssessmentID` | int | FK → `aca.StudentAssessmentStudentObjectiveAssessment` (composite with `IdentificationCode`) |
| `IdentificationCode` | nvarchar(60) | Part of FK composite |
| `AssessmentReportingMethodDescriptorID` | uniqueidentifier | Required |
| `Result` | nvarchar(35) | Score value as string |
| `ResultDatatypeTypeDescriptorID` | uniqueidentifier | Required |

---

#### `aca.StudentSectionAssociation`
Ed-Fi student ↔ section enrollment record. Links a student to an Ed-Fi section and a SIS class with a date range.

| Column | Type | Notes |
|---|---|---|
| `StudentSectionAssociationID` | int IDENTITY | PK |
| `EdFiSectionID` | int | FK → `crse.EdFiSection`; indexed |
| `ClassID` | int | Part of FK to `dbo.Roster(StudentID, ClassID)` |
| `StudentID` | int | FK → `dbo.Roster`; indexed |
| `BeginDate` | date | Required; part of unique key |
| `EndDate` | date | Nullable |
| `RepeatIdentifierDescriptorID` | uniqueidentifier | Nullable |
| `TeacherStudentDataLinkExclusion` | bit | Defaults to `0` |
| `AttemptStatusDescriptorId` | uniqueidentifier | Nullable |

Unique on `(ClassID, BeginDate, StudentID, EdFiSectionID)`.

---

#### `aca.TeacherClassNote`
Free-text note written by a staff member on a class. Both FKs CASCADE on delete.

| Column | Type | Notes |
|---|---|---|
| `TeacherClassNoteID` | int IDENTITY | PK |
| `ClassID` | int | FK → `dbo.Classes` (CASCADE); indexed |
| `StaffID` | int | FK → `dbo.Person` (CASCADE); indexed |
| `Note` | nvarchar(1000) | Nullable |
| `ModifiedUTC` | datetime2(2) | Defaults to `GETUTCDATE()` |

---

#### `aca` schema — cross-reference summary

| Table | Scope | Key FK targets |
|---|---|---|
| `StandardPath` | Standard hierarchy nodes | `dbo.ConfigSchool`, self |
| `Standard` | Master standard registry | `aca.StandardPath` |
| `LearningStandard` | Ed-Fi mapping of a standard | `aca.Standard` |
| `LearningObjective` | Ed-Fi objective hierarchy | self |
| `StandardCoursesMM` | Standard ↔ course link | `aca.Standard`, `crse.CourseCore` |
| `StandardSkillSetMM` | Standard ↔ skill-set skill link | `aca.Standard`, `dbo.SS_Skills` |
| `StandardPathTermGrade` | Path-level term grade per student | `aca.StandardPath`, `dbo.Classes`, `dbo.Person` |
| `GbkStandardSummary` | Computed term average per standard | `aca.Standard`, `dbo.Classes`, `dbo.Person` |
| `SBGTermGrade` | Official SBG term grade | `aca.Standard`, `dbo.Classes`, `dbo.Person` |
| `GbkAssignmentStandardGrade` | Per-student assignment grade | `aca.Standard`, `dbo.GbkAssignments`, `dbo.Classes`, `dbo.Person` |
| `GbkAssignmentsStandardMM` | Assignment ↔ standard link | `aca.Standard`, `dbo.GbkAssignments` |
| `GbkAssignmentStandardGradeMap` | Grade→score map (class scope) | `dbo.Classes` |
| `CourseLevelAssignmentStandardGradeMap` | Grade→score map (course-level scope) | `dbo.CourseLevel` |
| `GbkLessonPlanStandardMM` | Lesson plan ↔ standard (class/date) | `aca.Standard`, `dbo.Classes` |
| `MasterLessonPlanStandardMM` | Lesson plan ↔ standard (master/course) | `aca.Standard`, `dbo.MasterLessonPlan` |
| `StandardizedTestConfiguration` | Test type config (legacy sync) | `dbo.ConfigSchool` → `dbo.TestConfig` |
| `StandardizedTestConfigurationScore` | Score slot labels per test config | `aca.StandardizedTestConfiguration` → `dbo.TestConfig.Score{N}Label` |
| `PersonStandardizedTest` | Standardized test event per person | `aca.StandardizedTestConfiguration`, `dbo.Person` → `dbo.TestData` |
| `StandardizedTestAssessment` | Ed-Fi assessment instrument | — |
| `StandardizedTestAssessmentAcademicSubject` | Assessment subjects | `aca.StandardizedTestAssessment` |
| `StandardizedTestAssessmentContentStandard` | Assessment publication metadata | `aca.StandardizedTestAssessment`, `cnfg.EducationOrganization` |
| `StandardizedTestAssessmentGradeLevelsMM` | Assessment ↔ grade levels | `aca.StandardizedTestAssessment`, `dbo.GradeLevels` |
| `StandardizedTestAssessmentPlatformType` | Assessment delivery platforms | `aca.StandardizedTestAssessment` |
| `StandardizedTestAssessmentProgram` | Assessment ↔ programs | `aca.StandardizedTestAssessment`, `prgm.Program` |
| `StandardizedTestAssessmentScore` | Assessment score range/method | `aca.StandardizedTestAssessment` |
| `StandardizedTestAssessmentSection` | Assessment ↔ course section | `aca.StandardizedTestAssessment`, `crse.CourseCore`, `crse.EdFiSection`, `dbo.SchoolYear` |
| `StudentAcademicRecord` | Ed-Fi cumulative/session credit + GPA | `dbo.Person`, `cnfg.Session` |
| `StudentAcademicRecordDiploma` | Diploma awards per academic record | `aca.StudentAcademicRecord` |
| `StudentStandardizedTestAssessment` | Student test sitting header | `aca.StandardizedTestAssessment`, `dbo.Person`, `dbo.SchoolYear` |
| `StudentAssessmentAccommodation` | Accommodations per test sitting | `aca.StandardizedTestAssessment`, `aca.StudentStandardizedTestAssessment` |
| `StudentAssessmentItem` | Item responses per test sitting | `aca.StudentStandardizedTestAssessment` |
| `StudentAssessmentPerformanceLevel` | Performance level per test sitting | `aca.StandardizedTestAssessment`, `aca.StudentStandardizedTestAssessment` |
| `StudentAssessmentPeriod` | Assessment period per test sitting | `aca.StudentStandardizedTestAssessment` |
| `StudentAssessmentScoreResult` | Overall score result per test sitting | `aca.StudentStandardizedTestAssessment` |
| `StudentAssessmentStudentObjectiveAssessment` | Sub-assessment per test sitting | `aca.StudentStandardizedTestAssessment` |
| `StudentAssessmentStudentObjectiveAssessmentPerformanceLevel` | Performance level per sub-assessment | `aca.StudentStandardizedTestAssessment` |
| `StudentAssessmentStudentObjectiveAssessmentScoreResult` | Score result per sub-assessment | `aca.StudentAssessmentStudentObjectiveAssessment` |
| `StudentSectionAssociation` | Student ↔ Ed-Fi section enrollment | `crse.EdFiSection`, `dbo.Roster` |
| `TeacherClassNote` | Staff note on a class | `dbo.Classes`, `dbo.Person` |
| `StaffSectionAssociation` | Staff ↔ section (Ed-Fi) | `dbo.Person`, `cnfg.Session`, `crse.CourseCore` |
| `AttendanceAbsenceConversionHistory` | Absence conversion audit log | `dbo.ConfigSchool` |

---

### `acct` schema tables

The `acct` schema holds accounting/billing data related to courses.

#### `acct.CourseFees`
Fee configuration for a course — up to four fee types (course, material, lab, misc), each with an optional accounting category. One row per course (PK = `CourseID`).

Uses **system-versioned temporal** columns (`GENERATED ALWAYS AS ROW START/END`) on `ModifiedOnUTC` / `ModifiedOnUTCmax`, enabling point-in-time history queries.

| Column | Type | Notes |
|---|---|---|
| `CourseID` | int | PK; FK → `crse.CourseCore` |
| `CourseFee` | decimal(19,4) | Nullable |
| `CourseAcctCat` | int | Accounting category for course fee; nullable |
| `MaterialFee` | decimal(19,4) | Nullable |
| `MaterialAcctCat` | int | Nullable |
| `LabFee` | decimal(19,4) | Nullable |
| `LabAcctCat` | int | Nullable |
| `MiscFee` | decimal(19,4) | Nullable |
| `MiscAcctCat` | int | Nullable |
| `CreatedOnUTC` | datetime2(2) | Defaults to `SYSUTCDATETIME()` |
| `ModifiedOnUTC` | datetime2(2) | Temporal ROW START; auto-maintained |
| `ModifiedOnUTCmax` | datetime2(2) | Temporal ROW END; `9999-12-31` when current |

---

### `ae` schema tables

The `ae` schema holds admission/enrollment (application engine) data.

#### `ae.ConfigurableImage`
Stores a configurable image URL per member × area. Used to customize images shown in the admission/enrollment portal by area (e.g., banner, logo).

| Column | Type | Notes |
|---|---|---|
| `MemberId` | int | PK (composite); FK → `dbo.OAMember` |
| `AreaTitle` | varchar(75) | PK (composite); logical area identifier |
| `ImageUrl` | nvarchar(256) | URL of the image; nullable |

---

#### `ae.StudentApplicationWaitlistPriorityGroup`
Associates a student application with a waitlist priority group. Supports ordered waitlist processing.

| Column | Type | Notes |
|---|---|---|
| `StudentApplicationWaitlistPriorityGroupID` | int IDENTITY | PK |
| `WaitlistPriorityGroupID` | int | FK → `ae.WaitlistPriorityGroup`; indexed |
| `StudentApplicationID` | int | FK → `dbo.StudentApplication.ApplicationID`; indexed |



#### `ae.TextArea`
Localized rich-text content blocks for the admission/enrollment portal. One row per member × language × area title.

| Column | Type | Notes |
|---|---|---|
| `MemberId` | int | PK (composite); FK → `dbo.OAMember` |
| `LangCode` | char(2) | PK (composite); FK → `ref.LanguageCode`; indexed |
| `AreaTitle` | varchar(75) | PK (composite); logical content area |
| `Content` | nvarchar(max) | HTML/text content; defaults to `''` |

---

#### `ae.UnsubscribeEmail`
Records email addresses that have opted out of communications for a given member (school/org). Unique on `(EmailAddress, MemberId)`.

| Column | Type | Notes |
|---|---|---|
| `UnsubscribeId` | int IDENTITY | PK |
| `EmailAddress` | nvarchar(256) | Required; unique with `MemberId` |
| `MemberId` | int | Required |
| `UnsubscribeDate` | smalldatetime | Required |

No FK constraint on `MemberId` — email addresses may persist after org changes.

---

#### `ae.WaitlistPriorityGroup`
Defines a named priority tier for the admissions waitlist, scoped to a member (school/org). Referenced by `ae.StudentApplicationWaitlistPriorityGroup`.

| Column | Type | Notes |
|---|---|---|
| `WaitlistPriorityGroupID` | int IDENTITY | PK |
| `MemberID` | int | FK → `dbo.OAMember` (CASCADE); indexed |
| `GroupName` | nvarchar(255) | Defaults to `''` |
| `Description` | nvarchar(1024) | Defaults to `''` |
| `SortOrder` | int | Defaults to 0 |
| `IsActive` | bit | Defaults to `0` |

---

### `cafe` schema tables

The `cafe` schema holds cafeteria/lunch ordering data — menu items, carts, line items, and portal configuration. It was introduced as a refactor of the legacy `dbo.LunchMenuNew` system (Story 83388, Nov 2021).

#### `cafe.MenuItemGroup`
Optional grouping/category for menu items within a school. School-scoped (`ConfigSchoolId`); CASCADE deletes items in the group.

| Column | Type | Notes |
|---|---|---|
| `MenuItemGroupId` | int IDENTITY | PK |
| `ConfigSchoolId` | smallint | FK → `dbo.ConfigSchool` (CASCADE); indexed |
| `GroupName` | nvarchar(25) | Unique with `ConfigSchoolId` |
| `SortOrder` | smallint | Display order |

---

#### `cafe.MenuItem`
A cafeteria menu item for a school. Supports three price tiers (full, reduced, staff) and flags for breakfast, meal type, and reduced-lunch eligibility. Links to the legacy `dbo.LunchMenuNew` row via `LunchId` (nullable, SET NULL on delete).

| Column | Type | Notes |
|---|---|---|
| `MenuItemId` | int IDENTITY | PK |
| `ConfigSchoolId` | smallint | FK → `dbo.ConfigSchool`; indexed |
| `Description` | nvarchar(128) | Required; unique with `ConfigSchoolId` |
| `MenuItemGroupId` | int | FK → `cafe.MenuItemGroup` (SET NULL); nullable |
| `FullPrice` | decimal(19,4) | Defaults to 0 |
| `ReducedPrice` | decimal(19,4) | Defaults to 0 |
| `StaffPrice` | decimal(19,4) | Defaults to 0 |
| `IsReducedLunchEligible` | bit | Defaults to `0` |
| `IsBreakfast` | bit | Defaults to `0` |
| `IsMeal` | bit | Defaults to `0` |
| `IsActive` | bit | Defaults to `1` |
| `ModifiedBy` | int | FK → `dbo.Person` |
| `ModifiedDateUtc` | datetime | Last modified timestamp |
| `LunchId` | int | FK → `dbo.LunchMenuNew` (SET NULL); legacy cross-reference; nullable |

---

#### `cafe.MenuItemRecurrence`
Recurrence schedule for a menu item — defines when the item repeats (daily, weekly, etc.) within a date window. School-scoped; unique on `(ConfigSchoolId, Name)`.

| Column | Type | Notes |
|---|---|---|
| `MenuItemRecurrenceId` | int IDENTITY | PK |
| `ConfigSchoolId` | smallint | FK → `dbo.ConfigSchool` |
| `Name` | nvarchar(50) | Required; unique with `ConfigSchoolId` |
| `StartDate` / `EndDate` | date | Effective window; default to `GETDATE()` |
| `RecurrenceType` | tinyint | Defaults to 1 |
| `RecurrenceInterval` | tinyint | Defaults to 1 |
| `RecurrenceRelativeInterval` | tinyint | Defaults to 0 |
| `RecurrenceFactor` | tinyint | Defaults to 0 |

---

#### `cafe.Cart`
An order cart — a container for line items, with a lifecycle state (0–3). `ModifiedBy` tracks which person last touched the cart.

| Column | Type | Notes |
|---|---|---|
| `CartId` | int IDENTITY | PK |
| `State` | tinyint | Check: 0–3; defaults to 0 |
| `ModifiedBy` | int | FK → `dbo.Person` |
| `ModifiedUtc` | datetime2(2) | Defaults to `GETUTCDATE()` |

---

#### `cafe.FamilyCart`
Associates a cart with a family. One row per cart (PK = `CartId`); CASCADE delete from `cafe.Cart`.

| Column | Type | Notes |
|---|---|---|
| `CartId` | int | PK; FK → `cafe.Cart` (CASCADE) |
| `FamilyId` | int | FK → `dbo.FamilyConfig` |

---

#### `cafe.FamilyPortalConfiguration`
School-level settings controlling cafeteria visibility and ordering rules in the family portal. One row per school (PK = `ConfigSchoolId`).

| Column | Type | Notes |
|---|---|---|
| `ConfigSchoolId` | smallint | PK; FK → `dbo.ConfigSchool` |
| `DisplayMenu` | bit | Show menu in portal; defaults to `0` |
| `AllowOrdering` | bit | Enable ordering; defaults to `0` |
| `StartDate` / `EndDate` | datetime2(2) | Ordering window; nullable |
| `RequireZeroOrMoreCreditBalance` | bit | Blocks orders when balance negative; defaults to `0` |
| `ModifiedById` | int | FK → `dbo.Person_Staff` |
| `ModifiedUtc` | datetime2(2) | Defaults to `GETUTCDATE()` |

---

#### `cafe.LineItem`
One ordered item within a cart. Tracks which person the item is for, the menu item, quantity, and the date it is ordered for. CASCADE deletes when cart or menu item is deleted.

| Column | Type | Notes |
|---|---|---|
| `LineItemId` | int IDENTITY | PK |
| `CartId` | int | FK → `cafe.Cart` (CASCADE) |
| `PersonId` | int | FK → `dbo.Person` (the diner) |
| `MenuItemId` | int | FK → `cafe.MenuItem` (CASCADE) |
| `Quantity` | tinyint | Required |
| `DateOrderedFor` | date | Date the meal is for; defaults to `GETDATE()` |

---

#### `cafe.MenuItemRecurrenceDetail`
Links a recurrence schedule to the menu items it includes. Both FKs CASCADE on delete.

| Column | Type | Notes |
|---|---|---|
| `MenuItemRecurrenceDetailId` | int IDENTITY | PK |
| `MenuItemRecurrenceId` | int | FK → `cafe.MenuItemRecurrence` (CASCADE); unique with `MenuItemId` |
| `MenuItemId` | int | FK → `cafe.MenuItem` (CASCADE) |

---

#### `cafe.MenuItemScheduledDateMM`
Maps a menu item to its specific scheduled serving dates (refactor of `dbo.LunchMenuDates`, Story 71746). The optional `MenuItemRecurrenceId` records which recurrence generated the date.

| Column | Type | Notes |
|---|---|---|
| `MenuItemId` | int | PK (composite); FK → `cafe.MenuItem` (CASCADE) |
| `ScheduledDate` | date | PK (composite) |
| `MenuItemRecurrenceId` | int | FK → `cafe.MenuItemRecurrence` (CASCADE); nullable |

---

#### `cafe.Payment`
Payment transaction record for a cafeteria order. Links to the cart that was checked out (SET NULL on cart delete) and to the FACTS family mapping for billing. Referenced by `cafe.MenuOrder`.

| Column | Type | Notes |
|---|---|---|
| `PaymentId` | int IDENTITY | PK |
| `CartId` | int | FK → `cafe.Cart` (SET NULL); nullable after cart deletion |
| `PaymentSessionId` | nvarchar(128) | Payment gateway session identifier |
| `FamilyMappingId` | int | FK → `facts.FamilyMapping` |
| `FinancialTermCode` | nvarchar(50) | Required |
| `AccountCode` | nvarchar(20) | Required |
| `AccountActivityTypeId` | tinyint | Check: 0–3 |
| `OwnerBalance` | decimal(19,4) | Balance at time of payment |
| `TotalChargeAmount` | decimal(19,4) | Total charged |
| `TotalPaymentAmount` | decimal(19,4) | Total paid |
| `TimeStampUtc` | datetime2(2) | Defaults to `GETUTCDATE()` |
| `ResultCode` | int | Gateway result code; nullable |
| `ResultMessage` | nvarchar(50) | Gateway result message; nullable |

---

#### `cafe.MenuOrder`
A placed (submitted) order. Distinct from `cafe.Cart` (which is a pending/open order). Tracks who placed it, when, from which application, and the associated payment.

| Column | Type | Notes |
|---|---|---|
| `MenuOrderId` | int IDENTITY | PK |
| `PlacedBy` | int | FK → `dbo.Person` |
| `DateTimePlacedUtc` | datetime2(2) | Defaults to `GETUTCDATE()` |
| `ApplicationPlacedFrom` | tinyint | Check: 0–2; source app identifier; defaults to 0 |
| `PaymentId` | int | FK → `cafe.Payment`; nullable |

---

#### `cafe.MenuOrderItem`
An individual line item within a placed order. Records the price snapshot at time of order (separate from the current `MenuItem` price), price type, and processing state.

| Column | Type | Notes |
|---|---|---|
| `MenuOrderItemId` | int IDENTITY | PK |
| `MenuOrderId` | int | FK → `cafe.MenuOrder` |
| `PersonId` | int | FK → `dbo.Person` (the diner) |
| `MenuItemId` | int | FK → `cafe.MenuItem` |
| `Price` | decimal(19,4) | Price at time of order |
| `PriceType` | tinyint | Check: 0–3 (full/reduced/staff/other) |
| `ProcessState` | tinyint | Check: 0–3 |
| `IsVerified` | bit | Defaults to `0` |
| `IsBreakfast` | bit | Snapshot of item flag; defaults to `0` |
| `IsMeal` | bit | Snapshot of item flag; defaults to `0` |
| `ForDateUtc` | date | Date the meal is for |

---

#### `cafe.StaffCart`
Associates a cart with a staff member. One row per cart (PK = `CartId`); CASCADE delete from `cafe.Cart`.

| Column | Type | Notes |
|---|---|---|
| `CartId` | int | PK; FK → `cafe.Cart` (CASCADE) |
| `StaffId` | int | FK → `dbo.Person_Staff` |

---

#### `cafe` schema — cross-reference summary

| Table | Scope | Key FK targets |
|---|---|---|
| `MenuItemGroup` | Item category per school | `dbo.ConfigSchool` |
| `MenuItem` | Menu item with pricing | `dbo.ConfigSchool`, `cafe.MenuItemGroup`, `dbo.LunchMenuNew` |
| `MenuItemRecurrence` | Recurrence schedule per school | `dbo.ConfigSchool` |
| `MenuItemRecurrenceDetail` | Recurrence ↔ item link | `cafe.MenuItemRecurrence`, `cafe.MenuItem` |
| `MenuItemScheduledDateMM` | Item ↔ scheduled date | `cafe.MenuItem`, `cafe.MenuItemRecurrence` |
| `Cart` | Pending order cart | `dbo.Person` |
| `FamilyCart` | Cart ↔ family link | `cafe.Cart`, `dbo.FamilyConfig` |
| `StaffCart` | Cart ↔ staff link | `cafe.Cart`, `dbo.Person_Staff` |
| `LineItem` | Item in a pending cart | `cafe.Cart`, `cafe.MenuItem`, `dbo.Person` |
| `Payment` | Payment transaction | `cafe.Cart`, `facts.FamilyMapping` |
| `MenuOrder` | Placed (submitted) order | `dbo.Person`, `cafe.Payment` |
| `MenuOrderItem` | Line item in a placed order | `cafe.MenuOrder`, `cafe.MenuItem`, `dbo.Person` |
| `FamilyPortalConfiguration` | Portal settings per school | `dbo.ConfigSchool`, `dbo.Person_Staff` |

---

### `cnfg` schema tables

The `cnfg` schema holds Ed-Fi calendar and session configuration data.

#### `cnfg.CalendarName`
Ed-Fi calendar definition for a school year. Identified by `(SchoolYearID, CalendarCode)` (unique clustered).

| Column | Type | Notes |
|---|---|---|
| `CalendarNameID` | int IDENTITY | PK (non-clustered) |
| `SchoolYearID` | int | FK → `dbo.SchoolYear`; part of unique clustered key |
| `CalendarCode` | nvarchar(60) | Required; part of unique clustered key |
| `CalendarTypeDescriptorID` | uniqueidentifier | Required |

---

#### `cnfg.CalendarGradeLevel`
Grade levels associated with a calendar. One row per calendar × grade level descriptor.

| Column | Type | Notes |
|---|---|---|
| `CalendarGradeLevelID` | int IDENTITY | PK |
| `CalendarNameID` | int | FK → `cnfg.CalendarName`; unique with `GradeLevelDescriptorID` |
| `GradeLevelDescriptorID` | uniqueidentifier | Required |

---

#### `cnfg.CalendarNameDaySetup`
Links a calendar to its day setup entries (`dbo.DaySetup`). Many-to-many between calendars and day setups.

| Column | Type | Notes |
|---|---|---|
| `CalendarNameDaySetupID` | int IDENTITY | PK |
| `CalendarNameId` | int | FK → `cnfg.CalendarName` |
| `DaySetupId` | int | FK → `dbo.DaySetup` |

---

#### `cnfg.CalendarDateCalendarEvent`
Ed-Fi calendar event tags on a specific day setup. One row per day setup × event descriptor (unique clustered).

| Column | Type | Notes |
|---|---|---|
| `CalendarDateCalendarEventID` | int IDENTITY | PK (non-clustered) |
| `DaySetupID` | int | FK → `dbo.DaySetup`; part of unique clustered key |
| `CalendarEventDescriptorID` | uniqueidentifier | Required; part of unique clustered key |

---

#### `cnfg.EducationOrganization`
Maps an Ed-Fi `EducationOrganizationId` (bigint) to a SIS `ConfigSchoolID`. Acts as the bridge between the Ed-Fi org hierarchy and the FACTS school record.

| Column | Type | Notes |
|---|---|---|
| `EducationOrganizationId` | bigint | PK |
| `ConfigSchoolID` | smallint | FK → `dbo.ConfigSchool`; nullable |

---

#### `cnfg.SchoolCharacteristicDefinition`
Lookup table of named school characteristic types (e.g. "Title I", "Magnet"). Referenced by `cnfg.ConfigSchoolCharacteristic`.

| Column | Type | Notes |
|---|---|---|
| `SchoolCharacteristicDefinitionID` | int IDENTITY | PK |
| `CharacteristicName` | nvarchar(4000) | Optional label |

---

#### `cnfg.ConfigSchoolCharacteristic`
Associates a school with one or more characteristic definitions. Unique on `(SchoolCharacteristicDefinitionID, ConfigSchoolID)`.

| Column | Type | Notes |
|---|---|---|
| `ConfigSchoolCharacteristicID` | int IDENTITY | PK |
| `SchoolCharacteristicDefinitionID` | int | FK → `cnfg.SchoolCharacteristicDefinition`; indexed |
| `ConfigSchoolID` | smallint | FK → `dbo.ConfigSchool`; indexed |

---

#### `cnfg.SchoolGroupDefinition`
Lookup table of named school group types. Referenced by `cnfg.ConfigSchoolGroup`.

| Column | Type | Notes |
|---|---|---|
| `SchoolGroupDefinitionID` | int IDENTITY | PK |
| `SchoolGroupName` | nvarchar(4000) | Required |
| `SchoolGroupDescription` | nvarchar(4000) | Nullable |

---

#### `cnfg.ConfigSchoolGroup`
Associates a school with one or more group definitions. Unique on `(SchoolGroupDefinitionID, ConfigSchoolID)`.

| Column | Type | Notes |
|---|---|---|
| `ConfigSchoolGroupID` | int IDENTITY | PK |
| `SchoolGroupDefinitionID` | int | FK → `cnfg.SchoolGroupDefinition`; indexed |
| `ConfigSchoolID` | smallint | FK → `dbo.ConfigSchool`; indexed |

---

#### `cnfg.ConfigSchoolSubgroup`
Associates a school with one or more subgroup definitions. Unique on `(SchoolSubGroupDefinitionID, ConfigSchoolID)`. References `cnfg.SchoolSubgroupDefinition` (DDL not yet provided).

| Column | Type | Notes |
|---|---|---|
| `ConfigSchoolSubGroupID` | int IDENTITY | PK |
| `SchoolSubGroupDefinitionID` | int | FK → `cnfg.SchoolSubgroupDefinition`; indexed |
| `ConfigSchoolID` | smallint | FK → `dbo.ConfigSchool`; indexed |

---

#### `cnfg.SchoolCategory`
Ed-Fi school category descriptors for a school (e.g. elementary, high school). One row per school × category descriptor.

| Column | Type | Notes |
|---|---|---|
| `SchoolCategoryID` | int IDENTITY | PK |
| `ConfigSchoolID` | smallint | FK → `dbo.ConfigSchool`; unique with `SchoolCategoryDescriptorID` |
| `SchoolCategoryDescriptorID` | uniqueidentifier | Required |

---

#### `cnfg.SchoolDesignation`
Ed-Fi school designation flags — charter status, Title I part A, magnet program, funding control, etc. One row per school (unique clustered on `ConfigSchoolId`).

| Column | Type | Notes |
|---|---|---|
| `SchoolDesignationId` | int IDENTITY | PK (non-clustered) |
| `ConfigSchoolId` | smallint | FK → `dbo.ConfigSchool`; unique clustered |
| `SchoolTypeDescriptorId` | uniqueidentifier | Nullable |
| `CharterStatusDescriptorId` | uniqueidentifier | Nullable |
| `TitleIPartASchoolDesignationDescriptorId` | uniqueidentifier | Nullable |
| `MagnetSpecialProgramEmphasisSchoolDescriptorId` | uniqueidentifier | Nullable |
| `AdministrativeFundingControlDescriptorId` | uniqueidentifier | Nullable |
| `InternetAccessDescriptorId` | uniqueidentifier | Nullable |
| `CharterApprovalAgencyTypeDescriptorId` | uniqueidentifier | Nullable |
| `CharterApprovalSchoolYear` | smallint | Nullable |
| `CreatedUtc` | datetime2(2) | Defaults to `GETUTCDATE()` |

---

#### `cnfg.Cohort`
Ed-Fi cohort definition — a named group of students at an education organization. Identified by `(CohortIdentifier, EducationOrganizationId)` (unique clustered).

| Column | Type | Notes |
|---|---|---|
| `CohortId` | int IDENTITY | PK (non-clustered) |
| `CohortIdentifier` | nvarchar(20) | Required; unique with `EducationOrganizationId` |
| `EducationOrganizationId` | int | Required |
| `CohortTypeDescriptorId` | uniqueidentifier | Required |
| `CohortDescription` | nvarchar(1024) | Nullable |
| `AcademicSubjectDescriptorId` | uniqueidentifier | Nullable |
| `CohortScopeDescriptorId` | uniqueidentifier | Nullable |

Note: no FK on `EducationOrganizationId` to `cnfg.EducationOrganization` in this DDL.

---

#### `cnfg.CohortProgram`
Programs associated with a cohort. Unique on `(ProgramTypeDescriptorId, ProgramEducationOrganizationId, ProgramName)`.

| Column | Type | Notes |
|---|---|---|
| `CohortProgramId` | int IDENTITY | PK |
| `CohortId` | int | FK → `cnfg.Cohort`; indexed |
| `ProgramTypeDescriptorId` | uniqueidentifier | Part of unique key |
| `ProgramEducationOrganizationId` | int | Part of unique key |
| `ProgramName` | nvarchar(60) | Part of unique key |

---

#### `cnfg.SchoolSubgroupDefinition`
Lookup table of named school subgroup types. Child of `cnfg.SchoolGroupDefinition`; referenced by `cnfg.ConfigSchoolSubgroup`.

| Column | Type | Notes |
|---|---|---|
| `SchoolSubgroupDefinitionID` | int IDENTITY | PK |
| `SchoolGroupDefinitionID` | int | FK → `cnfg.SchoolGroupDefinition` |
| `SchoolSubgroupName` | nvarchar(4000) | Required |

---

#### `cnfg.Session`
Ed-Fi academic session (term/semester) for a school year. Unique on `SessionName`. Referenced as FK target by `aca.StaffSectionAssociation`, `aca.StudentAcademicRecord`, and others.

| Column | Type | Notes |
|---|---|---|
| `SessionID` | int IDENTITY | PK |
| `SchoolYearID` | int | FK → `dbo.SchoolYear` |
| `SessionName` | nvarchar(60) | Required; unique |
| `BeginDate` / `EndDate` | date | Required date range |
| `TermDescriptorID` | uniqueidentifier | Required |
| `TotalInstructionalDays` | int | Required |

---

#### `cnfg.SessionAcademicWeek`
Academic week identifiers within a session. One row per session × week identifier.

| Column | Type | Notes |
|---|---|---|
| `SessionAcademicWeekID` | int IDENTITY | PK |
| `SessionID` | int | FK → `cnfg.Session`; unique with `WeekIdentifier` |
| `WeekIdentifier` | nvarchar(60) | Required |

---

#### `cnfg.SessionGradingPeriod`
Grading periods within a session. Unique on `(SessionId, GradingPeriodDescriptorID, PeriodSequence)`. Sequence must be < 100.

| Column | Type | Notes |
|---|---|---|
| `SessionGradingPeriodId` | int IDENTITY | PK |
| `SessionId` | int | FK → `cnfg.Session` |
| `GradingPeriodDescriptorID` | uniqueidentifier | Required |
| `PeriodSequence` | int | Check: < 100 |

---

#### `cnfg.StaffCohortAssociation`
Associates a staff member with a cohort for a date range, with an optional student record access flag. Unique clustered on `(CohortId, StaffId, EducationOrganizationId, BeginDate)`.

| Column | Type | Notes |
|---|---|---|
| `StaffCohortAssociationId` | int IDENTITY | PK (non-clustered) |
| `CohortId` | int | FK → `cnfg.Cohort` |
| `StaffId` | int | FK → `dbo.Person_Staff`; indexed |
| `EducationOrganizationId` | int | Part of unique clustered key |
| `BeginDate` | date | Required |
| `EndDate` | date | Nullable |
| `StudentRecordAccess` | bit | Defaults to `0` |

---

#### `cnfg.StudentCohortAssociation`
Associates a student with a cohort for a date range. Unique on `(StudentID, CohortId, BeginDate)`.

| Column | Type | Notes |
|---|---|---|
| `StudentCohortAssociationId` | int IDENTITY | PK |
| `StudentID` | int | FK → `dbo.Person` |
| `CohortId` | int | FK → `cnfg.Cohort`; indexed |
| `BeginDate` | date | Required |
| `EndDate` | date | Nullable |

---

#### `cnfg.StudentCohortAssociationSection`
Scopes a student's cohort association to a specific Ed-Fi section. Unique on `(EdfiSectionID, StudentCohortAssociationId)`.

| Column | Type | Notes |
|---|---|---|
| `StudentCohortAssociationSectionId` | int IDENTITY | PK |
| `StudentCohortAssociationId` | int | FK → `cnfg.StudentCohortAssociation`; indexed |
| `EdfiSectionID` | int | FK → `crse.EdFiSection` |

---

#### `cnfg` schema — cross-reference summary

| Table | Scope | Key FK targets |
|---|---|---|
| `CalendarName` | Ed-Fi calendar per school year | `dbo.SchoolYear` |
| `CalendarGradeLevel` | Grade levels on a calendar | `cnfg.CalendarName` |
| `CalendarNameDaySetup` | Calendar ↔ day setup link | `cnfg.CalendarName`, `dbo.DaySetup` |
| `CalendarDateCalendarEvent` | Event tags on a day setup | `dbo.DaySetup` |
| `EducationOrganization` | Ed-Fi org ↔ SIS school bridge | `dbo.ConfigSchool` |
| `SchoolCharacteristicDefinition` | Characteristic type lookup | — |
| `ConfigSchoolCharacteristic` | School ↔ characteristic | `cnfg.SchoolCharacteristicDefinition`, `dbo.ConfigSchool` |
| `SchoolGroupDefinition` | Group type lookup | — |
| `SchoolSubgroupDefinition` | Subgroup type lookup | `cnfg.SchoolGroupDefinition` |
| `ConfigSchoolGroup` | School ↔ group | `cnfg.SchoolGroupDefinition`, `dbo.ConfigSchool` |
| `ConfigSchoolSubgroup` | School ↔ subgroup | `cnfg.SchoolSubgroupDefinition`, `dbo.ConfigSchool` |
| `SchoolCategory` | Ed-Fi category descriptors per school | `dbo.ConfigSchool` |
| `SchoolDesignation` | Ed-Fi designation flags per school | `dbo.ConfigSchool` |
| `Session` | Ed-Fi academic session (term) | `dbo.SchoolYear` |
| `SessionAcademicWeek` | Academic weeks in a session | `cnfg.Session` |
| `SessionGradingPeriod` | Grading periods in a session | `cnfg.Session` |
| `Cohort` | Ed-Fi cohort definition | — |
| `CohortProgram` | Programs on a cohort | `cnfg.Cohort` |
| `StaffCohortAssociation` | Staff ↔ cohort with date range | `cnfg.Cohort`, `dbo.Person_Staff` |
| `StudentCohortAssociation` | Student ↔ cohort with date range | `cnfg.Cohort`, `dbo.Person` |
| `StudentCohortAssociationSection` | Cohort association scoped to a section | `cnfg.StudentCohortAssociation`, `crse.EdFiSection` |

---

### `cnv` schema tables

The `cnv` schema holds third-party integration configuration. All tables use **system-versioned temporal** columns (`GENERATED ALWAYS AS ROW START/END` with `PERIOD FOR SYSTEM_TIME`) enabling point-in-time history. `CreatedOnUTC` is protected with a `DENY UPDATE … TO public` grant.

#### `cnv.Integration`
Master record for a named third-party integration. Referenced by `cnv.IntegrationAccount` and `cnv.IntegrationSchoolMM`.

| Column | Type | Notes |
|---|---|---|
| `IntegrationID` | int IDENTITY | PK |
| `IntegrationName` | nvarchar(max) | Required |
| `CreatedOnUTC` | datetime2(2) | Defaults to `SYSUTCDATETIME()`; UPDATE denied to public |
| `ModifiedOnUTC` | datetime2(2) | Temporal ROW START; indexed |
| `ModifiedOnUTCmax` | datetime2(2) | Temporal ROW END |

---

#### `cnv.IntegrationAccount`
Per-staff OAuth/API credentials for an integration. Stores tokens and secrets — **never log or expose these columns**. PK is composite `(IntegrationID, StaffID)`.

| Column | Type | Notes |
|---|---|---|
| `IntegrationID` | int | PK (composite); FK → `cnv.Integration` |
| `StaffID` | int | PK (composite); FK → `dbo.Person_Staff` |
| `Username` | nvarchar(max) | Nullable |
| `ClientID` | nvarchar(max) | Nullable |
| `ClientSecret` | nvarchar(max) | **Sensitive** — never log; nullable |
| `AccessToken` | nvarchar(max) | **Sensitive** — never log; nullable |
| `RefreshToken` | nvarchar(max) | **Sensitive** — never log; nullable |
| `TokenExpiryDate` | smalldatetime | Nullable |

---

#### `cnv.IntegrationSchoolMM`
Maps an integration to the schools it is enabled for. Temporal table — history queryable via `FOR SYSTEM_TIME`. `CreatedOnUTC` is UPDATE-denied to public.

| Column | Type | Notes |
|---|---|---|
| `IntegrationID` | int | PK (composite); FK → `cnv.Integration` |
| `ConfigSchoolID` | smallint | PK (composite); FK → `dbo.ConfigSchool`; indexed |
| `CreatedOnUTC` | datetime2(2) | Defaults to `SYSUTCDATETIME()`; UPDATE denied to public |
| `ModifiedOnUTC` | datetime2(2) | Temporal ROW START |
| `ModifiedOnUTCmax` | datetime2(2) | Temporal ROW END |

---

#### `cnv` schema — cross-reference summary

| Table | Scope | Key FK targets |
|---|---|---|
| `Integration` | Third-party integration definition | — |
| `IntegrationAccount` | Per-staff OAuth credentials | `cnv.Integration`, `dbo.Person_Staff` |
| `IntegrationSchoolMM` | Integration ↔ school enablement | `cnv.Integration`, `dbo.ConfigSchool` |

#### `cnv.MappingGbkAssessments`
Maps a SIS gradebook assessment to its counterpart ID in an external integration (e.g. Canvas). One row per integration × gradebook assessment.

| Column | Type | Notes |
|---|---|---|
| `MappingAssessmentID` | int IDENTITY | PK |
| `IntegrationID` | int | FK → `cnv.Integration` |
| `GbkAssessmentID` | int | FK → `dbo.GbkAssessments` (CASCADE on delete) |
| `CanvasID` | int | External system ID |
| `ModifiedBy` | int | FK → `dbo.Person_Staff` |
| `ModifiedDate` | smalldatetime | Required |

---

#### `cnv.MappingGbkAssignments`
Maps a SIS gradebook assignment to its counterpart ID in an external integration. FK to `dbo.GbkAssignments` is composite `(AssessmentID, ClassID, AssignmentID)` with CASCADE on delete and update.

| Column | Type | Notes |
|---|---|---|
| `MappingAssignmentID` | int IDENTITY | PK |
| `IntegrationID` | int | FK → `cnv.Integration` |
| `AssessmentID` | int | Part of composite FK to `dbo.GbkAssignments` |
| `ClassID` | int | Part of composite FK |
| `AssignmentID` | int | Part of composite FK |
| `CanvasID` | int | External system ID |
| `ModifiedBy` | int | FK → `dbo.Person_Staff` |
| `ModifiedDate` | smalldatetime | Required |

---

#### `cnv` schema — cross-reference summary

| Table | Scope | Key FK targets |
|---|---|---|
| `Integration` | Third-party integration definition | — |
| `IntegrationAccount` | Per-staff OAuth credentials | `cnv.Integration`, `dbo.Person_Staff` |
| `IntegrationSchoolMM` | Integration ↔ school enablement | `cnv.Integration`, `dbo.ConfigSchool` |
| `MappingGbkAssessments` | Assessment ID mapping to external system | `cnv.Integration`, `dbo.GbkAssessments` |
| `MappingGbkAssignments` | Assignment ID mapping to external system | `cnv.Integration`, `dbo.GbkAssignments` |

---

### `cr` schema tables

The `cr` schema holds cash register configuration and session data for point-of-sale functionality.

#### `cr.CashRegister`
Master cash register definition. Linked to an accounting system and optional accounting category; configures payment method flags and UI settings.

| Column | Type | Notes |
|---|---|---|
| `CashRegisterID` | int IDENTITY | PK |
| `AccountingSystemID` | int | FK → `dbo.AccountingSystem` |
| `AccountingCategoryID` | int | FK → `dbo.AcctCat`; nullable |
| `CashRegisterName` | nvarchar(64) | Nullable |
| `TaxRate` | decimal(9,4) | Defaults to 0 |
| `ProductsPerPage` | int | Defaults to 0 |
| `UseCashPayment` | bit | Defaults to `1` |
| `UsePayLater` | bit | Defaults to `0` |
| `UseCheckPayment` | bit | Defaults to `1` |
| `UseCreditPayment` | bit | Defaults to `0` |

---

#### `cr.CashRegisterSession`
An open/closed register session for a specific cash register, opened and closed by a staff member.

| Column | Type | Notes |
|---|---|---|
| `CashRegisterSessionID` | int IDENTITY | PK |
| `CashRegisterID` | int | FK → `cr.CashRegister` (CASCADE) |
| `RegisterID` | nvarchar(64) | Required session identifier |
| `StaffID` | int | FK → `dbo.Person_Staff` |
| `OpeningDate` | smalldatetime | Defaults to `GETUTCDATE()` |
| `ClosingDate` | smalldatetime | Nullable |
| `OpeningBalance` | decimal(19,4) | Defaults to 0 |
| `ClosingBalance` | decimal(19,4) | Defaults to 0 |
| `OpeningNote` / `ClosingNote` | nvarchar(1024) | Nullable |

---

#### `cr.CashRegisterStaffMM`
Authorizes staff members to use a cash register. Both FKs CASCADE on delete.

| Column | Type | Notes |
|---|---|---|
| `StaffID` | int | PK (composite); FK → `dbo.Person_Staff` (CASCADE) |
| `CashRegisterID` | int | PK (composite); FK → `cr.CashRegister` (CASCADE) |

---

#### `cr.UserCashRegister`
UI-level register configuration — controls display flags (zero balance warning, UD ID lookup, receipt, picture, person list, barcode scan, number pad, previous orders, account balance). Independent of `cr.CashRegister`; `RegisterName` is unique.

| Column | Type | Notes |
|---|---|---|
| `CashRegisterID` | int IDENTITY | PK |
| `RegisterName` | nvarchar(64) | Required; unique |
| `ShowZeroBalanceWarning` | bit | Defaults to `0` |
| `UseUDIDLookup` | bit | Defaults to `0` |
| `HideTransactionReceipt` | bit | Defaults to `0` |
| `HidePersonPicture` | bit | Defaults to `0` |
| `HidePersonList` | bit | Defaults to `0` |
| `HideBarcodeScan` | bit | Defaults to `0` |
| `HideNumberPad` | bit | Defaults to `0` |
| `DisplayPreviousOrders` | bit | Defaults to `0` |
| `DisplayAccountBalance` | bit | Defaults to `0` |

---

#### `cr.Product`
A sellable product on a cash register. Optionally linked to an accounting category and an inventory item. CASCADE deletes when the register is deleted.

| Column | Type | Notes |
|---|---|---|
| `ProductID` | int IDENTITY | PK |
| `CashRegisterID` | int | FK → `cr.CashRegister` (CASCADE) |
| `AccountingCategoryID` | int | FK → `dbo.AcctCat`; nullable |
| `InventoryID` | int | FK → `dbo.Inventory`; nullable |
| `ProductName` | nvarchar(128) | Nullable |
| `Barcode` | nvarchar(64) | Nullable |
| `Price` | decimal(19,4) | Defaults to 0 |
| `IsTaxable` | bit | Defaults to `0` |
| `SortOrder` | int | Defaults to 0 |
| `BackgroundColor` | nvarchar(7) | Hex color; nullable |

---

#### `cr.ColumnColor`
Display color settings for a specific column number on a cash register UI. No FK — `CashRegisterID` is part of the composite PK but not constrained.

| Column | Type | Notes |
|---|---|---|
| `CashRegisterID` | int | PK (composite) |
| `ColumnNum` | int | PK (composite) |
| `FontColor` | nvarchar(50) | Nullable |
| `BackgroundColor` | nvarchar(50) | Nullable |

---

#### `cr.DepartmentColor`
Display color settings for a defined-list department on a cash register UI.

| Column | Type | Notes |
|---|---|---|
| `CashRegisterID` | int | PK (composite) |
| `DLID` | int | PK (composite); FK → `dbo.DefinedLists` |
| `Department` | nvarchar(250) | Required |
| `BackgroundColor` | nvarchar(50) | Nullable |
| `IsWhite` | bit | Defaults to `0` |
| `IsBlack` | bit | Defaults to `1` |

---

#### `cr` schema — cross-reference summary

| Table | Scope | Key FK targets |
|---|---|---|
| `CashRegister` | Register definition | `dbo.AccountingSystem`, `dbo.AcctCat` |
| `CashRegisterSession` | Open/closed register session | `cr.CashRegister`, `dbo.Person_Staff` |
| `CashRegisterStaffMM` | Authorized staff per register | `cr.CashRegister`, `dbo.Person_Staff` |
| `UserCashRegister` | UI display flags per register | — |
| `Product` | Sellable product on a register | `cr.CashRegister`, `dbo.AcctCat`, `dbo.Inventory` |
| `ColumnColor` | Column color config per register | — |
| `DepartmentColor` | Department color config per register | `dbo.DefinedLists` |

---

### `crse` schema tables

The `crse` schema holds Ed-Fi course and section data.

#### `crse.CourseCore`
Master course record. The central FK target for the entire `crse` schema and for many tables in `aca`, `acct`, `cnfg`, `cnv`, and `aca` schemas. Temporal table.

| Column | Type | Notes |
|---|---|---|
| `CourseID` | int IDENTITY | PK |
| `Title` | nvarchar(50) | Nullable |
| `Abbreviation` | nvarchar(50) | Nullable |
| `Description` | nvarchar(4000) | Nullable |
| `CourseLevelID` | int | FK → `dbo.CourseLevel`; indexed; nullable |
| `SchoolCode` | varchar(50) | FK → `dbo.ConfigSchool.SchoolCode`; indexed; nullable |
| `Active` | bit | Defaults to `1` |
| `ModifiedBy` | int | Indexed; nullable (no FK constraint) |
| `ModifiedDate` | smalldatetime | Nullable |
| `CreatedOnUTC` | datetime2(2) | Defaults to `SYSUTCDATETIME()` |
| `ModifiedOnUTC` / `ModifiedOnUTCmax` | datetime2(2) | Temporal ROW START/END |

---

#### `crse.CourseCalculation`
Grading calculation settings for a course — credits, weighting factors, transcript flags. One row per course (PK = `CourseID`). Temporal table.

| Column | Type | Notes |
|---|---|---|
| `CourseID` | int | PK; FK → `crse.CourseCore` |
| `Credits` | decimal(9,4) | Nullable |
| `ReportCard` | bit | Defaults to `0` |
| `Calc` | bit | Defaults to `0` |
| `TermWt` / `SemesterWt` / `FinalWt` | decimal(9,4) | Term/semester/final weights; nullable |
| `TranscriptLoadTimeFrame` | int | Defaults to 0 |
| `NoCalcTranscript` | bit | Defaults to `0` |
| `CreatedOnUTC` | datetime2(2) | Defaults to `SYSUTCDATETIME()` |
| `ModifiedOnUTC` / `ModifiedOnUTCmax` | datetime2(2) | Temporal ROW START/END |

---

#### `crse.CourseDeprecatedFields`
Legacy course fields preserved for backward compatibility — Moodle integration, weight, prerequisites, schedule style, etc. **Do not reference these in new code.** Temporal table with `PERIOD FOR SYSTEM_TIME`.

| Column | Type | Notes |
|---|---|---|
| `CourseID` | int | PK; FK → `crse.CourseCore` |
| `Transcript` | bit | Defaults to `0` |
| `Terms` / `Contacts` | int | Nullable |
| `Prerequisites` / `Corequisites` / `Equivalents` / `ReqGrade` | nvarchar(50) | Nullable |
| `CalcTranscript` | bit | Nullable |
| `Weight` | real | Nullable |
| `EnableMoodle` / `MoodleGuestAccess` | bit | Moodle integration flags |
| `MoodleCourseID` | int | Nullable |
| `CourseType` | nvarchar(50) | Nullable |
| `DepartmentID` | int | Nullable (no FK) |
| `ScheduleStyle` | int | Nullable |
| `CreatedOnUTC` | datetime2(2) | Defaults to `SYSUTCDATETIME()` |
| `ModifiedOnUTC` / `ModifiedOnUTCmax` | datetime2(2) | Temporal ROW START/END |

---

#### `crse.CourseExternalIDs`
External identifier cross-references for a course — state ID, IB course ID, legacy course ID. One row per course. Temporal table.

| Column | Type | Notes |
|---|---|---|
| `CourseID` | int | PK; FK → `crse.CourseCore` |
| `StateID` | nvarchar(64) | State course code; nullable |
| `IBCourseID` | int | IB course reference; nullable |
| `LegacyCourseID` | nvarchar(20) | Legacy system cross-reference; nullable |
| `CreatedOnUTC` | datetime2(2) | Defaults to `SYSUTCDATETIME()` |
| `ModifiedOnUTC` / `ModifiedOnUTCmax` | datetime2(2) | Temporal ROW START/END |

---

#### `crse.CourseFilterFlags`
Boolean flags used to filter/classify courses for UI and reporting — attendance tracking, activity, homeroom, elective, report card placement. Temporal table with `PERIOD FOR SYSTEM_TIME`.

| Column | Type | Notes |
|---|---|---|
| `CourseID` | int | PK; FK → `crse.CourseCore` |
| `Attendance` | bit | Defaults to `0` |
| `Activity` | bit | Defaults to `0` |
| `HomeRoom` | bit | Defaults to `0` |
| `Elective` | bit | Defaults to `0` |
| `Department` | nvarchar(50) | Nullable |
| `RCPlacement` | int | Report card placement slot; nullable |
| `CreatedOnUTC` | datetime2(2) | Defaults to `SYSUTCDATETIME()` |
| `ModifiedOnUTC` / `ModifiedOnUTCmax` | datetime2(2) | Temporal ROW START/END |

---

#### `crse.CourseIdentificationCode`
Ed-Fi course identification codes (e.g. SCED, LEA-assigned) for an Ed-Fi course. One row per course × identification system descriptor (unique clustered).

| Column | Type | Notes |
|---|---|---|
| `CourseIdentificationCodeID` | int IDENTITY | PK (non-clustered) |
| `EdFiCourseID` | int | FK → `crse.EdFiCourse`; unique clustered with `CourseIdentificationSystemDescriptorID` |
| `CourseIdentificationSystemDescriptorID` | uniqueidentifier | Required |
| `IdentificationCode` | nvarchar(60) | Required |
| `AssigningOrganizationIdentificationCode` | nvarchar(60) | Nullable |
| `CourseCatalogURL` | nvarchar(255) | Nullable |

---

#### `crse.CourseLearningObjectiveMM`
Many-to-many link between Ed-Fi courses and learning objectives (`aca.LearningObjective`).

| Column | Type | Notes |
|---|---|---|
| `EdFiCourseID` | int | PK (composite); FK → `crse.EdFiCourse` |
| `LearningObjectiveID` | int | PK (composite); FK → `aca.LearningObjective`; indexed |

---

#### `crse.CourseLearningStandardMM`
Many-to-many link between SIS courses and Ed-Fi learning standards (`aca.LearningStandard`).

| Column | Type | Notes |
|---|---|---|
| `SISCourseID` | int | PK (composite); FK → `crse.CourseCore` |
| `LearningStandardID` | int | PK (composite); FK → `aca.LearningStandard`; indexed |

---

#### `crse.CourseLevelCharacteristic`
Ed-Fi course level characteristic descriptors. Standalone lookup — no FK to `crse.CourseCore`.

| Column | Type | Notes |
|---|---|---|
| `CourseLevelCharacteristicId` | int IDENTITY | Part of composite PK |
| `CourseLevelCharacteristicDescriptorId` | uniqueidentifier | Part of composite PK |

---

#### `crse.CourseOffering`
Links a course to a session (term), creating a scheduled offering. One row per course × session (unique). FK to `cnfg.Session`.

| Column | Type | Notes |
|---|---|---|
| `CourseOfferingID` | int IDENTITY | PK |
| `SessionID` | int | FK → `cnfg.Session`; indexed; unique with `LocalCourseID` |
| `LocalCourseID` | int | FK → `crse.CourseCore` |
| `InstructionalTimePlanned` | int | Defaults to 0 |

---

#### `crse.CourseSchoolDivision`
Flags which school divisions a course is available in. One row per course (PK = `CourseID`). Temporal table.

| Column | Type | Notes |
|---|---|---|
| `CourseID` | int | PK; FK → `crse.CourseCore` |
| `HS` | bit | High school; defaults to `0` |
| `MiddleSchool` | bit | Defaults to `0` |
| `Elementary` | bit | Defaults to `0` |
| `PreSchool` | bit | Defaults to `0` |
| `CreatedOnUTC` | datetime2(2) | Defaults to `SYSUTCDATETIME()` |
| `ModifiedOnUTC` / `ModifiedOnUTCmax` | datetime2(2) | Temporal ROW START/END |

---

#### `crse.EdFiCourse`
Ed-Fi Course entity — extends `crse.CourseCore` with Ed-Fi-specific fields (GPA applicability, credit ranges, career pathway, etc.). Identified by `(CourseID, CourseCode)` (unique clustered).

| Column | Type | Notes |
|---|---|---|
| `EdFiCourseID` | int IDENTITY | PK (non-clustered) |
| `CourseID` | int | FK → `crse.CourseCore`; unique clustered with `CourseCode` |
| `CourseCode` | nvarchar(60) | Required |
| `AcademicSubjectDescriptorID` | uniqueidentifier | Nullable |
| `CareerPathwayDescriptorID` | uniqueidentifier | Nullable |
| `CourseDefinedByDescriptorID` | uniqueidentifier | Nullable |
| `CourseGPAApplicabilityDescriptorID` | uniqueidentifier | Nullable |
| `DateCourseAdopted` | date | Nullable |
| `HighSchoolCourseRequirement` | bit | Defaults to `0` |
| `MaxCompletionsForCredit` | int | Defaults to 0 |
| `MaximumAvailableCredits` / `MinimumAvailableCredits` | decimal(9,4) | Nullable |
| `MaximumAvailableCreditConversion` / `MinimumAvailableCreditConversion` | decimal(9,4) | Nullable |
| `MaximumAvailableCreditTypeDescriptorID` / `MinimumAvailableCreditTypeDescriptorID` | uniqueidentifier | Nullable |
| `NumberOfParts` | int | Defaults to 1 |
| `TimeRequiredForCompletion` | int | Defaults to 0 |

---

#### `crse.EdFiSection`
Ed-Fi Section entity — represents a scheduled class section, linking a SIS class (`dbo.Classes`) to a course offering and session. Referenced as FK target across `aca`, `cnfg`, and `crse` schemas.

| Column | Type | Notes |
|---|---|---|
| `EdFiSectionID` | int IDENTITY | PK |
| `SISClassID` | int | FK → `dbo.Classes` |
| `CourseOfferingID` | int | FK → `crse.CourseOffering`; unique with `EdFiSectionIdentifier` + `SessionId` |
| `EdFiSectionIdentifier` | nvarchar(255) | Required |
| `SectionName` | nvarchar(60) | Required |
| `SessionId` | int | FK → `cnfg.Session`; indexed |
| `AvailableCreditConversion` | decimal(9,2) | Nullable |
| `AvailableCreditTypeDescriptorID` | uniqueidentifier | Nullable |
| `EducationalEnvironmentDescriptorID` | uniqueidentifier | Nullable |
| `InstructionLanguageDescriptorID` | uniqueidentifier | Nullable |
| `MediumOfInstructionDescriptorID` | uniqueidentifier | Nullable |
| `OfficialAttendancePeriod` | bit | Defaults to `0` |
| `PopulationServedDescriptorID` | uniqueidentifier | Nullable |
| `SequenceOfCourse` | int | Nullable |

---

#### `crse.EdFiSectionCharacteristic`
Ed-Fi section characteristic descriptors for a section. One row per section × characteristic descriptor.

| Column | Type | Notes |
|---|---|---|
| `SectionCharacteristicID` | int IDENTITY | Part of composite PK |
| `SectionCharacteristicDescriptorID` | uniqueidentifier | Part of composite PK |
| `SectionID` | int | FK → `crse.EdFiSection`; indexed |
| `LocalCourseID` | int | FK → `crse.CourseCore`; indexed |

---

#### `crse.LearningObjectiveAcademicSubject`
Academic subject descriptors for a learning objective. One row per objective × subject.

| Column | Type | Notes |
|---|---|---|
| `LearningObjectiveAcademicSubjectID` | int IDENTITY | PK |
| `LearningObjectiveID` | int | FK → `aca.LearningObjective`; indexed |
| `AcademicSubjectDescriptorID` | uniqueidentifier | Required |

---

#### `crse.LearningObjectiveContentStandard`
Content standard publication metadata for a learning objective. One row per objective (unique on `LearningObjectiveId`). Mandating org FK to `cnfg.EducationOrganization`.

| Column | Type | Notes |
|---|---|---|
| `LearningObjectiveContentStandardId` | int IDENTITY | PK |
| `LearningObjectiveId` | int | FK → `aca.LearningObjective`; unique |
| `MandatingEducationOrganizationId` | bigint | FK → `cnfg.EducationOrganization`; indexed |
| `BeginDate` | date | Required |
| `EndDate` | date | Nullable |
| `PublicationDate` | date | Required |
| `PublicationStatusDescriptorId` | uniqueidentifier | Required |
| `PublicationYear` | smallint | Required |
| `Title` | nvarchar(75) | Required |
| `URI` | nvarchar(255) | Required |
| `Version` | nvarchar(50) | Required |

---

#### `crse.LearningObjectiveContentStandardAuthor`
Authors of a learning objective's content standard. One row per objective × author name (unique).

| Column | Type | Notes |
|---|---|---|
| `LearningObjectiveContentStandardAuthorId` | int IDENTITY | PK |
| `LearningObjectiveId` | int | FK → `aca.LearningObjective`; unique with `Author` |
| `Author` | nvarchar(100) | Required |

---

#### `crse.LearningObjectiveGradeLevelMM`
Grade levels applicable to a learning objective.

| Column | Type | Notes |
|---|---|---|
| `GradeLevelID` | int | PK (composite); FK → `dbo.GradeLevels` |
| `LearningObjectiveID` | int | PK (composite); FK → `aca.LearningObjective`; indexed |

---

#### `crse.LearningObjectiveLearningStandardMM`
Many-to-many link between learning objectives and learning standards.

| Column | Type | Notes |
|---|---|---|
| `LearningStandardID` | int | PK (composite); FK → `aca.LearningStandard` |
| `LearningObjectiveID` | int | PK (composite); FK → `aca.LearningObjective`; indexed |

---

#### `crse.LearningStandardAcademicSubject`
Academic subject descriptors for a learning standard. One row per standard × subject descriptor.

| Column | Type | Notes |
|---|---|---|
| `LearningStandardAcademicSubjectId` | int IDENTITY | PK |
| `LearningStandardId` | int | FK → `aca.LearningStandard` |
| `AcademicSubjectDescriptorId` | uniqueidentifier | Required; indexed |

---

#### `crse.LearningStandardContentStandard`
Content standard publication metadata for a learning standard. One row per standard (unique on `LearningStandardID`). Mirrors `crse.LearningObjectiveContentStandard` at the standard level.

| Column | Type | Notes |
|---|---|---|
| `LearningStandardContentStandardID` | int IDENTITY | PK |
| `LearningStandardID` | int | FK → `aca.LearningStandard`; unique |
| `MandatingEducationOrganizationID` | bigint | FK → `cnfg.EducationOrganization`; indexed |
| `BeginDate` | date | Required |
| `EndDate` | date | Nullable |
| `PublicationDate` | date | Required |
| `PublicationStatusDescriptorID` | uniqueidentifier | Required |
| `PublicationYear` | smallint | Required |
| `Title` | nvarchar(75) | Required |
| `URI` | nvarchar(255) | Required |
| `Version` | nvarchar(50) | Required |

---

#### `crse.LearningStandardContentStandardAuthor`
Authors of a learning standard's content standard. One row per standard × author (unique).

| Column | Type | Notes |
|---|---|---|
| `LearningStandardContentStandardAuthorID` | int IDENTITY | PK |
| `LearningStandardID` | int | FK → `aca.LearningStandard`; indexed; unique with `Author` |
| `Author` | nvarchar(100) | Required |

---

#### `crse.LearningStandardGradeLevelMM`
Grade levels applicable to a learning standard.

| Column | Type | Notes |
|---|---|---|
| `LearningStandardID` | int | PK (composite); FK → `aca.LearningStandard` |
| `GradeLevelID` | int | PK (composite); FK → `dbo.GradeLevels`; indexed |

---

#### `crse.LearningStandardIdentificationCode`
External identification codes for a learning standard. One row per standard × content standard name × identification code (unique).

| Column | Type | Notes |
|---|---|---|
| `LearningStandardIdentificationCodeID` | int IDENTITY | PK |
| `LearningStandardID` | int | FK → `aca.LearningStandard`; part of unique key |
| `ContentStandardName` | nvarchar(65) | Required; part of unique key |
| `IdentificationCode` | nvarchar(60) | Required; part of unique key |

---

#### `crse.LearningStandardPrerequisiteLearningStandard`
Records prerequisite learning standards for a learning standard. The prerequisite is stored as a string identifier rather than a FK.

| Column | Type | Notes |
|---|---|---|
| `LearningStandardPrerequisisteLearningStandardId` | int IDENTITY | PK (note: name has a typo in DDL — "Prerequisiste") |
| `LearningStandardId` | int | FK → `aca.LearningStandard`; indexed |
| `PrerequisiteLearningStandardId` | nvarchar(60) | Prerequisite standard identifier (string, not FK) |

---

#### `crse.SectionClassPeriod`
Class period names for a section. One row per section class period (PK includes `ClassPeriodName`).

| Column | Type | Notes |
|---|---|---|
| `SectionClassPeriodID` | int IDENTITY | Part of composite PK |
| `ClassPeriodName` | nvarchar(60) | Part of composite PK |
| `SectionID` | int | FK → `crse.EdFiSection`; indexed |
| `LocalCourseID` | int | FK → `crse.CourseCore`; indexed |

---

#### `crse.SectionCourseLevelCharacteristic`
Course level characteristic descriptors applied to a specific section. Unique on `(SISCourseID, SISClassID, EdFiSectionID)`.

| Column | Type | Notes |
|---|---|---|
| `CourseLevelCharacteristicDescriptorID` | uniqueidentifier | PK |
| `SISClassID` | int | FK → `dbo.Classes`; indexed |
| `SISCourseID` | int | FK → `crse.CourseCore`; part of unique key |
| `EdFiSectionID` | int | FK → `crse.EdFiSection`; indexed |

---

#### `crse.SectionOfferedGradeLevel`
Grade levels at which a section is offered. Unique on `(SISClassID, SISCourseID)`.

| Column | Type | Notes |
|---|---|---|
| `SectionOfferedGradeLevelID` | int IDENTITY | PK |
| `SISClassID` | int | FK → `dbo.Classes`; part of unique key |
| `SISCourseID` | int | FK → `crse.CourseCore`; indexed; part of unique key |
| `GradeLevelDescriptorID` | uniqueidentifier | Required |
| `EdFiSectionID` | int | FK → `crse.EdFiSection`; indexed |

---

#### `crse.SectionProgram`
Programs associated with a section. Unique on `(SISCourseID, ProgramName, ProgramTypeDescriptorID, ClassID)`.

| Column | Type | Notes |
|---|---|---|
| `SectionProgramID` | int IDENTITY | PK |
| `SISCourseID` | int | FK → `crse.CourseCore`; part of unique key |
| `ClassID` | int | FK → `dbo.Classes`; indexed |
| `ProgramName` | nvarchar(60) | Part of unique key |
| `ProgramTypeDescriptorID` | uniqueidentifier | Part of unique key |

---

#### `crse` schema — cross-reference summary

| Table | Scope | Key FK targets |
|---|---|---|
| `CourseCore` | Master course record | `dbo.ConfigSchool`, `dbo.CourseLevel` |
| `CourseCalculation` | Grading weights and transcript flags | `crse.CourseCore` |
| `CourseDeprecatedFields` | Legacy fields (do not use in new code) | `crse.CourseCore` |
| `CourseExternalIDs` | State/IB/legacy ID cross-references | `crse.CourseCore` |
| `CourseFilterFlags` | Classification flags (attendance, homeroom, etc.) | `crse.CourseCore` |
| `CourseSchoolDivision` | School division availability flags | `crse.CourseCore` |
| `EdFiCourse` | Ed-Fi course extension | `crse.CourseCore` |
| `CourseIdentificationCode` | Ed-Fi identification codes | `crse.EdFiCourse` |
| `CourseLearningObjectiveMM` | Course ↔ learning objective | `crse.EdFiCourse`, `aca.LearningObjective` |
| `CourseLearningStandardMM` | Course ↔ learning standard | `crse.CourseCore`, `aca.LearningStandard` |
| `CourseLevelCharacteristic` | Ed-Fi level characteristic descriptors | — |
| `CourseOffering` | Course ↔ session offering | `crse.CourseCore`, `cnfg.Session` |
| `EdFiSection` | Ed-Fi section (class instance) | `crse.CourseOffering`, `cnfg.Session`, `dbo.Classes` |
| `EdFiSectionCharacteristic` | Section characteristic descriptors | `crse.EdFiSection`, `crse.CourseCore` |
| `SectionClassPeriod` | Class period names per section | `crse.EdFiSection`, `crse.CourseCore` |
| `SectionCourseLevelCharacteristic` | Level characteristics per section | `crse.EdFiSection`, `dbo.Classes`, `crse.CourseCore` |
| `SectionOfferedGradeLevel` | Grade levels a section is offered at | `crse.EdFiSection`, `dbo.Classes`, `crse.CourseCore` |
| `SectionProgram` | Programs on a section | `crse.CourseCore`, `dbo.Classes` |
| `LearningObjectiveAcademicSubject` | Subjects on a learning objective | `aca.LearningObjective` |
| `LearningObjectiveContentStandard` | Content standard metadata per objective | `aca.LearningObjective`, `cnfg.EducationOrganization` |
| `LearningObjectiveContentStandardAuthor` | Authors of an objective's content standard | `aca.LearningObjective` |
| `LearningObjectiveGradeLevelMM` | Objective ↔ grade level | `aca.LearningObjective`, `dbo.GradeLevels` |
| `LearningObjectiveLearningStandardMM` | Objective ↔ learning standard | `aca.LearningObjective`, `aca.LearningStandard` |
| `LearningStandardAcademicSubject` | Subjects on a learning standard | `aca.LearningStandard` |
| `LearningStandardContentStandard` | Content standard metadata per standard | `aca.LearningStandard`, `cnfg.EducationOrganization` |
| `LearningStandardContentStandardAuthor` | Authors of a standard's content standard | `aca.LearningStandard` |
| `LearningStandardGradeLevelMM` | Standard ↔ grade level | `aca.LearningStandard`, `dbo.GradeLevels` |
| `LearningStandardIdentificationCode` | External identification codes per standard | `aca.LearningStandard` |
| `LearningStandardPrerequisiteLearningStandard` | Prerequisite standards (string ref) | `aca.LearningStandard` |
| `CompetencyLevel` | Ed-Fi competency levels per course | `crse.EdFiCourse` |

---

### `dbo` schema — additional documented tables

The `dbo` schema is the legacy core (see **Core FACTS tables** above). Individual `dbo` tables documented from provided DDL:

#### `dbo._Trojan`
A small diagnostic/tracking table recording a count per table-column pair. Despite the name, it contains no code — just three nullable columns. No PK, no FK, no constraints. Likely a developer/maintenance scratch table used to track row or value counts during data audits.

| Column | Type | Notes |
|---|---|---|
| `TableName` | varchar(50) | Nullable |
| `ColumnName` | varchar(50) | Nullable |
| `Count` | int | Nullable |

Treat this as a utility/scratch table — not part of the core application data model.

#### `dbo.AccountingSystem`
Defines an accounting system for a school — web payment settings, GL/revenue/liability/asset account codes, and QuickBooks integration fields. The central FK target for `cr.CashRegister`, `dbo.AccountingSystemUsers`, and other accounting tables.

| Column | Type | Notes |
|---|---|---|
| `AccountingSystemID` | int IDENTITY | PK |
| `AccountingSystemName` | nvarchar(50) | Nullable |
| `SchoolCode` | varchar(50) | Nullable |
| `WebPayment` / `BlockParentsWeb` / `AutoClearWebPayment` | bit | Web payment flags; nullable |
| `SchoolPaysConvenienceFee` | bit | Nullable |
| `GLCashAccount` / `RevenueAccount` / `LiabilityAccount` / `AssetAccount` | nvarchar(60) | GL account codes; nullable |
| `AutoClear` | bit | Defaults to `1` |
| `QB_AcctSystemID` / `QB_AcctSystemName` / `DefaultQBItemId` / `QB_Worksheet` | nvarchar | QuickBooks integration; nullable |
| `QB_PrePaymentLiability` | bit | Defaults to `0` |
| `FactsAccountID` | int | FK → `facts.Account`; nullable |

Indexed on `(AccountingSystemID, BlockParentsWeb)`.

---

#### `dbo.AccountingSystemUsers`
Authorizes staff to access an accounting system, with an optional modify flag. PK is composite `(AccountingSystemID, StaffID)`.

| Column | Type | Notes |
|---|---|---|
| `AccountingSystemID` | int | PK (composite) |
| `StaffID` | int | PK (composite) |
| `Modify` | bit | Write access flag; nullable |

---

#### `dbo.AccountingFamily`
Per-school family accounting record, including QuickBooks sync state. PK is composite `(SchoolCode, FamilyID)`.

| Column | Type | Notes |
|---|---|---|
| `SchoolCode` | varchar(50) | PK (composite) |
| `FamilyID` | int | PK (composite) |
| `QuickBooksID` | nvarchar(50) | Nullable |
| `QuickBooksSync` | bit | Nullable |
| `Table_Creationtime` | datetime | Nullable |
| `Accounting` | bit | Nullable |

---

#### `dbo.AccountingFamily_AccountingCodes`
Accounting codes assigned to a family at a school. PK is composite `(FamilyID, SchoolCode, AccountingCode)`.

| Column | Type | Notes |
|---|---|---|
| `FamilyID` | int | PK (composite) |
| `SchoolCode` | varchar(50) | PK (composite) |
| `AccountingCode` | nvarchar(255) | PK (composite) |
| `ModifiedBy` | int | Nullable |
| `ModifiedDate` | smalldatetime | Nullable |

---

#### `dbo.AcctCat`
Accounting category (chart-of-accounts node). Self-referencing via `ParentID` to build a category hierarchy (up to 5 levels). Links accounting categories to GL accounts and QuickBooks items. Referenced by `cr.CashRegister`, `cr.Product`, and many accounting reports.

| Column | Type | Notes |
|---|---|---|
| `CatID` | int IDENTITY | PK (non-clustered) |
| `Title` | nvarchar(50) | Indexed; nullable |
| `ParentID` | int | Self-reference; indexed; defaults to 0 |
| `SchoolCode` | varchar(50) | Indexed; nullable |
| `AccountingSystemID` | int | Nullable (no FK constraint) |
| `AssetAccount` / `LiabilityAccount` / `RevenueAccount` / `Account` | nvarchar(64) | GL account codes; nullable |
| `FullTitle` | nvarchar(256) | Nullable |
| `Level1`…`Level5` | nvarchar(50) | Hierarchy level names; nullable |
| `Levels` | int | Depth count; nullable |
| `QB_ItemID` / `QB_Worksheet` / `QB_ItemName` | nvarchar | QuickBooks integration; nullable |
| `FactsAdjustmentReasonId` | int | FK → `facts.AdjustmentReason`; nullable |
| `ModifiedBy` / `ModifiedDate` | int / smalldatetime | Nullable |

---

#### `dbo.Acct_Active`
Tracks whether a student's family accounting is active at a school. PK is composite `(FamilyID, studentID, SchoolCode)`.

| Column | Type | Notes |
|---|---|---|
| `FamilyID` | int | PK (composite) |
| `studentID` | int | PK (composite) |
| `SchoolCode` | varchar(50) | PK (composite) |
| `active` | bit | Nullable |

---

#### `dbo.Acct_Person_Family`
Associates a person with a family under an accounting system, with a financial responsibility percentage. PK is composite `(PersonID, FamilyID, AccountingSystemID)`.

| Column | Type | Notes |
|---|---|---|
| `PersonID` | int | PK (composite) |
| `FamilyID` | int | PK (composite) |
| `AccountingSystemID` | int | PK (composite) |
| `FinancialResponsibility` | real | Share of responsibility; nullable |

---

#### `dbo.Acct_PayEasy`
PayEasy payment transaction record — ACH/credit card payments, settlement, bank details. The header for `dbo.Acct_PayEasyCharges`.

| Column | Type | Notes |
|---|---|---|
| `PayEasyID` | int IDENTITY | PK |
| `FamilyID` | int | Nullable |
| `SchoolCode` | varchar(50) | Nullable |
| `Amount` / `TransactionAmount` | money | Nullable |
| `Description` | varchar(50) | Nullable |
| `PaymentID` / `TransactionID` | varchar(50) | Gateway identifiers; nullable |
| `ProcessDate` / `SettlementDate` | smalldatetime | Nullable |
| `BankName` | varchar(128) | Nullable |
| `BankAccount` | varchar(50) | Nullable |
| `PaymentType` | int | Nullable |
| `Message` | varchar(128) | Nullable |
| `RenWebPaymentID` / `DepositID` / `FileID` / `deposit` | int | Cross-references; nullable |
| `Cancel` / `paymentinterruption` / `ACH` / `CC` | bit | Status flags; nullable |

---

#### `dbo.Acct_PayEasyCharges`
Line items linking a PayEasy payment to the charges it pays. PK is composite `(PayEasyID, ChargeID)`.

| Column | Type | Notes |
|---|---|---|
| `PayEasyID` | int | PK (composite); references `dbo.Acct_PayEasy` |
| `ChargeID` | int | PK (composite); indexed with `Cancel` |
| `RecurringChargeID` | int | Nullable |
| `Amount` | money | Nullable |
| `Cancel` | bit | Nullable |

---

#### `dbo.Acct_PayNowFamilyBlock`
Blocks a family from using PayNow under a given accounting system. PK is composite `(AccountingSystemID, FamilyID)`.

| Column | Type | Notes |
|---|---|---|
| `AccountingSystemID` | int | PK (composite) |
| `FamilyID` | int | PK (composite) |

---

#### `dbo` accounting tables — cross-reference summary

| Table | Scope | Key FK targets |
|---|---|---|
| `AccountingSystem` | Accounting system per school | `facts.Account` |
| `AccountingSystemUsers` | Staff access to accounting system | — |
| `AccountingFamily` | Family accounting + QuickBooks sync | — |
| `AccountingFamily_AccountingCodes` | Accounting codes per family | — |
| `AcctCat` | Accounting category hierarchy | `facts.AdjustmentReason`, self |
| `Acct_Active` | Family accounting active flag | — |
| `Acct_Person_Family` | Person ↔ family financial responsibility | — |
| `Acct_PayEasy` | PayEasy payment transaction | — |
| `Acct_PayEasyCharges` | Charges paid by a PayEasy payment | — |
| `Acct_PayNowFamilyBlock` | PayNow block per family | — |
| `AcctCodeUsers` | Accounting code assigned to family/student | — |
| `AcctGLClosing` | GL period-close flag per school/date | — |
| `AcctTuitionPlan` | Tuition plan template (per fiscal year) | — |
| `AcctStudentTuitionPlan` | Per-student tuition plan instance | — |

---

#### `dbo.AcctCodeUsers`
Associates an accounting code with a family/student at a school. Surrogate-key table (all business columns nullable).

| Column | Type | Notes |
|---|---|---|
| `AcctCodeUsersID` | int IDENTITY | PK |
| `FamilyID` | int | Nullable |
| `StudentID` | int | Nullable |
| `SchoolCode` | varchar(50) | Nullable |
| `AccountingCode` | nvarchar(127) | Nullable |

---

#### `dbo.AcctGLClosing`
General-ledger period-close flag — marks a date as closed for a school so transactions can't be posted to it. PK is composite `(Date, SchoolCode)`.

| Column | Type | Notes |
|---|---|---|
| `Date` | smalldatetime | PK (composite); the closing date |
| `SchoolCode` | varchar(50) | PK (composite) |
| `Closed` | bit | Nullable |
| `ModifiedDate` / `ModifiedBy` | smalldatetime / int | Nullable |

---

#### `dbo.AcctTuitionPlan`
Tuition plan **template** for a fiscal year — defines tuition, multi-child discounts (1–6), staff discount, up to 3 generic discounts, up to 3 charges, 12 installment flags, and re-enroll settings. Each amount field has a paired `*CatID` linking to `dbo.AcctCat`. Temporal table. PK is composite `(FiscalYearID, TuitionPlanName)`.

| Column group | Type | Notes |
|---|---|---|
| `TuitionPlanID` | int IDENTITY | Surrogate key (not the PK) |
| `FiscalYearID` | int | PK (composite) |
| `TuitionPlanName` | nvarchar(50) | PK (composite) |
| `GradeLevels` | nvarchar(128) | Applicable grade levels; nullable |
| `Tuition` / `TuitionCatID` | real / int | Base tuition + category |
| `MultiChild1`…`MultiChild6` / `MultiChildCatID` | real / int | Multi-child discount tiers |
| `StaffDiscountAmount` / `StaffCatID` | real / int | Staff discount |
| `Discount1`…`Discount3` (+ `*Name`, `*Amount`, `*CatID`) | mixed | Generic discounts |
| `Charge1`…`Charge3` (+ `*Name`, `*Single`, `*CatID`) | mixed | Additional charges |
| `Installment1`…`Installment12` | bit | Per-month installment flags |
| `Reenroll` / `ReEnrollName` / `ReenrollCatID` / `ReenrollFiscalYearID` / `ReenrollAccountingSystemID` | mixed | Re-enrollment settings |
| `AccountingSystemID` / `interval` / `Months` / `Child` / `DiscountType` / `AmountType` | int/real | Plan config |
| `ChargeDate` / `DueDate` | smalldatetime | Nullable |
| `CreatedOnUTC` / `ModifiedOnUTC` / `ModifiedOnUTCmax` | datetime2(2) | Temporal versioning |

---

#### `dbo.AcctStudentTuitionPlan`
Per-student **instance** of a tuition plan for a fiscal year — the applied plan with the student's actual amounts. Mirrors `AcctTuitionPlan` structure but resolved per student. Temporal table. PK is composite `(FiscalYearID, StudentID, FamilyID)`.

| Column group | Type | Notes |
|---|---|---|
| `FiscalYearID` | int | PK (composite) |
| `StudentID` | int | PK (composite) |
| `FamilyID` | int | PK (composite) |
| `SchoolCode` | varchar(50) | Nullable |
| `TuitionPlanName` | nvarchar(50) | The applied plan |
| `Tuition` / `TuitionCatID` | real / int | Resolved tuition |
| `MultiChild` / `MultichildDiscountAmount` / `MultiChildCatID` / `MultiChildDiscountName` | mixed | Multi-child discount |
| `STaff` / `StaffDiscountAmount` / `StaffCatID` / `StaffDiscountName` | mixed | Staff discount |
| `Discount1`…`Discount3` (+ `*Name`, `*Amount`, `*CatID`) | mixed | Generic discounts |
| `Charge1`…`Charge3` (+ `*Name`, `*Single`, `*CatID`) | mixed | Additional charges |
| `Installment1`…`Installment12` | bit | Per-month installment flags |
| `Reenroll` / `ReEnrollName` / `ReenrollCatID` / `ReenrollFiscalYearID` / `ReenrollAccountingSystemID` | mixed | Re-enrollment settings |
| `AccountingSystemID` / `interval` / `Months` / `Child` / `DiscountType` / `AmountType` | int/real | Plan config |
| `ChargeDate` / `DueDate` | smalldatetime | Nullable |
| `CreatedOnUTC` / `ModifiedOnUTC` / `ModifiedOnUTCmax` | datetime2(2) | Temporal versioning |

---

### `dbo` activity log tables

A family of append-only audit/log tables, each scoped to a domain. All share a common shape (`LogID` PK, `ModifiedBy`, a timestamp, `Source`) and use `DATA_COMPRESSION = ROW` on their main index. None declare FK constraints — they reference IDs loosely for performance.

#### `dbo.ActivityLog`
General activity log covering students, families, charges, classes, assignments, terms, etc.

| Column | Type | Notes |
|---|---|---|
| `LogID` | int IDENTITY | PK |
| `Type` | nvarchar(50) | Log entry category; nullable |
| `Note` / `Task` | nvarchar(1000) | Free text; nullable |
| `StudentID` / `FamilyID` / `ChargeID` / `ID` / `ClassID` / `AssessmentID` / `AssignmentID` / `YearID` / `TermID` | int | Loosely-referenced IDs; nullable |
| `ModifiedBy` | int | Nullable |
| `ModifiedDate` | nvarchar(64) | Stored as text; nullable |
| `ModifiedByDateTime` | smalldatetime | Defaults to `GETDATE()` |
| `SerialNo` | int | Nullable |
| `Web` | bit | Nullable |
| `Source` | nvarchar(50) | Nullable |

---

#### `dbo.ActivityLog_Acct`
Accounting-specific activity log — payments, charges, lunch orders, recurring charges.

| Column | Type | Notes |
|---|---|---|
| `LogID` | int IDENTITY | PK |
| `Type` | nvarchar(50) | Nullable |
| `Note` / `Task` | nvarchar(1000) | Nullable |
| `StudentID` / `FamilyID` / `PaymentID` / `LunchOrderID` / `RecurringChargeID` / `ClassID` / `FiscalYearID` / `AccountingSystemID` / `ChargeID` | int | Loosely-referenced IDs; nullable |
| `Amount` | real | Nullable |
| `Date` / `DateDue` | smalldatetime | Nullable |
| `ModifiedBy` | int | Nullable |
| `ModifiedDate` | nvarchar(64) | Stored as text; nullable |
| `ModifiedDateTime` | smalldatetime | Defaults to `GETDATE()` |
| `SerialNo` | int | Nullable |
| `Source` | nvarchar(50) | Nullable |

---

#### `dbo.ActivityLog_ClassEnrollment`
Class enrollment change log — additions/drops per student per class.

| Column | Type | Notes |
|---|---|---|
| `LogID` | int IDENTITY | PK |
| `StudentID` / `ClassID` | int | Indexed; nullable |
| `Task` | nvarchar(255) | Nullable |
| `ModifiedBy` | int | Nullable |
| `ModifiedDate` | smalldatetime | Defaults to `GETDATE()`; indexed |
| `SerialNo` | int | Nullable |
| `Source` | nvarchar(50) | Nullable |

---

#### `dbo.ActivityLog_DataMining`
Execution log for data-mining jobs. Minimal — token and exit code per run.

| Column | Type | Notes |
|---|---|---|
| `LogID` | int IDENTITY | PK |
| `ActivityDateTime` | datetime2(0) | Defaults to `GETDATE()` |
| `ExecToken` | uniqueidentifier | Run identifier |
| `ExitCode` | tinyint | Job exit code |

---

#### `dbo.ActivityLog_General`
General-purpose person activity log with request URL tracking.

| Column | Type | Notes |
|---|---|---|
| `LogID` | int IDENTITY | PK |
| `PersonID` | int | Nullable |
| `RecordID` | nvarchar(50) | Loosely-referenced record; nullable |
| `Type` | nvarchar(50) | Nullable |
| `Note` / `Task` | nvarchar(1000) | Nullable |
| `SchoolCode` | varchar(50) | Nullable |
| `ModifiedBy` | int | Nullable |
| `ModifiedbyDatetime` | smalldatetime | Defaults to `GETDATE()` |
| `SerialNo` | int | Nullable |
| `Source` | nvarchar(50) | Nullable |
| `RequestURL` | varchar(2000) | Defaults to `'(none)'` |

---

#### `dbo.ActivityLog_Login`
Login event log — who logged in, when, and via which login type/source.

| Column | Type | Notes |
|---|---|---|
| `LogID` | int IDENTITY | PK |
| `PersonID` | int | Nullable |
| `LoginDateTime` | smalldatetime | Defaults to `GETDATE()` |
| `LoginType` | int | Nullable |
| `Source` | nvarchar(50) | Nullable |

---

#### `dbo.ActivityLog_MaintenanceManager`
Maintenance job activity log, scoped to a district and server.

| Column | Type | Notes |
|---|---|---|
| `LogID` | int IDENTITY | PK |
| `DistrictCode` | nvarchar(50) | Nullable |
| `DateTime` | smalldatetime | Nullable |
| `Type` | nvarchar(128) | Nullable |
| `Name` | nvarchar(256) | Nullable |
| `MaintenanceID` | int | Nullable |
| `Server` | nvarchar(50) | Nullable |
| `ModifiedDateTime` | smalldatetime | Defaults to `GETDATE()` |
| `Source` | nvarchar(50) | Nullable |

---

#### `dbo.ActivityLog_Medical`
Medical activity log with request URL. Note `Type`, `Note`, `ModifiedBy` are NOT NULL here (stricter than most logs). UTC timestamp.

| Column | Type | Notes |
|---|---|---|
| `LogID` | int IDENTITY | PK |
| `Type` | nvarchar(50) | Required |
| `Note` | nvarchar(1000) | Required |
| `ModifiedUTC` | datetime2(2) | Defaults to `GETUTCDATE()`; indexed |
| `ModifiedBy` | int | Required |
| `RequestURL` | varchar(2000) | Defaults to `'(none)'` |

---

#### `dbo.ActivityLog_Person`
Person field-change audit log — records old/new field data, address and family context. Heavily indexed (PersonID, AddressID, FamilyID, Field, Type).

| Column | Type | Notes |
|---|---|---|
| `LogID` | int IDENTITY | PK |
| `PersonID` | int | Indexed; nullable |
| `Type` | varchar(50) | Indexed; nullable |
| `Field` | varchar(50) | Field changed; indexed; nullable |
| `Data` | nvarchar(360) | New value; nullable |
| `AddressID` / `FamilyID` | int | Indexed; nullable |
| `Note` | varchar(128) | Nullable |
| `ModifiedBy` | int | Nullable |
| `ModifiedDate` | varchar(50) | Stored as text; nullable |
| `ModifiedByDateTime` | smalldatetime | Defaults to `GETDATE()` |
| `SerialNo` | int | Nullable |
| `Source` | nvarchar(50) | Nullable |
| `RequestURL` | varchar(2000) | Defaults to `'(none)'` |

---

#### `dbo.ActivityLog_SSGrades`
Skill-set grade change audit log — records field changed and from/to values per student/class/skill. Clustered on `ModifiedDateTime` (not `LogID`).

| Column | Type | Notes |
|---|---|---|
| `LogID` | int IDENTITY | PK (non-clustered) |
| `FieldModified` | nvarchar(50) | Nullable |
| `DataChangedFrom` / `DataChangedTo` | nvarchar(50) | Old/new value; nullable |
| `Task` | nvarchar(50) | Nullable |
| `StaffID` | int | Nullable |
| `ClassID` / `SkillID` / `StudentID` | int | Nullable |
| `ModifiedDateTime` | datetime | Defaults to `GETDATE()`; clustered index |
| `Source` | nvarchar(50) | Nullable |

---

#### `dbo` activity log tables — cross-reference summary

| Table | Scope | Notes |
|---|---|---|
| `ActivityLog` | General activity (student/family/class/assignment) | No FKs; loosely-referenced IDs |
| `ActivityLog_Acct` | Accounting activity (payments, charges) | No FKs |
| `ActivityLog_ClassEnrollment` | Class enrollment add/drop | No FKs |
| `ActivityLog_DataMining` | Data-mining job execution | Token + exit code |
| `ActivityLog_General` | General person activity + request URL | No FKs |
| `ActivityLog_Login` | Login events | No FKs |
| `ActivityLog_MaintenanceManager` | Maintenance jobs per district/server | No FKs |
| `ActivityLog_Medical` | Medical activity + request URL | Type/Note/ModifiedBy NOT NULL |
| `ActivityLog_Person` | Person field-change audit (old/new) | No FKs; heavily indexed |
| `ActivityLog_SSGrades` | Skill-set grade change audit | Clustered on ModifiedDateTime |

---

### `dbo` general tables

Additional core `dbo` tables documented from provided DDL (beyond the accounting and activity-log groups above).

#### `dbo.Address`
Address record, referenced by `Person` and others. Temporal table. A trigger keeps related modified-dates and FACTS sync flags in sync on insert/update.

| Column | Type | Notes |
|---|---|---|
| `AddressID` | int IDENTITY | PK |
| `Address1` / `Address2` / `City` / `State` / `ZIP` / `Country` | nvarchar(255) | Nullable |
| `Greeting1`…`Greeting5` | nvarchar(128) | Salutation lines; nullable |
| `NewStudentInquiryID` | int | Nullable |
| `AddressTypeDescriptorId` | uniqueidentifier | Nullable |
| `StateAbbreviationDescriptorId` | uniqueidentifier | Nullable |
| `ModifiedBy` / `ModifiedDate` | int / smalldatetime | Nullable |
| `CreatedOnUTC` | datetime2(2) | Defaults to `SYSUTCDATETIME()` |
| `ModifiedOnUTC` / `ModifiedOnUTCmax` | datetime2(2) | Temporal ROW START/END |

**Trigger** `tr_Address_InsertUpdate` (INSERT, UPDATE): sets the address's own `ModifiedDate`, then propagates `ModifiedDate` to all `Person` rows on this address, and sets the FACTS sync flags `FamilyConfig.FactsUpdateState = 1` and `facts.FamilyMapping.UpdateState = 1` for affected families. **Editing an address cascades modified-dates and triggers FACTS re-sync** — account for this when touching address data.

---

#### `dbo.AdmissionsFamily`
Admissions tracking record per family — interview, open houses, financial aid, event-participation flags (`EP1`–`EP10`), 10 generic note slots, admission codes, and priority. Surrogate PK `AutoNum`.

| Column | Type | Notes |
|---|---|---|
| `AutoNum` | int IDENTITY | PK |
| `FamilyID` | int | Required |
| `ContactDate` / `InterviewDate` | smalldatetime | Nullable |
| `InterviewStaff` | nvarchar(50) | Nullable |
| `InterviewComments` / `FamilyNote` | nvarchar(max) | Nullable |
| `OpenHouse1`…`OpenHouse4` | nvarchar(50) | Nullable |
| `FinancialAid` | bit | Nullable |
| `ReferredBy` / `ReferredByDetails` | nvarchar | Nullable |
| `EP1`…`EP10` | bit | Event-participation flags; nullable |
| `Note1`…`Note10` | nvarchar(50) | Generic note slots; nullable |
| `AdmissionCodes` / `Priority` / `PriorityUD` | nvarchar(50) | Nullable |
| `ModifiedBy` / `ModifiedDate` | int / smalldatetime | Nullable |

---

#### `dbo.AdmissionsGoals`
Admissions funnel targets per grade level per year — inquiries, visits, applications, offers, capacity. Temporal table. PK is composite `(YearID, GradeLevelID)`.

| Column | Type | Notes |
|---|---|---|
| `YearID` | int | PK (composite); FK → `dbo.SchoolYear` |
| `GradeLevelID` | int | PK (composite); FK → `dbo.GradeLevels` (CASCADE) |
| `Returns` / `Inquiries` / `Visits` | int | Funnel counts; nullable |
| `AppStarted` / `AppSubmitted` | int | Nullable |
| `OfferSent` / `OfferAccepted` / `OfferFinished` | int | Nullable |
| `Capacity` | int | Nullable |
| `CreatedOnUTC` | datetime2(2) | Defaults to `SYSUTCDATETIME()` |
| `ModifiedOnUTC` / `ModifiedOnUTCmax` | datetime2(2) | Temporal ROW START/END |

---

#### `dbo.AdmissionsStatistics`
Point-in-time admissions funnel snapshot per school/year/date/grade — split into returning-student and new-student funnel stages. Temporal table. PK is composite `(SchoolCode, YearID, AsOfDate, GradeLevel)`.

| Column | Type | Notes |
|---|---|---|
| `SchoolCode` | varchar(50) | PK (composite); FK → `dbo.ConfigSchool` |
| `YearID` | int | PK (composite); FK → `dbo.SchoolYear` |
| `AsOfDate` | smalldatetime | PK (composite); snapshot date |
| `GradeLevel` | nvarchar(50) | PK (composite) |
| `Returning_Open` / `_Withdrawn` / `_Rejected` / `_Blocked` / `_Finished` | int | Returning-student funnel; nullable |
| `New_Inquiries` / `_Visits` / `_AppSubmitted` / `_AppWithdrawn` / `_AppRejected` / `_AppWaitList` / `_AppOfferSent` / `_OfferDeclined` / `_OfferAccepted` / `_OfferFinished` | int | New-student funnel; nullable |
| `Capacity` | int | Nullable |
| `CreatedOnUTC` | datetime2(2) | Defaults to `SYSUTCDATETIME()` |
| `ModifiedOnUTC` / `ModifiedOnUTCmax` | datetime2(2) | Temporal ROW START/END |

---

#### `dbo.AdvisingNotes`
Free-text advising notes per student, with created/modified tracking.

| Column | Type | Notes |
|---|---|---|
| `NoteID` | int IDENTITY | PK |
| `Note` | nvarchar(max) | Nullable |
| `Date` | datetime | Nullable |
| `StudentID` | int | Nullable |
| `CreatedBy` | int | Defaults to 0 |
| `CreatedDate` | smalldatetime | Defaults to `GETUTCDATE()` |
| `ModifiedBy` / `ModifiedDate` | int / smalldatetime | Nullable |

---

#### `dbo.AnnouncementsDistrict`
District/school announcements shown in the portal, with date window, icon, public flag, and HTML body.

| Column | Type | Notes |
|---|---|---|
| `AnnouncementID` | int IDENTITY | PK |
| `SchoolCode` | varchar(50) | Indexed; nullable |
| `Title` | nvarchar(255) | Nullable |
| `Message` / `HTML` | nvarchar(max) | Body text / HTML; nullable |
| `BeginDate` / `EndDate` | smalldatetime | Display window; indexed; nullable |
| `GlobalItem` | bit | District-wide flag; nullable |
| `Public` | bit | Public visibility; nullable |
| `Icon_PictureID` | int | Nullable |
| `ModifiedBy` / `ModifiedDate` | int / smalldatetime | Nullable |

---

#### `dbo` general tables — cross-reference summary

| Table | Scope | Key FK targets |
|---|---|---|
| `Address` | Address record (with FACTS-sync trigger) | — |
| `AdmissionsFamily` | Admissions tracking per family | — |
| `AdmissionsGoals` | Admissions funnel targets per grade/year | `dbo.SchoolYear`, `dbo.GradeLevels` |
| `AdmissionsStatistics` | Admissions funnel snapshot per school/year/date | `dbo.ConfigSchool`, `dbo.SchoolYear` |
| `AdvisingNotes` | Advising notes per student | — |
| `AnnouncementsDistrict` | Portal announcements (district) | — |
| `AnnouncementsStaff` | Portal announcements (staff/class) | — |
| `ArchiveDocuments` | Uploaded document archive | — |
| `AutoEmailConfig` | Auto-email rule/template config | — |
| `AutoEmailSent` | Auto-email send log | — |

#### `dbo.AnnouncementsStaff`
Staff/class-scoped portal announcements with date window. Parallel to `AnnouncementsDistrict` but targeted at a staff member or class.

| Column | Type | Notes |
|---|---|---|
| `AnnouncementID` | int IDENTITY | PK |
| `StaffID` | int | Indexed; defaults to 0 |
| `ClassID` | int | Indexed; defaults to 0 |
| `Title` | nvarchar(128) | Nullable |
| `Message` | nvarchar(max) | Nullable |
| `BeginDate` / `EndDate` | smalldatetime | Display window; indexed; nullable |
| `GlobalItem` | bit | Nullable |
| `Icon_PictureID` | int | Nullable |
| `ModifiedBy` / `ModifiedDate` | int / smalldatetime | Nullable |

---

#### `dbo.ArchiveDocuments`
Archive of uploaded documents tied to a student/staff/parent/family, with type, year/term, description, and public/private comment fields.

| Column | Type | Notes |
|---|---|---|
| `ArchiveID` | int IDENTITY | PK |
| `StudentID` / `StaffID` / `ParentID` / `FamilyID` / `OwnerID` | int | Loosely-referenced; `StudentID` indexed; nullable |
| `Type` | int | Document type; nullable |
| `YearID` / `TermID` | int | Nullable |
| `Description` | nvarchar(500) | Nullable |
| `Comment` / `CommentPublic` | nvarchar(500) | Private/public comments; nullable |
| `FileName` | nvarchar(128) | Stored file name; nullable |
| `MakePublic` | bit | Nullable |
| `DateAdded` / `Date1` / `Date2` | smalldatetime | Nullable |
| `schoolcode` | varchar(64) | Nullable |

---

### `dbo` attendance tables

The attendance subsystem. `dbo.Attendance` holds raw period/class attendance; `dbo.AttendanceDaySummary` and `dbo.AttendanceClassSummary` hold derived aggregates used by report cards. **`AttendanceDaySummary` is the table `GetDayAttendance.cfm` reads from** (see Core FACTS tables).

#### `dbo.Attendance`
Raw attendance record — one row per student × class × date × column (period). Temporal table. **A trigger recalculates day attendance on every change.**

| Column | Type | Notes |
|---|---|---|
| `AutoNumber` | int IDENTITY | Surrogate (not the PK) |
| `AttendanceDate` | smalldatetime | PK (composite) |
| `Column` | smallint | PK (composite); period/column index |
| `StudentID` | int | PK (composite); indexed |
| `ClassID` | int | PK (composite); indexed |
| `AttendanceCode` | nvarchar(50) | The code applied; nullable |
| `LastCode` | nvarchar(50) | Previous code; nullable |
| `Comment` | nvarchar(50) | Nullable |
| `Updated` / `Notified` | bit | Default 0 |
| `SetByAdmin` | bit | Default 0 |
| `EducationalEnvironmentDescriptorId` | uniqueidentifier | Nullable |
| `ModifiedBy` / `ModifiedDate` | int / smalldatetime | Nullable |
| `CreatedOnUTC` | datetime2(2) | Defaults to `SYSUTCDATETIME()` |
| `ModifiedOnUTC` / `ModifiedOnUTCmax` | datetime2(2) | Temporal ROW START/END |

**Trigger** `tr_CreateDayAttendance` (INSERT, UPDATE, DELETE): for each affected student/date (where the class is not flagged `NoDayAttendance`), looks up the school code and executes `Attendance_CreateDayAttendance_Manual` to rebuild `dbo.AttendanceDaySummary`. **Note**: a `ClassID = 0` row is a special sentinel used to force a day-attendance recalculation. **Editing raw attendance cascades into day-summary recalculation** — account for this when bulk-updating.

---

#### `dbo.AttendanceClassSummary`
Per-student class attendance aggregate for a term — excused/unexcused absences and tardies, and present count. One row per student × class × term.

| Column | Type | Notes |
|---|---|---|
| `StudentID` | int | PK (composite) |
| `ClassID` | int | PK (composite) |
| `TermID` | int | PK (composite) |
| `AE` | real | Absences excused; default 0 |
| `AU` | real | Absences unexcused; default 0 |
| `TE` | real | Tardies excused; default 0 |
| `TU` | real | Tardies unexcused; default 0 |
| `P` | int | Present count; default 0 |
| `ModifiedBy` / `ModifiedDate` | int / smalldatetime | Nullable |

---

#### `dbo.AttendanceDaySummary`
Per-student per-day attendance aggregate — the day-level rollup driven by the `tr_CreateDayAttendance` trigger. **This is the source for day-attendance values in report cards** (`GetDayAttendance.cfm`). One row per student × date.

| Column | Type | Notes |
|---|---|---|
| `StudentID` | int | PK (composite) |
| `Date` | smalldatetime | PK (composite) |
| `Absent` | bit | Full-day absence; nullable |
| `AbsentHalf` | bit | Half-day absence; nullable |
| `Tardy` | bit | Nullable |
| `Present` | bit | Nullable |
| `Excused` | bit | Nullable |
| `SchoolCode` | varchar(50) | Nullable |

---

#### `dbo.AttendanceCodes`
Attendance code definitions per school — name, weight, and classification flags (absent/tardy/excused, faculty/admin). Temporal table. PK is composite `(AttendanceCode, SchoolCode)`.

| Column | Type | Notes |
|---|---|---|
| `AttendanceCode` | nvarchar(5) | PK (composite); indexed |
| `SchoolCode` | varchar(50) | PK (composite); indexed |
| `Name` | nvarchar(100) | Indexed; nullable |
| `Weight` | real | Defaults to 1 |
| `Absent` / `Tardy` / `Excused` | bit | Classification; default 0 |
| `Faculty` / `Administrator` | bit | Who can set; default 0 |
| `LockChangesIfUsedByAdmin` | bit | Default 0 |
| `AttendanceEventCategoryDescriptorId` | uniqueidentifier | Nullable |
| `CreatedOnUTC` | datetime2(2) | Defaults to `SYSUTCDATETIME()` |
| `ModifiedOnUTC` / `ModifiedOnUTCmax` | datetime2(2) | Temporal ROW START/END |

---

#### `dbo.AttendanceNotes`
Free-text attendance notes per student per date. Surrogate PK `AutoNum`.

| Column | Type | Notes |
|---|---|---|
| `AutoNum` | int IDENTITY | PK |
| `StudentID` | int | Nullable |
| `AttendanceNote` | nvarchar(255) | Nullable |
| `AttendanceDate` | datetime | Nullable |

---

#### `dbo.AttendanceSeatingChart`
Seating chart positions for attendance-taking — row/column per student per class.

| Column | Type | Notes |
|---|---|---|
| `ClassID` | int | PK (composite); unique with `StudentID` |
| `StudentID` | int | PK (composite) |
| `Row` | int | PK (composite) |
| `Col` | int | PK (composite) |

---

#### `dbo` attendance tables — cross-reference summary

| Table | Scope | Notes |
|---|---|---|
| `Attendance` | Raw period/class attendance | Temporal; `tr_CreateDayAttendance` rebuilds day summary |
| `AttendanceClassSummary` | Per-student class term aggregate (AE/AU/TE/TU/P) | — |
| `AttendanceDaySummary` | Per-student day aggregate | Source for `GetDayAttendance.cfm` |
| `AttendanceCodes` | Code definitions per school | Temporal; PK `(AttendanceCode, SchoolCode)` |
| `AttendanceNotes` | Free-text notes per student/date | — |
| `AttendanceSeatingChart` | Seating positions per class | — |

---

### `dbo` auto-email tables

#### `dbo.AutoEmailConfig`
Configuration for automated email rules — template, trigger type/fields, recipient flags, and HTML body. Drives the auto-email engine.

| Column | Type | Notes |
|---|---|---|
| `AutoMessageID` | int IDENTITY | PK |
| `AutoEmailConfigID` | int | Secondary identifier; defaults to 0 |
| `HTML` | nvarchar(max) | Email body; nullable |
| `Subject` | nvarchar(512) | Nullable |
| `TemplateName` | nvarchar(128) | Nullable |
| `TemplateTypeID` | smallint | Nullable |
| `BaseType` | nvarchar(50) | Indexed; nullable |
| `SourceID` | int | Nullable |
| `TriggerType` | nvarchar(50) | Indexed; nullable |
| `TriggerFieldID1` / `TriggerFieldID2` / `TriggerFieldID3` | int | Trigger field references; nullable |
| `Active` / `Resend` | bit | Nullable |
| `NotifySchool` / `NotifyPerson1` / `NotifyPerson2` / `NotifyPerson3` | bit | Recipient flags; nullable |
| `SchoolEmail` | nvarchar(256) | Nullable |
| `SchoolCode` | varchar(50) | Nullable |
| `DistrictWide` | bit | Nullable |
| `ConfigSchoolID` | smallint | Nullable |

---

#### `dbo.AutoEmailSent`
Log of auto-emails already sent, keyed by message + entity + table, to prevent duplicate sends. Clustered on `(AutoMessageID, EntityID)`. No PK declared.

| Column | Type | Notes |
|---|---|---|
| `AutoMessageID` | int | Part of clustered index |
| `EntityID` | int | The entity emailed about |
| `TableID` | int | Which source table the entity is from |
| `SchoolCode` | varchar(50) | Nullable |
| `Note` | nvarchar(50) | Nullable |

---

#### `dbo.AutoReport`
A wide generic staging/scratch table used by the auto-report engine to hold report row data. Has 199 `Field1`–`Field199` columns (mostly nvarchar(128); the first nine are nvarchar(512)), 5 `Text1`–`Text5` nvarchar(max) columns, an `ARUser` owner column, and `IDList`. Surrogate PK `AutoNum`. The first several `Field*` columns are indexed (with `DATA_COMPRESSION = ROW`).

This is a denormalized work table — column meanings depend on the report populating it, so there is no fixed schema beyond `ARUser` (the report user) and `AutoNum`. Treat it as report-engine scratch space, not a relational data source.

| Column | Type | Notes |
|---|---|---|
| `AutoNum` | int IDENTITY | PK |
| `ARUser` | nvarchar(32) | Report user/owner; indexed |
| `IDList` | nvarchar(max) | Comma-separated ID list; nullable |
| `Field1`–`Field9` | nvarchar(512) | Generic columns; `Field1`–`Field4` indexed |
| `Field10`–`Field199` | nvarchar(128) | Generic columns; `Field11` indexed |
| `Text1`–`Text5` | nvarchar(max) | Large text columns; nullable |

---

### `dbo` calendar / messaging tables

#### `dbo.Bank`
Bank account record for accounting — contact info, GL cash account, QuickBooks mapping, and PayNow/AMPP flags.

| Column | Type | Notes |
|---|---|---|
| `BankID` | int IDENTITY | PK |
| `BankName` | nvarchar(128) | Nullable |
| `AccountName` | nvarchar(128) | Nullable |
| `Contact` / `Street` / `City` / `State` / `Zip` / `Phone` | nvarchar(50) | Nullable |
| `SchoolCode` | varchar(50) | Nullable |
| `GLCashAccount` | nvarchar(50) | Nullable |
| `PayNow` | bit | Nullable |
| `AMPP` | bit | Defaults to 0 |
| `QB_AccountId` / `QB_Worksheet` / `QB_BankName` | nvarchar | QuickBooks integration; nullable |

---

#### `dbo.BroadcastMessage`
System broadcast message shown to users for a date window.

| Column | Type | Notes |
|---|---|---|
| `MessageID` | int | PK |
| `MessageText` | varchar(max) | Nullable |
| `MessageURL` | varchar(256) | Nullable |
| `StartDate` / `EndDate` | smalldatetime | Display window; nullable |
| `MessageType` | int | Nullable |

---

#### `dbo.BroadcastMessageStaff`
Per-staff read-state for a broadcast message. PK is composite `(MessageID, StaffID)`.

| Column | Type | Notes |
|---|---|---|
| `MessageID` | int | PK (composite) |
| `StaffID` | int | PK (composite) |
| `MessageRead` | bit | Nullable |
| `MessageReadDate` | smalldatetime | Nullable |

---

#### `dbo.CalendarConfig`
Master calendar event definition — date/time window (local + UTC), recurrence, location, audience, volunteers, styling, and meeting/event metadata. The header for `dbo.CalendarDates`.

| Column | Type | Notes |
|---|---|---|
| `CalendarID` | int IDENTITY | PK |
| `Title` | nvarchar(128) | Nullable |
| `Message` | nvarchar(max) | Nullable |
| `BeginDate` / `EndDate` / `BeginTime` / `EndTime` | datetime | Local; nullable |
| `BeginDateUTC` / `EndDateUTC` | datetime2(2) | UTC; nullable |
| `AllDay` | bit | Defaults to 0 |
| `Repeat` / `RecurrencePattern` / `RecurrenceHash` | mixed | Recurrence config; nullable |
| `EventType` / `EventGroup` | nvarchar | Nullable |
| `RoomID` | int | Nullable |
| `ResponsiblePerson` / `ResponsiblePersonPhone` / `ResponsiblePersonEmail` | nvarchar | Nullable |
| `VolunteersNeeded` | bit | Required |
| `VolunteersMessage` | nvarchar(max) | Nullable |
| `SetupRequired` | bit | Nullable |
| `AudienceDistrict` / `AudienceSchool` / `Public` | bit | Visibility; nullable |
| `MQ_Address` / `MQ_City` / `MQ_State` / `MQ_Zipcode` / `MQ_Country` | nvarchar(50) | Map/location; nullable |
| `URL` | nvarchar(128) | Nullable |
| `Image_PictureID` / `Icon_PictureID` | int | Nullable |
| `BGColor` / `TextColor` | nvarchar(50) | Styling; nullable |
| `SchoolCode` | varchar(50) | Nullable |

---

#### `dbo.CalendarDates`
Specific occurrence dates for a calendar event (expands recurrence). PK is composite `(CalendarID, Date)`.

| Column | Type | Notes |
|---|---|---|
| `CalendarID` | int | PK (composite) |
| `Date` | smalldatetime | PK (composite) |
| `Cancel` | bit | Cancelled occurrence flag; nullable |

---

#### `dbo.CalendarClassOccasion`
Class calendar occasion (assignment due date, event, etc.) — title, date range, message, icon, and optional Moodle link. The header for `dbo.CalendarClassOccasionClass`.

| Column | Type | Notes |
|---|---|---|
| `OccasionId` | int IDENTITY | PK |
| `OccasionType` | int | Required |
| `Title` | nvarchar(128) | Nullable |
| `BeginDt` | smalldatetime | Required |
| `EndDt` | smalldatetime | Nullable |
| `Message` / `DataString` | nvarchar(max) | Nullable |
| `IconId` | int | Nullable |
| `MoodleID` | int | Nullable |
| `CreatedBy` / `UpdatedBy` | int | Nullable |
| `CreatedDt` / `UpdatedDt` | smalldatetime | Nullable |

---

#### `dbo.CalendarClassOccasionClass`
Links a class calendar occasion to the classes it applies to. CASCADE deletes from `CalendarClassOccasion`. PK is composite `(OccasionId, ClassID)`.

| Column | Type | Notes |
|---|---|---|
| `OccasionId` | int | PK (composite); FK → `dbo.CalendarClassOccasion` (CASCADE) |
| `ClassID` | int | PK (composite) |
| `ExternalId` | int | Nullable |

---

#### `dbo.CalendarDistrict`
District/school calendar events (single-date) shown in the portal.

| Column | Type | Notes |
|---|---|---|
| `EventID` | int IDENTITY | PK |
| `Title` | nvarchar(255) | Nullable |
| `EventDate` | smalldatetime | Nullable |
| `Message` | nvarchar(max) | Nullable |
| `SchoolCode` | varchar(50) | Nullable |
| `GlobalItem` | bit | District-wide flag; nullable |
| `ModifiedBy` / `ModifiedDate` | int / smalldatetime | Nullable |

---

#### `dbo.CalendarGroup`
Event type / subgroup lookup for calendar categorization, scoped to a school. Surrogate PK `AutoNumber`.

| Column | Type | Notes |
|---|---|---|
| `AutoNumber` | int IDENTITY | PK |
| `EventType` | nvarchar(50) | Nullable |
| `SubGroup` | nvarchar(50) | Nullable |
| `SchoolCode` | varchar(50) | Nullable |

---

#### `dbo.CalendarMembers`
Members (audience) of a `CalendarConfig` event, by type. PK is composite `(CalendarID, Type, ID)`.

| Column | Type | Notes |
|---|---|---|
| `CalendarID` | int | PK (composite); references `dbo.CalendarConfig` |
| `Type` | nvarchar(50) | PK (composite); member type |
| `ID` | int | PK (composite); member identifier |
| `PersonID` | int | Nullable |
| `_ID` | int | Secondary identifier; nullable |

---

#### `dbo.CalendarSchoolOccasion`
Newer school calendar occasion model — full event definition (date/time, recurrence, location, volunteers, styling, website posting) with UTC audit columns. Replaces the older `CalendarConfig`/`CalendarDistrict` model. Header for `CalendarOccasionDate` and `CalendarOccasionMember`.

| Column | Type | Notes |
|---|---|---|
| `OccasionId` | int IDENTITY | PK |
| `OccasionType` | smallint | Required |
| `Title` | nvarchar(128) | Nullable |
| `BeginDateTime` / `EndDateTime` | datetime2(0) | Required |
| `AllDay` | bit | Defaults to 0 |
| `Repeat` | nvarchar(24) | Recurrence; nullable |
| `OccasionGroup` / `SubGroup` | nvarchar(128) | Categorization; nullable |
| `Message` / `VolunteersMessage` / `DataString` | nvarchar(4000) | Nullable |
| `RoomId` | int | FK → `dbo.Rooms`; nullable |
| `Address` / `City` / `State` / `Zipcode` / `Country` | nvarchar | Location; nullable |
| `ResponsiblePerson` / `ResponsiblePersonPhone` / `ResponsiblePersonEmail` | nvarchar | Nullable |
| `VolunteersNeeded` | bit | Defaults to 0 |
| `IconId` | int | Nullable |
| `PostToSchoolWebsite` | bit | Defaults to 0 |
| `CreatedBy` / `CreatedUTC` / `UpdatedBy` / `UpdatedUTC` | int / datetime2(2) | Audit; nullable |

---

#### `dbo.CalendarOccasionDate`
Occurrence dates for a `CalendarSchoolOccasion` (expands recurrence). CASCADE deletes from the occasion.

| Column | Type | Notes |
|---|---|---|
| `OccasionDateId` | int IDENTITY | PK |
| `OccasionId` | int | FK → `dbo.CalendarSchoolOccasion` (CASCADE) |
| `OccasionDate` | date | Required |
| `Cancel` | bit | Defaults to 0 |

---

#### `dbo.CalendarOccasionMember`
Audience members of a `CalendarSchoolOccasion`, by audience type. CASCADE deletes from the occasion.

| Column | Type | Notes |
|---|---|---|
| `OccasionMemberId` | int IDENTITY | PK |
| `OccasionId` | int | FK → `dbo.CalendarSchoolOccasion` (CASCADE) |
| `AudienceType` | smallint | Required |
| `MemberId` | int | Required |
| `CustomMemberType` | nvarchar(32) | Nullable |
| `ExternalId` | int | Nullable |

---

#### `dbo.CalendarStaff`
Staff/class-scoped single-date calendar events (older model). Parallel to `CalendarDistrict` but staff-targeted.

| Column | Type | Notes |
|---|---|---|
| `EventID` | int IDENTITY | PK |
| `Title` | nvarchar(50) | Nullable |
| `EventDate` | smalldatetime | Nullable |
| `StaffID` / `ClassID` | int | Nullable |
| `GlobalItem` | char(10) | Nullable |
| `Message` | nvarchar(max) | Nullable |
| `URL` | nvarchar(128) | Nullable |
| `Image_PictureID` / `Icon_PictureID` / `MoodleID` | int | Nullable |
| `ModifiedBy` / `ModifiedDate` | int / smalldatetime | Nullable |

---

#### `dbo` calendar / messaging tables — cross-reference summary

There are **two calendar event models** in `dbo`: the older `CalendarConfig`/`CalendarDates`/`CalendarDistrict`/`CalendarStaff` set, and the newer `CalendarSchoolOccasion` set (with `OccasionDate`/`OccasionMember`). The `CalendarClassOccasion` set is class-specific. Check which model a given report uses before joining.

| Table | Scope | Notes |
|---|---|---|
| `Bank` | Bank account for accounting | QuickBooks mapping |
| `BroadcastMessage` | System broadcast message | — |
| `BroadcastMessageStaff` | Per-staff read state | PK `(MessageID, StaffID)` |
| `CalendarConfig` | Master calendar event (older model) | Header for `CalendarDates` |
| `CalendarDates` | Event occurrence dates (older model) | PK `(CalendarID, Date)` |
| `CalendarMembers` | Audience of a `CalendarConfig` event | PK `(CalendarID, Type, ID)` |
| `CalendarClassOccasion` | Class calendar occasion | Header for occasion-class link |
| `CalendarClassOccasionClass` | Occasion ↔ class link | CASCADE from occasion |
| `CalendarSchoolOccasion` | School calendar occasion (newer model) | Header; FK → `dbo.Rooms` |
| `CalendarOccasionDate` | Occurrence dates (newer model) | CASCADE from occasion |
| `CalendarOccasionMember` | Audience (newer model) | CASCADE from occasion |
| `CalendarDistrict` | District/school single-date events | Older model |
| `CalendarStaff` | Staff/class single-date events | Older model |
| `CalendarGroup` | Event type/subgroup lookup | — |
| `AutoReport` | Auto-report engine scratch table | 199 Field + 5 Text columns |

---

### `dbo` legacy cash register tables

> **Important — two cash register systems exist.** These `dbo.CashRegister*` tables are the **legacy** point-of-sale system. The newer system lives in the **`cr` schema** (`cr.CashRegister`, `cr.Product`, `cr.CashRegisterSession`, etc., documented above). They are separate and not FK-linked. When working on register functionality, confirm which system the report/feature targets — newer work generally uses the `cr` schema.

#### `dbo.CashRegisterConfig`
Legacy register definition — tax rate/category, up to 5 labels, tuition flag, and accounting system link.

| Column | Type | Notes |
|---|---|---|
| `RegisterID` | int IDENTITY | PK |
| `Name` | varchar(50) | Nullable |
| `TaxRate` | real | Nullable |
| `TaxCategory` | int | Nullable |
| `SchoolCode` | varchar(50) | Nullable |
| `UserList` | varchar(50) | Nullable |
| `Label1`–`Label5` | varchar(50) | UI labels; nullable |
| `Tuition` | bit | Nullable |
| `AccountingSystemID` | int | Nullable |
| `ModifiedBy` / `ModifiedDate` | int / smalldatetime | Nullable |

---

#### `dbo.CashRegisterItems`
Legacy register sellable items — name, amount, tax, barcode, inventory link, position. PK is composite `(RegisterID, ItemNumber)`.

| Column | Type | Notes |
|---|---|---|
| `RegisterID` | int | PK (composite) |
| `ItemNumber` | int | PK (composite) |
| `ItemName` | varchar(255) | Nullable |
| `ItemAmount` | decimal(10,4) | Nullable |
| `ItemAccountingCategory` | int | Nullable |
| `ItemTaxable` | bit | Nullable |
| `ItemBarCode` | varchar(255) | Nullable |
| `InventoryID` / `DLID` / `ItemPosition` | int | Nullable |
| `ModifiedBy` / `ModifiedDate` | int / smalldatetime | Nullable |

---

#### `dbo.CashRegisterUsers`
Authorizes staff to use a legacy register. PK is composite `(StaffID, RegisterID)`.

| Column | Type | Notes |
|---|---|---|
| `StaffID` | int | PK (composite) |
| `RegisterID` | int | PK (composite) |

---

#### `dbo.CashRegisterTransactions`
Legacy register transaction header — per student/staff/date. Note `CashRegisterID` here is a string, not the `CashRegisterConfig.RegisterID` int.

| Column | Type | Notes |
|---|---|---|
| `TransactionID` | int IDENTITY | PK |
| `CashRegisterID` | varchar(50) | String register identifier; nullable |
| `Date` | datetime | Nullable |
| `StudentID` / `StaffID` | int | Nullable |
| `SchoolCode` | varchar(50) | Nullable |
| `ModifiedBy` / `ModifiedDate` | int / smalldatetime | Nullable |

---

#### `dbo.CashRegisterBalance`
Legacy register daily balance/reconciliation — drawer balances, charges, payments, transaction count. PK is composite `(CashRegisterID, Date, SchoolCode)`. `CashRegisterID` is a string here.

| Column | Type | Notes |
|---|---|---|
| `CashRegisterID` | nvarchar(50) | PK (composite); string identifier |
| `Date` | datetime | PK (composite) |
| `SchoolCode` | varchar(50) | PK (composite) |
| `BeginningDrawerBalance` / `EndingDrawerBalance` | money | Nullable |
| `Charges` / `Payments` / `Balance` | money | Nullable |
| `Transactions` | int | Transaction count; nullable |
| `StaffID` | int | Nullable |

---

#### `dbo` legacy cash register tables — cross-reference summary

| Table | Scope | Notes |
|---|---|---|
| `CashRegisterConfig` | Legacy register definition | Newer equivalent: `cr.CashRegister` |
| `CashRegisterItems` | Legacy register items | Newer equivalent: `cr.Product` |
| `CashRegisterUsers` | Legacy register staff access | Newer equivalent: `cr.CashRegisterStaffMM` |
| `CashRegisterTransactions` | Legacy transaction header | String `CashRegisterID` |
| `CashRegisterBalance` | Legacy daily balance/reconciliation | String `CashRegisterID`; newer: `cr.CashRegisterSession` |

---

### `dbo` charges tables

The charges/billing subsystem. `dbo.Charges` is the central transaction table; the others handle recurring templates, archival, and error-checking.

#### `dbo.Charges`
The core charge/fee transaction table — one row per charge posted to a family/student. Heavily indexed (family, student, fiscal year, accounting system, date). Note the duplicate-looking column pairs: `_Amount`/`Amount` (real vs decimal) and `_ClearedAmount`/`ClearedAmount`, plus shadow columns `_StudentID`/`_FamilyID`/`_SchoolCode` — the underscore-prefixed and `decimal` variants reflect a data-type migration; **check which column a given report uses** (the `decimal` `Amount`/`ClearedAmount` are the current ones).

| Column | Type | Notes |
|---|---|---|
| `ChargeID` | int IDENTITY | PK (non-clustered) |
| `Amount` | decimal(10,2) | Current amount column |
| `_Amount` | real | Legacy amount; defaults to 0 |
| `ClearedAmount` | decimal(10,2) | Current cleared amount |
| `_ClearedAmount` | real | Legacy cleared amount |
| `Date` / `DueDate` / `Posted` | datetime/smalldatetime | Nullable |
| `Description` / `Memo` | nvarchar(255) | Nullable |
| `Type` | nvarchar(50) | Charge type; nullable |
| `Journal` | nvarchar(50) | Nullable |
| `CatID` | int | Accounting category (→ `dbo.AcctCat`); defaults to 0 |
| `FamilyID` / `StudentID` | int | Indexed; default 0 |
| `_FamilyID` / `_StudentID` / `SID` / `FID` | int | Shadow/legacy ID columns; nullable |
| `SchoolCode` / `_SchoolCode` | varchar/nvarchar(50) | Indexed; nullable |
| `YearID` / `FiscalYearID` | int | Indexed; nullable |
| `AccountingSystemID` | int | Indexed; nullable |
| `InvoiceID` / `PaymentID` / `TransactionID` / `PostedID` | int | Cross-references; nullable |
| `CR_QTY` / `CR_Amount` / `CR_InventoryID` | int/real | Cash-register charge detail; nullable |
| `ClassID` | int | Nullable |
| `Lock` / `ErrorCheck` / `QBPosted` / `Balance_Transfer` | bit | Status flags; nullable |
| `SessionID` | varchar(50) | Nullable |
| `QB_InvoiceID` | nvarchar(50) | QuickBooks invoice; nullable |
| `SyncId` | int | Nullable |

---

#### `dbo.Charges_Recurring`
Template for recurring charges — generates `Charges` rows on a schedule. Mirrors the core `Charges` columns minus the posting/clearing detail.

| Column | Type | Notes |
|---|---|---|
| `RecurringChargeID` | int IDENTITY | PK (non-clustered) |
| `Amount` | real | Nullable |
| `Date` / `DueDate` | datetime | Nullable |
| `Description` / `Memo` | nvarchar(255) | Nullable |
| `Type` | varchar(50) | Nullable |
| `CatID` | int | Accounting category; nullable |
| `FamilyID` / `StudentID` | int | Nullable |
| `SchoolCode` | varchar(50) | Nullable |
| `YearID` / `FiscalYearID` | int | Nullable |
| `AccountingSystemID` | int | Nullable |
| `TransactionID` / `ChargeID` | int | Cross-references; nullable |

---

#### `dbo.ChargesArchive`
Archival copy of deleted/historical charges. Same column shape as `dbo.Charges` (legacy `real`/`varchar` variants), plus an `ArchiveChargeID`. No PK declared — pure archive/audit storage.

| Column | Type | Notes |
|---|---|---|
| `ArchiveChargeID` | int | Archive identifier; nullable |
| `ChargeID` | int | Original charge ID; nullable |
| `Amount` / `ClearedAmount` / `CR_Amount` | real | Nullable |
| `Date` / `DueDate` | datetime | Nullable |
| `Description` / `Memo` | varchar(255) | Nullable |
| `Type` / `Journal` / `_SchoolCode` / `SchoolCode` | varchar(50) | Nullable |
| `CatID` / `FamilyID` / `StudentID` / `_FamilyID` / `_StudentID` / `SID` / `FID` | int | Nullable |
| `InvoiceID` / `PaymentID` / `TransactionID` / `PostedID` | int | Nullable |
| `YearID` / `FiscalYearID` / `AccountingSystemID` / `ClassID` | int | Nullable |
| `CR_QTY` / `CR_InventoryID` | int | Nullable |
| `Lock` / `ErrorCheck` | bit | Nullable |

---

#### `dbo.ChargesError`
Charges that failed validation during a batch posting run, with the proposed charge detail and a `Processed` flag.

| Column | Type | Notes |
|---|---|---|
| `ErrorCheckID` | int IDENTITY | PK |
| `ChargeDate` / `DueDate` | datetime | Nullable |
| `Description` / `AccountingType` / `Memo` | nvarchar(255) | Nullable |
| `ChargeType` | nvarchar(50) | Nullable |
| `FamilyID` / `StudentID` | int | Nullable |
| `SchoolCode` | varchar(50) | Nullable |
| `FiscalYearID` / `AccountingSystemID` | int | Nullable |
| `Amount` | decimal(19,4) | Nullable |
| `Processed` | bit | Required |
| `CR_QTY` / `CR_Amount` / `CR_InventoryID` | int/decimal | Cash-register detail; default 0 |

---

#### `dbo.ChargesErrorMM`
Links a charge to the error-check record(s) it triggered. CASCADE deletes from `dbo.Charges`. PK is composite `(ChargeID, ErrorCheckID)`.

| Column | Type | Notes |
|---|---|---|
| `ChargeID` | int | PK (composite); FK → `dbo.Charges` (CASCADE) |
| `ErrorCheckID` | int | PK (composite) |

---

#### `dbo` charges tables — cross-reference summary

| Table | Scope | Notes |
|---|---|---|
| `Charges` | Core charge/fee transaction | `Amount`/`ClearedAmount` (decimal) are current; underscore cols legacy |
| `Charges_Recurring` | Recurring charge template | Generates `Charges` rows |
| `ChargesArchive` | Archived/deleted charges | No PK; legacy column types |
| `ChargesError` | Failed-validation charges | `Processed` flag |
| `ChargesErrorMM` | Charge ↔ error-check link | CASCADE from `Charges` |

---

### `dbo` core class tables

#### `dbo.Classes`
**One of the most important tables in the system.** A class is a section of a course for a year — the central entity that gradebook, attendance, scheduling, and report cards all hang off. Referenced by FK from many `aca` and `crse` tables. Temporal table. Has 80+ columns spanning scheduling, gradebook config, standards-based grading config, and LMS integration.

Key columns by group:

| Column group | Type | Notes |
|---|---|---|
| `ClassID` | int IDENTITY | PK (non-clustered); clustered index is `(ClassID, YearID, CourseID, StaffID)` |
| `CourseID` | int | The course this class is a section of (→ `dbo.Courses`); indexed |
| `Name` / `Section` | nvarchar | Class name and section |
| `YearID` | int | School year; indexed |
| `StaffID` / `AltStaffID` / `AidID` | int | Primary teacher / alternate / aide; indexed |
| `RoomID` / `RequiredRoom` | smallint/int | Room assignment |
| `Capacity` / `MaxSize` | smallint/int | Enrollment limits |
| `Pattern` / `DurationInMinutes` | int | Scheduling; indexed |
| `Term1`–`Term6` / `Terms` | bit/smallint | Which terms the class meets |
| `Homeroom` | bit | Homeroom flag |
| `LetterGrade` | bit | Uses letter grades |
| `NoDayAttendance` | bit | **If set, `tr_CreateDayAttendance` skips this class** (see `dbo.Attendance`) |
| `Comment1`–`Comment6` | nvarchar(max) | Per-term class comments |
| `GbkGradeMethod` / `GbkStudentSort` / `GbkAssignmentSort` / `GbkDecimalPlaces` / `GbkTimeFrame` / `GbkDefaultView` | mixed | Gradebook config |
| `GbkIncompleteis0` / `GbkAutoEmailFail` / `GbkWebProgressReport` / `GbkShowPointsEarned` / `GbkCapCategory` / `GbkCapTerm` / `GbkShowCurve` | bit | Gradebook flags |
| `AllowStandardGrading` / `EnableStandardTagging` / `IsStandardsBasedCalculation` | bit | Standards-based grading toggles |
| `StandardMaxGrade` / `StandardMasteryGradeMinVal0`–`2` / `DefaultAssignmentMaxPoints` | decimal(9,4) | SBG thresholds |
| `GbkStandardCalculation` / `GbkStandardCalculationRecent` / `GbkStandardCalculationDecayRate` / `StandardAssignmentGradeFlowType` | int/decimal | SBG calculation config |
| `WebProgressReportStyle` / `PWTeacher` / `PWHomework` / `PWLessonPlan` | nvarchar | Portal/progress-report config |
| `SeatingChartColumn` / `SeatingChartRow` / `RoomOrientationMarker` | int/nvarchar | Seating chart layout |
| `Color` / `ColorText` | nvarchar | UI styling |
| `Team` / `GradeLevels` / `MaleFemale` | nvarchar | Grouping/filtering |
| `Closed` / `LockSchedule` / `LockEnrollment` / `LockRoom` | bit | Lock flags |
| `EnableMoodle` / `ClassLMS` / `GoogleCourseId` / `AllowStudentComment` / `AllowStudentPost` | mixed | LMS integration (`GoogleCourseId` unique when not null) |
| `TemplateID` / `LinkedClassID` / `LegacyClassID` | int/nvarchar | Cross-references |
| `Weight` | real | Class weight |
| `ModifiedBy` / `ModifiedDate` | int/smalldatetime | Audit |
| `CreatedOnUTC` / `ModifiedOnUTC` / `ModifiedOnUTCmax` | datetime2(2) | Temporal versioning |

**Triggers** (legacy referential-integrity enforcement, since some relationships aren't declared as FK constraints):
- `Classes_ITrig` (INSERT): rejects a class whose `CourseID` has no matching `dbo.Courses` row.
- `Classes_UTrig` (UPDATE): same `CourseID` check on update; also blocks changing `ClassID` if dependent `dbo.Roster` rows exist.
- `Classes_DTrig` (DELETE): blocks deleting a class that still has `dbo.Roster` rows (raises an error and rolls back).

**Practical note**: because of these triggers, you can't delete a class with enrolled students, and a class must always reference a valid course. The `NoDayAttendance` flag ties directly into the attendance day-summary trigger.

---

#### `dbo.ClassGradeCalculation`
Grade-weighting matrix per class — defines how term grades (`t1`–`t6`), exams (`e1`–`e3`), and finals roll up into semester (`s1`/`s2`/`s3`) and final (`f`) grades. One row per class (PK = `ClassID`). The column naming is `{scope}_{component}`: e.g. `s1_t1` = semester-1 weight for term 1, `f_e2` = final weight for exam 2, `f_s1` = final weight for semester 1.

| Column group | Type | Notes |
|---|---|---|
| `ClassID` | int | PK; default 0 |
| `s1_t1`–`s1_t6`, `s1_e1`–`s1_e3` | real | Semester 1: term and exam weights |
| `s2_t1`–`s2_t6`, `s2_e1`–`s2_e3` | real | Semester 2 weights |
| `s3_t1`–`s3_t6`, `s3_e1`–`s3_e3` | real | Semester 3 weights |
| `f_t1`–`f_t6`, `f_e1`–`f_e3`, `f_s1`–`f_s3` | real | Final grade weights (terms, exams, semesters) |
| `DecimalPlaces` | smallint | Output precision; default 0 |
| `ModifiedBy` / `ModifiedDate` | int/smalldatetime | Audit |

This table drives transcript and report-card grade calculation — relevant when a report's computed final grade doesn't match expectations.

---

#### `dbo.ClassGroupClasses`
Links classes into class groups. PK is composite `(GroupID, ClassID)`.

| Column | Type | Notes |
|---|---|---|
| `GroupID` | int | PK (composite); default 0 |
| `ClassID` | int | PK (composite); default 0 |
| `ModifiedBy` / `ModifiedDate` | int/smalldatetime | Nullable |

---

### `dbo` lookup tables

#### `dbo.Church`
Church directory record — name, address, contact, and pastor names. Used by faith-based schools.

| Column | Type | Notes |
|---|---|---|
| `ChurchID` | int IDENTITY | PK |
| `Church` | nvarchar(128) | Church name; nullable |
| `ChurchPhone` / `ChurchStreet` / `ChurchCity` / `ChurchState` / `ChurchZip` | nvarchar(50) | Nullable |
| `YouthPastor` / `SeniorPastor` | nvarchar(50) | Nullable |

---

#### `dbo.CitizenshipCodes`
Citizenship/conduct grade codes per school (e.g. behavior marks). `DisableHonors` flags codes that exclude a student from honor roll. Unique on `(CitizenshipCodeNumber, SchoolCode)`.

| Column | Type | Notes |
|---|---|---|
| `CitizenshipCodeId` | int IDENTITY | PK |
| `CitizenshipCodeNumber` | smallint | Code number; default 0; unique with `SchoolCode` |
| `SchoolCode` | varchar(50) | Required |
| `CodeAbbreviation` / `Description` | nvarchar(50) | Nullable |
| `DisableHonors` | bit | Excludes from honors; default 0 |
| `SortOrder` | smallint | Nullable |

---

#### `dbo` class/lookup tables — cross-reference summary

| Table | Scope | Key FK targets / notes |
|---|---|---|
| `Classes` | Class (section of a course) — central entity | `dbo.Courses` (trigger-enforced); 3 RI triggers |
| `ClassGradeCalculation` | Per-class grade-weighting matrix | `ClassID`; drives transcript/report-card calc |
| `ClassGroupClasses` | Class ↔ group link | PK `(GroupID, ClassID)` |
| `Church` | Church directory | — |
| `CitizenshipCodes` | Citizenship/conduct codes per school | `DisableHonors` flag |

---

### `dbo` config / class-group / conference tables

#### `dbo.ClassGroups`
A named group of classes for a year, scoped to a school, with division flags. Header for `dbo.ClassGroupClasses` and `dbo.ClassGroupStudents`.

| Column | Type | Notes |
|---|---|---|
| `GroupID` | int IDENTITY | PK |
| `GroupName` | nvarchar(50) | Nullable |
| `YearID` | int | Default 0 |
| `SchoolCode` | varchar(50) | Indexed; nullable |
| `TemplateID` | int | Nullable |
| `Preschool` / `Elementary` / `MiddleSchool` / `HighSchool` | bit | Division flags; nullable |
| `ModifiedBy` / `ModifiedDate` | int/smalldatetime | Nullable |

Note: `ClassGroupClasses` (group↔class) is documented under *core class tables*; `ClassGroupStudents` (group↔student) is below.

---

#### `dbo.ClassGroupStudents`
Links students to a class group. PK is composite `(GroupID, StudentID)`.

| Column | Type | Notes |
|---|---|---|
| `GroupID` | int | PK (composite) |
| `StudentID` | int | PK (composite) |

---

#### `dbo.ClassWebDocument`
Links a web document to a class for a date window. PK is composite `(DocumentID, ClassID)`.

| Column | Type | Notes |
|---|---|---|
| `DocumentID` | int | PK (composite) |
| `ClassID` | int | PK (composite) |
| `BeginDate` / `EndDate` | datetime | Display window; nullable |

---

#### `dbo.CommentCodes`
Report-card comment codes per school — numbered canned comments. Unique on `(CommentNumber, SchoolCode)`. Relevant to report-card comment rendering.

| Column | Type | Notes |
|---|---|---|
| `CommentCodeId` | int IDENTITY | PK |
| `CommentNumber` | smallint | Code number; default 0; unique with `SchoolCode` |
| `Comment` | nvarchar(128) | Comment text; nullable |
| `SchoolCode` | varchar(50) | Required |
| `ModifiedBy` / `ModifiedDate` | int/smalldatetime | Nullable |

---

#### `dbo.CommunityService`
Community service hours logged per student — hours, type, location, supervisor, verification.

| Column | Type | Notes |
|---|---|---|
| `CommunityServiceID` | int IDENTITY | PK (non-clustered) |
| `StudentID` | int | FK → `dbo.Person`; indexed |
| `Description` | nvarchar(255) | Nullable |
| `HoursWorked` | real | Default 0 |
| `Day` | datetime | Service date; nullable |
| `ServiceType` / `RequirementArea` | nvarchar(256) | Nullable |
| `Location` / `Supervisor` | nvarchar(75) | Nullable |
| `VerifiedBy` / `Note` | nvarchar(255) | Nullable |
| `CreatedBy` / `ModifiedBy` / `ModifiedDate` | int/smalldatetime | Audit |

---

#### `dbo.Conference`
Parent/teacher conference record per student — reason/problem checkboxes (with custom labels), narrative fields, and status.

| Column | Type | Notes |
|---|---|---|
| `ConferenceID` | int IDENTITY | PK (non-clustered) |
| `StudentID` | int | Default 0 |
| `StaffID` | int | Nullable |
| `Date` | datetime | Nullable |
| `Subject` | nvarchar(128) | Nullable |
| `Reason` / `Problem` / `Recommendation` / `Parent` | nvarchar(max) | Narrative fields; nullable |
| `Reason1`–`Reason3` / `Problem1`–`Problem10` | bit | Checkbox flags; nullable |
| `Problem1Label`–`Problem10Label` | nvarchar(50) | Custom checkbox labels; nullable |
| `Location` / `Status` | int | Nullable |
| `ModifiedBy` / `ModifiedDate` | int/smalldatetime | Nullable |

---

#### `dbo.ConfigDistrict`
**District-level configuration** — the district counterpart to `dbo.ConfigSchool`. PK is `DistrictCode` (nvarchar). Holds district identity, portal styling/policy, password policy, timezone, library policy defaults, LMS, and overlay (data-copy) metadata. Referenced in the skill's Core FACTS tables as district settings.

Key columns by group:

| Column group | Type | Notes |
|---|---|---|
| `DistrictCode` | nvarchar(16) | PK |
| `DistrictName` | nvarchar(100) | Required |
| `Address` / `City` / `State` / `Zip` / `Phone` / `Fax` / `Web` / `Email` / `BillTo` | nvarchar | District contact |
| `DistrictOfficeID` | smallint | FK → `dbo.ConfigSchool`; indexed |
| `AccountingDistrict` / `LibraryDistrict` / `ParentsWebDistrict` / `DonateOnlineDistrict` / `DistrictLMS` | bit | Feature toggles |
| `DistrictConfiguration` / `PDACount` / `ProgressionDate` | mixed | Config |
| `DistrictPassword` / `pwversion` | mixed | Legacy district password |
| Password policy: `PasswordExpiration` / `PasswordLength` / `PasswordExpirationLimit` / `PasswordRequiresNumber` / `PasswordRequiresCapital` / `PasswordRequiresSymbol` / `LockOutAttempts` / `InactivityTimeoutInMinutes` | int/bit | Auth policy |
| Portal: `PWBanner` / `PWMessage` / `PWHeaderColor1` / `PWHeaderColor2` / `PWHeaderPicturePath` / `PWTextColor` / `PWMascotName` / `PWDefaultStaffIDforComments` | mixed | ParentsWeb styling |
| `AttendancePolicy` / `BehaviorPolicy` | nvarchar(max) | Policy text |
| Timezone: `TimezoneOffset` / `TimezoneOffsetUTC` / `TimezoneUsesDST` / `MicrosoftTimeZoneId` | mixed | `MicrosoftTimeZoneId` FK → `ref.MSTimeZones`, default 'unknown' |
| Library policy: `LibraryPolicyAccountingCategoryID` / `LibraryPolicyFiscalYearID` / `LibraryPolicyLateFeeMode` / `LibraryPolicyDefaultMaxCheckouts` / `LibraryPolicyDefaultBlockOnFines` / `LibraryPolicyDefaultMaxHoldTime` / `LibraryPolicyDefaultMaxReservations` / `LibraryPolicyDefaultMaxReservationTime` / `LibraryCalendarSettings` / `LibraryPolicyIsSchoolDays` | int/bit/smallint | `LateFeeMode`: 0=off, 1=Automatic, 2=Manual |
| Overlay (data copy): `OverlayID` / `OverlayDateTime` / `OverlayByRWstaff` / `OverlaySourceDistrict` / `OverlaySourceDateTime` / `OverlayIsSourceConfidential` / `OverlayIsTargetDemo` | mixed | Demo/overlay provenance |
| `DonateNowContact` / `DonateNowMessage` | nvarchar | Donation portal |
| `ParentAlert` / `ShareSurvey` / `SSE` / `Daycare` / `LunchPaymentMethod` | bit | Misc toggles |
| `TenantId` | uniqueidentifier | Nullable |
| `ModifiedBy` / `ModifiedDate` | int/smalldatetime | Audit |

FKs: `DistrictOfficeID` → `dbo.ConfigSchool.ConfigSchoolID`; `MicrosoftTimeZoneId` → `ref.MSTimeZones`.

---

#### `dbo.ConfigEditGrid`
Per-staff editable-grid column configuration — column order, width, and grouping for a given grid type. PK is composite `(Type, StaffID, EditGridOrder, EditGridGroup)`.

| Column | Type | Notes |
|---|---|---|
| `Type` | nvarchar(50) | PK (composite); grid type |
| `StaffID` | int | PK (composite) |
| `EditGridOrder` | int | PK (composite); column order |
| `EditGridGroup` | nvarchar(50) | PK (composite) |
| `FieldName` | nvarchar(400) | Column field; nullable |
| `ColWidth` | int | Nullable |

---

#### `dbo.ConfigMedicalTests`
Legacy medical-test type configuration — a test name plus 10 generic field-label slots (`Field1`–`Field10`), per school. **Synced to the newer `med` schema via three triggers** (`med.MedicalTestConfiguration` + `med.MedicalTestConfigurationField`).

| Column | Type | Notes |
|---|---|---|
| `TestTypeID` | int IDENTITY | PK (non-clustered) |
| `TestName` | nvarchar(50) | Nullable |
| `Field1`–`Field10` | nvarchar(50) | Field-label slots; nullable |
| `SchoolCode` | varchar(50) | Indexed; nullable |
| `DistrictWide` | bit | Nullable |
| `ModifiedBy` / `ModifiedDate` | int/smalldatetime | Nullable |

**Triggers** (INSERT/UPDATE/DELETE, with `trigger_nestlevel()` guards to prevent recursion): keep `med.MedicalTestConfiguration` and `med.MedicalTestConfigurationField` in sync. INSERT uses `IDENTITY_INSERT` to mirror `TestTypeID` → `MedicalTestConfigurationID`, then unpivots `Field1`–`Field10` into per-field rows. UPDATE propagates name/school changes and field-by-field label changes. DELETE removes the linked `med` config. **This is a legacy→new bridge**; new medical-test work uses the `med` schema directly.

---

#### `dbo.ConfigScheduling`
Per-school scheduling configuration — currently just the default scheduling year. PK = `ConfigSchoolID`.

| Column | Type | Notes |
|---|---|---|
| `ConfigSchoolID` | smallint | PK; FK → `dbo.ConfigSchool` |
| `DefaultSchedulingYearId` | int | Default 0 |

---

#### `dbo` config / class-group / conference tables — cross-reference summary

| Table | Scope | Key FK targets / notes |
|---|---|---|
| `ClassGroups` | Named class group per year/school | Header for group↔class and group↔student |
| `ClassGroupStudents` | Class group ↔ student | PK `(GroupID, StudentID)` |
| `ClassWebDocument` | Web document ↔ class | PK `(DocumentID, ClassID)` |
| `CommentCodes` | Report-card comment codes per school | Unique `(CommentNumber, SchoolCode)` |
| `CommunityService` | Community service hours per student | `dbo.Person` |
| `Conference` | Parent/teacher conference per student | Checkbox + narrative fields |
| `ConfigDistrict` | District-level configuration | `dbo.ConfigSchool`, `ref.MSTimeZones`; PK `DistrictCode` |
| `ConfigEditGrid` | Per-staff grid column config | PK `(Type, StaffID, EditGridOrder, EditGridGroup)` |
| `ConfigMedicalTests` | Legacy medical-test config | 3 triggers sync to `med` schema |
| `ConfigScheduling` | Per-school scheduling config | `dbo.ConfigSchool` |

---

### `dbo` school config / course-relationship tables

#### `dbo.ConfigSchool`
**One of the most important configuration tables in the system** — per-school settings, the school counterpart to `dbo.ConfigDistrict`. PK is `SchoolCode`; `ConfigSchoolID` is a unique IDENTITY surrogate that most other tables FK to. Temporal table. Holds report-card/transcript display config, gradebook term toggles, attendance source, library policy, lunch/online-enrollment accounting, portal styling, and FACTS-sync settings. **Directly relevant to report cards and transcripts** — many report behaviors are driven by columns here.

Key columns by group:

| Column group | Type | Notes |
|---|---|---|
| `SchoolCode` | varchar(50) | PK |
| `ConfigSchoolID` | smallint IDENTITY | Unique surrogate; the FK target most tables reference |
| `SchoolName` / `Address` / `City` / `State` / `Zip` / `Phone` / `Fax` / `Web` / `Email` / `DistrictName` | nvarchar | School identity |
| `Active` / `IsNonFactsSchool` / `BlockDistrictOffice` | bit | Status flags |
| `DefaultYearID` / `DefaultTermID` / `NextYearID` / `EnrollmentYearID` | int/smallint | Current/next year & term defaults |
| `DefaultTemplate` | nvarchar(50) | Default report template |
| Report card terms: `RC_Term1`–`RC_Term6`, `RC_Sem1`/`RC_Sem2`/`RC_Sem3`, `RC_Exam1`/`RC_Exam2`/`RC_Exam3`, `RC_FinalGrade` | bit | **Which columns appear on the report card** |
| Gradebook terms: `GBK_Term1`–`GBK_Term6`, `GBK_CurrentYearEditOnly` | bit | Gradebook term visibility/edit |
| Transcript: `TranscriptNote1`–`5`, `TranscriptLoad`, `TranscriptT1Suffix`–`T6Suffix`, `CollegeBoardSchoolCode` | mixed | **Transcript display config** |
| Report card notes: `ReportCardNote1`–`5`, `ReportCardOnlyAllowSystemComments` | mixed | **Report-card footer notes & comment policy** |
| Attendance: `DayAttendanceSource` / `AbsentDay` / `AbsentHalf` / `UseGradeLevelAttendanceConfiguration` | int/bit | `UseGradeLevelAttendanceConfiguration` historically routed the day-attendance SP (see `dbo.Attendance` trigger notes) |
| Family naming: `FamilyNameCouple1`–`3`, `FamilyNameIndividual1`–`3` | nvarchar | Salutation formatting |
| Lesson plan: `LessonPlanLabel1`–`4` | nvarchar | Lesson-plan field labels |
| ParentsWeb: `PWYearID` / `PWTermID` / `PWTermID2` / `PWBanner` / `PWScheduleYearID` / `PWScheduleTermID` / `PWScheduleTemplate` / `PWSchoolName` / `PWMascotName` / `PWHeaderColor1` / `PWHeaderColor2` / `PWHeaderPicturePath` / `PWTextColor` / `PWDefaultStaffIDforComments` / `pwversion` | mixed | Portal config/styling |
| Web course requests: `WebCourseRequestsCustomTemplate` / `...FilterByGradeLevel` / `...SortByDepartment` / `...UsePrereqRules` / `...ShowHistory` / `...UseNextYearGradeLevel` / `...UseCustomTemplate` / `...YearID` | mixed | Online course-request behavior |
| Web lunch: `BeginWebLunch` / `EndWebLunch` / `LunchPaymentMethod` / `LunchAccountingSystemID` / `LunchFiscalYearID` / `LunchAccountingCategoryID` | mixed | Lunch ordering/accounting |
| Online enrollment (OE): `OE_AccountingSystemID` / `OE_CategoryID` / `OE_FiscalYearID` / `OE_Tuition_Plan_Fiscal_Year_ID` / `EnrollmentNotificationTemplate_NewStudent` / `EnrollmentNotificationTemplate_ExistingStudent` | mixed | Enrollment accounting & templates |
| FACTS sync (OE/OA): `OEFactsTerm` / `OEFactsAccount` / `OEFactsAdjustmentReason` / `OAFactsTerm` / `OAFactsAccount` / `OAFactsAdjustmentReason` | nvarchar(50) | FACTS integration mapping |
| Library policy: `LibraryPolicyAccountingCategoryID` / `LibraryPolicyFiscalYearID` / `LibraryPolicyLateFeeMode` / `LibraryPolicyDefaultMaxCheckouts` / `LibraryPolicyDefaultBlockOnFines` / `LibraryPolicyDefaultMaxHoldTime` / `LibraryPolicyDefaultMaxReservations` / `LibraryPolicyDefaultMaxReservationTime` / `LibraryCalendarSettings` / `LibraryPolicyIsSchoolDays` | int/bit/smallint | `LateFeeMode`: 0=off, 1=Automatic, 2=Manual |
| `DaySchedule` / `ShowCalendar` / `ShowAnnouncements` / `SchoolChat` / `SchoolLMS` | smallint/bit | Feature toggles |
| Notifications: `NotificationEmail1` / `NotificationEmail2` | nvarchar(256) | — |
| Policy text: `AttendancePolicy` / `BehaviorPolicy` | nvarchar(max) | — |
| Donations: `DonateNowContact` / `DonateNowMessage` / `ParentAlert` | mixed | — |
| Misc: `SchoolSortOrder` / `SystemOfMeasurement` / `ClockFormatID` (CHECK 1–2) / `GovernanceDefinedListID` (FK → `dbo.DefinedLists`) / `TenantId` / `DistrictCodeSeed` | mixed | `SystemOfMeasurement` 1=Imperial, etc. |
| `CreatedOnUTC` / `ModifiedOnUTC` / `ModifiedOnUTCmax` | datetime2(2) | Temporal versioning |
| `ModifiedBy` / `ModifiedDate` | int/smalldatetime | Audit |

Constraints: PK `SchoolCode`; unique `ConfigSchoolID`; CHECK `ClockFormatID` between 1 and 2; FK `GovernanceDefinedListID` → `dbo.DefinedLists.DLID`.

**Practical note**: when a report card or transcript shows/hides the wrong term/exam columns, the `RC_*` and `GBK_*` flags here are the first place to look. `ConfigSchoolID` (not `SchoolCode`) is what most child tables join on.

---

#### `dbo.ConfigSchedulingFilters`
Per-staff scheduling division filter (which school divisions a scheduler sees) for a school. Unique on `(ConfigSchoolID, PersonID)`.

| Column | Type | Notes |
|---|---|---|
| `ConfigSchedulingFiltersId` | int IDENTITY | PK |
| `PersonID` | int | FK → `dbo.Person`; indexed |
| `ConfigSchoolID` | smallint | FK → `dbo.ConfigSchool`; unique with `PersonID` |
| `PreSchool` / `Elementary` / `MiddleSchool` / `HighSchool` | bit | Division filters; default 1 |

---

#### `dbo.ConfigSubstatus`
Lookup of status → substatus values per school (e.g. enrollment status breakdowns). Surrogate PK `Autonumber`.

| Column | Type | Notes |
|---|---|---|
| `Autonumber` | int IDENTITY | PK |
| `Status` | nvarchar(50) | Parent status; nullable |
| `SubStatus` | nvarchar(50) | Nullable |
| `SchoolCode` | varchar(50) | Nullable |

---

#### `dbo.Configuration`
Generic name/value configuration store per school — a flexible key/value bag for settings that don't have dedicated columns. Temporal table. PK is composite `(Name, SchoolCode)`. `CreatedOnUTC` is protected (`DENY UPDATE` to public); the FACTS sync tool account has SELECT.

| Column | Type | Notes |
|---|---|---|
| `Name` | varchar(100) | PK (composite); setting key |
| `SchoolCode` | varchar(50) | PK (composite) |
| `Value` | nvarchar(1000) | Setting value; nullable |
| `CreatedOnUTC` | datetime2(2) | `DENY UPDATE` to public |
| `ModifiedOnUTC` / `ModifiedOnUTCmax` | datetime2(2) | Temporal versioning |

---

#### `dbo.Configuration_LoadWilcompStudentUD` (stored procedure, not a table)
**This is a stored procedure, included here for completeness.** It was written to mine a legacy "WILCOMP" linked-server database for district-level user-defined config and MERGE it into `dbo.Configuration`. **It is effectively disabled** — the body is `SET NOCOUNT ON; RETURN 0;` with the entire MERGE commented out (the `wilcdb` linked server was removed in 2017). Safe to ignore for current work; no live effect.

---

### `dbo` course-relationship tables

These small link tables define relationships between courses (`dbo.Courses`). All are keyed by `CourseID` + the related course/value.

#### `dbo.Course_Corequisites`
Courses that must be taken alongside a course. PK `(CourseID, CorequisiteCourseID)`.

| Column | Type | Notes |
|---|---|---|
| `CourseID` | int | PK (composite) |
| `CorequisiteCourseID` | int | PK (composite) |
| `ModifiedBy` / `ModifiedDate` | int/smalldatetime | Nullable |

---

#### `dbo.Course_Equivalents`
Courses considered equivalent (for credit/requirement purposes). PK `(CourseID, EquivalentCourseID)`.

| Column | Type | Notes |
|---|---|---|
| `CourseID` | int | PK (composite) |
| `EquivalentCourseID` | int | PK (composite) |
| `ModifiedBy` / `ModifiedDate` | int/smalldatetime | Nullable |

---

#### `dbo.Course_Prerequisites`
Courses required before a course, with an optional minimum grade. PK `(CourseID, PrerequisiteCourseID)`.

| Column | Type | Notes |
|---|---|---|
| `CourseID` | int | PK (composite) |
| `PrerequisiteCourseID` | int | PK (composite) |
| `MinimumGrade` | decimal(19,4) | Required grade in prereq; nullable |
| `ModifiedBy` / `ModifiedDate` | int/smalldatetime | Nullable |

---

#### `dbo.Course_GradeLevel`
Grade levels a course is offered to, with auto-schedule priority. Temporal table. PK `(CourseID, GradeLevel)`.

| Column | Type | Notes |
|---|---|---|
| `CourseID` | int | PK (composite) |
| `GradeLevel` | nvarchar(50) | PK (composite) |
| `GradeLevelDescriptorId` | uniqueidentifier | Ed-Fi descriptor; nullable |
| `AutoSchedulePriority` | int | Default 3 |
| `CreatedOnUTC` / `ModifiedOnUTC` / `ModifiedOnUTCmax` | datetime2(2) | Temporal versioning |
| `ModifiedBy` / `ModifiedDate` | int/smalldatetime | Nullable |

---

#### `dbo.CourseBooks`
Links textbook definitions to a course. PK `(TextBookDefinitionID, CourseID)`.

| Column | Type | Notes |
|---|---|---|
| `TextBookDefinitionID` | int | PK (composite) |
| `CourseID` | int | PK (composite) |

---

#### `dbo` school-config / course-relationship tables — cross-reference summary

| Table | Scope | Key FK targets / notes |
|---|---|---|
| `ConfigSchool` | Per-school configuration — central | PK `SchoolCode`; `ConfigSchoolID` is the surrogate most tables FK to; temporal; drives report-card/transcript display |
| `ConfigSchedulingFilters` | Per-staff scheduling division filter | `dbo.Person`, `dbo.ConfigSchool` |
| `ConfigSubstatus` | Status→substatus lookup per school | — |
| `Configuration` | Generic name/value config store | Temporal; PK `(Name, SchoolCode)` |
| `Configuration_LoadWilcompStudentUD` | **Stored proc** (disabled legacy WILCOMP importer) | Not a table; no live effect |
| `Course_Corequisites` | Course corequisite links | PK `(CourseID, CorequisiteCourseID)` |
| `Course_Equivalents` | Course equivalency links | PK `(CourseID, EquivalentCourseID)` |
| `Course_Prerequisites` | Course prerequisite links + min grade | PK `(CourseID, PrerequisiteCourseID)` |
| `Course_GradeLevel` | Course ↔ grade-level offering | Temporal; `AutoSchedulePriority` |
| `CourseBooks` | Course ↔ textbook definition | PK `(TextBookDefinitionID, CourseID)` |

---

### `dbo` course-level / course-objective / course-request tables

#### `dbo.CourseLevel`
Course level/track definition per school (e.g. Honors, Regular, AP) — carries **default gradebook config and the grade-weighting matrix** that classes inherit. The `s1_t1`…`f_s3` columns are the same weight-matrix layout as `dbo.ClassGradeCalculation` (see that table for the `{scope}_{component}` naming), here serving as the course-level default. Also holds the same standards-based-grading config columns as `dbo.Classes`.

Key columns by group:

| Column group | Type | Notes |
|---|---|---|
| `CourseLevelID` | int IDENTITY | PK (non-clustered) |
| `LevelName` / `Description` | nvarchar(50) | Level name/description |
| `SchoolCode` | varchar(50) | Nullable |
| `Honors` | bit | Honors-level flag |
| Gradebook config: `GbkGradeMethod` / `GbkIncompleteIs0` / `GbkStudentSort` / `GbkAssignmentSort` / `GbkShowPointsEarned` / `GbkCapCategory` / `GbkCapTerm` / `GbkDecimalPlaces` / `GbkTimeFrame` / `GbkWebProgressReport` / `GbkShowCurve` / `WebProgressReportStyle` | mixed | Defaults inherited by classes |
| Weight matrix: `s1_t1`–`s1_t6`/`s1_e1`–`s1_e3`, `s2_*`, `s3_*`, `f_t1`–`f_t6`/`f_e1`–`f_e3`/`f_s1`–`f_s3`, `DecimalPlaces` | real/smallint | Same layout as `ClassGradeCalculation` |
| SBG config: `AllowStandardGrading` / `EnableStandardTagging` / `IsStandardsBasedCalculation` / `DefaultAssignmentMaxPoints` / `StandardMaxGrade` / `StandardMasteryGradeMinVal0`–`2` / `GbkStandardCalculation` / `GbkStandardCalculationRecent` / `GbkStandardCalculationDecayRate` / `StandardAssignmentGradeFlowType` | bit/int/decimal | Same as `dbo.Classes` SBG columns |
| `ModifiedBy` / `ModifiedDate` | int/smalldatetime | Audit |

---

#### `dbo.CourseLevelAssessments`
Assessment definitions tied to a course level — title, weight, term applicability, and color. Unique clustered on `(AssessmentID, CourseLevelID)`.

| Column | Type | Notes |
|---|---|---|
| `CourseLevelAssessmentID` | int IDENTITY | PK (non-clustered) |
| `AssessmentID` | int | Part of unique clustered index |
| `CourseLevelID` | int | Part of unique clustered index |
| `Title` | nvarchar(50) | Nullable |
| `Description` | nvarchar(100) | Nullable |
| `Weight` | real | Nullable |
| `Term1`–`Term6` | bit | Term applicability; nullable |
| `ColorHexHTML` | char(7) | Hex color; nullable |

---

#### `dbo.CourseLevelCodeTranslation`
Maps a letter code to a percentage and a status code for a course level — used to translate non-numeric grade marks. CASCADE deletes from `dbo.CourseLevel`. The `StatusCode` is CHECK-constrained to a fixed set.

| Column | Type | Notes |
|---|---|---|
| `CourseLevelCodeTranslationId` | int IDENTITY | PK |
| `CourseLevelID` | int | FK → `dbo.CourseLevel` (CASCADE) |
| `LetterCode` | nvarchar(50) | The mark being translated |
| `Percent` | decimal(9,4) | Numeric equivalent; default 0 |
| `StatusCode` | char(1) | Default 'V'; CHECK ∈ {M, I, P, A, E, D, V} |

`StatusCode` values (M/I/P/A/E/D/V) classify the mark — e.g. Missing, Incomplete, Pass, Absent, Excused, Dropped, and V (the default, a normal graded value). Confirm the exact mapping against the grading UI when it matters for a report.

---

#### `dbo.CourseLevelGradeTranslation`
Maps a grade string to a numeric average for a course level (e.g. for GPA computation). PK is composite `(CourseLevelID, Grade)`.

| Column | Type | Notes |
|---|---|---|
| `CourseLevelID` | int | PK (composite); default 0 |
| `Grade` | nvarchar(50) | PK (composite); grade string |
| `Avg` | real | Numeric value; default 0 |
| `ModifiedBy` / `ModifiedDate` | int/smalldatetime | Nullable |

---

#### `dbo.CourseObjectives`
Course learning objectives — numbered objectives optionally grouped via `CourseObjectivesGroup`.

| Column | Type | Notes |
|---|---|---|
| `ObjectiveID` | int IDENTITY | PK (non-clustered) |
| `CourseID` | int | Indexed; default 0 |
| `Objective` | nvarchar(max) | Objective text; nullable |
| `ObjectiveNumber` | smallint | Indexed; default 0 |
| `Number` | varchar(50) | Display number; nullable |
| `GroupID` | int | → `dbo.CourseObjectivesGroup`; nullable |
| `ModifiedBy` / `ModifiedDate` | int/smalldatetime | Nullable |

---

#### `dbo.CourseObjectivesGroup`
Groups for course objectives — a named/numbered grouping within a course.

| Column | Type | Notes |
|---|---|---|
| `GroupID` | int IDENTITY | PK |
| `CourseID` | int | Nullable |
| `GroupNumber` | varchar(50) | Nullable |
| `GroupName` | varchar(255) | Nullable |
| `ModifiedBy` / `ModifiedDate` | int/smalldatetime | Nullable |

---

#### `dbo.CourseOfferingCurriculumUsed`
Ed-Fi style record of which curriculum a course offering used, per session. Bridges to the `crse` and `cnfg` schemas. PK is composite `(CourseOffereingCurriculumUsedID, CurriculumUsedDescriptorCode)` (note: `Offereing` is a typo in the actual column name).

| Column | Type | Notes |
|---|---|---|
| `CourseOffereingCurriculumUsedID` | int IDENTITY | PK (composite); *sic* spelling |
| `CurriculumUsedDescriptorCode` | uniqueidentifier | PK (composite); Ed-Fi descriptor |
| `SessionID` | int | FK → `cnfg.Session`; indexed |
| `LocalCourseID` | int | FK → `crse.CourseCore`; indexed |

---

#### `dbo.CourseRequestTemplate`
Online course-request template per school/grade level — portal display config and min/max request counts. Unique on `(GradeLevel, SchoolCode)`. Header for `CourseRequestTemplateCourse` and `CourseRequestTemplateElementName`.

| Column | Type | Notes |
|---|---|---|
| `TemplateID` | int IDENTITY | PK |
| `GradeLevel` | nvarchar(50) | CHECK: non-empty trimmed; unique with `SchoolCode` |
| `SchoolCode` | varchar(50) | Nullable |
| `HTML_text` | nvarchar(max) | Template body; nullable |
| `ShowInFamilyPortal` / `ShowTeacherRecommendations` / `ShowGradeLevelDefaults` / `RequireParentSignOff` | bit | Display/behavior flags; default 0 |
| `MinAllowed` / `MaxAllowed` | tinyint | Request count bounds; default 0 |

---

#### `dbo.CourseRequestTemplateCourse`
Courses available within a course-request template element. PK is composite `(TemplateID, ElementNum, CourseID)`.

| Column | Type | Notes |
|---|---|---|
| `TemplateID` | int | PK (composite) |
| `ElementNum` | int | PK (composite); template element |
| `CourseID` | int | PK (composite) |

---

#### `dbo.CourseRequestTemplateElementName`
Names for each element (section) of a course-request template. PK is composite `(TemplateID, ElementNum)`.

| Column | Type | Notes |
|---|---|---|
| `TemplateID` | int | PK (composite) |
| `ElementNum` | int | PK (composite) |
| `Name` | nvarchar(500) | Element label; nullable |
| `ShowPassed` | bit | Nullable |

---

#### `dbo` course-level / course-objective / course-request tables — cross-reference summary

| Table | Scope | Key FK targets / notes |
|---|---|---|
| `CourseLevel` | Course level/track + default grade config | Weight matrix mirrors `ClassGradeCalculation`; SBG cols mirror `Classes` |
| `CourseLevelAssessments` | Assessments per course level | Unique `(AssessmentID, CourseLevelID)` |
| `CourseLevelCodeTranslation` | Letter-code → percent/status | CASCADE from `CourseLevel`; `StatusCode` CHECK {M,I,P,A,E,D,V} |
| `CourseLevelGradeTranslation` | Grade string → numeric avg | PK `(CourseLevelID, Grade)` |
| `CourseObjectives` | Course learning objectives | → `CourseObjectivesGroup` |
| `CourseObjectivesGroup` | Objective groupings | — |
| `CourseOfferingCurriculumUsed` | Curriculum used per offering/session | `crse.CourseCore`, `cnfg.Session` |
| `CourseRequestTemplate` | Online course-request template | Unique `(GradeLevel, SchoolCode)` |
| `CourseRequestTemplateCourse` | Courses in a template element | PK `(TemplateID, ElementNum, CourseID)` |
| `CourseRequestTemplateElementName` | Template element labels | PK `(TemplateID, ElementNum)` |

---

### `dbo` legacy courses, payment, and curriculum-plan tables

#### `dbo.Courses_was`
**The legacy master course table, renamed.** The `_was` suffix indicates it has been **superseded** — the current master course entity is `crse.CourseCore` (documented in the `crse` section). This definition is retained for history/migration reference. Temporal table. **Important for older reports**: many legacy report queries still reference `dbo.Courses` (the name this table previously had), so when a report joins to `Courses`, confirm whether it means this legacy table or the newer `crse.CourseCore`.

Note the triggers still name the live table `Courses_was` but cascade to `dbo.Classes` — see below.

Key columns by group:

| Column group | Type | Notes |
|---|---|---|
| `CourseID` | int IDENTITY | PK (non-clustered) |
| `Title` / `Abbreviation` / `Description` | nvarchar | Course identity |
| `SchoolCode` | varchar(50) | Indexed |
| `LevelID` | int | → course level; default 0 |
| `Department` / `DepartmentID` | nvarchar/int | Department |
| `Active` | bit | Default 1 |
| Report/transcript: `ReportCard` / `Transcript` / `CalcTranscript` / `NoCalcTranscript` / `TranscriptLoad` / `RCPlacement` | bit/int | **Whether/how the course appears on report cards & transcripts** |
| Credits/weights: `Credits` / `TermWt` / `SemesterWt` / `FinalWt` / `Weight` | float/real | Credit value and grade weights |
| Flags: `Calc` / `Attendance` / `Activity` / `HomeRoom` / `Elective` / `HS` / `PreSchool` / `Elementary` / `MidleSchool` (*sic*) | bit | Behavior/division flags |
| Terms/rooms: `Terms` / `RequiredRoomID` / `MaxSize` / `ScheduleStyle` / `PatternGroup` / `PatternGroupID` | mixed | `PatternGroupID` FK → `sched.TemplatePatternGroup` |
| Fees: `CourseFee` / `MaterialFee` / `LabFee` / `MiscFee` + `CourseAcctCat` / `MaterialAcctCat` / `LabAcctCat` / `MiscAcctCat` | real/int | Fee amounts + accounting categories |
| Relationships (legacy text): `Prerequisites` / `Corequisites` / `Equivalents` / `ReqGrade` / `LinkedCourseID` / `Contacts` / `CourseType` | mixed | Superseded by the `Course_*` link tables |
| Moodle/IB: `EnableMoodle` / `MoodleCourseID` / `MoodleGuestAccess` / `IBCourseID` | mixed | Integrations |
| `StateID` / `LegacyCourseID` / `DefaultStaffID` | mixed | External/legacy IDs |
| `CreatedOnUTC` / `ModifiedOnUTC` / `ModifiedOnUTCmax` | datetime2(2) | Temporal versioning |
| `ModifiedBy` / `ModifiedDate` | int/smalldatetime | Audit |

**Triggers** (legacy cascade, defined on `Courses_was`):
- `Courses_DTrig` (DELETE): cascades deletes to `dbo.Classes` (deletes classes whose `CourseID` matches). The cascade statement is duplicated in the body (harmless redundancy).
- `Courses_UTrig` (INSERT, UPDATE): cascades `CourseID` updates to `dbo.Classes`, and refreshes `ModifiedDate` on the affected rows.

**Practical note**: deleting a course here cascades to its classes (and `Classes`' own triggers then block if rosters exist). Because this is the `_was` table, verify whether current code paths still write to it before relying on these cascades.

---

#### `dbo.CPEndOfDay`
CashPay (payment gateway) end-of-day transaction reconciliation — one row per gateway transaction with order, billing, gateway result, and processing-status fields. PK `CPEndofDayID`; unique on `TransactionID`. Money fields are stored as `int` (cents). `lastfour` holds the card's last four digits only (no full PAN).

| Column group | Type | Notes |
|---|---|---|
| `CPEndofDayID` | int IDENTITY | PK |
| `TransactionID` | int | Unique |
| Transaction: `TransactionType` / `TransactionStatus` / `TransactionTotalAmt` / `TransactionAccType` / `TransactionDate` / `TransactionEffectiveDate` / `TransactionResultCode` / `TransactionResultMessage` / `TransactionFailureMessage` / `TransSettlementDate` | mixed | Gateway transaction detail |
| Order: `OrderDescription` / `OrderType` / `OrderAmt` / `OrderFee` / `OrderAmtDue` / `OrderDueDate` / `OrderBalance` / `OrderCurrStatusBalance` / `OrderCurrStatusAmtDue` | mixed | Order detail (amounts in cents) |
| Billing: `AccHolderName` / `Street1` / `Street2` / `City` / `State` / `Zip` / `Country` / `DayTimePhone` / `EveningPhone` / `Email` | nvarchar | Account-holder billing info |
| `UserChoice1`–`UserChoice5` | nvarchar(50) | Custom fields |
| Payment refs: `lastfour` / `CPPaymentID` / `PaymentID` / `DepositID` / `GatewayTransID` / `cpPaymentToken` / `AdditionalResults1` | mixed | `lastfour` = masked card; tokenized payment ref |
| `DistrictCode` / `SchoolCode` | nvarchar/varchar | Scope |
| Status: `Processed` / `NotificationSent` / `Refunded` / `SyncToMaster` | bit | Default 0 |

> **Sensitive**: this table holds billing/contact PII and payment-gateway tokens. Don't expose `cpPaymentToken`, full billing details, or gateway IDs in reports beyond what's needed; never log them.

---

#### `dbo.CreateAReport`
Header for a user-built "Create A Report" definition — name, owner, type, share level, and the report definition serialized as XML (`carObject`).

| Column | Type | Notes |
|---|---|---|
| `CreateAReportID` | int IDENTITY | PK |
| `Name` | varchar(128) | Nullable |
| `StaffID` | int | Owner; nullable |
| `SchoolCode` | varchar(50) | Nullable |
| `Type` | varchar(50) | Report type; nullable |
| `Share` | int | Share level; nullable |
| `FieldCount` | int | Nullable |
| `HideFilter2` | varchar(50) | Nullable |
| `carObject` | xml | Serialized report definition |
| `ModifiedBy` / `ModifiedDateTime` | int/smalldatetime | Audit |

---

#### `dbo.CreateAReportConfiguration`
Saved Create-A-Report configuration — a flat set of field slots (`F1`–`F20`), grouping/sort slots (`X1`–`X3` with a/b variants, `S1`–`S3` with a variants), owner, share, and optional webform link.

| Column group | Type | Notes |
|---|---|---|
| `CreateAReportID` | int IDENTITY | PK |
| `Name` / `Type` | varchar | Identity; indexed with `StaffID`/`Share` |
| `F1`–`F20` | varchar(50) | Field slots |
| `X1`/`X1a`/`X1b` … `X3`/`X3a`/`X3b` | varchar(50) | Grouping/cross-tab slots |
| `S1`/`S1a` … `S3`/`S3a` | varchar(50) | Sort/summary slots |
| `StaffID` | int | Owner; indexed |
| `Share` | bit | Nullable |
| `Webform` / `WebformID` | varchar/int | Optional webform link |

---

#### `dbo.CreateAReportFieldGroup`
Field groups selected for a Create-A-Report. PK is composite `(CreateAReportID, FieldGroup)`.

| Column | Type | Notes |
|---|---|---|
| `CreateAReportID` | int | PK (composite) |
| `FieldGroup` | varchar(50) | PK (composite) |

---

#### `dbo.CreateAReportFields`
Per-field configuration for a Create-A-Report — display name, cross-tab/summary slots, format, alignment, and hide flags. PK is composite `(CreateAReportID, Field)`.

| Column | Type | Notes |
|---|---|---|
| `CreateAReportID` | int | PK (composite) |
| `Field` | int | PK (composite); field index |
| `Name` | varchar(128) | Display name; nullable |
| `Xa`–`Xe`, `Xg` | varchar(50) | Cross-tab slots; nullable |
| `Sa` / `Sb` / `Summary` | varchar(50) | Summary slots; nullable |
| `Format` / `Alignment` | varchar(50) | Display; nullable |
| `Hide` / `HideFilter2` | varchar(50) | Hide flags; nullable |

---

#### `dbo.CryptPayForms`
Payment-form (CryptPay/CashPay) credentials per school — gateway form ID, GUID, username, and password. PK is composite `(CPForm, SchoolCode)`.

| Column | Type | Notes |
|---|---|---|
| `CPForm` | nvarchar(10) | PK (composite); form identifier |
| `SchoolCode` | varchar(50) | PK (composite); default '' |
| `CPFormGUID` | nvarchar(128) | Gateway form GUID; nullable |
| `CPFormUN` | nvarchar(50) | Gateway username; nullable |
| `CPFormPW` | nvarchar(50) | Gateway password; nullable |

> **Sensitive credentials**: `CPFormUN`/`CPFormPW`/`CPFormGUID` are live payment-gateway credentials. Never select these into a report, log, or expose them. Treat like `cnv.IntegrationAccount` tokens.

---

#### `dbo.Currency`
Currency formatting lookup — symbol, decimal/thousands separators, and symbol position. PK `CurrencyCode`.

| Column | Type | Notes |
|---|---|---|
| `CurrencyCode` | varchar(10) | PK |
| `Name` | varchar(50) | Nullable |
| `Symbol` | varchar(10) | Nullable |
| `Decimal` / `Thousands` | varchar(1) | Separator chars; nullable |
| `Position` | varchar(5) | Symbol position; nullable |

---

#### `dbo.CurriculumPlan`
Curriculum plan ↔ course membership (legacy form) — keyed by plan name + course + school. PK is composite `(CurriculumPlan, CourseID, SchoolCode)`.

| Column | Type | Notes |
|---|---|---|
| `CurriculumPlan` | nvarchar(50) | PK (composite); plan name |
| `CourseID` | int | PK (composite) |
| `SchoolCode` | varchar(50) | PK (composite) |

---

#### `dbo.CurriculumPlanCourses`
Curriculum plan ↔ course membership (newer, ID-based) — by plan ID, with grade level. PK is composite `(CurriculumPlanID, CourseID)`.

| Column | Type | Notes |
|---|---|---|
| `CurriculumPlanID` | int | PK (composite) |
| `CourseID` | int | PK (composite) |
| `GradeLevel` | nvarchar(50) | Nullable |
| `ModifiedBy` / `ModifiedDate` | int/smalldatetime | Nullable |

Note: two curriculum-plan membership models coexist — `CurriculumPlan` (name-keyed) and `CurriculumPlanCourses` (ID-keyed). Check which one a report uses.

---

#### `dbo` legacy-courses / payment / curriculum-plan tables — cross-reference summary

| Table | Scope | Key FK targets / notes |
|---|---|---|
| `Courses_was` | **Legacy** master course table (renamed) | Superseded by `crse.CourseCore`; cascades to `Classes`; temporal; `sched.TemplatePatternGroup` |
| `CPEndOfDay` | Payment-gateway end-of-day reconciliation | **PII + tokens — sensitive**; amounts in cents |
| `CreateAReport` | Create-A-Report header (XML definition) | `carObject` xml |
| `CreateAReportConfiguration` | Saved report field/sort config | Slot-based (F/X/S columns) |
| `CreateAReportFieldGroup` | Report field groups | PK `(CreateAReportID, FieldGroup)` |
| `CreateAReportFields` | Per-field report config | PK `(CreateAReportID, Field)` |
| `CryptPayForms` | Payment-form gateway credentials | **Credentials — never expose** |
| `Currency` | Currency formatting lookup | PK `CurrencyCode` |
| `CurriculumPlan` | Curriculum plan↔course (name-keyed, legacy) | PK `(CurriculumPlan, CourseID, SchoolCode)` |
| `CurriculumPlanCourses` | Curriculum plan↔course (ID-keyed) | PK `(CurriculumPlanID, CourseID)` |

---

### `dbo` curriculum-plan (ID-based) tables

These complete the **ID-based curriculum-plan model** (`CurriculumPlanID`-keyed), distinct from the older name-keyed `dbo.CurriculumPlan`. `CurriculumPlans` is the header; the others hang off `CurriculumPlanID` or `RequirementID`.

#### `dbo.CurriculumPlans`
Header for an ID-based curriculum plan (graduation/program requirements set) per school.

| Column | Type | Notes |
|---|---|---|
| `CurriculumPlanID` | int IDENTITY | PK |
| `CurriculumPlanName` | nvarchar(50) | Nullable |
| `SchoolCode` | varchar(50) | Nullable |
| `Description` | nvarchar(max) | Nullable |
| `ModifiedBy` / `ModifiedDate` | int/smalldatetime | Nullable |

---

#### `dbo.CurriculumPlanRequirements`
Individual requirements within a curriculum plan — by department or specific course, with required credits and minimum grade. Surrogate PK `RequirementID`.

| Column | Type | Notes |
|---|---|---|
| `RequirementID` | int IDENTITY | PK |
| `CurriculumPlanID` | int | Parent plan; nullable |
| `RequirementNumber` | int | Display/order; nullable |
| `Department` | nvarchar(50) | Requirement by department; nullable |
| `CourseID` | int | Requirement by specific course; nullable |
| `Credits` | float | Required credits; nullable |
| `GradeLevel` | nvarchar(50) | Nullable |
| `GradeType` | int | Grade-comparison type; nullable |
| `Grade` | decimal(10,3) | Minimum grade; nullable |
| `ModifiedBy` / `ModifiedDate` | int/smalldatetime | Nullable |

---

#### `dbo.CurriculumPlanStudent`
Assigns a student to a curriculum plan. PK is composite `(StudentID, CurriculumPlanID)`.

| Column | Type | Notes |
|---|---|---|
| `StudentID` | int | PK (composite) |
| `CurriculumPlanID` | int | PK (composite) |

---

#### `dbo.CurriculumPlanExemptions`
Per-student exemptions from a specific requirement, with a reason. PK is composite `(RequirementID, StudentID)`.

| Column | Type | Notes |
|---|---|---|
| `RequirementID` | int | PK (composite); → `CurriculumPlanRequirements` |
| `StudentID` | int | PK (composite) |
| `Reason` | nvarchar(max) | Exemption reason; nullable |
| `ModifiedBy` / `ModifiedDate` | int/smalldatetime | Nullable |

---

#### `dbo` curriculum-plan (ID-based) tables — cross-reference summary

| Table | Scope | Key FK targets / notes |
|---|---|---|
| `CurriculumPlans` | ID-based plan header | PK `CurriculumPlanID` |
| `CurriculumPlanRequirements` | Requirements within a plan | → `CurriculumPlans`; by dept or `CourseID` |
| `CurriculumPlanStudent` | Student ↔ plan assignment | PK `(StudentID, CurriculumPlanID)` |
| `CurriculumPlanExemptions` | Per-student requirement exemptions | PK `(RequirementID, StudentID)` |

Related (documented earlier): `dbo.CurriculumPlanCourses` (plan↔course, ID-keyed) and `dbo.CurriculumPlan` (name-keyed legacy model).

---

### `dbo` daycare billing tables

The daycare time-based billing subsystem. Rate plans, day types, and time zones (time bands) combine to compute daycare charges. Most tables carry `SchoolCode` + `DistrictWide` for scoping.

#### `dbo.DayCare_RatePlans`
Named daycare rate plan per school. Referenced by `RateID` from the other daycare tables.

| Column | Type | Notes |
|---|---|---|
| `RateID` | int IDENTITY | PK |
| `PlanNumber` | int | Nullable |
| `PlanDescription` | nvarchar(50) | Nullable |
| `SchoolCode` | varchar(50) | Nullable |
| `DistrictWide` / `Default` | bit | Scope/default flags; nullable |
| `ModifiedBy` / `ModifiedTime` | int/nvarchar(50) | Audit (`ModifiedTime` is text) |

---

#### `dbo.DayCare_DayTypes`
Daycare day-type definitions (e.g. full day, half day) per school.

| Column | Type | Notes |
|---|---|---|
| `DayCareDayID` | int IDENTITY | PK |
| `Description` | nvarchar(50) | Nullable |
| `DefaultDayType` | bit | Nullable |
| `SchoolCode` | varchar(50) | Nullable |
| `DistrictWide` | bit | Nullable |
| `ModifiedBy` / `ModifiedTime` | int/nvarchar(50) | Audit |

---

#### `dbo.DayCare_TimeZone`
Daycare time bands ("time zones") — a begin/end time window with a rate, interval, day-type, and accounting category. Note: unrelated to clock/timezone; here "TimeZone" means a billable time band.

| Column | Type | Notes |
|---|---|---|
| `TimeZoneID` | int IDENTITY | PK |
| `BeginTime` / `EndTime` | nvarchar(50) | Band window (text); nullable |
| `RateID` | int | → `DayCare_RatePlans`; nullable |
| `DayCareDayID` | int | → `DayCare_DayTypes`; nullable |
| `CapAble` | bit | Subject to capped amounts; nullable |
| `Interval` | int | Billing interval (minutes); nullable |
| `Description` | nvarchar(128) | Nullable |
| `CatID` / `AccountingSystemid` | int | Accounting mapping; nullable |
| `SchoolCode` / `DistrictWide` | varchar/bit | Scope |
| `ModifiedBy` / `ModifiedTime` | int/nvarchar(50) | Audit |

---

#### `dbo.DayCare_TimeZoneRates`
Rate amounts per time band × rate plan — per-interval or per-hour pricing. PK is composite `(TimeZoneID, RateID)`.

| Column | Type | Notes |
|---|---|---|
| `TimeZoneID` | int | PK (composite); → `DayCare_TimeZone` |
| `RateID` | int | PK (composite); → `DayCare_RatePlans` |
| `AmountPerInterval` / `AmountPerHour` | real | Pricing; nullable |
| `AmountType` | int | Which pricing applies; nullable |
| `ModifiedBy` / `ModifiedTime` | int/nvarchar(50) | Audit |

---

#### `dbo.DayCare_CappedAmounts`
Caps on daycare charges within a min/max amount band, tied to a rate plan.

| Column | Type | Notes |
|---|---|---|
| `CappedID` | int IDENTITY | PK |
| `BeginAmount` / `EndAmount` | real | Cap band; nullable |
| `RateID` | int | → `DayCare_RatePlans`; nullable |
| `SchoolCode` / `DistrictWide` | varchar/bit | Scope |

---

#### `dbo` daycare billing tables — cross-reference summary

| Table | Scope | Key FK targets / notes |
|---|---|---|
| `DayCare_RatePlans` | Named rate plan | Referenced by `RateID` |
| `DayCare_DayTypes` | Day-type definitions | Referenced by `DayCareDayID` |
| `DayCare_TimeZone` | Billable time bands | `DayCare_RatePlans`, `DayCare_DayTypes` |
| `DayCare_TimeZoneRates` | Per-band×plan pricing | PK `(TimeZoneID, RateID)` |
| `DayCare_CappedAmounts` | Charge caps | → `DayCare_RatePlans` |

---

### `dbo` calendar day-setup table

#### `dbo.DaySetup`
Per-school calendar day definition — one row per date per school, defining the day's type, schedule rotation, attendance behavior, instructional minutes, and optional daycare day-type. Drives the school calendar and attendance/scheduling. PK is composite `(DaySetupDate, SchoolCode)`; `DaySetupID` is a unique surrogate.

| Column | Type | Notes |
|---|---|---|
| `DaySetupDate` | datetime | PK (composite); the calendar date |
| `SchoolCode` | varchar(50) | PK (composite); indexed |
| `DaySetupID` | int IDENTITY | Unique surrogate |
| `DayTitle` | nvarchar(50) | Day label; nullable |
| `DayType` | int | Day type; default 0 |
| `ScheduleDay` | int | Schedule rotation day; default 0 |
| `BSID` | int | Bell-schedule ID; default 0 |
| `Attendance` | int | Attendance behavior; nullable |
| `LastPeriodForAttendance` | int | Default 0 |
| `InstructionalMinutes` | smallint | Default 0 |
| `DayCareDayID` | int | → `DayCare_DayTypes`; nullable |
| `ModifiedBy` / `ModifiedDate` | int/smalldatetime | Audit |

**Practical note**: `InstructionalMinutes` and `Attendance`/`LastPeriodForAttendance` here feed instructional-time and day-attendance reporting. When a school's calendar or membership/attendance-day counts look wrong, `DaySetup` is the per-day source of truth.

---

### `dbo` scheduling, defined-lists, accounting-deposit, discipline, donation, and email tables

A mixed batch spanning the `D`–`E` range.

#### `dbo.DaySetupTemplate`
Template version of `dbo.DaySetup` — defines a reusable calendar-day pattern (schedule day, title, last attendance period) keyed by template + date. Applied to produce `DaySetup` rows. PK is composite `(TemplateID, Date)`.

| Column | Type | Notes |
|---|---|---|
| `TemplateID` | int | PK (composite) |
| `Date` | smalldatetime | PK (composite) |
| `ScheduleDay` | int | Default 0 |
| `DayTitle` | nvarchar(50) | Nullable |
| `LastPeriodForAttendance` | int | Nullable |

---

#### `dbo.DefaultRequests`
Default course requests per grade level/school — courses auto-requested for a grade. PK is composite `(CourseID, GradeLevel, SchoolCode)`. FK-validated against the **newer** course table (`crse.CourseCore`) and `dbo.GradeLevels`.

| Column | Type | Notes |
|---|---|---|
| `CourseID` | int | PK (composite); FK → `crse.CourseCore` |
| `GradeLevel` | nvarchar(50) | PK (composite); FK → `dbo.GradeLevels` (with `SchoolCode`) |
| `SchoolCode` | varchar(50) | PK (composite); indexed |
| `ModifiedBy` / `ModifiedDate` | int/smalldatetime | Nullable |

Note: this table's FK points to `crse.CourseCore`, confirming the current master-course entity (vs. legacy `dbo.Courses_was`).

---

#### `dbo.DefinedLists`
**User-defined list / dropdown definitions** — the backbone of configurable lookup lists throughout the app (and the FK target for `dbo.ConfigSchool.GovernanceDefinedListID`). Each row is a list entry identified by `DLID`, categorized by `Type`, scoped by `SchoolCode`. Referenced in the skill's Core FACTS tables area as a configuration source.

| Column | Type | Notes |
|---|---|---|
| `DLID` | int IDENTITY | PK; the value other tables FK to |
| `Name` | nvarchar(256) | List entry name; indexed |
| `Type` | nvarchar(64) | List category; indexed |
| `SchoolCode` | varchar(50) | Indexed; nullable |
| `DefaultField` | bit | Default-entry flag; default 0 |
| `SortOrder` | tinyint | Default 0 |
| `ModifiedBy` / `ModifiedDate` | int/smalldatetime | Nullable |

**Practical note**: when a report needs to translate a stored `DLID` into a readable label, join to `DefinedLists` on `DLID`; filter by `Type` to scope to the right list.

---

#### `dbo.Deposit`
Bank deposit batch record — groups payments into a deposit for reconciliation, with bank, amount, date, and QuickBooks/PayEasy integration refs.

| Column | Type | Notes |
|---|---|---|
| `DepositID` | int IDENTITY | PK |
| `Deposit` | nvarchar(50) | Deposit name/label; nullable |
| `Amount` | money | Nullable |
| `Date` | smalldatetime | Nullable |
| `SchoolCode` | varchar(50) | Nullable |
| `BankID` | int | → `dbo.Bank`; nullable |
| `Number` | int | Deposit number; nullable |
| `Closed` | bit | Nullable |
| `Posted` / `SessionID` / `PayEasyNowID` | nvarchar(50) | Posting/session refs; nullable |
| `QB_DepositID` / `SyncId` / `QBPosted` / `BalanceTransfer` | mixed | QuickBooks/sync refs; nullable |

---

#### `dbo.Discipline`
Student discipline incident record — incident description, violation, up to two sanctions (with dates and end dates), demerits, status, and reporter/reviewer. Relevant to conduct/discipline reports.

| Column | Type | Notes |
|---|---|---|
| `DisciplineID` | int IDENTITY | PK (non-clustered) |
| `StudentID` | int | Indexed; default 0 |
| `StaffID` | int | Nullable |
| `DateofIncident` | datetime | Nullable |
| `DescriptionOfIncident` / `History` | nvarchar(max) | Nullable |
| `Violation` | nvarchar(256) | Nullable |
| `Sanction1` / `Sanction2` | nvarchar(256) | Nullable |
| `SanctionDate1` / `SanctionDate2` | datetime | Nullable |
| `SanctionEndDate1` / `SanctionEndDate2` | datetime2(2) | Nullable |
| `Demerits` | real | Default 0 |
| `Level` / `Type` | int | Classification; nullable |
| `Status` | nvarchar(128) | Nullable |
| `ReportedBy` / `ReviewedBy` | nvarchar(50) | Nullable |
| `Notified` | bit | Default 0 |
| `StateSanctionID` | int | State reporting; nullable |
| `ModifiedBy` / `ModifiedDate` | int/smalldatetime | Audit |

---

#### `dbo.DisciplineMemorized`
Saved/"memorized" violation→sanction presets per school — quick-fill defaults for the discipline form. PK is composite `(Violation, SchoolCode)`.

| Column | Type | Notes |
|---|---|---|
| `Violation` | nvarchar(255) | PK (composite) |
| `SchoolCode` | varchar(50) | PK (composite) |
| `Sanction` | nvarchar(255) | Preset sanction; nullable |
| `Status` | nvarchar(50) | Nullable |
| `Demerits` | real | Nullable |
| `Level` / `Type` | int | Nullable |
| `ModifiedBy` / `ModifiedDate` | int/smalldatetime | Nullable |

---

#### `dbo.DonateOnLineCampaigns`
Online donation campaigns per school — title, message, goal/raised, graphic, and DonorConnect integration refs.

| Column | Type | Notes |
|---|---|---|
| `CampaignID` | int IDENTITY | PK |
| `SchoolCode` | varchar(50) | Nullable |
| `Title` / `Headline` | nvarchar(128) | Nullable |
| `Message` | nvarchar(max) | Nullable |
| `Active` | bit | Nullable |
| `Graphic` | nvarchar(128) | Nullable |
| `Goal` / `AmountRaised` | nvarchar(50) | Stored as text; nullable |
| `SortOrder` | int | Nullable |
| `DonorConnectEffortID` / `DonorConnectFundID` | int | Integration refs; nullable |

---

#### `dbo.DonateOnlineConfiguration`
Per-school online-donation page configuration — contact, message, graphics, and stylesheet. PK `SchoolCode`.

| Column | Type | Notes |
|---|---|---|
| `SchoolCode` | varchar(50) | PK |
| `ContactEmail` | nvarchar(256) | Nullable |
| `Message` | nvarchar(max) | Nullable |
| `Headline` | nvarchar(128) | Nullable |
| `BannerGraphic` / `TopGraphic` / `LeftGraphic` / `RightGraphic` | varchar(50) | Nullable |
| `MessageGraphic` | nvarchar(128) | Nullable |
| `StyleSheet` | varchar(max) | Nullable |

---

#### `dbo.Email_Attachment`
Attachment for an outbound email message. CASCADE deletes/updates from `dbo.Email_Message`.

| Column | Type | Notes |
|---|---|---|
| `AID` | int IDENTITY | PK |
| `A_MID` | int | FK → `dbo.Email_Message` (CASCADE delete & update) |
| `A_Name` | varchar(512) | Display name; nullable |
| `A_FileName` | varchar(512) | Stored file name; required |
| `SessionID` | varchar(50) | Nullable |

---

#### `dbo.Email_ErrorLog`
Per-message email error log. PK `MID` (one error row per message).

| Column | Type | Notes |
|---|---|---|
| `MID` | int | PK; the email message ID |
| `Description` | varchar(256) | Error text; nullable |
| `SessionID` | varchar(50) | Nullable |

Note: both `Email_Attachment` and `Email_ErrorLog` reference `dbo.Email_Message` (the email message header, not yet documented — its DDL will get a full entry when provided).

---

#### `dbo` D–E mixed batch — cross-reference summary

| Table | Scope | Key FK targets / notes |
|---|---|---|
| `DaySetupTemplate` | Reusable calendar-day pattern | Template for `DaySetup`; PK `(TemplateID, Date)` |
| `DefaultRequests` | Default course requests per grade | `crse.CourseCore`, `dbo.GradeLevels` |
| `DefinedLists` | User-defined list/dropdown definitions | `DLID` is FK target (e.g. `ConfigSchool`); join to resolve labels |
| `Deposit` | Bank deposit batch | `dbo.Bank`; QuickBooks/PayEasy refs |
| `Discipline` | Student discipline incident | `StudentID`; conduct reports |
| `DisciplineMemorized` | Violation→sanction presets | PK `(Violation, SchoolCode)` |
| `DonateOnLineCampaigns` | Online donation campaigns | DonorConnect refs |
| `DonateOnlineConfiguration` | Donation-page config | PK `SchoolCode` |
| `Email_Attachment` | Email attachment | CASCADE from `dbo.Email_Message` |
| `Email_ErrorLog` | Per-message email error | → `dbo.Email_Message` |

---

### `dbo` email engine, email defaults, emergency-contact, and enrollment tables

> **Naming caution — two distinct email table families.** The **`Email_*`** tables (underscore: `Email_Message`, `Email_MessageText`, `Email_Recipient`, `Email_Attachment`, `Email_ErrorLog`) are the **mail-delivery engine** — the queue of actual outbound messages and their recipients/attachments/errors. The **`Email*`** tables (no underscore: `EmailMessage`, `EmailRecipient`, `EmailAttachment`) are tiny **per-staff "default" stores** (a staff member's saved default message text / recipient / attachment). They are unrelated; don't join across the two families.

#### `dbo.Email_Message`
Mail-engine message header — one row per outbound email, with district scope, sender, subject, queue/delivery timestamps, processing metadata, and status. The parent of `Email_MessageText`, `Email_Recipient`, `Email_Attachment`, and `Email_ErrorLog`.

| Column | Type | Notes |
|---|---|---|
| `MID` | int IDENTITY | PK; referenced by all child `Email_*` tables |
| `M_DistrictCode` | varchar(32) | Required; indexed |
| `M_Status` | varchar(32) | Queue status; indexed |
| `M_Priority` | int | Nullable |
| `M_StaffID` | int | Sender staff; indexed |
| `M_From` / `M_FromName` | varchar/nvarchar | Sender address/name |
| `M_Subject` | nvarchar(1204) | Subject (*sic* length 1204) |
| `M_NumRcpts` | int | Recipient count |
| `M_IsHTML` | bit | HTML flag |
| `M_DateQueued` / `M_DateDelivered` / `M_DateCompleted` | datetime | Lifecycle timestamps; `M_DateQueued` indexed |
| `M_NumMinutesInQueue` | float | Queue duration |
| `M_ProcessedByThread` / `M_ProcessedOnServerNum` / `server` | mixed | Processing metadata |
| `M_DeliveryReport` / `M_MailProcessorReport` | varchar | Delivery/processor output |
| `M_GenerateReceivedLink` | bit | Default 1 |
| `SessionID` | varchar(50) | Nullable |

---

#### `dbo.Email_MessageText`
The body text for an `Email_Message` (separated from the header). PK `MID`; CASCADE from `Email_Message`.

| Column | Type | Notes |
|---|---|---|
| `MID` | int | PK; FK → `dbo.Email_Message` (CASCADE delete & update) |
| `M_Message` | nvarchar(max) | Email body; nullable |

---

#### `dbo.Email_Recipient`
A recipient of an `Email_Message`, with per-recipient delivery/read tracking. CASCADE from `Email_Message`.

| Column | Type | Notes |
|---|---|---|
| `RID` | int IDENTITY | PK |
| `R_MID` | int | FK → `dbo.Email_Message` (CASCADE); indexed |
| `R_Email` | nvarchar(256) | Recipient address; nullable |
| `R_Received` / `R_CouldNotSend` | bit | Delivery status; nullable |
| `R_DateReceived` | datetime | Defaults to `GETDATE()` |
| `R_EmailAccessedCount` | int | Open/access count; nullable |
| `SessionID` | varchar(50) | Indexed; nullable |

---

#### `dbo.Email_Attachment` (cross-reference)
Documented in the previous batch — attachment for an `Email_Message` (CASCADE from `MID`). Listed here for completeness of the `Email_*` family.

#### `dbo.Email_ErrorLog` (cross-reference)
Documented in the previous batch — per-message error log keyed by `MID`.

---

#### `dbo.EmailMessage`
**Per-staff default email body** (no underscore — not part of the mail engine). One row per staff member holding their saved default message text. PK `StaffID`.

| Column | Type | Notes |
|---|---|---|
| `StaffID` | int | PK |
| `EmailMessage` | nvarchar(max) | Saved default message; nullable |

---

#### `dbo.EmailRecipient`
Per-staff saved default recipient address(es) (no underscore). Surrogate PK `AutoNum`.

| Column | Type | Notes |
|---|---|---|
| `AutoNum` | int IDENTITY | PK |
| `StaffID` | int | Indexed; nullable |
| `EmailRecipient` | nvarchar(256) | Saved recipient; nullable |

---

#### `dbo.EmailAttachment`
Per-staff saved default attachment (no underscore). Surrogate PK `AutoNum`.

| Column | Type | Notes |
|---|---|---|
| `AutoNum` | int IDENTITY | PK |
| `StaffID` | int | Indexed; nullable |
| `Attachment` | nvarchar(256) | Saved attachment path; nullable |

---

#### `dbo.EmailReports`
Log of report files queued/sent by email, by session, with the report path(s). Surrogate PK.

| Column | Type | Notes |
|---|---|---|
| `EmailReportsID` | int IDENTITY | PK |
| `SessionID` | varchar(50) | Indexed; nullable |
| `ReportPath` | varchar(8000) | Report file path(s); nullable |
| `Date` | smalldatetime | Indexed; nullable |

---

#### `dbo.EmergencyContact`
**Emergency contact / non-parent contact for a student** — name, phones, email, relationship, and a portal sort order. In the skill's Core FACTS tables (family/parent linkage). Links to a contact address in the `rw` schema.

| Column | Type | Notes |
|---|---|---|
| `EmergencyContactID` | int IDENTITY | PK |
| `StudentID` | int | Indexed; nullable |
| `FirstName` / `MiddleName` | nvarchar(64) | Nullable |
| `LastName` | nvarchar(128) | Nullable |
| `Salutation` / `Suffix` | nvarchar(50) | Nullable |
| `Relationship` | nvarchar(256) | Relationship to student; nullable |
| `HomePhone` / `CellPhone` | nvarchar(50) | Nullable |
| `WorkPhone` | nvarchar(128) | Nullable |
| `CountryCode` | nvarchar(50) | Phone country code; nullable |
| `Email` | nvarchar(256) | Nullable |
| `Note` | nvarchar(2000) | Nullable |
| `SortOrder` / `PortalSortOrder` | int | Ordering; `PortalSortOrder` defaults to 1000; `SortOrder` indexed |
| `RefID` | int | Reference; nullable |
| `ContactAddressID` | int | FK → `rw.ContactAddress`; nullable |
| `LegacyPersonID` | nvarchar(50) | Unique when not null; legacy linkage |

---

#### `dbo.Enrollment_Log`
**Enrollment status change log** per student — append-style record of status transitions with date, grade level, year, and both user-facing `Status` and `SystemStatus`. Temporal table. Heavily indexed (student, status, date, systemstatus). Key source for enrollment/withdrawal reporting.

| Column | Type | Notes |
|---|---|---|
| `LogID` | int IDENTITY | PK |
| `StudentID` | int | Required; indexed |
| `Status` | nvarchar(50) | Required; user-facing status; indexed |
| `SystemStatus` | nvarchar(50) | Internal status; indexed; nullable |
| `Date` | datetime | Required; indexed |
| `GradeLevel` | varchar(50) | Nullable |
| `Yearid` | int | Nullable |
| `SchoolCode` | varchar(50) | Nullable |
| `Notes` | nvarchar(50) | Nullable |
| `CreatedOnUTC` / `ModifiedOnUTC` / `ModifiedOnUTCmax` | datetime2(2) | Temporal versioning |
| `ModifiedBy` / `ModifiedDate` | int/datetime | Audit |

---

#### `dbo.EnrollmentHistory`
Enrollment spans per student — begin/end dates for an enrollment status within a year/grade/school. Where `Enrollment_Log` records point-in-time transitions, this records the resulting date ranges.

| Column | Type | Notes |
|---|---|---|
| `ID` | int IDENTITY | PK |
| `StudentID` | int | Indexed; nullable |
| `Status` | nvarchar(50) | Nullable |
| `BeginDate` / `EndDate` | smalldatetime | Enrollment span; `BeginDate` indexed |
| `GradeLevel` | nvarchar(50) | Nullable |
| `YearID` | int | Indexed; nullable |
| `SchoolCode` | varchar(50) | Nullable |
| `Note` | nvarchar(50) | Nullable |

---

#### `dbo` email / emergency-contact / enrollment tables — cross-reference summary

| Table | Scope | Key FK targets / notes |
|---|---|---|
| `Email_Message` | Mail-engine message header | Parent of all `Email_*` children |
| `Email_MessageText` | Mail-engine message body | CASCADE from `Email_Message` |
| `Email_Recipient` | Mail-engine recipient + tracking | CASCADE from `Email_Message` |
| `Email_Attachment` | Mail-engine attachment | CASCADE from `Email_Message` (prev. batch) |
| `Email_ErrorLog` | Mail-engine per-message error | → `Email_Message` (prev. batch) |
| `EmailMessage` | Per-staff default body | **No underscore — not the engine**; PK `StaffID` |
| `EmailRecipient` | Per-staff default recipient | No underscore |
| `EmailAttachment` | Per-staff default attachment | No underscore |
| `EmailReports` | Emailed-report log | By `SessionID` |
| `EmergencyContact` | Student emergency/non-parent contact | `rw.ContactAddress`; Core FACTS table |
| `Enrollment_Log` | Enrollment status-change log | Temporal; `Status` + `SystemStatus` |
| `EnrollmentHistory` | Enrollment date-range spans | Begin/end per year/grade |

---

### `dbo` enrollment-stats, faculty-group, family, fiscal, and gradebook-core tables

#### `dbo.EnrollmentStatistics`
Precomputed enrollment counts by school/year/as-of-date/grade level, sliced by a filter dimension. PK is the full composite `(SchoolCode, YearID, AsOfDate, GradeLevel, FilterType, FilterValue)`. FKs to `ConfigSchool` and `SchoolYear`. A reporting rollup table.

| Column | Type | Notes |
|---|---|---|
| `SchoolCode` | varchar(50) | PK; FK → `dbo.ConfigSchool` |
| `YearID` | int | PK; FK → `dbo.SchoolYear` |
| `AsOfDate` | smalldatetime | PK; snapshot date |
| `GradeLevel` | nvarchar(50) | PK |
| `FilterType` | nvarchar(50) | PK; dimension name (e.g. gender, ethnicity) |
| `FilterValue` | nvarchar(50) | PK; dimension value |
| `Enrollment` | int | Count; nullable |

---

#### `dbo.FacultyGroups`
A named faculty group for a year. Header for `FacultyGroupStaff` and `FacultyGroupClasses`.

| Column | Type | Notes |
|---|---|---|
| `GroupID` | int IDENTITY | PK |
| `GroupName` | nvarchar(50) | Nullable |
| `YearID` | int | Nullable |

---

#### `dbo.FacultyGroupStaff`
Staff members in a faculty group, with a per-member user level. PK is composite `(GroupID, StaffID)`.

| Column | Type | Notes |
|---|---|---|
| `GroupID` | int | PK (composite) |
| `StaffID` | int | PK (composite) |
| `UserLevel` | int | Permission level within group; nullable |

---

#### `dbo.FacultyGroupClasses`
Classes associated with a faculty group. PK is composite `(GroupID, ClassID)`.

| Column | Type | Notes |
|---|---|---|
| `GroupID` | int | PK (composite) |
| `ClassID` | int | PK (composite) |

---

#### `dbo.FamilyConfig`
**The family record** — one row per family (`FamilyID`), with names, contact, web/directory/accounting flags, and FACTS-integration linkage. A core entity for family-scoped reporting (statements, directories). **Two triggers sync the family `Note` into `rw.FamilyNote`.** Also the table whose `FactsUpdateState` flag is set by the `dbo.Address` trigger (see `Address`) to mark families dirty for FACTS sync.

| Column | Type | Notes |
|---|---|---|
| `FamilyID` | int IDENTITY | PK |
| `FamilyName` | nvarchar(255) | Indexed; primary family name |
| `FamilyName2` / `FamilyNameBP` | nvarchar | Alternate family names |
| `FamilyLetter` | nvarchar(255) | Salutation/letter name |
| `FamilyCode` | nvarchar(128) | External family code |
| `FamilyEmail` | nvarchar(256) | Nullable |
| `StandardFamily` / `EnableWeb` / `Accounting` | bit | Type/feature flags (`Accounting` default 1) |
| `Unlisted` / `Directory` | int | Directory visibility; nullable |
| `AccountingCode` | nvarchar(256) | Nullable |
| `Note` | nvarchar(max) | Family note — **synced to `rw.FamilyNote` via triggers** |
| `ParentsWebFinancialBlock` | bit | Blocks portal financials; default 0 |
| `FactsCustomerPersonId` | int | FK → `dbo.Person`; indexed; FACTS customer linkage |
| `FactsUpdateState` | int | FACTS sync dirty-state; default 1 (set by `Address` trigger) |
| `ModifiedBy` / `ModifiedDate` | int/smalldatetime | Audit |

**Triggers**:
- `TR_dbo_FamilyConfig_Insert` (AFTER INSERT): if the new row has a non-empty `Note`, inserts a corresponding desktop note row into `rw.FamilyNote`.
- `TR_dbo_FamilyConfig_Update` (AFTER UPDATE): keeps the `rw.FamilyNote` desktop note in sync — deletes it when the note is cleared, updates it when changed, inserts it when newly added. (Contains commented-out `Context_Info` circular-trigger guards.)

So the canonical family note lives in `FamilyConfig.Note`, mirrored into `rw.FamilyNote` (where `IsDesktopNote = 1`) for the reporting/web layer.

---

#### `dbo.FinanceNotes`
Per-family (and optionally per-student) finance notes, with a flag to show the note on statements. Surrogate PK `NoteID`.

| Column | Type | Notes |
|---|---|---|
| `NoteID` | int IDENTITY | PK (non-clustered) |
| `FamilyID` | int | Default 0 |
| `StudentID` | int | Nullable |
| `Date` | datetime | Nullable |
| `Note` | nvarchar(max) | Nullable |
| `ShowOnStatement` | bit | Whether it prints on the family statement; nullable |
| `SchoolCode` | varchar(50) | Nullable |
| `AccountingSystemID` | int | Nullable |
| `ModifiedBy` / `ModifiedDate` | int/smalldatetime | Audit |

---

#### `dbo.FiscalYear`
Accounting fiscal-year definition per school — name and date range, with a portal-block flag. Temporal table. Referenced widely by accounting tables via `FiscalYearID`.

| Column | Type | Notes |
|---|---|---|
| `FiscalYearID` | int IDENTITY | PK |
| `FiscalYearName` | nvarchar(50) | Nullable |
| `BeginDate` / `EndDate` | smalldatetime | Fiscal year span; nullable |
| `SchoolCode` | varchar(50) | Nullable |
| `BlockParentsWeb` | bit | Nullable |
| `CreatedOnUTC` / `ModifiedOnUTC` / `ModifiedOnUTCmax` | datetime2(2) | Temporal versioning |
| `ModifiedBy` / `ModifiedDate` | int/smalldatetime | Audit |

---

### `dbo` gradebook core tables

The gradebook (`Gbk*`) subsystem. `GbkAssessments` are the weighted categories within a class; `GbkAssignments` are the individual assignments within a category. Together with `ClassGradeCalculation`/`CourseLevel` weights, these drive computed grades on report cards and progress reports.

#### `dbo.GbkAliases`
Per-class display alias for a student in the gradebook (e.g. anonymized name). PK is composite `(ClassID, StudentID)`.

| Column | Type | Notes |
|---|---|---|
| `ClassID` | int | PK (composite); default 0 |
| `StudentID` | int | PK (composite); default 0 |
| `Alias` | nvarchar(50) | Display alias; nullable |
| `ModifiedBy` / `ModifiedDate` | int/smalldatetime | Nullable |

---

#### `dbo.GbkAssessments`
**Gradebook assessment categories** within a class (e.g. Tests, Homework, Quizzes) — the weighted buckets that assignments belong to. Weight, drop-lowest count, per-term applicability, and color. Unique on `(AssessmentID, ClassID)`.

| Column | Type | Notes |
|---|---|---|
| `GbkAssessmentID` | int IDENTITY | PK |
| `AssessmentID` | int | Category id within class; default 0; unique with `ClassID` |
| `ClassID` | int | Indexed; default 0 |
| `Title` | nvarchar(50) | Category name; indexed |
| `Description` | nvarchar(100) | Nullable |
| `Weight` | real | Category weight; default 0 |
| `Drop` | smallint | Drop N lowest scores; default 0 |
| `Term1`–`Term6` | bit | Which terms the category applies to; nullable |
| `ColorHexHTML` | char(7) | Display color; nullable |
| `ModifiedBy` / `ModifiedDate` | int/smalldatetime | Audit |

---

#### `dbo.GbkAssignments`
**Individual gradebook assignments** within an assessment category — points, weight, dates, publish/calculate flags, LMS linkage, and standards-mastery exclusion. Temporal table. The PK is composite `(AssessmentID, ClassID, AssignmentID)`; `GbkAssignmentID` is a unique surrogate. Scores live in a separate grades table (e.g. `GbkAssignmentGrades`/`SS_*`, not yet documented).

| Column group | Type | Notes |
|---|---|---|
| `AssessmentID` | int | PK (composite); the category (→ `GbkAssessments.AssessmentID`) |
| `ClassID` | int | PK (composite); indexed |
| `AssignmentID` | int | PK (composite); assignment id within class |
| `GbkAssignmentID` | int IDENTITY | Unique surrogate |
| `Title` | nvarchar(50) | Indexed |
| `Description` / `DescriptionHTML` | nvarchar(max) | Body |
| `AssignmentNumber` | int | Display order; default 0 |
| `MaxPoints` | real | Points possible; default 0; indexed |
| `Weight` | real | Assignment weight; default 0 |
| `DateAssigned` / `DateDue` | datetime | Local dates; indexed |
| `DateAssignedUtc` / `DateDueUtc` | smalldatetime | UTC dates |
| `Publish` / `Calculate` | bit | Visible to portal / counts toward grade; indexed |
| `Test` | bit | Marked as a test; default 0 |
| `ECType` | int | Extra-credit type; default 0 |
| `SkillID` | int | Linked skill; default 0 |
| `ObjectiveList` | nvarchar(255) | Linked objectives (CSV) |
| `ExcludeFromStandardMasteryCalculation` | bit | SBG exclusion; default 0 |
| `MoodleID` / `MoodleAssignmentType` / `GoogleAssignmentId` / `LMSAssignment` / `SystemOfRecord` | mixed | LMS integration; `SystemOfRecord` default 1 |
| `ItemID` | int | FK → `lms.Item`; indexed |
| `ItemTypeID` | int | FK → `lms.ItemType` |
| `CreatedOnUTC` / `ModifiedOnUTC` / `ModifiedOnUTCmax` | datetime2(2) | Temporal versioning |
| `ModifiedBy` / `ModifiedDate` | int/smalldatetime | Audit |

**Practical note**: only assignments with `Calculate = 1` count toward the computed grade; `Publish = 1` controls portal visibility. The `(AssessmentID, ClassID)` pair joins each assignment to its `GbkAssessments` category and that category's weight.

---

#### `dbo` enrollment-stats / faculty-group / family / fiscal / gradebook-core — cross-reference summary

| Table | Scope | Key FK targets / notes |
|---|---|---|
| `EnrollmentStatistics` | Precomputed enrollment counts | `ConfigSchool`, `SchoolYear`; full composite PK |
| `FacultyGroups` | Named faculty group | Header for staff/class links |
| `FacultyGroupStaff` | Faculty group ↔ staff (+user level) | PK `(GroupID, StaffID)` |
| `FacultyGroupClasses` | Faculty group ↔ class | PK `(GroupID, ClassID)` |
| `FamilyConfig` | Family record | `dbo.Person`; 2 triggers sync `Note` → `rw.FamilyNote`; `FactsUpdateState` |
| `FinanceNotes` | Family/student finance notes | `ShowOnStatement` flag |
| `FiscalYear` | Accounting fiscal year | Temporal; referenced by `FiscalYearID` |
| `GbkAliases` | Per-class student display alias | PK `(ClassID, StudentID)` |
| `GbkAssessments` | Gradebook categories (weighted) | Unique `(AssessmentID, ClassID)` |
| `GbkAssignments` | Gradebook assignments | Temporal; `lms.Item`/`lms.ItemType`; `Calculate`/`Publish` flags |

---

### `dbo` gradebook grades, summary, lesson-plan & homework tables

This batch completes the gradebook grade chain: **`GbkGrades`** holds the per-student per-assignment scores (the table flagged as missing last batch), and **`GbkSummary`** holds the computed per-category/term rollup that report cards and progress reports read.

#### `dbo.GbkGrades`
**The individual student score for a gradebook assignment** — one row per student × assignment, with received/curve/penalty/bonus points and status. Temporal table. PK is composite `(AssessmentID, ClassID, StudentID, AssignmentID)`; FK to `dbo.GbkAssignments` on `(AssessmentID, ClassID, AssignmentID)`. **Clustered on `StudentID`** (per-student grade retrieval is the hot path).

| Column | Type | Notes |
|---|---|---|
| `AssessmentID` | int | PK; category (with class/assignment → `GbkAssignments`) |
| `ClassID` | int | PK |
| `StudentID` | int | PK; **clustered index** |
| `AssignmentID` | int | PK; default 0 |
| `GbkGradeID` | int IDENTITY | Unique surrogate |
| `MaxPoints` | real | Points possible (snapshot); default 0 |
| `ReceivedPoints` | real | Points earned; default 0; indexed |
| `CurvePoints` / `PenaltyPoints` / `BonusPoints` | real | Adjustments; default 0 |
| `Weight` | real | Per-grade weight; default 0 |
| `Status` | nvarchar(50) | Grade status; default 'V' (same code family as `GbkCodeTranslation.StatusCode`) |
| `DisplayGrade` | nvarchar(50) | Displayed grade string; nullable |
| `Notes` | nvarchar(4000) | Nullable |
| `EmailSent` | bit | Notification flag; nullable |
| `ItemStatusID` | int | FK → `lms.ItemStatus`; default 4 |
| `MigratedItemID` / `MigratedItemGradeID` | int | LMS migration refs; nullable |
| `CreatedDate` / `LastModifiedDate` | smalldatetime | Legacy audit |
| `CreatedOnUTC` / `ModifiedOnUTC` / `ModifiedOnUTCmax` | datetime2(2) | Temporal versioning |
| `ModifiedBy` / `ModifiedDate` | int/smalldatetime | Audit |

**Practical note**: the effective score is `ReceivedPoints + CurvePoints + BonusPoints − PenaltyPoints` over `MaxPoints`, subject to `Status` (e.g. exempt/missing). Join `(AssessmentID, ClassID, AssignmentID)` to `GbkAssignments` for assignment metadata and to `GbkAssessments` for the category weight.

---

#### `dbo.GbkCodeTranslation`
Per-class letter-code → percentage translation with exempt flag and status code — the class-level counterpart to `CourseLevelCodeTranslation`. CASCADE from `dbo.Classes`. Unique on `(ClassID, LetterCode)`.

| Column | Type | Notes |
|---|---|---|
| `GbkCodeTranslationId` | int IDENTITY | PK |
| `ClassID` | int | FK → `dbo.Classes` (CASCADE); unique with `LetterCode` |
| `LetterCode` | nvarchar(50) | The mark being translated |
| `Percent` | decimal(9,4) | Numeric equivalent; default 0 |
| `Exempt` | bit | Treat as exempt (excluded from average); default 0 |
| `StatusCode` | char(1) | Default 'V'; CHECK ∈ {M, I, P, A, E, D, V} (same set as `CourseLevelCodeTranslation`) |

---

#### `dbo.GbkGradeTranslation`
Per-class grade-string → numeric average mapping (for GPA/computed averages). The class-level counterpart to `CourseLevelGradeTranslation`. PK is composite `(ClassID, Grade)`.

| Column | Type | Notes |
|---|---|---|
| `ClassID` | int | PK (composite); default 0; indexed |
| `Grade` | nvarchar(50) | PK (composite); grade string |
| `Avg` | real | Numeric value; default 0; indexed |
| `ModifiedBy` / `ModifiedDate` | int/smalldatetime | Nullable |

---

#### `dbo.GbkSummary`
**Computed gradebook summary** — per student × class × assessment-category × term, the rolled-up average, letter grade, and points. **This is what report cards and progress reports read for the gradebook grade.** A special `AssessmentID = -1` row represents the overall class grade (the trigger references it for predicted-grade loading). PK is composite `(ClassId, StudentID, AssessmentID, TermID)`.

| Column | Type | Notes |
|---|---|---|
| `ClassId` | int | PK (composite); indexed |
| `StudentID` | int | PK (composite); indexed |
| `AssessmentID` | int | PK (composite); category, or **-1 for the overall class grade**; indexed |
| `TermID` | int | PK (composite); indexed |
| `Average` | nvarchar(50) | Displayed average; nullable |
| `FullAverage` | real | Unrounded numeric average; nullable |
| `LetterGrade` | nvarchar(50) | Letter grade; nullable |
| `PointsEarned` / `PointsPossible` | real | Totals; nullable |
| `ExtraCredit` | real | Nullable |
| `DecimalPlaces` | int | Display precision; nullable |
| `ModifiedBy` / `ModifiedDate` | int/smalldatetime | Audit |

**Trigger** `tr_GbkSummary_U` (INSERT, UPDATE): **currently a no-op** — its body (a cursor over `AssessmentID = -1` rows calling `GBK_LoadGradePredicted`) is entirely commented out and the trigger just `RETURN`s. Retained but inactive.

**Practical note**: for a student's overall class grade on a report card, read the `GbkSummary` row where `AssessmentID = -1` for the relevant `TermID`. Per-category breakdowns use the real `AssessmentID` values.

---

#### `dbo.GbkSummary_Test`
Identical structure to `dbo.GbkSummary` (same columns and composite PK) but **no trigger** — a scratch/QA copy used for testing summary calculations. Not a live reporting source; don't read from it for production reports.

| Column | Type | Notes |
|---|---|---|
| (same as `GbkSummary`) | | PK `(ClassId, StudentID, AssessmentID, TermID)`; no trigger |

---

#### `dbo.GbkHomework`
Per-class daily homework text (plain + HTML), keyed by class + plan date. PK is composite `(ClassID, PlanDate)`; `AutoNum` is a unique surrogate.

| Column | Type | Notes |
|---|---|---|
| `ClassID` | int | PK (composite); indexed |
| `PlanDate` | datetime | PK (composite); indexed |
| `AutoNum` | int IDENTITY | Unique surrogate |
| `Homework` / `HomeworkHTML` | nvarchar(max) | Homework text (plain/HTML); nullable |
| `ModifiedBy` / `ModifiedDate` | int/smalldatetime | Audit |

---

#### `dbo.GbkLessonPlan`
Per-class daily lesson plan (plain + HTML) with optional course-objective link, homework, and instruction method. Surrogate PK `AutoNum`; unique on `(ClassID, PlanDate)`.

| Column | Type | Notes |
|---|---|---|
| `AutoNum` | int IDENTITY | PK |
| `ClassID` | int | Indexed; unique with `PlanDate`; nullable |
| `PlanDate` | datetime | Indexed; nullable |
| `LessonPlan` / `LessonPlanHTML` | nvarchar(max) | Plan text (plain/HTML); nullable |
| `Homework` | nvarchar(max) | Nullable |
| `CourseObjectiveID` | int | → `dbo.CourseObjectives`; nullable |
| `InstructionMethod` | char(10) | Nullable |
| `ModifiedBy` / `ModifiedDate` | int/smalldatetime | Audit |

---

#### `dbo.GbkLessonPlanObjective`
Objectives attached to a lesson plan, with per-objective instruction method. PK is composite `(ClassID, PlanDate, ObjectiveID)`.

| Column | Type | Notes |
|---|---|---|
| `ClassID` | int | PK (composite) |
| `PlanDate` | datetime | PK (composite) |
| `ObjectiveID` | int | PK (composite) |
| `InstructionMethod` | nvarchar(4000) | Nullable |
| `ModifiedBy` / `ModifiedDate` | int/smalldatetime | Nullable |

---

#### `dbo.GbkLessonPlanWebDocument`
Web documents attached to a lesson plan. CASCADE from `dbo.WebDocuments`. PK is composite `(ClassID, PlanDate, DocumentID)`.

| Column | Type | Notes |
|---|---|---|
| `ClassID` | int | PK (composite) |
| `PlanDate` | datetime | PK (composite) |
| `DocumentID` | int | PK (composite); FK → `dbo.WebDocuments` (CASCADE; note target col misspelled `DocumnetID`) |

---

#### `dbo.GbkObjective`
Objectives evaluated by a specific gradebook assignment, with evaluation method. PK is composite `(ClassID, AssessmentID, AssignmentID, ObjectiveID)`.

| Column | Type | Notes |
|---|---|---|
| `ClassID` | int | PK (composite) |
| `AssessmentID` | int | PK (composite) |
| `AssignmentID` | int | PK (composite) |
| `ObjectiveID` | int | PK (composite) |
| `EvaluationMethod` | nvarchar(50) | Nullable |
| `ModifiedBy` / `ModifiedDate` | int/smalldatetime | Nullable |

---

#### `dbo` gradebook grades / summary / lesson-plan — cross-reference summary

| Table | Scope | Key FK targets / notes |
|---|---|---|
| `GbkGrades` | Per-student assignment score | Temporal; → `GbkAssignments`, `lms.ItemStatus`; clustered on `StudentID` |
| `GbkCodeTranslation` | Per-class letter→percent + exempt | CASCADE from `Classes`; `StatusCode` CHECK {M,I,P,A,E,D,V} |
| `GbkGradeTranslation` | Per-class grade→numeric avg | PK `(ClassID, Grade)` |
| `GbkSummary` | **Computed grade rollup** (report-card source) | `AssessmentID = -1` = overall class grade; trigger is a no-op |
| `GbkSummary_Test` | QA copy of `GbkSummary` | No trigger; **not for production reports** |
| `GbkHomework` | Per-class daily homework | PK `(ClassID, PlanDate)` |
| `GbkLessonPlan` | Per-class daily lesson plan | → `CourseObjectives`; unique `(ClassID, PlanDate)` |
| `GbkLessonPlanObjective` | Objectives on a lesson plan | PK `(ClassID, PlanDate, ObjectiveID)` |
| `GbkLessonPlanWebDocument` | Web docs on a lesson plan | CASCADE from `WebDocuments` |
| `GbkObjective` | Objectives evaluated by an assignment | PK `(ClassID, AssessmentID, AssignmentID, ObjectiveID)` |

---

### `dbo` gradebook-transfer, grade-calculator, grade-config, grade-levels, and honor-roll tables

#### `dbo.GbkTransfer`
Maps a gradebook assignment/assessment from one class to another for transfer (e.g. when copying or moving gradebook structure between classes). Surrogate PK.

| Column | Type | Notes |
|---|---|---|
| `GbkTransferID` | int IDENTITY | PK |
| `FromClassID` / `ToClassID` | int | Source/target class; nullable |
| `FromAssessmentID` / `ToAssessmentID` | int | Source/target category; nullable |
| `FromAssignmentID` / `ToAssignmentID` | int | Source/target assignment; nullable |

---

#### `dbo.GradeCalculatorConfig`
Configuration for a "grade calculator" report — up to 6 configurable grade/weight/factor slots, division include/exclude filters, and grouping. Header for `GradeCalculatorCourses` and `GradeCalculatorDepartments`.

| Column group | Type | Notes |
|---|---|---|
| `ReportID` | int IDENTITY | PK |
| `ReportTitle` | nvarchar(50) | Nullable |
| `Option1`–`Option6` | nvarchar(50) | Configurable option slots |
| `GradeType1`–`GradeType6` | nvarchar(50) | Grade-type per slot |
| `WeightType1`–`WeightType6` | nvarchar(50) | Weight-type per slot |
| `Factor1`–`Factor6` | real | Numeric factor per slot |
| `Group` / `GradeFilter` / `Threshold` | mixed | Grouping/filter config |
| `IncludeElementary` / `IncludeMiddleSchool` / `IncludeHighSchool` | bit | Division include flags |
| `ExcludeElementary` / `ExcludeMiddleSchool` / `ExcludeHighSchool` / `ExcludeElectives` | bit | Division/elective exclude flags |
| `SchoolCode` | varchar(50) | Nullable |

---

#### `dbo.GradeCalculatorCourses`
Per-report course include/exclude list for a grade calculator. PK is composite `(ReportID, CourseID, Include)`.

| Column | Type | Notes |
|---|---|---|
| `ReportID` | int | PK (composite) |
| `CourseID` | int | PK (composite) |
| `Include` | bit | PK (composite); include vs exclude |

---

#### `dbo.GradeCalculatorDepartments`
Per-report department include/exclude list for a grade calculator. PK is composite `(ReportID, Department, Include)`.

| Column | Type | Notes |
|---|---|---|
| `ReportID` | int | PK (composite) |
| `Department` | nvarchar(50) | PK (composite) |
| `Include` | bit | PK (composite); include vs exclude |

---

#### `dbo.GradeConfiguration`
**The grade scale** — maps a numeric `Average` range to a `Grade` (letter/number), `GPA`, passing flag, and calc inclusion, per course level. **Central to transcript/GPA and report-card grade display.** Surrogate PK `AutoNum`; indexed by `CourseLevelID` + `Average`/`Grade`.

| Column | Type | Notes |
|---|---|---|
| `AutoNum` | int IDENTITY | PK |
| `CourseLevelID` | int | The course level this scale applies to; default 0; indexed |
| `Grade` | nvarchar(50) | Letter/number grade; indexed with `CourseLevelID` |
| `Average` | decimal(12,4) | Threshold average for this grade; default 0; indexed |
| `LetterGrade` / `NumberGrade` | bit | Which display style; default 0 |
| `Passing` | bit | Counts as passing; default 0 |
| `Calc` | bit | Included in GPA/average calc; default 0 |
| `GPA` | decimal(12,4) | Weighted GPA points; default 0 |
| `UGPA` | decimal(12,4) | Unweighted GPA points; nullable |
| `Offset` | int | Ordering/offset; default 0 |
| `Skip` | bit | Skip flag; nullable |
| `SchoolCode` | varchar(50) | Nullable |
| `CourseAttemptResultDescriptorID` | uniqueidentifier | Ed-Fi descriptor; nullable |
| `ModifiedBy` / `ModifiedDate` | int/smalldatetime | Audit |

**Practical note**: to turn a numeric average into a letter grade and GPA points on a transcript, look up the `GradeConfiguration` row for the student's `CourseLevelID` whose `Average` threshold the score meets. `GPA` vs `UGPA` distinguishes weighted vs unweighted.

---

#### `dbo.GradeLevels`
**Grade-level definitions per school** — one of the Core FACTS tables. PK is composite `(GradeLevel, SchoolCode)`; `GradeLevelID` is a unique surrogate. Temporal table. Holds promotion linkage (`NextGradeLevel`/`NextSchoolCode`), per-grade report/transcript/progress **templates**, attendance defaults, library circulation policy, and admission/inquiry tracking links.

| Column group | Type | Notes |
|---|---|---|
| `GradeLevel` | nvarchar(50) | PK (composite) |
| `SchoolCode` | varchar(50) | PK (composite); indexed |
| `GradeLevelID` | int IDENTITY | Unique surrogate |
| `Description` | nvarchar(128) | Display name; nullable |
| `SortOrder` | int | Ordering; nullable |
| `FinalGradeLevel` | bit | Terminal grade (graduates); default 0 |
| `GradDate` | nvarchar(50) | Graduation date label; nullable |
| Promotion: `NextGradeLevel` / `NextSchoolCode` | nvarchar/varchar | Where students promote to |
| Templates: `ReportCardTemplate` / `ProgressReportTemplate` / `TranscriptTemplate` / `ScheduleTemplate` | nvarchar(128) | **Per-grade report templates** |
| Divisions: `PreSchool` / `Elementary` / `MiddleSchool` / `HighSchool` | bit | Division flags |
| Attendance: `AttendanceMethod` / `AbsentHalf` / `AbsentDay` | nvarchar/int | Attendance defaults (`AbsentHalf`/`AbsentDay` default 1) |
| Library: `CirculationLimit` / `CirculationPeriod` / `PatronGroupID` | int | `PatronGroupID` FK → `lib.PatronGroup` (SET NULL on delete) |
| Tracking: `AdmissionTrackingID` / `ReenrollTrackingID` / `InquiryTrackingID` | int | Admission funnel links |
| `CurriculumPlanID` | int | Default curriculum plan; nullable |
| `Capacity` | int | Grade capacity; nullable |
| `GradeLevelDescriptorId` | uniqueidentifier | Ed-Fi descriptor; nullable |
| `CreatedOnUTC` / `ModifiedOnUTC` / `ModifiedOnUTCmax` | datetime2(2) | Temporal versioning |
| `ModifiedBy` / `ModifiedDate` | int/smalldatetime | Audit |

**Practical note**: the per-grade `ReportCardTemplate` / `TranscriptTemplate` / `ProgressReportTemplate` columns determine which template a student's report uses based on their grade level — a key lookup when a report renders with the wrong layout. `GradeLevels` is FK'd by many tables (e.g. `DefaultRequests`) on `(GradeLevel, SchoolCode)`.

---

#### `dbo.HomeworkDropBox`
Student-submitted homework files (drop box) — file name/UUID, uploader, class, and soft-delete/verify tracking.

| Column | Type | Notes |
|---|---|---|
| `HomeworkDropBoxID` | int IDENTITY | PK |
| `ClassID` | int | Nullable |
| `FileName` | nvarchar(128) | Nullable |
| `UUID` | varchar(50) | Stored file identifier; nullable |
| `UploadedBy` | int | Nullable |
| `DatePosted` | smalldatetime | Nullable |
| `Note` | nvarchar(2000) | Nullable |
| `Downloaded` / `Verified` / `Deleted` | bit | Status flags; nullable |
| `DeletedBy` / `DeletedDate` | int/smalldatetime | Soft-delete audit; nullable |

---

### `dbo` honor-roll tables

The honor-roll subsystem — a reporting feature that ranks/qualifies students by grade average. `HonorRollConfig` is the named honor-roll definition; `HonorRollFilter` scopes it; `Honors` defines the qualifying tiers.

#### `dbo.HonorRollConfig`
Named honor-roll definition per school — ranking source, elective handling, template, and transcript inclusion. Header for `HonorRollFilter` and `Honors`.

| Column | Type | Notes |
|---|---|---|
| `HonorRollID` | int IDENTITY | PK |
| `HonorRollName` | nvarchar(50) | Nullable |
| `RankBy` / `Source` / `FilterSource` / `Include_Exclude_Filter` | int | Ranking/source/filter config |
| `ExcludeElectives` | bit | Nullable |
| `Transcript` | bit | Include on transcript; nullable |
| `HonorRollTemplate` | nvarchar(50) | Report template; nullable |
| `Active` | bit | Default 1 |
| `Description` | nvarchar(2000) | Nullable |
| `SchoolCode` | varchar(50) | Nullable |
| `ModifiedBy` / `ModifiedDate` | int/smalldatetime | Audit |

---

#### `dbo.HonorRollFilter`
Filter values scoping an honor roll (e.g. grade levels included). PK is composite `(HonorRollID, Filter)`.

| Column | Type | Notes |
|---|---|---|
| `HonorRollID` | int | PK (composite); → `HonorRollConfig` |
| `Filter` | nvarchar(50) | PK (composite); filter value |
| `ModifiedBy` / `ModifiedDate` | int/smalldatetime | Nullable |

---

#### `dbo.Honors`
Honor tier definitions — the qualifying thresholds (min average, class-rank range, min credits) for each honor, optionally tied to an `HonorRollConfig`. This is where "Honor Roll", "High Honors", etc. and their cutoffs live.

| Column | Type | Notes |
|---|---|---|
| `HonorID` | int IDENTITY | PK |
| `Honor` | nvarchar(50) | Honor name (e.g. "High Honors"); required |
| `MinAvg` | real | Minimum average to qualify; required |
| `MinClass` / `MaxClass` | real | Class-rank range; required |
| `MinCredits` | real | Minimum credits; required |
| `CalcMethod` | nvarchar(50) | How qualification is computed; nullable |
| `TimeFrame` | smallint | Term/semester/year scope; required |
| `Sequence` | smallint | Tier ordering; nullable |
| `GradeLevel` | nvarchar(50) | Applicable grade level; nullable |
| `HonorRollID` | int | → `HonorRollConfig`; nullable |
| `SchoolCode` | varchar(50) | Nullable |
| `ModifiedBy` / `ModifiedDate` | int/smalldatetime | Audit |

---

#### `dbo` grade-calculator / grade-config / grade-levels / honor-roll — cross-reference summary

| Table | Scope | Key FK targets / notes |
|---|---|---|
| `GbkTransfer` | Gradebook assignment transfer map | From/To class/assessment/assignment |
| `GradeCalculatorConfig` | Grade-calculator report config | 6 grade/weight/factor slots |
| `GradeCalculatorCourses` | Grade-calc course include/exclude | PK `(ReportID, CourseID, Include)` |
| `GradeCalculatorDepartments` | Grade-calc dept include/exclude | PK `(ReportID, Department, Include)` |
| `GradeConfiguration` | **Grade scale** (avg→grade/GPA) | By `CourseLevelID`; `GPA` vs `UGPA`; transcript-critical |
| `GradeLevels` | **Grade-level definitions** (Core FACTS) | PK `(GradeLevel, SchoolCode)`; per-grade report templates; `lib.PatronGroup`; temporal |
| `HomeworkDropBox` | Student homework submissions | Soft-delete tracking |
| `HonorRollConfig` | Named honor-roll definition | Header for filter/honors |
| `HonorRollFilter` | Honor-roll scope filters | PK `(HonorRollID, Filter)` |
| `Honors` | Honor tier thresholds | → `HonorRollConfig`; min avg/class/credits |

---

### `dbo` templates, import-staging, lookup, inventory, label, and lesson-plan tables

#### `dbo.HTMLTemplates`
Stored HTML templates (email/letter/merge templates) with compiled output cache, owner, district/school scope, and soft-delete. Distinct from the per-grade report *template names* in `GradeLevels` — these are the actual template bodies.

| Column | Type | Notes |
|---|---|---|
| `TemplateID` | int IDENTITY | PK |
| `TemplateType` | int | Template category; nullable |
| `TemplateName` | nvarchar(255) | Indexed; nullable |
| `TemplateOwner` | int | Owner staff; indexed; nullable |
| `Template` | nvarchar(max) | Source template body |
| `CompiledTemplate` / `CompiledResult` / `CompiledDate` | mixed | Compiled cache |
| `Custom` | nvarchar(max) | Custom data; nullable |
| `Subject` | nvarchar(128) | Email subject; nullable |
| `AttachmentSession` | nvarchar(128) | Attachment session ref; nullable |
| `DistrictWide` | bit | Scope; indexed |
| `ConfigSchoolID` | smallint | School scope; nullable |
| `IsDeleted` | bit | Soft-delete; default 0 |

---

#### `dbo.IDList`
Per-staff scratch list of ID + text pairs — a working set (e.g. a saved selection of records) scoped to a staff member. PK is composite `(StaffID, ID, Text)`.

| Column | Type | Notes |
|---|---|---|
| `StaffID` | int | PK (composite); indexed |
| `ID` | int | PK (composite) |
| `Text` | nvarchar(50) | PK (composite) |

---

#### `dbo.ImmunizationComplianceRules`
Rules defining immunization compliance — shot type, required count, timing windows (month/date ranges, "on or after" / "within" constraints with an operator), per grade level. Drives medical/immunization compliance reporting.

| Column | Type | Notes |
|---|---|---|
| `ID` | int IDENTITY | PK |
| `ShotType` | nvarchar(50) | Vaccine/shot type; nullable |
| `ShotCount` | int | Required doses; nullable |
| `BeginMonth` / `EndMonth` | int | Age/month window; nullable |
| `BeginDate` / `EndDate` | datetime | Date window; nullable |
| `StartCountOnOrAfter` | int | Count doses on/after this age; nullable |
| `LastShotOnOrAfter` / `LastShotOnOrAfterOperator` / `LastShotWithin` | mixed | Last-dose timing constraints |
| `GradeLevel` | nvarchar(50) | Applicable grade; nullable |
| `ComplianceNote` | nvarchar(255) | Nullable |
| `ModifiedBy` / `ModifiedDate` | int/smalldatetime | Audit |

---

#### `dbo.Import`
**Wide student/parent import staging table** — one row per incoming student with denormalized parent (P1/P2) and secondary-contact (S1/S2) blocks plus address/contact fields. Used during data imports before records are written to the live `Person`/family tables.

> **Sensitive — contains PII**: `ssn`, birthdates, addresses, phones, and emails for students and contacts. This is raw import data; never expose `ssn` or the full contact blocks in reports, and treat the whole table as confidential staging.

Documented by column group (it has ~100 columns):

| Column group | Type | Notes |
|---|---|---|
| `ID` | int IDENTITY | PK |
| `Type` / `TimeStamp` | nvarchar/smalldatetime | Import batch type & time |
| Student core: `studentid` / `firstname` / `middlename` / `lastname` / `suffix` / `nickname` / `Gender` / `Birthdate` / `ssn` / `ethnicity` / `email` / `cellphone` / `primarylanguage` | mixed | **`ssn` sensitive** |
| Enrollment: `status` / `nextstatus` / `gradelevel` / `nextgradelevel` / `schoolcode` / `nextschoolcode` / `placement` / `classof` | mixed | Current & next-year placement |
| Prior school: `publicschoolDistrict` / `publicschoolCOunty` / `publicschoolState` / `publicschoolLocalSchool` / `publicschoolCode` | nvarchar | Sending-school info |
| Student address: `SAddress` / `SAddress2` / `SCity` / `SState` / `SZip` / `SHomephone` / `addressid` | mixed | — |
| Primary address: `PAddress` / `PAddress2` / `PCity` / `PState` / `PZip` / `PHomephone` | nvarchar | — |
| Parents `P1*` / `P2*` | mixed | Two parent blocks: PersonID, relationship, name parts, custody, marital status, phones, email, company, occupation, church, classof, alumni year |
| Secondary contacts `S1*` / `S2*` | mixed | Two secondary-contact blocks (same shape as parent blocks) |

---

#### `dbo.ImportError`
Errors encountered during an import run, by student and timestamp.

| Column | Type | Notes |
|---|---|---|
| `ID` | int IDENTITY | PK |
| `TimeStamp` | smalldatetime | Nullable |
| `StudentID` | int | Nullable |
| `Errors` | nvarchar(1024) | Error text; nullable |

---

#### `dbo.Interest`
Interest lookup (extracurricular/activity interests) within a category.

| Column | Type | Notes |
|---|---|---|
| `InterestID` | int IDENTITY | PK |
| `Interest` | nvarchar(50) | Nullable |
| `InterestCategoryID` | int | → `dbo.InterestCategory`; nullable |
| `SortOrder` | int | Nullable |
| `Active` | bit | Nullable |

---

#### `dbo.InterestCategory`
Category grouping for interests, with online-application visibility and scope.

| Column | Type | Notes |
|---|---|---|
| `InterestCategoryID` | int IDENTITY | PK |
| `Category` | nvarchar(50) | Nullable |
| `Type` | int | Nullable |
| `OnlineApplication` | bit | Show on online application; nullable |
| `DistrictWide` | bit | Scope; nullable |
| `SchoolCode` | varchar(50) | Nullable |
| `SortOrder` / `Active` | int/bit | Ordering/active; nullable |

---

#### `dbo.Inventory`
**Inventory items** — referenced in Core FACTS tables and the FK/lookup target for `CashRegisterItems.InventoryID`, `Charges.CR_InventoryID`, and similar. Item name, barcode, price/cost, stock levels, vendor, and accounting category. Note `InventoryID` is the PK but **not** an IDENTITY (assigned by the app).

| Column | Type | Notes |
|---|---|---|
| `InventoryID` | int | PK (app-assigned, not identity) |
| `Name` | nvarchar(255) | Item name; nullable |
| `Barcode` | nvarchar(255) | Nullable |
| `Amount` | decimal(10,4) | Sale price; nullable |
| `COST` | decimal(10,4) | Cost; nullable |
| `InStockQuantity` / `ReorderQuantity` | int | Stock levels; nullable |
| `VendorID` | int | → vendor; nullable |
| `CatID` | int | Accounting category; nullable |
| `Taxable` | bit | Nullable |
| `IDType` / `ID` | nvarchar/int | Cross-reference to source record; nullable |
| `SchoolCode` | varchar(50) | Nullable |
| `ModifiedBy` / `ModifiedDate` | int/smalldatetime | Audit |

---

#### `dbo.LabelLayout`
Saved label-printing layouts — layout definition, label stock type/name, default flag, per school.

| Column | Type | Notes |
|---|---|---|
| `LayoutID` | int IDENTITY | PK (non-clustered) |
| `LayoutName` | nvarchar(255) | Nullable |
| `Layout` | nvarchar(4000) | Layout definition; nullable |
| `LabelID` | int | Label stock id; nullable |
| `LabelName` | nvarchar(20) | Nullable |
| `LabelType` | nvarchar(255) | Nullable |
| `DefaultLayout` | bit | Nullable |
| `SchoolCode` | varchar(50) | Nullable |
| `ModifiedBy` / `ModifiedDate` | int/smalldatetime | Audit |

---

#### `dbo.LessonPlanDetails`
Lesson-plan detail records spanning a date range — four rich-text body sections (plain + HTML), comments, homework, and an optional link to a stored/reusable lesson. Distinct from `GbkLessonPlan` (which is single-date, per class): this is a richer, date-range lesson plan. Unique on `(ClassID, BeginDate)`.

| Column | Type | Notes |
|---|---|---|
| `AutoNum` | int IDENTITY | PK |
| `ClassID` | int | Indexed; unique with `BeginDate`; nullable |
| `CourseID` | int | Nullable |
| `BeginDate` / `EndDate` | datetime | Plan span; nullable |
| `LessonName` | nvarchar(256) | Nullable |
| `Text1`–`Text4` / `Text1HTML`–`Text4HTML` | nvarchar(max) | Four body sections (plain/HTML) |
| `Comments` / `CommentsHTML` | nvarchar(max) | Plain/HTML comments |
| `LessonPlan` / `Homework` | nvarchar(max) | Nullable |
| `StoredLessonId` | int | FK → `lp.StoredLesson` (SET NULL on delete); indexed |
| `ModifiedBy` / `ModifiedDate` | int/smalldatetime | Audit |

---

#### `dbo` templates / import / lookup / inventory / label / lesson-plan — cross-reference summary

| Table | Scope | Key FK targets / notes |
|---|---|---|
| `HTMLTemplates` | Stored HTML/email templates (bodies) | Soft-delete; compiled cache |
| `IDList` | Per-staff scratch ID list | PK `(StaffID, ID, Text)` |
| `ImmunizationComplianceRules` | Immunization compliance rules | Drives medical compliance reports |
| `Import` | **Wide student/parent import staging** | **PII incl. `ssn` — confidential** |
| `ImportError` | Import-run errors | By student |
| `Interest` | Interest lookup | → `InterestCategory` |
| `InterestCategory` | Interest categories | Online-application flag |
| `Inventory` | **Inventory items** (Core FACTS) | PK not identity; FK target for `Charges.CR_InventoryID`, `CashRegisterItems` |
| `LabelLayout` | Label-printing layouts | Per school |
| `LessonPlanDetails` | Date-range lesson plans (rich) | `lp.StoredLesson`; vs single-date `GbkLessonPlan` |

---

### `dbo` lesson-plan settings, library, locker, login-token, and legacy lunch tables

#### `dbo.LessonPlanSettings`
Per-class/per-teacher lesson-plan display settings — which sections and weekdays are shown. CASCADE from both `dbo.Classes` and `dbo.Person_Staff`. PK is composite `(ClassID, StaffID)`.

| Column | Type | Notes |
|---|---|---|
| `ClassID` | int | PK (composite); FK → `dbo.Classes` (CASCADE) |
| `StaffID` | int | PK (composite); FK → `dbo.Person_Staff` (CASCADE) |
| Section toggles: `LessonPlan` / `Homework` / `Documents` / `Text1`–`Text4` / `Standards` / `Comments` / `Assignments` | bit | Show section; default 1 |
| Weekday toggles: `SundayView` / `MondayView` … `SaturdayView` | bit | Sun/Sat default 0, weekdays default 1 |
| `ModifiedBy` | int | Required |
| `ModifiedDate` | smalldatetime | Nullable |

---

#### `dbo.Library`
**Library catalog** — book/media bibliographic records with MARC, Dewey, ISBN, reading-program level/points, cost, and current checkout/reserve status. PK `BookID`. (Library circulation policy defaults live on `ConfigSchool`/`ConfigDistrict`/`GradeLevels`; patron groups in `lib`.)

| Column group | Type | Notes |
|---|---|---|
| `BookID` | int IDENTITY | PK |
| Bibliographic: `Title` / `SubTitle` / `Author` / `Publisher` / `Copyright` / `ISBN` / `Dewey` / `Subject` / `Category` / `Keywords` / `series` / `Awards` / `Pages` / `Summary` / `MediaType` / `Hardback` | mixed | `Title`/`Author` indexed |
| `MARC` | varchar(8000) | MARC record |
| `NonfilingCharacters` | int | Leading chars to ignore in sort; default 0 |
| Reading program: `ReadingProgramLevel` / `ReadingProgramPoints` (+ `...Was` legacy) | nvarchar | AR-style level/points |
| Circulation status: `CheckoutID` / `Checkouttype` / `ReserveID` / `ReserveType` / `CheckoutDate` / `ReturnDate` / `Lost` | mixed | Current state; `(CheckoutID, Checkouttype)` indexed |
| `BarCode` / `BarcodeID` / `Inventory` | mixed | Barcode/inventory flags; `BarcodeID` indexed |
| `Cost` | money | Replacement cost |
| `Permission` / `PermissionNote` | bit/nvarchar | Checkout permission |
| `SchoolCode` | varchar(255) | Nullable |
| `ModifiedBy` / `ModifiedDate` | int/smalldatetime | Audit |

---

#### `dbo.LibraryHistory`
Library checkout/return history per student × book, with overdue tracking. Where `Library` holds current status, this is the historical log.

| Column | Type | Notes |
|---|---|---|
| `ID` | int IDENTITY | PK |
| `StudentID` | int | Nullable |
| `BookID` | int | → `dbo.Library`; nullable |
| `CheckOutDate` / `CheckInDate` | smalldatetime | Nullable |
| `DaysOverdue` | int | Nullable |
| `OverdueBilled` | bit | Whether a fine was charged; nullable |

---

#### `dbo.LockerConfig`
Locker definitions per school — up to 5 stored combinations with a current-combination pointer, group, and out-of-service flag. FK to `DefinedLists` for the locker group. PK is composite `(Locker, SchoolCode)`.

| Column | Type | Notes |
|---|---|---|
| `Locker` | nvarchar(50) | PK (composite); locker number |
| `SchoolCode` | varchar(50) | PK (composite) |
| `LockerConfigID` | int IDENTITY | Surrogate |
| `Combination1`–`Combination5` | nvarchar(50) | Stored combinations; nullable |
| `CurrentCombination` | int | Which combination is active; nullable |
| `LockerGroupID` | int | FK → `dbo.DefinedLists` (SET NULL on delete); nullable |
| `OutOfService` | bit | Nullable |
| `Note` | nvarchar(128) | Nullable |

---

#### `dbo.LoginToken`
Login/authentication tokens per person per login type (e.g. password-reset, remember-me). PK is composite `(PersonID, LoginType)`.

| Column | Type | Notes |
|---|---|---|
| `PersonID` | int | PK (composite) |
| `LoginType` | nvarchar(50) | PK (composite); token purpose |
| `Token` | varchar(50) | The token value; nullable |
| `TokenCreationTime` | datetime | Issued-at; nullable |

> **Sensitive**: `Token` is an authentication credential. Never expose login tokens in reports or logs.

---

### `dbo` legacy lunch / cafeteria tables

> **Note — newer cafeteria system exists.** These `dbo.Lunch*`/`dbo.LunchMenuNew` tables are the **legacy** lunch/cafeteria subsystem. The refactored system lives in the **`cafe` schema** (`cafe.MenuItem`, `cafe.MenuOrder`, `cafe.Cart`, etc., documented earlier), which the `cafe` section notes is a refactor of `dbo.LunchMenuNew`. Confirm which system a report targets.

#### `dbo.LunchMenuNew`
Legacy lunch menu item catalog per school — item description, pricing tiers (full/reduced/staff), meal/breakfast flags, and accounting category. PK `LunchID` (despite the "ItemNumber" column). The item table the lunch-order tables reference by `LunchID`.

| Column | Type | Notes |
|---|---|---|
| `LunchID` | int IDENTITY | PK |
| `ItemNumber` | smallint | Item number within school; required |
| `SchoolCode` | varchar(50) | Required; indexed |
| `Description` | nvarchar(128) | Nullable |
| `FullPrice` / `ReducedPrice` / `StaffPrice` | decimal(19,4) | Pricing tiers; nullable |
| `ReducedLunchEligible` | bit | Required |
| `Meal` / `Breakfast` | bit | Meal/breakfast flags; default 0 |
| `Active` | bit | Default 1 |
| `AcctCat` | int | Accounting category; nullable |
| `ModifiedBy` / `ModifiedDate` | int/smalldatetime | Audit |

---

#### `dbo.LunchMenuDates`
Dates a legacy lunch menu item (`LunchID`) is offered. PK is composite `(LunchID, Date)`.

| Column | Type | Notes |
|---|---|---|
| `LunchID` | int | PK (composite); → `LunchMenuNew` |
| `Date` | smalldatetime | PK (composite); indexed |

---

#### `dbo.LunchOrders`
Legacy student lunch orders — one row per student × day × column, with the ordered item, free/reduced eligibility, meal/breakfast flags, and the resulting charge. Surrogate PK `AutoNum`. **Note `ItemNumber` here joins to `LunchMenuNew.LunchID`** (per the trigger), not to `LunchMenuNew.ItemNumber`.

| Column | Type | Notes |
|---|---|---|
| `AutoNum` | int IDENTITY | PK |
| `StudentID` | int | Indexed; nullable |
| `Day` | smalldatetime | Order date; indexed with `StudentID` |
| `Column` | int | Slot/position; nullable |
| `ItemNumber` | int | Joins to `LunchMenuNew.LunchID`; nullable |
| `Description` | nvarchar(128) | Nullable |
| `ReducedLunchEligible` | bit | Required |
| `Reduced` / `Free` / `StateReduced` / `StateFree` | bit | Subsidy flags; default 0 |
| `Verified` | bit | Default 0 |
| `breakfast` / `Meal` | bit | Default 0 (maintained by trigger) |
| `ChargeID` | int | → `dbo.Charges`; nullable |
| `IsFactsProcessed` | bit | FACTS sync flag; default 0 |
| `ModifiedBy` / `ModifiedDate` | int/smalldatetime | Audit |

**Trigger** `tr_lunchorders` (AFTER INSERT, UPDATE): **currently a no-op** — the body begins with `RETURN` before any work. When active it backfilled `meal`/`breakfast` from `LunchMenuNew` (joining `lo.itemnumber = lmn.lunchid`). Inactive now, but the join it documents is the canonical order→item linkage.

---

#### `dbo.LunchordersStaff`
Legacy staff lunch orders — staff counterpart to `LunchOrders`. PK is composite `(StaffID, Day, Column)`.

| Column | Type | Notes |
|---|---|---|
| `StaffID` | int | PK (composite) |
| `Day` | datetime | PK (composite) |
| `Column` | int | PK (composite); slot |
| `ItemNumber` | int | → `LunchMenuNew.LunchID`; nullable |
| `Description` | nvarchar(128) | Nullable |
| `SchoolCode` | varchar(50) | Nullable |
| `ChargeID` | int | → `dbo.Charges`; nullable |
| `IsFactsProcessed` | bit | FACTS sync flag; default 0 |
| `ModifiedBy` / `ModifiedDate` | int/smalldatetime | Audit |

---

#### `dbo.LunchordersWeb`
Legacy web-submitted lunch orders (pre-conversion queue) — student orders placed via the portal, with quantity, paid, and a `converted` flag (moved into `LunchOrders`). Unique on `(StudentID, Date, LunchID)`.

| Column | Type | Notes |
|---|---|---|
| `OrderID` | int IDENTITY | PK |
| `StudentID` | int | Indexed; nullable |
| `Date` | smalldatetime | Indexed; nullable |
| `LunchID` | int | → `LunchMenuNew`; nullable |
| `quantity` | int | Nullable |
| `paid` | bit | Nullable |
| `converted` | bit | Whether moved into `LunchOrders`; nullable |

---

#### `dbo` lesson-settings / library / locker / login / legacy-lunch — cross-reference summary

| Table | Scope | Key FK targets / notes |
|---|---|---|
| `LessonPlanSettings` | Per-class/teacher lesson-plan display | CASCADE from `Classes` + `Person_Staff` |
| `Library` | Library catalog | `BookID`; circulation policy on `ConfigSchool`/`GradeLevels` |
| `LibraryHistory` | Library checkout history | → `Library` |
| `LockerConfig` | Locker definitions | `dbo.DefinedLists` (SET NULL); PK `(Locker, SchoolCode)` |
| `LoginToken` | Auth tokens per person/type | **Token is a credential — never expose** |
| `LunchMenuNew` | **Legacy** lunch item catalog | PK `LunchID`; newer system = `cafe` schema |
| `LunchMenuDates` | Legacy menu item offer dates | PK `(LunchID, Date)` |
| `LunchOrders` | Legacy student lunch orders | `ItemNumber`→`LunchMenuNew.LunchID`; `Charges`; no-op trigger |
| `LunchordersStaff` | Legacy staff lunch orders | PK `(StaffID, Day, Column)`; `Charges` |
| `LunchordersWeb` | Legacy web lunch-order queue | `converted` → `LunchOrders` |

---

### `dbo` mobile-log, mail-merge, maintenance-jobs, master-lesson-plan, and MIP-export tables

#### `dbo.MobileApp_ErrorDetailsLog`
Error log for the mobile app — file/method, message, stack trace, and method params. Diagnostic only.

| Column | Type | Notes |
|---|---|---|
| `ID` | int IDENTITY | PK |
| `Date` | datetime | Nullable |
| `FileName` / `MethodName` | nvarchar(50) | Where the error occurred; nullable |
| `ErrorMessage` / `StackTrace` / `MethodParams` | nvarchar(max) | Diagnostic detail; nullable |

---

#### `dbo.MailMerge`
Saved mail-merge letter templates per school, keyed by name + type. PK is composite `(Name, Type, SchoolCode)`.

| Column | Type | Notes |
|---|---|---|
| `Name` | nvarchar(125) | PK (composite); template name |
| `Type` | nvarchar(50) | PK (composite); template type |
| `SchoolCode` | varchar(50) | PK (composite) |
| `Letter` | nvarchar(max) | Letter body; nullable |
| `ModifiedBy` / `ModifiedDate` | int/smalldatetime | Audit |

---

### `dbo` maintenance / notification-job tables

The "Maintenance" subsystem here refers to **scheduled jobs / notifications** (the Maintenance Manager — cf. the `ActivityLog_MaintenanceManager` table), not facilities maintenance. `Maintenance` defines a job; the others track its class scope, run log, and per-entity tracking.

#### `dbo.Maintenance`
A scheduled maintenance/notification job — type, status, run schedule, notification content (voice/text-to-speech/SMS), and 20 generic `F1`–`F20` parameter slots.

| Column group | Type | Notes |
|---|---|---|
| `MaintenanceID` | int IDENTITY | PK |
| `Type` | nvarchar(50) | Job type; nullable |
| `Description` | nvarchar(255) | Nullable |
| `Status` | int | Job status; nullable |
| `SchoolCode` | varchar(50) | Nullable |
| `RunTime` / `LastTimeRunDay` / `LastTimeRunTime` | varchar(50) | Schedule & last-run (text) |
| `NotificationMessage` | nvarchar(max) | Nullable |
| `NotificationSourceID` | int | Nullable |
| `VoiceFile` / `TextToSpeech` / `TextMessage` | nvarchar | Notification delivery content |
| `F1`–`F20` | varchar(50) | Generic parameter slots |
| `ReadOnly` | bit | Default 0 |

---

#### `dbo.MaintenanceClassList`
Classes scoped to a maintenance job, by job type. CASCADE from both `dbo.Maintenance` and `dbo.Classes`.

| Column | Type | Notes |
|---|---|---|
| `ListID` | int IDENTITY | PK |
| `MaintenanceID` | int | FK → `dbo.Maintenance` (CASCADE) |
| `ClassID` | int | FK → `dbo.Classes` (CASCADE) |
| `JobType` | nvarchar(50) | Required |
| `ModifiedDate` | smalldatetime | Required |

---

#### `dbo.MaintenanceLog`
Run log for maintenance jobs. Note `Date` is stored as text (nvarchar).

| Column | Type | Notes |
|---|---|---|
| `ID` | int IDENTITY | PK |
| `MaintenanceID` | int | Nullable |
| `Date` | nvarchar(50) | Run date (text); required |
| `Log` | nvarchar(max) | Log output; nullable |

---

#### `dbo.MaintenanceTracking`
Per-entity tracking produced by maintenance jobs — links a job to a student/class/discipline/term with a value (string or numeric) and time frame. Used for accumulator-style tracking (e.g. counting events per student per term). FK to `dbo.SchoolTerm` on `(TermID, YearID)`.

| Column | Type | Notes |
|---|---|---|
| `ID` | int IDENTITY | PK |
| `MaintenanceID` | int | The job; nullable |
| `StudentID` | int | Indexed; nullable |
| `ClassID` / `DisciplineID` | int | Linked entities; nullable |
| `TermID` / `YearID` | smallint/int | FK → `dbo.SchoolTerm` `(TermID, YearID)` |
| `BeginDate` / `EndDate` | nvarchar(50) | Text date range; nullable |
| `BeginDateTime` / `EndDateTime` | smalldatetime | Typed date range; nullable |
| `TimeFrame` | tinyint | Scope (term/sem/year); indexed with `StudentID`; nullable |
| `LogDataString` | nvarchar(50) | String value; nullable |
| `LogDataNumeric` | decimal(19,4) | Numeric value; nullable |
| `ModifiedDate` | smalldatetime | Defaults to `GETDATE()` |

---

### `dbo` master lesson plan tables

The **master lesson plan** is a course/teacher-level template keyed by `(CourseID, StaffID, Day)` — a reusable plan a teacher applies across classes of a course. (Cf. `aca.MasterLessonPlanStandardMM`, the standards link documented in the `aca` schema; and `dbo.GbkLessonPlan`/`dbo.LessonPlanDetails`, the per-class instances.)

#### `dbo.MasterLessonPlan`
The master lesson plan body for a course/teacher/day — plan, homework, and four detail sections. PK is composite `(CourseID, StaffID, Day)`.

| Column | Type | Notes |
|---|---|---|
| `CourseID` | int | PK (composite) |
| `StaffID` | int | PK (composite) |
| `Day` | int | PK (composite); day number in sequence |
| `LessonPlan` / `Homework` | nvarchar(max) | Nullable |
| `Details1`–`Details4` | nvarchar(max) | Detail sections; nullable |

---

#### `dbo.MasterLessonPlanObjectives`
Objectives attached to a master lesson plan day. PK is composite `(CourseID, StaffID, Day, ObjectiveID)`.

| Column | Type | Notes |
|---|---|---|
| `CourseID` / `StaffID` / `Day` | int | PK (composite); the master plan day |
| `ObjectiveID` | int | PK (composite) |

---

#### `dbo.MasterLessonPlanWebDocuments`
Web documents attached to a master lesson plan day. PK is composite `(CourseID, StaffID, Day, DocumentID)`.

| Column | Type | Notes |
|---|---|---|
| `CourseID` / `StaffID` / `Day` | int | PK (composite); the master plan day |
| `DocumentID` | int | PK (composite); → web document |

---

#### `dbo.MIPExportResults`
Results of an MIP (accounting system) export — exported financial transactions with grouping, effective date, amount, document number, and deposit slip. An accounting-integration export log.

| Column | Type | Notes |
|---|---|---|
| `ID` | int IDENTITY | PK |
| `Session` | varchar(50) | Export session; nullable |
| `Grping` | varchar(50) | Grouping key; nullable |
| `EffectiveDate` | datetime | Nullable |
| `Description` | varchar(128) | Nullable |
| `DocNum` | varchar(50) | Document number; nullable |
| `Amount` | money | Nullable |
| `DistCode` | varchar(50) | Distribution/GL code; nullable |
| `DepositSlip` | varchar(50) | Nullable |
| `Type` | varchar(50) | Nullable |

---

#### `dbo` mobile-log / mail-merge / maintenance / master-lesson-plan / MIP — cross-reference summary

| Table | Scope | Key FK targets / notes |
|---|---|---|
| `MobileApp_ErrorDetailsLog` | Mobile app error log | Diagnostic |
| `MailMerge` | Mail-merge letter templates | PK `(Name, Type, SchoolCode)` |
| `Maintenance` | Scheduled job / notification def | Maintenance Manager; `F1`–`F20` slots |
| `MaintenanceClassList` | Job ↔ class scope | CASCADE from `Maintenance` + `Classes` |
| `MaintenanceLog` | Job run log | `Date` is text |
| `MaintenanceTracking` | Per-entity job tracking | `dbo.SchoolTerm` `(TermID, YearID)` |
| `MasterLessonPlan` | Course/teacher lesson template | PK `(CourseID, StaffID, Day)`; cf. `aca.MasterLessonPlanStandardMM` |
| `MasterLessonPlanObjectives` | Objectives on a master plan day | PK adds `ObjectiveID` |
| `MasterLessonPlanWebDocuments` | Web docs on a master plan day | PK adds `DocumentID` |
| `MIPExportResults` | MIP accounting export log | Financial export results |

---

### `dbo` mobile-subscription, newsletter, inquiry, and Online-Application (OA) tables

#### `dbo.Mobileapp_SubscriptionPurchaseDetails`
Mobile-app in-app subscription purchase records per family — receipt data, transaction id, expiry. Header for `Mobileapp_SubscriptionPersonNotifiedBulk`.

| Column | Type | Notes |
|---|---|---|
| `SubscriptionID` | int IDENTITY | PK |
| `FamilyID` | int | Nullable |
| `ExpiryDate` | smalldatetime | Nullable |
| `PurchaseDate` | nvarchar(30) | Purchase date (text); nullable |
| `TransactionID` | nvarchar(50) | Store transaction id; nullable |
| `ReceiptData` | nvarchar(max) | Store receipt blob; nullable |
| `Old` / `AllowFreeAccess` | bit | Status flags; nullable |

> **Sensitive**: `ReceiptData`/`TransactionID` are payment-store artifacts — don't expose in reports.

---

#### `dbo.Mobileapp_SubscriptionPersonNotifiedBulk`
Tracks which persons have been bulk-notified for a subscription. PK is composite `(SubscriptionID, PersonID)`; FK to `Mobileapp_SubscriptionPurchaseDetails`.

| Column | Type | Notes |
|---|---|---|
| `SubscriptionID` | int | PK (composite); FK → `Mobileapp_SubscriptionPurchaseDetails` |
| `PersonID` | int | PK (composite) |

---

#### `dbo.MobileApp_UsersAnalytics`
Mobile-app usage analytics — per family/user device, OS, and app version snapshots.

| Column | Type | Notes |
|---|---|---|
| `AnalyticsID` | int IDENTITY | PK |
| `DistrictCode` | nvarchar(50) | Required; default '' |
| `FamilyID` | int | Required |
| `UserFName` | nvarchar(255) | Nullable |
| `OS` / `OSVersion` / `AppVersion` / `Device` | nvarchar | Device/app metadata |
| `CurrentTime` | smalldatetime | Snapshot time; nullable |

---

#### `dbo.NewsLetters`
Newsletter/document links shown in the portal, per school. `IsHyperlink` distinguishes an external link from an uploaded file.

| Column | Type | Notes |
|---|---|---|
| `NewsLetterID` | int IDENTITY | PK |
| `Caption` | nvarchar(128) | Nullable |
| `Filename` | nvarchar(256) | File or URL; nullable |
| `SchoolCode` | varchar(50) | Nullable |
| `GlobalItem` | bit | District-wide flag; nullable |
| `Newsletter` | bit | Nullable |
| `Icon_PictureID` | int | Nullable |
| `IsHyperlink` | bit | External link vs file; default 0 |

---

#### `dbo.NewStudentInquiry`
**Prospective-student inquiry record** — a wide admissions-funnel intake form capturing family, up to two parents (P1/P2), up to four prospective students (S1–S4 with grade/school/birthdate/enrolled flags), interview, open houses, referral source, and 10 generic notes + 10 `EP` flags. Early-funnel counterpart to the `ae`/`OA` application tables.

> **Contains PII**: names, addresses, phones, birthdates, email for prospective families. Treat as confidential.

Documented by column group:

| Column group | Type | Notes |
|---|---|---|
| `NewStudentInquiryID` | int IDENTITY | PK |
| Family: `FamilyName` / `FamilyName2` / `FamilyName3` / `FamilyEmail` / `ExistingFamilyID` / `ChildrenNames` | mixed | `ExistingFamilyID` links to a known family |
| Parents: `P1*` / `P2*` (LastName/FirstName/MiddleName) | varchar | Two parent name blocks |
| Address/contact: `Phone` / `Street` / `City` / `State` / `Zip` | varchar | — |
| Students `S1*`–`S4*` | mixed | Per prospect: name, gender, school year, grade level, current/prior school, birthdate, enrolled flag |
| Interview: `InterviewStaff` / `InterviewDate` / `InterviewComments` | mixed | — |
| Funnel: `ContactDate` / `Status` / `ReferredBy` / `ReferredByDetails` / `OpenHouse1`–`4` / `FinancialAid` / `Ethnicity` | mixed | Tracking |
| `EP1`–`EP10` | bit | Generic enrollment-process flags |
| `Note` / `Note1`–`Note10` | mixed | Free-text notes |
| `ModifiedBy` / `ModifiedDate` | int/smalldatetime | Audit |

---

### `dbo` Online Application (OA) tables

The **OA** subsystem is the online admissions application (distinct from, but related to, the `ae` admission/enrollment schema). `OA` is the application definition/config; `OAAddress` holds the per-applicant household/contact data submitted; `OAAddressField`/`OAAdditionalQuestionFormSchool` configure form fields; `OAAddressParentPreferences` captures portal/directory preferences.

#### `dbo.OA`
Online-application definition per school/year — fees, payment options, notification emails, labels, language, multi-school sync, and packet config. PK `onlineappid`. FK to `rw.PortfolioGroup`.

| Column group | Type | Notes |
|---|---|---|
| `onlineappid` | int IDENTITY | PK |
| `appname` / `apptype` | nvarchar/char | App name; type (default 'OA') |
| `SchoolCode` / `school_year` / `school_year_bak` | mixed | Scope; `school_year` required |
| `memberid` | int | Required; owning member |
| `on_off` / `production_test` / `new_apps_allowed` / `finished_when_submitted` / `finished_when_submitted_new` | varchar(1) | Status/behavior flags |
| `admissions_email` / `notify_emails` / `notify_emails_subject` | mixed | Notification config |
| Fees: `school_fee1`–`4` / `manual_amount` / `payment_option` / `EnrollmentFeeWaived` / `ApplicationFeeWaived` / `OEFeeWaivedNewOtherMeans` | mixed | Fee config |
| Text: `before_amount_text` / `after_amount_text` / `parent_ack_check_title1` / `parent_ack_check_title2` / `LabelSuppAppForms` / `LabelRegForms` | nvarchar | Display text/labels |
| `enrollmenttype` | nvarchar(5) | Default '1,2,3' |
| `IsPrimary` / `ReturnForUpdatesEmailParent` / `FamilyPacket` | bit | Behavior flags |
| Multi-school: `MultiSchoolAppID` / `MultiSchoolSyncNeeded` | int/bit | Cross-school linkage |
| `LangDefault` | nvarchar(10) | Default 'en' |
| `PacketReviewOverride` / `TuitionContractTemplateId` / `PortfolioGroupId` | mixed | `PortfolioGroupId` FK → `rw.PortfolioGroup` |

---

#### `dbo.OAAddress`
**The per-applicant household/contact record submitted through an online application** — one row per `(addressname, studentid)`. Holds parent/guardian or student contact, employer, education, church, and emergency/pickup info. Links to `dbo.Person` via `PersonId`.

> **Contains PII**: `ssn`, `Birthdate`, full address/contact, employer details. Treat as confidential; never expose `ssn`.

Documented by column group (~70 columns):

| Column group | Type | Notes |
|---|---|---|
| `addressname` | nvarchar(50) | PK (composite); the household role/slot (e.g. parent1) |
| `studentid` | int | PK (composite) |
| `OAAddressId` | int IDENTITY | Unique surrogate |
| `PersonId` | int | FK → `dbo.Person` (SET NULL / CASCADE update); indexed |
| Name: `firstname` / `middlename` / `lastname` / `suffix` / `salutation` / `NickName` / `gender` / `Birthdate` / `ssn` | mixed | **`ssn`/`Birthdate` sensitive** |
| Contact: `phone` / `phone_work` / `phone_work_ext` / `phone_cell` / `email` / `email2` / `Email1Confirmed` / `Email2Confirmed` | mixed | — |
| Address: `address` / `address2` / `city` / `state` / `country` / `zip` | nvarchar | — |
| Relationship: `relationship` / `custodialrights` / `financially_resp` / `receive_corr` / `maritalstatus` / `remove_from_family` / `remove_from_family_reason` / `deceased` / `unlisted_directory` | mixed | Household role flags |
| Employer/education: `occupation` / `jobtitle` / `JobDescription` / `employer` / `employer_address` / `employer_city` / `employer_state` / `employer_zip` / `degrees_earned` / `highest_education` / `highest_education_year` / `school_name` | mixed | — |
| Church: `religion` / `church` / `same_church` / `churchid` / `church_new_*` (phone/city/state/zip/street/senior_pastor/youth_pastor) | mixed | — |
| Prior-school history: `fromdate` / `todate` / `gradecompleted` | nvarchar | — |
| Emergency/pickup: `emergency_contact` / `emergency_contact_note` / `authorized_pickup` / `authorized_pickup_note` | mixed | — |
| `Photo` / `ECPUSortOrder` | mixed | — |

---

#### `dbo.OAAddressField`
Per-application configuration of the "recent school" address-history fields — which fields show/require and how many previous schools to collect.

| Column | Type | Notes |
|---|---|---|
| `onlineappid` | int | PK; → `dbo.OA` |
| `recent_school` | varchar(1) | Default 'r' |
| `rs_address` / `rs_city` / `rs_state` / `rs_zip` / `rs_phone` / `rs_fromdate` / `rs_todate` / `rs_gradecompleted` | varchar(1) | Field show/require flags; default '1' |
| `NumPreviousSchools` | tinyint | How many to collect; default 3 |

---

#### `dbo.OAAddressParentPreferences`
Per-student, per-parent (one_or_two) portal preferences — gradebook auto-email frequency, directory-block flags, and parent-alert phone routing. PK is composite `(studentid, one_or_two)`.

| Column | Type | Notes |
|---|---|---|
| `studentid` | int | PK (composite) |
| `one_or_two` | tinyint | PK (composite); which parent |
| `auto_email_gradebook` | varchar(6) | CHECK ∈ {WEEKLY, DAILY, NEVER, 0, ''} |
| `directory_block_name` / `directory_block_address` / `directory_block_phone` / `directory_block_cell_phone` / `directory_block_email` | varchar(1) | Directory-suppression flags |
| `parent_alert_home_phone` / `parent_alert_cell_phone` / `parent_alert_work_phone` / `parent_alert_no_text` | varchar(1) | Alert routing flags |

---

#### `dbo.OAAdditionalQuestionFormSchool`
Links additional-question forms to a packet, per school. FKs to `OAFormSchool` and `OAPacketSchool` (not yet documented).

| Column | Type | Notes |
|---|---|---|
| `AQFSID` | int IDENTITY | PK |
| `PacketSchoolID` | int | FK → `dbo.OAPacketSchool` |
| `FormSchoolID` | int | FK → `dbo.OAFormSchool` |

---

#### `dbo` mobile-subscription / newsletter / inquiry / OA — cross-reference summary

| Table | Scope | Key FK targets / notes |
|---|---|---|
| `Mobileapp_SubscriptionPurchaseDetails` | Mobile in-app subscription purchases | **Receipt data sensitive** |
| `Mobileapp_SubscriptionPersonNotifiedBulk` | Subscription bulk-notify tracking | → purchase details |
| `MobileApp_UsersAnalytics` | Mobile usage analytics | Per family/device |
| `NewsLetters` | Portal newsletter/document links | `IsHyperlink` |
| `NewStudentInquiry` | Prospective-student inquiry intake | **PII**; early admissions funnel |
| `OA` | Online-application definition/config | `rw.PortfolioGroup`; PK `onlineappid` |
| `OAAddress` | Per-applicant household/contact | **PII incl. `ssn`**; → `dbo.Person` |
| `OAAddressField` | Application address-history field config | → `dbo.OA` |
| `OAAddressParentPreferences` | Parent portal/directory preferences | PK `(studentid, one_or_two)`; gradebook-email CHECK |
| `OAAdditionalQuestionFormSchool` | Packet ↔ additional-question form link | `OAFormSchool`, `OAPacketSchool` |

---

### `dbo` Online Application (OA) tables — continued

This batch continues the OA subsystem (online admissions application). Pattern recap: `OA*Field` tables configure which fields an application shows/requires (keyed by `onlineappid` → `dbo.OA`); the bare `OA*` tables hold submitted applicant data (keyed by `studentid`); member/design/notify tables are per-`memberid`/school config.

#### `dbo.OAAlumni`
Alumni relationships submitted on an application — links a prospective student to a related alumnus (relationship + years attended).

| Column | Type | Notes |
|---|---|---|
| `alumnusid` | int IDENTITY | PK |
| `studentid` | int | Indexed |
| `alumniname` | nvarchar(50) | Nullable |
| `relationship` | nvarchar(125) | Nullable |
| `attended` | nvarchar(50) | Years attended; nullable |

---

#### `dbo.OAAlumniField`
Per-application config for the alumni section — which alumni fields show/require, plus an opening question. PK `onlineappid`.

| Column | Type | Notes |
|---|---|---|
| `onlineappid` | int | PK; → `dbo.OA` |
| `alumniname` / `relationship` | varchar(1) | Show/require flags; default 'r' |
| `attended` | varchar(1) | Default '1' |
| `opening_question` | nvarchar(max) | Section intro text; nullable |

---

#### `dbo.OADesign`
Per-member visual theme for the online application — colors (hex), fonts, logo, and extra CSS. PK `memberid`. Effectively a styling config row; most columns are 6-char hex color codes with defaults.

| Column group | Type | Notes |
|---|---|---|
| `memberid` | int | PK |
| `templateid` | smallint | Template selector; nullable |
| Colors: `body_bg` / `alink*` / `header*` / `header2*` / `alternatebg1`/`2` / `inside_page_bg` / `category_*` / `level1_*` / `level2_*` / `top_drop_*` / `footer` / `field_bg` / `fontcolor` | nvarchar(6) | Hex color codes with defaults |
| `fonttype` / `fontsize` | nvarchar/smallint | Font (default Arial, size 13) |
| `css_more` | nvarchar(max) | Additional CSS |
| `LogoPhoto` / `DisplayLogoWideScreen` | nvarchar/bit | Logo config |

---

#### `dbo.OAEmergencyPickup`
Emergency-contact / authorized-pickup people submitted on an application, per student — name, contact, address, and emergency/pickup flags + notes. The OA-application counterpart to `dbo.EmergencyContact`.

> **Contains PII**: contact names, phones, email, and addresses of third parties. Treat as confidential.

| Column group | Type | Notes |
|---|---|---|
| `contactid` | int IDENTITY | PK |
| `studentid` | int | Indexed |
| Name/contact: `firstname` / `lastname` / `relationship` / `phone` / `phone_cell` / `phone_work` / `email` | mixed | — |
| Address: `Address1` / `Address2` / `City` / `State` / `PostalCode` / `Country` | nvarchar | — |
| Flags/notes: `emergency_contact` / `authorized_pickup` / `emergency_contact_note` / `authorized_pickup_note` / `note` | mixed | — |
| `Photo` / `SortOrder` / `RefID` | mixed | — |

---

#### `dbo.OAEmergencyPickupField`
Per-application config for the emergency-contact/pickup section — which fields show. PK `onlineappid`.

| Column | Type | Notes |
|---|---|---|
| `onlineappid` | int | PK; → `dbo.OA` |
| `emergency_contact` / `authorized_pickup` | bit | Section show flags; default 1 |
| `ECPUPhoto` / `SortOrder` / `Address` | nvarchar(1) | Field show flags |

---

#### `dbo.OAEnrollmentNotify`
Per-school enrollment-notification email config by enroll type — subject, body, from address, CC, and graphic. PK is composite `(SchoolCode, enroll_type, IsPrimary)`.

| Column | Type | Notes |
|---|---|---|
| `SchoolCode` | varchar(50) | PK (composite) |
| `enroll_type` | varchar(1) | PK (composite); enrollment type |
| `IsPrimary` | bit | PK (composite); default 1 |
| `subject_line` | nvarchar(255) | Nullable |
| `email_body` | nvarchar(max) | Nullable |
| `from_email` / `CCEmail` | nvarchar | Sender/CC |
| `graphic_type` / `photo` | mixed | Graphic config |
| `counter` | int | Default 1 |

---

#### `dbo.OAEnterpriseLogin`
Enterprise/admin login accounts for the OA system, per member — name, role, email, and login code. CASCADE from `dbo.OAMember`.

> **Sensitive**: `LoginCode` is an access credential; don't expose in reports.

| Column | Type | Notes |
|---|---|---|
| `EnterpriseLoginID` | int IDENTITY | PK |
| `MemberID` | int | FK → `dbo.OAMember` (CASCADE) |
| `FirstName` / `LastName` | nvarchar | Required |
| `UserRole` | nvarchar(5) | Role; nullable |
| `EmailAddress` | nvarchar(256) | Nullable |
| `LoginCode` | nvarchar(35) | **Credential**; nullable |
| `CreatedDate` | smalldatetime | Required |

---

#### `dbo.OAFileUpload`
Files uploaded against an OA application, per member — name, size, folder, date. (Application-phase uploads.)

| Column | Type | Notes |
|---|---|---|
| `uploadid` | int IDENTITY | PK |
| `memberid` | int | Indexed |
| `filename` | nvarchar(255) | Required; default '' |
| `filesize` | int | Bytes; default 0 |
| `foldername` | nvarchar(50) | Default '/' |
| `uploaddate` | datetime | Nullable |

---

#### `dbo.OAFileUploadEnroll`
Same shape as `OAFileUpload` but for the **enrollment** phase (OE) rather than the application phase. Separate table per phase.

| Column | Type | Notes |
|---|---|---|
| `uploadid` | int IDENTITY | PK |
| `memberid` | int | Owning member |
| `filename` | nvarchar(255) | Required; default '' |
| `filesize` | int | Bytes; default 0 |
| `foldername` | nvarchar(50) | Default '/' |
| `uploaddate` | datetime | Nullable |

---

#### `dbo.OAForm`
Catalog of available application forms — form name/code, sort order, default-inclusion flags (separate for OA application vs OE enrollment), and family-vs-student scope. PK `formid` (not identity).

| Column | Type | Notes |
|---|---|---|
| `formid` | int | PK (app-assigned) |
| `formname` | nvarchar(100) | Required |
| `formcode` | nvarchar(20) | Nullable |
| `sortorder` | int | Required |
| `config_options` | char(1) | Default '0' |
| `include_by_default` | char(1) | Include in OA app; default '1' |
| `include_by_default_oe` | char(1) | Include in OE enrollment; default '0' |
| `apptype` | nvarchar(4) | Default 'OA' |
| `SecondParentInclude` | bit | Default 1 |
| `FamilyOrStudent` | nvarchar(7) | Scope; default 'Student' |

---

#### `dbo` OA (continued) — cross-reference summary

| Table | Scope | Key FK targets / notes |
|---|---|---|
| `OAAlumni` | Applicant alumni relationships | By `studentid` |
| `OAAlumniField` | Alumni-section field config | → `dbo.OA` |
| `OADesign` | Per-member application theme | PK `memberid`; hex colors |
| `OAEmergencyPickup` | Applicant emergency/pickup contacts | **PII**; cf. `dbo.EmergencyContact` |
| `OAEmergencyPickupField` | Emergency/pickup field config | → `dbo.OA` |
| `OAEnrollmentNotify` | Enrollment-notify email config | PK `(SchoolCode, enroll_type, IsPrimary)` |
| `OAEnterpriseLogin` | OA admin login accounts | CASCADE from `dbo.OAMember`; **`LoginCode` credential** |
| `OAFileUpload` | Application-phase file uploads | By `memberid` |
| `OAFileUploadEnroll` | Enrollment-phase file uploads | Same shape, OE phase |
| `OAForm` | Application form catalog | OA vs OE default-inclusion flags |

---

### `dbo` Online Application (OA) tables — continued (forms, household, info)

#### `dbo.OAForm` / `dbo.OAFormSchool` relationship
`OAForm` (documented previously) is the global form catalog; **`OAFormSchool`** is the per-application instance of a form (which forms a given `onlineappid` includes, with intro text and PDF options). `OAFormCompleted` tracks per-student completion of an `OAFormSchool`.

#### `dbo.OAFormSchool`
A form attached to a specific online application — links `OAForm` to `OA`, with active flag, intro text, PDF/review options, and family-vs-student scope. PK `FormSchoolID`. FKs to `OAForm`, `OA`, and `rw.PortfolioGroup`.

| Column | Type | Notes |
|---|---|---|
| `FormSchoolID` | int IDENTITY | PK; referenced by `OAFormCompleted`, `OAAdditionalQuestionFormSchool` |
| `formid` | int | FK → `dbo.OAForm` |
| `onlineappid` | int | FK → `dbo.OA` |
| `formname` | nvarchar(100) | Required |
| `isactive` | varchar(1) | Default '1' |
| `formintro` | nvarchar(max) | Intro HTML; nullable |
| `IntroSentence` | nvarchar(2000) | Short intro; nullable |
| `intro_on_review_pdf` / `SavePDF` | bit | PDF options; default 0 |
| `SchoolSortOrder` | tinyint | Nullable |
| `FamilyOrStudent` | nvarchar(7) | Scope; default 'Student' |
| `BeforeAfterStudents` | nvarchar(6) | Placement; default 'Before' |
| `MultiSchoolFormSchoolID` | int | Multi-school linkage; nullable |
| `PortfolioGroupId` | int | FK → `rw.PortfolioGroup`; nullable |

---

#### `dbo.OAFormCompleted`
Per-student completion status of a form on an application. PK is composite `(FormSchoolID, studentid)`; FK to `OAFormSchool`.

| Column | Type | Notes |
|---|---|---|
| `FormSchoolID` | int | PK (composite); FK → `dbo.OAFormSchool` |
| `studentid` | int | PK (composite) |
| `completed` | varchar(1) | Completion flag; default '0' |

---

#### `dbo.OAGenericAcknowledgeForm`
Per-application config for a generic acknowledgement/signature form — signature titles, type-your-name toggles, and whether the second signature is required. PK is composite `(OnlineAppID, FormID)`; FKs to `OA` and `OAForm`.

| Column | Type | Notes |
|---|---|---|
| `OnlineAppID` | int | PK (composite); FK → `dbo.OA` |
| `FormID` | int | PK (composite); FK → `dbo.OAForm` |
| `Title1` / `Title2` | nvarchar(255) | Signature line labels |
| `TypeYourName1` / `TypeYourName2` | bit | Allow typed signature; default 1 |
| `Title2Req` | bit | Second signature required; default 1 |

---

#### `dbo.OAGenericAcknowledgeStudent`
Per-student signatures captured for a generic acknowledgement form — names, dates, and signature images. PK is composite `(StudentID, FormID)`; FKs to `OAForm` and `OAStudent`.

| Column | Type | Notes |
|---|---|---|
| `StudentID` | int | PK (composite); FK → `dbo.OAStudent` |
| `FormID` | int | PK (composite); FK → `dbo.OAForm` |
| `SignedName1` / `SignedName2` | nvarchar(100) | Typed signatures; nullable |
| `SignedDate1` / `SignedDate2` | smalldatetime | Nullable |
| `SignedName1Img` / `SignedName2Img` | nvarchar(max) | Signature images (data URI); nullable |

---

#### `dbo.OAGrade`
Grade levels offered/accepted by an online application. PK is composite `(onlineappid, GradeLevel)`.

| Column | Type | Notes |
|---|---|---|
| `onlineappid` | int | PK (composite); → `dbo.OA` |
| `GradeLevel` | nvarchar(50) | PK (composite) |

---

#### `dbo.OAHouseholdField`
Per-application configuration of the **household/parent section** fields — a very wide flags table where each `p_*` (parent), `g_*` (grandparent), and church/ssn/photo column is a single-char show/require flag ('r' = required, '1' = shown, '' = hidden), plus a few label-override columns. PK `onlineappid`.

This table mirrors the data fields of `dbo.OAAddress`: for each contact field there's a matching `OAHouseholdField` flag controlling whether the application asks for it. Notable: the **`ssn`** flag here gates whether SSN is collected from the household.

| Column group | Type | Notes |
|---|---|---|
| `onlineappid` | int | PK; → `dbo.OA` |
| Parent fields `p_*` | varchar(1) | Show/require flags for parent name, contact, address, employer, education, religion/church (with `_label` overrides) |
| Grandparent fields `g_*` | varchar(1) | Show/require flags for grandparent block |
| `ssn` | varchar(1) | Whether SSN is collected; default '' (hidden) |
| Church-new fields | varchar(1) + label cols | New-church capture flags + labels |
| Photo/misc: `ParentPhoto` / `GrandparentPhoto` / `p_NickName` / `p_Birthdate` / `NicknameLabel` / `unlisted_directory` / `hide_new_church` / `GFinanciallyResp` | mixed | Misc flags/labels |

---

#### `dbo.OAHouseholdFieldParentPreferences`
Per-application config controlling whether the parent-preferences options (gradebook auto-email, directory blocks, parent-alert routing) are shown on the application. The config counterpart to `dbo.OAAddressParentPreferences` (which stores the submitted values). PK `onlineappid`.

| Column | Type | Notes |
|---|---|---|
| `onlineappid` | int | PK; → `dbo.OA` |
| `auto_email_gradebook` | bit | Show option; default 0 |
| `directory_block_name` / `_address` / `_phone` / `_cell_phone` / `_email` | bit | Show directory-block options; default 0 |
| `parent_alert_home_phone` / `_cell_phone` / `_work_phone` / `_no_text` | bit | Show alert-routing options; default 0 |

---

#### `dbo.OAImport`
Minimal import-tracking table for OA — maps an import run to a file GUID.

| Column | Type | Notes |
|---|---|---|
| `OAImportID` | int IDENTITY | PK |
| `FileGUID` | uniqueidentifier | Imported file id; indexed |

---

#### `dbo.OAInfo`
**The main per-student online-application info record** — one row per `studentid` holding the student's submitted demographics, contact, citizenship/language, birth info, religion, signature/acknowledgement timestamps + images, household-grade flags, vehicle/driver info, tuition payment, and SmartTuition linkage. PK `studentid`.

> **Contains PII**: `ssn`, birth city/state/country, `DriversLicense`, addresses, phones, signature images. Treat as confidential; never expose `ssn`/`DriversLicense`.

Documented by column group (~70 columns):

| Column group | Type | Notes |
|---|---|---|
| `studentid` | int | PK |
| Identity/contact: `nickname` / `ssn` / `home_phone` / `cell_phone` / `email` / `address` / `address2` / `city` / `state` / `country` / `zip` / `district_residence` / `gender` / `ethnicity` | mixed | **`ssn` sensitive** |
| Citizenship/birth: `citizenship` / `language_spoken` / `birth_city` / `birth_state` / `birth_country` | nvarchar | — |
| Religion/church: `religion` / `senior_pastor` / `church_member` | mixed | — |
| Signatures/acks: `parent_stmt` / `student_stmt_parent` / `student_stmt_student` / `elec_sig_first`/`_second` (+ `_name`, `_img`) / `parent_ack_area1`/`2` (+ `_name`, `Img`) / `StudentStmtParentImg` / `ParentStmtImg` / `StudentStmtStudentImg` | mixed | Date + typed-name + image triples |
| Section flags: `previous_schools` / `previous_schools2` / `PreviousSchools3` / `alumni` / `siblings` / `household2` / `h1g1`–`h1g4` / `h2g1`–`h2g4` | varchar(1)/bit | Which sections/grades apply |
| Vehicle/driver: `AutoMake` / `AutoModel` / `AutoLicense` / `DriversLicense` / `will_drive` | nvarchar | **`DriversLicense` sensitive** |
| Prior district: `DistrictCounty` / `DistrictSchool` / `DistrictState` / `ClassOf` | nvarchar | — |
| Tuition: `TuitionPaymentMethod` / `SmartTuitionFamilyID` / `SmartTuitionStudentID` / `TuitionContractAcknowledge` / `TuitionContractNotRequiredToSignDisplayed` | mixed | SmartTuition integration |
| `photo` / `EmailConfirmed` | mixed | — |

---

#### `dbo.OAInfoAnswer`
Answers to configurable application questions, per question × student × signer (one_or_two), with optional signature image. PK is composite `(questionid, studentid, one_or_two)`.

| Column | Type | Notes |
|---|---|---|
| `questionid` | int | PK (composite) |
| `studentid` | int | PK (composite) |
| `one_or_two` | varchar(2) | PK (composite); which signer/parent; default '1' |
| `answer` | nvarchar(max) | Answer text; nullable |
| `SignatureImg` | nvarchar(max) | Signature image; nullable |

---

#### `dbo` OA (forms/household/info) — cross-reference summary

| Table | Scope | Key FK targets / notes |
|---|---|---|
| `OAFormSchool` | Form attached to an application | `OAForm`, `OA`, `rw.PortfolioGroup`; PK `FormSchoolID` |
| `OAFormCompleted` | Per-student form completion | → `OAFormSchool` |
| `OAGenericAcknowledgeForm` | Acknowledgement-form config | `OA`, `OAForm` |
| `OAGenericAcknowledgeStudent` | Captured acknowledgement signatures | `OAForm`, `OAStudent` |
| `OAGrade` | Grade levels offered by an app | PK `(onlineappid, GradeLevel)` |
| `OAHouseholdField` | Household-section field config | Mirrors `OAAddress`; `ssn` flag |
| `OAHouseholdFieldParentPreferences` | Parent-prefs option config | Counterpart to `OAAddressParentPreferences` |
| `OAImport` | OA import file tracking | By `FileGUID` |
| `OAInfo` | **Main per-student application info** | **PII incl. `ssn`/`DriversLicense`**; SmartTuition linkage |
| `OAInfoAnswer` | Configurable question answers | PK `(questionid, studentid, one_or_two)` |

---

### `dbo` Online Application (OA) tables — continued (info fields, question engine, inquiry)

#### `dbo.OAInfoField`
Per-application configuration of the **student-info section** fields — single-char show/require flags ('r' required, '1' shown, '0' hidden) for each `OAInfo` field, plus signature/statement title labels, tuition-contract config, and required toggles. The config counterpart to `dbo.OAInfo`. PK `onlineappid`; FK to `rw.PortfolioGroup`.

Notable: the **`ssn`** and **`DriversLicense`** flags here gate whether those sensitive fields are collected. `TuitionContractSigningTime` is CHECK-constrained to {After, During, ''}.

| Column group | Type | Notes |
|---|---|---|
| `onlineappid` | int | PK; → `dbo.OA` |
| Field show/require flags: `nickname` / `ssn` / `home_phone` / `cell_phone` / `email` / `howhear` / `address` / `city` / `state` / `country` / `zip` / `district_residence` / `gender` / `ethnicity` / `citizenship` / `language_spoken` / `religion` / `senior_pastor` / `church_member` / `birth_*` / `photo` / `race` / `MiddleName` / `DistrictCounty` / `DistrictSchool` / `DistrictState` / `ClassOf` | varchar(1) | 'r'/'1'/'0' per field |
| Vehicle: `AutoMake` / `AutoModel` / `AutoLicense` / `DriversLicense` | varchar(1) | Show flags (gates sensitive vehicle/license data) |
| Signature config: `elec_sig_first_show_name` / `elec_sig_second_show_name` / `elec_sig_second_show` / `Elec_sig_secondReq` / `parent_stmt_name` / `student_stmt_parent_name` / `student_stmt_student_name` / `parent_ack_area1_name` / `parent_ack_area2_name` / `Parent_ack_area2Req` / `StudentStmt2Req` | mixed | Signature/statement visibility & required |
| Labels: `NicknameLabel` / `ParentStmtTitle` / `StudentStmtTitle1` / `StudentStmtTitle2` | nvarchar | Display-label overrides |
| `StudentNameChange` | bit | Allow name change; default 1 |
| Tuition: `TuitionContractAcknowledge` / `TuitionContractSigningTime` (CHECK {After, During, ''}) / `TuitionContractPortfolioGroupId` | mixed | `...PortfolioGroupId` FK → `rw.PortfolioGroup` |

---

### `dbo` OA configurable-question engine

A small engine for custom application questions: `OAInfoQuestion` is the legacy/global question; **`OAInfoQuestionMember`** is the per-application question (the live one); `OAInfoQuestionMemberOption` holds its choices; `OAInfoQuestionMemberOptionConditional` drives conditional show/hide of follow-up questions. Answers are stored in `dbo.OAInfoAnswer` (documented previously).

#### `dbo.OAInfoQuestion`
Global/legacy custom-question definition — question text, type, optional form linkage.

| Column | Type | Notes |
|---|---|---|
| `questionid` | int IDENTITY | PK |
| `formid` | int | → form; indexed; nullable |
| `question` | nvarchar(max) | Required |
| `question_type` | char(1) | Required |
| `sortorder` | int | Required |

---

#### `dbo.OAInfoQuestionMember`
**Per-application custom question** — the active question instance attached to an `OAFormSchool`, with type, required flag, conditional flag, RenWeb field mapping (`renweb_fieldid`), and UD origin. FKs to `OAFormSchool` and `rw.PortfolioGroup`.

| Column | Type | Notes |
|---|---|---|
| `questionid` | int IDENTITY | PK |
| `onlineappid` | int | → `dbo.OA` |
| `formid` | int | Indexed |
| `FormSchoolID` | int | FK → `dbo.OAFormSchool`; indexed |
| `question` | nvarchar(max) | Required |
| `question_label` | nvarchar(50) | Nullable |
| `question_type` | varchar(1) | Nullable |
| `required` / `isactive` / `isdate` | varchar(1) | Flags ('0'/'1') |
| `IsConditional` | bit | Drives conditional logic; default 0 |
| `renweb_fieldid` | int | Maps answer to a RenWeb UD field; nullable |
| `ud_origin` | varchar(1) | Default 'C' (custom) |
| `numcols` | int | Layout columns; default 3 |
| `FormSection` / `SignatureCheckLabel` | nvarchar | Layout/labels |
| `MultiSchoolQuestionID` | smallint | Multi-school linkage; nullable |
| `EventServiceID` | int | Nullable |
| `PortfolioGroupId` | int | FK → `rw.PortfolioGroup`; default 0 |

---

#### `dbo.OAInfoQuestionMemberOption`
Answer options for a member question (for select/radio types).

| Column | Type | Notes |
|---|---|---|
| `optionid` | int IDENTITY | PK |
| `questionid` | int | → `OAInfoQuestionMember` |
| `optionname` | nvarchar(250) | Option label; nullable |
| `sortorder` | smallint | Required |

---

#### `dbo.OAInfoQuestionMemberOptionConditional`
Conditional display rules — when a given option (or yes/no answer) is chosen on one question, show/hide another question. Self-referential through `OAInfoQuestionMember` (two FKs: the triggering `QuestionID` and the `DisplayQuestionID` to show/hide, the latter CASCADE) and `OAInfoQuestionMemberOption` (CASCADE).

| Column | Type | Notes |
|---|---|---|
| `ConditionalID` | int IDENTITY | PK |
| `QuestionID` | int | FK → `OAInfoQuestionMember` (the trigger question) |
| `OptionID` | int | FK → `OAInfoQuestionMemberOption` (CASCADE); nullable |
| `YesOrNo` | nvarchar(3) | Trigger on yes/no answer; nullable |
| `DisplayQuestionID` | int | FK → `OAInfoQuestionMember` (CASCADE); the question to show/hide |
| `ShowIt` | bit | Show (1) or hide (0) when condition met; default 1 |
| `UDFieldName` | nvarchar(128) | Optional UD field driver; nullable |

---

#### `dbo.OAInfoRace`
Race selections for an applicant (multi-select). CASCADE from `dbo.OAStudent`. PK is composite `(studentid, race)`.

| Column | Type | Notes |
|---|---|---|
| `studentid` | int | PK (composite); FK → `dbo.OAStudent` (CASCADE) |
| `race` | nvarchar(256) | PK (composite); a selected race value |

---

### `dbo` OA inquiry (admissions funnel) tables

The **inquiry** tables support the public admissions inquiry/lead-capture flow (before a full application), per `memberid`.

#### `dbo.OAInquiryBySchool`
Maps an inquiry member to the schools it covers. PK is composite `(memberid, SchoolCode)`.

| Column | Type | Notes |
|---|---|---|
| `memberid` | int | PK (composite) |
| `SchoolCode` | varchar(50) | PK (composite) |

---

#### `dbo.OAInquiryLang`
Per-member, per-language localized text for the inquiry/admissions pages — labels, intro/thank-you/notify text, email subjects (with separate OE variants), and button labels. CASCADE from `dbo.OAMember`; FK to `ref.LanguageCode`.

| Column | Type | Notes |
|---|---|---|
| `InquiryLangID` | int IDENTITY | PK |
| `MemberID` | int | FK → `dbo.OAMember` (CASCADE) |
| `LangCode` | char(2) | FK → `ref.LanguageCode` |
| Labels/text: `InquiryLabel` / `IntroText` / `HowHearLabel` / `ThankYouText` / `EmailNotifyText` / `EmailSubjectLine` / `AdmissionsLabel` / `AdmissionsText` / `SchoolLinkTitle` / `ParentAccessText` | mixed | Localized content |
| Account emails: `CreateAccountEmailText` / `CreateAccountEmailSubject` / `CreateAccountEmailTextOE` / `CreateAccountEmailSubjectOE` | nvarchar | OA + OE variants |
| Buttons: `AdmissionsHomePrimaryButtonLabel` / `AdmissionsHomeSecondaryButtonLabel` | nvarchar(100) | — |

---

#### `dbo.OAInquiryReportTemplateColumn`
Column definitions for inquiry report templates — each row maps a report column to one of several possible sources (standard reporting type, request-info question, tracking config/items, or interest/category). Many FKs, several CASCADE. Audit columns are UTC.

| Column | Type | Notes |
|---|---|---|
| `OAInquiryReportTemplateColumnId` | int IDENTITY | PK |
| `OAReportTemplateColumnId` | int | FK → `dbo.OAReportTemplateColumn`; clustered |
| `OAStandardReportingTypeId` | int | FK → `ref.OAStandardReportingType`; nullable |
| `OARequestInfoQuestionId` | int | FK → `dbo.OARequestInfoQuestion` (CASCADE); nullable |
| `TrackingConfigId` | int | FK → `dbo.TrackingConfig` (CASCADE); nullable |
| `TrackingItemsId` | int | FK → `dbo.TrackingItems` (CASCADE); nullable |
| `InterestCategoryId` | int | FK → `dbo.InterestCategory` (CASCADE); nullable |
| `InterestId` | int | FK → `dbo.Interest` (CASCADE); nullable |
| `CreateId` / `CreateDate` / `UpdateId` / `UpdateDate` | int/datetime | UTC audit |

---

#### `dbo.OAInquiryTask`
Links an admissions task (`OATask`) to an inquiry student (`OARequestInfoStudent`). FKs to both; clustered on the student.

| Column | Type | Notes |
|---|---|---|
| `OAInquiryTaskId` | int IDENTITY | PK (non-clustered) |
| `OATaskId` | int | FK → `dbo.OATask`; unique |
| `OARequestInfoStudentId` | int | FK → `dbo.OARequestInfoStudent`; clustered |
| `CreateId` / `CreateDate` / `UpdateId` / `UpdateDate` | int/datetime | UTC audit |

---

#### `dbo` OA (info-field / question-engine / inquiry) — cross-reference summary

| Table | Scope | Key FK targets / notes |
|---|---|---|
| `OAInfoField` | Student-info section field config | Config for `OAInfo`; `ssn`/`DriversLicense` gates; `rw.PortfolioGroup` |
| `OAInfoQuestion` | Global/legacy custom question | — |
| `OAInfoQuestionMember` | Per-application custom question | `OAFormSchool`, `rw.PortfolioGroup`; `renweb_fieldid` mapping |
| `OAInfoQuestionMemberOption` | Member-question answer options | → `OAInfoQuestionMember` |
| `OAInfoQuestionMemberOptionConditional` | Conditional show/hide rules | Self-ref `OAInfoQuestionMember` (CASCADE), `...Option` (CASCADE) |
| `OAInfoRace` | Applicant race multi-select | CASCADE from `OAStudent` |
| `OAInquiryBySchool` | Inquiry member ↔ schools | PK `(memberid, SchoolCode)` |
| `OAInquiryLang` | Localized inquiry page text | CASCADE from `OAMember`; `ref.LanguageCode` |
| `OAInquiryReportTemplateColumn` | Inquiry report column mapping | `OAReportTemplateColumn`, `ref.OAStandardReportingType`, tracking/interest (CASCADE) |
| `OAInquiryTask` | Admissions task ↔ inquiry student | `OATask`, `OARequestInfoStudent` |

---

### `dbo` Online Application (OA) tables — continued (medical, member, packet, parent)

### `dbo` OA medical-form tables

The applicant medical form: `OAMedicalForm` is the per-student health record; `OAMedicalAllergy`/`OAMedicalCondition` are its multi-row child lists; `OAMedicalFormField` configures which fields show. `OAOTCConfig` configures over-the-counter medication options.

> **Contains health PII (HIPAA-adjacent)**: doctor/dentist/hospital, insurance, blood type, allergies, conditions, medications. Treat all `OAMedical*` tables as confidential health data.

#### `dbo.OAMedicalForm`
Per-student medical form submitted on an application — doctor/dentist/hospital, insurance, blood type, permission-to-treat, and yes/no flags for conditions/allergies/medications. Keyed by `studentid` (no explicit PK constraint in DDL; one row per student in practice).

| Column group | Type | Notes |
|---|---|---|
| `studentid` | int | The applicant |
| Providers: `Doctor` / `Doctor_Phone` / `Doctor_Address` / `Hospital` / `Dentist` / `Dentist_Phone` / `Dentist_Address` | nvarchar(128) | Required (NOT NULL) |
| Insurance: `Insurance_Company` / `Insurance_Policy` / `Insurance_Group` | nvarchar(128) | Required |
| `Blood_Type` | nvarchar(50) | Required |
| `Permission_To_Treat` | varchar(1) | Nullable |
| `ConditionsYN` / `AllergiesYN` | varchar(1) | Has-conditions/allergies flags |
| `MedicationsYN` | bit | Default 1 |

---

#### `dbo.OAMedicalAllergy`
Allergy entries for an applicant (multi-row child of the medical form).

| Column | Type | Notes |
|---|---|---|
| `AllergyID` | int IDENTITY | PK |
| `StudentID` | int | The applicant |
| `Allergy` | nvarchar(255) | Nullable |
| `Comment` | nvarchar(255) | Nullable |

---

#### `dbo.OAMedicalCondition`
Medical condition entries for an applicant (multi-row child of the medical form).

| Column | Type | Notes |
|---|---|---|
| `ConditionID` | int IDENTITY | PK |
| `StudentID` | int | The applicant |
| `Condition` | nvarchar(512) | Nullable |
| `Comment` | nvarchar(512) | Nullable |

---

#### `dbo.OAMedicalFormField`
Per-application config for the medical-form fields — single-char show/require flags plus permission-to-treat text. Config counterpart to `OAMedicalForm`. PK `onlineappid`.

| Column | Type | Notes |
|---|---|---|
| `onlineappid` | int | PK; → `dbo.OA` |
| Field flags: `Doctor` / `Doctor_Phone` / `Doctor_Address` / `Hospital` / `Dentist*` / `Insurance_*` / `Blood_Type` / `Permission_To_Treat` / `Conditions` / `Allergies` / `OTC` / `Medications` | nvarchar(1)/varchar(1) | 'r'/'1'/'' show-require flags |
| `PermissionToTreatText` | nvarchar(max) | Permission statement text; nullable |

---

#### `dbo.OAOTCConfig`
Per-application display config for over-the-counter (OTC) medication options. PK is composite `(onlineappid, OTCID)`.

| Column | Type | Notes |
|---|---|---|
| `onlineappid` | int | PK (composite); → `dbo.OA` |
| `OTCID` | int | PK (composite); the OTC item |
| `DisplayOption` | varchar(1) | Display mode; default '?' |

---

### `dbo` OA member / packet / parent tables

#### `dbo.OAMember`
**The top-level OA "member" config** (per school/organization) — the parent record that most OA config and content tables CASCADE from (`OAEnterpriseLogin`, `OAInquiryLang`, `OAMemberLang`, etc.). Controls admissions/inquiry/enrollment toggles, branding, payment/merchant setup, submission fees (application/enrollment, new/returning), email templates (OA + OE variants), languages, waitlist, and analytics. PK `memberid`.

Documented by column group:

| Column group | Type | Notes |
|---|---|---|
| `memberid` | int | PK |
| Branding: `custom_design` / `banner_photo` / `bannertitle` / `swf_height` / `vhost_domain` / `back_title` / `back_url` / `BackOnClick` | mixed | Look/host config |
| Module toggles: `admissions_on` / `admissions_label` / `inquiry_on` / `inquiry_label` / `parent_access_on` / `EnrollmentOnlineLabel` / `inquiry_by_school` / `InquirySelectSchoolYears` | mixed | Feature switches + labels |
| Payment: `do_payment` / `merchant_account_ready` / `do_payment_oe` / `merchant_account_ready_oe` / `family_based_oe_fee` / `BillingProvider` / `TuitionService` / `TuitionSchoolCode` | mixed | Merchant/payment setup (OA + OE) |
| Submission fees: `ApplicationSubmissionFee` / `EnrollmentSubmissionFeeReturning` / `EnrollmentSubmissionFeeNew` / `EnrollmentSubmissionFeeNewApplication` / `FeesUpdatedDate` | decimal/date | Fee schedule |
| Email templates: `create_account_email`(+`_subject`,`_from`) / `request_info_email`(+`_from`,`_subject`,`_link`) / `CreateAccountEmailOE`(+`SubjectOE`,`FromOE`) / `WillNotEnrollEmail` | mixed | OA + OE email content |
| Review/flow: `NewApplicationReview` / `NewEnrollmentReview` / `RequestInfoCreateAccountOn` / `CreateAccountOALinksEnabled` / `WillNotEnrollEnabled` / `StandaloneStatus` / `OEBatchImport` | bit | Workflow toggles |
| Signatures: `DualSignatureType` / `RealSignatures` / `CreateAppAcctAgreeTitle` / `TuitionContractForm` | mixed | Signature config |
| Waitlist: `WaitlistEnabled` / `WaitlistType` | bit/int | — |
| Languages: `Languages` / `InquiryLangDefault` | nvarchar | Default 'en' |
| Analytics: `GoogleAnalyticsUA` / `AnalyticsType` | mixed | Default 'GA' |
| Admissions-home buttons: `AdmissionsHomePrimaryButton*` / `AdmissionsHomeSecondaryButton*` (Url/Label) | nvarchar | — |
| `adjust_settings` / `EventServiceOrgID` | mixed | — |

---

#### `dbo.OAMemberLang`
Per-member, per-language label overrides (currently just a gender label). CASCADE from `dbo.OAMember`; FK to `ref.LanguageCode`.

| Column | Type | Notes |
|---|---|---|
| `MemberLangID` | int IDENTITY | PK |
| `MemberId` | int | FK → `dbo.OAMember` (CASCADE) |
| `LangCode` | char(2) | FK → `ref.LanguageCode` |
| `GenderLabel` | nvarchar(50) | Nullable |

---

#### `dbo.OAOEPacketNotAllowed`
Suppression list — parent/student (by RenWeb `Person` IDs) who are not allowed an OE (online enrollment) packet for a given school year. Both IDs FK to `dbo.Person`.

| Column | Type | Notes |
|---|---|---|
| `PacketNotAllowedID` | int IDENTITY | PK |
| `RenWebParentID` | int | FK → `dbo.Person` |
| `RenWebStudentID` | int | FK → `dbo.Person` |
| `SchoolYear` | nvarchar(50) | Nullable |

---

#### `dbo.OAPacketSchool`
A packet instance for an application/member. PK `PacketSchoolID` (referenced by `OAAdditionalQuestionFormSchool`). FK to `dbo.OA`.

| Column | Type | Notes |
|---|---|---|
| `PacketSchoolID` | int IDENTITY | PK; referenced by `OAAdditionalQuestionFormSchool` |
| `OnlineAppID` | int | FK → `dbo.OA` |
| `MemberID` | int | Owning member |

---

#### `dbo.OAParent`
**OA parent login account** — the credential record for a parent using the online application/enrollment portal. Username, password (hashed in `Password2`), contact, verification flags, multi-school linkage, and a set of `deprecated_*` columns retained during a migration. PK `parentid`.

> **Sensitive**: `passwd` / `Password2` are authentication credentials; `username`/`email`/contact are PII. Never expose credentials. Note `passwd` is indexed (legacy plaintext-ish lookup); `Password2` is the `varbinary` hashed password with `PasswordVersion`.

| Column group | Type | Notes |
|---|---|---|
| `parentid` | int IDENTITY | PK |
| `memberid` | int | Indexed; owning member |
| Credentials: `username` / `passwd` / `Password2` (varbinary) / `PasswordVersion` / `ForcePasswordChange` | mixed | **Credentials**; `username`/`passwd` indexed |
| Identity: `firstname` / `lastname` / `email` / `phone` | nvarchar | PII |
| Verification: `EmailVerified` / `EmailVerifiedOE` | bit | OA + OE |
| Status: `isactive` / `test_account` / `createddate` | mixed | — |
| Linkage: `MultiSchoolParentID` / `OERenWebParentID` / `OAPWLinkPersonID` | int | Cross-system parent links |
| Migration: `deprecated_username` / `original_username` / `deprecated_firstname` / `deprecated_lastname` / `deprecated_email` / `deprecated_phone` / `deprecated_password2` / `deprecated_processed` | mixed | Retained during username/password migration |

**Trigger** `TR_dbo_OAParent_Update` (AFTER UPDATE): when `FirstName`, `LastName`, or `Email` changes, posts a demographic-sync event to the UserMS API via `dbo.Passport_DemographicSync` (builds a JSON body with district code + changed parent IDs). **Skipped on Linux/container databases** (checks `@@VERSION NOT LIKE '%Linux%'` because the sync uses an EXTERNAL_ACCESS assembly unavailable on Linux). This is the Passport/UserMS identity-sync integration.

---

#### `dbo` OA (medical / member / packet / parent) — cross-reference summary

| Table | Scope | Key FK targets / notes |
|---|---|---|
| `OAMedicalForm` | Applicant medical record | **Health PII**; by `studentid` |
| `OAMedicalAllergy` | Applicant allergies | Child of medical form |
| `OAMedicalCondition` | Applicant conditions | Child of medical form |
| `OAMedicalFormField` | Medical-form field config | Config for `OAMedicalForm` |
| `OAOTCConfig` | OTC medication option config | PK `(onlineappid, OTCID)` |
| `OAMember` | **Top-level OA member config** | PK `memberid`; CASCADE parent for many OA tables |
| `OAMemberLang` | Per-member language labels | CASCADE from `OAMember`; `ref.LanguageCode` |
| `OAOEPacketNotAllowed` | OE packet suppression list | Both IDs → `dbo.Person` |
| `OAPacketSchool` | Packet instance | → `dbo.OA`; referenced by `OAAdditionalQuestionFormSchool` |
| `OAParent` | **OA parent login account** | **Credentials + PII**; Passport/UserMS sync trigger |

---

### `dbo` Online Application (OA) tables — continued (payment, referral engine, religion config)

### `dbo` OA payment tables

#### `dbo.OAPayment`
Recorded application/enrollment payments per student — transaction id, amount, billing name/address/contact, and processed status. The OA payment transaction log.

> **Contains PII / payment data**: account holder name, billing address, phone, email, transaction ids. Treat as confidential.

| Column | Type | Notes |
|---|---|---|
| `paymentid` | int IDENTITY | PK |
| `studentid` | int | The applicant |
| `transid` | varchar(36) | Gateway transaction id; indexed |
| `transdate` | smalldatetime | Required |
| `amount` | decimal(19,4) | Required |
| `accountholder` | nvarchar(100) | Required; billing name |
| Billing: `street` / `city` / `state` / `zip` / `dayphone` / `email` | nvarchar | Billing contact |
| `production_or_test` | varchar(1) | Environment flag; nullable |
| `processed` | bit | Default 0 |
| `ReturnTransID` | int | Refund linkage; nullable |
| `TransactionAccType` | nvarchar(20) | Account type; nullable |
| `EffectiveDate` | smalldatetime | Nullable |

---

#### `dbo.OAPaymentAdvanced`
Advanced (tiered) fee schedule per application — early/regular/late fee windows by grade level, enrollment type, and staff flag. PK is composite `(onlineappid, GradeLevel, enrollmenttype, isstaff)`.

| Column | Type | Notes |
|---|---|---|
| `onlineappid` | int | PK (composite); → `dbo.OA` |
| `GradeLevel` | nvarchar(50) | PK (composite) |
| `enrollmenttype` | nvarchar(50) | PK (composite) |
| `isstaff` | bit | PK (composite) |
| `earlydate` / `earlyfee` | smalldatetime/decimal | Early-bird window |
| `regdate` / `regfee` | smalldatetime/decimal | Regular window |
| `latedate` / `latefee` | smalldatetime/decimal | Late window |
| `enddate` | smalldatetime | Cutoff |
| `OEFeeWaived` / `FeeWaived` | bit | Waiver flags; default 0 |

---

#### `dbo.OAPayOption`
Named payment options for an application — labeled choices each with up to four school-fee amounts. PK `optionid`.

| Column | Type | Notes |
|---|---|---|
| `optionid` | int IDENTITY | PK |
| `onlineappid` | int | → `dbo.OA` |
| `optionname` | nvarchar(100) | Required |
| `sortorder` | smallint | Required |
| `school_fee1`–`4` | decimal(6,2) | Fee components; nullable |
| `description` | nvarchar(max) | Nullable |

---

### `dbo` OA referral (recommendation) engine

The **referral** subsystem handles recommendation/reference forms (e.g. teacher or pastor references) sent as part of an application. It parallels the `OAInfoQuestion*` engine but adds grids: `OAReferral` is the referral document/form; `OAReferralQuestion` its questions; `OAReferralQuestionOption` the choices; `OAReferralQuestionGrid` grid rows; and the `*Answer` tables hold submitted responses keyed by `StudentReferralID`.

#### `dbo.OAReferral`
A referral/recommendation form attached to an application — title, email subject/body (sent to the referrer), graphic, required flag, and portfolio category. FKs to `dbo.OA` and `rw.PortfolioGroup` (via `PortfolioCategory`).

| Column | Type | Notes |
|---|---|---|
| `ReferralID` | int IDENTITY | PK |
| `OnlineAppID` | int | FK → `dbo.OA` |
| `DocTitle` | nvarchar(100) | Required |
| `SortOrder` | tinyint | Required |
| `EmailSubject` / `EmailBody` | nvarchar | Sent to referrer; nullable |
| `BottomEditor` | nvarchar(max) | Footer content; nullable |
| `ItemID` | int | Nullable |
| `Photo` / `GraphicType` | nvarchar | Graphic (default 'sl') |
| `Counter` | smallint | Default 1 |
| `IsActive` / `IsRequired` | bit | Default 1 |
| `PortfolioCategory` | int | FK → `rw.PortfolioGroup`; default 0 |
| `MultiSchoolReferralID` | int | Multi-school linkage; nullable |

---

#### `dbo.OAReferralQuestion`
Questions on a referral form — text, label, type, layout, signature flag, and portfolio category. FKs to `dbo.OAReferral` and `rw.PortfolioGroup`.

| Column | Type | Notes |
|---|---|---|
| `QuestionID` | int IDENTITY | PK |
| `ReferralID` | int | FK → `dbo.OAReferral` |
| `Question` | nvarchar(max) | Required |
| `QuestionLabel` | nvarchar(50) | Required |
| `QuestionType` | varchar(1) | Nullable |
| `SortOrder` | smallint | Required |
| `IsActive` / `IsRequired` / `IsDate` / `IsSignature` | bit | Flags |
| `NumCols` / `ColumnWidth` | int/smallint | Layout (NumCols default 3) |
| `PortfolioCategory` | int | FK → `rw.PortfolioGroup`; default 0 |
| `MultiSchoolQuestionID` | int | Nullable |

---

#### `dbo.OAReferralQuestionOption`
Answer options for a referral question (select/radio types). FK to `dbo.OAReferralQuestion`.

| Column | Type | Notes |
|---|---|---|
| `OptionID` | int IDENTITY | PK |
| `QuestionID` | int | FK → `dbo.OAReferralQuestion` |
| `OptionName` | nvarchar(128) | Nullable |
| `SortOrder` | smallint | Required |
| `MultiSchoolOptionID` | int | Nullable |

---

#### `dbo.OAReferralQuestionGrid`
Grid rows for a grid-type referral question (matrix questions). FK to `dbo.OAReferralQuestion`.

| Column | Type | Notes |
|---|---|---|
| `GridID` | int IDENTITY | PK |
| `QuestionID` | int | FK → `dbo.OAReferralQuestion` |
| `GridName` | nvarchar(500) | Row label; nullable |
| `SortOrder` | smallint | Required |
| `IsActive` | bit | Default 1 |
| `MultiSchoolGridID` | int | Nullable |

---

#### `dbo.OAReferralAnswer`
Submitted answers to referral questions, per question × student-referral, with optional signature date. PK is composite `(QuestionID, StudentReferralID)`. (`StudentReferralID` identifies the specific referral instance/referrer for a student — the referral counterpart to an answer row.)

| Column | Type | Notes |
|---|---|---|
| `QuestionID` | int | PK (composite); → `OAReferralQuestion` |
| `StudentReferralID` | int | PK (composite); the referral instance |
| `Answer` | nvarchar(max) | Nullable |
| `SignatureDate` | smalldatetime | Nullable |

---

#### `dbo.OAReferralGridAnswer`
Submitted answers to grid-type referral questions, per grid row × student-referral. PK is composite `(GridID, StudentReferralID)`; FK to `OAReferralQuestionGrid`.

| Column | Type | Notes |
|---|---|---|
| `GridID` | int | PK (composite); FK → `dbo.OAReferralQuestionGrid` |
| `StudentReferralID` | int | PK (composite); the referral instance |
| `Answer` | nvarchar(500) | Nullable |

---

#### `dbo.OAReligionField`
Per-application config for the **religion/church section** — single-char show/require flags and label overrides for religion, church, pastor, sacrament checkboxes (baptism/communion/confirmation/reconciliation/bar_bat), and new-church details. Common in faith-based schools. PK `onlineappid`.

| Column group | Type | Notes |
|---|---|---|
| `onlineappid` | int | PK; → `dbo.OA` |
| Core: `religion` / `church` / `church_member` / `senior_pastor` (+ `_label` overrides) | varchar(1)/nvarchar | Show flags + labels |
| Church location: `rel_city` / `rel_state` / `rel_zip` / `rel_phone` | varchar(1) | Show flags |
| Sacraments: `baptism` / `communion` / `confirmation` / `reconciliation` / `bar_bat` | varchar(1) | Show flags; default '0' |
| Sections: `section_church` / `section_date` / `section_city` / `section_state` | varchar(1) | Section toggles |
| New church: `hide_new_church` / `ChurchNewStreet` / `ChurchYouthPastor` (+ `Label`) | mixed | New-church capture |

---

#### `dbo` OA (payment / referral / religion) — cross-reference summary

| Table | Scope | Key FK targets / notes |
|---|---|---|
| `OAPayment` | Application payment transactions | **PII / payment**; by `studentid` |
| `OAPaymentAdvanced` | Tiered fee schedule | PK `(onlineappid, GradeLevel, enrollmenttype, isstaff)` |
| `OAPayOption` | Named payment options | → `dbo.OA` |
| `OAReferral` | Referral/recommendation form | `dbo.OA`, `rw.PortfolioGroup` |
| `OAReferralQuestion` | Referral form questions | `dbo.OAReferral`, `rw.PortfolioGroup` |
| `OAReferralQuestionOption` | Referral question options | → `dbo.OAReferralQuestion` |
| `OAReferralQuestionGrid` | Referral grid rows | → `dbo.OAReferralQuestion` |
| `OAReferralAnswer` | Submitted referral answers | PK `(QuestionID, StudentReferralID)` |
| `OAReferralGridAnswer` | Submitted grid answers | → `dbo.OAReferralQuestionGrid` |
| `OAReligionField` | Religion/church section config | Faith-based schools; → `dbo.OA` |

---

### `dbo` Online Application (OA) tables — continued (religion data, report builder, request-info engine)

#### `dbo.OAReligionSection`
Submitted sacrament/religion-section data per student — church, date, city, state for a named section (e.g. baptism, communion). The data counterpart to the section flags in `OAReligionField`. PK is composite `(studentid, thesection)`.

| Column | Type | Notes |
|---|---|---|
| `studentid` | int | PK (composite) |
| `thesection` | nvarchar(50) | PK (composite); sacrament/section name; default '' |
| `s_church` / `s_date` / `s_city` / `s_state` | nvarchar | Section details; nullable |

---

### `dbo` OA report-builder tables

A newer (UTC-audited) report-builder for OA: `OAReportTemplate` is a saved report; `OAReportTemplateColumn` its columns (each typed by a `ref.OAColumnSourceType`); `OAInquiryReportTemplateColumn` (documented earlier) maps inquiry-specific column sources onto those columns; `OAReportSettings` stores per-member saved view settings (sorts/filters).

#### `dbo.OAReportTemplate`
A saved OA report template per member. Clustered on `MemberId`. `AppType` distinguishes application vs enrollment reports.

| Column | Type | Notes |
|---|---|---|
| `OAReportTemplateId` | int IDENTITY | PK (non-clustered) |
| `MemberId` | int | Clustered index; owning member |
| `Name` | nvarchar(100) | Required |
| `AppType` | tinyint | App vs enrollment; default 1 |
| `CreateId` / `CreateDate` / `UpdateId` / `UpdateDate` | int/datetime | UTC audit |

---

#### `dbo.OAReportTemplateColumn`
Columns of an OA report template, each typed by a column-source type. FKs to `dbo.OAReportTemplate` and `ref.OAColumnSourceType`. Referenced by `dbo.OAInquiryReportTemplateColumn` (which adds the specific source linkage).

| Column | Type | Notes |
|---|---|---|
| `OAReportTemplateColumnId` | int IDENTITY | PK; referenced by `OAInquiryReportTemplateColumn` |
| `OAReportTemplateId` | int | FK → `dbo.OAReportTemplate` |
| `OAColumnSourceTypeId` | int | FK → `ref.OAColumnSourceType` |
| `SortOrder` | int | Column order |
| `IsPinned` | bit | Pinned column |
| `CreateId` / `CreateDate` / `UpdateId` / `UpdateDate` | int/datetime | UTC audit |

---

#### `dbo.OAReportSettings`
Per-member saved report view settings — name, type, sorts, year filters, and column filters (JSON-ish text). CASCADE from `dbo.OAMember`; FK to `ref.OAReportSettingsType`.

| Column | Type | Notes |
|---|---|---|
| `OAReportSettingsId` | int IDENTITY | PK (non-clustered) |
| `MemberId` | int | FK → `dbo.OAMember` (CASCADE) |
| `Name` | nvarchar(100) | Required |
| `OAReportSettingsTypeId` | int | FK → `ref.OAReportSettingsType` |
| `Sorts` | nvarchar(1000) | Saved sort spec; nullable |
| `YearFilters` | nvarchar(250) | Nullable |
| `ColumnFilters` | nvarchar(max) | Saved column filters; nullable |
| `Version` | smallint | Required |
| `CreateId` / `CreateDate` / `UpdateId` / `UpdateDate` | int/datetime | UTC audit |

---

### `dbo` OA request-info (inquiry lead) tables

The **request-info** subsystem is the public "Request Information" lead-capture flow (lighter than a full application). `OARequestInfo` is the submitted lead; `OARequestInfoField` configures which fields show (per member); `OARequestInfoGrade` lists offered grades; `OARequestInfoQuestion`/`...Option`/`...Answer` are a custom-question engine paralleling the OA-info and referral engines. (Inquiry tasks/reporting tie in via `OAInquiryTask`/`OAInquiryReportTemplateColumn` documented earlier; `OARequestInfoStudent` — the per-student child — is still pending.)

#### `dbo.OARequestInfo`
**The submitted "Request Information" lead** — prospective family contact (up to two parents), how-they-heard, language, source IP, and links to resolved Person/Address records. **Temporal table** (system-versioned on `ModifiedOnUTC`/`ModifiedOnUTCmax`). PK `requestid`.

> **Contains PII**: parent names, email, phone, address, source IP for prospective families. Treat as confidential.

| Column group | Type | Notes |
|---|---|---|
| `requestid` | int IDENTITY | PK |
| `memberid` | int | Indexed; owning member |
| Parent 1: `salutation` / `firstname` / `middlename` / `lastname` / `email` / `phone` / `work_phone` / `cell_phone` / `gender` | nvarchar | — |
| Parent 2: `salutation2` / `firstname2` / `middlename2` / `lastname2` / `email2` / `work_phone2` / `cell_phone2` / `gender2` | nvarchar | — |
| Address: `address` / `city` / `state` / `country` / `zip` | nvarchar | — |
| Source: `howhear` / `howhear_details` / `FromIP` | nvarchar | Lead source + originating IP |
| Status: `substatus` / `Active` / `parent_notes` / `pdfname` | mixed | — |
| Resolved links: `_AddressID` / `_P1PersonID` / `_P2PersonID` | int | Links to resolved `Person`/address |
| `LangCode` | nvarchar(10) | Default 'en' |
| `createddate` / `CreatedOnUTC` | datetime/datetime2 | — |
| `ModifiedOnUTC` / `ModifiedOnUTCmax` | datetime2 | System-versioning period (temporal); `ModifiedOnUTC` indexed |

---

#### `dbo.OARequestInfoField`
Per-member config for the request-info form fields — single-char show/require flags for parent/student fields, plus `howhear` and student-interests config. PK `memberid`.

| Column group | Type | Notes |
|---|---|---|
| `memberid` | int | PK; → `dbo.OAMember` |
| Parent fields: `salutation` / `middlename` / `parent2` / `address` / `city` / `state` / `country` / `zip` / `cell_phone` / `work_phone` / `HomePhone` / `gender_parent` / `parent_notes` | varchar(1) | Show/require flags |
| Student fields: `student_birthdate` / `student_middlename` / `student_email` / `gender_student` / `current_school` | varchar(1) | Show/require flags |
| How-hear: `howhear` / `howhear_label` | mixed | Label default "How Did You Hear About Us?" |
| Interests: `student_interests` / `StudentInterestsColumns` | mixed | Interests block (cols default 3) |
| `school_year` | varchar(1) | Default 'r' (required) |

---

#### `dbo.OARequestInfoGrade`
Grade levels offered in the request-info form, per member. PK is composite `(memberid, GradeLevel)`.

| Column | Type | Notes |
|---|---|---|
| `memberid` | int | PK (composite); → `dbo.OAMember` |
| `GradeLevel` | nvarchar(50) | PK (composite) |

---

#### `dbo.OARequestInfoQuestion`
Custom questions on the request-info form — text, type, parent-vs-student target, required/active/date flags, conditional flag, and language. Per member. Referenced by `OAInquiryReportTemplateColumn` (as a report column source) and `OARequestInfoAnswer`.

| Column | Type | Notes |
|---|---|---|
| `questionid` | int IDENTITY | PK |
| `memberid` | int | Indexed |
| `student_parent` | varchar(1) | Target: 'P' parent / 'S' student; default 'P' |
| `question` | nvarchar(max) | Required |
| `question_label` | nvarchar(50) | Nullable |
| `question_type` | varchar(1) | Required |
| `sortorder` | smallint | Required |
| `isactive` / `required` / `isdate` | varchar(1) | Flags |
| `IsConditional` | bit | Default 0 |
| `numcols` | int | Default 3 |
| `LangCode` | nvarchar(10) | Default 'en' |
| `EventServiceID` | int | Nullable |

---

#### `dbo.OARequestInfoQuestionOption`
Answer options for a request-info question.

| Column | Type | Notes |
|---|---|---|
| `optionid` | int IDENTITY | PK |
| `questionid` | int | → `OARequestInfoQuestion` |
| `optionname` | nvarchar(250) | Required |
| `sortorder` | smallint | Required |

---

#### `dbo.OARequestInfoAnswer`
Submitted answers to request-info questions, per question × request. PK is composite `(questionid, requestid)`; FKs to `OARequestInfo` and `OARequestInfoQuestion`.

| Column | Type | Notes |
|---|---|---|
| `questionid` | int | PK (composite); FK → `dbo.OARequestInfoQuestion` |
| `requestid` | int | PK (composite); FK → `dbo.OARequestInfo`; indexed |
| `answer` | nvarchar(max) | Nullable |

---

#### `dbo` OA (religion data / report builder / request-info) — cross-reference summary

| Table | Scope | Key FK targets / notes |
|---|---|---|
| `OAReligionSection` | Submitted sacrament/section data | Data counterpart to `OAReligionField`; PK `(studentid, thesection)` |
| `OAReportTemplate` | Saved OA report template | By `MemberId`; `AppType` |
| `OAReportTemplateColumn` | Report template columns | `OAReportTemplate`, `ref.OAColumnSourceType`; referenced by `OAInquiryReportTemplateColumn` |
| `OAReportSettings` | Saved report view settings | CASCADE from `OAMember`; `ref.OAReportSettingsType` |
| `OARequestInfo` | **Request-info lead (inquiry)** | **PII**; temporal; by `memberid` |
| `OARequestInfoField` | Request-info field config | PK `memberid` |
| `OARequestInfoGrade` | Offered grades | PK `(memberid, GradeLevel)` |
| `OARequestInfoQuestion` | Request-info custom questions | By `memberid`; referenced by `OAInquiryReportTemplateColumn` |
| `OARequestInfoQuestionOption` | Question options | → `OARequestInfoQuestion` |
| `OARequestInfoAnswer` | Submitted answers | `OARequestInfo`, `OARequestInfoQuestion` |

---

### `dbo` Online Application (OA) tables — continued (request-info student, status, tracking, school-year, siblings)

#### `dbo.OARequestInfoQuestionOptionConditional`
Conditional display rules for the request-info question engine — the request-info counterpart to `OAInfoQuestionMemberOptionConditional`. When an option (or yes/no answer) on one question is chosen, show/hide another. Self-referential through `OARequestInfoQuestion` (trigger `QuestionID` + `DisplayQuestionID`, the latter CASCADE) and `OARequestInfoQuestionOption` (CASCADE).

| Column | Type | Notes |
|---|---|---|
| `ConditionalID` | int IDENTITY | PK |
| `QuestionID` | int | FK → `OARequestInfoQuestion` (trigger question) |
| `OptionID` | int | FK → `OARequestInfoQuestionOption` (CASCADE); nullable |
| `YesOrNo` | nvarchar(3) | Trigger on yes/no answer; nullable |
| `DisplayQuestionID` | int | FK → `OARequestInfoQuestion` (CASCADE); question to show/hide |
| `ShowIt` | bit | Show (1) / hide (0) when condition met; default 1 |

---

#### `dbo.OARequestInfoStatus`
Lookup of request-info lead statuses (statusid → name). Referenced by `OARequestInfoStudent.statusid`.

| Column | Type | Notes |
|---|---|---|
| `statusid` | int | PK (app-assigned) |
| `statusname` | nvarchar(50) | Required |

---

#### `dbo.OARequestInfoStudent`
**The per-student child of a request-info lead** — one row per prospective student on a `OARequestInfo` submission, with name, grade, school year, current school, visit/tour date, status, and resolved RenWeb/Person/Address links. **Temporal table** (system-versioned). PK `studentid` (its own identity — note this is the FK target referenced by `OAInquiryTask.OARequestInfoStudentId` and the student `*Answer`/`*Interest`/`*Track` tables).

> **Contains PII**: prospective student name, birthdate, email. Treat as confidential.

| Column group | Type | Notes |
|---|---|---|
| `studentid` | int IDENTITY | PK (this table's own id) |
| `requestid` | int | FK → `dbo.OARequestInfo` (the lead); indexed |
| Identity: `firstname` / `middlename` / `lastname` / `birthdate` / `gender` / `email` | mixed | PII |
| Academic: `GradeLevel` / `school_year` / `current_school` / `SchoolCode` | nvarchar | — |
| Funnel: `statusid` (→ `OARequestInfoStatus`; default 1) / `substatus` / `visit_tour` / `admin_notes` | mixed | — |
| Resolved links: `_AddressID` / `_StudentID` / `Renweb_StudentID` / `studentid_app` | int | Links to resolved records / promoted application |
| `CreatedDateStudent` / `CreatedOnUTC` | smalldatetime/datetime2 | — |
| `ModifiedOnUTC` / `ModifiedOnUTCmax` | datetime2 | System-versioning period (temporal); `ModifiedOnUTC` indexed |

---

#### `dbo.OARequestInfoStudentAnswer`
Answers to student-targeted request-info questions, per question × request-info-student. PK is composite `(questionid, studentid)`; FKs to `OARequestInfoQuestion` and `OARequestInfoStudent`. (Parallels `OARequestInfoAnswer`, which is keyed by `requestid` for parent-level answers.)

| Column | Type | Notes |
|---|---|---|
| `questionid` | int | PK (composite); FK → `dbo.OARequestInfoQuestion` |
| `studentid` | int | PK (composite); FK → `dbo.OARequestInfoStudent`; indexed |
| `answer` | nvarchar(max) | Nullable |

---

#### `dbo.OARequestInfoStudentInterest`
Interests selected for a request-info student (multi-select). CASCADE from `dbo.Interest`. PK is composite `(studentid, InterestID)`.

| Column | Type | Notes |
|---|---|---|
| `studentid` | int | PK (composite); → `dbo.OARequestInfoStudent` |
| `InterestID` | int | PK (composite); FK → `dbo.Interest` (CASCADE); indexed |

---

#### `dbo.OARequestInfoTrack`
Per-student admissions tracking checklist — yes/no completion of tracking items with notes and notification flag. PK is composite `(studentid, itemid)`. (`itemid` references the tracking-item config; cf. `dbo.TrackingItems`/`TrackingConfig` used by the report-column tables.)

| Column | Type | Notes |
|---|---|---|
| `studentid` | int | PK (composite); the request-info student |
| `itemid` | int | PK (composite); tracking item |
| `yesno` | char(1) | Completion flag |
| `notes` | nvarchar(max) | Nullable |
| `NotificationSent` | bit | Nullable |

---

#### `dbo.OASchoolYearEmailTo`
Per-member, per-school-year config for who application emails are sent to. CASCADE from `dbo.SchoolYear`.

| Column | Type | Notes |
|---|---|---|
| `EmailToID` | int IDENTITY | PK |
| `YearID` | int | FK → `dbo.SchoolYear` (CASCADE) |
| `MemberID` | int | Owning member |
| `SendTo` | nvarchar(2) | Recipient code |

---

#### `dbo.OASchoolYearFACTSIntegration`
Maps an OA school year + school to the FACTS (tuition/billing) integration settings used when pushing online-enrollment fees — FACTS term, account, and adjustment reason. CASCADE from both `dbo.SchoolYear` and `dbo.ConfigSchool`. This is the OA→FACTS billing handoff config.

| Column | Type | Notes |
|---|---|---|
| `IntegrationID` | int IDENTITY | PK |
| `YearID` | int | FK → `dbo.SchoolYear` (CASCADE) |
| `ConfigSchoolID` | smallint | FK → `dbo.ConfigSchool` (CASCADE) |
| `OEFactsTerm` | nvarchar(50) | FACTS term; nullable |
| `OEFactsAccount` | nvarchar(50) | FACTS account; nullable |
| `OEFactsAdjustmentReason` | nvarchar(50) | FACTS adjustment reason; nullable |

---

#### `dbo.OASharedReportTemplateColumn`
A shared/standardized variant of `OAInquiryReportTemplateColumn` — maps a report template column to a source (standard field type, request-info question, tracking config/items, or interest/category), with a person-context type. FKs largely mirror `OAInquiryReportTemplateColumn`; differs by using `OAStandardFieldTypeId` (smallint) and adding `PersonContextType`. Several CASCADE.

| Column | Type | Notes |
|---|---|---|
| `OASharedReportTemplateColumnId` | int IDENTITY | PK |
| `OAReportTemplateColumnId` | int | FK → `dbo.OAReportTemplateColumn`; clustered |
| `OAStandardFieldTypeId` | smallint | Standard field type |
| `OARequestInfoQuestionId` | int | FK → `dbo.OARequestInfoQuestion` (CASCADE); nullable |
| `TrackingConfigId` | int | FK → `dbo.TrackingConfig` (CASCADE); nullable |
| `TrackingItemsId` | int | FK → `dbo.TrackingItems` (CASCADE); nullable |
| `InterestCategoryId` | int | FK → `dbo.InterestCategory` (CASCADE); nullable |
| `InterestId` | int | FK → `dbo.Interest` (CASCADE); nullable |
| `PersonContextType` | tinyint | Parent/student context; default 0 |
| `CreateId` / `CreateDate` / `UpdateId` / `UpdateDate` | int/datetime2 | UTC audit |

---

#### `dbo.OASibling`
Siblings submitted on an application, per applicant — name, age, grade, school, DOB, gender.

| Column | Type | Notes |
|---|---|---|
| `siblingid` | int IDENTITY | PK |
| `studentid` | int | The applicant; indexed |
| `childname` | nvarchar(50) | Nullable |
| `age` / `grade` | nvarchar | Nullable |
| `school` | nvarchar(100) | Nullable |
| `dob` | datetime2(2) | Nullable |
| `Gender` | nvarchar(50) | Nullable |

---

#### `dbo` OA (request-info student / status / tracking / school-year / siblings) — cross-reference summary

| Table | Scope | Key FK targets / notes |
|---|---|---|
| `OARequestInfoQuestionOptionConditional` | Request-info conditional show/hide | Self-ref `OARequestInfoQuestion` (CASCADE), `...Option` (CASCADE) |
| `OARequestInfoStatus` | Lead status lookup | Referenced by `OARequestInfoStudent` |
| `OARequestInfoStudent` | **Per-student inquiry record** | **PII**; temporal; FK target for `OAInquiryTask`; → `OARequestInfo` |
| `OARequestInfoStudentAnswer` | Student-targeted answers | `OARequestInfoQuestion`, `OARequestInfoStudent` |
| `OARequestInfoStudentInterest` | Student interest multi-select | CASCADE from `dbo.Interest` |
| `OARequestInfoTrack` | Per-student tracking checklist | PK `(studentid, itemid)` |
| `OASchoolYearEmailTo` | Per-year email recipients | CASCADE from `dbo.SchoolYear` |
| `OASchoolYearFACTSIntegration` | OA→FACTS billing handoff config | CASCADE from `SchoolYear` + `ConfigSchool` |
| `OASharedReportTemplateColumn` | Shared report column mapping | `OAReportTemplateColumn` + tracking/interest (CASCADE); `PersonContextType` |
| `OASibling` | Applicant siblings | By `studentid` |

---

### `dbo` Online Application (OA) tables — continued (the OAStudent application record, status, staff/site config, import)

#### `dbo.OAStudent`
**The central per-student online-application record** — the row created when a parent applies/enrolls a student. This is the spine of the OA subsystem: most `OA*` student-data tables key to its `studentid` (`OAInfo`, `OAAddress`, `OAInfoRace`, `OAGenericAcknowledgeStudent`, `OAStatusChanges`, `OAStudentFormPDF`, `OAStudentIFN`, `OAStudentInterest`, `OASibling`, etc.). Holds the applicant identity, grade/school, payment/fee state, application status, RenWeb linkage, and FACTS institution-fee tracking. **Temporal table** (system-versioned on `ModifiedOnUTC`/`ModifiedOnUTCmax`). PK `studentid`.

> **Contains PII**: applicant name, birthdate, payment tokens (`cpPaymentToken`), transaction ids. Treat as confidential; never expose payment tokens.

Documented by column group:

| Column group | Type | Notes |
|---|---|---|
| `studentid` | int IDENTITY | PK; the OA student id (FK target across the OA subsystem) |
| `parentid` | int | The applying parent (`OAParent`); indexed |
| `onlineappid` | int | → `dbo.OA` (the application) |
| Identity: `firstname` / `middlename` / `lastname` / `suffix` / `birthdate` | mixed | PII; name + birthdate indexed |
| Placement: `GradeLevel` / `SchoolCode` / `enrollmenttype` / `isStaff` | mixed | — |
| Status: `appstatusid` (→ `OAStatus`; indexed) / `admin_notes` / `date_started` / `date_submitted` | mixed | Application status & lifecycle |
| Lead source: `howhear` / `howhear_details` | nvarchar | — |
| Payment/fees: `do_payment` / `payment_finished` / `trans_id` / `optionid` / `enrollment_fee` / `ApplicationFee` / `TotalFee` / `FeeWasWaived` / `bill_the_school` / `cpPaymentToken` | mixed | **`cpPaymentToken`/`trans_id` sensitive** |
| Accounting links: `ChargeID` / `CreditID` / `PaymentID` / `RenWebAccounting` | mixed | Into the charges/credits system |
| FACTS institution fee: `FACTSInstitutionFeeSuccess` / `FACTSInstitutionFeeStart` / `FACTSInstitutionFeeEnd` | bit/smalldatetime | OA→FACTS fee push state |
| RenWeb linkage: `renweb_studentid` (indexed) / `production_or_test` | mixed | Resolved SIS student |
| Family packet: `IsFamilyPacket` / `FamilyPacketFamilyID` / `IncludeHouseholdForms` | mixed | Family-vs-student packet |
| Import/review: `CreateDate` / `ImportDate` / `reviewed_by` / `sync_by` / `imported_by` | mixed | Workflow audit |
| `MultiSchoolStudentID` | int | Multi-school linkage |
| `CreatedOnUTC` / `ModifiedOnUTC` / `ModifiedOnUTCmax` | datetime2 | System-versioning period (temporal); `ModifiedOnUTC` indexed |

---

#### `dbo.OAStatus`
Application-status lookup (e.g. started, submitted, accepted) with flags for which products surface the status (`SIS`, `EAdmissions`). Referenced by `OAStudent.appstatusid` and `OAStatusChanges`.

| Column | Type | Notes |
|---|---|---|
| `appstatusid` | int | PK (app-assigned) |
| `appstatus` | nvarchar(50) | Required; status name |
| `sortorder` | int | Required |
| `SIS` / `EAdmissions` | bit | Show in SIS / eAdmissions; default 1 |

---

#### `dbo.OAStatusChanges`
Audit log of application-status transitions per student — from/to status, admin, timestamp. FKs to `OAStudent`, `OAStatus` (×2 for from/to), and `dbo.Person` (admin).

| Column | Type | Notes |
|---|---|---|
| `LogID` | int IDENTITY | PK |
| `StudentID` | int | FK → `dbo.OAStudent` |
| `AdminID` | int | FK → `dbo.Person`; nullable |
| `LogDate` | smalldatetime | Default 1/1/1901 (sentinel) |
| `AppStatusID_From` | int | FK → `dbo.OAStatus` |
| `AppStatusID_To` | int | FK → `dbo.OAStatus` |

---

#### `dbo.OAStudentFormPDF`
Generated PDF per student per form. PK is composite `(FormSchoolID, StudentID)`; FKs to `OAStudent` and `OAFormSchool`.

| Column | Type | Notes |
|---|---|---|
| `FormSchoolID` | int | PK (composite); FK → `dbo.OAFormSchool` |
| `StudentID` | int | PK (composite); FK → `dbo.OAStudent` |
| `PDFname` | nvarchar(255) | Required; generated PDF filename |

---

#### `dbo.OAStudentIFN`
Institution-fee-notification (IFN) records per student — amount and date sent. FK to `OAStudent`. (Tracks the FACTS institution-fee notification corresponding to `OAStudent.FACTSInstitutionFee*`.)

| Column | Type | Notes |
|---|---|---|
| `IFNID` | int IDENTITY | PK |
| `StudentID` | int | FK → `dbo.OAStudent` |
| `DateSent` | smalldatetime | Required |
| `Amount` | decimal(19,4) | Required |

---

#### `dbo.OAStudentImport`
Per-row import staging/matching for batch student imports — links to an `OAImport` run, with match IDs for family/student/parents and a resolved-warning flag. FKs to `OAImport` and `ref.OAImportStatusType`.

| Column | Type | Notes |
|---|---|---|
| `OAStudentImportID` | int IDENTITY | PK |
| `OAImportID` | int | FK → `dbo.OAImport`; clustered |
| `OAImportStatusTypeID` | tinyint | FK → `ref.OAImportStatusType` |
| `RowNumber` | int | Default 0 |
| Match IDs: `FamilyMatchID` / `StudentMatchID` / `Parent1MatchID` / `Parent2MatchID` | int | Resolved matches; nullable |
| School IDs: `StudentSchoolID` / `Parent1SchoolID` / `Parent2SchoolID` | nvarchar(50) | Source-system ids; nullable |
| `HasResolvedWarning` | bit | Default 0 |

---

#### `dbo.OAStudentInterest`
Interests selected for an OA application student (multi-select). PK is composite `(studentid, InterestID)`. (The application-student counterpart to `OARequestInfoStudentInterest`, which is keyed to the inquiry student.)

| Column | Type | Notes |
|---|---|---|
| `studentid` | int | PK (composite); → `dbo.OAStudent` |
| `InterestID` | int | PK (composite); → `dbo.Interest` |

---

#### `dbo.OASiblingField`
Per-application config for the sibling-section fields — single-char show/require flags. Config counterpart to `OASibling`. PK `onlineappid`.

| Column | Type | Notes |
|---|---|---|
| `onlineappid` | int | PK; → `dbo.OA` |
| `childname` / `age` | varchar(1) | Default 'r' (required) |
| `grade` / `school` / `dob` / `Gender` | varchar(1)/nvarchar(1) | Default '1' (shown) |

---

#### `dbo.OASiteDesignConfig`
Newer per-member site design config (RGB hex theme + logo + fonts) — the modern replacement for the older `OADesign` table. CASCADE from `dbo.OAMember`. PK `MemberId`.

| Column | Type | Notes |
|---|---|---|
| `MemberId` | int | PK; FK → `dbo.OAMember` (CASCADE) |
| `LogoBlobUri` / `LogoFileName` | varchar | Logo storage |
| `FontType` / `FontSize` | varchar/tinyint | Required |
| Theme (7-char `#RRGGBB`): `HeaderNavigationTextRgbHex` / `HeaderBackgroundRgbHex` / `HeaderBorderRgbHex` / `SectionHeadingBackgroundRgbHex` / `SectionHeadingTextRgbHex` / `PrimaryButtonBackgroundRgbHex` / `PrimaryButtonTextRgbHex` / `SecondaryButtonRgbHex` | varchar(7) | Required hex colors |

> **Note**: two OA design tables coexist — older `OADesign` (per `memberid`, 6-char hex, many element colors) and newer `OASiteDesignConfig` (per `MemberId`, 7-char `#RRGGBB`, fewer semantic tokens). Confirm which the app reads.

---

#### `dbo.OAStaffSchoolMM`
Many-to-many linking OA staff (`Person`) to the schools (`ConfigSchool`) they have admissions access to. CASCADE from both.

| Column | Type | Notes |
|---|---|---|
| `StaffSchoolID` | int IDENTITY | PK |
| `PersonID` | int | FK → `dbo.Person` (CASCADE) |
| `ConfigSchoolID` | smallint | FK → `dbo.ConfigSchool` (CASCADE) |

---

#### `dbo` OA (student / status / staff-site / import) — cross-reference summary

| Table | Scope | Key FK targets / notes |
|---|---|---|
| `OAStudent` | **Central OA application student** | **PII + payment token**; temporal; FK target across OA |
| `OAStatus` | Application-status lookup | Referenced by `OAStudent`, `OAStatusChanges` |
| `OAStatusChanges` | Status-transition audit | `OAStudent`, `OAStatus` ×2, `Person` |
| `OAStudentFormPDF` | Generated per-form PDFs | `OAStudent`, `OAFormSchool` |
| `OAStudentIFN` | Institution-fee notifications | → `OAStudent`; cf. `FACTSInstitutionFee*` |
| `OAStudentImport` | Batch import staging/matching | `OAImport`, `ref.OAImportStatusType` |
| `OAStudentInterest` | Application-student interests | PK `(studentid, InterestID)` |
| `OASiblingField` | Sibling-section field config | Config for `OASibling` |
| `OASiteDesignConfig` | **Newer** per-member site theme | CASCADE from `OAMember`; coexists with older `OADesign` |
| `OAStaffSchoolMM` | OA staff ↔ school access | CASCADE from `Person` + `ConfigSchool` |

---

### `dbo` Online Application (OA) tables — continued (OAStudent children: medications, referrals, sync, tasks, tracking)

All tables in this batch hang off `dbo.OAStudent` (the central application-student record).

#### `dbo.OAStudentInterestsField`
Per-application layout config for the student-interests block (just column count). PK `onlineappid`.

| Column | Type | Notes |
|---|---|---|
| `onlineappid` | int | PK; → `dbo.OA` |
| `NumColumns` | smallint | Display columns; default 3 |

---

#### `dbo.OAStudentMedication`
Medications submitted for an application student — name, dose, route, schedule/discontinue status, and notes. FK to `OAStudent`. Parent of `OAStudentMedicationSchedule`.

> **Contains health PII (HIPAA-adjacent)**: medication, dose, route. Treat as confidential.

| Column | Type | Notes |
|---|---|---|
| `OAStudentMedicationID` | int IDENTITY | PK (FILLFACTOR 90) |
| `StudentID` | int | FK → `dbo.OAStudent` |
| `MedicationID` | int | Lookup ref; nullable |
| `Medication` / `Dose` / `Route` | nvarchar | — |
| `SelfAdminister` | bit | Default 0 |
| `Scheduled` / `ScheduledNote` | bit/nvarchar | Scheduled-dose flag |
| `Discontinued` / `DateDiscontinued` / `DatePrescribed` | mixed | Lifecycle (dates stored as text) |
| `MedicationNote` | nvarchar(255) | Nullable |

---

#### `dbo.OAStudentMedicationSchedule`
Dosing schedule for a medication — a scheduled time plus per-weekday flags. CASCADE from `OAStudentMedication`.

| Column | Type | Notes |
|---|---|---|
| `OAStudentMedicationScheduleID` | int IDENTITY | PK |
| `OAStudentMedicationID` | int | FK → `dbo.OAStudentMedication` (CASCADE) |
| `ScheduledDoseTime` | time(0) | Dose time |
| `ScheduledForSunday`–`ScheduledForSaturday` | bit | Per-weekday flags; default 0 |

---

#### `dbo.OAStudentMultiSchools`
Schools an application student is being applied to (multi-school applications). FK to `OAStudent`.

| Column | Type | Notes |
|---|---|---|
| `StudentSchoolsID` | int IDENTITY | PK |
| `StudentID` | int | FK → `dbo.OAStudent` |
| `MemberID` | int | Owning member |
| `SchoolCode` | varchar(50) | Nullable |

---

#### `dbo.OAStudentOTC`
Per-student over-the-counter medication permissions — allow flag + note per OTC item. PK is composite `(studentid, OTCID)`. The data counterpart to `OAOTCConfig`.

| Column | Type | Notes |
|---|---|---|
| `studentid` | int | PK (composite); the OA student |
| `OTCID` | int | PK (composite); the OTC item |
| `Allow` | bit | Permission; nullable |
| `Note` | nvarchar(255) | Nullable |

---

#### `dbo.OAStudentReferral`
A referral instance for a student — the specific referrer (name/email) for a referral form. **This is the `StudentReferralID` source** that `OAReferralAnswer`/`OAReferralGridAnswer` key to. FKs to `OAReferral` and `OAStudent`.

| Column | Type | Notes |
|---|---|---|
| `StudentReferralID` | int IDENTITY | PK; keyed by the referral `*Answer` tables |
| `ReferralID` | int | FK → `dbo.OAReferral` (the form) |
| `StudentID` | int | FK → `dbo.OAStudent` |
| `ReferralName` | nvarchar(100) | Required; referrer name |
| `ReferralEmail` | nvarchar(256) | Referrer email; nullable |
| `DateSubmitted` | smalldatetime | Nullable |

---

#### `dbo.OAStudentReferralFile`
Files uploaded against a student referral. FK to `OAStudentReferral`.

| Column | Type | Notes |
|---|---|---|
| `FileID` | int IDENTITY | PK |
| `StudentReferralID` | int | FK → `dbo.OAStudentReferral` |
| `FileName` | nvarchar(255) | Required |

---

#### `dbo.OAStudentSync`
**Family-matching worktable for syncing an application into the RenWeb SIS** — for each application student (and the parent/grandparent slots), holds the matched `familyid`/`studentid_match`/`parentid`/`grandparentid` plus `address_use` choices and `saved_*` display strings. This is the staging map used when promoting an `OAStudent` into real `Person`/family records. Keyed by `(studentid, one_or_two)` (the `one_or_two` selects household).

| Column group | Type | Notes |
|---|---|---|
| `studentid` | int | The OA student |
| `one_or_two` | smallint | Which household |
| Matches: `familyid` / `studentid_match` / `parentida` / `parentidb` | int | Resolved family/student/parent ids |
| Grandparents: `grandparentid_1a`/`1b` … `4a`/`4b` (+ `address_grandparent1_use`…`4_use`) | int/nvarchar | Up to 4 grandparent pairs + address-use |
| `address_use` | nvarchar(10) | Which address to use |
| `saved_*` (`saved_family` / `saved_student` / `saved_parenta`/`b` / `saved_grandparent1a`…`4b`) | nvarchar(150) | Display strings for the matched records |

---

#### `dbo.OAStudentTask`
Links an admissions task (`OATask`) to an application student (`OAStudent`). The application-student counterpart to `OAInquiryTask` (which links tasks to inquiry students). FKs to `OATask` and `OAStudent`; unique clustered on `OATaskId`.

| Column | Type | Notes |
|---|---|---|
| `OAStudentTaskId` | int IDENTITY | PK (non-clustered) |
| `OATaskId` | int | FK → `dbo.OATask`; unique clustered |
| `OAStudentId` | int | FK → `dbo.OAStudent` |
| `CreateId` / `CreateDate` / `UpdateId` / `UpdateDate` | int/datetime | UTC audit |

---

#### `dbo.OAStudentTrack`
Per-student admissions tracking checklist (application-student counterpart to `OARequestInfoTrack`) — yes/no completion of tracking items with notes. PK is composite `(studentid, itemid)`.

| Column | Type | Notes |
|---|---|---|
| `studentid` | int | PK (composite); the OA student |
| `itemid` | int | PK (composite); tracking item |
| `yesno` | varchar(1) | Completion; default '0' |
| `notes` | nvarchar(max) | Nullable |
| `NotificationSent` | bit | Nullable |

---

#### `dbo` OA (OAStudent children) — cross-reference summary

| Table | Scope | Key FK targets / notes |
|---|---|---|
| `OAStudentInterestsField` | Interests-block layout config | → `dbo.OA` |
| `OAStudentMedication` | Application-student medications | **Health PII**; → `OAStudent` |
| `OAStudentMedicationSchedule` | Medication dosing schedule | CASCADE from `OAStudentMedication` |
| `OAStudentMultiSchools` | Multi-school application targets | → `OAStudent` |
| `OAStudentOTC` | Per-student OTC permissions | Data counterpart to `OAOTCConfig` |
| `OAStudentReferral` | Referral instance (referrer) | **`StudentReferralID` source** for referral answers; `OAReferral`, `OAStudent` |
| `OAStudentReferralFile` | Referral uploaded files | → `OAStudentReferral` |
| `OAStudentSync` | Family-match SIS-sync worktable | Matched `Person`/family ids; promotion staging |
| `OAStudentTask` | Admissions task ↔ app student | `OATask`, `OAStudent`; cf. `OAInquiryTask` |
| `OAStudentTrack` | Per-student tracking checklist | PK `(studentid, itemid)`; cf. `OARequestInfoTrack` |

---

### `dbo` Online Application (OA) tables — final (task, text areas, tuition plans)

#### `dbo.OATask`
**Admissions task definition** — a to-do assigned to a staff person, optionally scoped to a school, with due/complete dates. The task record that `OAInquiryTask` (inquiry students) and `OAStudentTask` (application students) both link to. PK `OATaskId`; FK to `dbo.ConfigSchool`.

| Column | Type | Notes |
|---|---|---|
| `OATaskId` | int IDENTITY | PK; linked by `OAInquiryTask` + `OAStudentTask` |
| `SchoolId` | smallint | FK → `dbo.ConfigSchool`; nullable |
| `AssignedPersonId` | int | Assignee (staff) |
| `Description` | nvarchar(100) | Required |
| `DueDate` | date | Nullable |
| `IsCompleted` / `CompleteDate` | bit/datetime | Completion |
| `IsActive` | bit | Default 1 |
| `CreateId` / `CreateDate` / `UpdateId` / `UpdateDate` | int/datetime | UTC audit |

---

#### `dbo.OATextArea`
Reusable rich-text content blocks per member — title, description (HTML), and a graphic. PK is composite `(areatitle, memberid)`.

| Column | Type | Notes |
|---|---|---|
| `areatitle` | nvarchar(75) | PK (composite); block name |
| `memberid` | int | PK (composite) |
| `description` | nvarchar(max) | HTML content; nullable |
| `photo` / `graphic_type` | nvarchar/varchar | Graphic (default 'sl') |
| `counter` | smallint | Default 1 |

---

#### `dbo.OATextAreaApp`
Per-application instance of a text-area block (the application-scoped counterpart to `OATextArea`). PK `TextAreaAppID`.

| Column | Type | Notes |
|---|---|---|
| `TextAreaAppID` | int IDENTITY | PK |
| `areatitle` | nvarchar(75) | Block name |
| `onlineappid` | int | → `dbo.OA` |
| `description` | nvarchar(max) | HTML content; nullable |
| `photo` / `graphic_type` | nvarchar/varchar | Graphic (default 'sl') |
| `counter` | smallint | Default 1 |

---

### `dbo` OA tuition-plan tables

#### `dbo.OATuitionPlan`
Tuition plan options offered on an application — title, description, and a link to a RenWeb tuition plan. PK `tuitionplanid`.

| Column | Type | Notes |
|---|---|---|
| `tuitionplanid` | int IDENTITY | PK |
| `onlineappid` | int | → `dbo.OA` |
| `plantitle` | nvarchar(128) | Nullable |
| `description` | nvarchar(max) | Nullable |
| `sortorder` | smallint | Default 0 |
| `isactive` | varchar(1) | Default '1' |
| `renwebtuitionplanid` | int | Link to RenWeb tuition plan; nullable |

---

#### `dbo.OATuitionPlanForm`
Per-application tuition-plan form config — signature title, FACTS-integration toggles, and financial-responsibility question. PK `OnlineAppID`; FK to `dbo.OA`. Notable FACTS flags: `ForceFACTS`, `FACTSEnabled`, `IfFACTSThenRenWebToo`.

| Column | Type | Notes |
|---|---|---|
| `OnlineAppID` | int | PK; FK → `dbo.OA` |
| `SigTitle` | nvarchar(255) | Signature label; default '' |
| `TypeYourName` | bit | Allow typed signature; default 0 |
| `ForceFACTS` | bit | Require FACTS; default 0 |
| `FACTSEnabled` | bit | FACTS available; default 1 |
| `IfFACTSThenRenWebToo` | bit | Mirror to RenWeb; default 1 |
| `AskFinRespQuestion` | bit | Ask financial-responsibility %; default 1 |

---

#### `dbo.OATuitionPlanStudent`
Per-student tuition-plan selection and signature — chosen plan, signature, and financial-responsibility percent. PK `StudentID`; FKs to `OAStudent` and `OATuitionPlan`.

| Column | Type | Notes |
|---|---|---|
| `StudentID` | int | PK; FK → `dbo.OAStudent` |
| `TuitionPlanID` | int | FK → `dbo.OATuitionPlan`; nullable |
| `SignedName` | nvarchar(100) | Nullable |
| `SignedDate` | smalldatetime | Nullable |
| `SignedImg` | nvarchar(max) | Signature image; nullable |
| `FinRespPercent` | tinyint | Financial-responsibility %; nullable |

---

#### `dbo` OA (task / text-area / tuition-plan) — cross-reference summary

| Table | Scope | Key FK targets / notes |
|---|---|---|
| `OATask` | **Admissions task definition** | → `ConfigSchool`; linked by `OAInquiryTask` + `OAStudentTask` |
| `OATextArea` | Reusable member text blocks | PK `(areatitle, memberid)` |
| `OATextAreaApp` | Per-application text blocks | → `dbo.OA` |
| `OATuitionPlan` | Tuition plan options | → `dbo.OA`; links RenWeb plan |
| `OATuitionPlanForm` | Tuition-plan form config | → `dbo.OA`; FACTS toggles |
| `OATuitionPlanStudent` | Per-student plan + signature | `OAStudent`, `OATuitionPlan` |

> **OA subsystem complete.** This finishes the `dbo.OA*` Online Application/Enrollment tables. The subsystem spans application definition (`OA`), the central student record (`OAStudent`) and its many data children, three parallel custom-question engines (info / referral / request-info, each with options + conditional show/hide), the inquiry/lead funnel (`OARequestInfo*`), member/site config, medical & tuition forms, a report builder, and external integrations (FACTS billing via `OASchoolYearFACTSIntegration`/`OATuitionPlanForm`; Passport/UserMS via the `OAParent` trigger; SIS promotion via `OAStudentSync`).

---

### `dbo` Observation (staff/teacher evaluation) tables

The **Observation** subsystem records staff/teacher observations and evaluations using a config + instance + radio-answer pattern: `Observation_Setup` defines an observation type (template); `Observation_Setup_Radio` its rating areas; `Observation` is a completed observation of a person by an evaluator; `Observation_Radio` the per-area ratings. (Compare the OA question engines — same config-vs-instance shape.)

#### `dbo.Observation_Setup`
Observation template/type definition. `Eval` distinguishes a formal evaluation from a general observation.

| Column | Type | Notes |
|---|---|---|
| `ObservationConfigID` | int IDENTITY | PK |
| `Name` | nvarchar(256) | Nullable |
| `Eval` | bit | Evaluation vs observation; nullable |

---

#### `dbo.Observation_Setup_Radio`
Rating areas (rows) for an observation template. PK is composite `(ObservationConfigID, AreaID)`.

| Column | Type | Notes |
|---|---|---|
| `ObservationConfigID` | int | PK (composite); → `Observation_Setup` |
| `AreaID` | int | PK (composite); rating area |
| `AreaLabel` | nvarchar(512) | Area name; nullable |

---

#### `dbo.Observation`
A completed observation/evaluation of a person by an evaluator, against a template. `PersonID` is the observed; `EvaluatorID` the observer.

| Column | Type | Notes |
|---|---|---|
| `ObservationID` | int IDENTITY | PK |
| `PersonID` | int | Observed person |
| `EvaluatorID` | int | Evaluator |
| `ObservationConfigID` | int | → `Observation_Setup` (the template) |
| `StartDate` / `EndDate` | smalldatetime | Nullable |
| `Title` | nvarchar(512) | Nullable |
| `Eval` | bit | Evaluation flag; nullable |
| `TypeName` | nvarchar(256) | Required; default '' |

---

#### `dbo.Observation_Radio`
Per-area ratings captured for an observation — the value plus a snapshot of the area label. PK is composite `(ObservationID, AreaID)`.

| Column | Type | Notes |
|---|---|---|
| `ObservationID` | int | PK (composite); → `Observation` |
| `AreaID` | int | PK (composite); the rating area |
| `Value` | int | Rating value; nullable |
| `AreaLabel` | nvarchar(512) | Label snapshot; nullable |

---

#### `dbo` Observation — cross-reference summary

| Table | Scope | Key FK targets / notes |
|---|---|---|
| `Observation_Setup` | Observation template/type | `Eval` = evaluation vs observation |
| `Observation_Setup_Radio` | Template rating areas | PK `(ObservationConfigID, AreaID)` |
| `Observation` | Completed observation/eval | Observed `PersonID` + `EvaluatorID` + template |
| `Observation_Radio` | Per-area ratings | PK `(ObservationID, AreaID)` |

---

### `dbo` Observation (tabs), online donation/payment, OTC, parent-student, and PA-groups tables

#### `dbo.Observation_Setup_Tabs`
Tab definitions (free-text sections) for an observation template. PK is composite `(ObservationConfigID, TabID)`. The text-section counterpart to `Observation_Setup_Radio` (rating areas).

| Column | Type | Notes |
|---|---|---|
| `ObservationConfigID` | int | PK (composite); → `Observation_Setup` |
| `TabID` | int | PK (composite); tab |
| `TabLabel` | nvarchar(256) | Tab name; nullable |

---

#### `dbo.Observation_Tabs`
Captured free-text per tab for a completed observation. PK is composite `(ObservationID, TabID)`.

| Column | Type | Notes |
|---|---|---|
| `ObservationID` | int | PK (composite); → `Observation` |
| `TabID` | int | PK (composite); the tab |
| `Text` | nvarchar(max) | Free-text response; nullable |
| `TabLabel` | nvarchar(256) | Label snapshot; nullable |

---

### `dbo` online donation / payment tables

These are the public-portal online giving and payment tables (distinct from the OA application payments and the legacy cash register). All hold gateway transaction data and billing PII.

#### `dbo.On_Line_Donation`
Online donation transactions via the giving portal — donor identity, billing/account details, gateway transaction result, honor/memory dedication, matched-gift, and campaign. Wide table; one row per donation.

> **Contains PII / payment data**: donor name/address/phone/email, billing & account details, transaction ids. Treat as confidential.

| Column group | Type | Notes |
|---|---|---|
| `DonationID` | int IDENTITY | PK |
| Scope: `SessionID` / `DistrictCode` / `SchoolCode` / `FamilyID` / `PersonID` / `CampaignID` | mixed | `CampaignID` → `DonateOnLineCampaigns` |
| Donor: `FirstName` / `MiddleName` / `LastName` / `Address` / `City` / `State` / `Zip` / `HomePhone` / `Email` / `Note` / `Affiliation` / `AnonymousDonor` | mixed | Donor identity |
| Match-by: `MatchedByName` / `MatchedByStreet` / `MatchedByCity` / `MatchedByState` / `MatchedByZIP` / `MatchedByPhone` / `MatchedByEmail` | nvarchar | How donor was matched to a record |
| Dedication: `HonorOf` / `MemoryOf` / `HonorOfNote` | nvarchar | In honor/memory of |
| Billing: `BillingName` / `BillingAddress` / `BillingCity` / `BillingState` / `BillingZip` / `BillingEmail` | nvarchar | — |
| Account: `AccountHolderName` / `AccountStreet` / `AccountCity` / `AccountState` / `AccountZip` / `AccountPhone` / `AccountEmail` / `PaymentType` | mixed | — |
| Transaction: `TransactionType` / `TransactionStatus` / `TransactionID` / `TransactionDate` / `TransactionAccountType` / `TransactionResultDate` / `TransactionResultCode` / `TransactionResultMessage` / `ResultCode` / `ResultMessage` / `TimeStamp` | varchar | Gateway result |
| Amounts: `Amount` / `MatchedGift` | decimal(10,2) | — |
| `DepositID` / `DonorConnectCID` | int | Deposit/CRM linkage |

---

#### `dbo.On_Line_Donation_Details`
Per-campaign allocation of a donation (one donation split across campaigns). PK is composite `(DonationID, CampaignID)`.

| Column | Type | Notes |
|---|---|---|
| `DonationID` | int | PK (composite); → `On_Line_Donation` |
| `CampaignID` | int | PK (composite); the campaign |
| `Amount` | decimal(10,2) | Allocated amount; nullable |
| `DonorConnectGHID` | int | CRM gift linkage; nullable |

---

#### `dbo.On_Line_Payment`
Online family payment transactions (tuition/fees/lunch via the portal) — amount, accounting linkage, gateway result, and flags for re-enrollment/FACTS/lunch. One row per payment attempt.

> **Contains payment data**: transaction results, payment GUID. Treat as confidential.

| Column group | Type | Notes |
|---|---|---|
| `ProcessID` | int IDENTITY | PK |
| Scope: `SessionID` / `DistrictCode` / `SchoolCode` / `FamilyID` / `AccountingSystemID` / `FiscalYearID` | mixed | — |
| `Amount` | float | Payment amount |
| Result: `ResultCode` / `ResultMessage` / `ResultMessage1` / `TimeStamp` | mixed | Gateway result |
| Linkage: `School_PaymentID` / `PaymentType` / `DepositID` / `WebOrderID` / `Lunch` | int | What was paid |
| Flags: `reenrollment` / `FACTS` | bit | Payment purpose |
| Migration: `OldProcessID` / `OldResultMessage` | mixed | Legacy linkage |
| `PaymentGUID` | nvarchar(50) | Gateway payment id |

---

#### `dbo.On_line_Reenrollment`
Link table tying an online payment (`ProcessID`) to the re-enrollment charge(s) it covers. PK is composite `(Processid, Chargeid)`.

| Column | Type | Notes |
|---|---|---|
| `Processid` | int | PK (composite); → `On_Line_Payment` |
| `Chargeid` | int | PK (composite); → `dbo.Charges` |

---

### `dbo` OTC (over-the-counter medication) tables — school-level

These are the **school-level** OTC medication permission tables (distinct from the OA-application `OAOTCConfig`/`OAStudentOTC`, which capture OTC during admissions). `OTCConfig` defines OTC items; `OTCStudent` records per-student permissions.

#### `dbo.OTCConfig`
OTC medication item definitions, per school (or district-wide).

| Column | Type | Notes |
|---|---|---|
| `OTCID` | int IDENTITY | PK |
| `SchoolCode` | varchar(50) | Nullable |
| `DistrictWide` | bit | District-wide flag; nullable |
| `Name` | nvarchar(50) | OTC item name; nullable |
| `SortOrder` | int | Nullable |
| `IsActive` | bit | Default 1 |

---

#### `dbo.OTCStudent`
Per-student OTC medication permissions — allow flag, dose, note. PK is composite `(OTCID, StudentID)`. (Health-related; treat with care.)

| Column | Type | Notes |
|---|---|---|
| `OTCID` | int | PK (composite); → `OTCConfig` |
| `StudentID` | int | PK (composite) |
| `Allow` | bit | Permission; default 0 |
| `Dose` | nvarchar(256) | Nullable |
| `Note` | nvarchar(256) | Nullable |

---

### `dbo.Parent_Student` — the parent↔student relationship table

#### `dbo.Parent_Student`
**Core FACTS table.** The many-to-many link between parents and students, carrying the relationship and a set of per-relationship permission/role flags (custody, correspondence, report card, pickup, ParentsWeb access, re-enrollment rights, emergency contact, etc.) plus contact priority. **Temporal table** (system-versioned). PK is composite `(ParentID, StudentID)`. Both IDs reference `dbo.Person`.

| Column | Type | Notes |
|---|---|---|
| `ParentID` | int | PK (composite); → `dbo.Person`; indexed |
| `StudentID` | int | PK (composite); → `dbo.Person`; indexed |
| `Relationship` | nvarchar(50) | Relationship label; nullable |
| `RelationDescriptorId` | uniqueidentifier | Structured relationship type; nullable |
| `Grandparent` | bit | — |
| Permission flags: `Custody` / `Correspondence` / `ReportCard` / `PickUp` / `EmergencyContact` / `ParentsWeb` / `PWBlock` / `reenroll` | bit | Per-relationship roles/permissions; `ParentsWeb` indexed |
| `ContactPriority` | tinyint | Ordering for contact; nullable |
| `CreatedOnUTC` | datetime2 | — |
| `ModifiedOnUTC` / `ModifiedOnUTCmax` | datetime2 | System-versioning period (temporal); `ModifiedOnUTC` indexed |

**Trigger** `tr_Parent_Student_U` (FOR INSERT, UPDATE): touches `Person.ModifiedDate = GETDATE()` for **both** the parent and the student on any insert/update — so a relationship change bumps both Person records (feeding downstream sync/change detection, consistent with the `Address`/`FamilyConfig` ModifiedDate pattern).

---

### `dbo.PA_Groups`

#### `dbo.PA_Groups`
Per-staff group definitions (parameterized) — `GroupType` + `GroupParameter` define a saved grouping/scope for a staff member (e.g. a filter set). PK is composite `(StaffID, GroupID)`.

| Column | Type | Notes |
|---|---|---|
| `StaffID` | int | PK (composite) |
| `GroupID` | int IDENTITY | PK (composite) |
| `GroupType` | nvarchar(25) | Required; group kind |
| `GroupParameter` | nvarchar(25) | Required; group value/scope |

---

#### `dbo` Observation-tabs / online-donation-payment / OTC / parent-student / PA-groups — cross-reference summary

| Table | Scope | Key FK targets / notes |
|---|---|---|
| `Observation_Setup_Tabs` | Observation template text tabs | PK `(ObservationConfigID, TabID)` |
| `Observation_Tabs` | Captured observation text | PK `(ObservationID, TabID)` |
| `On_Line_Donation` | Online donation transactions | **PII/payment**; `CampaignID` → `DonateOnLineCampaigns` |
| `On_Line_Donation_Details` | Per-campaign donation split | PK `(DonationID, CampaignID)` |
| `On_Line_Payment` | Online family payments | **Payment data**; re-enroll/FACTS/lunch flags |
| `On_line_Reenrollment` | Payment ↔ re-enroll charge link | `On_Line_Payment`, `Charges` |
| `OTCConfig` | School-level OTC item defs | Distinct from OA `OAOTCConfig` |
| `OTCStudent` | Per-student OTC permissions | PK `(OTCID, StudentID)` |
| `Parent_Student` | **Core parent↔student link** | **Core FACTS**; temporal; both → `Person`; ModifiedDate trigger |
| `PA_Groups` | Per-staff saved groupings | PK `(StaffID, GroupID)` |

---

### `dbo` ParentAlert (mass notification), parent committee/service-hours, and ParentsWeb (portal) tables

### `dbo` ParentAlert mass-notification subsystem

The **ParentAlert** subsystem is the mass-notification / broadcast feature (voice/text/email blasts to parents, integrating with SchoolCast). `ParentAlert` is a sent/scheduled alert; `ParentAlertMembers` the per-recipient delivery rows; `ParentAlertLibrary` reusable message templates.

#### `dbo.ParentAlert`
A broadcast alert — subject/message, audience flags (which relationship roles to target), schedule/sent times, provider linkage (SchoolCast), caller ID, and cancel state.

| Column group | Type | Notes |
|---|---|---|
| `ParentAlertID` | int IDENTITY | PK |
| `StaffID` | int | Sender; indexed with `DateSubmitted` |
| `Subject` / `Message` / `MessageType` / `SoundFileID` | mixed | Content (text + voice) |
| Audience flags: `Student` / `Custody` / `Correspondence` / `Grandparent` / `EmergencyContact` / `PickUp` / `Staff` | bit | Which relationship roles receive it |
| `Emergency` | bit | Emergency alert |
| Provider: `SchoolCastAlertID` / `ParentAlertProviderID` / `CallerID` / `PhoneNumber` / `Token` | mixed | SchoolCast integration; `SchoolCastAlertID` indexed |
| Schedule: `ScheduleDateTime` / `SentDateTime` / `DateSubmitted` | smalldatetime | — |
| Cancel: `CancelAlert` / `CancelAlertBy` / `CancelAlertDateTime` | mixed | Default not-cancelled |
| `ResultMessage` | nvarchar(max) | Gateway result |

---

#### `dbo.ParentAlertMembers`
Per-recipient delivery rows for an alert — contact data/method/name, the resolved person, and per-channel delivery results (call/text/email). Generated when an alert is sent.

> **Contains PII**: recipient names, phone/email contact data. Treat as confidential.

| Column group | Type | Notes |
|---|---|---|
| `ParentAlertMembersID` | int IDENTITY | PK |
| `ParentAlertID` | int | → `ParentAlert`; indexed (and with `ContactData`) |
| `PersonID` / `AlertPersonID` / `ContactName` / `Type` | mixed | Resolved recipient |
| `ContactData` / `ContactMethod` / `countrycode` | nvarchar | Phone/email + channel |
| Call result: `AnsweredBy` / `StartTime` / `Duration` / `ResponseCode` | nvarchar | Voice-call outcome |
| Text result: `TextStatus` / `TextReason` | nvarchar | SMS outcome |
| `EmailResult` | nvarchar(256) | Email outcome |
| `Error` / `ErrorMessage` / `ResultMessage` | mixed | Delivery error |

---

#### `dbo.ParentAlertLibrary`
Reusable alert message templates — type, title, message, sound file, with share/district-wide flags.

| Column | Type | Notes |
|---|---|---|
| `ParentAlertLibraryID` | int IDENTITY | PK |
| `Type` | int | Message type; nullable |
| `Title` | nvarchar(128) | Nullable |
| `Message` | nvarchar(max) | Nullable |
| `SoundFileID` | nvarchar(50) | Voice file; nullable |
| `SchoolCode` / `StaffID` | mixed | Owner |
| `Share` / `DistrictWide` | bit | Sharing scope |

---

### `dbo` parent committee / service-hours

#### `dbo.ParentCommittee`
Parent committee/office memberships — which committee and office a parent holds.

| Column | Type | Notes |
|---|---|---|
| `ID` | int IDENTITY | PK |
| `ParentID` | int | The parent; nullable |
| `Committee` / `Office` | nvarchar(50) | Membership; nullable |
| `Note` | nvarchar(255) | Nullable |
| `ModifiedBy` / `ModifiedDate` | int/smalldatetime | Audit |

---

#### `dbo.ParentServiceHours`
Parent volunteer/service-hour records — hours logged against a requirement area/service type, per year, with verification. FK to `dbo.Person`. (Common in schools that require parent volunteer hours.)

| Column | Type | Notes |
|---|---|---|
| `ID` | int IDENTITY | PK |
| `ParentID` | int | FK → `dbo.Person` |
| `Description` | nvarchar(255) | Nullable |
| `Hours` | real | Hours logged; nullable |
| `Date` | datetime | Nullable |
| `YearID` | int | School year; nullable |
| `ServiceType` / `RequirementArea` | nvarchar(256) | Categorization |
| `Location` / `Supervisor` | nvarchar(75) | — |
| `VerifiedBy` | nvarchar(255) | Verification |
| `Note` | nvarchar(255) | Nullable |
| `CreatedBy` / `ModifiedBy` / `ModifiedDate` | mixed | Audit |

---

### `dbo` ParentsWeb (parent/student portal) tables

**ParentsWeb** is the legacy name for the parent/student web portal (now "Family Portal"). These tables manage portal sessions and the per-session navigation index. (Note the broader product was historically called RenWeb/ParentsWeb; many `ParentsWeb_*` references in code mean "the portal.")

#### `dbo.ParentsWeb_Family`
Portal login sessions for a family/parent user — session id, user, email, login time, financial-responsibility flag, and current class context.

> **Contains PII**: email, session identifiers. Treat as confidential.

| Column | Type | Notes |
|---|---|---|
| `ID` | int IDENTITY | PK |
| `SessionID` | nvarchar(128) | Portal session; indexed |
| `DistrictCode` | nvarchar(50) | Nullable |
| `UserID` / `UserType` / `ParentID` | mixed | Logged-in user |
| `Email` | nvarchar(256) | Indexed (and with `UserType`) |
| `LoginDateTime` | smalldatetime | — |
| `FinancialResponsibility` | bit | — |
| `CurrentClassID` | int | Class context; nullable |

---

#### `dbo.ParentsWeb_Index`
Per-session navigation index — maps a session + index position to a web page/record. PK is composite `(SessionID, PWIndex)`.

| Column | Type | Notes |
|---|---|---|
| `SessionID` | char(35) | PK (composite) |
| `PWIndex` | int | PK (composite); nav position |
| `ID` | int | Linked record |
| `WebPage` | int | Page id |

---

#### `dbo.ParentsWeb_Index1`
Variant of `ParentsWeb_Index` with a surrogate `AutoNum` PK and nullable columns (append-style log rather than keyed index). Likely a working/secondary copy.

| Column | Type | Notes |
|---|---|---|
| `AutoNum` | int IDENTITY | PK |
| `SessionID` | char(35) | Nullable |
| `PWIndex` / `ID` / `WebPage` | int | Nullable |

---

#### `dbo.ParentsWeb_Students`
Per-session student context — the students visible in a portal session, with the per-student web-items payload, year/term, and name. PK is composite `(ID, StudentID, StudentIndex)`.

| Column | Type | Notes |
|---|---|---|
| `ID` | int | PK (composite); session/family id; indexed |
| `StudentID` | int | PK (composite) |
| `StudentIndex` | int | PK (composite); ordering |
| `SchoolCode` | varchar(50) | Nullable |
| `WebItems` | nvarchar(max) | Per-student portal items payload |
| `YearID` / `TermID` | int | Context |
| `FirstName` | nvarchar(50) | Nullable |

---

#### `dbo.ParentsWebItems`
Portal feature/item toggles per school — which portal items are enabled, with a version. PK is composite `(Item, SchoolCode)`.

| Column | Type | Notes |
|---|---|---|
| `Item` | nvarchar(50) | PK (composite); portal item name |
| `SchoolCode` | varchar(50) | PK (composite) |
| `Version` | int | Item version; indexed; nullable |

---

#### `dbo` ParentAlert / parent-committee-service / ParentsWeb — cross-reference summary

| Table | Scope | Key FK targets / notes |
|---|---|---|
| `ParentAlert` | Broadcast alert (voice/text/email) | SchoolCast integration; audience role flags |
| `ParentAlertMembers` | Per-recipient delivery rows | **PII**; → `ParentAlert` |
| `ParentAlertLibrary` | Reusable alert templates | Share/district-wide |
| `ParentCommittee` | Parent committee/office memberships | By `ParentID` |
| `ParentServiceHours` | Parent volunteer hours | FK → `dbo.Person`; by requirement area |
| `ParentsWeb_Family` | Portal login sessions | **PII**; by `SessionID`/`Email` |
| `ParentsWeb_Index` | Per-session nav index | PK `(SessionID, PWIndex)` |
| `ParentsWeb_Index1` | Nav-index variant (surrogate PK) | Working/secondary copy |
| `ParentsWeb_Students` | Per-session student context | PK `(ID, StudentID, StudentIndex)` |
| `ParentsWebItems` | Per-school portal item toggles | PK `(Item, SchoolCode)` |

---

### `dbo` ParentsWeb log, password history, scheduling patterns, and payment tables

#### `dbo.ParentsWebLog`
Portal login/logout audit log — per session, the family/parent/student, email, login/logout times, and class context. Heavily indexed by district + login time (for usage reporting). The audit-log counterpart to the session table `ParentsWeb_Family`.

> **Contains PII**: email, session ids. Treat as confidential.

| Column | Type | Notes |
|---|---|---|
| `LogID` | int IDENTITY | PK |
| `DistrictCode` | varchar(50) | Indexed (and with `LoginTime`) |
| `FamilyID` / `ParentID` / `StudentID` | int | Who |
| `Email` | nvarchar(256) | — |
| `UserType` | varchar(50) | — |
| `SessionID` | char(35) | Indexed |
| `LoginTime` / `LogoutTime` / `LoginDate` | datetime | Indexed |
| `ClassID` | int | Class context |

---

#### `dbo.PasswordHistory`
Password history for staff (to prevent reuse) — old password (hashed) per staff with date. PK `PasswordHistory` (identity).

> **Sensitive**: contains password material (`Pswd` varbinary hash, legacy `Password`). Never expose.

| Column | Type | Notes |
|---|---|---|
| `PasswordHistory` | int IDENTITY | PK |
| `StaffID` | int | The staff member; nullable |
| `Password` | nvarchar(50) | Legacy password value; nullable |
| `Pswd` | varbinary(8000) | Hashed password; nullable |
| `Date` | smalldatetime | When set; nullable |

---

### `dbo` scheduling pattern tables (legacy vs New)

> **Legacy-vs-refactored pair.** `Patterns`/`PatternDescription` are the older school-day pattern model (keyed by `(PatternID, SchoolCode)`); `PatternsNew`/`PatternDescriptionNew` add `YearID` to the key (per-year patterns). The `*New` tables are the current year-aware model. (These define rotating-day / block-schedule patterns; cf. `sched.TemplatePatternGroup` referenced elsewhere.)

#### `dbo.Patterns`
Legacy school-day pattern header — named pattern per school. PK is composite `(PatternID, SchoolCode)`.

| Column | Type | Notes |
|---|---|---|
| `PatternID` | int | PK (composite) |
| `SchoolCode` | varchar(50) | PK (composite) |
| `Name` | nvarchar(50) | Pattern name; nullable |
| `Contacts` | int | Nullable |
| `Team` | nvarchar(50) | Nullable |
| `ModifiedBy` / `ModifiedDate` | int/smalldatetime | Audit |

---

#### `dbo.PatternsNew`
Year-aware school-day pattern header (current model). PK is composite `(PatternID, SchoolCode, Name, YearID, Team)`.

| Column | Type | Notes |
|---|---|---|
| `PatternID` | int | PK (composite) |
| `SchoolCode` | varchar(50) | PK (composite) |
| `Name` | nvarchar(50) | PK (composite); required |
| `YearID` | int | PK (composite); per-year |
| `Team` | nvarchar(50) | PK (composite); required |
| `ModifiedBy` / `ModifiedDate` | int/smalldatetime | Audit |

---

#### `dbo.PatternDescription`
Legacy pattern detail — which `(Day, Begin)` periods belong to a pattern. Surrogate PK `AutoNum`.

| Column | Type | Notes |
|---|---|---|
| `AutoNum` | int IDENTITY | PK |
| `PatternID` | smallint | The pattern; indexed |
| `Day` | smallint | Day in cycle; indexed |
| `Begin` | smallint | Period begin; indexed |
| `SchoolCode` | varchar(50) | Indexed |
| `ModifiedBy` / `ModifiedDate` | int/smalldatetime | Audit |

---

#### `dbo.PatternDescriptionNew`
Year-aware pattern detail (current model). PK is composite `(PatternID, Day, Begin, SchoolCode, YearID)`.

| Column | Type | Notes |
|---|---|---|
| `PatternID` | smallint | PK (composite) |
| `Day` | smallint | PK (composite) |
| `Begin` | smallint | PK (composite) |
| `SchoolCode` | varchar(50) | PK (composite) |
| `YearID` | int | PK (composite); per-year |
| `ModifiedBy` / `ModifiedDate` | int/smalldatetime | Audit |

---

### `dbo` payment tables (core accounting)

These are the **core family-accounting payment tables** (distinct from the OA application payments and the online-portal `On_Line_Payment`). `Payments` is the payment header; `Payment_Charges` allocates a payment across charges; `Payment_Deferred` handles deferred/prepaid amounts; `PaymentMethods` is the method lookup.

#### `dbo.Payments`
**Core payment record** — a family payment with method, amount, fiscal year, accounting-system linkage, deposit, posting state, and QuickBooks sync. Like `Charges`, carries the legacy `Amt`/`_Amount`-style decimal column (`Amt` decimal is current). One row per payment.

> **Contains payment data**: check numbers, ACH/CC flags, session/user-agent. Treat as confidential.

| Column group | Type | Notes |
|---|---|---|
| `PaymentID` | int IDENTITY | PK |
| `FamilyID` / `StudentID` / `SchoolCode` / `CatID` | mixed | Who/what; `FamilyID` indexed |
| `Date` / `Amt` | datetime/decimal(10,2) | Payment date & amount (`Amt` is the decimal amount) |
| Method: `Method` / `PaymentType` / `Check` / `ACH` / `CC` / `Credit` | mixed | Payment method + check number |
| Accounting: `FiscalYearID` / `AccountingSystemID` / `TransactionID` / `DepositID` / `deposit` | int | Ledger linkage; `FiscalYearID`/`TransactionID` indexed |
| Posting: `Posted` / `PostedID` / `Lock` / `End_of_day` / `ErrorCheck` | mixed | Post/lock state |
| Sync: `QB_PaymentID` / `SyncId` / `Balance_Transfer` | mixed | QuickBooks/sync |
| Reversal: `ReversePaymentID` / `paymentinterruption` | mixed | Reversal linkage |
| Audit/source: `Memo` / `Note` / `SessionID` / `FileID` / `UserAgent` / `ModifiedBy` / `ModifiedDate` | mixed | — |

---

#### `dbo.Payment_Charges`
Allocation of a payment across charges (many-to-many `Payments` ↔ `Charges`). Carries the legacy `_Amount` (float) alongside the current `Amount` (decimal).

| Column | Type | Notes |
|---|---|---|
| `PCID` | int IDENTITY | PK |
| `PaymentID` | int | → `dbo.Payments`; indexed |
| `ChargeID` | int | → `dbo.Charges`; indexed |
| `Amount` | decimal(10,2) | Allocated amount (current) |
| `_Amount` | float | Legacy float amount |
| `ModifiedBy` / `ModifiedDate` | int/smalldatetime | Audit |

---

#### `dbo.Payment_Deferred`
Deferred/prepaid payment allocations — amount held against a family/student/category for a fiscal year, with accounting-system and QuickBooks linkage. Heavily indexed for accounting queries. Carries `_Amount` (float) + `Amount` (decimal).

| Column | Type | Notes |
|---|---|---|
| `AutoNum` | int IDENTITY | PK |
| `FamilyID` / `StudentID` / `CatID` / `SchoolCode` | mixed | Who/what; indexed |
| `PaymentID` | int | → `dbo.Payments`; nullable |
| `FiscalYearID` / `AccountingSystemID` | int | Ledger; indexed |
| `Amount` | decimal(10,2) | Deferred amount (current) |
| `_Amount` | float | Legacy float amount |
| `QB_PaymentID` / `SyncId` / `Balance_Transfer` | mixed | QuickBooks/sync |
| `ModifiedBy` / `ModifiedDate` | int/smalldatetime | Audit |

---

#### `dbo.PaymentMethods`
Payment-method lookup per school — method type, linked to a `DefinedLists` entry and a QuickBooks payment method.

| Column | Type | Notes |
|---|---|---|
| `PaymentMethodID` | int IDENTITY | PK |
| `PaymentMethodType` | nvarchar(125) | Method name; nullable |
| `DLID` | int | → `dbo.DefinedLists`; nullable |
| `SchoolCode` | varchar(50) | Nullable |
| `QB_PaymentMethodID` / `QB_PaymentMethodName` | nvarchar | QuickBooks mapping |

---

#### `dbo` ParentsWeb-log / password-history / patterns / payments — cross-reference summary

| Table | Scope | Key FK targets / notes |
|---|---|---|
| `ParentsWebLog` | Portal login/logout audit | **PII**; usage reporting (district + login time) |
| `PasswordHistory` | Staff password reuse history | **Credential** — never expose |
| `Patterns` | **Legacy** school-day pattern header | PK `(PatternID, SchoolCode)` |
| `PatternsNew` | Year-aware pattern header (current) | PK adds `YearID`, `Name`, `Team` |
| `PatternDescription` | **Legacy** pattern detail | Surrogate PK |
| `PatternDescriptionNew` | Year-aware pattern detail (current) | PK adds `YearID` |
| `Payments` | **Core family payment** | **Payment data**; `Amt` decimal; QB sync |
| `Payment_Charges` | Payment ↔ charge allocation | `Payments`, `Charges`; `_Amount`/`Amount` |
| `Payment_Deferred` | Deferred/prepaid allocations | `Payments`; heavily indexed; `_Amount`/`Amount` |
| `PaymentMethods` | Payment-method lookup | `DefinedLists`; QuickBooks mapping |

---

### `dbo.Person` and the `Person_*` family — the core SIS person model

> **This is the heart of the FACTS/RenWeb SIS.** `dbo.Person` is the single central record for every individual (student, staff, parent — a person can be more than one). It is the FK target for hundreds of tables across this catalog (`PersonID` everywhere). The role-specific tables `Person_Student`, `Person_Staff`, and the family link `Person_Family`/`Parent_Student` extend it. A person's `PersonID` *is* their student/staff/parent id — the `StudentID`/`StaffID`/`ParentID` used throughout the schema are `Person.PersonID` values.

#### `dbo.Person`
The master person record — identity, contact, demographics, medical, religious/sacrament, education, employment, portal credentials, directory/alert preferences, and role flags. Identity seeds at 10100. **Temporal table** (system-versioned). PK `PersonID`.

> **Contains extensive PII**: `SSN`, `Birthdate`, `DriversLicense`, medical (doctor/insurance/blood type/`MedicalNote`), credentials (`Password`, `pswd`, `username`), payment GUIDs. Treat as highly confidential; never expose SSN, credentials, or medical fields.

Documented by column group (~150 columns):

| Column group | Type | Notes |
|---|---|---|
| `PersonID` | int IDENTITY(10100,1) | PK; the universal person id |
| Role flags: `Student` / `Staff` / `Parent` | bit | A person may hold multiple roles; default 0 |
| Legacy role ids: `_StudentID` / `_StaffID` / `_ParentID` | int | Legacy per-role ids (default 0); modern code uses `PersonID` |
| Name: `LastName` / `FirstName` / `MiddleName` / `NickName` / `Salutation` / `Suffix` / `MaidenName` | nvarchar | Heavily indexed (last+first+middle) |
| Demographics: `Birthdate` / `Gender` / `Ethnicity` / `Citizenship` / `MaritalStatus` / `SSN` / `PrimaryLanguage` / `DefaultLanguage` / `Deceased` | mixed | **`SSN` sensitive**; `DefaultLanguage` default 'en-US' |
| Birth: `Birthplace` / `BirthCity` / `BirthState` / `BirthCountry` / `BirthCounty` | nvarchar | — |
| Contact: `Email` / `Email2` / `HomePhone` / `CellPhone` / `WorkPhone` / `WorkPhoneExtension` / `Fax` / `CountryCode` / `AddressID` | mixed | `AddressID` → `dbo.Address` (indexed) |
| Vehicle: `AutoMake` / `AutoModel` / `AutoLicense` / `DriversLicense` / `PermitNumber` | nvarchar | **`DriversLicense` sensitive** |
| Medical: `BloodType` / `Doctor`(+Phone/Address) / `Hospital`(+Address) / `Dentist`(+Phone/Address) / `Insurance{Company,Policy,Group}` / `Treat` / `MedicalNote` | mixed | **Health PII**; `MedicalNote` synced to `rw.PersonNote` by trigger |
| Religion/sacraments: `Denomination` / `ChurchID` / `LocalChurchMember` / `Baptism*` / `Communion*` / `Confirmation*` / `Reconciliation*` / `BarMitzvah*` (Church/City/State/Date each) | mixed | Synced to `rw.PersonReligiousEvent` by trigger |
| Education: `EducationLevel` / `Highschool` / `Bachelor*` / `Master*` / `PHD*` (School/Degree/Year, ×2 sets) | mixed | Degree history |
| Employment: `Occupation` / `Company` / `JobCategory` / `WorkStreet` / `WorkCity`/`State`/`Zip`/`Country` / `WorkCityStateZip` / `Subdivision` / `ExperienceSchool` / `ExperienceTotal` | mixed | — |
| Portal credentials: `username` / `Password` / `pswd` (varbinary) / `PasswordVersion` / `PasswordCreationDate` / `LoginAttempts` / `InvalidLoginCount` / `PasswordResetUrlSendDate` / `IsPasswordResetUrlExpired` / `ResetPasswordDate` / `ChatLogin` / `AutoLogin` / `LastSchoolLogin` / `LastConfigSchoolID` | mixed | **Credentials**; `username` filtered-indexed |
| Directory blocks: `Directory_BlockName` / `_BlockHomePhone` / `_BlockCellPhone` / `_BlockAddress` / `_BlockEmail` | bit | Directory suppression |
| Parent-alert prefs: `ParentAlertPreference` / `ParentAlertHomePhone` / `ParentAlertCellPhone` (default 1) / `ParentAlertWorkPhone` / `ParentAlertNoText` / `ParentAlertPin` | mixed | Maps to `ParentAlert` routing |
| Auto-email: `AutoEmailProgressReport` (CHECK {WEEKLY,DAILY,NEVER,0,''}) / `AutoEmailGradebookZero` | mixed | — |
| Donor: `MatchingGiftEmployer` / `DonorBlock` / `DonorCompanyID` | mixed | Development/giving |
| Public-school: `PublicSchoolDistrict`/`County`/`State`/`LocalSchool`/`Code` | nvarchar | Sending-school info |
| Misc: `PathToPicture` / `PicResized` / `Note` / `ReducedLunch` / `StateReducedLunchOption` / `DayCareRateID` / `UnlinkSibling` / `AttendanceScheduledOnly` / `EnrollmentResponsibilityID` / `NewStudentInquiryID`(+ChildNumber) | mixed | — |
| Payment GUIDs: `CryptPayPNGUID` / `CryptPayOEGUID` | nvarchar | **Gateway tokens — sensitive** |
| Import/legacy: `ImportID` / `LegacyPersonID` | nvarchar | Migration linkage |
| Audit: `ModifiedDate` / `ModifiedBy` / `CreatedOnUTC` | mixed | `ModifiedDate` bumped by many triggers across the DB |
| `ModifiedOnUTC` / `ModifiedOnUTCmax` | datetime2 | System-versioning period (temporal); indexed |

**Triggers** (three, all significant):
- `TR_dbo_Person_Insert` (AFTER INSERT): (1) copies `MedicalNote` into `rw.PersonNote` (NoteType 3, desktop note); (2) materializes religion/sacrament columns (Baptism/Bar mitzvah/Communion/Confirmation/Reconciliation) into `rw.PersonReligiousEvent`; (3) bumps `ModifiedDate`. Sets `Context_Info 0x86385` to suppress the `rw.PersonReligiousEvent` triggers.
- `TR_dbo_Person_Update` (AFTER UPDATE): (1) syncs `MedicalNote` changes to `rw.PersonNote`; (2) upserts/deletes religion events in `rw.PersonReligiousEvent` based on changed sacrament columns; (3) bumps `ModifiedDate`; (4) sets `FamilyConfig.FactsUpdateState=1` and `facts.FamilyMapping.UpdateState=1` for the person's families (FACTS sync); (5) on name/email change, posts a Passport/UserMS **demographic sync** via `dbo.Passport_DemographicSync 'person'` — **skipped on Linux/container DBs** (`@@VERSION NOT LIKE '%Linux%'`).
- `TR_dbo_Person_Update_LegalName` (AFTER UPDATE): on any name change (First/Middle/Last/Suffix/Salutation), writes the new name into `dbo.PersonPreviousName` (legal-name history).

---

#### `dbo.Person_Student`
**Core student-enrollment record** — per-student, per-school enrollment status, grade, dates, advisor/mentor, honor-roll/rank exclusions, lockers, public-school info, and progression (next status/grade/school) fields. **Temporal table.** PK is composite `(StudentID, SchoolCode)` (a student can have rows at multiple schools). `StudentID` = `Person.PersonID`.

| Column group | Type | Notes |
|---|---|---|
| `StudentID` | int | PK (composite); = `Person.PersonID` |
| `SchoolCode` | varchar(50) | PK (composite) |
| `PersonStudentID` | int IDENTITY | Unique surrogate |
| Status: `Status` / `Substatus` / `NextStatus` / `EnrollDate` / `WithdrawDate` / `WithdrawReason` / `GraduationDate` / `Reenrolled` / `ReEnrollMessage` | mixed | `Status` indexed; drives `Enrollment_Log` via trigger |
| Grade/school: `GradeLevel` / `NextGradeLevel` / `NextSchoolCode` / `SchoolID` / `Placement` / `ClassOf` | mixed | All indexed |
| Progression (staging): `PreProgression{Status,NextStatus,GradeLevel,NextGradeLevel,SchoolCode,NextSchoolCode,ProgressionDate}` / `ProgressionDate` | mixed | Year-rollover progression |
| Advisor: `AdvisorID` / `StudentMentorID` / `TeacherSite` | mixed | Default 0 |
| Honor/rank: `ExcludeTermHonorRoll` / `ExcludeCumHonorRoll` / `ExcludeTermRank` / `ExcludeCumRank` | bit | Report/transcript exclusions |
| Lockers: `Locker1` / `Combination1` / `Locker2` / `Combination2` | nvarchar | — |
| Public school: `PublicSchool{District,County,State,LocalSchool,Code}` | nvarchar | Sending/receiving school |
| Misc: `TranscriptNote1` / `ReducedLunch` / `DayCareRateID` / `UnlinkSibling` / `DistrictTransferableTo` | mixed | — |
| `CreatedOnUTC` / `ModifiedOnUTC` / `ModifiedOnUTCmax` | datetime2 | Temporal; `ModifiedOnUTC` indexed |

**Triggers:**
- `tr_Person_student_SetModified_U` (INSERT, UPDATE): bumps `Person.ModifiedDate` for the student.
- `tr_Person_student_U` (INSERT, UPDATE): **maintains `dbo.Enrollment_Log`** — on a status change, inserts an Enrollment_Log row (Enrolled/Withdrawn/Graduate/status-change, choosing the right date and grade level); also logs school-change and grade-level-change events. This is the source of enrollment history.
- `TR_dbo_Person_Student_SyncTenantRelationship` (AFTER INSERT, UPDATE): on `SchoolCode` change, posts a Passport tenant-relationship sync via `dbo.Passport_UpdateTenantRelationship`, **batched in chunks of 500** PersonIds; **skipped on Linux/container DBs**.

---

#### `dbo.Person_Staff`
**Core staff record** — employment/role flags, department, dates, school-level flags, FTE, portal credentials, and staff-directory/alert settings. PK `StaffID` (= `Person.PersonID`).

| Column group | Type | Notes |
|---|---|---|
| `StaffID` | int | PK; = `Person.PersonID` |
| Role flags: `Active` / `Faculty` / `Administrator` / `Substitute` / `DistrictUser` / `DistrictWideUser` / `DualEnrolledUser` | bit | — |
| Level flags: `Preschool` / `Elementary` / `MiddleSchool` / `HS` | bit | Which levels they serve |
| Employment: `Department` / `StartDate` / `EndDate` / `FullTime` / `FTE` / `RoomID` / `Spouse` / `FinancialFamilyID` | mixed | — |
| Credentials: `LoginPassword` / `Loginpswd` (varbinary) / `PasswordModified` | mixed | **Credentials** |
| Portal: `PWHeadline` / `PWComments` / `TeacherSite` / `BlockSurvey` / `StaffDirectoryBlock` / `UnsubscribeRenWebEmail` | mixed | Staff portal/directory |
| Misc: `PDA` / `ParentAlertPin` / `LegacyStaffID` | mixed | — |

**Trigger** `tr_Person_Staff_U` (INSERT, UPDATE): bumps `Person.ModifiedDate` for the staff member, and sets `FamilyConfig.FactsUpdateState=1` + `facts.FamilyMapping.UpdateState=1` for families the staff member belongs to (FACTS sync, for staff who are also FACTS customers).

---

#### `dbo.Person_Family`
**The person↔family membership link** — ties a person to a family with role (parent/student), financial responsibility, and family ordering. PK is composite `(PersonID, FamilyID)`. (Distinct from `Parent_Student`, which links parents directly to students; `Person_Family` groups people into family units.)

| Column | Type | Notes |
|---|---|---|
| `PersonID` | int | PK (composite); → `Person` |
| `FamilyID` | int | PK (composite); the family unit |
| `Parent` / `Student` | bit | Role in family; default 0 |
| `FinancialResponsibility` / `FinancialResponsibilityPercent` | bit/varchar | Indexed with `FamilyID`/`Parent` |
| `FamilyOrder` | int | Ordering within family |
| `FactsCustomer` | bit | FACTS customer flag; default 0 |

**Triggers** `TR_dbo_Person_Family_Update` (INSERT, UPDATE) and `TR_dbo_Person_Family_Delete` (DELETE): both set `FamilyConfig.FactsUpdateState=1` and `facts.FamilyMapping.UpdateState=1` for affected families (FACTS sync on family-membership change).

---

#### `dbo.Person_Race`
Race multi-select for a person. CASCADE from `Person`. PK is composite `(PersonID, Race)`. `IsPortalRace` flags portal-submitted entries; `RaceDescriptorID` links a structured Ed-Fi descriptor.

| Column | Type | Notes |
|---|---|---|
| `PersonID` | int | PK (composite); → `Person` (CASCADE) |
| `Race` | nvarchar(256) | PK (composite) |
| `IsPortalRace` | bit | Portal-submitted; default 0 |
| `RaceDescriptorID` | uniqueidentifier | Structured descriptor; nullable |

---

#### `dbo.Person_Education`
Degree/education history per person (multi-row alternative to the inline `Person.Bachelor*/Master*/PHD*` columns).

| Column | Type | Notes |
|---|---|---|
| `EducationID` | int IDENTITY | PK |
| `PersonID` | int | FK → `Person` |
| `EducationLevel` | int | Level code; nullable |
| `DegreeType` / `DegreeSchool` / `DegreeName` / `DegreeYear` | nvarchar | Degree detail |
| `HighestCompletedLevelOfEducationDescriptorId` | uniqueidentifier | Ed-Fi descriptor; nullable |

---

#### `dbo.Person_Interest`
Interests for a person (name-keyed, legacy). PK is composite `(PersonID, Interest)`.

| Column | Type | Notes |
|---|---|---|
| `PersonID` | int | PK (composite) |
| `Interest` | nvarchar(50) | PK (composite); interest name |

---

#### `dbo.PersonInterestNew`
Interests for a person (ID-keyed, current). PK is composite `(PersonID, InterestID)`. The ID-based replacement for `Person_Interest` (links `dbo.Interest`).

| Column | Type | Notes |
|---|---|---|
| `PersonID` | int | PK (composite) |
| `InterestID` | int | PK (composite); → `dbo.Interest` |

> **Legacy-vs-new pair**: `Person_Interest` (name-keyed) vs `PersonInterestNew` (ID-keyed, → `Interest`). Same pattern as `CurriculumPlan` name-vs-ID models.

---

#### `dbo.PersonPreviousName`
Legal-name history — every prior name a person held, written by `Person`'s `TR_dbo_Person_Update_LegalName` trigger on any name change. CASCADE from `Person`.

| Column | Type | Notes |
|---|---|---|
| `PersonPreviousNameId` | int IDENTITY | PK |
| `PersonId` | int | FK → `Person` (CASCADE) |
| `FirstName` / `MiddleName` / `LastName` / `Suffix` / `Salutation` | nvarchar | The prior name |
| `OtherNameTypeDescriptorCode` | nvarchar(50) | Name type; default 'Unknown' |
| `ModifiedDateTime` | datetime2 | When recorded |

---

#### `dbo.PersonPreferenceBit`
Per-person boolean preferences keyed by preference type — a normalized preference store. FKs to `Person` and `PreferenceType`. Unique on `(PersonID, PreferenceTypeID)`.

| Column | Type | Notes |
|---|---|---|
| `PersPrefBitID` | int IDENTITY | PK |
| `PersonID` | int | FK → `Person` |
| `PreferenceTypeID` | int | FK → `dbo.PreferenceType` |
| `IsSelected` | bit | Default 0 |

**Trigger** `TR_dbo_PersonPreferenceBit_Insert` (INSERT, UPDATE): sets `FamilyConfig.FactsUpdateState=1` + `facts.FamilyMapping.UpdateState=1` for the person's families (FACTS sync).

---

#### `dbo` Person family — cross-reference summary

| Table | Scope | Key FK targets / notes |
|---|---|---|
| `Person` | **Master person record** | **Heavy PII**; temporal; PK = universal `PersonID`; 3 triggers (rw.PersonNote / rw.PersonReligiousEvent / FACTS / Passport / PersonPreviousName) |
| `Person_Student` | Core student enrollment | **Temporal**; PK `(StudentID, SchoolCode)`; drives `Enrollment_Log`; Passport tenant sync |
| `Person_Staff` | Core staff record | PK `StaffID`; **credentials**; FACTS sync trigger |
| `Person_Family` | Person↔family membership | PK `(PersonID, FamilyID)`; FACTS sync triggers |
| `Person_Race` | Person race multi-select | CASCADE from `Person`; Ed-Fi descriptor |
| `Person_Education` | Degree/education history | → `Person` |
| `Person_Interest` | Interests (name-keyed, legacy) | PK `(PersonID, Interest)` |
| `PersonInterestNew` | Interests (ID-keyed, current) | → `dbo.Interest` |
| `PersonPreviousName` | Legal-name history | CASCADE from `Person`; written by name-change trigger |
| `PersonPreferenceBit` | Per-person boolean preferences | `Person`, `PreferenceType`; FACTS sync trigger |

---

### `dbo` person-tracking, pickup, pictures, portfolio, preference-type, previous-schools, and QuickBooks (QB) tables

#### `dbo.PersonTracking`
Per-person tracking-status records — notes, date range, status, and a UD status, against a tracking system. The person-level counterpart to the admissions tracking (`OAStudentTrack`/`OARequestInfoTrack`); ties to `TrackingConfig` via `TrackingSystemID`.

| Column | Type | Notes |
|---|---|---|
| `TrackingID` | int IDENTITY | PK |
| `PersonID` | int | The person; nullable |
| `TrackingSystemID` | int | → `dbo.TrackingConfig`; nullable |
| `TrackingStatus` | int | Status; nullable |
| `UDStatus` | nvarchar(50) | User-defined status; nullable |
| `Notes` | nvarchar(max) | Nullable |
| `StartDate` / `EndDate` | datetime | Range; nullable |
| `ModifiedBy` / `ModifiedDate` | int/smalldatetime | Audit |

---

#### `dbo.Pickup`
Authorized-pickup people per student — name, contact, relationship, and address. The "live" SIS counterpart to the OA-application `OAEmergencyPickup`. Links to `rw.ContactAddress`.

> **Contains PII**: third-party names, phones, email. Treat as confidential.

| Column | Type | Notes |
|---|---|---|
| `PickupID` | int IDENTITY | PK |
| `StudentID` | int | The student; nullable |
| Name: `FirstName` / `MiddleName` / `LastName` / `Salutation` / `Suffix` | nvarchar | — |
| Contact: `HomePhone` / `CellPhone` / `WorkPhone` / `Email` / `CountryCode` | nvarchar | — |
| `Relationship` | nvarchar(256) | — |
| `ContactAddressID` | int | FK → `rw.ContactAddress`; nullable |
| `SortOrder` / `PortalSortOrder` (default 1000) / `RefID` | int | Ordering |
| `Note` | nvarchar(2000) | Nullable |
| `LegacyPersonID` | nvarchar(50) | Migration; uniquely indexed when not null |

---

#### `dbo.Pictures`
Image/media library entries per staff/class/school — file, caption, group, sharing, hyperlink, and "picture cube" flag. `CHECK FileName <> ''`.

| Column | Type | Notes |
|---|---|---|
| `PictureID` | int IDENTITY | PK |
| `StaffID` / `ClassID` / `SchoolCode` | mixed | Owner/scope |
| `FileName` | nvarchar(128) | CHECK non-empty |
| `Caption` / `PictureGroup` / `Location` / `Hyperlink` | nvarchar | — |
| `Share` / `PictureCube` / `System` | bit | Flags |

---

#### `dbo.Portfolio`
Student/person portfolio file uploads — per person, with grade/year/term context, soft-delete, and audit. FK `LastModifiedBy` → `Person`. (Cf. the `rw.PortfolioGroup` categories used across OA; this is the actual uploaded-file store.)

| Column | Type | Notes |
|---|---|---|
| `PortfolioID` | int IDENTITY | PK |
| `PersonID` | int | The person; nullable |
| `FileName` / `UUID` / `FileType` | mixed | The file |
| `GradeLevel` / `YearID` / `TermID` / `ClassID` | mixed | Context |
| `Note` | nvarchar(2000) | Nullable |
| Upload: `UploadedBy` / `UploadedDate` / `UploadedDateUTC` | mixed | — |
| Soft-delete: `Deleted` / `DeletedBy` / `DeletedDate` | mixed | — |
| `LastModifiedBy` | int | FK → `Person`; indexed |
| `LastModifiedDateUTC` | datetime2 | — |

---

#### `dbo.PreferenceType`
Lookup of preference types (description), referenced by `PersonPreferenceBit.PreferenceTypeID`. Unique on `Description`.

| Column | Type | Notes |
|---|---|---|
| `PreferenceTypeID` | int IDENTITY | PK |
| `Description` | nvarchar(120) | Required; unique |

---

#### `dbo.PreviousSchools`
Prior-school history per student — school name/address/phone, dates attended, grade completed. PK is composite `(StudentID, SchoolNumber)`. (The "live" SIS counterpart to the OA-application address-history fields configured by `OAAddressField`.)

| Column | Type | Notes |
|---|---|---|
| `StudentID` | int | PK (composite); default 0 |
| `SchoolNumber` | smallint | PK (composite); ordinal; default 0 |
| `SchoolName` / `Address` / `Phone` | nvarchar | — |
| `FromDate` / `ToDate` / `GradeCompleted` | nvarchar | Text dates |
| `SchoolNote` | nvarchar(1000) | Nullable |
| `ModifiedBy` / `ModifiedDate` | int/smalldatetime | Audit |

---

### `dbo` QuickBooks (QB) integration tables

The **`QB_*`** tables are the QuickBooks accounting-integration staging/log (the sync that the `QB_PaymentID`/`QB_*` columns on `Payments`/`Payment_Deferred`/`PaymentMethods` feed). They map RenWeb/FACTS families↔QB customers and stage charges, payments, checks, and balance transfers pushed to QuickBooks. Most carry a `TicketId`/`RequestId` (the async sync request) and `QB_*` ids (the resulting QuickBooks object ids).

#### `dbo.QB_Customers`
Maps a RenWeb family to a QuickBooks customer — the customer-sync record. Carries the sync `TicketID`/`RequestID`, the RW family id, and the resulting QB family/customer id.

| Column | Type | Notes |
|---|---|---|
| `Id` | int IDENTITY | PK |
| `TicketID` | nvarchar(50) | Sync ticket; required |
| `RequestID` | int | Sync request; required |
| `RW_FamilyID` | nvarchar(50) | RenWeb family; required |
| `QB_FamilyID` | nvarchar(50) | Resulting QuickBooks customer id; nullable |
| `FamilyName` | nvarchar(128) | Nullable |
| `AddTime` | datetime | Nullable |
| `SchoolCode` | varchar(50) | Nullable |

---

#### `dbo.QB_Charges`
Staged charge/payment data pushed to QuickBooks — links a RenWeb `ChargeID`/`PaymentId` to the QB item/invoice, with amounts, dates, account-system, and payment method. The charge-sync log.

| Column group | Type | Notes |
|---|---|---|
| `Id` | int IDENTITY | PK |
| Sync: `TicketId` / `RequestId` | mixed | Async sync request |
| Family: `FamilyId` / `QB_FamilyId` / `FamilyName` | mixed | RenWeb + QB family |
| Charge: `ChargeId` / `ChargeDate` / `DueDate` / `ChargeAmount` / `CatId` / `Description` / `Title` | mixed | → `dbo.Charges` |
| Payment: `PaymentId` / `PaymentDate` / `PaymentAmount` / `ClearedAmount` / `PaymentMethodId` / `CheckNo` | mixed | → `dbo.Payments` |
| QB linkage: `QB_ItemId` / `QB_AcctSystemID` | nvarchar | QuickBooks object ids |
| Accounting: `AcctSystemId` / `AcctSystemName` / `SchoolCode` / `Transaction_time` | mixed | — |
| `Note` | nvarchar(255) | Nullable |

---

#### `dbo.QB_CheckAddDetails`
Staged check (payment) data pushed to QuickBooks — check number, amount, AR account, bank, and the resulting `QB_CheckId`.

| Column | Type | Notes |
|---|---|---|
| `Id` | int IDENTITY | PK |
| `CustomerId` | nvarchar(50) | QB customer; nullable |
| `CheckNo` / `TxnDate` / `Amount` / `Memo` | mixed | Check detail |
| `ARAccountId` / `BankId` | nvarchar | QB account/bank |
| Linkage: `ChargeId` / `PaymentId` / `TicketId` / `RequestId` / `AccountingSystemId` / `SchoolCode` | mixed | RenWeb + sync |
| `QB_CheckId` | nvarchar(50) | Resulting QuickBooks check id |

---

#### `dbo.QB_BalanceTransferTxns`
Staged balance-transfer transactions pushed to QuickBooks — invoice/credit-memo linkage, amount, account/item refs, and type. Handles family balance transfers in the QB sync.

| Column | Type | Notes |
|---|---|---|
| `Id` | int IDENTITY | PK |
| Sync: `TicketId` | nvarchar(50) | — |
| Family: `FamilyId` / `QB_CustomerId` | mixed | RenWeb + QB |
| Accounting: `AccountingSystemId` / `QB_AccountRefId` / `QB_ItemId` / `CatId` | mixed | — |
| `Amount` / `TxnCreationDate` | decimal/smalldatetime | — |
| Type: `Type` / `QB_Type` | nvarchar | — |
| QB docs: `QB_InvoiceId` / `QB_CreditMemoId` | nvarchar | Resulting QuickBooks documents |
| `SchoolCode` / `Desc` | mixed | — |

---

#### `dbo` person-tracking / pickup / pictures / portfolio / preference / previous-schools / QB — cross-reference summary

| Table | Scope | Key FK targets / notes |
|---|---|---|
| `PersonTracking` | Per-person tracking status | → `TrackingConfig`; cf. `OAStudentTrack` |
| `Pickup` | Authorized-pickup people | **PII**; → `rw.ContactAddress`; cf. `OAEmergencyPickup` |
| `Pictures` | Image/media library | By staff/class/school |
| `Portfolio` | Person portfolio file uploads | → `Person`; cf. `rw.PortfolioGroup` |
| `PreferenceType` | Preference-type lookup | Referenced by `PersonPreferenceBit` |
| `PreviousSchools` | Prior-school history | PK `(StudentID, SchoolNumber)` |
| `QB_Customers` | RenWeb family ↔ QB customer | QuickBooks sync |
| `QB_Charges` | Charge/payment QB sync log | → `Charges`/`Payments`; QB items |
| `QB_CheckAddDetails` | Check QB sync | → QB check |
| `QB_BalanceTransferTxns` | Balance-transfer QB sync | → QB invoice/credit memo |

---

### `dbo` QuickBooks (QB) integration tables — continued (invoice/deposit push, error log, imported QB data)

> **Two directions.** The QB integration moves data both ways: **outbound push** (RenWeb → QuickBooks: `QB_Customers`/`QB_Charges`/`QB_CheckAddDetails`/`QB_BalanceTransferTxns`/`QB_Invoice_PC`/`QB_Deposits`, carrying `TicketId`/`RequestId` sync requests) and **inbound import** (QuickBooks → RenWeb: the `QB_Imported*` tables, which mirror QB transactions keyed by QuickBooks `TxnId` + `SchoolCode`, with `SyncId`/`DeleteSyncId` change tracking).

#### `dbo.QB_Invoice_PC`
Outbound invoice+payment ("PC" = payments/charges) sync log — like `QB_Charges` but pairs the charge invoice and its payment, carrying both `QB_InvoiceID` and `QB_PaymentID`. Uses `Amt_Charges`/`Amt_Payments` amount columns.

| Column group | Type | Notes |
|---|---|---|
| `Id` | int IDENTITY | PK |
| Sync: `TicketID` / `RequestID` | mixed | Async request |
| Family: `FamilyID` / `QB_FamilyID` / `FamilyName` | mixed | RenWeb + QB |
| Charge: `ChargeID` / `ChargeDate` / `Amt_Charges` / `CatID` / `Title` | mixed | → `Charges` |
| Payment: `PaymentID` / `PaymentDate` / `Amt_Payments` / `ClearedAmount` | mixed | → `Payments` |
| QB linkage: `QB_ItemID` / `QB_InvoiceID` / `QB_PaymentID` | nvarchar | Resulting QB ids |
| Accounting: `AccSystemID` / `AcctSystemName` | mixed | — |

---

#### `dbo.QB_Deposits`
Outbound deposit sync log — maps a RenWeb `DepositId`/`PaymentId` to a QuickBooks deposit, with amount, date, and account number.

| Column | Type | Notes |
|---|---|---|
| `Id` | int IDENTITY | PK |
| `TicketId` / `RequestId` | mixed | Async request |
| `DepositId` / `PaymentId` | int | RenWeb deposit/payment |
| `DepositAmount` / `DepositDate` / `AccountNumber` | mixed | Deposit detail |
| `QB_PaymentId` / `QB_DepositId` | nvarchar | Resulting QB ids |
| `TransactionTime` / `SchoolCode` | mixed | — |

---

#### `dbo.QB_ErrorLog`
QuickBooks sync error log — error text per ticket/school.

| Column | Type | Notes |
|---|---|---|
| `Id` | int IDENTITY | PK |
| `ErrorTxt` | nvarchar(max) | Error detail; nullable |
| `Ticket` | nvarchar(50) | Sync ticket; nullable |
| `SchoolCode` | varchar(50) | Nullable |
| `ModifiedTime` | datetime | Nullable |

---

### `dbo` QB inbound-import tables

The **`QB_Imported*`** tables mirror QuickBooks transactions pulled back into RenWeb (so RenWeb can reconcile/report against what's actually in QuickBooks). All keyed by QuickBooks `TxnId` (+ `SchoolCode` where PK), with `SyncId`/`DeleteSyncId` for incremental change tracking. Header/line-item pairs follow QuickBooks' transaction model.

#### `dbo.QB_ImportedInvoices`
Imported QuickBooks invoices (header) — customer, AR account, dates, subtotal, applied/balance amounts. PK `Id`; keyed by QB `TxnId`.

| Column | Type | Notes |
|---|---|---|
| `Id` | int IDENTITY | PK |
| `TxnId` | nvarchar(50) | QuickBooks transaction id |
| `TxnNumber` / `TimeCreated` / `TimeModified` / `TxnDate` / `DueDate` / `TimeZoneOffset` | mixed | QB transaction metadata |
| `CustomerListId` / `CustomerFullName` / `ARAccountRef` | nvarchar | QB customer/account |
| `SubTotal` / `AppliedAmount` / `BalanceRemaining` | decimal | Amounts |
| `SchoolCode` / `SyncId` / `DeleteSyncId` | mixed | Change tracking |

---

#### `dbo.QB_ImportedInvoiceItems`
Line items for imported QuickBooks invoices — item, rate, amount, description. Child of `QB_ImportedInvoices` (by `TxnId`).

| Column | Type | Notes |
|---|---|---|
| `Id` | int IDENTITY | PK |
| `TxnId` / `TxnLineItemId` | nvarchar | QB transaction + line |
| `FullName` / `Description` | nvarchar | Item |
| `Rate` / `Amount` | decimal(10,2) | — |
| `SchoolCode` | varchar(50) | — |

---

#### `dbo.QB_ImportedPayments`
Imported QuickBooks customer payments (header) — customer, AR account, total, ref number, payment method. Keyed by QB `TxnId` + `SchoolCode`.

| Column | Type | Notes |
|---|---|---|
| `TxnId` | nvarchar(50) | PK (composite); QB transaction id |
| `SchoolCode` | varchar(50) | PK (composite) |
| `TxnNumber` / `TimeCreated` / `TimeModified` / `TxnDate` / `TimeZoneOffset` | mixed | QB metadata |
| `CustomerListId` / `CustomerFullName` / `ARAccountRef` | nvarchar | QB customer/account |
| `TotalAmount` | decimal(10,2) | — |
| `Memo` / `RefNumber` / `PaymentMethodRef` | nvarchar | — |
| `SyncId` / `DeleteSyncId` | int | Change tracking |

---

#### `dbo.QB_ImportedCheck`
Imported QuickBooks checks (header) — customer, AR + bank account, amount, memo. Keyed by QB `TxnId` + `SchoolCode`.

| Column | Type | Notes |
|---|---|---|
| `TxnId` | nvarchar(50) | PK (composite); QB transaction id |
| `SchoolCode` | varchar(50) | PK (composite) |
| `TxnNumber` / `TimeCreated` / `TimeModified` / `TxnDate` / `TimeZoneOffset` | mixed | QB metadata |
| `CustomerListId` / `CustomerFullName` / `ARAccountRef` / `BankAccountRef` | nvarchar | QB customer/accounts |
| `Amount` / `Memo` | mixed | — |
| `SyncId` / `DeleteSyncId` | int | Change tracking |

---

#### `dbo.QB_ImportedCheck_Expense`
Expense lines for imported QuickBooks checks — account/item refs, amount, customer ref. Child of `QB_ImportedCheck` (by `TxnId`).

| Column | Type | Notes |
|---|---|---|
| `Id` | int IDENTITY | PK |
| `TxnId` / `TxnLineId` | nvarchar | QB transaction + line |
| `Type` | nvarchar(20) | Line type |
| `AccountRefListId` / `AccoountRefFullName` | nvarchar | QB account (note "Accoount" typo in column) |
| `ItemRefListId` / `ItemRefFullName` | nvarchar | QB item |
| `CustomerRefListId` / `CustomerRefFullName` | nvarchar | QB customer |
| `Amount` / `Memo` / `SchoolCode` | mixed | — |

---

#### `dbo.QB_ImportedJournalEntry`
Imported QuickBooks journal entries (header). Keyed by QB `TxnId` + `SchoolCode`.

| Column | Type | Notes |
|---|---|---|
| `TxnId` | nvarchar(50) | PK (composite); QB transaction id |
| `SchoolCode` | varchar(50) | PK (composite) |
| `TxnNumber` / `TimeCreated` / `TimeModified` / `TxnDate` / `TimeZoneOffset` | mixed | QB metadata |
| `SyncId` / `DeleteSyncId` | int | Change tracking |

---

#### `dbo.QB_ImportedJournalEntryItems`
Journal-entry lines — account ref, entity ref, amount, debit/credit type. Child of `QB_ImportedJournalEntry` (by `TxnId`).

| Column | Type | Notes |
|---|---|---|
| `Id` | int IDENTITY | PK |
| `TxnId` / `TxnLineId` | nvarchar | QB transaction + line |
| `AccountRefListId` / `AccountRefFullName` | nvarchar | QB account |
| `EntityRefListId` / `EntityRefFullName` | nvarchar | QB entity (customer/vendor) |
| `Amount` | decimal(10,2) | — |
| `Type` | nvarchar(50) | Debit/credit |
| `Memo` / `SchoolCode` | mixed | — |

---

#### `dbo` QB (invoice/deposit/error/imported) — cross-reference summary

| Table | Scope | Direction | Notes |
|---|---|---|---|
| `QB_Invoice_PC` | Invoice+payment sync | Outbound | `QB_InvoiceID` + `QB_PaymentID` |
| `QB_Deposits` | Deposit sync | Outbound | → QB deposit |
| `QB_ErrorLog` | QB sync errors | — | By ticket/school |
| `QB_ImportedInvoices` | Imported QB invoices (header) | Inbound | QB `TxnId`; `SyncId` |
| `QB_ImportedInvoiceItems` | Imported invoice lines | Inbound | Child by `TxnId` |
| `QB_ImportedPayments` | Imported QB payments | Inbound | PK `(TxnId, SchoolCode)` |
| `QB_ImportedCheck` | Imported QB checks (header) | Inbound | PK `(TxnId, SchoolCode)` |
| `QB_ImportedCheck_Expense` | Imported check expense lines | Inbound | Child by `TxnId` |
| `QB_ImportedJournalEntry` | Imported QB journal entries | Inbound | PK `(TxnId, SchoolCode)` |
| `QB_ImportedJournalEntryItems` | Journal-entry lines | Inbound | Child by `TxnId` |

---

### `dbo` QuickBooks (QB) integration tables — final (push logs, sync infra, PW balance, QBCharges variant)

#### `dbo.QB_Items`
Outbound item (charge-category) sync log — maps a RenWeb category to a QuickBooks item, with description and amount.

| Column | Type | Notes |
|---|---|---|
| `Id` | int IDENTITY | PK |
| `TicketId` / `RequestId` | mixed | Async request |
| `QB_ItemId` | nvarchar(50) | Resulting QB item id |
| `CatTitle` / `Description` / `PaymentAmount` | mixed | Category → item |
| `Transaction_time` / `SchoolCode` | mixed | — |

---

#### `dbo.QB_Invoices`
Outbound invoice sync log (lighter than `QB_Invoice_PC`) — family, txn date, resulting `QB_InvoiceId`/`QB_PaymentId`.

| Column | Type | Notes |
|---|---|---|
| `Id` | int IDENTITY | PK |
| `TicketId` / `RequestId` | mixed | Async request |
| `QB_FamilyId` / `FamilyName` | mixed | QB family |
| `TxnDate` / `Transaction_time` | datetime | — |
| `QB_InvoiceId` / `QB_PaymentId` | nvarchar | Resulting QB ids |
| `SchoolCode` | varchar(50) | — |

---

#### `dbo.QB_Payments`
Outbound payment sync log — RenWeb `PaymentId` → QuickBooks payment, with amount (note `real`), check number, and method.

| Column | Type | Notes |
|---|---|---|
| `Id` | int IDENTITY | PK |
| `TicketId` / `RequestId` | mixed | Async request |
| `FamilyId` / `QB_FamilyId` / `FamilyName` | mixed | RenWeb + QB |
| `PaymentId` / `PaymentDate` / `PaymentAmt` (real) / `CheckNo` / `PaymentMethodId` | mixed | → `Payments` |
| `QB_PaymentId` / `QB_AcctSystemID` | nvarchar | Resulting QB ids |
| `Note` / `Transaction_time` / `SchoolCode` | mixed | — |

---

#### `dbo.QB_Journals`
Outbound journal-entry sync log — family payment posted as a QB journal entry, with resulting `QB_JournalId`.

| Column | Type | Notes |
|---|---|---|
| `Id` | int IDENTITY | PK |
| `TicketId` / `RequestId` | mixed | Async request |
| `FamilyId` / `QB_FamilyId` / `FamilyName` | mixed | — |
| `PaymentId` / `PaymentDate` / `PaymentAmt` | mixed | → `Payments` |
| `QB_JournalId` / `QB_AcctSystemID` | nvarchar | Resulting QB ids |
| `Note` / `Transaction_time` / `SchoolCode` | mixed | — |

---

### `dbo` QB sync infrastructure

#### `dbo.QB_Keys`
Tiny key table mapping an `Area` (sync area name) to an `Id`. Sync bookkeeping.

| Column | Type | Notes |
|---|---|---|
| `Id` | int | PK |
| `Area` | nvarchar(50) | Sync area name; nullable |

---

#### `dbo.QB_OngoingSyncLog`
Log of ongoing QB sync runs — ticket, time, completion flag.

| Column | Type | Notes |
|---|---|---|
| `ID` | int IDENTITY | PK |
| `TicketId` | nvarchar(50) | Sync ticket |
| `TimeCreated` | datetime | — |
| `SchoolCode` | varchar(50) | — |
| `Completed` | bit | Run completed |

---

#### `dbo.QBIDList`
Per-staff QB request payload store — holds an `ID` + large `Text` payload (the QB request/response body) per ticket. Working/scratch store for QB requests (cf. `dbo.IDList`).

| Column | Type | Notes |
|---|---|---|
| `QId` | int IDENTITY | PK |
| `StaffID` | int | Required |
| `ID` | nvarchar(50) | Required; request id |
| `Text` | nvarchar(max) | Required; payload |
| `SchoolCode` / `TicketID` | mixed | — |

---

### `dbo` QB ParentsWeb-balance reconciliation

#### `dbo.QB_PWBalance`
QuickBooks AR balance per customer/account, surfaced in ParentsWeb (the portal balance shown to families). PK is composite `(QB_CustomerId, QB_AccountId, SchoolCode)`.

| Column | Type | Notes |
|---|---|---|
| `QB_CustomerId` | nvarchar(50) | PK (composite) |
| `QB_AccountId` | nvarchar(50) | PK (composite) |
| `SchoolCode` | varchar(50) | PK (composite) |
| `QB_ARBalance` | decimal(10,2) | AR balance; nullable |

---

#### `dbo.QB_PWBalanceLog`
Change log for `QB_PWBalance` — adds `SyncId` + `Type` to the key for incremental balance history. PK is composite `(QB_CustomerId, QB_AccountId, SchoolCode, SyncId, Type)`.

| Column | Type | Notes |
|---|---|---|
| `QB_CustomerId` / `QB_AccountId` / `SchoolCode` | mixed | PK (composite) |
| `SyncId` | int | PK (composite); sync iteration |
| `Type` | nvarchar(20) | PK (composite); change type |
| `QB_ARBalance` | decimal(10,2) | Balance at this sync |

---

### `dbo` QBCharges_* (charge-batch variant)

The **`QBCharges_*`** set is a parallel charge-sync variant (likely a newer or batch-oriented charge push) — `QBCharges_Charges` (charges), `QBCharges_Invoices` (the invoices created), `QBCharges_Items` (the items/categories). Same `TicketId`/`RequestId` + `QB_*` id pattern as the main `QB_*` push tables, with a `Type` column.

#### `dbo.QBCharges_Charges`
Charge-batch push log — RenWeb `ChargeId` → QB item/invoice, with charge/cleared amounts, due date, and type.

| Column group | Type | Notes |
|---|---|---|
| `Id` | int IDENTITY | PK |
| Sync: `TicketId` / `RequestId` / `Type` | mixed | — |
| Family: `FamilyId` / `QB_FamilyId` / `FamilyName` | mixed | — |
| Charge: `ChargeId` / `ChargeDate` / `DueDate` / `ChargeAmount` / `ClearedAmount` / `CatId` / `Description` / `Title` | mixed | → `Charges` |
| QB/accounting: `QB_ItemId` / `AcctSystemId` / `AcctSystemName` / `QB_AcctSystemID` / `SchoolCode` / `Transaction_time` | mixed | — |

---

#### `dbo.QBCharges_Invoices`
Charge-batch invoice log — the QB invoices created for the batch.

| Column | Type | Notes |
|---|---|---|
| `Id` | int IDENTITY | PK |
| `TicketId` / `RequestId` / `Type` | mixed | — |
| `QB_FamilyId` / `FamilyName` | mixed | — |
| `TxnDate` / `Transaction_time` | datetime | — |
| `QB_InvoiceId` | nvarchar(50) | Resulting QB invoice |
| `SchoolCode` | varchar(50) | — |

---

#### `dbo.QBCharges_Items`
Charge-batch item log — the QB items/categories for the batch.

| Column | Type | Notes |
|---|---|---|
| `Id` | int IDENTITY | PK |
| `TicketId` / `RequestId` / `Type` | mixed | — |
| `QB_ItemId` / `CatTitle` / `Description` / `ChargeAmount` | mixed | Item/category |
| `Transaction_time` / `SchoolCode` | mixed | — |

---

### `dbo` recurring charges & re-enrollment process

#### `dbo.RecurringChargeConfig`
Recurring-charge plan header — named recurring-charge config per school, tied to an accounting system and register. Parent of `RecurringChargeItems`.

| Column | Type | Notes |
|---|---|---|
| `RecurringChargeID` | int IDENTITY | PK |
| `Name` | nvarchar(50) | Nullable |
| `SchoolCode` | varchar(50) | Nullable |
| `AccountingSystemID` | int | Nullable |
| `RegisterID` | int | Nullable |

---

#### `dbo.RecurringChargeItems`
Line items for a recurring-charge plan — item, category, amount, payment count/interval, dates, and 12 monthly installment flags. PK is composite `(RecurringChargeID, Item)`.

| Column | Type | Notes |
|---|---|---|
| `RecurringChargeID` | int | PK (composite); → `RecurringChargeConfig` |
| `Item` | int | PK (composite) |
| `Description` / `CatID` / `Amount` (real) | mixed | The charge |
| `Payments` / `Interval` | int | Schedule |
| `Date` / `DueDate` | smalldatetime | — |
| `Installment1`–`Installment12` | bit | Which months it applies |

---

#### `dbo.ReenrollProcess`
Re-enrollment process step config — the steps/webforms/messages of the online re-enrollment flow per school, with accounting/fiscal-year linkage. Drives the re-enrollment wizard (cf. `On_line_Reenrollment` / `OAStudent` enrollment).

| Column | Type | Notes |
|---|---|---|
| `ProcessID` | int IDENTITY | PK |
| `Step` | int | Step number; nullable |
| `WebformID` | int | Associated webform; nullable |
| `Type` | int | Step type; nullable |
| `Message` | nvarchar(max) | Step content; nullable |
| `Filename` / `Caption` | nvarchar(128) | Attachment |
| `NextYearGradeLevel` | bit | Use next-year grade |
| `AccountingSystemID` / `FiscalYearID` | int | Accounting linkage |
| `Finish` | bit | Final step |
| `SchoolCode` | varchar(50) | — |

---

#### `dbo` QB (final) / recurring-charge / reenroll — cross-reference summary

| Table | Scope | Direction / notes |
|---|---|---|
| `QB_Items` | Item/category sync | Outbound |
| `QB_Invoices` | Invoice sync (light) | Outbound |
| `QB_Payments` | Payment sync | Outbound |
| `QB_Journals` | Journal-entry sync | Outbound |
| `QB_Keys` | Sync area→id map | Infra |
| `QB_OngoingSyncLog` | Ongoing sync run log | Infra |
| `QBIDList` | Per-staff QB request payloads | Infra (cf. `IDList`) |
| `QB_PWBalance` | QB AR balance for portal | PK `(QB_CustomerId, QB_AccountId, SchoolCode)` |
| `QB_PWBalanceLog` | Balance change log | Adds `SyncId`, `Type` |
| `QBCharges_Charges` | Charge-batch push | Variant push set |
| `QBCharges_Invoices` | Charge-batch invoices | Variant push set |
| `QBCharges_Items` | Charge-batch items | Variant push set |
| `RecurringChargeConfig` | Recurring-charge plan header | Parent of items |
| `RecurringChargeItems` | Recurring-charge lines | PK `(RecurringChargeID, Item)`; 12 installment flags |
| `ReenrollProcess` | Re-enrollment step config | Online re-enroll wizard |

---

### `dbo.Roster` and `dbo` reporting, room, session, and schedule-backup tables

#### `dbo.Roster`
**Core student↔class enrollment + grade record.** One row per `(StudentID, ClassID)`, holding the student's enrollment in a class and every per-term/semester/exam/final grade, average, GPA, UGPA, passing flag, calc flag, citizenship/conduct mark, comment, progress-report grade/comment, transcript linkage, and per-term absent/tardy counts. This is one of the most-joined tables in the SIS (report cards, transcripts, gradebooks all read it). **Temporal table.** PK is composite `(StudentID, ClassID)`. FK to `dbo.Classes`.

> The term/semester/exam columns follow a fixed naming scheme: `TermN*` (N=1–6), `Sem1/2/3*`, `Exam1/2/3*`, `FinalGrade*`. For each period there's typically a Grade, Avg, GPA, UGPA, Passing, and Calc variant. This mirrors the weight matrix in `ClassGradeCalculation`/`CourseLevel`/`ReportCardCalculation`.

Documented by column group (~140 columns):

| Column group | Type | Notes |
|---|---|---|
| `StudentID` | int | PK (composite); indexed |
| `ClassID` | int | PK (composite); FK → `dbo.Classes` (NOCHECK); indexed |
| `Enrolled` / `Enrolled1`–`Enrolled6` | bit | Overall + per-term enrollment |
| `YearID` / `AltYearID` / `GradeLevel` | mixed | Year context |
| Term grades: `Grade1`–`Grade6` / `Citizen1`–`Citizen6` / `Com1`–`Com6` | mixed | Per-term grade, conduct mark, comment |
| Semester/exam/final: `Sem1Grade`/`Sem2Grade`/`Sem3Grade` / `Sem1Exam`/`Sem2Exam`/`Sem3Exam` / `FinalGrade` | nvarchar | — |
| Averages: `Term1Avg`–`Term6Avg` / `Sem1Avg`–`Sem3Avg` / `Exam1Avg`–`Exam3Avg` / `FinalGradeAvg` | real | Numeric averages |
| GPA: `Term1GPA`–`Term6GPA` / `Sem1GPA`–`Sem3GPA` / `Exam1GPA`–`Exam3GPA` / `FinalGradeGPA` | real | Weighted GPA |
| UGPA: `Term1UGPA`–`Term6UGPA` / `Sem1UGPA`–`Sem3UGPA` / `FinalGradeUGPA` | real | Unweighted GPA |
| Passing flags: `Term1Passing`–`Term6Passing` / `Sem1/2/3Passing` / `Exam1/2/3Passing` / `FinalPassing` | bit | — |
| Calc flags: `Term1Calc`–`Term6Calc` / `Sem*/Exam*Calc` / `FinalCalc` | bit | Whether the value was auto-calculated |
| Attendance: `Term1Absent`/`Term1Tardy` … `Term6Absent`/`Term6Tardy` | real | Per-term absence/tardy counts (cf. `AttendanceClassSummary`) |
| Progress reports: `PRG1`–`PRG6` / `PRC1`–`PRC6` | mixed | Progress-report grade + comment |
| Transcript linkage: `TranscriptIDT1`–`T6` / `TranscriptIDS1`–`S3` / `TranscriptIDFG` | int | Links roster periods to transcript rows; all indexed |
| Credit/weight: `Weight` / `CreditsOverride` / `Audit` | mixed | Transcript weighting |
| `GbkComment` | nvarchar(2000) | Gradebook comment |
| `ModifiedBy` / `ModifiedDate` | int/smalldatetime | Audit |
| `CreatedOnUTC` / `ModifiedOnUTC` / `ModifiedOnUTCmax` | datetime2 | System-versioning (temporal); `ModifiedOnUTC` indexed |

**Triggers** (RI enforcement — note the FK to `Classes` is declared `NOCHECK`, so these triggers do the work):
- `tr_dbo_Roster_Insert` (FOR INSERT): rejects inserts with no matching `Classes` or `Students` row (RAISERROR + ROLLBACK).
- `tr_dbo_Roster_Update` (FOR UPDATE): same RI check when `ClassID`/`StudentID` changes.
- `TRI_dbo_Roster_Delete` (INSTEAD OF DELETE): **blocks delete** if the student×class has rows in `Attendance`, `GbkGrades`, or `Charges`; otherwise performs the delete. Protects grade/attendance/billing integrity.

> Note the triggers reference a `Students` table/view (legacy RI target) distinct from `Person_Student`.

---

#### `dbo.RosterPredicted`
Predicted/projected grades for a student×class — semester/final grade, GPA, UGPA, average, and passing/calc flags. A "what-if" projection counterpart to `Roster` (lighter; semester + final only). PK is composite `(StudentID, ClassID)`.

| Column | Type | Notes |
|---|---|---|
| `StudentID` / `ClassID` | int | PK (composite) |
| `Sem1Grade` / `Sem2Grade` / `FinalGrade` | varchar | Projected grades |
| `Sem1GPA`/`Sem2GPA`/`FinalGradeGPA` / `Sem1UGPA`/`Sem2UGPA`/`FinalGradeUGPA` / `Sem1Avg`/`Sem2Avg`/`FinalGradeAvg` | real | Projected metrics |
| `Sem1Passing`/`Sem2Passing`/`FinalPassing` / `Sem1Calc`/`Sem2Calc`/`FinalCalc` | bit | Flags |
| `ModifiedBy` / `ModifiedDate` | int/smalldatetime | Audit |

---

#### `dbo.ReportCardCalculation`
Per-grade-level report-card grade-weight matrix — the weights for combining term grades (`s1_t1`–`s2_t6`, `f_t1`–`f_t6`), exams (`s1_e1`/`e2`, `s2_e1`/`e2`, `f_e1`/`e2`), and semester finals (`f_s1`/`f_s2`) into report-card grades. PK is composite `(GradeLevel, SchoolCode)`. (Grade-level-keyed counterpart to the class/course weight matrices in `ClassGradeCalculation`/`CourseLevel`.)

| Column | Type | Notes |
|---|---|---|
| `GradeLevel` | nvarchar(10) | PK (composite) |
| `SchoolCode` | varchar(50) | PK (composite); indexed |
| `s1_t1`–`s1_t6` / `s2_t1`–`s2_t6` / `f_t1`–`f_t6` | real | Term weights (sem1/sem2/final) |
| `s1_e1`/`s1_e2` / `s2_e1`/`s2_e2` / `f_e1`/`f_e2` | real | Exam weights |
| `f_s1` / `f_s2` | real | Final-grade semester weights |
| `DecimalPlaces` | smallint | Rounding |
| `ModifiedBy` / `ModifiedDate` | int/smalldatetime | Audit |

---

### `dbo` report-builder / favorites / session / room tables

#### `dbo.ReportDescriptions`
Saved custom report definitions — base table, selected fields, and up to three filters. The data-mining/report-builder saved-report store.

| Column | Type | Notes |
|---|---|---|
| `ReportDescriptionID` | int IDENTITY | PK |
| `ReportName` / `SchoolCode` / `Base` | varchar | Name, school, base table |
| `Fields` / `SelectedFields` | mixed | Available + chosen fields |
| `Filter1` / `Filter2` / `Filter3` | nvarchar | Filter criteria |

---

#### `dbo.ReportFavorites`
Per-staff favorited reports. PK is composite `(ReportID, StaffID)`.

| Column | Type | Notes |
|---|---|---|
| `ReportID` | int | PK (composite) |
| `StaffID` | int | PK (composite) |

---

#### `dbo.ReportHashUsedHistory`
Log of report-hash usage per UUID cookie — anti-replay/audit for shared report links (a report hash used by a browser session).

| Column | Type | Notes |
|---|---|---|
| `HistoryID` | int IDENTITY | PK |
| `ReportHash` | nvarchar(32) | The report hash |
| `UUIDCookie` | nvarchar(35) | Browser session cookie |
| `HashUsedUTC` | datetime2 | When used; default UTC now |

---

#### `dbo.ReportSchoolList`
Per-staff, per-year list of schools selected for a (multi-school) report run. FKs to `ConfigSchool` and `SchoolYear`.

| Column | Type | Notes |
|---|---|---|
| `ReportSchoolListID` | int IDENTITY | PK |
| `ConfigSchoolID` | smallint | FK → `dbo.ConfigSchool`; indexed |
| `YearID` | int | FK → `dbo.SchoolYear`; indexed |
| `StaffID` | int | The staff member |

---

#### `dbo.RenWebSessions`
Staff application (RenWeb/FACTS SIS) login sessions — UUID, staff, login/last-accessed times. The staff-side session table (cf. `ParentsWeb_Family` for the portal side).

| Column | Type | Notes |
|---|---|---|
| `ID` | int IDENTITY | PK |
| `UUID` | varchar(50) | Session id; indexed |
| `StaffID` | int | Indexed with `LoginTime` |
| `LoginTime` / `LastAccessed` | smalldatetime | `LastAccessed` indexed (for timeout) |

---

#### `dbo.ResourcesStaff`
Staff/class web resources (links) — URL resources attached to a staff member or class, with ordering and a global flag.

| Column | Type | Notes |
|---|---|---|
| `ResourceID` | int IDENTITY | PK |
| `Type` / `NAME` / `URL` | nvarchar | The resource |
| `StaffID` / `ClassID` | int | Owner |
| `ResourceOrder` / `GlobalResource` | int | Ordering / global flag |
| `ModifiedBy` / `ModifiedDate` | int/smalldatetime | Audit |

---

#### `dbo.Rooms`
Room definitions per school — name, size, multi-use/auto flags. Referenced as `RoomID` by `Classes` and schedule tables.

| Column | Type | Notes |
|---|---|---|
| `RoomID` | int IDENTITY | PK |
| `Room` | nvarchar(50) | Room name; nullable |
| `Size` | smallint | Capacity; default 0 |
| `Multiple` / `Auto` | bit | Multi-use / auto-assign; default 0 |
| `SchoolCode` | varchar(50) | Indexed |
| `ModifiedBy` / `ModifiedDate` | int/smalldatetime | Audit |

---

### `dbo` scheduling patterns & schedule-backup tables

#### `dbo.SchedulePatterns`
Schedule pattern definitions per template — pattern number, name, and group, linked to a `sched.TemplatePatternGroup`. PK is composite `(PatternNumber, TemplateID)`. (Resolves the long-pending `sched.TemplatePatternGroup` reference.)

| Column | Type | Notes |
|---|---|---|
| `PatternNumber` | int | PK (composite) |
| `TemplateID` | int | PK (composite) |
| `Name` / `PatternGroup` | nvarchar | — |
| `PatternGroupID` | int | FK → `sched.TemplatePatternGroup`; indexed |
| `SortOrder` | int | — |

---

The **ScheduleBackup** tables snapshot a school's schedule (classes, rosters, timetable) for what-if scheduling/restore. `ScheduleBackupConfig` is the named backup; the others are its class/roster/timetable snapshots.

#### `dbo.ScheduleBackupConfig`
A named schedule backup for a school year. Parent of the backup snapshot tables.

| Column | Type | Notes |
|---|---|---|
| `BackUpID` | int IDENTITY | PK |
| `YearID` | int | Nullable |
| `BackUpName` | nvarchar(128) | Nullable |

---

#### `dbo.ScheduleBackUpClasses`
Snapshot of class scheduling for a backup — staff, pattern, room, term flags, lock flags, and duration per class. PK is composite `(BackupID, ClassID)`. (Mirrors the scheduling columns of `Classes`.)

| Column | Type | Notes |
|---|---|---|
| `BackupID` | int | PK (composite); → `ScheduleBackupConfig` |
| `ClassID` | int | PK (composite) |
| `StaffID` / `AltStaffID` / `AidID` | int | Staffing |
| `Pattern` / `RoomID` / `DurationInMinutes` | mixed | Schedule slot |
| `Term1`–`Term6` | bit | Which terms; default 0 |
| `LockSchedule` / `LockEnrollment` / `LockRoom` | bit | Lock flags |
| `LinkedClassID` / `MaleFemale` | mixed | — |

---

#### `dbo.ScheduleBackupRoster`
Snapshot of class rosters for a backup. PK is composite `(BackUpID, ClassID, StudentID)`.

| Column | Type | Notes |
|---|---|---|
| `BackUpID` | int | PK (composite) |
| `ClassID` | int | PK (composite) |
| `StudentID` | int | PK (composite) |

---

#### `dbo.ScheduleBackupTimeTable`
Snapshot of class timetable slots for a backup — day/begin period and room per class. Unique on `(BackUpID, ClassID, Day, Begin)`.

| Column | Type | Notes |
|---|---|---|
| `ScheduleBackupTimeTableId` | int IDENTITY | PK |
| `BackUpID` / `ClassID` | int | The backup + class |
| `Day` / `Begin` | int | Day in cycle + period |
| `RoomID` | int | Room; nullable |

---

#### `dbo` Roster / reporting / room / session / schedule-backup — cross-reference summary

| Table | Scope | Key FK targets / notes |
|---|---|---|
| `Roster` | **Student↔class enrollment + grades** | **Core**; temporal; PK `(StudentID, ClassID)`; → `Classes`; 3 RI triggers; transcript linkage |
| `RosterPredicted` | Projected grades | PK `(StudentID, ClassID)` |
| `ReportCardCalculation` | Per-grade-level RC weight matrix | PK `(GradeLevel, SchoolCode)`; cf. `ClassGradeCalculation` |
| `ReportDescriptions` | Saved report definitions | Report builder |
| `ReportFavorites` | Per-staff report favorites | PK `(ReportID, StaffID)` |
| `ReportHashUsedHistory` | Report-link usage audit | By UUID cookie |
| `ReportSchoolList` | Per-staff multi-school report scope | `ConfigSchool`, `SchoolYear` |
| `RenWebSessions` | Staff app login sessions | Staff-side (cf. `ParentsWeb_Family`) |
| `ResourcesStaff` | Staff/class web links | By staff/class |
| `Rooms` | Room definitions | `RoomID` referenced by `Classes` |
| `SchedulePatterns` | Schedule patterns | → `sched.TemplatePatternGroup` |
| `ScheduleBackupConfig` | Named schedule backup | Parent of snapshots |
| `ScheduleBackUpClasses` | Backup class snapshot | PK `(BackupID, ClassID)` |
| `ScheduleBackupRoster` | Backup roster snapshot | PK `(BackUpID, ClassID, StudentID)` |
| `ScheduleBackupTimeTable` | Backup timetable snapshot | Unique `(BackUpID, ClassID, Day, Begin)` |

---

### `dbo.SchoolYear`, `dbo.SchoolTerm`, schedule-template subsystem, and the security-group model

#### `dbo.SchoolYear`
**The academic-year record** — one of the most-referenced lookups in the SIS (`YearID` appears throughout: Roster, Classes, Portfolio, ReportSchoolList, etc.). Holds the year's first/last day, label, school, summer-school/template flags, and FACTS term code. **Temporal table.** PK `YearID`.

| Column | Type | Notes |
|---|---|---|
| `YearID` | int IDENTITY | PK; the universal year id |
| `SchoolYear` | nvarchar(50) | Label (e.g. "2025-2026") |
| `FirstDay` / `LastDay` | datetime | Year bounds |
| `SchoolID` / `SchoolCode` | mixed | School; both indexed |
| `SummerSchool` | bit | Summer-school year |
| `IsTemplate` | bit | Template year (for rollover); default 0 |
| `BlockAcademicYear` | bit | Block scheduling flag; default 0 |
| `OARequestInfoEnabled` | bit | Inquiry funnel enabled; default 1 |
| `FACTSTermCode` | nvarchar(50) | FACTS integration term code |
| `ModifiedBy` / `ModifiedDate` / `CreatedOnUTC` | mixed | Audit |
| `ModifiedOnUTC` / `ModifiedOnUTCmax` | datetime2 | System-versioning (temporal); `ModifiedOnUTC` indexed |

**Trigger** `SchoolYear_DTrig` (FOR DELETE): **cascades deletes to `SchoolTerm`** (deletes all terms for the year). (The cascade DELETE is duplicated in the trigger body — harmless but redundant.)

---

#### `dbo.SchoolTerm`
**The grading-term/period record** within a year — first/last day, semester membership, and FACTS-style term identity. The `TermID`/`YearID` pair is the period context used by Roster grades, attendance, gradebook, etc. PK is composite `(TermID, YearID)`. FK to `SchoolYear` (NOCHECK + trigger-enforced).

| Column | Type | Notes |
|---|---|---|
| `TermID` | smallint | PK (composite); default 0 |
| `YearID` | int | PK (composite); → `SchoolYear`; indexed |
| `SchoolTermID` | int IDENTITY | Unique surrogate |
| `Name` | nvarchar(50) | Term label |
| `FirstDay` / `LastDay` | datetime | Term bounds |
| `Semester1` / `Semester2` / `SemesterID` | mixed | Semester membership |
| `SchoolCode` | varchar(50) | Indexed |
| `ModifiedBy` / `ModifiedDate` | int/smalldatetime | Audit |

**Triggers** `SchoolTerm_ITrig` (INSERT) / `SchoolTerm_UTrig` (UPDATE): manual RI — reject if no matching `SchoolYear` row (RAISERROR + ROLLBACK). (The FK is `NOCHECK`, so these enforce it. Note two identical `SchoolTerm_FK00`/`FK01` constraints, both NOCHECK — redundant.)

> **`SchoolYear` + `SchoolTerm` resolve the most pervasive pending references in the catalog.** Nearly every academic table's `YearID`/`TermID` now points at a documented table. The delete cascade (year→terms) and the RI triggers (term requires year) define the year/term lifecycle.

---

### `dbo` schedule-template subsystem

The **ScheduleTemplate** family defines reusable master-schedule grid templates (rows×cols time grid) used by the scheduling/auto-scheduler. `ScheduleTemplate` is the template header; the `*TimeTable` tables define the grid cells; `*Staff` holds per-staff availability; the `SchedulePatterns*` tables (documented earlier) define meeting patterns on the grid; `ScheduleUserDefinedList*` adds course grouping for auto-scheduling.

#### `dbo.ScheduleTemplate`
Master-schedule template header — named grid (rows×cols) per year, with level applicability and lock. FK `CreatedByID` → `Person`. Unique on `(YearID, TemplateName)`.

| Column | Type | Notes |
|---|---|---|
| `TemplateID` | int IDENTITY | PK |
| `YearID` | int | The year |
| `TemplateName` | nvarchar(50) | Unique within year |
| `Preschool` / `Elementary` / `MiddleSchool` / `HighSchool` | bit | Level applicability |
| `Rows` / `Cols` | int | Grid dimensions |
| `Locked` | bit | Default 0 |
| `CreatedByID` | int | FK → `Person` (SET NULL on delete) |

---

#### `dbo.ScheduleTemplateTimeTable`
Grid cells of a template — row/col position with label, time text, and begin/end local times. Unique on `(TemplateID, Row, Col)`.

| Column | Type | Notes |
|---|---|---|
| `ScheduleTemplateTimeTableId` | int IDENTITY | PK |
| `TemplateID` | int | The template |
| `Row` / `Col` | int | Grid position |
| `TemplateText` / `TemplateTime` | nvarchar | Cell label/time |
| `BeginTimeLocal` / `EndTimeLocal` | time(2) | Period times |

---

#### `dbo.ScheduleTemplateStaff`
Per-staff schedule-template availability/blocks — text per staff×day×period. PK is composite `(StaffID, Day, Period, TemplateID)`.

| Column | Type | Notes |
|---|---|---|
| `StaffID` / `Day` / `Period` / `TemplateID` | int | PK (composite) |
| `TemplateText` | nvarchar(50) | Cell text |
| `ScheduleBlock` | bit | Blocked slot |
| `ModifiedBy` / `ModifiedDate` | int/smalldatetime | Audit |

---

#### `dbo.SchedulePatternsTimeTable`
Grid cells occupied by a schedule pattern — maps a `(PatternNumber, TemplateID)` pattern (from `SchedulePatterns`) to the grid row/col cells it uses. Unique on `(TemplateID, PatternNumber, Row, Col)`.

| Column | Type | Notes |
|---|---|---|
| `SchedulePatternsTimeTableId` | int IDENTITY | PK |
| `PatternNumber` / `TemplateID` | int | → `SchedulePatterns` |
| `Row` / `Col` | int | Grid cell used |

---

#### `dbo.ScheduleUserDefinedListName`
Named user-defined course lists per template — grouping buckets for auto-scheduling, with optional scheduling-priority flag. Unique on `(Name, TemplateID)`.

| Column | Type | Notes |
|---|---|---|
| `UDID` | int IDENTITY | PK |
| `Name` | nvarchar(50) | List name |
| `TemplateID` | int | The template |
| `UseAutoSchedulingPriority` | bit | Default 0 |

---

#### `dbo.ScheduleUserDefinedList`
Membership of courses in a user-defined list. PK is composite `(CourseID, UDID)`.

| Column | Type | Notes |
|---|---|---|
| `CourseID` | int | PK (composite) |
| `UDID` | int | PK (composite); → `ScheduleUserDefinedListName` |
| `SortOrder` | int | — |

---

### `dbo` security / permissions model

The **security** tables implement role-based access. `SecurityGroups` is the group definition (with per-module access levels as smallint columns + hierarchy via `ParentGroupID`); `SecurityGroupMembership` assigns staff to groups; `SecurityGroupRights` holds fine-grained per-item view/modify rights; `Security_Reports`/`Security_ReportCategory` control report visibility per group.

#### `dbo.SecurityGroups`
Security-group (role) definition — a named group with a per-module access level (smallint: typically 0=none … higher=more) for each SIS module, plus hierarchy and district/school-managed flags. PK `GroupID`; self-FK `ParentGroupID` → `SecurityGroups`.

| Column group | Type | Notes |
|---|---|---|
| `GroupID` | int IDENTITY | PK |
| `Name` / `Description` / `SchoolCode` | mixed | Identity; `SchoolCode` indexed |
| Module access (smallint, default 0): `Accounting` / `Attendance` / `Classes` / `ClassGroup` / `Conference` / `Courses` / `Discipline` / `EnrollmentD` / `Family` / `Medical` / `ReportCard` / `Scheduling` / `Security` / `Staff` / `Student` / `SystemConfiguration` / `SystemFunctions` / `Transcripts` / `GradeBook` / `Donor` / `PrintAdmin` / `PrintCreateAReport` / `Admissions` / `Library` / `CashRegister` | smallint | One access-level column per module |
| Hierarchy: `ParentGroupID` | int | Self-FK → `SecurityGroups`; indexed |
| Flags: `PortalConversionType` / `DistrictOfficeSecurityGroup` / `IsSchoolManagedSecurityGroup` | mixed | — |
| `ModifiedBy` / `ModifiedDate` | int/smalldatetime | Audit |

---

#### `dbo.SecurityGroupMembership`
Assigns a staff member to a security group. PK is composite `(StaffID, GroupID)`.

| Column | Type | Notes |
|---|---|---|
| `StaffID` | int | PK (composite); default 0; indexed |
| `GroupID` | int | PK (composite); default 0; indexed |
| `ModifiedBy` / `ModifiedDate` | int/smalldatetime | Audit |

---

#### `dbo.SecurityGroupRights`
Fine-grained per-item rights for a group — a named `SecurityItem` with view/modify bits (more granular than the module-level columns on `SecurityGroups`). PK is composite `(GroupID, SecurityItem)`.

| Column | Type | Notes |
|---|---|---|
| `GroupID` | int | PK (composite) |
| `SecurityItem` | nvarchar(50) | PK (composite); the named right |
| `View` / `Modify` | bit | Permissions |
| `SecurityID` | int | Item id; indexed with GroupID |
| `ModifiedBy` / `ModifiedDate` | int/smalldatetime | Audit |

---

#### `dbo.Security_Reports`
Per-group report visibility — view/block a specific report. PK is composite `(SecurityGroupID, ReportID)`.

| Column | Type | Notes |
|---|---|---|
| `SecurityGroupID` | int | PK (composite); indexed |
| `ReportID` | int | PK (composite); indexed |
| `ViewReport` / `BlockReport` | bit | Permissions |

---

#### `dbo.Security_ReportCategory`
Per-group report-category access. PK is composite `(SecurityGroupID, CategoryID)`.

| Column | Type | Notes |
|---|---|---|
| `SecurityGroupID` | int | PK (composite); indexed |
| `CategoryID` | int | PK (composite); indexed |

---

### `dbo` misc — SIS export & SEOA program characteristic

#### `dbo.SIS_Export_File`
SIS export-file definition — a named export file with a delimiter. Header for SIS data-export configuration.

| Column | Type | Notes |
|---|---|---|
| `FileID` | int IDENTITY | PK |
| `FileName` | nvarchar(255) | Export file name |
| `Delimiter` | int | Delimiter code |

---

#### `dbo.SEOAProgramParticipationProgramCharacteristic`
Student program-participation program characteristics (Ed-Fi-style; "SEOA" = state extension) — links a person to a program-characteristic + program-type descriptor pair. FK → `Person`. Unique on `(PersonID, ProgramCharacteristicDescriptorID, ProgramTypeDescriptorID)`.

| Column | Type | Notes |
|---|---|---|
| `StudentProgramParticipationProgramCharacteristicID` | int IDENTITY | PK |
| `PersonID` | int | FK → `Person` |
| `ProgramCharacteristicDescriptorID` | uniqueidentifier | Required |
| `ProgramTypeDescriptorID` | uniqueidentifier | Required |

---

#### `dbo` SchoolYear / SchoolTerm / schedule-template / security / misc — cross-reference summary

| Table | Scope | Key FK targets / notes |
|---|---|---|
| `SchoolYear` | **Academic-year record** | **Core**; temporal; PK `YearID`; delete cascades to `SchoolTerm` |
| `SchoolTerm` | **Grading-term record** | **Core**; PK `(TermID, YearID)`; → `SchoolYear` (trigger RI) |
| `ScheduleTemplate` | Master-schedule template header | → `Person`; unique `(YearID, TemplateName)` |
| `ScheduleTemplateTimeTable` | Template grid cells | Unique `(TemplateID, Row, Col)` |
| `ScheduleTemplateStaff` | Per-staff template availability | PK `(StaffID, Day, Period, TemplateID)` |
| `SchedulePatternsTimeTable` | Pattern→grid-cell mapping | → `SchedulePatterns` |
| `ScheduleUserDefinedListName` | Named course lists (auto-sched) | Unique `(Name, TemplateID)` |
| `ScheduleUserDefinedList` | Course→list membership | PK `(CourseID, UDID)` |
| `SecurityGroups` | Security-group (role) def | Self-FK hierarchy; per-module access levels |
| `SecurityGroupMembership` | Staff→group assignment | PK `(StaffID, GroupID)` |
| `SecurityGroupRights` | Per-item view/modify rights | PK `(GroupID, SecurityItem)` |
| `Security_Reports` | Per-group report visibility | PK `(SecurityGroupID, ReportID)` |
| `Security_ReportCategory` | Per-group report-category access | PK `(SecurityGroupID, CategoryID)` |
| `SIS_Export_File` | SIS export-file def | — |
| `SEOAProgramParticipationProgramCharacteristic` | Student program characteristics | → `Person`; Ed-Fi descriptors |

---

### `dbo` SIS-export subsystem, skill-set (SS) grading, special needs, and staff education/certification/attendance

### `dbo` SIS-export subsystem (continued)

The **SIS_Export_*** tables define configurable flat-file student-data exports (for state reporting / third-party SIS handoff). `SIS_Export_File` (header, documented earlier) → `SIS_Export_File_Record` (which records, ordered) → `SIS_Export_Record` (record definitions) → `SIS_Export_Record_Field` (field layout per record) → `SIS_Export_Translation` (value mapping); `SIS_Export_Members` scopes which entities are included.

#### `dbo.SIS_Export_Record`
Record-type definition within the export framework — a named record with type and custom flag.

| Column | Type | Notes |
|---|---|---|
| `RecordID` | int IDENTITY | PK |
| `Type` / `RecordName` / `Custom` | nvarchar | Record identity |

---

#### `dbo.SIS_Export_File_Record`
Maps records to a file with ordering. PK is composite `(FileID, RecordID, Order)`.

| Column | Type | Notes |
|---|---|---|
| `FileID` | int | PK (composite); → `SIS_Export_File` |
| `RecordID` | int | PK (composite); → `SIS_Export_Record` |
| `Order` | int | PK (composite); position |

---

#### `dbo.SIS_Export_Record_Field`
Field layout for an export record — field name/type/number/length, fixed-width begin/end positions, source `DatabaseTable`/`DatabaseField`, mask, custom extract expression, and translation/user-defined linkage. The detailed export field-mapping table.

| Column group | Type | Notes |
|---|---|---|
| `FieldID` | int IDENTITY | PK |
| `RecordID` | int | → `SIS_Export_Record` |
| Layout: `FieldName` / `FieldType` / `FieldNumber` / `FieldLength` / `BeginField` / `EndField` / `Mask` | mixed | Position/format |
| Source: `DatabaseTable` / `DatabaseField` / `CustomExtract` / `Data` | nvarchar | Where the value comes from |
| Translation: `TranslationRequired` / `TranslationType` | mixed | → `SIS_Export_Translation` |
| User-defined: `UDType` / `UDCategory` / `UDField` | mixed | UD-field source |

---

#### `dbo.SIS_Export_Translation`
Value-translation map for exports — translates a `From` value to a `To` value within a `Type`. **Temporal table.** PK is composite `(Type, From, To)`.

| Column | Type | Notes |
|---|---|---|
| `Type` | nvarchar(50) | PK (composite); translation set |
| `From` | nvarchar(200) | PK (composite); source value |
| `To` | nvarchar(200) | PK (composite); mapped value |
| `CreatedOnUTC` / `ModifiedOnUTC` / `ModifiedOnUTCmax` | datetime2 | System-versioning (temporal) |

---

#### `dbo.SIS_Export_Members`
Scopes which members (entities) are included in an export file. PK is composite `(ID, MemberType, FileID)`.

| Column | Type | Notes |
|---|---|---|
| `ID` | int | PK (composite); member id |
| `MemberType` | nvarchar(50) | PK (composite); entity type |
| `FileID` | int | PK (composite); → `SIS_Export_File` |

---

### `dbo` skill-set (SS) — standards-based grading (legacy)

The **SS_*** tables are the legacy skill-set / standards-based grading model (predecessor to the `aca` standards-based-grading schema). Structure: `SS_Subjects` (subject within a course) → `SS_Skills` (skills within a subject, with rubrics) → `SS_Grades` (per-student per-skill marks) and `SS_Assignment` (links gradebook assessments to skills).

#### `dbo.SS_Subjects`
Subjects within a course for skill-set grading.

| Column | Type | Notes |
|---|---|---|
| `SubjectID` | int IDENTITY | PK |
| `CourseID` | int | The course; default 0 |
| `Subject` | nvarchar(500) | Subject name |
| `SubjectOrder` | smallint | Ordering |
| `ModifiedBy` / `ModifiedDate` | int/smalldatetime | Audit |

---

#### `dbo.SS_Skills`
Skills within a subject — the gradable standards, with up to 5 rubric texts, grade type, and a state-standard id.

| Column | Type | Notes |
|---|---|---|
| `SkillID` | int IDENTITY | PK |
| `SubjectID` | int | → `SS_Subjects`; default 0 |
| `Skill` | nvarchar(1000) | Skill text |
| `SkillOrder` / `GradeType` / `SingleGrade` | mixed | Ordering / grade style |
| `Rubric1`–`Rubric5` | nvarchar(max) | Rubric descriptions |
| `StateID` | nvarchar(64) | State-standard linkage |
| `ModifiedBy` / `ModifiedDate` | int/smalldatetime | Audit |

---

#### `dbo.SS_Grades`
Per-student, per-skill marks — up to 6 period grades (`G1`–`G6`) and 6 comments (`Com1`–`Com6`), per class. PK is composite `(StudentID, SkillID, ClassID1)`. (The standards-based counterpart to `Roster` term grades.)

| Column | Type | Notes |
|---|---|---|
| `StudentID` / `SkillID` / `ClassID1` | int | PK (composite) |
| `G1`–`G6` | nvarchar(15) | Per-period skill marks |
| `Com1`–`Com6` | nvarchar(max) | Per-period comments |
| `ModifiedBy` / `ModifiedDate` | int/smalldatetime | Audit |

**Trigger** `SS_GradesIUtrig` (INSERT, UPDATE, DELETE): writes a detailed audit trail to `ActivityLog_SSGrades` — on delete logs a "Delete Full SkillGrade" row; on each changed `G1`–`G6`/`Com1`–`Com6` logs the from/to values (truncated to 50 chars). Field-level change history for skill grades.

---

#### `dbo.SS_Assignment`
Links a gradebook assessment/assignment to a skill — so a gradebook score can feed a standards-based skill. PK is composite `(ClassID, AssessmentID, AssignmentID, SkillID)`.

| Column | Type | Notes |
|---|---|---|
| `ClassID` / `AssessmentID` / `AssignmentID` / `SkillID` | int | PK (composite) |
| `ModifiedBy` / `ModifiedDate` | int/smalldatetime | Audit |

---

#### `dbo.SkillSet_CourseObjectives`
Links a skill to a course objective. PK is composite `(SkillID, ObjectiveID)`. (Bridges `SS_Skills` to `CourseObjectives`.)

| Column | Type | Notes |
|---|---|---|
| `SkillID` | int | PK (composite); → `SS_Skills` |
| `ObjectiveID` | int | PK (composite); → `CourseObjectives` |

---

### `dbo` special needs

#### `dbo.SpecialNeeds`
Special-needs flags per student — tutoring, behavior management, ADD/ADHD, gifted/talented (GT), special ed, with per-flag notes. PK `StudentID`.

> **Contains sensitive student data** (disability/special-ed status). Treat as confidential.

| Column | Type | Notes |
|---|---|---|
| `StudentID` | int | PK; default 0 |
| `Tutoring` / `TutoringNote` | bit/nvarchar | — |
| `BehaviorMgt` / `BehaviorMgtNote` | bit/nvarchar | — |
| `ADD/ADHD` / `ADDNote` | bit/nvarchar | Note literal column name includes the slash |
| `GT` / `GTNote` | bit/nvarchar | Gifted/talented |
| `SpecialED` / `SpecialEDNote` | bit/nvarchar | — |
| `OtherNeeds` | nvarchar(255) | — |
| `ModifiedBy` / `ModifiedDate` | int/smalldatetime | Audit |

---

#### `dbo.SpecialNeedsNotes`
Free-text special-needs note log per student. PK `StudentID` (one note row per student).

> **Contains sensitive student data.**

| Column | Type | Notes |
|---|---|---|
| `StudentID` | int | PK |
| `Date` / `Staff` / `Note` | mixed | The note |
| `upsize_ts` | timestamp | Row version (legacy Access upsize artifact) |
| `ModifiedBy` / `ModifiedDate` | int/smalldatetime | Audit |

---

### `dbo` staff education / certification / attendance

#### `dbo.StaffEducation`
Continuing-education / professional-development records per staff — description, hours/units/CEU, date, certification flag, and 5 user-defined fields.

| Column | Type | Notes |
|---|---|---|
| `ID` | int IDENTITY | PK |
| `StaffID` | int | The staff member |
| `Description` / `Hours` / `Units` / `CEU` | mixed | The activity |
| `Date` / `Certification` | mixed | — |
| `UD1`–`UD5` | nvarchar(50) | User-defined |
| `ModifiedBy` / `ModifiedDate` | int/smalldatetime | Audit |

---

#### `dbo.StaffCertification`
Staff certifications/licenses — certification name, level, type, received/expires dates, note, and 5 user-defined fields.

| Column | Type | Notes |
|---|---|---|
| `CertificationID` | int IDENTITY | PK |
| `StaffID` | int | The staff member |
| `Certification` / `CertificationLevel` / `CertificationType` | nvarchar | The credential |
| `Date` / `DateReceived` / `DateExpires` | mixed | Dates (`Date` is text) |
| `Note` | nvarchar(255) | — |
| `UD1`–`UD5` | nvarchar(50) | User-defined |
| `ModifiedBy` / `ModifiedDate` | int/smalldatetime | Audit |

---

#### `dbo.StaffAttendance`
Staff attendance records — code + comment per staff per date. PK is composite `(StaffID, AttendanceDate)`.

| Column | Type | Notes |
|---|---|---|
| `StaffID` | int | PK (composite) |
| `AttendanceDate` | smalldatetime | PK (composite) |
| `AttendanceCode` | nvarchar(50) | Attendance code |
| `Comment` | nvarchar(250) | — |

**Trigger** `TR_dbo_StaffAttendance_InsertUpdate` (AFTER INSERT, UPDATE): keeps `dbo.StaffSubstitutes.Reason` in sync with the attendance `Comment` for the same staff+date; guards against recursion via `trigger_nestlevel() < 2` (StaffSubstitutes has a reciprocal trigger).

---

#### `dbo` SIS-export / SS-grading / special-needs / staff-ed — cross-reference summary

| Table | Scope | Key FK targets / notes |
|---|---|---|
| `SIS_Export_Record` | Export record-type def | Export framework |
| `SIS_Export_File_Record` | File→record ordering | PK `(FileID, RecordID, Order)` |
| `SIS_Export_Record_Field` | Export field layout | Source table/field, translation |
| `SIS_Export_Translation` | Export value map | **Temporal**; PK `(Type, From, To)` |
| `SIS_Export_Members` | Export entity scoping | PK `(ID, MemberType, FileID)` |
| `SS_Subjects` | Skill-set subjects | Legacy standards-based grading |
| `SS_Skills` | Skill-set skills + rubrics | → `SS_Subjects`; `StateID` |
| `SS_Grades` | Per-student skill marks | PK `(StudentID, SkillID, ClassID1)`; audit trigger → `ActivityLog_SSGrades` |
| `SS_Assignment` | Gradebook→skill link | PK `(ClassID, AssessmentID, AssignmentID, SkillID)` |
| `SkillSet_CourseObjectives` | Skill→objective link | → `SS_Skills`, `CourseObjectives` |
| `SpecialNeeds` | Special-needs flags | **Sensitive**; PK `StudentID` |
| `SpecialNeedsNotes` | Special-needs note log | **Sensitive**; PK `StudentID` |
| `StaffEducation` | Staff PD/CEU records | Per staff |
| `StaffCertification` | Staff certifications | Per staff |
| `StaffAttendance` | Staff attendance | PK `(StaffID, AttendanceDate)`; syncs `StaffSubstitutes` |

---

### `dbo` StudentApplication, remaining staff tables, disability (Ed-Fi), and student alert/activity/honors/allergies

#### `dbo.StudentApplication`
**Admissions application record** for an existing-student (the "live SIS" admissions/enrollment-tracking record, distinct from the OA online-application subsystem). Per student×year: status, milestone dates (application/tested/interview/accepted), tracking, financial aid, and the enrollment-packet + enrollment-fee lifecycle. **Temporal table.** PK `ApplicationID`.

| Column group | Type | Notes |
|---|---|---|
| `ApplicationID` | int IDENTITY | PK |
| `StudentID` / `YearID` / `GradeLevel` | mixed | Who/when |
| Status: `ApplicationStatus` / `UDStatus` / `CancelReason` / `PriorityLevel` | mixed | — |
| Milestone dates: `ApplicationDate` / `TestedDate` / `InterviewDate` / `AcceptedDate` | datetime | Funnel |
| Referral: `ReferredBy` / `ReferredByDetails` | nvarchar | — |
| Financial: `FinancialAid` / `EnrollmentFeeWaived` / `EnrollmentFeePaidDate` / `EnrollmentFeePaidNote` / `BypassTuitionContract` | mixed | — |
| Enrollment packet: `EnrollmentPacketSent` / `EnrollmentPacketStarted` / `EnrollmentPacketSubmitted` / `UnfinishedEmailSent` | smalldatetime | Packet lifecycle |
| Integration: `OEBypassFACTS` / `TrackingSystemID` | mixed | FACTS bypass; → `TrackingConfig` |
| `Notes` | nvarchar(max) | Synced to `rw.PersonNote` by triggers |
| `ModifiedBy` / `ModifiedDate` / `CreatedOnUTC` | mixed | Audit |
| `ModifiedOnUTC` / `ModifiedOnUTCmax` | datetime2 | System-versioning (temporal); indexed |

**Triggers** (Insert/Update/Delete) maintain `rw.PersonNote` (NoteType 0, desktop note) from the application `Notes` field — Insert/Update upsert the note (clearing `IsDesktopNote` on prior notes, inserting/updating the current one), Delete resets `IsDesktopNote = 0`. Same materialize-to-`rw.PersonNote` pattern as `Person.MedicalNote`.

---

#### `dbo.StudentApplicationEmailSent`
Log of admissions emails sent for an application — type, date, address. FK → `StudentApplication`.

| Column | Type | Notes |
|---|---|---|
| `EmailSentID` | int IDENTITY | PK |
| `ApplicationID` | int | FK → `StudentApplication` |
| `EmailType` | nvarchar(50) | Indexed |
| `EmailDate` / `EmailAddress` | mixed | — |

---

### `dbo` Ed-Fi disability tables

These extend `prsn.StudentEducationOrganizationAssociation` (the "SEOA" Ed-Fi association) with disability detail. (Cf. `SEOAProgramParticipationProgramCharacteristic` documented earlier.)

> **Contains sensitive student data** (disability diagnosis/designation).

#### `dbo.StudentEducationOrganizationAssociationDisability`
A disability on a student's education-org association — disability descriptor, determination source, diagnosis text, and order. FK → `prsn.StudentEducationOrganizationAssociation`. Unique on `(StudentEducationOrganizationAssociationId, DisabilityDescriptorID)`.

| Column | Type | Notes |
|---|---|---|
| `SEOADisabilityID` | int IDENTITY | PK |
| `StudentEducationOrganizationAssociationId` | int | FK → `prsn.StudentEducationOrganizationAssociation` |
| `DisabilityDescriptorID` | uniqueidentifier | The disability |
| `DisabilityDeterminationSourceTypeDescriptorID` | uniqueidentifier | Source; nullable |
| `DisabilityDiagnosis` | nvarchar(80) | Free-text diagnosis |
| `OrderOfDisability` | int | Ordering |

---

#### `dbo.StudentEducationOrganizationAssociationDisabilityDesignation`
Designations on a disability (child of the above) — e.g. 504/IDEA designation. FK → `StudentEducationOrganizationAssociationDisability`. Unique on `(DisabilityDesignationDescriptorID, SEOADisabilityID)`.

| Column | Type | Notes |
|---|---|---|
| `SEOADisabilityDesignationID` | int IDENTITY | PK |
| `SEOADisabilityID` | int | FK → `…AssociationDisability` |
| `DisabilityDesignationDescriptorID` | uniqueidentifier | The designation |

---

### `dbo` remaining staff tables

#### `dbo.StaffLogin`
Staff login event log — date, faculty-web flag, login type per staff.

| Column | Type | Notes |
|---|---|---|
| `AutoNumber` | int IDENTITY | PK |
| `StaffID` | int | — |
| `Date` | smalldatetime | Indexed |
| `FacultyWeb` / `logintype` | mixed | Login channel/type |

---

#### `dbo.StaffSalary`
Staff salary history — start date, salary/hourly flags, amount, note.

> **Contains sensitive compensation data.**

| Column | Type | Notes |
|---|---|---|
| `SalaryID` | int IDENTITY | PK |
| `staffID` | int | The staff member |
| `StartDate` / `Salary` / `Hourly` / `amount` | mixed | `amount` decimal(14,4) |
| `note` | nvarchar(255) | — |

---

#### `dbo.StaffSchools`
Staff↔school assignments (multi-school access) — with super-user flag per school.

| Column | Type | Notes |
|---|---|---|
| `AutoNum` | int IDENTITY | PK |
| `StaffID` | int | The staff member |
| `SchoolCode` | varchar(50) | The school |
| `SuperUser` | bit | Super-user at this school |
| `ModifiedBy` / `ModifiedDate` | int/smalldatetime | Audit |

**Trigger** `TR_dbo_StaffSchools_SyncTenantRelationship` (AFTER INSERT, UPDATE): on `SchoolCode` change, posts a Passport tenant-relationship sync via `dbo.Passport_UpdateTenantRelationship`; **skipped on Linux/container DBs**. (Staff-side parallel to `Person_Student`'s tenant-sync trigger.)

---

#### `dbo.StaffSubstitutes`
Substitute-teacher assignments — staff being substituted, class, date, reason, and substitute. (Resolves the `StaffSubstitutes` reference from the `StaffAttendance` trigger last batch.)

| Column | Type | Notes |
|---|---|---|
| `ID` | int IDENTITY | PK |
| `StaffID` / `ClassID` / `Date` | mixed | Who/what/when |
| `SubstituteID` | int | The substitute |
| `Reason` | nvarchar(250) | — |
| `ModifiedBy` / `ModifiedDate` | int/smalldatetime | Audit |

**Trigger** `TR_dbo_StaffSubstitutes_InsertUpdate` (AFTER INSERT, UPDATE): inserts/updates a matching `StaffAttendance` row (code 'A', comment = reason) for the staff+date. Guarded by `trigger_nestlevel() < 2` to prevent recursion with `StaffAttendance`'s reciprocal trigger. **This is the reciprocal half** of the StaffAttendance↔StaffSubstitutes sync pair noted last batch.

---

#### `dbo.StandardsPerfStandard`
Performance-standard definitions under a standards strand — title, description, sort order. (Part of the academic-standards model; `StrandID` → standards strand.) Note a self-referential FK on `PerfID` (likely a schema artifact; a no-op self-FK).

| Column | Type | Notes |
|---|---|---|
| `PerfID` | int IDENTITY | PK; self-FK (no-op) |
| `StrandID` | smallint | The strand; default 0 |
| `PerfTitle` | nvarchar(50) | Required |
| `PerfDesc` | nvarchar(max) | — |
| `SortOrder` | smallint | Default 0 |

---

### `dbo` student alert / activity / honors / allergies

#### `dbo.StudentAlert`
Student alert definitions — a titled alert with description, per student. (cf. the staff-facing alert display in `StudentAlertApplication`.)

| Column | Type | Notes |
|---|---|---|
| `AlertID` | int IDENTITY | PK |
| `StudentID` | int | The student |
| `Title` / `Description` | nvarchar | The alert |
| `Active` | bit | Default 1 |

---

#### `dbo.StudentAlertApplication`
How an alert displays in a given application/module — visual/beep/popup behavior. PK is composite `(AlertID, ApplicationID)`. (Here "Application" = an app/module screen, not an admissions application.)

| Column | Type | Notes |
|---|---|---|
| `AlertID` | int | PK (composite); → `StudentAlert` |
| `ApplicationID` | int | PK (composite); the module/screen |
| `Visual` / `Beep` / `PopUp` / `PopUpAlways` | bit | Display behavior |

---

#### `dbo.StudentAlertRead`
Tracks which staff have read which student alerts. PK is composite `(AlertID, StudentID, StaffID)`.

| Column | Type | Notes |
|---|---|---|
| `AlertID` / `StudentID` / `StaffID` | int | PK (composite) |

---

#### `dbo.StudentActivity`
Student↔activity participation (extracurriculars). PK is composite `(StudentID, ActivityID)`.

| Column | Type | Notes |
|---|---|---|
| `StudentID` | int | PK (composite); default 0 |
| `ActivityID` | int | PK (composite); → `Activity`; default 0 |
| `Note` | nvarchar(50) | — |
| `ModifiedBy` / `ModifiedDate` | int/smalldatetime | Audit |

---

#### `dbo.StudentHonors`
Student honors/awards per term/year. PK `StudentHonorID`.

| Column | Type | Notes |
|---|---|---|
| `StudentHonorID` | int IDENTITY | PK |
| `StudentID` / `YearID` / `Term` | mixed | Context; indexed |
| `HonorID` / `Honor` | mixed | The honor; `HonorID` indexed |
| `ModifiedBy` / `ModifiedDate` | int/smalldatetime | Audit |

---

#### `dbo.StudentAllergies`
Student allergy records — allergy, comment, and medical-header display options.

> **Contains health PII.**

| Column | Type | Notes |
|---|---|---|
| `AllergyID` | int IDENTITY | PK |
| `StudentID` | int | The student; default 0 |
| `Allergy` / `Comment` | nvarchar(255) | — |
| `DisplayInMedicalHeader` | bit | Show in medical header; default 0 |
| `DisplayOrder` | tinyint | Default 0 |
| `ModifiedBy` / `ModifiedDate` | int/smalldatetime | Audit |

---

#### `dbo` StudentApplication / staff / disability / student-alert — cross-reference summary

| Table | Scope | Key FK targets / notes |
|---|---|---|
| `StudentApplication` | Live-SIS admissions record | **Temporal**; PK `ApplicationID`; Notes→`rw.PersonNote`; cf. OA subsystem |
| `StudentApplicationEmailSent` | Admissions email log | → `StudentApplication` |
| `StudentEducationOrganizationAssociationDisability` | SEOA disability | **Sensitive**; → `prsn.StudentEducationOrganizationAssociation` |
| `StudentEducationOrganizationAssociationDisabilityDesignation` | Disability designation | → `…AssociationDisability` |
| `StaffLogin` | Staff login log | Per staff |
| `StaffSalary` | Staff salary history | **Sensitive (comp)** |
| `StaffSchools` | Staff↔school assignment | Passport tenant-sync trigger |
| `StaffSubstitutes` | Substitute assignments | Reciprocal sync with `StaffAttendance` |
| `StandardsPerfStandard` | Performance-standard defs | Academic standards; self-FK no-op |
| `StudentAlert` | Student alert defs | Per student |
| `StudentAlertApplication` | Alert display per module | PK `(AlertID, ApplicationID)` |
| `StudentAlertRead` | Alert read-tracking | PK `(AlertID, StudentID, StaffID)` |
| `StudentActivity` | Activity participation | PK `(StudentID, ActivityID)` |
| `StudentHonors` | Honors/awards | Per term/year |
| `StudentAllergies` | Allergy records | **Health PII** |

---

### `dbo` student medical subsystem, inquiry, re-enroll, progression, rank, requests & transfer

> **The student medical tables below contain health PII (HIPAA-adjacent). Treat as strictly confidential.**

> **Legacy `dbo` medical vs `med` schema.** Several `dbo.StudentMedical*` tables are the legacy flat model; the refactored, configurable model lives in the `med` schema (`med.StudentMedicalTest`, `med.StudentMedicalTestFieldData`, `med.MedicalTestConfiguration*`). The legacy `dbo.StudentMedicalTests` table keeps the `med` schema in sync via triggers (see below). Same legacy-vs-refactored pattern as cash register (dbo vs `cr`), lunch (dbo vs `cafe`), courses (dbo vs `crse`).

#### `dbo.StudentImmunization`
Immunization shot records per student — shot type/number/date, exemption, lock. PK is composite `(StudentID, ShotType, ShotNumber)`.

| Column | Type | Notes |
|---|---|---|
| `StudentID` / `ShotType` / `ShotNumber` | mixed | PK (composite); all indexed |
| `ShotDate` | datetime | Indexed |
| `Exemption` | smallint | Exemption code; default 0 |
| `Comment` / `Locked` | mixed | — |
| `ModifiedBy` / `ModifiedDate` | int/smalldatetime | Audit |

---

#### `dbo.StudentImmunizationCompliance`
Per-student immunization-compliance status by type — compliant flag, date checked, reason. PK is composite `(StudentID, Type)`.

| Column | Type | Notes |
|---|---|---|
| `StudentID` / `Type` | mixed | PK (composite) |
| `Compliant` / `DateChecked` / `Reason` | mixed | Compliance result |
| `ModifiedBy` / `ModifiedDate` | int/smalldatetime | Audit |

---

#### `dbo.StudentMedicalConditions`
Student medical conditions — condition, comment, medical-header display. (Cf. `StudentAllergies` from last batch — same display-in-header pattern.)

| Column | Type | Notes |
|---|---|---|
| `ConditionID` | int IDENTITY | PK |
| `StudentID` | int | The student; default 0 |
| `Condition` / `Comment` | nvarchar(512) | — |
| `DisplayInMedicalHeader` / `DisplayOrder` | mixed | Medical header |
| `ModifiedBy` / `ModifiedDate` | int/smalldatetime | Audit |

---

#### `dbo.StudentMedication`
Student medications — medication, dose, route, schedule, prescribe/discontinue dates, self-administer flag. Referenced by `StudentMedicalEvents.MedicationID`.

| Column | Type | Notes |
|---|---|---|
| `MedicationID` | int IDENTITY | PK |
| `StudentID` | int | The student; default 0 |
| `Medication` / `Dose` / `Route` | nvarchar | The med |
| `SelfAdminister` / `Scheduled` / `ScheduledNote` / `Discontinued` | mixed | Administration |
| `DatePrescribed` / `DateDiscontinued` | nvarchar | Text dates |
| `MedicationNote` | nvarchar(255) | — |
| `ModifiedBy` / `ModifiedDate` | int/smalldatetime | Audit |

---

#### `dbo.StudentMedicalEvents`
Nurse/clinic visit log — event date/type, description, treatment, outcome, vitals (temperature), time in/out, person-contacted info, and medication given. FKs to `StudentMedication` (`MedicationID`), and to `Person` (both `StudentID` and `ReportedBy`).

| Column | Type | Notes |
|---|---|---|
| `EventID` | int IDENTITY | PK |
| `StudentID` | int | FK → `Person`; indexed |
| `EventDate` / `EventType` | mixed | — |
| `Description` / `Treatment` / `Outcome` | nvarchar(max) | The visit |
| `Temperature` / `TimeIn` / `TimeOut` | nvarchar | Vitals/timing |
| `PersonContacted` / `TimeContacted` / `ContactNote` | nvarchar | Contact info |
| `MedicationID` | int | FK → `StudentMedication`; indexed |
| `ReportedBy` | int | FK → `Person`; indexed |
| `Staff` / `InternalNote` | nvarchar | — |
| `ModifiedBy` / `ModifiedDate` | int/smalldatetime | Audit |

---

#### `dbo.StudentMedicalTests`
Legacy student medical-test results — a test (`TestTypeID`) with date and 10 generic `Field1`–`Field10` value slots. **Kept in sync with the `med` schema by triggers.** PK `TestID`.

| Column | Type | Notes |
|---|---|---|
| `TestID` | int IDENTITY | PK |
| `TestTypeID` | int | → `med.MedicalTestConfiguration`; default 0 |
| `StudentID` | int | The student; default 0 |
| `TestDate` | datetime | — |
| `Field1`–`Field10` | nvarchar(512) | Generic value slots (mapped to configured fields) |
| `ModifiedBy` / `ModifiedDate` | int/smalldatetime | Audit |

**Triggers** (Insert/Update/Delete) bridge legacy↔`med` schema:
- `TR_dbo_StudentMedicalTests_Ins`: inserts a corresponding `med.StudentMedicalTest` (with IDENTITY_INSERT to preserve `TestID`) and unpivots `Field1`–`Field10` into `med.StudentMedicalTestFieldData` rows via the `med.MedicalTestConfigurationField` `LegacyIndex` mapping. Guarded by `trigger_nestlevel() < 2`.
- `TR_dbo_StudentMedicalTests_Upd`: syncs header + changed field values into the `med` tables. Guarded against recursion.
- `TR_dbo_StudentMedicalTests_Del`: deletes the corresponding `med.StudentMedicalTest` + `med.StudentMedicalTestFieldData` rows.

> This is a notable bidirectional legacy/refactor bridge: the old wide `Field1`–`Field10` layout is auto-translated to the new normalized config-driven `med` model.

---

### `dbo` inquiry / re-enroll / progression — note-syncing admissions records

Three more records that materialize their `Notes` field into `rw.PersonNote` (joining `StudentApplication` from last batch). Each uses a distinct `NoteType`:

| Table | `rw.PersonNote` NoteType |
|---|---|
| `StudentApplication` | 0 |
| `StudentInquiry` | 1 |
| `StudentReenroll` | 2 |
| `Person.MedicalNote` | 3 |

#### `dbo.StudentInquiry`
Prospective-student inquiry record (top of the admissions funnel) — contact date, status, grade/year, financial-aid interest, referral, tracking. (The "live SIS" inquiry; cf. the OA inquiry funnel `OARequestInfo*`.)

| Column | Type | Notes |
|---|---|---|
| `InquiryID` | int IDENTITY | PK |
| `StudentID` | nchar(10) | Note: text id here, not int |
| `ContactDate` / `Active` / `Status` | mixed | Funnel status |
| `YearID` / `GradeLevel` / `SchoolCode` | mixed | Context |
| `FinancialAid` / `ReferredBy` / `ReferredByDetails` | mixed | — |
| `TrackingSystemID` | int | → `TrackingConfig` |
| `Notes` | nvarchar(max) | → `rw.PersonNote` (NoteType 1) via triggers |

**Triggers** Insert/Update/Delete maintain `rw.PersonNote` (NoteType 1) — same pattern as `StudentApplication`.

---

#### `dbo.StudentReenroll`
Re-enrollment record per student×year — status, milestone dates, tuition plan, re-enroll fee lifecycle, enrollment-packet lifecycle, FACTS-bypass. **Temporal table.** PK is composite `(StudentID, YearID)`. (The data record behind the `ReenrollProcess` wizard; parallel to `StudentApplication` but for returning students.)

| Column group | Type | Notes |
|---|---|---|
| `ReenrollID` | int IDENTITY | Surrogate |
| `StudentID` / `YearID` | int | PK (composite) |
| Status: `Status` / `CancelReason` / `StartDate` / `FinishDate` / `GradeLevel` | mixed | — |
| Fee: `ReenrollFeePaid` / `ReenrollFeePaidDate` / `Paid` / `PaidNote` / `EnrollmentFeeWaived` / `TuitionPlanID` | mixed | — |
| Packet: `EnrollmentPacketSent` / `…Started` / `…Submitted` / `…SentOtherHousehold` / `NotificationSent` / `UnfinishedEmail` | smalldatetime | Packet lifecycle |
| Integration: `OEBypassFACTS` / `BypassTuitionContract` / `TrackingSystemID` | mixed | — |
| `Notes` | nvarchar(max) | → `rw.PersonNote` (NoteType 2) via triggers |
| `CreatedOnUTC` / `ModifiedOnUTC` / `ModifiedOnUTCmax` | datetime2 | Temporal; indexed |

**Triggers** Insert/Update/Delete maintain `rw.PersonNote` (NoteType 2) — same pattern.

---

#### `dbo.StudentReenrollEmailSent`
Log of re-enrollment emails sent — type, date, address per re-enroll record. (Parallel to `StudentApplicationEmailSent`.)

| Column | Type | Notes |
|---|---|---|
| `EmailSentID` | int IDENTITY | PK |
| `ReenrollID` | int | The re-enroll record |
| `EmailType` | nvarchar(50) | Indexed |
| `EmailDate` / `EmailAddress` | mixed | — |

---

#### `dbo.StudentProgression`
Grade-level progression log per student — from/to grade level, progression label, date, memo. The history of a student's grade-level advancement (cf. the progression columns on `Person_Student`).

| Column | Type | Notes |
|---|---|---|
| `AutoNumber` | int IDENTITY | PK |
| `StudentID` / `YearID` | int | Context; default 0 |
| `FromGradeLevel` / `ToGradeLevel` / `Progression` | nvarchar | The move |
| `ProgressionDate` / `Memo` | mixed | — |
| `ModifiedBy` / `ModifiedDate` | int/smalldatetime | Audit |

---

### `dbo` rank / recognition

#### `dbo.StudentRank`
Per-student, per-term class-rank + GPA/average statistics — term avg/GPA/UGPA with high/low bounds, rank, rank count, credits, and 5 user-defined honor slots. PK `AutoNum`. (Feeds rank/honor-roll reporting; cf. `HonorRoll*` tables.)

| Column group | Type | Notes |
|---|---|---|
| `AutoNum` | int IDENTITY | PK |
| `StudentID` / `YearID` / `TermID` / `GradeLevel` | mixed | Context; default 0 |
| Avg: `TermAvg` / `TermHighAvg` / `TermLowAvg` | real | — |
| GPA: `TermGPA` / `TermHighGPA` / `TermLowGPA` / `TermUGPA` / `TermHighUGPA` / `TermLowUGPA` | real | Weighted + unweighted |
| Rank: `TermRank` / `RankCount` / `RankDate` | mixed | Rank N of RankCount |
| Credits: `CreditsAttempted` / `CreditsEarned` | real | — |
| Honors: `HonorID` / `HonorRollID` / `UDHonor1`–`UDHonor5` | mixed | — |

---

#### `dbo.StudentRecognition`
Student recognitions/awards per term/year — recognition text, category, honor/honor-roll linkage. (Cf. `StudentHonors` from last batch — overlapping concept; this adds category + school code.)

| Column | Type | Notes |
|---|---|---|
| `RecognitionID` | int IDENTITY | PK |
| `StudentID` / `YearID` / `TermID` / `GradeLevel` / `SchoolCode` | mixed | Context |
| `Recognition` / `Category` / `Note` | nvarchar | The recognition |
| `HonorID` / `HonorRollID` | int | Honor linkage |
| `ModifiedBy` / `ModifiedDate` | int/smalldatetime | Audit |

---

### `dbo` course requests & transfer

#### `dbo.StudentRequests`
**Student course requests** for scheduling — the courses a student requests for a year, with preferred/alternate course/class/instructor, level, term, count, and permission. **Temporal table.** PK is composite `(StudentID, CourseID, YearID)`. FKs to `crse.CourseCore`, `sched.FamilyRequest`, `Person` (student + preferred instructor), `SchoolYear`.

| Column | Type | Notes |
|---|---|---|
| `StudentID` | int | PK (composite); FK → `Person`; default 0 |
| `CourseID` | int | PK (composite); FK → `crse.CourseCore`; default 0; indexed |
| `YearID` | int | PK (composite); FK → `SchoolYear`; default 0; indexed |
| `StudentRequestID` | int IDENTITY | Unique clustered surrogate |
| Request: `Count` / `LEVEL` / `Term` / `RequestType` / `Permission` | mixed | — |
| Preferences: `PreferredClassID` / `AlternateCourseID` / `UseAlternate` / `PreferredInstructorID` / `WebPrimaryElem` / `WebAlternateElem` | mixed | Preferred/alt; `PreferredInstructorID` → `Person` |
| `ClassList` / `FamilyRequestID` | mixed | `FamilyRequestID` → `sched.FamilyRequest`; indexed |
| `ModifiedBy` / `ModifiedDate` / `CreatedOnUTC` | mixed | Audit |
| `ModifiedOnUTC` / `ModifiedOnUTCmax` | datetime2 | Temporal |

> Resolves the `crse.CourseCore` and `sched.FamilyRequest` references — the request→scheduling linkage.

---

#### `dbo.StudentTransferRequest`
Student-records transfer request between schools/districts — from/to district/school/contact/grade, the data categories requested (behavior/medical/portfolio/grades) and their approvals, plus approval status and response. Supports the cross-school student-records transfer workflow.

| Column group | Type | Notes |
|---|---|---|
| `TransferRequestID` | int IDENTITY | PK |
| Type: `TransferRecordType` / `TransferType` | int | — |
| From: `TransferFrom{DistrictCode,SchoolCode,SchoolName,TransferRequestID,ContactID,ContactName,GradeLevel,StudentName,StudentID}` | mixed | Source |
| To: `TransferTo{DistrictCode,SchoolCode,SchoolName,TransferRequestID,GradeLevel,YearID,OAID,RequestingStaffID,RequestingStaffName}` | mixed | Destination |
| Requested data: `RequestBehavior` / `RequestMedical` / `RequestPortfolio` / `RequestGrades` | bit | What's requested |
| Approved data: `ApproveBehavior` / `ApproveMedical` / `ApprovePortfolio` / `ApproveGrades` | bit | What's approved |
| Response: `TransferApprovalStatus` / `TransferResponseDateTime` / `TransferResponseByStaffID` | mixed | — |
| `DateTimeRequested` / `TransferNote` | mixed | — |

---

#### `dbo.StudentTransferRequestStudentMM`
Many-to-many link of students to a transfer request. PK is composite `(StudentID, TransferRequestID)`.

| Column | Type | Notes |
|---|---|---|
| `StudentID` | int | PK (composite) |
| `TransferRequestID` | int | PK (composite); → `StudentTransferRequest` |
| `StudentName` | varchar(128) | Denormalized name |

---

#### `dbo` student-medical / inquiry / reenroll / rank / requests / transfer — cross-reference summary

| Table | Scope | Key FK targets / notes |
|---|---|---|
| `StudentImmunization` | Immunization shots | **Health PII**; PK `(StudentID, ShotType, ShotNumber)` |
| `StudentImmunizationCompliance` | Immunization compliance | **Health PII**; PK `(StudentID, Type)` |
| `StudentMedicalConditions` | Medical conditions | **Health PII**; medical-header display |
| `StudentMedication` | Medications | **Health PII**; ref by `StudentMedicalEvents` |
| `StudentMedicalEvents` | Nurse/clinic visit log | **Health PII**; → `StudentMedication`, `Person` |
| `StudentMedicalTests` | Legacy medical tests | **Health PII**; triggers bridge → `med` schema |
| `StudentInquiry` | Admissions inquiry | Notes→`rw.PersonNote` (type 1); cf. `OARequestInfo*` |
| `StudentReenroll` | Re-enrollment record | **Temporal**; PK `(StudentID, YearID)`; Notes→`rw.PersonNote` (type 2) |
| `StudentReenrollEmailSent` | Re-enroll email log | → `StudentReenroll` |
| `StudentProgression` | Grade-progression log | Per student/year |
| `StudentRank` | Class-rank + GPA stats | Per term; feeds honor-roll reporting |
| `StudentRecognition` | Recognitions/awards | Per term/year; cf. `StudentHonors` |
| `StudentRequests` | Course requests | **Temporal**; → `crse.CourseCore`, `sched.FamilyRequest`, `Person`, `SchoolYear` |
| `StudentTransferRequest` | Cross-school records transfer | Request + approval per data category |
| `StudentTransferRequestStudentMM` | Students↔transfer request | PK `(StudentID, TransferRequestID)` |

---

### `dbo` standardized tests (legacy + aca bridge), survey/test engine, scheduling templates, syllabus, transportation & textbooks

### `dbo` standardized testing — legacy `TestConfig`/`TestData` with `aca` bridge

> **Legacy `dbo` standardized-test model vs `aca` schema.** `dbo.TestConfig` (test definition, up to 20 score columns) and `dbo.TestData` (per-student scores) are the legacy wide-column standardized-test model. The refactored, normalized model lives in the `aca` schema (`aca.StandardizedTestConfiguration` + `aca.StandardizedTestConfigurationScore` for the config; `aca.PersonStandardizedTest` + `aca.PersonStandardizedTestScore` for the data). Both legacy tables keep the `aca` schema in sync via triggers — the same legacy↔refactor auto-bridge pattern as `StudentMedicalTests`→`med`. Resolves the long-pending `TestConfig`/`TestData` references.

#### `dbo.TestConfig`
Standardized-test definition — a named test with up to **20 score-column labels** (`Score1Label`–`Score20Label`), transcript flag, district-wide flag, and fixed-width import field positions (`Begin1`–`Begin20`/`End1`–`End20` plus demographic-field positions). Links to `aca.StandardizedTestConfiguration` via `StandardizedTestConfigurationID`. PK `TestID`.

| Column group | Type | Notes |
|---|---|---|
| `TestID` | int IDENTITY | PK; `LegacyTestID` in `aca` |
| `Name` / `Transcript` / `SchoolCode` / `DistrictWide` | mixed | Identity/scope |
| `Score1Label`–`Score20Label` | nvarchar(50) | Score component labels (up to 20) |
| `Begin1`–`Begin20` / `End1`–`End20` | int | Fixed-width import positions per score |
| `BeginStudentID`/`EndStudentID` / `BeginLastName`/`EndLastName` / `BeginFirstName`/`EndFirstName` / `BeginDay`/`EndDay` / `BeginMonth`/`EndMonth` / `BeginYear`/`EndYear` / `BeginSynch1/2`/`EndSynch1/2` / `Synch1/2` / `BeginGradeLevel`/`EndGradeLevel` | mixed | Import-file field positions |
| `FileType` | int | Import file type |
| `StandardizedTestConfigurationID` | int | → `aca.StandardizedTestConfiguration` |
| `ModifiedBy` / `ModifiedDate` | int/smalldatetime | Audit |

**Triggers** (Insert/Update/Delete) bridge to the `aca` schema:
- `tr_dbo_TestConfig_Ins`: creates the matching `aca.StandardizedTestConfiguration` (mapping `DistrictWide`→`ConfigSchoolID` via `ConfigSchool`), back-fills `StandardizedTestConfigurationID`, then inserts one `aca.StandardizedTestConfigurationScore` per non-empty `ScoreNLabel` (SortOrder 1–20).
- `tr_dbo_TestConfig_Upd`: syncs name/transcript/school changes and adds/updates/deletes score rows as labels change (deleting empties also clears `aca.PersonStandardizedTestScore`).
- `tr_dbo_TestConfig_Del`: deletes the matching `aca.StandardizedTestConfiguration`.

---

#### `dbo.TestData`
Per-student standardized-test scores — up to **20 numeric scores** (`Score1`–`Score20`), date, grade level, transcript-exclusion. Links to `aca.PersonStandardizedTest` via `PersonStandardizedTestID`. PK `TestDataID`.

| Column | Type | Notes |
|---|---|---|
| `TestDataID` | int IDENTITY | PK; `LegacyTestDataID` in `aca` |
| `StudentID` | int | The student; indexed |
| `TestID` | int | → `TestConfig`; default 0 |
| `Score1`–`Score20` | real | The scores |
| `Date` / `GradeLevel` / `Note` / `ExcludeTranscript` | mixed | — |
| `PersonStandardizedTestID` | int | → `aca.PersonStandardizedTest` |
| `ModifiedBy` / `ModifiedDate` | int/smalldatetime | Audit |

**Triggers** (Insert/Update/Delete) bridge to the `aca` schema:
- `tr_dbo_TestData_Ins`: creates the matching `aca.PersonStandardizedTest` (joining `TestConfig`→config, `Person`→student), back-fills `PersonStandardizedTestID`, then inserts one `aca.PersonStandardizedTestScore` per score (SortOrder 1–20, joined to the config's score rows).
- `tr_dbo_TestData_Upd`: syncs header + changed scores; guarded by `trigger_nestlevel() < 2`.
- `tr_dbo_TestData_Del`: deletes the matching `aca.PersonStandardizedTest`.

> Together, `TestConfig`/`TestData` + their `aca` counterparts mean standardized-test data exists in **both** the legacy wide-column form and the normalized `aca` form, kept consistent by these triggers. Reporting can read either; the `aca` form is the current model.

---

### `dbo` survey / online-test engine

The **Survey*** tables are an online survey/quiz/test engine (distinct from standardized tests above). `SurveyConfig` is the test definition; `SurveyQuestions` the questions; `Survey` a student's attempt; `SurveyAnswers` the responses; `SurveyClasses`/`SurveyMembers` the audience. (Note: column `TestID` here refers to `SurveyConfig.TestID`, not `TestConfig`.)

#### `dbo.SurveyConfig`
Survey/test definition — name, instructions, timing, proctoring, attempts, points, audience (staff/students/parents/families lists), and sharing. PK `TestID`.

| Column group | Type | Notes |
|---|---|---|
| `TestID` | int IDENTITY | PK |
| `Name` / `Description` / `Instructions` / `TestType` | mixed | Identity |
| Timing: `BeginTime` / `EndTime` / `Duration` | mixed | Window |
| Proctor: `Proctor` / `ProctorPassword` | mixed | — |
| Scoring: `AllowedAttempts` / `ShowResults` / `Points` / `Questions` | mixed | — |
| Audience: `Members_Staff` / `Members_Students` / `Members_Parents` / `Members_Families` / `AllClasses` / `ShareTests` | mixed | Who takes it |
| `StaffID` / `Active` (default 1) | mixed | Owner |
| `ModifiedBy` / `ModifiedDate` | int/smalldatetime | Audit |

---

#### `dbo.SurveyQuestions`
Questions for a survey/test — text, answer, points, type, up to 5 options, HTML flag. (`TestID` → `SurveyConfig`.)

| Column | Type | Notes |
|---|---|---|
| `AutoNum` | int IDENTITY | PK |
| `TestID` / `Number` | int | → `SurveyConfig`; order |
| `Question` / `Answer` / `QuestionType` / `Points` / `HTML` | mixed | — |
| `Option1`–`Option5` | nvarchar(max) | Choices |
| `ModifiedBy` / `ModifiedDate` | int/smalldatetime | Audit |

---

#### `dbo.Survey`
A student's survey/test attempt — start/end, finished, points earned, comments. (`TestID` → `SurveyConfig`.)

| Column | Type | Notes |
|---|---|---|
| `AutoNum` | int IDENTITY | PK |
| `TestID` / `ClassID` / `StudentID` | int | The attempt |
| `StartTime` / `EndTime` / `Finished` / `PointsEarned` / `Comments` | mixed | Result |
| `ModifiedBy` / `ModifiedDate` | int/smalldatetime | Audit |

---

#### `dbo.SurveyAnswers`
Individual responses within an attempt — answer per question number, by member/user-type. (`TestID` → `SurveyConfig`.)

| Column | Type | Notes |
|---|---|---|
| `AutoNum` | int IDENTITY | PK |
| `MemberID` / `UserType` / `TestID` / `ClassID` | mixed | Who/which test |
| `Number` / `Answer` / `Comments` / `LastModified` | mixed | The response |
| `ModifiedBy` / `ModifiedDate` | int/smalldatetime | Audit |

---

#### `dbo.SurveyClasses`
Classes assigned a survey/test. PK is composite `(TestID, ClassID)`.

| Column | Type | Notes |
|---|---|---|
| `TestID` | int | PK (composite); → `SurveyConfig` |
| `ClassID` | int | PK (composite) |

---

#### `dbo.SurveyMembers`
Members (by id + type) assigned a survey. PK is composite `(ID, TYPE, SurveyID)`.

| Column | Type | Notes |
|---|---|---|
| `ID` | int | PK (composite); member id |
| `TYPE` | nchar(10) | PK (composite); member type |
| `SurveyID` | int | PK (composite); → `SurveyConfig` |

---

### `dbo` scheduling day-templates (legacy vs year-aware)

The **Template** tables define the day/period bell-schedule grid per school (distinct from the `ScheduleTemplate` master-schedule grid documented earlier). `Template` (legacy) vs `TemplateNew` (year-aware) — another legacy/year-aware pair like `Patterns`/`PatternsNew`. `TemplateStaff` holds per-staff schedule cells.

#### `dbo.Template`
Legacy day-template bell schedule — text per day×period×template×school. PK is composite `(Day, Template, Period, SchoolCode)`.

| Column | Type | Notes |
|---|---|---|
| `Day` / `Template` / `Period` / `SchoolCode` | mixed | PK (composite); `SchoolCode` indexed |
| `TemplateText` / `TemplateTime` | nvarchar | Cell label/time |
| `ModifiedBy` / `ModifiedDate` | int/smalldatetime | Audit |

---

#### `dbo.TemplateNew`
Year-aware day-template (adds `YearID` to the key). PK is composite `(Day, Template, Period, SchoolCode, YearID)`.

| Column | Type | Notes |
|---|---|---|
| `Day` / `Template` / `Period` / `SchoolCode` / `YearID` | mixed | PK (composite) |
| `TemplateText` | nvarchar(50) | Cell label |
| `ModifiedBy` / `ModifiedDate` | int/smalldatetime | Audit |

> **Legacy-vs-year-aware pair**: `Template` (no year) vs `TemplateNew` (year-keyed). Same pattern as `Patterns`/`PatternsNew`.

---

#### `dbo.TemplateStaff`
Per-staff day-template cells — text per staff×day×period, with schedule-block flag. PK is composite `(StaffID, Day, Period)`. (Cf. the template-id-keyed `ScheduleTemplateStaff` documented earlier; this one is not template-id-keyed in its PK.)

| Column | Type | Notes |
|---|---|---|
| `StaffID` / `Day` / `Period` | int | PK (composite) |
| `TemplateText` / `ScheduleBlock` / `TemplateID` | mixed | Cell |
| `ModifiedBy` / `ModifiedDate` | int/smalldatetime | Audit |

---

### `dbo` syllabus, transportation & textbooks

#### `dbo.Syllabus`
Class/staff syllabus entries — title + message (rich text), with a global flag.

| Column | Type | Notes |
|---|---|---|
| `SyllabusID` | int IDENTITY | PK |
| `StaffID` / `ClassID` | int | Owner |
| `Title` / `Message` | mixed | Content |
| `GlobalItem` | bit | Shared across classes |
| `ModifiedBy` / `ModifiedDate` | int/smalldatetime | Audit |

---

#### `dbo.StudentTransportation`
Student transportation routes — route type, address, days of week, pickup point, override date. FK `PickupPointID` → `rw.PickupPoint` (SET NULL on delete).

| Column | Type | Notes |
|---|---|---|
| `RouteID` | int IDENTITY | PK |
| `StudentID` / `RouteType` / `TransportationID` | mixed | Route |
| `Street` / `CityStateZip` | nvarchar | Address |
| `Monday`–`Sunday` | bit | Days of week |
| `PickupPointID` | int | FK → `rw.PickupPoint` (SET NULL) |
| `OverrideDate` / `Note` | mixed | — |

---

#### `dbo.TextBookDefinition`
Textbook catalog entry — title, author, publisher, cost, ISBN, per school. Parent of `TextBooks`.

| Column | Type | Notes |
|---|---|---|
| `TextBookDefinitionID` | int IDENTITY | PK |
| `Title` / `Author` / `Publisher` / `ISBN` | nvarchar | Catalog |
| `Cost` | smallmoney | — |
| `SchoolCode` | varchar(50) | — |
| `ModifiedBy` / `ModifiedDate` | int/smalldatetime | Audit |

---

#### `dbo.TextBooks`
Textbook copies / checkouts — a numbered copy of a `TextBookDefinition`, checked out to a student, with lost status.

| Column | Type | Notes |
|---|---|---|
| `TextBookID` | int IDENTITY | PK |
| `TextBookDefinitionID` | int | → `TextBookDefinition` |
| `Number` | int | Copy number |
| `StudentID` / `CheckoutDate` / `Lost` | mixed | Checkout |
| `Note` | nvarchar(max) | — |
| `ModifiedBy` / `ModifiedDate` | int/smalldatetime | Audit |

---

#### `dbo` standardized-test / survey / template / syllabus / transportation / textbook — cross-reference summary

| Table | Scope | Key FK targets / notes |
|---|---|---|
| `TestConfig` | Standardized-test def (legacy) | 20 score labels; triggers bridge → `aca.StandardizedTestConfiguration` |
| `TestData` | Student test scores (legacy) | 20 scores; triggers bridge → `aca.PersonStandardizedTest` |
| `SurveyConfig` | Survey/online-test def | Audience lists; PK `TestID` |
| `SurveyQuestions` | Survey questions | → `SurveyConfig`; 5 options |
| `Survey` | Survey attempt | → `SurveyConfig` |
| `SurveyAnswers` | Survey responses | → `SurveyConfig` |
| `SurveyClasses` | Survey→class | PK `(TestID, ClassID)` |
| `SurveyMembers` | Survey→member | PK `(ID, TYPE, SurveyID)` |
| `Template` | Day-template (legacy) | PK `(Day, Template, Period, SchoolCode)` |
| `TemplateNew` | Day-template (year-aware) | PK adds `YearID` |
| `TemplateStaff` | Per-staff day-template | PK `(StaffID, Day, Period)` |
| `Syllabus` | Class/staff syllabus | By staff/class |
| `StudentTransportation` | Transportation routes | → `rw.PickupPoint` |
| `TextBookDefinition` | Textbook catalog | Parent of TextBooks |
| `TextBooks` | Textbook copies/checkouts | → `TextBookDefinition` |

---

### `dbo.Transcript`, transcript supplements, tracking subsystem, time-clock, timetable & transportation

#### `dbo.Transcript`
**The core transcript record** — one row per student×course-term that appears on the official transcript. This is the **destination of all the `TranscriptIDx` columns on `Roster`** (Roster periods link to Transcript rows); it carries denormalized course/class/instructor names (so historical transcripts stay stable even if courses change), the final grade/GPA/UGPA/average/credits, per-term and semester grades/averages, transfer/imported flags, lock, and attendance. PK `TranscriptID`.

> Denormalization is deliberate: `SchoolName`, `Course`, `Class`, `Instructor`, `YearName`, `CourseLevel`, `Department` are stored as text (not FKs) so the transcript is a permanent snapshot independent of later changes to the live course/class tables.

Documented by column group:

| Column group | Type | Notes |
|---|---|---|
| `TranscriptID` | int IDENTITY | PK |
| `StudentID` | int | Indexed (with ClassID; with HS+GradeLevel) |
| `ClassID` | int | Source class (nullable; transfers/imports have none) |
| Denormalized labels: `SchoolName` / `SchoolCode` / `Course` / `Class` / `Abbreviation` / `Instructor` / `YearName` / `CourseLevel` / `Department` / `GradeLevel` | mixed | Permanent snapshot text |
| Period context: `TermID` / `SemesterID` / `YearID` | mixed | All default 0 |
| Final: `FinalGrade` / `FinalGradeAvg` / `FinalGradeGPA` / `FinalGradeUGPA` (decimal) + `_real` variants | mixed | Weighted/unweighted; both decimal + legacy `real` columns |
| Credits: `Credits` (decimal) / `Credits_real` / `CreditsOverride` | mixed | — |
| Term grades/avgs: `Grade1`–`Grade6` / `Term1Avg`–`Term6Avg` (decimal) | mixed | — |
| Exam: `Exam1Grade`–`Exam3Grade` / `Exam1Avg`–`Exam3Avg` | mixed | — |
| Semester: `Sem1Grade`–`Sem3Grade` / `Sem1Avg`–`Sem3Avg` / `Sem1GPA`–`Sem3GPA` / `Sem1UGPA`–`Sem3UGPA` / `Sem1Calc`–`Sem3Calc` / `Sem1Pass`–`Sem3Pass` | mixed | Per-semester detail |
| Attendance: `Absent` / `Tardy` | decimal | — |
| Flags: `Passing` / `Calc` / `CalcAvg` / `Transfer` / `Lock` / `Imported` / `HS` / `Preschool` / `Elementary` / `SummerSchool` | bit | `Transfer`/`Imported` = externally-sourced |
| `StateID` / `LegacyCourseID` / `Note` | mixed | State reporting / legacy linkage |
| `CourseAttemptResultDescriptorID` | uniqueidentifier | Ed-Fi descriptor |
| `ModifiedBy` / `ModifiedDate` | int/smalldatetime | Audit |

> **Source-file note:** an accompanying `dbo_Transcript_sql.orig` file is a **stale, git-conflicted version** (contains unresolved `<<<<<<< HEAD` / `=======` / `>>>>>>> test` merge markers, lacks the `Sem3`/`Exam3` columns, `CourseAttemptResultDescriptorID`, and the indexes). The current resolved definition is documented above; the `.orig` should be ignored.

---

#### `dbo.TranscriptAbsent`
Per-year transcript attendance summary — absent/tardy/days-present per student per year (free-text `YearID`/`SchoolName`, for imported/historical transcripts). PK `TranscriptAbsentID`.

| Column | Type | Notes |
|---|---|---|
| `TranscriptAbsentID` | int IDENTITY | PK |
| `StudentID` | int | Default 0 |
| `YearID` | nvarchar(50) | Text year (historical) |
| `Absent` / `Tardy` / `DaysPresent` | decimal | Attendance |
| `SchoolName` | nvarchar(50) | — |
| `ModifiedBy` / `ModifiedDate` | int/smalldatetime | Audit |

---

#### `dbo.TranscriptActivity`
Per-year activities listed on the transcript. PK `TranscriptActivityID`.

| Column | Type | Notes |
|---|---|---|
| `TranscriptActivityID` | int IDENTITY | PK |
| `StudentID` / `Year` | mixed | Context |
| `Activity` / `ActivityNote` / `SchoolName` | nvarchar | — |
| `ModifiedBy` / `ModifiedDate` | int/smalldatetime | Audit |

---

#### `dbo.TranscriptHonors`
Per-year honors listed on the transcript. PK `TranscriptHonorsID`. (The transcript-snapshot counterpart to `StudentHonors`.)

| Column | Type | Notes |
|---|---|---|
| `TranscriptHonorsID` | int IDENTITY | PK |
| `StudentID` / `Year` / `Honor` | mixed | — |
| `ModifiedBy` / `ModifiedDate` | int/smalldatetime | Audit |

---

### `dbo` tracking subsystem

The **Tracking** tables are a generic checklist/tracking-system framework, referenced throughout by `TrackingSystemID` (e.g. on `PersonTracking`, `StudentApplication`, `StudentInquiry`, `StudentReenroll`). `TrackingConfig` defines a tracking system; `TrackingItems` its checklist items; `TrackingData` the per-entity values; `TrackingItemDefinedList` provides picklist options. Resolves the long-pending `TrackingConfig`/`TrackingItems` references.

#### `dbo.TrackingConfig`
A named tracking system (checklist) — type, school/district scope, sort order. PK `TrackingSystemID`.

| Column | Type | Notes |
|---|---|---|
| `TrackingSystemID` | int IDENTITY | PK |
| `Name` / `Type` | mixed | Identity |
| `DistrictWide` / `SchoolCode` | mixed | Scope |
| `SortOrder` | int | Default 100 |

---

#### `dbo.TrackingItems`
Checklist items within a tracking system — item label, publish/notify flags, carbon-copy email, message text, data type, OA linkage, and filters. PK is composite `(TrackingSystemID, ItemNumber)`; unique surrogate `ItemID`.

| Column | Type | Notes |
|---|---|---|
| `TrackingSystemID` / `ItemNumber` | int | PK (composite); → `TrackingConfig` |
| `ItemID` | int IDENTITY | Unique surrogate |
| `Item` / `DataType` | mixed | The checklist item |
| `PublishApplication` / `Notify` / `CarbonEmail` / `MessageText` | mixed | Notification |
| `filterApp` / `filterEnroll` / `OAItemID` / `SortOrder` | mixed | Filters / OA linkage |

---

#### `dbo.TrackingData`
Per-entity tracking values — the checklist responses for an entity (`ID`) within a tracking system. PK is composite `(ID, TrackingSystemID, ItemNumber)`.

| Column | Type | Notes |
|---|---|---|
| `ID` | int | PK (composite); the tracked entity (e.g. person/application) |
| `TrackingSystemID` / `ItemNumber` | int | PK (composite); → `TrackingItems` |
| `YesNo` / `Note` | mixed | The response |
| `NotificationSent` / `ItemID` | mixed | — |

---

#### `dbo.TrackingItemDefinedList`
Picklist options for a tracking item. PK `TI_DL_ID`.

| Column | Type | Notes |
|---|---|---|
| `TI_DL_ID` | int IDENTITY | PK |
| `TrackingItemID` | int | → `TrackingItems.ItemID`; indexed |
| `Name` | nvarchar(128) | Option label |

---

### `dbo` time-clock subsystem

Staff and student time-clock (attendance/check-in) tables. Staff: `TimeClock` (events) + `TimeClockNote` (daily note/absence). Student: `TimeClockStudentNew` (current check-in/out) + `TimeClockNoteStudent` (notes).

#### `dbo.TimeClock`
Staff time-clock check-in/out events.

| Column | Type | Notes |
|---|---|---|
| `TimeClockID` | int IDENTITY | PK |
| `StaffID` / `Date` | mixed | — |
| `CheckIn` / `CheckOut` | bit | Event type |
| `ModifiedBy` / `ModifiedDate` | int/smalldatetime | Audit |

---

#### `dbo.TimeClockNote`
Staff daily time-clock note — absence, weight, reason, substitute flag.

| Column | Type | Notes |
|---|---|---|
| `AutoNum` | int IDENTITY | PK |
| `StaffID` / `Date` | mixed | — |
| `Note` / `Absent` / `Weight` / `AbsentReason` / `Substitute` | mixed | Absence detail |
| `ModifiedBy` / `ModifiedDate` | int/smalldatetime | Audit |

---

#### `dbo.TimeClockStudentNew`
Student check-in/out records (current model) — clocked-in/out times, who clocked them (staff/parent in/out ids), auto flags, processed date. (The "New" model; indexed for current-status lookup.)

| Column | Type | Notes |
|---|---|---|
| `TimeClockID` | int IDENTITY | PK |
| `StudentID` | int | Indexed with ClockedIn |
| `StaffInID` / `StaffOutID` / `ParentInID` / `ParentOutID` | int | Who clocked |
| `ClockedIn` / `ClockedOut` / `AutoIn` / `AutoOut` | mixed | Times + auto flags |
| `Note` / `ProcessedDate` | mixed | — |

---

#### `dbo.TimeClockNoteStudent`
Student time-clock daily notes.

| Column | Type | Notes |
|---|---|---|
| `AutoNum` | int IDENTITY | PK |
| `StudentID` / `Date` / `Note` | mixed | — |
| `ModifiedBy` / `ModifiedDate` | int/smalldatetime | Audit |

---

### `dbo` timetable & transportation routes

#### `dbo.TimeTable`
**Class meeting times** — the live timetable: day-in-cycle + begin-period + room per class. Unique on `(ClassID, Day, Begin)`. (The live counterpart to `ScheduleBackupTimeTable`; populated from the scheduling templates.)

| Column | Type | Notes |
|---|---|---|
| `TimeTableId` | int IDENTITY | PK |
| `ClassID` | int | The class; default 0 |
| `Day` / `Begin` | smallint | Day in cycle + period; both indexed; unique with ClassID |
| `RoomID` | int | Room; default 0 |
| `Remove` | bit | Soft-remove flag |
| `ModifiedBy` / `ModifiedDate` | int/smalldatetime | Audit |

---

#### `dbo.Transportation`
Transportation route definitions — route name, up to 3 drivers + phones, note, scope. (The route catalog; `StudentTransportation.TransportationID` references this.)

| Column | Type | Notes |
|---|---|---|
| `TransportationID` | int IDENTITY | PK |
| `RouteName` | nvarchar(50) | — |
| `Driver1`/`Phone1` … `Driver3`/`Phone3` | nvarchar | Up to 3 drivers |
| `Note` / `DistrictWide` / `SchoolCode` | mixed | Scope |

---

#### `dbo` Transcript / tracking / time-clock / timetable / transportation — cross-reference summary

| Table | Scope | Key FK targets / notes |
|---|---|---|
| `Transcript` | **Core transcript record** | Destination of `Roster.TranscriptIDx`; denormalized snapshot; PK `TranscriptID` |
| `TranscriptAbsent` | Transcript attendance summary | Per year (text year) |
| `TranscriptActivity` | Transcript activities | Per year |
| `TranscriptHonors` | Transcript honors | Per year; cf. `StudentHonors` |
| `TrackingConfig` | Tracking-system def | Referenced by `TrackingSystemID` everywhere |
| `TrackingItems` | Tracking checklist items | PK `(TrackingSystemID, ItemNumber)`; → OA |
| `TrackingData` | Per-entity tracking values | PK `(ID, TrackingSystemID, ItemNumber)` |
| `TrackingItemDefinedList` | Tracking picklist options | → `TrackingItems.ItemID` |
| `TimeClock` | Staff time-clock events | Per staff |
| `TimeClockNote` | Staff daily note/absence | Per staff/date |
| `TimeClockStudentNew` | Student check-in/out (current) | Per student |
| `TimeClockNoteStudent` | Student time-clock notes | Per student/date |
| `TimeTable` | Class meeting times (live) | Unique `(ClassID, Day, Begin)`; → `Rooms` |
| `Transportation` | Route catalog | Ref by `StudentTransportation` |

---

### `dbo` Web-order & Web-tests (end of `dbo`), then `enrl` and `facts` schemas

### `dbo` web order (online store)

#### `dbo.WebOrder`
Online-store order header — family, total, processed status, and the full order payload as JSON. (Portal e-commerce / web-store orders.)

| Column | Type | Notes |
|---|---|---|
| `OrderID` | int IDENTITY | PK |
| `FamilyID` | int | The ordering family |
| `TotalAmt` | float | Order total |
| `Processed` | int | Processing status |
| `WebOrderJSON` | nvarchar(max) | Full order payload (JSON) |
| `note` / `ModifiedDate` (nvarchar) | mixed | — |

---

#### `dbo.WebOrderItems`
Line items of a web order — per student, item, date, quantity, price. PK is composite `(OrderID, StudentID, ItemID, Date)`.

| Column | Type | Notes |
|---|---|---|
| `OrderID` | int | PK (composite); → `WebOrder` |
| `StudentID` / `ItemID` / `Date` | mixed | PK (composite) |
| `Quantity` / `Type` / `ItemPriceTotal` / `note` | mixed | Line detail |

---

### `dbo` web tests (online testing — current/gradebook-linked engine)

The **WebTests*** tables are the current online-testing engine — distinct from the older `Survey*` set, this one links to the gradebook (`GbkAssessmentID`/`GbkAssignmentID`/`GbkSave`), supports auto-grading and per-question feedback, and is class-scoped. `WebTestsConfig` (test def) → `WebTestsQuestions` (questions) → `WebTestsStudent` (attempt) → `WebTestsAnswers` (responses).

#### `dbo.WebTestsConfig`
Online-test definition — timing, proctoring, attempts, points, grading mode, gradebook linkage, class scope, ordering. PK `TestID`.

| Column group | Type | Notes |
|---|---|---|
| `TestID` | int IDENTITY | PK |
| `Name` / `Description` / `Instructions` / `TestType` / `HTML` | mixed | Identity |
| Timing: `BeginTime` / `EndTime` / `Duration` / `AllowScroll` | mixed | — |
| Proctor: `Proctor` / `ProctorPassword` | mixed | — |
| Scoring: `AllowedAttempts` / `ShowResults` / `Points` / `Questions` / `Grading` / `Print` / `OrderBy` | mixed | — |
| Gradebook: `GbkAssessmentID` / `GbkAssignmentID` / `GbkSave` | int/bit | Links score to gradebook |
| Scope: `StaffID` / `ClassID` / `ShareTests` | mixed | `ClassID` required |
| `ModifiedBy` / `ModifiedDate` | int/smalldatetime | Audit |

---

#### `dbo.WebTestsQuestions`
Questions for an online test — text, answer, points, type, up to 5 options, HTML flag. (`TestID` → `WebTestsConfig`.)

| Column | Type | Notes |
|---|---|---|
| `AutoNum` | int IDENTITY | PK |
| `TestID` / `Number` | int | → `WebTestsConfig`; order |
| `Question` / `Answer` / `QuestionType` / `Points` / `HTML` | mixed | — |
| `Option1`–`Option5` | nvarchar(max) | Choices |
| `ModifiedBy` / `ModifiedDate` | int/smalldatetime | Audit |

---

#### `dbo.WebTestsStudent`
A student's online-test attempt — start/end, finished, points earned, comments. (`TestID` → `WebTestsConfig`.)

| Column | Type | Notes |
|---|---|---|
| `AutoNum` | int IDENTITY | PK |
| `TestID` / `ClassID` / `StudentID` | int | The attempt |
| `StartTime` / `EndTime` / `Finished` / `PointsEarned` / `Comments` | mixed | Result |
| `ModifiedBy` / `ModifiedDate` | int/smalldatetime | Audit |

---

#### `dbo.WebTestsAnswers`
Per-question responses within an attempt — answer, points earned, correct flag, auto-graded flag, and per-answer staff feedback. FK `StaffID` → `Person`. (`TestID` → `WebTestsConfig`.)

| Column | Type | Notes |
|---|---|---|
| `AutoNum` | int IDENTITY | PK |
| `StudentID` / `TestID` / `Number` | int | The response; indexed |
| `Answer` / `PointsEarned` / `Correct` / `AutoGraded` | mixed | Scoring |
| `StaffID` | int | FK → `Person`; grader |
| `Feedback` / `FeedbackOn` / `Comments` | mixed | Per-answer feedback |
| `LastModified` / `ModifiedBy` / `ModifiedDate` | mixed | Audit |

> **Two online-test engines**: legacy `Survey*` (audience = staff/students/parents/families, survey-oriented) vs current `WebTests*` (class-scoped, gradebook-linked, auto-graded, with feedback). Plus the separate `aca`-bridged standardized-test model (`TestConfig`/`TestData`). Three distinct "test" systems.

> **End of the `dbo` schema.** This completes the alphabetical pass through `dbo` (the bulk of the database). Remaining tables belong to the specialized schemas (`enrl`, `facts`, and others already partly documented: `aca`, `cafe`, `cnfg`, `cnv`, `cr`, `crse`, `med`, `rw`, `ref`, `sched`, `prsn`).

---

### `enrl` schema — Ed-Fi student-school enrollment

The **`enrl`** schema holds the Ed-Fi-aligned student enrollment association (a more structured, descriptor-driven enrollment model than the legacy `Person_Student`). It coexists with `Person_Student`; `enrl.StudentSchoolAssociation` is the Ed-Fi representation used for state reporting.

#### `enrl.StudentSchoolAssociation`
Ed-Fi student↔school enrollment association — entry/exit, grade level, calendar, FTE, residency, graduation plan, and numerous Ed-Fi descriptors. FKs to `Person` (StudentID), `SchoolYear`, `cnfg.CalendarName`, `dbo.GradeLevels`. Unique on `(StudentID, EntryDate, GradeLevelID)`.

| Column group | Type | Notes |
|---|---|---|
| `StudentSchoolAssociationId` | int IDENTITY | PK |
| `StudentID` | int | FK → `Person`; indexed |
| `SchoolYearId` | int | FK → `SchoolYear`; indexed |
| `CalendarNameID` | int | FK → `cnfg.CalendarName`; indexed |
| `GradeLevelID` | int | FK → `dbo.GradeLevels`; indexed |
| `EntryDate` / `ExitWithdrawDate` | date | Enrollment span; unique with StudentID+GradeLevelID |
| Flags: `EmployedWhileEnrolled` / `PrimarySchool` / `RepeatGradeIndicator` / `SchoolChoiceTransfer` / `TermCompletionIndicator` / `SchoolChoice` | bit | — |
| Descriptors: `EntryGradeLevelReasonDescriptorId` / `EntryTypeDescriptorId` / `ExitWithdrawTypeDescriptorId` / `GraduationPlanTypeDescriptorId` / `ResidencyStatusDescriptorId` / `EnrollmentTypeDescriptorId` | uniqueidentifier | Ed-Fi descriptors |
| `FullTimeEquivalency` | decimal(9,4) | FTE |
| `ClassOfSchoolYear` / `GraduationSchoolYear` / `NextYearSchoolId` | mixed | — |

---

#### `enrl.StudentSchoolAssociationAlternativeGraduationPlan`
Alternative graduation plans on an enrollment association. FK → `enrl.StudentSchoolAssociation`. Unique on `(StudentSchoolAssociationID, AlternativeEducationOrganizationCode, AlternativeGraduationPlanTypeDescriptorID, AlternativeGraduationSchoolYear)`.

| Column | Type | Notes |
|---|---|---|
| `StudentSchoolAssociationAlternativeGraduationPlanID` | int IDENTITY | PK |
| `StudentSchoolAssociationID` | int | FK → `enrl.StudentSchoolAssociation` |
| `AlternativeEducationOrganizationCode` | nvarchar(60) | — |
| `AlternativeGraduationPlanTypeDescriptorID` | uniqueidentifier | Ed-Fi descriptor |
| `AlternativeGraduationSchoolYear` | smallint | — |

---

#### `enrl.StudentSchoolAssociationEducationPlan`
Education plans on an enrollment association. FK → `enrl.StudentSchoolAssociation`. Unique on `(StudentSchoolAssociationID, EducationPlanDescriptorID)`.

| Column | Type | Notes |
|---|---|---|
| `StudentSchoolAssociationEducationPlanID` | int IDENTITY | PK |
| `StudentSchoolAssociationID` | int | FK → `enrl.StudentSchoolAssociation` |
| `EducationPlanDescriptorID` | uniqueidentifier | Ed-Fi descriptor |

---

### `facts` schema — FACTS accounting/tuition integration

The **`facts`** schema is the FACTS (parent company) integration layer — the target of the `FactsUpdateState`/`facts.FamilyMapping.UpdateState` sync flags set by triggers throughout `dbo` (Person, Person_Family, Person_Staff, PersonPreferenceBit, etc.). It holds FACTS account/adjustment mappings and the automated-charge configuration for cafeteria and child-care billing. (`facts.FamilyMapping` itself — the most-referenced `facts` table — is not in this batch but is referenced extensively; see the FACTS sync triggers throughout `dbo`.)

#### `facts.Account`
Maps a FACTS general-ledger account — code, type, activity type, balance-tracking level. PK `AccountId`.

| Column | Type | Notes |
|---|---|---|
| `AccountId` | int IDENTITY | PK |
| `FactsAccountId` | nvarchar(20) | FACTS-side id |
| `Name` / `Code` / `Type` / `ActivityType` / `BalanceTrackingLevel` | nvarchar | Account detail |
| `SchoolCode` | nchar(50) | — |

> Note a self-referential FK on `AccountId` (constraint named `…dbo_AccountingSystem_AccountID`) — likely a schema artifact (no-op self-FK).

---

#### `facts.AdjustmentReason`
FACTS adjustment-reason mapping — code, type, reason text. PK `AdjustmentReasonID`.

| Column | Type | Notes |
|---|---|---|
| `AdjustmentReasonID` | int IDENTITY | PK |
| `FactsAdjustmentReasonID` | nvarchar(20) | FACTS-side id |
| `Code` / `Type` / `Reason` | nvarchar | — |
| `SchoolCode` | nchar(50) | — |

---

### `facts` automated-charge configuration (cafeteria & child-care)

Two parallel automated-charge subsystems push cafeteria and child-care charges to FACTS on a schedule. Each has a per-school config + a staff-notification list. Identical structure.

#### `facts.AutomatedCafeteriaChargeConfiguration`
Per-school automated-cafeteria-charge schedule — enable flag, days of week (bitmask 0–7), min/max days prior, time of day (UTC). PK `ConfigSchoolId`. FK → `ConfigSchool` (CASCADE) and `Person_Staff` (ModifiedBy). Several CHECK constraints enforce day/range bounds (incl. `MaxDaysPrior > MinDaysPrior`).

| Column | Type | Notes |
|---|---|---|
| `ConfigSchoolId` | smallint | PK; FK → `dbo.ConfigSchool` (CASCADE) |
| `EnableAutomation` | bit | Default 0 |
| `DaysOfWeek` | tinyint | CHECK 0–7; default 1 |
| `MinDaysPrior` / `MaxDaysPrior` | tinyint | CHECK 0–60; Max > Min |
| `TimeOfDayUtc` | time | Default UTC now |
| `ModifiedBy` | int | FK → `Person_Staff` |
| `ModifiedUTC` | datetime2 | — |

---

#### `facts.AutomatedCafeteriaChargeConfigurationStaff`
Staff notification list for cafeteria-charge automation. PK is composite `(ConfigSchoolId, StaffId)`. FKs → the config (CASCADE) and `Person_Staff` (CASCADE).

| Column | Type | Notes |
|---|---|---|
| `ConfigSchoolId` | smallint | PK (composite); FK → config (CASCADE) |
| `StaffId` | int | PK (composite); FK → `Person_Staff` (CASCADE) |

---

#### `facts.AutomatedChildCareChargeConfiguration`
Per-school automated-child-care-charge schedule — identical structure to the cafeteria config (enable, days-of-week bitmask, min/max days prior, time of day, same CHECK constraints). PK `ConfigSchoolId`. FK → `ConfigSchool` (CASCADE) and `Person_Staff`.

| Column | Type | Notes |
|---|---|---|
| `ConfigSchoolId` | smallint | PK; FK → `dbo.ConfigSchool` (CASCADE) |
| `EnableAutomation` / `DaysOfWeek` / `MinDaysPrior` / `MaxDaysPrior` / `TimeOfDayUtc` | mixed | Same as cafeteria config |
| `ModifiedBy` / `ModifiedUTC` | mixed | FK → `Person_Staff` |

---

#### `facts.AutomatedChildCareChargeConfigurationStaff`
Staff notification list for child-care-charge automation. PK is composite `(ConfigSchoolId, StaffId)`. FKs → the config (CASCADE) and `Person_Staff` (CASCADE).

| Column | Type | Notes |
|---|---|---|
| `ConfigSchoolId` | smallint | PK (composite); FK → config (CASCADE) |
| `StaffId` | int | PK (composite); FK → `Person_Staff` (CASCADE) |

---

#### `dbo` Web / `enrl` / `facts` — cross-reference summary

| Table | Schema | Scope / notes |
|---|---|---|
| `WebOrder` | dbo | Online-store order header; JSON payload |
| `WebOrderItems` | dbo | Order line items; PK `(OrderID, StudentID, ItemID, Date)` |
| `WebTestsConfig` | dbo | Online-test def (current); gradebook-linked |
| `WebTestsQuestions` | dbo | Test questions |
| `WebTestsStudent` | dbo | Test attempt |
| `WebTestsAnswers` | dbo | Per-question responses; feedback; → `Person` |
| `StudentSchoolAssociation` | enrl | **Ed-Fi enrollment**; → `Person`, `SchoolYear`, `cnfg.CalendarName`, `GradeLevels` |
| `StudentSchoolAssociationAlternativeGraduationPlan` | enrl | Alt grad plans |
| `StudentSchoolAssociationEducationPlan` | enrl | Education plans |
| `Account` | facts | FACTS GL account map |
| `AdjustmentReason` | facts | FACTS adjustment-reason map |
| `AutomatedCafeteriaChargeConfiguration` | facts | Auto cafeteria-charge schedule; → `ConfigSchool` |
| `AutomatedCafeteriaChargeConfigurationStaff` | facts | Cafeteria notify list |
| `AutomatedChildCareChargeConfiguration` | facts | Auto child-care-charge schedule |
| `AutomatedChildCareChargeConfigurationStaff` | facts | Child-care notify list |

---

### `facts` schema — FamilyMapping (keystone), outgoing/charge batches, email reminders, course fees

#### `facts.FamilyMapping`
**The keystone FACTS-integration table** — maps a RenWeb family to a FACTS customer (person) per FACTS institution, and carries the `UpdateState` flag. **This is the table whose `UpdateState` is set to 1 by FACTS-sync triggers throughout `dbo`** (Person, Person_Family, Person_Staff, PersonPreferenceBit, address/email changes, etc.) to mark a family as needing re-sync to FACTS. Resolves the single most-referenced cross-schema reference in the catalog.

| Column | Type | Notes |
|---|---|---|
| `FamilyMappingID` | int IDENTITY | PK |
| `FamilyID` | int | FK → `dbo.FamilyConfig` (CASCADE); indexed |
| `CustomerPersonID` | int | FK → `dbo.Person` (CASCADE); the FACTS customer; indexed |
| `InstitutionID` | int | FACTS institution; default 0; unique with FamilyID |
| `UpdateState` | tinyint | **0 = synced, 1 = needs update** (set by `dbo` triggers) |

> The `dbo.FamilyConfig.FactsUpdateState` + `facts.FamilyMapping.UpdateState` pair is the FACTS dirty-flag mechanism: when family-related data changes in `dbo`, triggers set these to 1; a sync process reads them, pushes to FACTS, and resets. Note `FamilyConfig.FactsCustomerPersonID` is the older single-institution mapping; `FamilyMapping` is the newer multi-institution model (unique on `(FamilyID, InstitutionID)`).

---

#### `facts.FamilyUpdateError`
FACTS family-sync error log — error message/details per person/family/institution. Records failures from the FACTS sync process.

| Column | Type | Notes |
|---|---|---|
| `FamilyUpdateErrorID` | bigint IDENTITY | PK |
| `PersonID` | int | FK → `Person` (CASCADE) |
| `FamilyID` | int | FK → `FamilyConfig` (CASCADE) |
| `ErrorMessage` / `ErrorDetails` | nvarchar(max) | The error |
| `SchoolCode` / `InstitutionId` | mixed | Scope |

---

### `facts` outgoing/charge batch pipeline

The charge pipeline pushes charges to FACTS in batches: `facts.ChargeBatch` (a batch header) → `facts.ChargeBatchDetail` (per-family/person amounts); `facts.OutgoingBatch` tracks the batch's submission to FACTS (status lifecycle).

#### `facts.OutgoingBatch`
Tracks a batch's transmission to FACTS — term code, FACTS batch id/post time, status (CREATED→…), charge source, institution. FK `ModifiedBy` → `Person_Staff`.

| Column | Type | Notes |
|---|---|---|
| `OutgoingBatchId` | int IDENTITY | PK |
| `TermCode` | nvarchar(50) | FACTS term |
| `FactsBatchId` / `FactsBatchPostDateTime` | mixed | FACTS-side batch |
| `BatchStatus` | nvarchar(32) | Default 'CREATED' |
| `SendChangeNotice` / `ChargeSource` / `FactsInstitutionId` | mixed | — |
| `ModifiedBy` | int | FK → `Person_Staff` (SET NULL) |
| `ModifiedDateTime` | smalldatetime | — |

---

#### `facts.ChargeBatch`
A batch of charges to send to FACTS — description, term/account/activity/adjustment codes, student-vs-family target (CHECK), transaction/invoice dates, invoice message. PK `ChargeBatchId`.

| Column | Type | Notes |
|---|---|---|
| `ChargeBatchId` | int IDENTITY | PK |
| `Description` / `TermCode` / `AccountCode` / `ActivityType` / `AdjustmentReasonCode` | nvarchar | Batch metadata |
| `StudentFamily` | nvarchar(50) | CHECK {FAMILY, STUDENT} |
| `TransactionDate` / `InvoiceSendDate` / `InvoiceDueDate` / `InvoiceMessage` | mixed | Invoicing |
| `FactsBatchId` / `FactsBatchPostDateTime` | mixed | FACTS-side |
| `ConfigSchoolId` | smallint | Default 0 |

---

#### `facts.ChargeBatchDetail`
Per-family/person charge lines within a batch — amount, source, description. FKs to `ChargeBatch` (CASCADE), `Person`, `FamilyConfig`.

| Column | Type | Notes |
|---|---|---|
| `ChargeBatchDetailId` | int IDENTITY | PK |
| `ChargeBatchId` | int | FK → `ChargeBatch` (CASCADE) |
| `PersonId` | int | FK → `Person` |
| `FamilyId` | int | FK → `FamilyConfig` |
| `Amount` | decimal(19,4) | — |
| `ChargeSource` / `Description` | nvarchar | — |

---

### `facts` automated-charge & email-reminder configuration (continued)

Joining the cafeteria/child-care automated-charge configs from the previous batch, these cover **automated recurring charges** and the **email-reminder** subsystem. The reminder config drives four reminder types, each with its own per-school staff-notification list.

#### `facts.AutomatedRecurringChargeConfiguration`
Per-school automated-recurring-charge enable. PK `ConfigSchoolId`. FK → `ConfigSchool` (CASCADE), `Person_Staff` (ModifiedBy).

| Column | Type | Notes |
|---|---|---|
| `ConfigSchoolId` | smallint | PK; FK → `dbo.ConfigSchool` (CASCADE) |
| `EnableAutomation` | bit | Default 0 |
| `ModifiedBy` / `ModifiedUTC` | mixed | FK → `Person_Staff` |

---

#### `facts.AutomatedRecurringChargeConfigurationStaff`
Staff notification list for recurring-charge automation. PK `(ConfigSchoolId, StaffId)`. FKs → config (CASCADE), `Person_Staff` (CASCADE).

| Column | Type | Notes |
|---|---|---|
| `ConfigSchoolId` / `StaffId` | mixed | PK (composite); both CASCADE FKs |

---

#### `facts.AutomatedEmailReminderConfiguration`
Per-school email-reminder config — toggles + frequency (CHECK 0–2, recurring 1–2) for four reminder types: invalid transactions, recurring charges, families-with-errors, financial-responsibility errors. PK `ConfigSchoolId`. FK → `ConfigSchool` (CASCADE), `Person_Staff`. Parent of the four staff-list tables below.

| Column group | Type | Notes |
|---|---|---|
| `ConfigSchoolId` | smallint | PK; FK → `dbo.ConfigSchool` (CASCADE) |
| Invalid txns: `SendInvalidTransactionsReminder` / `InvalidTransactionsFrequency` | bit/tinyint | CHECK 0–2 |
| Recurring: `SendRecurringChargesReminder` / `RecurringChargesFrequency` | bit/tinyint | CHECK 1–2; default 1 |
| Families w/ errors: `SendFamiliesWithErrorsReminder` / `FamiliesWithErrorsFrequency` | bit/tinyint | CHECK 0–2 |
| Fin. responsibility: `SendFinancialResponsibilityErrorsReminder` / `FinancialResponsibilityErrorsFrequency` | bit/tinyint | CHECK 0–2 |
| `ModifiedBy` / `ModifiedUTC` | mixed | FK → `Person_Staff` |

---

The four reminder staff-notification lists — all identical structure (PK `(ConfigSchoolId, StaffId)`, FK → `AutomatedEmailReminderConfiguration` CASCADE + `Person_Staff` CASCADE), one per reminder type:

#### `facts.AutomatedEmailInvalidtransactionsStaff`
Staff notified of invalid-transaction reminders.

| Column | Type | Notes |
|---|---|---|
| `ConfigSchoolId` / `StaffId` | mixed | PK (composite); → reminder config + `Person_Staff` |

#### `facts.AutomatedEmailRecurringChargesStaff`
Staff notified of recurring-charge reminders.

| Column | Type | Notes |
|---|---|---|
| `ConfigSchoolId` / `StaffId` | mixed | PK (composite); → reminder config + `Person_Staff` |

#### `facts.AutomatedEmailFamiliesWithErrorsStaff`
Staff notified of families-with-errors reminders.

| Column | Type | Notes |
|---|---|---|
| `ConfigSchoolId` / `StaffId` | mixed | PK (composite); → reminder config + `Person_Staff` |

#### `facts.AutomatedEmailFinancialResponsibilityErrorsStaff`
Staff notified of financial-responsibility-error reminders.

| Column | Type | Notes |
|---|---|---|
| `ConfigSchoolId` / `StaffId` | mixed | PK (composite); → reminder config + `Person_Staff` |

---

### `facts` course-fee subsystem

Course-based fees that flow into FACTS billing: `facts.CourseFeeType` (fee-type def per school) → `facts.CourseFee` (a fee on a course) → `facts.CourseFeeCharge` (the fee applied to a student×class). Both `CourseFee` and `CourseFeeCharge` have triggers enforcing school/course consistency. (Distinct from the earlier `acct.CourseFees` — this is the FACTS-integrated version.)

#### `facts.CourseFeeType`
Fee-type definition per school — name, FACTS account/adjustment-reason, activity type. PK `CourseFeeTypeId`. Unique on `(FeeTypeName, ConfigSchoolId)`. FK → `ConfigSchool` (CASCADE), `Person`.

| Column | Type | Notes |
|---|---|---|
| `CourseFeeTypeId` | int IDENTITY | PK |
| `FeeTypeName` | nvarchar(50) | Unique within school |
| `AccountId` / `AdjustmentReasonId` | bigint | FACTS account/reason |
| `AccountActivityTypeId` | tinyint | CHECK {0,1,2,3} |
| `ConfigSchoolId` | smallint | FK → `dbo.ConfigSchool` (CASCADE) |
| `ModifiedById` / `ModifiedUTC` | mixed | FK → `Person` |

---

#### `facts.CourseFee`
A fee on a course — amount, interval, fee type. PK `CourseFeeId`. Unique on `(CourseId, CourseFeeTypeId)`. FKs → `crse.CourseCore`, `facts.CourseFeeType` (CASCADE), `Person`.

| Column | Type | Notes |
|---|---|---|
| `CourseFeeId` | int IDENTITY | PK |
| `CourseId` | int | FK → `crse.CourseCore`; unique with FeeType |
| `CourseFeeTypeId` | int | FK → `facts.CourseFeeType` (CASCADE) |
| `Amount` | decimal(19,4) | — |
| `Interval` | tinyint | Default 0 |
| `ModifiedById` / `ModifiedUTC` | mixed | FK → `Person` |

**Trigger** `TR_facts_CourseFee_UI` (AFTER UPDATE, INSERT): enforces that the course's school (`Courses`→`ConfigSchool`) matches the fee-type's `ConfigSchoolId` — RAISERROR + ROLLBACK on mismatch. (Cross-references `dbo.Courses` — the current courses table.)

---

#### `facts.CourseFeeCharge`
A course fee applied to a specific student×class (optionally per semester/term) — amount. PK `CourseFeeChargeId`. Unique on `(CourseFeeId, StudentId, ClassId, SemesterId, TermId)`. FKs → `Person`, `Roster` (StudentId+ClassId, CASCADE), `facts.CourseFee`.

| Column | Type | Notes |
|---|---|---|
| `CourseFeeChargeId` | int IDENTITY | PK |
| `CourseFeeId` | int | FK → `facts.CourseFee`; indexed |
| `StudentId` | int | FK → `Person`; with ClassId → `Roster` (CASCADE) |
| `ClassId` | int | Part of `Roster` FK |
| `SemesterId` / `TermId` | int | CHECK 0–3 / 0–6 |
| `Amount` | decimal(19,4) | — |

**Trigger** `TR_facts_CourseFeeCharge_UI` (AFTER UPDATE, INSERT): enforces that the class's `CourseID` (`Classes`) matches the fee's `CourseId` (`CourseFee`) — RAISERROR + ROLLBACK on mismatch.

---

#### `facts` schema (batch 2) — cross-reference summary

| Table | Scope | Key FK targets / notes |
|---|---|---|
| `FamilyMapping` | **Family↔FACTS customer map** | **Keystone**; `UpdateState` set by `dbo` triggers; → `Person`, `FamilyConfig` |
| `FamilyUpdateError` | FACTS sync error log | → `Person`, `FamilyConfig` |
| `OutgoingBatch` | Batch transmission tracking | → `Person_Staff`; status lifecycle |
| `ChargeBatch` | Charge batch header | CHECK {FAMILY, STUDENT} |
| `ChargeBatchDetail` | Charge batch lines | → `ChargeBatch`, `Person`, `FamilyConfig` |
| `AutomatedRecurringChargeConfiguration` | Auto recurring-charge enable | → `ConfigSchool` |
| `AutomatedRecurringChargeConfigurationStaff` | Recurring-charge notify list | PK `(ConfigSchoolId, StaffId)` |
| `AutomatedEmailReminderConfiguration` | Email-reminder config (4 types) | → `ConfigSchool`; parent of 4 staff lists |
| `AutomatedEmailInvalidtransactionsStaff` | Invalid-txn notify list | → reminder config |
| `AutomatedEmailRecurringChargesStaff` | Recurring-charge notify list | → reminder config |
| `AutomatedEmailFamiliesWithErrorsStaff` | Families-with-errors notify list | → reminder config |
| `AutomatedEmailFinancialResponsibilityErrorsStaff` | Fin-responsibility-error notify list | → reminder config |
| `CourseFeeType` | Course-fee-type def | → `ConfigSchool`; FACTS account/reason |
| `CourseFee` | Fee on a course | → `crse.CourseCore`; school-consistency trigger |
| `CourseFeeCharge` | Fee applied to student×class | → `Roster`, `CourseFee`; course-consistency trigger |

---

### `facts` outgoing-transaction pipeline, `facts.PersonFamily`, then `ib` and `gi` schemas

### `facts` outgoing-transaction layer

Beneath the batch layer (`OutgoingBatch`/`ChargeBatch` from prior batches), the **OutgoingTransaction** layer holds individual transactions and their batch linkage, with creation-time and post-time error tables. Flow: `OutgoingBatch` → `OutgoingTransaction` (individual charges) → linked via `OutgoingBatchTransactionMM`; subtype tables `OutgoingBatchPaymentPlan`/`OutgoingBatchIncidental` extend a batch; errors captured at creation (`OutgoingTransactionCreationError`) and post (`OutgoingTransactionPostError`).

#### `facts.OutgoingTransaction`
An individual transaction within an outgoing batch — customer/student/person, account/adjustment codes, amount, charge source, agreement number. FK → `OutgoingBatch` (CASCADE), `Person` (SET NULL).

| Column | Type | Notes |
|---|---|---|
| `OutgoingTransactionId` | int IDENTITY | PK |
| `OutgoingBatchId` | int | FK → `OutgoingBatch` (CASCADE) |
| `TransactionDate` | date | — |
| `CustomerId` / `StudentId` | nvarchar | FACTS-side ids |
| `AccountCode` / `AdjustmentCode` / `ChargeSource` / `AgreementNumber` | nvarchar | Transaction coding |
| `Amount` | decimal(19,4) | — |
| `Description` | nvarchar(200) | Default '' |
| `PersonId` | int | FK → `Person` (SET NULL) |

---

#### `facts.OutgoingBatchTransactionMM`
Links outgoing transactions to batches (many-to-many, with parent-batch and error flag). PK is composite `(OutgoingBatchId, OutgoingTransactionId)`. FKs → `OutgoingBatch` (×2: batch + parent), `OutgoingTransaction`, `Person` (CreatedBy, SET NULL).

| Column | Type | Notes |
|---|---|---|
| `OutgoingBatchId` / `OutgoingTransactionId` | int | PK (composite); FKs |
| `ParentBatchId` | int | FK → `OutgoingBatch` |
| `CreatedDate` / `CreatedBy` | mixed | `CreatedBy` → `Person` (SET NULL) |
| `HasError` / `TransactionDate` | mixed | — |

> Note the PK constraint is misnamed `PK_dbo_ChargesErrorMM_ChargeIDErrorCheckID` (copy-paste artifact from a different table).

---

#### `facts.OutgoingBatchPaymentPlan`
Payment-plan subtype of an outgoing batch — finalize + apply-increase/decrease options. PK `OutgoingBatchId` (1:1 with `OutgoingBatch`, CASCADE).

| Column | Type | Notes |
|---|---|---|
| `OutgoingBatchId` | int | PK; FK → `OutgoingBatch` (CASCADE) |
| `Finalized` / `ApplyIncreasesInd` / `ApplyDecreasesInd` / `ApplyIncreasesToPaymentDate` / `SendChangeNotice` | mixed | Plan options |

---

#### `facts.OutgoingBatchIncidental`
Incidental-charge subtype of an outgoing batch — invoice generation/due dates, message, partial-payment + decrease options. PK `OutgoingBatchId` (1:1, CASCADE). (Source file named `OutgoingIncidentalBatch.sql` but the table is `OutgoingBatchIncidental`.)

| Column | Type | Notes |
|---|---|---|
| `OutgoingBatchId` | int | PK; FK → `OutgoingBatch` (CASCADE) |
| `InvoiceGenerationDate` / `InvoiceDueDate` / `InvoiceMessage` | mixed | Invoicing |
| `AllowPartialPayment` (default 1) / `ApplyDecreaseOption` | bit | — |

---

#### `facts.OutgoingTransactionCreationError`
Errors encountered while *creating* outgoing transactions — full charge context (person/family, codes, amount) so the transaction can be re-attempted. Self-referencing (parent error). CHECK requires Person or Family. FKs → `OutgoingBatch`/`Person`/`FamilyConfig` (CASCADE).

| Column group | Type | Notes |
|---|---|---|
| `OutgoingTransactionCreationErrorId` | int IDENTITY | PK |
| `OutgoingBatchId` | int | FK → `OutgoingBatch` (CASCADE); indexed |
| `ParentOutgoingTransactionCreationErrorId` | int | Self-FK |
| `PersonId` / `FamilyId` | int | CHECK coalesce NOT NULL; both CASCADE FKs; indexed |
| Charge context: `TermCode` / `AccountCode` / `AdjustmentReasonCode` / `Amount` / `ChargeSource` / `Description` / `EntityCharged` / `TransactionDate` | mixed | For repost |
| Error: `ErrorDate` / `ErrorMessage` / `ErrorDetails` / `Processed` | mixed | — |
| `ModifiedBy` / `ModifiedDateTime` | mixed | Audit |

> Indexes use `DATA_COMPRESSION = PAGE`. (Note: an ALTER references a `Deleted` default column not present in the CREATE — a schema-drift artifact.)

---

#### `facts.OutgoingTransactionPostError`
Errors returned from FACTS Enterprise when *posting* a transaction (Story/55416). PK is composite `(OutgoingBatchId, OutgoingTransactionId)`. FKs → `OutgoingBatch` (CASCADE), `OutgoingTransaction`, `Person_Staff` (ModifiedBy).

| Column | Type | Notes |
|---|---|---|
| `OutgoingBatchId` / `OutgoingTransactionId` | int | PK (composite); FKs |
| `ErrorMessage` / `ErrorDetails` / `Processed` | mixed | The post error |
| `ModifiedBy` | int | FK → `Person_Staff` |
| `ModifiedDateTime` | smalldatetime | — |

> Note: an ALTER references a `Deleted` default column not present in the (absent) CREATE.

---

#### `facts.TransactionError`
Holds FACTS transaction errors with data to re-post (Story/9000). **Source file contains only `ALTER`/default statements — the `CREATE TABLE` is not in the provided DDL**, so columns are inferred from the defaults: `Processed`, `ErrorType`, `Deleted`, `StudentCharge` (all bit/int, default 0). The general FACTS transaction-error/repost holding table (older than the `OutgoingTransaction*Error` tables).

| Column (inferred from defaults) | Type | Notes |
|---|---|---|
| `Processed` | bit | Default 0 |
| `ErrorType` | int | Default 0 |
| `Deleted` | bit | Default 0 |
| `StudentCharge` | bit | Default 0; marks student-charge errors |

> **Documentation note:** the full column list isn't available (CREATE missing from the source file); only the defaulted columns are known. If the complete DDL surfaces later, this entry should be expanded.

---

#### `facts.PersonFamily`
FACTS-side person↔family financial mapping — per institution + account code, with financial-responsibility percent. PK is composite `(PersonID, FamilyID, FactsInstitutionID, FactsAccountCode)`. FKs → `Person`, `FamilyConfig`. (The FACTS counterpart to `dbo.Person_Family`, adding institution/account/responsibility-percent.)

| Column | Type | Notes |
|---|---|---|
| `PersonID` / `FamilyID` | int | PK (composite); FKs → `Person`, `FamilyConfig` |
| `FactsInstitutionID` | int | PK (composite); default 0 |
| `FactsAccountCode` | nvarchar(50) | PK (composite); default '' |
| `FinancialResponsibilityPercent` | decimal(9,4) | — |

---

### `ib` schema — International Baccalaureate

#### `ib.AssessmentGradeBoundary`
IB assessment grade boundaries per department — the score range (`FromBoundary`–`ToBoundary`) for each IB grade. PK is composite `(Department, Grade)`.

| Column | Type | Notes |
|---|---|---|
| `Department` | nvarchar(50) | PK (composite) |
| `Grade` | int | PK (composite); IB grade (e.g. 1–7) |
| `FromBoundary` / `ToBoundary` | int | Score range for the grade |

---

### `gi` schema — Google Integration

The **`gi`** schema integrates with Google Workspace (Calendar + user/domain provisioning). `gi.Domain` defines a Google domain (with service credentials); `gi.SchoolGoogleDomainMM` maps schools to domains; `gi.StaffDomainGoogleUser`/`gi.StudentDomainGoogleUser` map people to their Google accounts; `gi.CalendarApiKey`/`gi.CalendarGroup` handle Google Calendar integration.

> **Contains credentials** — `gi.Domain.Sacreds` (service credentials/secrets) and `GoogleApiKey`. Treat as sensitive.

#### `gi.Domain`
A Google Workspace domain — domain name, service credentials (`Sacreds`), default user. PK `GoogleDomainId`. Unique on `GoogleDomain`.

| Column | Type | Notes |
|---|---|---|
| `GoogleDomainId` | int IDENTITY | PK |
| `GoogleDomain` | nvarchar(450) | Domain; unique |
| `Sacreds` | nvarchar(max) | **Service credentials/secrets** |
| `DefaultGoogleUser` | nvarchar(max) | Default impersonation user |

---

#### `gi.SchoolGoogleDomainMM`
Maps schools to Google domains. PK is composite `(GoogleDomainId, ConfigSchoolId)`. FKs → `ConfigSchool`, `gi.Domain`.

| Column | Type | Notes |
|---|---|---|
| `GoogleDomainId` / `ConfigSchoolId` | mixed | PK (composite); FKs |

---

#### `gi.StaffDomainGoogleUser`
Maps a staff person to their Google account within a domain. PK is composite `(PersonId, GoogleDomainId)`. Unique on `(GoogleDomainId, GoogleUserEmail)`. FKs → `Person` (CASCADE), `gi.Domain`.

| Column | Type | Notes |
|---|---|---|
| `PersonId` / `GoogleDomainId` | int | PK (composite) |
| `GoogleUserId` / `GoogleUserEmail` | nvarchar | Google account |

---

#### `gi.StudentDomainGoogleUser`
Maps a student person to their Google account within a domain. Identical structure to the staff version. PK `(PersonId, GoogleDomainId)`; unique `(GoogleDomainId, GoogleUserEmail)`. FKs → `Person` (CASCADE), `gi.Domain`.

| Column | Type | Notes |
|---|---|---|
| `PersonId` / `GoogleDomainId` | int | PK (composite) |
| `GoogleUserId` / `GoogleUserEmail` | nvarchar | Google account |

---

#### `gi.CalendarApiKey`
Google Calendar API key per school. PK `CalendarApiKeyId`.

| Column | Type | Notes |
|---|---|---|
| `CalendarApiKeyId` | int IDENTITY | PK |
| `SchoolId` | int | The school |
| `GoogleApiKey` | nvarchar(64) | **API key — sensitive** |

---

#### `gi.CalendarGroup`
Google Calendar group(s) under an API key. PK `CalendarGroupId`. FK → `gi.CalendarApiKey` (CASCADE).

| Column | Type | Notes |
|---|---|---|
| `CalendarGroupId` | int IDENTITY | PK |
| `CalendarApiKeyId` | int | FK → `gi.CalendarApiKey` (CASCADE) |
| `GoogleGroupId` | varchar(4000) | Google group id |

---

#### `facts` (txn pipeline) / `ib` / `gi` — cross-reference summary

| Table | Schema | Scope / notes |
|---|---|---|
| `OutgoingTransaction` | facts | Individual outgoing transaction; → `OutgoingBatch`, `Person` |
| `OutgoingBatchTransactionMM` | facts | Batch↔transaction link (PK misnamed) |
| `OutgoingBatchPaymentPlan` | facts | Payment-plan batch subtype |
| `OutgoingBatchIncidental` | facts | Incidental-charge batch subtype (file misnamed) |
| `OutgoingTransactionCreationError` | facts | Creation errors (repost context); self-FK |
| `OutgoingTransactionPostError` | facts | Post errors from FACTS Enterprise |
| `TransactionError` | facts | Repost holding table (**CREATE missing from source**) |
| `PersonFamily` | facts | FACTS person↔family financial map; cf. `dbo.Person_Family` |
| `AssessmentGradeBoundary` | ib | IB grade boundaries; PK `(Department, Grade)` |
| `Domain` | gi | Google domain; **credentials** |
| `SchoolGoogleDomainMM` | gi | School↔Google domain |
| `StaffDomainGoogleUser` | gi | Staff↔Google account |
| `StudentDomainGoogleUser` | gi | Student↔Google account |
| `CalendarApiKey` | gi | Google Calendar API key; **sensitive** |
| `CalendarGroup` | gi | Google Calendar group |

---

### `ib` schema (continued) — diploma & criterion grading

#### `ib.DiplomaCourses`
IB Diploma Programme course catalog — the set of IB diploma subjects. PK `IBCourseID`.

| Column | Type | Notes |
|---|---|---|
| `IBCourseID` | int IDENTITY | PK |
| `Title` | nvarchar(50) | Subject title |

---

#### `ib.DiplomaGrades`
Per-student IB diploma grades — up to three predicted grades + final, per IB course per year. PK is composite `(IBCourseID, StudentID)`. FKs → `SchoolYear`, `Person`.

| Column | Type | Notes |
|---|---|---|
| `IBCourseID` / `StudentID` | int | PK (composite); → `DiplomaCourses` (logical), `Person` |
| `SchoolYearID` | int | FK → `SchoolYear` |
| `PredictedGrade1`–`PredictedGrade3` / `FinalGrade` | int | IB grades |

---

#### `ib.CriterionMaxAchievementLevel`
Max achievement level per IB assessment criterion per department (MYP-style criterion grading). PK is composite `(Criterion, Department)`.

| Column | Type | Notes |
|---|---|---|
| `Criterion` | nvarchar(1) | PK (composite); criterion letter (A–D…) |
| `Department` | nvarchar(50) | PK (composite) |
| `MaxAchievementLevel` | int | Cap for the criterion |

> Together with `ib.AssessmentGradeBoundary` (prior batch), the `ib` schema supports both IB Diploma grading (boundaries + predicted/final grades) and MYP criterion-based grading (criterion max levels).

---

### `lib` schema — library / media center

The **`lib`** schema is a complete library-management subsystem: MARC-based cataloging (`Catalog` + `CatalogDataField` + `CatalogSubField`), physical copies (`Inventory`), circulation (`CirculationHistory` + `CirculationType`), patrons (`PatronGroup` + `PatronGroupCirculationType`), reservations (`Reservation`), and import/conversion utilities. A full-text-style `lib.SearchCatalog` table (not in this batch) is maintained automatically by triggers on `Catalog` and `CatalogSubField`.

#### `lib.Catalog`
**The bibliographic catalog record** (one per title) — MARC-derived bibliographic fields (title, author, publisher, ISBN/LCCN, Dewey, call number, series, etc.), reading/interest levels, the raw `MarcRecord`, and an `IsActive` flag (kept in sync by `Inventory` triggers). PK `CatalogID`. FKs → `DefinedLists` (SubCategory), `lib.CirculationType`, `lib.ImportFile` (SET NULL / UPDATE CASCADE).

| Column group | Type | Notes |
|---|---|---|
| `CatalogID` | int IDENTITY | PK |
| `ConfigSchoolID` | smallint | School |
| Bibliographic: `Title` / `SubTitle` / `Author` / `Illustrator` / `Publisher` / `PublisherPlace` / `PublishYear` / `Edition` / `Volume` / `Series` / `Pages` / `Size` | nvarchar | — |
| Identifiers: `LCCN` / `CallNumber` / `DeweyDecimal` / `Control001` / `Control003` | mixed | — |
| MARC: `MarcRecord` / `MarcLeader` / `NonFilingCharacters` / `StatementOfResponsibility` | mixed | Raw MARC |
| Classification: `CategoryListID` / `SubCategoryListID` / `PhysicalTypeListID` / `FormatListID` / `Format` | mixed | FK SubCategory → `DefinedLists` |
| Levels: `ReadingLevel` / `InterestLevel` / `StudyProgram` / `TargetAudience` / `Points` | mixed | AR-style |
| `CirculationTypeID` | int | FK → `lib.CirculationType` |
| `IsActive` | bit | **Synced by `Inventory` triggers** |
| `ImportFileID` / `OpenLibraryCoverID` / `OtherDetail` | mixed | Import / cover art |

**Triggers** (maintain the `lib.SearchCatalog` full-text index):
- `trig_Catalog_Insert` (AFTER INSERT): inserts search rows for Title+SubTitle (type −5), LCCN (−6), Series (−2), Author (−1).
- `trig_Catalog_Update` (AFTER UPDATE): updates the corresponding search rows when those fields change.
- `trig_Catalog_Delete` (AFTER DELETE): removes the catalog's search rows.

---

#### `lib.CatalogDataField`
MARC data fields for a catalog record — tag + two indicators. PK `CatalogDataFieldID`. FK → `lib.Catalog` (CASCADE). Indexed `(CatalogID, Tag)`.

| Column | Type | Notes |
|---|---|---|
| `CatalogDataFieldID` | int IDENTITY | PK |
| `CatalogID` | int | FK → `lib.Catalog` (CASCADE) |
| `Tag` | char(3) | MARC tag (e.g. 650, 020) |
| `Indicator1` / `Indicator2` | char(1) | MARC indicators |

---

#### `lib.CatalogSubField`
MARC subfields within a data field — code + value. PK `CatalogSubFieldID`. FK → `lib.CatalogDataField` (CASCADE). Indexed `(CatalogDataFieldID, Code)`.

| Column | Type | Notes |
|---|---|---|
| `CatalogSubFieldID` | int IDENTITY | PK |
| `CatalogDataFieldID` | int | FK → `lib.CatalogDataField` (CASCADE) |
| `Code` | char(1) | MARC subfield code |
| `DataField` | nvarchar(4000) | Subfield value |
| `AdditionalInfo` | nvarchar(256) | e.g. ISBN for tag 020 |

**Triggers** (maintain `lib.SearchCatalog`):
- `trig_CatalogSubField_Insert`: indexes subject subfields (tags 600/610/611/630/650/651/655, code 'a' → type −4) and ISBN (tag 020, code 'a' → type −3).
- `trig_CatalogSubField_Update`: updates the corresponding search rows when `DataField` changes.
- `trig_CatalogSubField_Delete`: removes the subfield's search rows.

---

#### `lib.Inventory`
**Physical copies** of a catalog title — barcode, copy number, costs, location, status, inventory/inactive tracking. PK `InventoryID`. FKs → `lib.Catalog`, `lib.ImportFile` (SET NULL/UPDATE CASCADE), `DefinedLists` (Library, Vendor).

| Column group | Type | Notes |
|---|---|---|
| `InventoryID` | int IDENTITY | PK |
| `CatalogID` | int | FK → `lib.Catalog` |
| `Barcode` / `CopyNumber` / `CallNumber` / `DeweyDecimal` / `ItemLocation` | mixed | Copy identity |
| Costs: `PublisherCost` / `PurchaseCost` / `ReplacementCost` | mixed | — |
| `VendorID` / `LibraryListID` | int | FKs → `DefinedLists` |
| Status: `StatusID` / `InactiveReasonListID` / `InactiveNote` / `InactiveDate` / `InactiveByPersonID` | mixed | `StatusID = -13` ⇒ inactive |
| Audit: `CreateDate` / `ModifyDate` / `CreatedByPersonID` / `ModifiedByPersonID` / `InventoryDate` / `InventoriedByPersonID` | mixed | — |
| Notes: `LibrarianNote` / `CirculationNote` | nvarchar(1024) | — |
| Links: `ReservationID` / `ImportFileID` / `BarcodeBatchID` / `CirculationHistoryID` / `LegacyBookID` | int | — |

**Triggers** (keep `Catalog.IsActive` in sync):
- `TR_lib_Inventory_Del` (AFTER DELETE) and `TR_lib_Inventory_InsUpd` (AFTER INSERT, UPDATE — only when `StatusID` changes): set `Catalog.IsActive = 1` if the title has any non-inactive copy (`StatusID <> -13`), else 0.

---

#### `lib.CirculationHistory`
Check-out/return history — per person×inventory item, due/return dates, overdue days, late fee, renewals. PK `CirculationHistoryID`. FK → `lib.Inventory`.

| Column | Type | Notes |
|---|---|---|
| `CirculationHistoryID` | int IDENTITY | PK |
| `PersonID` | int | The patron |
| `InventoryID` | int | FK → `lib.Inventory` |
| `CheckOutDate` / `DueDate` / `ReturnDate` | smalldatetime | Loan span |
| `DaysOverdue` / `LateFee` / `LateFeeProcessed` / `TimesRenewed` | mixed | Overdue/fine |
| `CreateDate` / `ModifyDate` | smalldatetime | Audit |

---

#### `lib.CirculationType`
Circulation-rule type — default loan period, grace, checkout limit, renewals, fine increment/max. PK `CirculationTypeID`.

| Column | Type | Notes |
|---|---|---|
| `CirculationTypeID` | int IDENTITY | PK |
| `ConfigSchoolID` / `CirculationTypeName` / `IsDefault` | mixed | Identity |
| `DefaultCheckOutLimit` (5) / `DefaultLoanPeriod` (7) / `DefaultGracePeriod` (1) / `DefaultTimesRenewable` (0) | int | Defaults |
| `DefaultFineIncrement` (0.05) / `DefaultMaxFine` (5) | decimal | Fine policy |

---

#### `lib.PatronGroup`
Patron group (by person type) — checkout/hold/reservation limits, fine-block flag. PK `PatronGroupID`. `GroupType`: 0=Default, 1=Staff, 2=Parent, 3=Student (per extended property).

| Column | Type | Notes |
|---|---|---|
| `PatronGroupID` | int IDENTITY | PK |
| `ConfigSchoolID` / `GroupName` | mixed | Identity |
| `GroupType` | smallint | 0=Default,1=Staff,2=Parent,3=Student |
| `MaxCheckouts` / `MaxHoldTime` / `MaxReservations` / `MaxReservationTime` / `BlockOnFines` | mixed | Limits |

---

#### `lib.PatronGroupCirculationType`
Per-patron-group overrides of circulation-type rules. PK `PatronGroupCirculationTypeID`. FKs → `lib.PatronGroup` (CASCADE), `lib.CirculationType` (CASCADE).

| Column | Type | Notes |
|---|---|---|
| `PatronGroupCirculationTypeID` | int IDENTITY | PK |
| `PatronGroupID` / `CirculationTypeID` | int | FKs (both CASCADE) |
| `CheckOutLimit` / `LoanPeriod` / `GracePeriod` / `TimesRenewable` / `FineIncrement` / `MaxFine` | mixed | Overrides |

---

#### `lib.Reservation`
Holds/reservations on a catalog title by a person — reserved span, on-hold end, status. PK `ReservationID`. FKs → `Person` (CASCADE), `lib.Catalog` (CASCADE).

| Column | Type | Notes |
|---|---|---|
| `ReservationID` | int IDENTITY | PK |
| `CatalogID` | int | FK → `lib.Catalog` (CASCADE) |
| `PersonID` | int | FK → `Person` (CASCADE) |
| `ReservedDate` / `ReservedEndDate` / `OnHoldEndDate` | datetime | Reservation span |
| `ReservationStatusID` | int | Default 1 |
| `CreatedDate` | datetime | — |

---

#### `lib.BarcodeBatch`
A batch of barcode generation/printing. PK `BarcodeBatchID`.

| Column | Type | Notes |
|---|---|---|
| `BarcodeBatchID` | int IDENTITY | PK |
| `ConfigSchoolID` / `BatchDate` / `CompletedBy` | mixed | — |

---

#### `lib.ImportFile`
A library-record import file (e.g. MARC import). PK `ImportFileID`. Referenced by `Catalog`/`Inventory` (SET NULL on delete).

| Column | Type | Notes |
|---|---|---|
| `ImportFileID` | int IDENTITY | PK |
| `FileName` / `ImportDate` / `ImportedBy` / `IsCompleted` | mixed | — |

---

#### `lib.ConversionMapping`
Maps legacy RenWeb media types to the new physical/format/circulation-type lists (used during library data conversion). PK `ConversionMappingID`.

| Column | Type | Notes |
|---|---|---|
| `ConversionMappingID` | int IDENTITY | PK |
| `ConfigSchoolID` / `RWMediaType` | mixed | Legacy type |
| `PhysicalTypeListID` / `FormatTypeListID` / `CirculationTypeListID` | int | Target lists |

> `RWMediaType` + the table's purpose flag the legacy RenWeb → FACTS SIS library migration (another instance of the legacy-vs-current theme).

---

#### `ib` (continued) / `lib` — cross-reference summary

| Table | Schema | Scope / notes |
|---|---|---|
| `DiplomaCourses` | ib | IB diploma subject catalog |
| `DiplomaGrades` | ib | Per-student predicted/final IB grades; → `Person`, `SchoolYear` |
| `CriterionMaxAchievementLevel` | ib | MYP criterion max levels |
| `Catalog` | lib | **Bibliographic record**; MARC; maintains `SearchCatalog` via triggers |
| `CatalogDataField` | lib | MARC data fields; → `Catalog` |
| `CatalogSubField` | lib | MARC subfields; maintains `SearchCatalog` via triggers |
| `Inventory` | lib | Physical copies; triggers sync `Catalog.IsActive` |
| `CirculationHistory` | lib | Checkout/return history; → `Inventory` |
| `CirculationType` | lib | Circulation rules (loan/fine defaults) |
| `PatronGroup` | lib | Patron groups + limits; GroupType 0–3 |
| `PatronGroupCirculationType` | lib | Per-group rule overrides |
| `Reservation` | lib | Holds; → `Catalog`, `Person` |
| `BarcodeBatch` | lib | Barcode batches |
| `ImportFile` | lib | Import files; ref by `Catalog`/`Inventory` |
| `ConversionMapping` | lib | Legacy RW media-type mapping |

---

### `lib.SearchCatalog` (resolves library search triggers), then `lms` schema — Learning Management System

#### `lib.SearchCatalog`
The library **full-text-style search index** — denormalized searchable strings per catalog record, keyed by attribute type. **This is the table maintained by the triggers on `lib.Catalog` and `lib.CatalogSubField`** (documented in the prior batch): each searchable attribute (title, author, series, LCCN, ISBN, subjects) is stored as a row tagged with a negative `CatalogAttributeType` and the source `ForeignTable`/`ForiegnTableID`. Resolves the `SearchCatalog` references from those triggers.

| Column | Type | Notes |
|---|---|---|
| `SearchCatalogID` | int IDENTITY | PK |
| `CatalogID` | int | The catalog record |
| `SearchData` | nvarchar(513) | The searchable text |
| `CatalogAttributeType` | int | Attribute code: −1 Author, −2 Series, −3 ISBN, −4 subject subfield, −5 Title+SubTitle, −6 LCCN |
| `ForeignTable` / `ForiegnTableID` | mixed | Source table + id (note misspelling `Foriegn`) |
| `Timestamp` | timestamp | Rowversion; indexed |

---

### `lms` schema — Learning Management System (online classroom)

The **`lms`** schema is the online-classroom / LMS subsystem: course content is organized into Units → `Topic` → `Item` (the generic content/assignment unit); items can be assignments (`ItemAssignment`), have file attachments (`ItemFileMM`, `ItemAssignmentFileMM`, `CalendarFileMM`), graded (`Grades`), tracked for submission (`StudentSubmittedMM`), scheduled on a `Calendar`, and integrated with Zoom (`ItemZoomEvent`) and LTI external tools. Reference tables: `ItemType`, `ItemStatus`, `EventType`, `AutoGradingSupport`. (`lms.Unit`, the parent of `Topic`, is referenced but not in this batch.)

#### `lms.Topic`
A topic within a unit — name/description, visibility/active flags, ordering, schedule (with timezone + UTC), student-post/comment permissions. PK `TopicID`. FK → `lms.Unit`.

| Column group | Type | Notes |
|---|---|---|
| `TopicID` | int IDENTITY | PK |
| `UnitID` | int | FK → `lms.Unit`; indexed |
| `TopicName` / `TopicDescription` / `TopicOrder` | mixed | Identity/order |
| Visibility: `ShowToStudent` / `ActiveToStudent` / `InactiveDate` | mixed | — |
| Permissions: `AllowStudentPost` / `AllowStudentComment` | bit | — |
| Schedule: `StartDate` / `EndDate` / `StartTimeUtc` / `EndTimeUtc` / `ZoneCountryCode` / `ZoneName` / `ZoneOffset` | mixed | Local + UTC + tz |
| `CreatedDate` / `LastModifiedDate` | smalldatetime | Audit |

---

#### `lms.Item`
**The core LMS content unit** — a lesson, assignment, quiz, or external-tool link within a topic. Carries visibility/active flags, ordering, gradebook integration (`EnableGradebook`/`GradebookSyncing`/`MaxPoints`), auto-grading flags, answer-key/review options, schedule (tz+UTC), and LTI linkage. PK `ItemID`. FKs → `lms.ItemType`, `lti.ToolType` (LTI).

| Column group | Type | Notes |
|---|---|---|
| `ItemID` | int IDENTITY | PK |
| `ItemTypeID` | int | FK → `lms.ItemType` |
| `TopicID` | int | The topic; indexed |
| `ItemName` / `ItemDescription` / `ItemOrder` | mixed | Identity/order |
| Visibility: `ShowToStudent` / `ActiveToStudent` / `InactiveDate` | mixed | — |
| Gradebook: `EnableGradebook` / `GradebookSyncing` / `MaxPoints` / `TurnedInOffline` | mixed | Links to gradebook |
| Auto-grade: `AutoGrading` / `AutoGradingAutoShow` / `ShowAnswerKey` / `AllowReview` | bit | — |
| Permissions: `AllowStudentPost` / `AllowStudentComment` | bit | — |
| Schedule: `StartDate` / `EndDate` / `StartTimeUtc` / `EndTimeUtc` / `DueDateUtc` / `ZoneCountryCode` / `ZoneName` / `ZoneOffset` | mixed | Local + UTC + tz |
| LTI: `LtiToolTypeId` / `LtiResourceLinkId` | mixed | FK → `lti.ToolType`; indexed |
| `ExtID` / `CreatedDate` / `LastModifiedDate` | mixed | — |

---

#### `lms.ItemType`
Item-type reference (lesson, assignment, quiz, etc.). PK `ItemTypeID`.

| Column | Type | Notes |
|---|---|---|
| `ItemTypeID` | int IDENTITY | PK |
| `ItemTypeName` | nvarchar(50) | — |

---

#### `lms.ItemStatus`
Item-status reference — status name + weight, active tracking. PK `ItemStatusID`. (Referenced by `lms.Grades.ItemStatusID`.)

| Column | Type | Notes |
|---|---|---|
| `ItemStatusID` | int IDENTITY | PK |
| `Status` / `Weight` | mixed | — |
| `CreateDate` / `InactiveDate` / `LastModifiedDate` | smalldatetime | — |

---

#### `lms.Grades`
LMS gradebook entry — per item×person, max/received/curve/penalty/bonus points, display grade, status. PK `GradeID`. FKs → `lms.Item`, `lms.ItemStatus`, `Person` (×2: PersonID + ModifiedBy).

| Column | Type | Notes |
|---|---|---|
| `GradeID` | int IDENTITY | PK (constraint named `…GradeBookID`) |
| `ItemID` | int | FK → `lms.Item`; indexed |
| `PersonID` | int | FK → `Person`; indexed |
| Points: `MaxPoints` / `ReceivedPoints` / `CurvePoints` / `PenaltyPoints` / `BonusPoints` | decimal | — |
| `DisplayGrade` / `Status` / `ItemStatusID` | mixed | FK → `lms.ItemStatus` |
| `Notes` | nvarchar(4000) | — |
| `ModifiedBy` / `ModifiedDate` / `CreatedDate` / `LastModifiedDate` | mixed | FK ModifiedBy → `Person` |

---

#### `lms.ItemAssignment`
A student's assignment submission for an item — title/description, submitted files (also `Files` text + the `ItemAssignmentFileMM` link), feedback, earned points. PK `AssignmentID`. FKs → `lms.Item`, `Person` (×2: StudentID + TeacherID).

| Column | Type | Notes |
|---|---|---|
| `AssignmentID` | int IDENTITY | PK |
| `ItemID` | int | FK → `lms.Item`; indexed |
| `StudentID` / `TeacherID` | int | FKs → `Person`; indexed |
| `Title` / `Description` / `Files` | mixed | Submission |
| `SubmittedOn` / `SubmittedOnUtc` | smalldatetime | — |
| `Feedback` / `FeedbackOn` / `FeedbackOnUtc` / `EarnedPoints` | mixed | Grading |
| `CreatedDate` / `LastModifiedDate` | smalldatetime | Audit |

---

#### `lms.StudentSubmittedMM`
Tracks which students have submitted an item. PK is composite `(ItemID, StudentID)`. FKs → `lms.Item`, `Person`.

| Column | Type | Notes |
|---|---|---|
| `ItemID` / `StudentID` | int | PK (composite); FKs |
| `SubmitDate` / `CreatedDate` / `LastModifiedDate` | smalldatetime | — |

---

File-attachment link tables (many-to-many between an entity and uploaded files):

#### `lms.ItemFileMM`
Files attached to an item. PK `(ItemID, FileID)`. FK → `lms.Item`.

| Column | Type | Notes |
|---|---|---|
| `ItemID` / `FileID` | mixed | PK (composite); → `lms.Item` |
| `FileName` | nvarchar(100) | — |

#### `lms.ItemAssignmentFileMM`
Files attached to an assignment submission. PK `FileID` (uniqueidentifier). FKs → `lms.ItemAssignment`, `Person`.

| Column | Type | Notes |
|---|---|---|
| `FileID` | uniqueidentifier | PK |
| `AssignmentID` | int | FK → `lms.ItemAssignment`; indexed |
| `PersonID` | int | FK → `Person`; indexed |
| `FileName` / `CreatedDate` / `LastModifiedDate` | mixed | — |

#### `lms.CalendarFileMM`
Files attached to a calendar event. PK `(EventID, FileID)`. FK → `lms.Calendar`.

| Column | Type | Notes |
|---|---|---|
| `EventID` / `FileID` | mixed | PK (composite); → `lms.Calendar` |
| `FileName` / `CreatedDate` / `LastModifiedDate` | mixed | — |

---

#### `lms.Calendar`
LMS calendar events — title, start/end (tz+UTC), location, due date, optionally linked to an item/class/person/school. PK `EventID`. FKs → `lms.EventType`, `lms.Item`, `dbo.Classes`, `dbo.ConfigSchool` (SchoolCode), `Person`.

| Column | Type | Notes |
|---|---|---|
| `EventID` | int IDENTITY | PK |
| `EventTypeID` | int | FK → `lms.EventType` |
| `Title` / `Location` / `Description` | mixed | — |
| Schedule: `StartDateTime` / `EndDateTime` / `DueDate` + `…Utc` variants / `ZoneCountryCode` / `ZoneName` / `ZoneOffset` | mixed | Local + UTC + tz |
| Links: `ItemID` / `ClassID` / `PersonID` / `SchoolCode` | mixed | FKs → `Item`, `Classes`, `Person`, `ConfigSchool`; all indexed |
| `CreatedDate` / `LastModifiedDate` | smalldatetime | — |

---

#### `lms.EventType`
Calendar-event-type reference. PK `EventTypeID`.

| Column | Type | Notes |
|---|---|---|
| `EventTypeID` | int IDENTITY | PK |
| `EventTypeName` | nvarchar(50) | — |

---

#### `lms.ItemZoomEvent`
Links an LMS item to a Zoom meeting/occurrence. PK `ItemZoomEventID`. Unique on `ItemID` and on `(ZoomMeetingId, OccurrenceId)`. FKs → `lms.Item`, `Person` (CreatedBy).

| Column | Type | Notes |
|---|---|---|
| `ItemZoomEventID` | int IDENTITY | PK |
| `ItemID` | int | FK → `lms.Item`; unique |
| `ZoomMeetingId` / `OccurrenceId` | mixed | Zoom meeting; unique together |
| `CreatedBy` / `CreatedUtc` | mixed | FK → `Person` |

---

#### `lms.AutoGradingSupport`
Reference table marking which question types support auto-grading. PK `AutoGradingSupportID`.

| Column | Type | Notes |
|---|---|---|
| `AutoGradingSupportID` | int IDENTITY | PK |
| `QuestionTypeMatch` / `Supported` | mixed | — |
| `Createdate` / `Inactivedate` / `LastModifiedDate` | smalldatetime | — |

---

#### `lib.SearchCatalog` / `lms` — cross-reference summary

| Table | Schema | Scope / notes |
|---|---|---|
| `SearchCatalog` | lib | **Library search index**; maintained by `Catalog`/`CatalogSubField` triggers |
| `Topic` | lms | Topic within a unit; → `lms.Unit` |
| `Item` | lms | **Core LMS content unit**; → `ItemType`, `lti.ToolType`; gradebook + LTI |
| `ItemType` | lms | Item-type reference |
| `ItemStatus` | lms | Item-status reference; ref by `Grades` |
| `Grades` | lms | LMS gradebook entry; → `Item`, `ItemStatus`, `Person` |
| `ItemAssignment` | lms | Student assignment submission; → `Item`, `Person` |
| `StudentSubmittedMM` | lms | Submission tracking; PK `(ItemID, StudentID)` |
| `ItemFileMM` | lms | Item file attachments |
| `ItemAssignmentFileMM` | lms | Assignment file attachments |
| `CalendarFileMM` | lms | Calendar-event file attachments |
| `Calendar` | lms | LMS calendar events; → `Item`, `Classes`, `Person`, `ConfigSchool` |
| `EventType` | lms | Calendar-event-type reference |
| `ItemZoomEvent` | lms | Item↔Zoom meeting link |
| `AutoGradingSupport` | lms | Auto-grading question-type support |

---

### `lms` (learning-management units), `lp` (lesson planner), `lti` (external tools)

### `lms` schema — learning-management units

The **`lms`** schema holds class units (modules) that organize curriculum/content, aligned to academic standards.

#### `lms.Unit`
A unit/module within a class — name, description, date span, student visibility/active flags, ordering, and timezone-aware scheduling. PK `UnitID`. FK → `dbo.Classes`.

| Column group | Type | Notes |
|---|---|---|
| `UnitID` | int IDENTITY | PK |
| `ClassID` | int | FK → `dbo.Classes`; indexed |
| `UnitName` / `UnitDescription` / `UnitOrder` | mixed | Identity/order |
| `StartDate` / `EndDate` / `InactiveDate` | datetime | Span |
| `ShowToStudent` / `ActiveToStudent` | bit | Visibility |
| Timezone: `ZoneCountryCode` / `ZoneName` / `ZoneOffset` / `StartTimeUtc` / `EndTimeUtc` | mixed | TZ-aware scheduling |
| `CreatedDate` / `LastModifiedDate` | smalldatetime | Audit |

---

#### `lms.UnitStandardMM`
Links units to academic standards (many-to-many). PK is composite `(UnitID, StandardID)`. FKs → `lms.Unit`, **`aca.Standard`**.

| Column | Type | Notes |
|---|---|---|
| `UnitID` / `StandardID` | int | PK (composite); → `lms.Unit`, `aca.Standard` |

---

### `lp` schema — lesson planner

The **`lp`** schema is the lesson-planning subsystem, with two parallel halves: **live lessons** (`Lesson` + `LessonText`/`LessonWebDocumentMM`/`LessonStandardMm`, tied to a class + plan date) and **reusable stored-lesson templates** (`StoredLesson` + `StoredLessonText`/`StoredLessonWebDocumentMM`/`StoredLessonStandardMM`, tied to a course, instantiated into live lessons). Shared lookup `LessonTextLabel` labels text sections; per-student family-portal visibility overrides exist for both lesson text and documents. Standards alignment is via `aca.Standard`; documents via `dbo.WebDocuments`.

> This is the canonical **template-vs-instance** pattern: `StoredLesson*` = reusable course-level templates; `Lesson*` = the live, dated, class-level instances (with `Lesson.StoredLessonId` recording the source template).

#### `lp.Lesson`
A live (planned) lesson for a class on a date — optionally instantiated from a stored lesson. PK `LessonId`. FKs → `dbo.Classes`, `lp.StoredLesson`.

| Column | Type | Notes |
|---|---|---|
| `LessonId` | int IDENTITY | PK |
| `ClassId` | int | FK → `dbo.Classes`; indexed with PlanDate |
| `PlanDate` | date | The lesson date |
| `LessonName` | nvarchar(256) | — |
| `StoredLessonId` | int | FK → `lp.StoredLesson` (source template) |

---

#### `lp.LessonText`
Rich-text sections of a live lesson (plain + HTML), labeled, with parent/student visibility. PK `LessonTextId`. Unique `(LessonId, LessonTextLabelId)`. FKs → `lp.Lesson` (CASCADE), `lp.LessonTextLabel` (CASCADE), `lp.StoredLessonText` (SET NULL, source).

| Column | Type | Notes |
|---|---|---|
| `LessonTextId` | int IDENTITY | PK |
| `LessonId` | int | FK → `lp.Lesson` (CASCADE) |
| `LessonTextLabelId` | int | FK → `lp.LessonTextLabel`; unique with LessonId |
| `PlainText` / `HtmlText` | nvarchar(max) | Content |
| `ShowToParents` / `ShowToStudents` | bit | Visibility |
| `StoredLessonTextId` | int | FK → `lp.StoredLessonText` (SET NULL) |

---

#### `lp.LessonTextLabel`
Lookup of lesson-text section labels (e.g. "Objective", "Homework"). PK `LessonTextLabelId`. Shared by live and stored lesson text.

| Column | Type | Notes |
|---|---|---|
| `LessonTextLabelId` | int IDENTITY | PK |
| `Name` | nvarchar(50) | Label |

---

#### `lp.LessonTextFamilyPortalVisibility`
Per-student override of a lesson-text's family-portal visibility. PK `…VisibilityId`. FKs → `lp.LessonText` (CASCADE), `Person` (CASCADE).

| Column | Type | Notes |
|---|---|---|
| `LessonTextFamilyPortalVisibilityId` | int IDENTITY | PK |
| `LessonTextId` | int | FK → `lp.LessonText` (CASCADE) |
| `StudentId` | int | FK → `Person` (CASCADE) |
| `ShowForStudent` | bit | Per-student override |

---

#### `lp.LessonWebDocumentMM`
Attaches web documents to a live lesson, with parent/student visibility + an override flag. PK `LessonWebDocumentMmId`. FKs → `lp.Lesson` (CASCADE), **`dbo.WebDocuments`** (CASCADE).

| Column | Type | Notes |
|---|---|---|
| `LessonWebDocumentMmId` | int IDENTITY | PK |
| `LessonId` | int | FK → `lp.Lesson` (CASCADE) |
| `DocumentId` | int | FK → `dbo.WebDocuments` (`DocumnetID` — sic) (CASCADE) |
| `ShowToParents` / `ShowToStudents` / `HasVisibilityOverrides` | bit | Visibility |

---

#### `lp.LessonWebDocumentFamilyPortalVisibility`
Per-student override of a lesson-document's family-portal visibility. PK `…VisibilityId`. FKs → `lp.LessonWebDocumentMM` (CASCADE), `Person` (CASCADE).

| Column | Type | Notes |
|---|---|---|
| `LessonWebDocumentFamilyPortalVisibilityId` | int IDENTITY | PK |
| `LessonWebDocumentMmId` | int | FK → `lp.LessonWebDocumentMM` (CASCADE) |
| `StudentId` | int | FK → `Person` (CASCADE) |
| `ShowForStudent` | bit | Per-student override |

---

#### `lp.LessonStandardMm`
Links a live lesson to academic standards, with parent/student visibility. PK `LessonStandardMmId`. FKs → `lp.Lesson` (CASCADE), **`aca.Standard`** (CASCADE).

| Column | Type | Notes |
|---|---|---|
| `LessonStandardMmId` | int IDENTITY | PK |
| `LessonId` / `StandardId` | int | FKs (both CASCADE) |
| `ShowToParents` / `ShowToStudents` | bit | Visibility |

---

#### `lp.StoredLesson`
A reusable lesson template at the course level — owned by a staff member, ordered. PK `StoredLessonId`. FKs → **`crse.CourseCore`**, `Person` (StaffId). (Instantiated into `lp.Lesson` via `Lesson.StoredLessonId`.)

| Column | Type | Notes |
|---|---|---|
| `StoredLessonId` | int IDENTITY | PK |
| `CourseId` | int | FK → `crse.CourseCore`; unique with StaffId |
| `StaffId` | int | FK → `Person` |
| `SortOrder` / `LessonName` | mixed | — |

---

#### `lp.StoredLessonText`
Rich-text sections of a stored lesson (plain + HTML), labeled. PK `StoredLessonTextId`. Unique `(StoredLessonId, LessonTextLabelId)`. FKs → `lp.StoredLesson`, `lp.LessonTextLabel`. (Source for `LessonText.StoredLessonTextId`.)

| Column | Type | Notes |
|---|---|---|
| `StoredLessonTextId` | int IDENTITY | PK |
| `StoredLessonId` | int | FK → `lp.StoredLesson` |
| `LessonTextLabelId` | int | FK → `lp.LessonTextLabel`; unique with StoredLessonId |
| `PlainText` / `HtmlText` | nvarchar(max) | Content |

---

#### `lp.StoredLessonWebDocumentMM`
Attaches web documents to a stored lesson. PK `StoredLessonWebDocumentMmId`. Unique `(StoredLessonId, DocumentId)`. FKs → `lp.StoredLesson`, `dbo.WebDocuments`.

| Column | Type | Notes |
|---|---|---|
| `StoredLessonWebDocumentMmId` | int IDENTITY | PK |
| `StoredLessonId` / `DocumentId` | int | FKs; unique together |

---

#### `lp.StoredLessonStandardMM`
Links a stored lesson to academic standards. PK `StoredLessonStandardMmId`. Unique `(StoredLessonId, StandardId)`. FKs → `lp.StoredLesson`, `aca.Standard`.

| Column | Type | Notes |
|---|---|---|
| `StoredLessonStandardMmId` | int IDENTITY | PK |
| `StoredLessonId` / `StandardId` | int | FKs; unique together |

---

### `lti` schema — LTI external-tool configuration

The **`lti`** schema configures external learning tools (LTI). A `lti.ToolConfiguration` (not in this batch) is enabled per school and per class via these MM tables.

#### `lti.SchoolToolConfigurationMM`
Enables an LTI tool configuration for a school. PK `SchoolToolConfigurationMMId`. FKs → `dbo.ConfigSchool`, `lti.ToolConfiguration`.

| Column | Type | Notes |
|---|---|---|
| `SchoolToolConfigurationMMId` | int IDENTITY | PK |
| `ConfigSchoolId` | smallint | FK → `dbo.ConfigSchool`; indexed |
| `ToolConfigurationId` | int | FK → `lti.ToolConfiguration`; indexed |
| `Enabled` | bit | Default 1 |

---

#### `lti.ClassToolConfigurationMM`
Enables an LTI tool configuration for a class. PK `ClassToolConfigurationMMId`. FKs → `dbo.Classes`, `lti.ToolConfiguration`.

| Column | Type | Notes |
|---|---|---|
| `ClassToolConfigurationMMId` | int IDENTITY | PK |
| `ClassId` | int | FK → `dbo.Classes`; indexed |
| `ToolConfigurationId` | int | FK → `lti.ToolConfiguration`; indexed |
| `Enabled` | bit | Default 1 |

---

#### `lms` / `lp` / `lti` — cross-reference summary

| Table | Schema | Scope / notes |
|---|---|---|
| `Unit` | lms | Class unit/module; → `dbo.Classes` |
| `UnitStandardMM` | lms | Unit↔standard; → `aca.Standard` |
| `Lesson` | lp | Live dated lesson; → `dbo.Classes`, `StoredLesson` |
| `LessonText` | lp | Live lesson text sections; → `StoredLessonText` |
| `LessonTextLabel` | lp | Text-section label lookup (shared) |
| `LessonTextFamilyPortalVisibility` | lp | Per-student text visibility; → `Person` |
| `LessonWebDocumentMM` | lp | Live lesson docs; → `dbo.WebDocuments` |
| `LessonWebDocumentFamilyPortalVisibility` | lp | Per-student doc visibility; → `Person` |
| `LessonStandardMm` | lp | Live lesson↔standard; → `aca.Standard` |
| `StoredLesson` | lp | **Reusable course-level template**; → `crse.CourseCore`, `Person` |
| `StoredLessonText` | lp | Template text sections |
| `StoredLessonWebDocumentMM` | lp | Template docs; → `dbo.WebDocuments` |
| `StoredLessonStandardMM` | lp | Template↔standard; → `aca.Standard` |
| `SchoolToolConfigurationMM` | lti | LTI tool enabled per school |
| `ClassToolConfigurationMM` | lti | LTI tool enabled per class |

---

### `lti` schema (continued) — tool definitions, and `mail` schema — email/messaging

### `lti` schema (continued)

These complete the `lti` schema — the `ToolType`/`ToolConfiguration` definitions referenced by the school/class MM tables from the prior batch, plus a staff-level enablement MM.

#### `lti.ToolType`
LTI tool-type lookup (the kind of external tool). PK `ToolTypeId`.

| Column | Type | Notes |
|---|---|---|
| `ToolTypeId` | int IDENTITY | PK |
| `Name` / `Description` / `Enabled` | mixed | — |

---

#### `lti.ToolConfiguration`
An LTI tool configuration — launch/OAuth URLs, account id, shared/secret keys, enabled. PK `ToolConfigurationId`. FK → `lti.ToolType`. **The table the school/class/staff MM tables enable.**

> **Contains credentials** — `SharedKey` and `SecretKey` are LTI OAuth credentials. Treat as sensitive.

| Column | Type | Notes |
|---|---|---|
| `ToolConfigurationId` | int IDENTITY | PK |
| `ToolTypeId` | int | FK → `lti.ToolType`; indexed |
| `Url` / `OauthUrl` / `AccountId` | mixed | Launch/OAuth |
| `SharedKey` / `SecretKey` | nvarchar | **OAuth credentials — sensitive** |
| `Enabled` | bit | Default 1 |

---

#### `lti.StaffConfigurationToolMM`
Enables an LTI tool configuration for a staff member. PK `StaffConfigurationToolMMId`. FKs → `dbo.Person_Staff`, `lti.ToolConfiguration`. (The staff-level counterpart to `SchoolToolConfigurationMM`/`ClassToolConfigurationMM`.)

| Column | Type | Notes |
|---|---|---|
| `StaffConfigurationToolMMId` | int IDENTITY | PK |
| `StaffId` | int | FK → `dbo.Person_Staff`; indexed |
| `ToolConfigurationId` | int | FK → `lti.ToolConfiguration`; indexed |
| `Enabled` | bit | Default 1 |

---

### `mail` schema — email / messaging

The **`mail`** schema is the outbound email/messaging subsystem: `EmailMessage` (a sent message) → `EmailMessageText` (body, 1:1) + `EmailMessageAttachment` (files) + `EmailRecipient` (per-recipient delivery tracking). **Communication groups** (`CommunicationGroup` + person/security-group/security-person MM) define reusable recipient lists. `MessageType`/`RecipientType`/`RecipientTypeConfig` configure which recipient types are allowed per message type per school. `EmailAuthentication` tracks per-domain SPF/DKIM/DMARC status.

#### `mail.EmailMessage`
A sent/queued email message — status, sender, subject, recipient count, queue/delivery timestamps, type, school, scheduled-batch id. PK `EmailMessageID` (bigint, IDENTITY seed 2,000,000,000). FK → `dbo.ConfigSchool`.

| Column group | Type | Notes |
|---|---|---|
| `EmailMessageID` | bigint IDENTITY(2000000000,1) | PK |
| `MessageStatus` | nvarchar(50) | Indexed with id+queued |
| `StaffID` / `FromEmail` / `FromName` | mixed | Sender |
| `Subject` / `NumRcpts` | mixed | — |
| `DateQueued` / `DateDelivered` / `DateCompleted` / `NumMinutesInQueue` | mixed | Lifecycle |
| `EmailType` / `SourceID` / `GenerateReceivedLink` | mixed | — |
| `SessionID` / `AttachmentSession` / `ScheduledBatchId` | mixed | Batch/session; `ScheduledBatchId` filtered-indexed |
| `ConfigSchoolID` | smallint | FK → `dbo.ConfigSchool` |

---

#### `mail.EmailMessageText`
The message body (separated from the header for performance). PK `EmailMessageID` (1:1 with `EmailMessage`). `TEXTIMAGE_ON`.

| Column | Type | Notes |
|---|---|---|
| `EmailMessageID` | bigint | PK; 1:1 with `EmailMessage` |
| `MessageText` | nvarchar(max) | Body |

---

#### `mail.EmailMessageAttachment`
Attachments on a message — filename + URL. PK `EmailMessageAttachmentID`; clustered on `EmailMessageID`. FK → `EmailMessage` (CASCADE).

| Column | Type | Notes |
|---|---|---|
| `EmailMessageAttachmentID` | bigint IDENTITY | PK (nonclustered) |
| `EmailMessageID` | bigint | FK → `EmailMessage` (CASCADE); clustered |
| `FileName` / `FileUrl` | nvarchar | — |

---

#### `mail.EmailRecipient`
Per-recipient delivery record — email, received/could-not-send/suppressed flags, access count, merge tags, display name. PK `EmailRecipientID`. (No FK to `EmailMessage`, but logically a child; `EmailMessageID` indexed.)

| Column | Type | Notes |
|---|---|---|
| `EmailRecipientID` | bigint IDENTITY | PK |
| `EmailMessageID` | bigint | The message; indexed |
| `Email` / `DisplayName` | mixed | Recipient; email indexed |
| `Received` / `CouldNotSend` / `WasSuppressed` / `DateReceived` / `EmailAccessedCount` | mixed | Delivery tracking; `WasSuppressed` indexed |
| `MergeTags` / `MergeTagVersion` | mixed | Mail-merge personalization |
| `SessionID` | nvarchar(50) | — |

---

#### `mail.CommunicationGroup`
A reusable recipient group — name, description, school, "everyone can use" flag. PK `CommunicationGroupID`. Members defined via the three MM tables below.

| Column | Type | Notes |
|---|---|---|
| `CommunicationGroupID` | int IDENTITY | PK |
| `GroupName` / `GroupDescription` | nvarchar | — |
| `ConfigSchoolID` / `CanEveryoneUse` | mixed | Scope/sharing |

---

#### `mail.CommunicationGroupPersonMM`
Direct person members of a communication group. PK `(CommunicationGroupID, PersonID)`. FKs → `CommunicationGroup` (CASCADE), `Person` (CASCADE).

| Column | Type | Notes |
|---|---|---|
| `CommunicationGroupID` / `PersonID` | int | PK (composite); both CASCADE |

---

#### `mail.CommunicationGroupSecurityGroupMM`
Security-group members of a communication group (dynamic membership by role). PK `(CommunicationGroupID, SecurityGroupID)`. FKs → `CommunicationGroup` (CASCADE), `dbo.SecurityGroups` (CASCADE).

| Column | Type | Notes |
|---|---|---|
| `CommunicationGroupID` / `SecurityGroupID` | int | PK (composite); → `SecurityGroups` |

---

#### `mail.CommunicationGroupSecurityPersonMM`
Person members added via the security context of a communication group (distinct from the direct-person MM). PK `(CommunicationGroupID, PersonID)`. FKs → `CommunicationGroup` (CASCADE), `Person` (CASCADE).

| Column | Type | Notes |
|---|---|---|
| `CommunicationGroupID` / `PersonID` | int | PK (composite); both CASCADE |

---

#### `mail.MessageType`
Message-type lookup (tinyint-keyed). PK `MessageTypeID`.

| Column | Type | Notes |
|---|---|---|
| `MessageTypeID` | tinyint | PK |
| `MessageType` | nvarchar(20) | — |

---

#### `mail.RecipientType`
Recipient-type lookup (tinyint-keyed). PK `RecipientTypeID`.

| Column | Type | Notes |
|---|---|---|
| `RecipientTypeID` | tinyint | PK |
| `RecipientType` | nvarchar(20) | — |

---

#### `mail.RecipientTypeConfig`
Configures which recipient types are permitted per message type per school. PK is composite `(ConfigSchoolID, MessageTypeID, RecipientTypeID)`. FKs → `ConfigSchool`, `MessageType`, `RecipientType`.

| Column | Type | Notes |
|---|---|---|
| `ConfigSchoolID` | smallint | PK (composite); FK → `dbo.ConfigSchool` |
| `MessageTypeID` | tinyint | PK (composite); FK → `mail.MessageType` |
| `RecipientTypeID` | tinyint | PK (composite); FK → `mail.RecipientType` |

---

#### `mail.EmailAuthentication`
Per-domain email-authentication DNS status — SPF/DKIM(internal+external)/DMARC presence, admin email. PK `EmailAuthenticationId`. FK → `Person_Staff` (ModifiedBy). (Used to verify a school's sending domain is properly configured for deliverability.)

| Column | Type | Notes |
|---|---|---|
| `EmailAuthenticationId` | int IDENTITY | PK |
| `DomainAddress` / `SchoolCode` / `AdministratorEmail` | mixed | Domain |
| `HasSPFRecord` / `HasDKIMRecordInternal` / `HasDKIMRecordExternal` / `HasDMARCRecord` | bit | DNS auth status |
| `ModifiedDateTimeUTC` / `ModifiedBy` | mixed | FK → `Person_Staff` |

---

#### `lti` (continued) / `mail` — cross-reference summary

| Table | Schema | Scope / notes |
|---|---|---|
| `ToolType` | lti | LTI tool-type lookup |
| `ToolConfiguration` | lti | LTI tool config; **credentials**; → `ToolType` |
| `StaffConfigurationToolMM` | lti | LTI tool enabled per staff |
| `EmailMessage` | mail | Sent/queued message; → `ConfigSchool`; bigint seed 2e9 |
| `EmailMessageText` | mail | Message body (1:1) |
| `EmailMessageAttachment` | mail | Attachments; → `EmailMessage` |
| `EmailRecipient` | mail | Per-recipient delivery tracking |
| `CommunicationGroup` | mail | Reusable recipient group |
| `CommunicationGroupPersonMM` | mail | Direct person members; → `Person` |
| `CommunicationGroupSecurityGroupMM` | mail | Role-based members; → `SecurityGroups` |
| `CommunicationGroupSecurityPersonMM` | mail | Security-context person members |
| `MessageType` | mail | Message-type lookup |
| `RecipientType` | mail | Recipient-type lookup |
| `RecipientTypeConfig` | mail | Allowed recipient types per msg type per school |
| `EmailAuthentication` | mail | Per-domain SPF/DKIM/DMARC status |

---

### `mail` schema (continued) — scheduled batches & suppression, then `med` schema — medical/health

### `mail` schema (continued)

#### `mail.ScheduledBatch`
A scheduled (future-send) email batch — send time, status, Service Bus sequence, and the full draft as JSON (CHECK ISJSON). PK `ScheduledBatchId` (uniqueidentifier). FK → `Person_Staff` (CreatedBy). Referenced by `EmailMessage.ScheduledBatchId`.

| Column | Type | Notes |
|---|---|---|
| `ScheduledBatchId` | uniqueidentifier | PK |
| `ScheduledSendTime` / `Status` | mixed | Default status 'Scheduled'; filtered index on Scheduled |
| `ServiceBusSequenceNumber` | bigint | Azure Service Bus linkage |
| `EmailDraftJson` | nvarchar(max) | CHECK ISJSON = 1 |
| `CreatedDateUtc` / `CreatedByStaffId` | mixed | FK → `Person_Staff` |

---

#### `mail.SuppressionList`
Suppressed email addresses (per email type) — do-not-send list (bounces/unsubscribes). PK is composite `(Email, EmailType)`. (`EmailRecipient.WasSuppressed` reflects a hit against this list.)

| Column | Type | Notes |
|---|---|---|
| `Email` / `EmailType` | mixed | PK (composite) |

---

### `med` schema — medical / health (modern subsystem)

> **Contains health PII (HIPAA-adjacent).** Medication administration, medical events, measurements, immunization config. Treat as highly sensitive.

The **`med`** schema is the modern student-health subsystem. It bridges to the **legacy `dbo` medical tables** (`StudentMedicalEvents`, `StudentMedication`, `OTCConfig`, `ConfigMedicalTests`) — many `med` tables FK back to those, and `med.MedicalTestConfiguration*` triggers keep the legacy `dbo.ConfigMedicalTests` in sync. Core flow: a medical event (`dbo.StudentMedicalEvents`) gets medication-administration records (`AdministrationOTC`/`AdministrationPrescription`), measurements (`MedicalEventMeasurement`), contacts (`EventContactMM`), and medication links (the two `PersonMedicalEvent*MM`); medications are scheduled via `OTCMedicationSchedule`/`PersonMedicationSchedule`; per-school/person profiles configure behavior.

#### `med.MedicalTestConfiguration`
Medical-test-type configuration (modern) — name, school scope, district-wide. PK `MedicalTestConfigurationID`. FK → `ConfigSchool` (CASCADE). **The modern replacement for legacy `dbo.ConfigMedicalTests`**, kept in sync by triggers.

| Column | Type | Notes |
|---|---|---|
| `MedicalTestConfigurationID` | int IDENTITY | PK |
| `ConfigSchoolID` | smallint | FK → `dbo.ConfigSchool` (CASCADE) |
| `ConfigurationName` / `DistrictWide` | mixed | — |

**Triggers** (bridge to legacy `dbo.ConfigMedicalTests`, keyed `MedicalTestConfigurationID = ConfigMedicalTests.TestTypeID`):
- `TR_med_MedicalTestConfiguration_Ins` (AFTER INSERT, nest-level guarded): inserts the matching `ConfigMedicalTests` row (with `SET IDENTITY_INSERT`, copying SchoolCode from `ConfigSchool`).
- `TR_med_MedicalTestConfiguration_Upd` (AFTER UPDATE, nest-level guarded): syncs name/school/district-wide changes to `ConfigMedicalTests`.
- `TR_med_MedicalTestConfiguration_Del` (AFTER DELETE): deletes the matching `ConfigMedicalTests` row.

---

#### `med.MedicalTestConfigurationField`
Fields within a medical-test configuration — field name + a `LegacyIndex` (1–10). PK `MedicalTestConfigurationFieldID`. FK → `med.MedicalTestConfiguration` (CASCADE).

| Column | Type | Notes |
|---|---|---|
| `MedicalTestConfigurationFieldID` | int IDENTITY | PK |
| `MedicalTestConfigurationID` | int | FK → `med.MedicalTestConfiguration` (CASCADE) |
| `FieldName` | nvarchar(50) | — |
| `LegacyIndex` | smallint | 1–10; maps to legacy `Field1`–`Field10` |

**Triggers** (Ins/Upd/Del, nest-level guarded): write the field name into the legacy `dbo.ConfigMedicalTests.Field1`–`Field10` columns based on `LegacyIndex` (each index → its numbered column; delete sets it NULL). This is the legacy denormalized-`FieldN`-columns ↔ normalized-rows bridge.

> The `med.MedicalTestConfiguration[Field]` pair is the modern normalized model; `dbo.ConfigMedicalTests` (with its `TestTypeID` PK and `Field1`–`Field10` columns) is the legacy denormalized one. The triggers keep legacy in sync so older reports/screens keep working. Classic legacy-vs-refactored bridge.

---

#### `med.AdministrationOTC`
Records an administration of an OTC medication during a medical event — dose, result, optional schedule. PK `AdministrationOTCID`. FKs → `dbo.StudentMedicalEvents`, `dbo.OTCConfig`, `med.OTCMedicationSchedule`.

| Column | Type | Notes |
|---|---|---|
| `AdministrationOTCID` | int IDENTITY | PK |
| `EventID` | int | FK → `dbo.StudentMedicalEvents`; indexed |
| `OTCID` | int | FK → `dbo.OTCConfig`; indexed |
| `Dose` / `Result` | mixed | Administration |
| `ScheduleID` | int | FK → `med.OTCMedicationSchedule` |

---

#### `med.AdministrationPrescription`
Records an administration of a prescription medication during a medical event. PK `AdministrationPrescriptionID`. FKs → `dbo.StudentMedicalEvents`, `dbo.StudentMedication`, `med.PersonMedicationSchedule`.

| Column | Type | Notes |
|---|---|---|
| `AdministrationPrescriptionID` | int IDENTITY | PK |
| `EventID` | int | FK → `dbo.StudentMedicalEvents`; indexed |
| `PrescriptionID` | int | FK → `dbo.StudentMedication`; indexed |
| `Dose` / `Result` | mixed | Administration |
| `ScheduleID` | int | FK → `med.PersonMedicationSchedule` |

---

#### `med.MedicalEventMeasurement`
Measurements taken during a medical event (typed, e.g. temp/BP/weight). PK is composite `(EventID, MeasurementType)`. FK → `dbo.StudentMedicalEvents`.

| Column | Type | Notes |
|---|---|---|
| `EventID` | int | PK (composite); FK → `dbo.StudentMedicalEvents` |
| `MeasurementType` | tinyint | PK (composite); type code |
| `MeasurementValue` | decimal(9,4) | The reading |

---

#### `med.EventContactMM`
Contacts associated with a medical event (e.g. parents notified). PK is composite `(EventID, PersonID)`. FKs → `dbo.StudentMedicalEvents` (CASCADE), `Person`.

| Column | Type | Notes |
|---|---|---|
| `EventID` / `PersonID` | int | PK (composite); → events, `Person` |

---

#### `med.PersonMedicalEventOTCConfigMM`
Links a medical event to OTC-medication configs. PK `(MedicalEventID, OTCConfigID)`. FKs → `dbo.StudentMedicalEvents` (CASCADE), `dbo.OTCConfig` (CASCADE).

| Column | Type | Notes |
|---|---|---|
| `MedicalEventID` / `OTCConfigID` | int | PK (composite); both CASCADE |

---

#### `med.PersonMedicalEventPersonMedicationMM`
Links a medical event to prescription medications. PK `(MedicalEventID, MedicationID)`. FKs → `dbo.StudentMedicalEvents` (CASCADE), `dbo.StudentMedication` (CASCADE).

| Column | Type | Notes |
|---|---|---|
| `MedicalEventID` / `MedicationID` | int | PK (composite); both CASCADE |

---

#### `med.OTCMedicationSchedule`
Per-person OTC-medication dosing schedule — dose time + per-weekday flags. PK `OTCMedicationScheduleID`. Unique on all fields. FKs → `dbo.OTCConfig`, `Person` (CASCADE).

| Column | Type | Notes |
|---|---|---|
| `OTCMedicationScheduleID` | int IDENTITY | PK |
| `OTCID` / `PersonID` | int | FKs; PersonID CASCADE + indexed |
| `ScheduledDoseTime` | time(0) | — |
| `ScheduledForSunday`…`ScheduledForSaturday` | bit | Per-weekday |

---

#### `med.PersonMedicationSchedule`
Per-prescription dosing schedule — dose time + per-weekday flags. PK `PersonMedicationScheduleID`. FK → `dbo.StudentMedication` (CASCADE).

| Column | Type | Notes |
|---|---|---|
| `PersonMedicationScheduleID` | int IDENTITY | PK |
| `MedicationID` | int | FK → `dbo.StudentMedication` (CASCADE); indexed |
| `ScheduledDoseTime` | time(0) | — |
| `ScheduledForSunday`…`ScheduledForSaturday` | bit | Per-weekday |

**Triggers** (Ins/Upd/Del, added 2024): maintain `dbo.StudentMedication.Scheduled` — set to 1 when a schedule exists for the medication, 0 when the last one is removed. (The Upd trigger uses an explicit transaction with `XACT_ABORT` + TRY/CATCH/THROW.)

> Same denormalized-flag-sync pattern as elsewhere: `StudentMedication.Scheduled` is a cached bit kept in sync by triggers on the schedule table.

---

#### `med.MedicalNoteAddendum`
Addenda to a medical note — append-only notes on a `rw.PersonNote`. PK `AddendumID` (IDENTITY seed 100). FKs → **`rw.PersonNote`** (PersonNoteID), `Person` (CreatedBy).

| Column | Type | Notes |
|---|---|---|
| `AddendumID` | int IDENTITY(100,1) | PK |
| `PersonNoteID` | int | FK → **`rw.PersonNote`** |
| `AddendumText` | nvarchar(max) | The addendum |
| `CreatedByPersonID` / `AddendumDateUTC` | mixed | Audit |

> **Confirms the `rw.PersonNote` materialization target.** Medical notes (`Person.MedicalNote`, NoteType 3) are materialized into `rw.PersonNote` by triggers (documented earlier); this addendum table attaches follow-up notes directly to those `rw.PersonNote` rows.

---

#### `med.ProfilePerson`
Per-person medical profile — records when permission-to-treat was answered. PK `PersonID`. FK → `Person`.

| Column | Type | Notes |
|---|---|---|
| `PersonID` | int | PK; FK → `Person` |
| `PermissionToTreatAnsweredUTC` | datetime2 | When answered |

---

#### `med.ProfileSchool`
Per-school medical settings — max immunization dates (CHECK 1–20), clock format (CHECK 1–2). PK `ConfigSchoolID`. FK → `ConfigSchool`.

| Column | Type | Notes |
|---|---|---|
| `ConfigSchoolID` | smallint | PK; FK → `dbo.ConfigSchool` |
| `MaxImmunizationDates` | tinyint | CHECK 1–20; default 7 |
| `ClockFormatID` | tinyint | CHECK 1–2; default 1 |

---

#### `mail` (continued) / `med` — cross-reference summary

| Table | Schema | Scope / notes |
|---|---|---|
| `ScheduledBatch` | mail | Future-send batch; JSON draft; → `Person_Staff` |
| `SuppressionList` | mail | Do-not-send list; PK `(Email, EmailType)` |
| `MedicalTestConfiguration` | med | Modern med-test config; **triggers sync legacy `ConfigMedicalTests`** |
| `MedicalTestConfigurationField` | med | Config fields; triggers write legacy `Field1`–`Field10` |
| `AdministrationOTC` | med | OTC admin record; → `StudentMedicalEvents`, `OTCConfig` |
| `AdministrationPrescription` | med | Rx admin record; → `StudentMedicalEvents`, `StudentMedication` |
| `MedicalEventMeasurement` | med | Event measurements; PK `(EventID, MeasurementType)` |
| `EventContactMM` | med | Event↔contact; → `StudentMedicalEvents`, `Person` |
| `PersonMedicalEventOTCConfigMM` | med | Event↔OTC config |
| `PersonMedicalEventPersonMedicationMM` | med | Event↔Rx medication |
| `OTCMedicationSchedule` | med | Per-person OTC dosing schedule |
| `PersonMedicationSchedule` | med | Per-Rx dosing schedule; **triggers sync `StudentMedication.Scheduled`** |
| `MedicalNoteAddendum` | med | Note addenda; → **`rw.PersonNote`** |
| `ProfilePerson` | med | Per-person med profile (permission-to-treat) |
| `ProfileSchool` | med | Per-school med settings |

---

### `med` student-medical-test bridge, then `prgm` (Ed-Fi programs) & `prsn` (Ed-Fi person extensions)

### `med` student-medical-test (bridge to legacy `dbo.StudentMedicalTests`)

These complete the `med` ↔ legacy-`dbo` medical-test bridge begun by `MedicalTestConfiguration[Field]`. The modern normalized model is `StudentMedicalTest` (one test instance) + `StudentMedicalTestFieldData` (one row per field value); triggers keep the **legacy denormalized `dbo.StudentMedicalTests`** (PK `TestID`, columns `Field1`–`Field10`) in sync. (See also the `med` overview/health-PII flag in the prior batch.)

> **Contains health PII (HIPAA-adjacent).**

#### `med.StudentMedicalTest`
A student's medical-test instance (modern) — config, student, date. PK `StudentMedicalTestID`. FK → `med.MedicalTestConfiguration` (CASCADE).

| Column | Type | Notes |
|---|---|---|
| `StudentMedicalTestID` | int IDENTITY | PK |
| `MedicalTestConfigurationID` | int | FK → `med.MedicalTestConfiguration` (CASCADE) |
| `StudentID` | int | The student |
| `TestDate` | smalldatetime | — |

**Triggers** (bridge to legacy `dbo.StudentMedicalTests`, keyed `StudentMedicalTestID = TestID`):
- `TR_med_StudentMedicalTest_Ins` (AFTER INSERT, nest-guarded): inserts the matching `StudentMedicalTests` row (`SET IDENTITY_INSERT`, blank Field1–10).
- `TR_med_StudentMedicalTest_Upd` (nest-guarded): syncs StudentID/TestDate changes.
- `TR_med_StudentMedicalTest_Del`: deletes the matching `StudentMedicalTests` row.

---

#### `med.StudentMedicalTestFieldData`
A single field value of a medical test (modern) — value text, keyed to a config field. PK `StudentMedicalTestFieldDataID`. FKs → `med.StudentMedicalTest`, `med.MedicalTestConfigurationField` (CASCADE).

| Column | Type | Notes |
|---|---|---|
| `StudentMedicalTestFieldDataID` | int IDENTITY | PK |
| `StudentMedicalTestID` | int | FK → `med.StudentMedicalTest` |
| `MedicalTestConfigurationFieldID` | int | FK → `med.MedicalTestConfigurationField` (CASCADE) |
| `FieldData` | nvarchar(512) | The value |

**Triggers** (Ins/Upd/Del, nest-guarded): write `FieldData` into legacy `dbo.StudentMedicalTests.Field1`–`Field10` based on the field's `LegacyIndex` (1–10) — insert/update set the column to `FieldData`, delete blanks it. Same `LegacyIndex`→numbered-column bridge as `MedicalTestConfigurationField`. (Source has a few stray empty `GO` batches — harmless.)

> Net effect: the normalized `StudentMedicalTest` + `StudentMedicalTestFieldData` pair is the modern store; every change is mirrored into the legacy denormalized `dbo.StudentMedicalTests.Field1`–`Field10` so legacy reports/screens keep working. The full medical-test bridge (config + field + test + field-data, all four with triggers) is now documented.

---

### `prgm` schema — Ed-Fi federal/state program associations

The **`prgm`** schema models student participation in federal/state programs (Ed-Fi `StudentProgramAssociation` and its specializations: CTE, Title I Part A, Language Instruction/English-learner). `Program` defines a program; `StudentProgramAssociation` is the base enrollment; the specialization tables extend it 1:1 by program type. Used heavily for state/federal reporting.

#### `prgm.Program`
A program definition — name, type, education organization, identifier. PK `ProgramID`. Unique on `(ProgramName, ProgramTypeDescriptorID, EducationOrganizationID)`. FK → `cnfg.EducationOrganization`.

| Column | Type | Notes |
|---|---|---|
| `ProgramID` | int IDENTITY | PK |
| `ProgramName` / `ProgramIdentifier` | nvarchar | — |
| `ProgramTypeDescriptorID` | uniqueidentifier | Ed-Fi descriptor |
| `EducationOrganizationID` | bigint | FK → `cnfg.EducationOrganization` |

---

#### `prgm.ProgramClassMM`
Links programs to classes. PK `(ProgramID, ClassID)`. FKs → `prgm.Program`, `dbo.Classes`.

| Column | Type | Notes |
|---|---|---|
| `ProgramID` / `ClassID` | int | PK (composite); → `Program`, `dbo.Classes` |

---

#### `prgm.StudentProgramAssociation`
**The base student↔program enrollment** — begin/end, exit reason, education org, served-outside-regular-session. PK `StudentProgramAssociationId`. Unique on `(StudentId, ProgramId, BeginDate, EducationOrganizationId)`. FKs → `Person`, `prgm.Program`. Parent of the CTE/Title-I/Language specializations.

| Column | Type | Notes |
|---|---|---|
| `StudentProgramAssociationId` | int IDENTITY | PK |
| `StudentId` | int | FK → `Person` |
| `ProgramId` | int | FK → `prgm.Program`; indexed |
| `BeginDate` / `EndDate` / `ReasonExitedDescriptorId` | mixed | Participation span |
| `EducationOrganizationId` / `ServedOutsideOfRegularSession` | mixed | — |

---

#### `prgm.StudentCTEProgramAssociation`
CTE (Career & Technical Education) specialization of a program association. PK `StudentCTEProgramAssociationID`. FK → `prgm.StudentProgramAssociation`.

| Column | Type | Notes |
|---|---|---|
| `StudentCTEProgramAssociationID` | int IDENTITY | PK |
| `StudentProgramAssociationId` | int | FK → base association; indexed |
| `NonTraditionalGenderStatus` / `PrivateCTEProgram` | bit | — |
| `TechnicalSkillAssessmentDescriptorID` | uniqueidentifier | Ed-Fi descriptor |

---

#### `prgm.StudentCTEProgramAssociationProgramService`
CTE program services within a CTE association — service descriptor, dates, CIP code, primary flag. PK `…ProgramServiceID`. FK → `prgm.StudentCTEProgramAssociation`.

| Column | Type | Notes |
|---|---|---|
| `StudentCTEProgramAssociationProgramServiceID` | int IDENTITY | PK |
| `StudentCTEProgramAssociationID` | int | FK → CTE association; indexed |
| `CTEProgramServiceDescriptorID` | uniqueidentifier | Unique; Ed-Fi descriptor |
| `PrimaryIndicator` / `ServiceBeginDate` / `ServiceEndDate` / `CIPCode` | mixed | Service detail |

---

#### `prgm.StudentTitleIPartAProgramAssociation`
Title I Part A specialization. PK `StudentTitleIPartAProgramAssociationID`. FK → `prgm.StudentProgramAssociation`.

| Column | Type | Notes |
|---|---|---|
| `StudentTitleIPartAProgramAssociationID` | int IDENTITY | PK |
| `StudentProgramAssociationId` | int | FK → base association; indexed |
| `TitleIPartAParticipantDescriptorId` | uniqueidentifier | Ed-Fi descriptor |

---

#### `prgm.StudentLanguageInstructionProgramAssociation`
Language-instruction / English-learner specialization. PK `…AssociationID`. Unique on `StudentProgramAssociationID`. FK → `prgm.StudentProgramAssociation`.

| Column | Type | Notes |
|---|---|---|
| `StudentLanguageInstructionProgramAssociationID` | int IDENTITY | PK |
| `StudentProgramAssociationID` | int | FK → base association; unique |
| `EnglishLearnerParticipation` | bit | — |

---

#### `prgm.StudentLanguageInstructionProgramAssociationLanguageInstructionProgramService`
Language-instruction program services within an LI association — service descriptor, dates, primary flag. PK `…ServiceId`. FK → `prgm.StudentLanguageInstructionProgramAssociation`.

| Column | Type | Notes |
|---|---|---|
| `…LanguageInstructionProgramServiceId` | int IDENTITY | PK |
| `StudentLanguageInstructionProgramAssociationID` | int | FK; indexed |
| `LanguageInstructionProgramServiceDescriptorId` | uniqueidentifier | Ed-Fi descriptor |
| `PrimaryIndicator` / `ServiceBeginDate` / `ServiceEndDate` | mixed | — |

> Note a misnamed default constraint `DF_sped_SSEPASEPS_PrimaryIndicator` (copied from a `sped` table — schema artifact).

---

#### `prgm.StudentLanguageInstructionProgramAssociationEnglishLanguageProficiencyAssessment`
Per-year English-language-proficiency assessment within an LI association — participation/proficiency/progress/monitored descriptors. PK `…AssessmentID`. Unique on `(SchoolYearID, StudentLanguageInstructionProgramAssociationID)`. FKs → `dbo.SchoolYear`, `prgm.StudentLanguageInstructionProgramAssociation`.

| Column | Type | Notes |
|---|---|---|
| `…EnglishLanguageProficiencyAssessmentID` | int IDENTITY | PK |
| `SchoolYearID` | int | FK → `SchoolYear`; unique with association |
| `StudentLanguageInstructionProgramAssociationID` | int | FK; indexed |
| `ParticipationDescriptorID` / `ProficiencyDescriptorID` / `ProgressDescriptorID` / `MonitoredDescriptorID` | uniqueidentifier | Ed-Fi descriptors |

---

### `prsn` schema — Ed-Fi person demographic extensions

The **`prsn`** schema holds Ed-Fi-aligned person demographic detail that extends `dbo.Person` (the legacy person record): identification documents, ancestry/ethnic origin, birth detail, electronic mail. All FK to `Person`. (Joins the previously-documented `prsn.StudentEducationOrganizationAssociation*` tables.)

> **Contains PII** (identity documents, birth, citizenship, email).

#### `prsn.IdentificationDocument`
Identity documents for a person — type/use, verification, expiration, issuer. PK `IdentificationDocumentID`. Unique clustered on `(PersonID, UseDescriptorID, VerificationDescriptorID)`. FK → `Person`.

| Column | Type | Notes |
|---|---|---|
| `IdentificationDocumentID` | int IDENTITY | PK (nonclustered) |
| `PersonID` | int | FK → `Person`; part of unique clustered |
| `IdentificationDocumentUseDescriptorID` / `PersonalInformationVerificationDescriptorID` | uniqueidentifier | Ed-Fi descriptors; in unique key |
| `DocumentTitle` / `DocumentExpirationDate` | mixed | — |
| `IssuerCountryDescriptorID` / `IssuerDocumentIdentificationCode` / `IssuerName` | mixed | Issuer |
| `Personal` | bit | — |

---

#### `prsn.AncestryEthnicOrigin`
Ancestry/ethnic-origin descriptors for a person. PK `AncestryEthnicOriginID`. Unique on `(PersonID, AncestryEthnicOriginDescriptorID)`. FK → `Person`.

| Column | Type | Notes |
|---|---|---|
| `AncestryEthnicOriginID` | int IDENTITY | PK |
| `PersonID` | int | FK → `Person`; unique with descriptor |
| `AncestryEthnicOriginDescriptorID` | uniqueidentifier | Ed-Fi descriptor |

---

#### `prsn.Birth`
Birth/citizenship detail for a person (1:1). PK `PersonID`. FK → `Person`.

| Column | Type | Notes |
|---|---|---|
| `PersonID` | int | PK; FK → `Person` |
| `BirthInternationalProvince` / `BirthStateAbbreviationDescriptorId` / `BirthSexDescriptorId` | mixed | Birth place/sex |
| `CitizenshipStatusDescriptorId` / `DateEnteredUS` / `MultipleBirthStatus` | mixed | Citizenship |

---

#### `prsn.ElectronicMail`
Email addresses for a person — type, primary, do-not-publish. PK `ElectronicMailID`. Unique clustered on `(PersonID, Address, TypeDescriptorID)`. FK → `Person`.

| Column | Type | Notes |
|---|---|---|
| `ElectronicMailID` | int IDENTITY | PK (nonclustered) |
| `PersonID` | int | FK → `Person`; in unique clustered |
| `ElectronicMailAddress` / `ElectronicMailTypeDescriptorID` | mixed | In unique key |
| `PrimaryEmailAddressIndicator` / `DoNotPublishIndicator` | bit | — |

---

#### `med` (test bridge) / `prgm` / `prsn` — cross-reference summary

| Table | Schema | Scope / notes |
|---|---|---|
| `StudentMedicalTest` | med | Modern med-test instance; **triggers sync legacy `StudentMedicalTests`** |
| `StudentMedicalTestFieldData` | med | Modern field values; triggers write legacy `Field1`–`Field10` |
| `Program` | prgm | Program def; → `cnfg.EducationOrganization` |
| `ProgramClassMM` | prgm | Program↔class; → `dbo.Classes` |
| `StudentProgramAssociation` | prgm | **Base student↔program enrollment**; → `Person`, `Program` |
| `StudentCTEProgramAssociation` | prgm | CTE specialization |
| `StudentCTEProgramAssociationProgramService` | prgm | CTE services |
| `StudentTitleIPartAProgramAssociation` | prgm | Title I Part A specialization |
| `StudentLanguageInstructionProgramAssociation` | prgm | English-learner specialization |
| `StudentLanguageInstructionProgramAssociationLanguageInstructionProgramService` | prgm | LI services |
| `StudentLanguageInstructionProgramAssociationEnglishLanguageProficiencyAssessment` | prgm | Per-year ELP assessment; → `SchoolYear` |
| `IdentificationDocument` | prsn | Identity docs; **PII**; → `Person` |
| `AncestryEthnicOrigin` | prsn | Ancestry/ethnicity; → `Person` |
| `Birth` | prsn | Birth/citizenship (1:1); **PII**; → `Person` |
| `ElectronicMail` | prsn | Email addresses; **PII**; → `Person` |

---

### `prsn` schema (continued) — person languages, staff Ed-Fi associations, student Ed-Org association

This substantially completes the `prsn` schema: person language tables, the Ed-Fi **staff** associations (employment → assignment, credentials, recognition, school-association with subject/grade-level children), and the Ed-Fi **student education-organization association** with its characteristic/indicator children (the demographic-snapshot record used heavily for state/federal reporting).

> **Contains PII** (demographics, languages, internet-access, credentials, wages). All link to `dbo.Person`/`dbo.Person_Staff`.

#### `prsn.Language`
Languages associated with a person, with a primary flag. PK `LanguageId`. Unique on `(PersonID, LanguageDescriptorId)`. FK → `Person`.

| Column | Type | Notes |
|---|---|---|
| `LanguageId` | int IDENTITY | PK |
| `PersonID` | int | FK → `Person`; unique with descriptor |
| `LanguageDescriptorId` | uniqueidentifier | Ed-Fi descriptor |
| `PrimaryLanguage` | bit | — |

---

#### `prsn.LanguageUse`
Uses of a person-language (e.g. home, instruction). PK `LanguageUseID`. Unique on `(LanguageID, LanguageUseDescriptorID)`. FK → `prsn.Language`.

| Column | Type | Notes |
|---|---|---|
| `LanguageUseID` | int IDENTITY | PK |
| `LanguageID` | int | FK → `prsn.Language`; unique with descriptor |
| `LanguageUseDescriptorID` | uniqueidentifier | Ed-Fi descriptor |

---

### `prsn` — Ed-Fi staff associations

Staff employment/assignment chain: `StaffEducationOrganizationEmploymentAssociation` (employment) → `StaffEducationOrganizationAssignmentAssociation` (assignment within an employment). Plus credentials, identification codes, recognition, and a per-year `StaffSchoolAssociation` (with subject + grade-level children).

#### `prsn.StaffEducationOrganizationEmploymentAssociation`
Staff employment at an education organization — hire/offer/end dates, employment status, separation, department, FTE, hourly wage. PK `SEOEAId`. Unique on `(EducationOrganizationID, StaffID, HireDate, EmploymentStatusDescriptorID)`. FKs → `cnfg.EducationOrganization`, `Person_Staff`.

| Column | Type | Notes |
|---|---|---|
| `SEOEAId` | int IDENTITY | PK |
| `EducationOrganizationID` | bigint | FK → `cnfg.EducationOrganization` |
| `StaffID` | int | FK → `Person_Staff` |
| `HireDate` / `OfferDate` / `EndDate` | date | Employment span |
| `EmploymentStatusDescriptorID` / `SeparationDescriptorID` / `SeparationReasonDescriptorID` | uniqueidentifier | Ed-Fi descriptors |
| `Department` / `FullTimeEquivalency` / `HourlyWage` | mixed | **Wage = sensitive** |

---

#### `prsn.StaffEducationOrganizationAssignmentAssociation`
A position assignment within a staff employment — classification, title, dates, order, credential, FTE. PK `SEOAAId`. FK → `prsn.StaffEducationOrganizationEmploymentAssociation`.

| Column | Type | Notes |
|---|---|---|
| `SEOAAId` | int IDENTITY | PK |
| `SEOEmploymentAssociationId` | int | FK → employment association |
| `StaffClassificationDescriptorId` / `PositionTitle` | mixed | The role |
| `BeginDate` / `EndDate` / `OrderOfAssignment` | mixed | — |
| `CredentialIdentifier` / `StateOfIssueStateAbbreviationDescriptorId` / `FullTimeEquivalency` | mixed | — |

---

#### `prsn.StaffCredential`
Staff credentials — identifier + state of issue. PK `StaffCredentialId`. Unique clustered on `(StaffId, CredentialIdentifier)`. FK → `Person_Staff`.

| Column | Type | Notes |
|---|---|---|
| `StaffCredentialId` | int IDENTITY | PK (nonclustered) |
| `StaffId` | int | FK → `Person_Staff`; in unique key |
| `CredentialIdentifier` / `StateOfIssueStateAbbreviationDescriptorId` | mixed | — |

---

#### `prsn.StaffIdentificationCode`
Staff identification codes by system (e.g. state staff id). PK `StaffIdentificationCodeId`. FK → **`Person`** (note: FK targets `Person.PersonID`, not `Person_Staff`).

| Column | Type | Notes |
|---|---|---|
| `StaffIdentificationCodeId` | int IDENTITY | PK |
| `StaffID` | int | FK → `dbo.Person` |
| `StaffIdentificationSystemDescriptorID` / `IdentificationCode` / `AssignmentOrganizationIdentifiicationCode` (sic) | mixed | Note the misspelled column |

---

#### `prsn.StaffRecognition`
Staff recognitions/awards/badges — type, title, issuer, criteria, image/URLs, award dates. PK `StaffRecognitionId`. Unique clustered on `(StaffId, RecognitionTypeDescriptorId, RecognitionAwardDate)`. FK → `Person_Staff`.

| Column | Type | Notes |
|---|---|---|
| `StaffRecognitionId` | int IDENTITY | PK (nonclustered) |
| `StaffId` | int | FK → `Person_Staff`; in unique key |
| `RecognitionTypeDescriptorId` / `AchievementTitle` / `AchievementCategoryDescriptorId` / `AchievementCategorySystem` | mixed | The recognition |
| `IssuerName` / `IssuerOriginURL` / `Criteria` / `CriteriaURL` / `EvidenceStatement` / `ImageURL` | mixed | Open-badge-style fields |
| `RecognitionDescription` / `RecognitionAwardDate` / `RecognitionAwardExpiresDate` | mixed | — |

---

#### `prsn.StaffSchoolAssociation`
Per-year staff↔school program-assignment association. PK `StaffSchoolAssociationID`. Unique clustered on `(StaffID, SchoolYearID)`. FKs → `Person_Staff`, `SchoolYear`. Parent of the subject + grade-level children.

| Column | Type | Notes |
|---|---|---|
| `StaffSchoolAssociationID` | int IDENTITY | PK (nonclustered) |
| `StaffID` | int | FK → `Person_Staff`; unique with year |
| `SchoolYearID` | int | FK → `SchoolYear` |
| `ProgramAssignmentDescriptorID` | uniqueidentifier | Ed-Fi descriptor |

---

#### `prsn.StaffSchoolAssociationAcademicSubject`
Academic subjects taught within a staff-school association. PK `…AcademicSubjectID`. FK → `prsn.StaffSchoolAssociation`.

| Column | Type | Notes |
|---|---|---|
| `StaffSchoolAssociationAcademicSubjectID` | int IDENTITY | PK |
| `StaffSchoolAssociationID` | int | FK → `prsn.StaffSchoolAssociation` |
| `AcademicSubjectDescriptorID` | uniqueidentifier | Ed-Fi descriptor (unique) |

---

#### `prsn.StaffSchoolAssociationGradeLevel`
Grade levels taught within a staff-school association. PK `…GradeLevelId`. Unique clustered on `(StaffSchoolAssociationId, GradeLevelDescriptorId)`. FK → `prsn.StaffSchoolAssociation`.

| Column | Type | Notes |
|---|---|---|
| `StaffSchoolAssociationGradeLevelId` | int IDENTITY | PK (nonclustered) |
| `StaffSchoolAssociationId` | int | FK → `prsn.StaffSchoolAssociation` |
| `GradeLevelDescriptorId` | uniqueidentifier | Ed-Fi descriptor |

---

### `prsn` — Ed-Fi student education-organization association

#### `prsn.StudentEducationOrganizationAssociation`
**The Ed-Fi student demographic-snapshot record** at an education organization per year — sex, LEP, learning-device/internet-access descriptors. PK `StudentEducationOrganizationAssociationId`. FKs → `cnfg.EducationOrganization`, `Person`, `SchoolYear`. Parent of the characteristic + indicator children. (Heavily used for state/federal reporting; complements `enrl.StudentSchoolAssociation`.)

| Column group | Type | Notes |
|---|---|---|
| `StudentEducationOrganizationAssociationId` | int IDENTITY | PK |
| `EducationOrganizationId` | bigint | FK → `cnfg.EducationOrganization`; indexed |
| `StudentId` | int | FK → `Person`; indexed |
| `SchoolYearId` | int | FK → `SchoolYear`; indexed |
| `SexDescriptorId` / `LimitedEnglishProficiencyDescriptorId` | uniqueidentifier | Demographics |
| Learning device: `PrimaryLearningDeviceAwayFromSchoolDescriptorId` / `…AccessDescriptorId` / `…ProviderDescriptorId` | uniqueidentifier | Remote-learning (COVID-era Ed-Fi) |
| Internet: `InternetAccessInResidence` / `BarrierToInternetAccessInResidenceDescriptorId` / `InternetAccessTypeInResidenceDescriptorId` / `InternetPerformanceInResidenceDescriptorId` | mixed | Residence connectivity |

---

#### `prsn.StudentEducationOrganizationAssociationStudentCharacteristic`
Student characteristics (e.g. homeless, migrant, economic-disadvantage) on the SEOA, with who designated it. PK `SEOAStudentCharacteristicID`. Unique on `(SEOAId, CharacteristicDescriptorID)`. FK → `prsn.StudentEducationOrganizationAssociation`.

| Column | Type | Notes |
|---|---|---|
| `SEOAStudentCharacteristicID` | int IDENTITY | PK |
| `StudentEducationOrganizationAssociationId` | int | FK → SEOA; unique with descriptor |
| `StudentCharacteristicDescriptorID` | uniqueidentifier | Ed-Fi descriptor |
| `DesignatedBy` | nvarchar(60) | Who flagged it |

---

#### `prsn.StudentEducationOrganizationAssociationStudentCharacteristicPeriod`
Time-bounded periods for a student characteristic (begin/end). PK `SEOAStudentCharacteristicPeriodID`. FK → `prsn.StudentEducationOrganizationAssociationStudentCharacteristic`.

| Column | Type | Notes |
|---|---|---|
| `SEOAStudentCharacteristicPeriodID` | int IDENTITY | PK |
| `SEOAStudentCharacteristicID` | int | FK → characteristic; indexed; unique with BeginDate |
| `StudentCharacteristicDescriptorID` | uniqueidentifier | (denormalized for indexing) |
| `BeginDate` / `EndDate` | date | Period |

---

#### `prsn.StudentEducationOrganizationAssociationStudentIndicator`
Named indicators on the SEOA (generic flag/value, grouped). PK `SEOAStudentIndicatorId`. FK → `prsn.StudentEducationOrganizationAssociation`.

| Column | Type | Notes |
|---|---|---|
| `SEOAStudentIndicatorId` | int IDENTITY | PK |
| `StudentEducationOrganizationAssociationId` | int | FK → SEOA; indexed |
| `IndicatorName` / `Indicator` / `IndicatorGroup` / `DesignatedBy` | mixed | Generic indicator |

---

#### `prsn.StudentEducationOrganizationAssociationStudentIndicatorPeriod`
Time-bounded periods for a student indicator (begin/end). PK `SEOAStudentIndicatorPeriodId`. Unique on `(IndicatorName, BeginDate)`. FK → `prsn.StudentEducationOrganizationAssociationStudentIndicator`.

| Column | Type | Notes |
|---|---|---|
| `SEOAStudentIndicatorPeriodId` | int IDENTITY | PK |
| `SEOAStudentIndicatorId` | int | FK → indicator; indexed |
| `IndicatorName` | nvarchar(200) | Unique with BeginDate |
| `BeginDate` / `EndDate` | date | Period |

---

#### `prsn` (continued) — cross-reference summary

| Table | Schema | Scope / notes |
|---|---|---|
| `Language` | prsn | Person languages; → `Person` |
| `LanguageUse` | prsn | Language uses; → `prsn.Language` |
| `StaffEducationOrganizationEmploymentAssociation` | prsn | Staff employment; → `cnfg.EducationOrganization`, `Person_Staff`; **wage** |
| `StaffEducationOrganizationAssignmentAssociation` | prsn | Position assignment; → employment assoc |
| `StaffCredential` | prsn | Staff credentials; → `Person_Staff` |
| `StaffIdentificationCode` | prsn | Staff id codes; → `Person` (not `Person_Staff`) |
| `StaffRecognition` | prsn | Staff awards/badges; → `Person_Staff` |
| `StaffSchoolAssociation` | prsn | Per-year staff↔school; → `Person_Staff`, `SchoolYear` |
| `StaffSchoolAssociationAcademicSubject` | prsn | Subjects taught |
| `StaffSchoolAssociationGradeLevel` | prsn | Grade levels taught |
| `StudentEducationOrganizationAssociation` | prsn | **Ed-Fi student demo snapshot**; → `cnfg.EducationOrganization`, `Person`, `SchoolYear` |
| `StudentEducationOrganizationAssociationStudentCharacteristic` | prsn | Student characteristics |
| `StudentEducationOrganizationAssociationStudentCharacteristicPeriod` | prsn | Characteristic periods |
| `StudentEducationOrganizationAssociationStudentIndicator` | prsn | Student indicators |
| `StudentEducationOrganizationAssociationStudentIndicatorPeriod` | prsn | Indicator periods |

---

### `prsn` schema (final) — student id/restrictions/contact, then `ptc` (parent-teacher conferences) & `pwb` (ParentsWeb portal)

### `prsn` schema (final tables)

These complete the `prsn` schema: student identification codes, student↔staff and student↔student restrictions (both temporal), telephone, tribal affiliation, visa, and the student education-organization *responsibility* association.

> **Contains PII** (phone, visa, tribal affiliation, identification codes).

#### `prsn.StudentIdentificationCode`
Student identification codes by system (e.g. state student id). PK `StudentIdentificationCodeId`. Unique clustered on `(PersonId, AssigningOrganizationIdentificationCode, StudentIdentificationSystemDescriptorId)`. FK → `Person`.

| Column | Type | Notes |
|---|---|---|
| `StudentIdentificationCodeId` | int IDENTITY | PK (nonclustered) |
| `PersonId` | int | FK → `Person`; in unique key |
| `AssigningOrganizationIdentificationCode` / `StudentIdentificationSystemDescriptorId` / `IdentificationCode` | mixed | The code |

---

#### `prsn.StudentStaffRestriction`
**Temporal table.** A restriction between a student and a staff member (e.g. no-contact), with reason and audit. PK `StudentStaffRestrictionId`. Unique on `(StaffId, StudentId)`. FKs → `Person_Staff` (StaffId), `Person` (StudentId, CreatedBy).

| Column | Type | Notes |
|---|---|---|
| `StudentStaffRestrictionId` | int IDENTITY | PK |
| `StaffId` | int | FK → `Person_Staff`; unique with StudentId |
| `StudentId` | int | FK → `Person`; indexed |
| `CreatedByPersonId` | int | FK → `Person`; indexed |
| `Reason` | nvarchar(200) | — |
| `CreatedOnUTC` / `ModifiedOnUTC` / `ModifiedOnUTCmax` | datetime2 | Temporal (system-versioned) |

---

#### `prsn.StudentStudentRestriction`
**Temporal table.** A restriction between two students (e.g. keep-apart), with reason. PK `StudentStudentRestrictionId`. CHECK `Student1Id < Student2Id` (canonical ordering to avoid duplicate pairs). Unique on `(Student1Id, Student2Id)`. FKs → `Person` (×3).

| Column | Type | Notes |
|---|---|---|
| `StudentStudentRestrictionId` | int IDENTITY | PK |
| `Student1Id` / `Student2Id` | int | FKs → `Person`; CHECK `1 < 2`; unique together |
| `CreatedByPersonId` | int | FK → `Person`; indexed |
| `Reason` | nvarchar(200) | — |
| `CreatedOnUTC` / `ModifiedOnUTC` / `ModifiedOnUTCmax` | datetime2 | Temporal (system-versioned) |

> The `Student1Id < Student2Id` CHECK is a nice idiom: it guarantees an unordered pair is stored exactly once (no need to check both orderings).

---

#### `prsn.Telephone`
Phone numbers for a person — type, priority, do-not-publish, text-capable. PK `TelephoneId`. FK → `Person`.

| Column | Type | Notes |
|---|---|---|
| `TelephoneId` | int IDENTITY | PK |
| `PersonId` | int | FK → `Person`; indexed with number+type |
| `TelephoneNumber` / `TelephoneNumberTypeDescriptorId` | mixed | The number |
| `DoNotPublishIndicator` / `OrderOfPriority` / `TextMessageCapabilityIndicator` | mixed | — |

---

#### `prsn.TribalAffiliation`
Tribal affiliations for a person. PK `TribalAffiliationID`. Unique clustered on `(PersonID, TribalAffiliationDescriptorID)`. FK → `Person`.

| Column | Type | Notes |
|---|---|---|
| `TribalAffiliationID` | int IDENTITY | PK (nonclustered) |
| `PersonID` | int | FK → `Person`; in unique key |
| `TribalAffiliationDescriptorID` | uniqueidentifier | Ed-Fi descriptor |

---

#### `prsn.Visa`
Visa for a person (1:1). PK `PersonID`. FK → `Person`. (Unique index on `VisaDescriptorID` alone — effectively one person per visa descriptor, likely unintended but recorded as-is.)

| Column | Type | Notes |
|---|---|---|
| `PersonID` | int | PK; FK → `Person` |
| `VisaDescriptorID` | uniqueidentifier | Unique (standalone) |

---

#### `prsn.StudentEducationOrganizationResponsibilityAssociation`
Responsibility association — which education org is responsible for a student over a date range. PK `SEORAId`. Unique on `(EducationOrganizationId, BeginDate, ResponsibilityDescriptorId, StudentId)`. FKs → `cnfg.EducationOrganization`, `Person`.

| Column | Type | Notes |
|---|---|---|
| `SEORAId` | int IDENTITY | PK |
| `StudentId` | int | FK → `Person`; indexed |
| `EducationOrganizationId` | bigint | FK → `cnfg.EducationOrganization` |
| `ResponsibilityDescriptorId` | uniqueidentifier | Ed-Fi descriptor |
| `BeginDate` / `EndDate` | date | Responsibility span |

> **`prsn` schema now complete** across all batches: person extensions (IdentificationDocument/AncestryEthnicOrigin/Birth/ElectronicMail), languages, staff Ed-Fi associations, student Ed-Org association + characteristics/indicators, and these final id/restriction/contact/responsibility tables.

---

### `ptc` schema — parent-teacher conferences

The **`ptc`** schema schedules parent-teacher conferences: a `Conference` has time `Slot`s and targets an audience (`AudienceClass`); `Invitee` records who's invited/scheduled and notification status.

#### `ptc.Conference`
A parent-teacher conference event — title, message, location, per-slot capacity, registration cutoff, owning staff, email flag. PK `ConferenceId`. FKs → `Person` (Staff, CreatedBy, UpdatedBy — all → `Person`).

| Column | Type | Notes |
|---|---|---|
| `ConferenceId` | int IDENTITY | PK |
| `Title` / `Message` / `Location` | nvarchar | — |
| `CapacityPerSlot` / `EndRegistrationDaysBefore` / `SendEmail` | mixed | Scheduling rules |
| `StaffId` | int | FK → `Person`; owning staff |
| `CreatedBy` / `CreatedUTC` / `UpdatedBy` / `UpdatedUTC` | mixed | Audit (FKs → `Person`) |

---

#### `ptc.Slot`
A time slot within a conference — begin/end, capacity, scheduled count. PK `SlotId`. FK → `ptc.Conference` (CASCADE).

| Column | Type | Notes |
|---|---|---|
| `SlotId` | int IDENTITY | PK |
| `ConferenceId` | int | FK → `ptc.Conference` (CASCADE) |
| `BeginDateTime` / `EndDateTime` | datetime2 | Slot time |
| `AssignedCapacity` / `ScheduledCount` | smallint | Capacity tracking |

---

#### `ptc.AudienceClass`
Targets a conference at a class's families. PK `AudienceClassId`. FKs → `ptc.Conference` (CASCADE), `dbo.Classes`.

| Column | Type | Notes |
|---|---|---|
| `AudienceClassId` | int IDENTITY | PK |
| `ConferenceId` | int | FK → `ptc.Conference` (CASCADE) |
| `ClassId` | int | FK → `dbo.Classes` |

---

#### `ptc.Invitee`
An invited person for a conference — optional audience-class + booked slot, with inbound/outbound notification type+timestamps. PK `InviteeId`. FKs → `ptc.AudienceClass` (CASCADE), `ptc.Slot`, `Person`.

| Column | Type | Notes |
|---|---|---|
| `InviteeId` | int IDENTITY | PK |
| `AudienceClassId` | int | FK → `ptc.AudienceClass` (CASCADE) |
| `SlotId` | int | FK → `ptc.Slot` (booked slot, nullable) |
| `PersonId` | int | FK → `Person` |
| `OutboundNotificationType` / `OutboundNotificationUTC` / `InboundNotificationType` / `InboundNotificationUTC` | mixed | Notification status |

---

### `pwb` schema — ParentsWeb portal (legacy parent portal)

The **`pwb`** schema backs the legacy **ParentsWeb** parent/student portal: session/login records (`ParentsWebFamily` + `ParentsWebStudent`) and per-school theming (`DesignConfig` for desktop, `MobileDesignConfig` for mobile). (ParentsWeb is the older RenWeb-era portal branding; another legacy-vs-current artifact.)

#### `pwb.ParentsWebFamily`
A ParentsWeb login session for a family/user — session id, district, user, email, financial-responsibility, current class. PK `ParentsWebFamilyID`.

| Column | Type | Notes |
|---|---|---|
| `ParentsWebFamilyID` | int IDENTITY | PK |
| `SessionID` | nvarchar(128) | Indexed |
| `UserID` / `UserType` / `Email` / `UserFirstName` / `UserLastName` | mixed | The logged-in user |
| `DistrictCode` / `FamilyID` / `FinancialResponsibility` / `CurrentClassID` | mixed | — |
| `LoginDateTime` | smalldatetime | — |

---

#### `pwb.ParentsWebStudent`
Per-student portal context within a ParentsWeb session — the student's web-items payload, year/term, name. PK is composite `(ParentsWebFamilyID, StudentID, StudentIndex)`. FKs → `pwb.ParentsWebFamily`, `dbo.ConfigSchool`.

| Column | Type | Notes |
|---|---|---|
| `ParentsWebFamilyID` | int | PK (composite); FK → `pwb.ParentsWebFamily` |
| `StudentID` / `StudentIndex` | int | PK (composite); indexed |
| `ConfigSchoolID` | smallint | FK → `dbo.ConfigSchool` |
| `WebItems` | nvarchar(max) | Per-student portal payload |
| `YearID` / `TermID` / `FirstName` / `LastName` | mixed | Context |

---

#### `pwb.DesignConfig`
**Per-school desktop portal theming** — an extensive set of color/layout/font tokens (left-menu, content, tabs, tables, scrollbars), header images/logo, additional CSS, analytics (GA UA), layout version, live flag. PK `DesignConfigID`. FK → `dbo.ConfigSchool`. (~60 styling columns, all defaulted; documented by group.)

| Column group | Type | Notes |
|---|---|---|
| `DesignConfigID` | smallint IDENTITY | PK |
| `ConfigSchoolID` | smallint | FK → `dbo.ConfigSchool` |
| Left menu: `LeftMenu*` (width/color/hover/border/background/header…) | varchar(6)/smallint | Hex colors |
| Content: `Content*` (head/border/background/tab…) | varchar(6) | Hex colors |
| Student tab: `StudentTab*` | varchar(6) | Hex colors |
| Tables: `DataTable*` / `SortableHeader*` / `OddRowBackground` | varchar(6) | Hex colors |
| Buttons/body/scroll: `Button*` / `Body*` / `Scroll*` | varchar(6) | Hex colors |
| Header: `HeaderBackgroundImage` / `HeaderLogoImage` / `HeaderColor` / `HeaderTextOnly` / `BannerLinkURL` | mixed | Branding |
| Fonts: `FontSize` / `FontType` | mixed | Default Roboto 12 |
| `AdditionalCSS` / `CustomTemplate` / `LayoutVersion` / `SiteWidth` / `IsLive` | mixed | Layout |
| Analytics: `GoogleAnalyticsUA` / `AnalyticsType` | mixed | — |
| `SchoolSiteMemberID` / `LastModified` | mixed | — |

---

#### `pwb.MobileDesignConfig`
**Per-school mobile portal theming** — header/body colors, home-page graphic, header link, design-preview user. PK `MobileDesignConfigID`. FK → `dbo.ConfigSchool`.

| Column | Type | Notes |
|---|---|---|
| `MobileDesignConfigID` | smallint IDENTITY | PK |
| `ConfigSchoolID` | smallint | FK → `dbo.ConfigSchool` |
| `HeaderColor` / `HeaderTextColor` / `BodyColor` / `BodyTextColor` | varchar(6) | Hex colors |
| `HomePageGraphicURL` / `HeaderLinkURL` / `DesignPreviewForUserID` | mixed | — |

---

#### `prsn` (final) / `ptc` / `pwb` — cross-reference summary

| Table | Schema | Scope / notes |
|---|---|---|
| `StudentIdentificationCode` | prsn | Student id codes; → `Person` |
| `StudentStaffRestriction` | prsn | Student↔staff restriction; **temporal**; → `Person_Staff`, `Person` |
| `StudentStudentRestriction` | prsn | Student↔student restriction; **temporal**; CHECK `1<2` |
| `Telephone` | prsn | Phones; **PII**; → `Person` |
| `TribalAffiliation` | prsn | Tribal affiliation; → `Person` |
| `Visa` | prsn | Visa (1:1); **PII**; → `Person` |
| `StudentEducationOrganizationResponsibilityAssociation` | prsn | Responsibility assoc; → `cnfg.EducationOrganization`, `Person` |
| `Conference` | ptc | PTC event; → `Person` (staff/created/updated) |
| `Slot` | ptc | Conference time slot; → `Conference` |
| `AudienceClass` | ptc | Conference↔class audience; → `Conference`, `dbo.Classes` |
| `Invitee` | ptc | Invited person + booking + notify; → `AudienceClass`, `Slot`, `Person` |
| `ParentsWebFamily` | pwb | Portal login session |
| `ParentsWebStudent` | pwb | Per-student portal context; → `ParentsWebFamily`, `ConfigSchool` |
| `DesignConfig` | pwb | Per-school desktop theming (~60 tokens) |
| `MobileDesignConfig` | pwb | Per-school mobile theming |

---

### `ref` (reference lookups), `rpt` (report customization), `rsys` (system/retention), `rw` (RenWeb-refactor) schemas

### `ref` schema — reference/lookup types

The **`ref`** schema holds small reference/lookup tables (type enumerations) used across the app — auto-scheduler algorithm priorities, course time frames, language codes, MS time zones, OA (Online Application) type enumerations, and person state-identifier types. Resolves several long-pending references (`OAColumnSourceType`, `OAReportSettingsType`, `MSTimeZones`, `LanguageCode`).

#### `ref.AutoSchedulerAlgorithmPriorityType`
Algorithm-priority types for the auto-scheduler — grouped (Scheduling/Enrollment/Other) and ordered to drive auto-schedule runs. PK `AutoSchedulerAlgorithmPriorityTypeId`. CHECK on `AlgorithmGroup`.

| Column | Type | Notes |
|---|---|---|
| `AutoSchedulerAlgorithmPriorityTypeId` | tinyint IDENTITY | PK |
| `Name` / `Description` | nvarchar | e.g. "Singleton Sections" |
| `AlgorithmGroup` | nvarchar(10) | CHECK {Scheduling, Enrollment, Other}; default Scheduling |
| `CanDeactivate` | bit | — |

---

#### `ref.CourseTimeFrame`
Course time-frame lookup (e.g. full year, semester). PK `CourseTimeFrameID`. Unique on `TimeFrame`.

| Column | Type | Notes |
|---|---|---|
| `CourseTimeFrameID` | tinyint IDENTITY | PK |
| `TimeFrame` | nvarchar(15) | Unique |

---

#### `ref.LanguageCode`
2-char language-code lookup. PK `LangCode`.

| Column | Type | Notes |
|---|---|---|
| `LangCode` | char(2) | PK |
| `LangName` | nvarchar(50) | — |

> Note: there are now **three language lookups** — `ref.LanguageCode` (2-char codes), `rsys.LanguageList` (tagged, this batch), and the Ed-Fi `prsn.Language` (per-person, descriptor-based). Distinct purposes (UI codes vs system tags vs per-person Ed-Fi).

---

#### `ref.MSTimeZones`
Microsoft time-zone id ↔ display-name lookup. PK `MicrosoftTimeZoneID`. (Resolves the `MSTimeZones` reference from the `lms.Unit`/timezone columns.)

| Column | Type | Notes |
|---|---|---|
| `MicrosoftTimeZoneID` | varchar(100) | PK |
| `Display` | varchar(100) | — |

---

#### `ref.OAColumnSourceType`
Online-Application column-source-type lookup. PK `OAColumnSourceTypeId`.

| Column | Type | Notes |
|---|---|---|
| `OAColumnSourceTypeId` | int | PK |
| `Description` | nvarchar(50) | — |

---

#### `ref.OAImportStatusType`
OA import-status-type lookup. PK `OAImportStatusTypeID`.

| Column | Type | Notes |
|---|---|---|
| `OAImportStatusTypeID` | tinyint | PK |
| `Name` | nvarchar(50) | — |

---

#### `ref.OAReportSettingsType`
OA report-settings-type lookup. PK `OAReportSettingsTypeId`. (PK constraint misnamed `PK_dbo_…` — schema artifact.)

| Column | Type | Notes |
|---|---|---|
| `OAReportSettingsTypeId` | int | PK |
| `Description` | nvarchar(50) | — |

---

#### `ref.OAStandardReportingType`
OA standard-reporting-type lookup. PK `OAStandardReportingTypeId`.

| Column | Type | Notes |
|---|---|---|
| `OAStandardReportingTypeId` | int | PK |
| `Description` | nvarchar(50) | — |

---

#### `ref.PersonStateIdentifierType`
Person state-identifier-type lookup (kinds of state-issued IDs). PK `TypeId`.

| Column | Type | Notes |
|---|---|---|
| `TypeId` | smallint | PK |
| `StateIdentifierType` | nvarchar(30) | — |

---

### `rpt` schema — report customization

#### `rpt.CustomizationRC`
**Per-school report-card customization** — which derived fields to include (term GPA/UGPA, cumulative HS GPA, term honor roll, promoted-to), plus logo/signature images and signature text. PK `CustomizationRCID`. FK → `dbo.ConfigSchool`. (Directly relevant to report-card rendering — toggles optional report-card elements per school.)

| Column | Type | Notes |
|---|---|---|
| `CustomizationRCID` | int IDENTITY | PK |
| `ConfigSchoolID` | smallint | FK → `dbo.ConfigSchool` |
| `IncludeTermGpa` / `IncludeTermUgpa` / `IncludeChsGpa` / `IncludeTermHonorRoll` / `IncludePromotedTo` | bit | Optional RC elements |
| `ReportLogoImagePath` / `SignatureImagePath` / `SignatureText` | mixed | Branding/signature |

---

### `rsys` schema — system / data-retention

The **`rsys`** schema holds system-level tables: a language list and the data-retention audit framework (`RetentionAuditDatabase` per run + `RetentionAuditTable` per table within a run, with computed pct/elapsed columns and a What-If mode).

#### `rsys.LanguageList`
Tagged language list (system-level). PK `LanguageID`.

| Column | Type | Notes |
|---|---|---|
| `LanguageID` | int | PK |
| `Tag` | varchar(8) | Language tag (e.g. en-US) |
| `LanguageName` | nvarchar(64) | — |

---

#### `rsys.RetentionAuditDatabase`
A data-retention purge run (database-level) — What-If flag, records tested/purged (+ computed pct), timing (+ computed elapsed), status, error. PK `DbAuditID`.

| Column | Type | Notes |
|---|---|---|
| `DbAuditID` | int IDENTITY | PK |
| `WhatIf` | bit | Default 1 (dry-run by default) |
| `CntRecordsTested` / `CntRecordsPurged` | bigint | — |
| `PctRecordsPurged` | computed | Purged/Tested×100 |
| `TimestampStart` / `TimestampCompleted` | datetime2 | — |
| `ElapsedSec` | computed | datediff seconds |
| `ExecStatus` / `ErrorMsg` | mixed | — |

---

#### `rsys.RetentionAuditTable`
Per-table detail within a retention run — target table/PK/date-field, retain weeks, counts (records/expired/deleted + computed pct), max-expired-id, timing. PK `TableAuditID`. FK → `rsys.RetentionAuditDatabase` (CASCADE).

| Column | Type | Notes |
|---|---|---|
| `TableAuditID` | int IDENTITY | PK |
| `DbAuditID` | int | FK → `RetentionAuditDatabase` (CASCADE) |
| `WhatIf` | bit | Default 1 |
| `NameSchemaTable` / `NameFieldPK` / `ObjectDateTest` | sysname | Target table/PK/date column |
| `RetainWeeks` | smallint | Retention window |
| `CntRecords` / `CntExpired` / `CntDeleted` / `MaxExpiredID` | bigint | Counts |
| `PctExpired` | computed | Expired/Records×100 |
| `TimestampStart` / `TimestampEnd` / `ElapsedSec` (computed) / `ExecStatus` / `ErrorMsg` | mixed | Run detail |

---

### `rw` schema — RenWeb-refactor (materialization target) — first tables

The **`rw`** schema is a refactored set of tables many `dbo` triggers materialize into (notes, religious events, contact addresses, pickup points, previous names). This batch documents the first two: `DefinedList` and `ContactAddress`. (Key pending member: `rw.PersonNote` — the materialization destination for `Person.MedicalNote` and application/inquiry/reenroll notes, and the FK target of `med.MedicalNoteAddendum`.)

#### `rw.DefinedList`
Refactored defined-list (lookup) values — type + value + default + sort. PK `DefinedListID` (not IDENTITY — externally assigned). (The `rw`-schema counterpart to `dbo.DefinedLists`.)

| Column | Type | Notes |
|---|---|---|
| `DefinedListID` | int | PK (externally assigned) |
| `ListType` / `ListValue` | nvarchar | The lookup entry |
| `DefaultValue` / `SortOrder` | mixed | — |

> Another legacy-vs-refactored pair: `dbo.DefinedLists` (PK `DLID`, referenced by `lib.*` FKs) vs `rw.DefinedList` (PK `DefinedListID`). Distinct tables; verify which one a given FK targets.

---

#### `rw.ContactAddress`
A reusable postal address (refactored) — standard address parts. PK `ContactAddressID`. (Referenced as the materialized address store for contacts; the `rw` counterpart to the legacy `dbo.Address`.)

| Column | Type | Notes |
|---|---|---|
| `ContactAddressID` | int IDENTITY | PK |
| `Address1` / `Address2` / `City` / `State` / `PostalCode` / `Country` | nvarchar(255) | Address parts |

---

#### `ref` / `rpt` / `rsys` / `rw` — cross-reference summary

| Table | Schema | Scope / notes |
|---|---|---|
| `AutoSchedulerAlgorithmPriorityType` | ref | Auto-scheduler priorities; CHECK group |
| `CourseTimeFrame` | ref | Course time-frame lookup |
| `LanguageCode` | ref | 2-char language codes |
| `MSTimeZones` | ref | MS time-zone lookup |
| `OAColumnSourceType` | ref | OA column-source types |
| `OAImportStatusType` | ref | OA import-status types |
| `OAReportSettingsType` | ref | OA report-settings types (PK misnamed) |
| `OAStandardReportingType` | ref | OA standard-reporting types |
| `PersonStateIdentifierType` | ref | Person state-id types |
| `CustomizationRC` | rpt | **Per-school report-card customization**; → `ConfigSchool` |
| `LanguageList` | rsys | System tagged language list |
| `RetentionAuditDatabase` | rsys | Retention purge run (db-level) |
| `RetentionAuditTable` | rsys | Retention run per-table detail; → `RetentionAuditDatabase` |
| `DefinedList` | rw | Refactored defined-list; cf. `dbo.DefinedLists` |
| `ContactAddress` | rw | Refactored postal address; cf. `dbo.Address` |

---

### `rw` schema (keystone) — PersonNote, PersonReligiousEvent, PickupPoint, FamilyNote, portfolio & templates

This batch documents the heart of the **`rw`** (RenWeb-refactor) schema — including `rw.PersonNote`, the materialization target referenced by `Person`/`StudentApplication`/`StudentInquiry`/`StudentReenroll` triggers and FK'd by `med.MedicalNoteAddendum`, and `rw.PersonReligiousEvent`, which has triggers that sync *back* to the legacy `dbo.Person` religious-event columns.

#### `rw.PersonNote`
**The materialized person-note store** — notes for a person by type, with date, entered/modified-by, desktop-note + pinned flags, optional year. PK `PersonNoteID`. FK → `Person` (CASCADE). `NoteType` (per extended property): **0 = Admission, 1 = Inquiry, 2 = ReEnrollment** (and 3 = Person.MedicalNote per the documented `Person` materialization triggers).

| Column | Type | Notes |
|---|---|---|
| `PersonNoteID` | int IDENTITY | PK |
| `PersonID` | int | FK → `Person` (CASCADE); indexed |
| `PersonNote` | nvarchar(max) | The note text |
| `NoteType` | int | 0=Admission, 1=Inquiry, 2=ReEnrollment, 3=Medical |
| `NoteDate` / `YearID` | mixed | — |
| `EnteredByID` / `ModifiedByID` | int | Audit |
| `IsDesktopNote` / `IsPinned` | bit | — |

> **Resolves the single most-referenced materialization target in the catalog.** `dbo` triggers on `Person.MedicalNote` (type 3) and on `StudentApplication`/`StudentInquiry`/`StudentReenroll` notes (types 0/1/2) write into this table; `med.MedicalNoteAddendum` attaches addenda to its rows. The materialize-to-`rw.PersonNote`-by-NoteType pattern threaded through many earlier batches now lands on a documented table.

---

#### `rw.PersonReligiousEvent`
A religious event (sacrament) for a person — type, date, location/city/state, note. PK `PersonReligiousEventID`. Unique on `(PersonID, ReligiousEventType)`. FK → `Person` (CASCADE). **The refactored store materialized from `dbo.Person`'s Baptism/Communion/Confirmation/Reconciliation/BarMitzvah columns** — and these triggers sync the *reverse* direction.

| Column | Type | Notes |
|---|---|---|
| `PersonReligiousEventID` | int IDENTITY | PK |
| `PersonID` | int | FK → `Person` (CASCADE); unique with type |
| `ReligiousEventType` | nvarchar(256) | e.g. Baptism, Communion, Confirmation, Reconciliation, Bar Mitzvah |
| `ReligiousEventDate` / `Location` / `City` / `State` / `Note` | mixed | Event detail |

**Triggers** (Ins/Upd/Del) — `tr_LegacyPersonUpdateReligiousEventData_*`: write the event back into the legacy `dbo.Person` sacrament columns (`{Baptism,Communion,Confirmation,Reconciliation,Barmitzvah}{Church,City,State,Date}`) keyed by `ReligiousEventType`; delete blanks them. **Use a `Context_Info` recursion guard** (`0x86385`): each trigger checks/sets `Context_Info` so the reverse-direction update from the `Person` side doesn't loop back. This is the **bidirectional half** of the materialization — `Person` triggers (documented earlier) push *into* `rw.PersonReligiousEvent`; these triggers push *back* to the legacy `Person` columns, with the context-info flag preventing infinite recursion between the two.

> Important behavioral note for reporting: the `dbo.Person.{sacrament}` columns and `rw.PersonReligiousEvent` are kept mutually in sync by triggers in both directions. Either can be read; writes propagate. The `Context_Info 0x86385` handshake is what stops the two trigger sets from ping-ponging.

---

#### `rw.PickupPoint`
A student pickup point (transportation) — name, address, subdivision, note, district-wide flag. PK `PickupPointID`. (The target of `dbo.StudentTransportation` pickup references documented earlier.)

| Column | Type | Notes |
|---|---|---|
| `PickupPointID` | int IDENTITY | PK |
| `ConfigSchoolID` | smallint | School |
| `Name` / `Address` / `City` / `State` / `ZIP` / `Subdivision` / `Note` | mixed | Location |
| `IsDistrictWide` | bit | — |

---

#### `rw.FamilyNote`
Family-level notes — text, date, entered/modified-by, desktop-note flag. PK `FamilyNoteID`. FK → `dbo.FamilyConfig` (CASCADE). (The family counterpart to `rw.PersonNote`.)

| Column | Type | Notes |
|---|---|---|
| `FamilyNoteID` | int IDENTITY | PK |
| `FamilyID` | int | FK → `dbo.FamilyConfig` (CASCADE); indexed |
| `FamilyNote` | nvarchar(max) | The note |
| `NoteDate` / `EnteredByID` / `ModifiedByID` / `IsDesktopNote` | mixed | — |

---

#### `rw.PortfolioGroup`
A document-portfolio group (for the family portal) — name, scope (district-wide / school), person type, system-group/show-in-portal/allow-upload flags. PK `PortfolioGroupId` (seed 100). FK → `dbo.ConfigSchool` (CASCADE). CHECK: system groups may have null school, else school required.

| Column | Type | Notes |
|---|---|---|
| `PortfolioGroupId` | int IDENTITY(100,1) | PK |
| `Name` / `PersonTypeId` | mixed | — |
| `DistrictWide` / `ConfigSchoolId` / `SystemGroup` | mixed | Scope; CHECK system-or-school |
| `ShowInFamilyPortal` / `AllowUpload` | bit | Portal behavior |

---

#### `rw.PortfolioGroupSecurityGroup`
Grants a security group a right-level on a portfolio group. PK `(PortfolioGroupId, SecurityGroupId)`. FKs → `rw.PortfolioGroup` (CASCADE), `dbo.SecurityGroups` (CASCADE).

| Column | Type | Notes |
|---|---|---|
| `PortfolioGroupId` / `SecurityGroupId` | int | PK (composite); both CASCADE |
| `RightLevel` | int | Access level |

---

#### `rw.ImageGallery`
Per-person image gallery — image content (`image` type), GUID, name, type, accessibility scope. PK `ImageID`. Unique on `ImageGUID`. FK → `Person` (CASCADE). `ImageAccessibility`: 0=Personal, 1=School-specific, 2=DistrictWide.

| Column | Type | Notes |
|---|---|---|
| `ImageID` | int IDENTITY | PK |
| `PersonID` | int | FK → `Person` (CASCADE) |
| `ConfigSchoolID` | smallint | — |
| `ImageGUID` | uniqueidentifier | Unique; default newid() |
| `ImageName` / `ImageType` / `ImageAccessibility` | mixed | 0=Personal,1=School,2=District |
| `ImageContent` | image | Binary image |
| `DateEntered` | smalldatetime | — |

---

#### `rw.Person_Acknowledgement`
Person↔acknowledgement link (which acknowledgements a person has accepted). PK `(PersonID, AcknowledgementID)`.

| Column | Type | Notes |
|---|---|---|
| `PersonID` / `AcknowledgementID` | int | PK (composite) |

---

#### `rw.DefinedListFriendlyValue`
Localized friendly display values for `rw.DefinedList` entries, per language. PK `DefinedListFriendlyNameID`. FKs → `rw.DefinedList`, `rsys.LanguageList`. (Resolves the `rw.DefinedList` ↔ `rsys.LanguageList` link.)

| Column | Type | Notes |
|---|---|---|
| `DefinedListFriendlyNameID` | int IDENTITY | PK |
| `DefinedListID` | int | FK → `rw.DefinedList` |
| `LanguageID` | int | FK → `rsys.LanguageList` |
| `FriendlyValue` | nvarchar(256) | Localized label |

---

### `rw` family-default templates (new-family seeding)

`FamilyDefaultConfiguration` → `FamilyDefaultTemplate` → `FamilyDefaultRelationship`: a configurable template for seeding default family structure (relationships, financial responsibility, portal/accounting flags) when creating a new family.

#### `rw.FamilyDefaultConfiguration`
A named family-default configuration. PK `FamilyDefaultConfigurationID`.

| Column | Type | Notes |
|---|---|---|
| `FamilyDefaultConfigurationID` | int IDENTITY | PK |
| `ConfigurationName` | nvarchar(128) | — |

---

#### `rw.FamilyDefaultTemplate`
A template within a configuration — web/accounting flags, use-student-address, financial responsibility. PK `FamilyDefaultTemplateID`. FK → `rw.FamilyDefaultConfiguration`.

| Column | Type | Notes |
|---|---|---|
| `FamilyDefaultTemplateID` | int IDENTITY | PK |
| `FamilyDefaultConfigurationID` | int | FK → configuration |
| `WebEnabled` / `Accounting` / `UseStudentAddress` / `FinancialResponsibility` | mixed | Defaults |

---

#### `rw.FamilyDefaultRelationship`
A default relationship within a template — relationship label + flags (custody, correspondence, grandparent, report-card, ParentsWeb, financial responsibility, use-student-last-name). PK `FamilyDefaultRelationshipID`. FK → `rw.FamilyDefaultTemplate` (CASCADE).

| Column | Type | Notes |
|---|---|---|
| `FamilyDefaultRelationshipID` | int IDENTITY | PK |
| `FamilyDefaultTemplateID` | int | FK → template (CASCADE); indexed |
| `Relationship` / `UseStudentLastName` / `SortOrder` | mixed | — |
| `IsCustody` / `IsCorrespondence` / `IsGrandparent` / `IsReportCard` / `IsParentsWeb` / `FinancialResponsibility` | bit | Default flags |

---

### `rw` grid-edit templates & portal session

#### `rw.GridEditTemplate`
A user's saved grid-edit template (column layout for bulk-edit grids) — name, type, school. PK `GridTemplateID`.

| Column | Type | Notes |
|---|---|---|
| `GridTemplateID` | int IDENTITY | PK |
| `PersonID` / `TemplateName` / `TemplateType` / `ConfigSchoolID` | mixed | — |

---

#### `rw.GridEditTemplateColumn`
Columns within a grid-edit template, ordered. PK `(GridTemplateID, ColumnID)`. FK → `rw.GridEditTemplate` (CASCADE).

| Column | Type | Notes |
|---|---|---|
| `GridTemplateID` / `ColumnID` | int | PK (composite); → template (CASCADE) |
| `SortOrder` | int | — |

---

#### `rw.PortalSession`
A portal session token mapping (portal session id ↔ user session id). PK `PortalSessionId` (uniqueidentifier).

| Column | Type | Notes |
|---|---|---|
| `PortalSessionId` | uniqueidentifier | PK |
| `UserSessionId` / `DateCreated` | mixed | — |

---

#### `rw` (keystone batch) — cross-reference summary

| Table | Schema | Scope / notes |
|---|---|---|
| `PersonNote` | rw | **Materialized person notes** by NoteType (0=Adm,1=Inq,2=Reenr,3=Med); → `Person`; FK'd by `med.MedicalNoteAddendum` |
| `PersonReligiousEvent` | rw | Sacraments; **bidirectional sync** with `dbo.Person` sacrament columns (Context_Info guard) |
| `PickupPoint` | rw | Transportation pickup points; ref by `StudentTransportation` |
| `FamilyNote` | rw | Family notes; → `FamilyConfig` |
| `PortfolioGroup` | rw | Portal document-portfolio groups; → `ConfigSchool` |
| `PortfolioGroupSecurityGroup` | rw | Portfolio group rights; → `SecurityGroups` |
| `ImageGallery` | rw | Per-person images; → `Person` |
| `Person_Acknowledgement` | rw | Person↔acknowledgement |
| `DefinedListFriendlyValue` | rw | Localized list labels; → `rw.DefinedList`, `rsys.LanguageList` |
| `FamilyDefaultConfiguration` | rw | New-family default config |
| `FamilyDefaultTemplate` | rw | New-family template |
| `FamilyDefaultRelationship` | rw | New-family default relationships |
| `GridEditTemplate` | rw | Saved bulk-edit grid layout |
| `GridEditTemplateColumn` | rw | Grid template columns |
| `PortalSession` | rw | Portal session token map |

---

### `rw` schema (final security/personalization), then `sched` schema — auto-scheduler

### `rw` schema (final tables)

These complete the `rw` schema: portfolio individual-security, screen personalization, transportation override, and the UD-group person-security MM (with `CanEveryoneUse`-sync triggers).

#### `rw.PortfolioGroupSecurityIndividual`
Grants an individual person a right-level on a portfolio group (the per-person counterpart to `PortfolioGroupSecurityGroup`). PK `(PortfolioGroupId, PersonId)`. FKs → `rw.PortfolioGroup` (CASCADE), `Person` (CASCADE).

| Column | Type | Notes |
|---|---|---|
| `PortfolioGroupId` / `PersonId` | int | PK (composite); both CASCADE |
| `RightLevel` | int | Access level |

---

#### `rw.ScreenPersonalizationMM`
Per-staff screen personalization — visibility + order of items on a screen. PK `(ScreenID, StaffID, ID)`.

| Column | Type | Notes |
|---|---|---|
| `ScreenID` / `StaffID` / `ID` | int | PK (composite) |
| `IsVisible` / `Order` | mixed | Per-item personalization |

---

#### `rw.StudentTransportationOverride`
Per-date override of a student transportation route (e.g. not riding today). PK `(RouteID, OverrideDate)`. FK → `dbo.StudentTransportation` (CASCADE) — note FK targets `StudentTransportation.RouteID`.

| Column | Type | Notes |
|---|---|---|
| `RouteID` | int | PK (composite); FK → `dbo.StudentTransportation` (CASCADE) |
| `OverrideDate` | datetime | PK (composite) |
| `Note` | nvarchar(150) | — |

---

#### `rw.UDGroupSecurityPersonMM`
Person-level security for a user-defined group — security level per person. PK `(UDGroupID, PersonID)`. FKs → `dbo.UDGroup` (CASCADE), `Person` (CASCADE).

| Column | Type | Notes |
|---|---|---|
| `UDGroupID` / `PersonID` | int | PK (composite); both CASCADE |
| `SecurityLevel` | int | Default 1 |

**Triggers** (Ins/Del) — maintain `dbo.UDGroup.CanEveryoneUse`: insert sets it 0 (group now restricted); delete sets it 1 **only if** no person-security *and* no `dbo.UDGroupSecurity` (group-security) rows remain (group becomes open again). Same "no restrictions ⇒ everyone can use" pattern as `mail`/communication groups.

> Mirrors the `mail.CommunicationGroup` membership model: a UD group is usable by everyone when it has *no* security rows (person or group), restricted otherwise; triggers keep the cached `CanEveryoneUse` flag consistent.

> **`rw` schema now complete** across all batches: DefinedList(+FriendlyValue), ContactAddress, PersonNote, PersonReligiousEvent, PickupPoint, FamilyNote, portfolio groups (+group/individual security), ImageGallery, Person_Acknowledgement, family-default templates, grid-edit templates, PortalSession, screen personalization, transportation override, UD-group security.

---

### `sched` schema — auto-scheduler / course requests

The **`sched`** schema is the modern scheduling/auto-scheduler subsystem: per-course scheduling config (`CourseScheduling`), eligible instructors, student course requests + alternates + recommendations, parent sign-off (`FamilyRequest`), auto-scheduler settings + algorithm priorities, and run-time caches (`ClassEnrollmentSummary`, `ConflictMatrix`) for candidate scheduling runs. Most config tables are **temporal** (system-versioned) and key off `crse.CourseCore`.

#### `sched.CourseScheduling`
**Per-course scheduling configuration** — required room, linked course, min/max size, default staff/template, pattern group, priority, time frame, waitlist, prerequisite/recommendation rules, and various auto-schedule behavior flags. **Temporal.** PK `CourseID` (1:1 with the course). FKs → `crse.CourseCore` (Course + LinkedCourse), `Person` (DefaultStaff), `Rooms`, `ScheduleTemplate`, `ref.CourseTimeFrame`, `sched.TemplatePatternGroup`.

| Column group | Type | Notes |
|---|---|---|
| `CourseID` | int | PK; FK → `crse.CourseCore` |
| `RequiredRoomID` / `LinkedCourseID` / `DefaultStaffID` / `DefaultTemplateId` / `PatternGroupID` | int | FKs (Rooms/CourseCore/Person/ScheduleTemplate/TemplatePatternGroup) |
| `MinSize` / `MaxSize` / `MaxCourseRequests` / `Waitlist` | mixed | Capacity |
| `Priority` / `TimeFrame` | tinyint | `TimeFrame` → `ref.CourseTimeFrame` |
| Rules: `RequireAllPrerequisites` / `RequireRecommendation` / `AllowCourseRequestsForPassedOrCurrentClasses` / `AllowRequestsForPreferredInstructor` / `AllowAutoScheduleStudentTransferAtTerm` / `AllowGradeLevelPriority` / `IgnoreStudentStaffRestrictions` | bit | Auto-schedule behavior |
| `CreatedOnUTC` / `ModifiedOnUTC` / `ModifiedOnUTCmax` | datetime2 | Temporal |

> `IgnoreStudentStaffRestrictions` ties back to `prsn.StudentStaffRestriction` — the auto-scheduler normally honors those no-contact restrictions unless this flag is set.

---

#### `sched.AlternateCourse`
Alternate course choices for a student request (priority-ordered). **Temporal.** PK `AlternateCourseID`. FKs → `dbo.StudentRequests`, `crse.CourseCore`.

| Column | Type | Notes |
|---|---|---|
| `AlternateCourseID` | int IDENTITY | PK |
| `StudentRequestID` | int | FK → `dbo.StudentRequests`; indexed |
| `CourseID` | int | FK → `crse.CourseCore`; indexed |
| `WebElement` / `Priority` | mixed | Choice priority |
| `CreatedOnUTC` / `ModifiedOnUTC` / `ModifiedOnUTCmax` | datetime2 | Temporal |

---

#### `sched.CourseRecommendation`
A teacher's course recommendation for a student for a year — note, referring class. PK `CourseRecommendationID`. FKs → `SchoolYear`, `Person` (Student + CreatedBy), `crse.CourseCore`, `Classes` (ReferredBy).

| Column | Type | Notes |
|---|---|---|
| `CourseRecommendationID` | int IDENTITY | PK |
| `YearID` / `StudentID` / `CourseID` | int | The recommendation |
| `Note` / `ReferredByClassID` | mixed | — |
| `CreatedByPersonID` / `CreatedUTC` | mixed | Audit |

---

#### `sched.CourseEligibleInstructor`
Instructors eligible to teach a course. PK `CourseEligibleInstructorId`. FKs → `crse.CourseCore`, `Person`.

| Column | Type | Notes |
|---|---|---|
| `CourseEligibleInstructorId` | int IDENTITY | PK |
| `CourseId` / `PersonId` | int | FKs; indexed |
| `CreatedOnUTC` / `ModifiedOnUTC` / `ModifiedOnUTCmax` | datetime2 | Audit (non-temporal here) |

---

#### `sched.FamilyRequest`
Parent sign-off on a student's course requests for a year. PK `FamilyRequestID`. Unique on `(YearID, StudentID, ParentSignOffPersonID)`. FKs → `Person` (Student + ParentSignOff), `SchoolYear`. (Resolves the `sched.FamilyRequest` reference from `StudentRequests`.)

| Column | Type | Notes |
|---|---|---|
| `FamilyRequestID` | int IDENTITY | PK |
| `YearID` / `StudentID` | int | Indexed; FKs |
| `ParentSignOffPersonID` / `ParentSignOffUTC` | mixed | Sign-off |

---

#### `sched.CourseRequestConfiguration`
Per-school course-request settings — show teacher recs, require parent sign-off, min/max requests. PK `CourseRequestConfigurationID`. Unique on `ConfigSchoolID`. FK → `dbo.ConfigSchool`.

| Column | Type | Notes |
|---|---|---|
| `CourseRequestConfigurationID` | smallint IDENTITY | PK |
| `ConfigSchoolID` | smallint | FK → `dbo.ConfigSchool`; unique |
| `ShowTeacherRecommendations` / `RequireParentSignOff` / `MinRequests` / `MaxRequests` | mixed | Settings |

---

#### `sched.AutoSchedulerSettings`
Per-school auto-scheduler settings — base UD-list/course, auto-assign instructor, section-for-conflict creation, duration-pattern tolerances, max sections/student. **Temporal.** PK `AutoSchedulerSettingsId`. Unique on `ConfigSchoolId`. FKs → `ConfigSchool`, `dbo.ScheduleUserDefinedListName`, `crse.CourseCore`.

| Column | Type | Notes |
|---|---|---|
| `AutoSchedulerSettingsId` | int IDENTITY | PK |
| `ConfigSchoolId` | smallint | FK → `ConfigSchool`; unique |
| `BaseUdListId` / `BaseCourseId` | int | FKs → `ScheduleUserDefinedListName`, `crse.CourseCore` |
| `AutoAssignPrimaryInstructor` / `AutoCreateSectionsForConflicts` / `AskToLeaveDataAsIs` | bit | Behavior |
| `AllowLongerDurationPatterns` / `MaxLongerDurationMinutes` / `AllowShorterDurationPatterns` / `MaxShorterDurationMinutes` / `MaxSectionsPerStudent` | mixed | Tolerances |
| `CreatedOnUTC` / `ModifiedOnUTC` / `ModifiedOnUTCmax` | datetime2 | Temporal |

---

#### `sched.AutoSchedulerAlgorithmPriority`
Per-school ordering of auto-scheduler algorithm priorities — which priority types are active and in what order. **Temporal.** PK `AutoSchedulerAlgorithmPriorityId`. Unique on `(ConfigSchoolId, TypeId)` and (filtered, active only) `(ConfigSchoolId, PriorityOrder)`. FKs → `ConfigSchool`, `ref.AutoSchedulerAlgorithmPriorityType`.

| Column | Type | Notes |
|---|---|---|
| `AutoSchedulerAlgorithmPriorityId` | int IDENTITY | PK |
| `ConfigSchoolId` | smallint | FK → `ConfigSchool` |
| `AutoSchedulerAlgorithmPriorityTypeId` | tinyint | FK → `ref.AutoSchedulerAlgorithmPriorityType` |
| `PriorityOrder` / `IsActive` | mixed | Unique active order per school |
| `CreatedOnUTC` / `ModifiedOnUTC` / `ModifiedOnUTCmax` | datetime2 | Temporal |

---

#### `sched.ClassScheduleGender`
Gender restriction(s) for a class in scheduling. **Temporal.** PK `(ClassID, GenderID)`. FKs → `dbo.Classes`, `dbo.DefinedLists` (GenderID).

| Column | Type | Notes |
|---|---|---|
| `ClassID` / `GenderID` | int | PK (composite); → `Classes`, `DefinedLists` |
| `CreatedOnUTC` / `ModifiedOnUTC` / `ModifiedOnUTCmax` | datetime2 | Temporal |

---

#### `sched.ClassEnrollmentSummary`
**Run-time cache** — per-run/per-class running enrollment counts (total/male/female) for candidate auto-scheduler runs, avoiding repeated COUNT(*) against the staging roster. PK `(RunId, ClassID)`. FKs → `sched.SchedulingRun` (CASCADE), `dbo.Classes` (CASCADE).

| Column | Type | Notes |
|---|---|---|
| `RunId` / `ClassID` | int | PK (composite); → `sched.SchedulingRun`, `Classes` |
| `EnrolledCt` / `MaleCt` / `FemaleCt` | int | Running counts |

> References `sched.SchedulingRun` (not yet documented) — the candidate-run header for auto-scheduler sandbox runs.

---

#### `sched.ConflictMatrix`
**Run-time cache** — per-(school, baseline, course-pair) count of students who requested both courses, used by the auto-scheduler for course ordering and conflict scoring. PK `(SchoolId, BaselineCapturedAt, LowerCourseID, HigherCourseID)`. CHECK `LowerCourseID < HigherCourseID` (canonical pair ordering — each unordered pair stored once). FKs → `crse.CourseCore` (×2).

| Column | Type | Notes |
|---|---|---|
| `SchoolId` / `BaselineCapturedAt` | mixed | PK; sandbox baseline scope |
| `LowerCourseID` / `HigherCourseID` | int | PK; CHECK `Lower<Higher`; FKs → `crse.CourseCore` |
| `SharedStudentCount` | smallint | CHECK ≥ 0; co-request count |

> Same `Lower < Higher` canonical-pair idiom as `prsn.StudentStudentRestriction` — stores each unordered course pair exactly once. Baseline-scoped so it's shared across candidate runs against the same sandbox (requests don't change during scheduling).

---

#### `rw` (final) / `sched` — cross-reference summary

| Table | Schema | Scope / notes |
|---|---|---|
| `PortfolioGroupSecurityIndividual` | rw | Per-person portfolio rights; → `PortfolioGroup`, `Person` |
| `ScreenPersonalizationMM` | rw | Per-staff screen layout |
| `StudentTransportationOverride` | rw | Per-date route override; → `StudentTransportation` |
| `UDGroupSecurityPersonMM` | rw | UD-group person security; triggers sync `UDGroup.CanEveryoneUse` |
| `CourseScheduling` | sched | **Per-course schedule config**; temporal; → `crse.CourseCore` etc. |
| `AlternateCourse` | sched | Request alternates; temporal; → `StudentRequests`, `crse.CourseCore` |
| `CourseRecommendation` | sched | Teacher course recs; → `crse.CourseCore`, `Person`, `Classes` |
| `CourseEligibleInstructor` | sched | Eligible instructors; → `crse.CourseCore`, `Person` |
| `FamilyRequest` | sched | Parent sign-off; → `Person`, `SchoolYear` |
| `CourseRequestConfiguration` | sched | Per-school request settings; → `ConfigSchool` |
| `AutoSchedulerSettings` | sched | Per-school auto-scheduler settings; temporal |
| `AutoSchedulerAlgorithmPriority` | sched | Per-school algorithm priority order; temporal; → `ref.AutoSchedulerAlgorithmPriorityType` |
| `ClassScheduleGender` | sched | Class gender restriction; temporal; → `Classes`, `DefinedLists` |
| `ClassEnrollmentSummary` | sched | Run-time enroll-count cache; → `sched.SchedulingRun`, `Classes` |
| `ConflictMatrix` | sched | Course-pair conflict cache; CHECK `Lower<Higher`; → `crse.CourseCore` |

---

### `sched` schema (scheduling runs & sandbox), `sec` (security rights), `sped` (special education)

### `sched` — scheduling-run model

The auto-scheduler runs as candidate **scheduling runs**: `SchedulingRun` (run header) with per-run staging tables (`StagingClassSchedule`, `StagingRoster`), summary/cache children (`RunSummary`, `StudentScheduleSummary`, `StudentPatternConflicts`; plus `ClassEnrollmentSummary`/`ConflictMatrix` from the prior batch), and a **sandbox** layer (`SandboxClassSchedule`, `SandboxRoster`) that a chosen run is promoted into before final promotion to live `Classes`/`Roster`. `TemplatePatternGroup` is the pattern-group lookup referenced by `CourseScheduling`.

> Flow (per the design comments): a school runs up to ~10 candidate runs per template with different baseline settings/priorities → compares `RunSummary` metrics → promotes a chosen run to the sandbox overlay → eventually promotes the sandbox to live `dbo.Classes`/`dbo.Roster`.

#### `sched.SchedulingRun`
**Core auto-scheduler run header** — template, label, status, phases, settings snapshot (JSON), baseline capture + lock signature, applied-to-sandbox audit. PK `RunId`. FKs → `dbo.ScheduleTemplate` (CASCADE), `Person` (CreatedBy, AppliedBy). Parent of all per-run children.

| Column | Type | Notes |
|---|---|---|
| `RunId` | int IDENTITY | PK; parent of run children |
| `TemplateId` | int | FK → `dbo.ScheduleTemplate` (CASCADE); indexed |
| `Label` | nvarchar(100) | User-facing run name |
| `StatusId` | tinyint | CHECK 0–4 (0=queued,1=processing,2=cancelled,3=ok,4=finished w/ problems) |
| `PhasesExecuted` | tinyint | CHECK 0–2 (0=schedule+enroll,1=schedule,2=enroll) |
| `SettingsSnapshotJson` | nvarchar(max) | CHECK ISJSON; baseline settings |
| `BaselineCapturedAtUTC` / `LockSignature` | mixed | "similar-job"/expiry check |
| `CreatedBy` / `CreatedAtUTC` / `CompletedAtUTC` | mixed | FK → `Person` |
| `AppliedAtUTC` / `AppliedBy` | mixed | Sandbox-promotion audit (FK → `Person`, SET NULL) |

---

#### `sched.RunSummary`
Headline metrics per run (1:1) — scheduled/enrolled pct, unplaced count, section-size + gender-balance distributions (JSON), auto-created sections. PK `RunId`. FK → `sched.SchedulingRun` (CASCADE).

| Column | Type | Notes |
|---|---|---|
| `RunId` | int | PK; FK → `SchedulingRun` (CASCADE) |
| `ScheduledPct` / `EnrolledPct` / `UnplacedCount` / `AutoCreatedSectionCount` | mixed | Metrics |
| `SectionSizeDistJson` / `GenderBalanceJson` | nvarchar(max) | Aggregated detail |

---

#### `sched.StagingClassSchedule`
Per-run class-scheduling output — staff/room/pattern per class. PK `(RunId, ClassID)`. FKs → `SchedulingRun` (CASCADE), `Classes` (CASCADE), `Person` (Staff, SET NULL), `Rooms` (SET NULL).

| Column | Type | Notes |
|---|---|---|
| `RunId` / `ClassID` | int | PK (composite) |
| `StaffID` / `RoomID` / `PatternNumber` | mixed | Assigned schedule |

---

#### `sched.StagingRoster`
Per-run enrollment (student↔class) for a candidate run. PK `StagingRosterId`. Unique on `(RunId, StudentID, ClassID)`. FKs → `SchedulingRun`, `Person`, `Classes` (all CASCADE).

| Column | Type | Notes |
|---|---|---|
| `StagingRosterId` | int IDENTITY | PK |
| `RunId` / `StudentID` / `ClassID` | int | Unique together |

---

#### `sched.StudentScheduleSummary`
Per-run/per-student running enrollment count (cache for "next student to try"). PK `(RunId, StudentID)`. FKs → `SchedulingRun`, `Person` (CASCADE).

| Column | Type | Notes |
|---|---|---|
| `RunId` / `StudentID` | int | PK (composite) |
| `EnrolledCount` | int | Running count |

> Design comment notes the temporal columns were *intentionally omitted* pending DBA guidance on whether transient staging tables need system-versioning — a nice documented decision point.

---

#### `sched.StudentPatternConflicts`
Per-run cache of schedule patterns a student can't use (and which class causes each conflict) — reduces the time-conflict constraint to a single key lookup. PK `(RunId, StudentID, PatternNumber, ConflictSourceClassID)`. FKs → `SchedulingRun`, `Person`, `Classes` (all CASCADE).

| Column | Type | Notes |
|---|---|---|
| `RunId` / `StudentID` / `PatternNumber` / `ConflictSourceClassID` | int | PK (composite) |

> Multiple source classes can exclude the same pattern; all recorded so the scheduler knows which patterns free up if a student is moved out of a given class.

---

#### `sched.SandboxClassSchedule`
Sandbox class-scheduling overlay (chosen run promoted here) — pattern/staff/room per class, with a `rowversion` for concurrent-edit detection. PK `(TemplateId, ClassID)`. FKs → `dbo.SchedulePatterns` (PatternNumber+TemplateId), `ScheduleTemplate`, `Classes`, `Person_Staff`, `Rooms`. All other class data still read from `dbo.Classes`.

| Column | Type | Notes |
|---|---|---|
| `TemplateId` / `ClassID` | int | PK (composite) |
| `PatternNumber` / `StaffID` / `RoomID` | mixed | Scheduler output only |
| `RowVersion` | rowversion | Concurrency |

---

#### `sched.SandboxRoster`
Sandbox enrollment overlay — enrolled (+ per-term Enrolled1–6), is-alternate, alternate-course link, `rowversion`. PK `(TemplateId, StudentID, ClassID)`. FKs → `ScheduleTemplate`, `Person`, `Classes`, `sched.AlternateCourse` (SET NULL).

| Column | Type | Notes |
|---|---|---|
| `TemplateId` / `StudentID` / `ClassID` | int | PK (composite) |
| `Enrolled` / `Enrolled1`–`Enrolled6` / `IsAlternate` / `AlternateCourseID` | mixed | Enrollment output |
| `RowVersion` | rowversion | Concurrency |

---

#### `sched.TemplatePatternGroup`
Pattern-group lookup per school (the target of `CourseScheduling.PatternGroupID`). PK `TemplatePatternGroupID`. FK → `dbo.ConfigSchool`. (Resolves the long-pending `sched.TemplatePatternGroup` reference.)

| Column | Type | Notes |
|---|---|---|
| `TemplatePatternGroupID` | int IDENTITY | PK |
| `PatternGroupName` / `ConfigSchoolID` | mixed | FK → `dbo.ConfigSchool` |

---

### `sec` schema — security rights (refactored)

The **`sec`** schema is the refactored security-rights store — `SecurityGroupRight` (right-level per group per item) and a backup pair (`Backup` + `SecurityGroupRight_Backup`). (Refactored counterpart to the legacy `dbo` security model; `dbo.SecurityGroups` remains the group table.)

#### `sec.SecurityGroupRight`
Right-level a security group has on a security item. PK `(SecurityGroupID, SecurityItemID)`. FK → `dbo.SecurityGroups` (CASCADE). `RightLevel`: 0=None, 1=View/Use, 2=Modify.

| Column | Type | Notes |
|---|---|---|
| `SecurityGroupID` / `SecurityItemID` | int | PK (composite); → `SecurityGroups` |
| `RightLevel` | int | 0=None, 1=View/Use, 2=Modify |

---

#### `sec.Backup`
A security backup snapshot header — staff, group, timestamp. PK `BackupID`.

| Column | Type | Notes |
|---|---|---|
| `BackupID` | int IDENTITY | PK |
| `StaffID` / `SecurityGroupID` / `BackupDateTime` | mixed | Snapshot context |

---

#### `sec.SecurityGroupRight_Backup`
Backed-up security-group rights, keyed to a backup. PK `(BackupID, SecurityGroupID, SecurityItemID)`. (Point-in-time copy of `SecurityGroupRight` for restore.)

| Column | Type | Notes |
|---|---|---|
| `BackupID` / `SecurityGroupID` / `SecurityItemID` | int | PK (composite) |
| `RightLevel` | int | — |

---

### `sped` schema — special education (Ed-Fi)

The **`sped`** schema models student special-education program associations (Ed-Fi), with disability + disability-designation children. (Resolves the `sped` schema referenced by the stray constraint name on `prgm.StudentLanguageInstructionProgramAssociationLanguageInstructionProgramService` and the `sped` SSEPADD naming.)

> **Contains sensitive student data** (IEP, disability, IDEA eligibility, medical-fragility).

#### `sped.StudentSpecialEducationProgramAssociation`
A student's special-education program enrollment — IDEA eligibility, setting, hours, multiply-disabled/medically-fragile flags, IEP/evaluation dates. PK `StudentSpecialEducationProgramAssociationID`. Unique on `(ProgramID, EducationOrganizationID, BeginDate, StudentID)`. FKs → `cnfg.EducationOrganization`, `prgm.Program`. (Specializes `prgm.Program`, like the `prgm` student-program associations.)

| Column group | Type | Notes |
|---|---|---|
| `StudentSpecialEducationProgramAssociationID` | int IDENTITY | PK |
| `ProgramID` | int | FK → `prgm.Program` |
| `EducationOrganizationID` | bigint | FK → `cnfg.EducationOrganization`; indexed |
| `StudentID` / `BeginDate` / `EndDate` / `ReasonExitedDescriptorID` | mixed | Enrollment; unique key |
| `IdeaEligibility` / `MultiplyDisabled` / `MedicallyFragile` | bit | Status flags |
| `SpecialEducationSettingDescriptorID` / `SpecialEducationHoursPerWeek` / `SchoolHoursPerWeek` | mixed | Setting/hours |
| `LastEvaluationDate` / `IEPReviewDate` / `IEPBeginDate` / `IEPEndDate` | date | IEP dates |

---

#### `sped.StudentSpecialEducationProgramAssociationDisability`
A disability on a SpEd association — descriptor, diagnosis, order, determination source. PK `StudentSpecialEducationProgramAssociationDisabilityID`. Unique on `(SSEPAID, DisabilityDescriptorID)`. FK → `sped.StudentSpecialEducationProgramAssociation`.

| Column | Type | Notes |
|---|---|---|
| `StudentSpecialEducationProgramAssociationDisabilityID` | int IDENTITY | PK |
| `StudentSpecialEducationProgramAssociationID` | int | FK → SpEd association; unique with descriptor |
| `DisabilityDescriptorID` | uniqueidentifier | Ed-Fi descriptor |
| `DisabilityDiagnosis` / `OrderOfDisability` / `DisabilityDeterminationSourceTypeDescriptorID` | mixed | — |

---

#### `sped.StudentSpecialEducationProgramAssociationDisabilityDesignation`
Designations on a SpEd disability (e.g. primary). PK `StuSpEdProgAssocDisabilityDesignationID`. Unique on `(DisabilityID, DesignationDescriptorID)`. FK → `sped.StudentSpecialEducationProgramAssociationDisability`.

| Column | Type | Notes |
|---|---|---|
| `StuSpEdProgAssocDisabilityDesignationID` | int IDENTITY | PK |
| `StudentSpecialEducationProgramAssociationDisabilityID` | int | FK → disability; unique with descriptor |
| `DisabilityDesignationDescriptorID` | uniqueidentifier | Ed-Fi descriptor |

> The `sped` chain (association → disability → designation) parallels the `prgm` base-plus-specialization pattern and the `prsn` SEOA characteristic/period nesting — Ed-Fi's consistent association→detail→sub-detail shape.

---

#### `sched` (runs) / `sec` / `sped` — cross-reference summary

| Table | Schema | Scope / notes |
|---|---|---|
| `SchedulingRun` | sched | **Auto-scheduler run header**; → `ScheduleTemplate`, `Person`; status/phase CHECKs |
| `RunSummary` | sched | Per-run metrics (1:1) |
| `StagingClassSchedule` | sched | Per-run class schedule output |
| `StagingRoster` | sched | Per-run enrollment |
| `StudentScheduleSummary` | sched | Per-run/student enroll-count cache |
| `StudentPatternConflicts` | sched | Per-run pattern-conflict cache |
| `SandboxClassSchedule` | sched | Sandbox class overlay; rowversion |
| `SandboxRoster` | sched | Sandbox enrollment overlay; rowversion; → `AlternateCourse` |
| `TemplatePatternGroup` | sched | Pattern-group lookup; ref by `CourseScheduling` |
| `SecurityGroupRight` | sec | Group→item right level; → `SecurityGroups` |
| `Backup` | sec | Security backup header |
| `SecurityGroupRight_Backup` | sec | Backed-up rights |
| `StudentSpecialEducationProgramAssociation` | sped | **SpEd enrollment**; IEP; → `prgm.Program`, `cnfg.EducationOrganization` |
| `StudentSpecialEducationProgramAssociationDisability` | sped | SpEd disabilities |
| `StudentSpecialEducationProgramAssociationDisabilityDesignation` | sped | Disability designations |

---

### `sped` (special education) & `sr` (state reporting — discipline, programs, state IDs)

### `sped` schema — special education

The **`sped`** schema models special-education program participation. The base `sped.StudentSpecialEducationProgramAssociation` (referenced earlier; not in this batch) is extended by service-provider, program-service, and program-service-provider tables documented here. (Earlier batches surfaced this schema via a stray `DF_sped_SSEPASEPS_*` constraint name copied into a `prgm` table.)

#### `sped.StudentSpecialEducationProgramAssociationServiceProvider`
Staff service providers on a special-ed program association. PK `…ServiceProviderID`. Unique on `(AssociationID, StaffID)`. FKs → `sped.StudentSpecialEducationProgramAssociation`, `Person` (StaffID → `Person`).

| Column | Type | Notes |
|---|---|---|
| `StudentSpecialEducationProgramAssociationServiceProviderID` | int IDENTITY | PK |
| `StudentSpecialEducationProgramAssociationID` | int | FK → base association; unique with StaffID |
| `StaffID` | int | FK → `Person`; indexed |
| `PrimaryProvider` | bit | — |

---

#### `sped.StudentSpecialEducationProgramAssociationSpecialEducationProgramService`
Special-ed program services on the association — service descriptor, primary flag, begin/end dates. PK `…ProgramServiceID`. Unique on `(AssociationID, ServiceDescriptorID)`. FK → `sped.StudentSpecialEducationProgramAssociation`.

| Column | Type | Notes |
|---|---|---|
| `StudentSpecialEducationProgramAssociationSpecialEducationProgramServiceID` | int IDENTITY | PK |
| `StudentSpecialEducationProgramAssociationID` | int | FK → base association; unique with descriptor |
| `SpecialEducationProgramServiceDescriptorID` | uniqueidentifier | Ed-Fi descriptor |
| `PrimaryProvider` / `ServiceBeginDate` / `ServiceEndDate` | mixed | — |

---

#### `sped.StudentSpecialEducationProgramAssociationSpecialEducationProgramServiceProvider`
Staff providers for a specific special-ed program service. PK `…ServiceProviderID`. Unique on `(StaffID, ServiceID)`. FKs → `Person` (StaffID), `sped.…SpecialEducationProgramService`.

| Column | Type | Notes |
|---|---|---|
| `…SpecialEducationProgramServiceProviderID` | int IDENTITY | PK |
| `StaffID` | int | FK → `Person`; unique with ServiceID |
| `StudentSpecialEducationProgramAssociationSpecialEducationProgramServiceID` | int | FK → program service; indexed |
| `PrimaryProvider` | bit | — |

---

### `sr` schema — state reporting (discipline & program detail)

The **`sr`** schema holds state-reporting data — discipline incidents (incident → person associations → actions → arrest/service-provided), discipline weapons/external participants, person state identifiers, and program detail (services, characteristics, learning-objective/standard links) extending `prgm.Program`. Used for state compliance submissions.

#### `sr.Incident`
A discipline incident — year, date, behavior, location, reporter, law-enforcement flag, case number, cost, reporting staff. PK `Id`. FKs → `SchoolYear`, `Person_Staff`.

| Column | Type | Notes |
|---|---|---|
| `Id` | int IDENTITY | PK |
| `YearId` | int | FK → `SchoolYear`; indexed |
| `DateUTC` / `BehaviorDescriptor` / `Description` / `IncidentIdentifier` | mixed | Incident detail |
| `IncidentLocationDescriptorId` / `ReporterDescriptionDescriptorId` / `ReporterName` | mixed | Location/reporter |
| `ReportedToLawEnforcement` / `CaseNumber` / `IncidentCost` | mixed | — |
| `StaffId` | int | FK → `Person_Staff`; indexed |

---

#### `sr.IncidentAssociation`
A person's association with an incident — role, behavior, gang-related, description. PK `Id`. Unique on `(IncidentId, PersonId, BehaviorDescriptorId)`. FKs → `sr.Incident` (CASCADE), `Person`.

| Column | Type | Notes |
|---|---|---|
| `Id` | int IDENTITY | PK |
| `IncidentId` | int | FK → `sr.Incident` (CASCADE) |
| `PersonId` | int | FK → `Person`; indexed |
| `BehaviorDescriptorId` / `Role` / `GangRelatedDescriptor` / `Description` | mixed | The person's role |

---

#### `sr.DisciplineAction`
A disciplinary action taken for an incident association — date range, descriptor, interim alt-ed flag, length-difference reason. PK `Id`. FK → `sr.IncidentAssociation` (CASCADE).

| Column | Type | Notes |
|---|---|---|
| `Id` | int IDENTITY | PK |
| `IncidentAssociationId` | int | FK → `sr.IncidentAssociation` (CASCADE); indexed |
| `StartDateUTC` / `EndDateUTC` / `Descriptor` | mixed | The action |
| `InterimAltEd` / `DisciplineActionLengthDifferenceReasonDescriptorId` | mixed | — |

---

#### `sr.DisciplineArrest`
Arrest detail for a discipline action (1:1). PK `Id`. Unique on `DisciplineActionId`. FK → `sr.DisciplineAction` (CASCADE).

| Column | Type | Notes |
|---|---|---|
| `Id` | int IDENTITY | PK |
| `DisciplineActionId` | int | FK → `sr.DisciplineAction` (CASCADE); unique |
| `ArrestLocation` / `ArrestReason` | nvarchar | — |

---

#### `sr.DisciplineServiceProvided`
Service provided as part of a discipline action (1:1). PK `Id`. Unique on `DisciplineActionId`. FK → `sr.DisciplineAction` (CASCADE).

| Column | Type | Notes |
|---|---|---|
| `Id` | int IDENTITY | PK |
| `DisciplineActionId` | int | FK → `sr.DisciplineAction` (CASCADE); unique |
| `ServiceDescriptor` | nvarchar(250) | — |

---

#### `sr.DisciplineIncidentWeapon`
Weapons involved in an incident. PK `DisciplineIncidentWeaponId`. Unique on `(WeaponDescriptorId, IncidentId)`. FK → `sr.Incident`.

| Column | Type | Notes |
|---|---|---|
| `DisciplineIncidentWeaponId` | int IDENTITY | PK |
| `IncidentId` | int | FK → `sr.Incident`; indexed |
| `WeaponDescriptorId` / `WeaponDescription` | mixed | Unique with IncidentId |

---

#### `sr.DisciplineIncidentExternalParticipant`
Non-system (external) participants in an incident — name + participation code. PK `DiscipineIncidentExternalParticipantID` (sic). Unique on `(IncidentID, FirstName, LastSurname, ParticipationCodeDescriptorID)`. FK → `sr.Incident`.

| Column | Type | Notes |
|---|---|---|
| `DiscipineIncidentExternalParticipantID` | int IDENTITY | PK (misspelled "Discipine") |
| `IncidentID` | int | FK → `sr.Incident` |
| `DisciplineIncidentParticipationCodeDescriptorID` / `FirstName` / `LastSurname` | mixed | External person |

---

#### `sr.PersonStateIdentifier`
Per-person state identifiers by type. PK `Id`. Unique on `(PersonId, IdentifierTypeId)`. FKs → `Person` (CASCADE), `ref.PersonStateIdentifierType`. (Resolves the `ref.PersonStateIdentifierType` reference from the prior batch.)

| Column | Type | Notes |
|---|---|---|
| `Id` | int IDENTITY | PK |
| `PersonId` | int | FK → `Person` (CASCADE); unique with type |
| `IdentifierTypeId` | smallint | FK → `ref.PersonStateIdentifierType` |
| `StateIdentifier` | nvarchar(30) | The id value |

---

#### `sr.ProgramService`
Services offered by a program. PK `ProgramServiceID`. Unique clustered on `(ProgramID, ServiceDescriptorID)`. FK → `prgm.Program`.

| Column | Type | Notes |
|---|---|---|
| `ProgramServiceID` | int IDENTITY | PK (nonclustered) |
| `ProgramID` | int | FK → `prgm.Program`; in unique key |
| `ServiceDescriptorID` | uniqueidentifier | Ed-Fi descriptor |

---

#### `sr.ProgramCharacteristic`
Characteristics of a program. PK `ProgramCharacteristicID`. Unique clustered on `(ProgramID, CharacteristicDescriptorID)`. FK → `prgm.Program`.

| Column | Type | Notes |
|---|---|---|
| `ProgramCharacteristicID` | int IDENTITY | PK (nonclustered) |
| `ProgramID` | int | FK → `prgm.Program`; in unique key |
| `ProgramCharacteristicDescriptorID` | uniqueidentifier | Ed-Fi descriptor |

---

#### `sr.ProgramLearningObjectiveMM`
Links a program to academic learning objectives. PK `(ProgramID, LearningObjectiveID)`. FKs → `prgm.Program`, **`aca.LearningObjective`**.

| Column | Type | Notes |
|---|---|---|
| `ProgramID` / `LearningObjectiveID` | int | PK (composite); → `prgm.Program`, `aca.LearningObjective` |

---

#### `sr.ProgramLearningStandardMM`
Links a program to academic learning standards. PK `(ProgramID, LearningStandardID)`. FKs → `prgm.Program`, **`aca.LearningStandard`**.

| Column | Type | Notes |
|---|---|---|
| `ProgramID` / `LearningStandardID` | int | PK (composite); → `prgm.Program`, `aca.LearningStandard` |

---

#### `sped` / `sr` — cross-reference summary

| Table | Schema | Scope / notes |
|---|---|---|
| `StudentSpecialEducationProgramAssociationServiceProvider` | sped | Staff providers; → base assoc, `Person` |
| `StudentSpecialEducationProgramAssociationSpecialEducationProgramService` | sped | Program services; → base assoc |
| `StudentSpecialEducationProgramAssociationSpecialEducationProgramServiceProvider` | sped | Service-specific providers; → service, `Person` |
| `Incident` | sr | **Discipline incident**; → `SchoolYear`, `Person_Staff` |
| `IncidentAssociation` | sr | Person↔incident role; → `Incident`, `Person` |
| `DisciplineAction` | sr | Action for an association; → `IncidentAssociation` |
| `DisciplineArrest` | sr | Arrest detail (1:1); → `DisciplineAction` |
| `DisciplineServiceProvided` | sr | Service provided (1:1); → `DisciplineAction` |
| `DisciplineIncidentWeapon` | sr | Weapons; → `Incident` |
| `DisciplineIncidentExternalParticipant` | sr | External participants; → `Incident` |
| `PersonStateIdentifier` | sr | Person state IDs; → `Person`, `ref.PersonStateIdentifierType` |
| `ProgramService` | sr | Program services; → `prgm.Program` |
| `ProgramCharacteristic` | sr | Program characteristics; → `prgm.Program` |
| `ProgramLearningObjectiveMM` | sr | Program↔learning objective; → `aca.LearningObjective` |
| `ProgramLearningStandardMM` | sr | Program↔learning standard; → `aca.LearningStandard` |

---

### `sr` schema (Ed-Fi state reporting) and `System.Activities.DurableInstancing` (WF instance store)

### `sr` schema — state reporting

The **`sr`** schema holds additional Ed-Fi state-reporting entities not covered by `prgm`/`prsn`/`sped`: program sponsors, restraint/seclusion events (+ reasons), and a program-participation record. All key off `prgm.Program` and/or `dbo.Person`.

> **Contains sensitive student data** (restraint/seclusion events).

#### `sr.ProgramSponsor`
Sponsor descriptor(s) for a program. PK `ProgramSponsorID`. Unique clustered on `(ProgramID, ProgramSponsorDescriptorID)`. FK → `prgm.Program`.

| Column | Type | Notes |
|---|---|---|
| `ProgramSponsorID` | int IDENTITY | PK (nonclustered) |
| `ProgramID` | int | FK → `prgm.Program`; in unique key |
| `ProgramSponsorDescriptorID` | uniqueidentifier | Ed-Fi descriptor |

---

#### `sr.RestraintEvent`
A restraint/seclusion event for a student in a year — event date, educational environment. PK `RestraintEventID`. FKs → `Person`, `SchoolYear`.

| Column | Type | Notes |
|---|---|---|
| `RestraintEventID` | int IDENTITY | PK |
| `StudentID` | int | FK → `Person`; indexed |
| `SchoolYearID` | int | FK → `SchoolYear`; indexed |
| `EventDate` / `EducationalEnvironmentDescriptorID` | mixed | — |

---

#### `sr.RestraintEventReason`
Reason descriptor(s) for a restraint event. PK `RestraintEventReasonID`. Unique on `(RestraintEventID, RestraintEventReasonDescriptorID)`. FK → `sr.RestraintEvent`.

| Column | Type | Notes |
|---|---|---|
| `RestraintEventReasonID` | int IDENTITY | PK |
| `RestraintEventID` | int | FK → `sr.RestraintEvent`; in unique key |
| `RestraintEventReasonDescriptorID` | uniqueidentifier | Ed-Fi descriptor |

---

#### `sr.StudentEducationOrganizationAssociationProgramParticipation`
Student program-participation record (begin/end, designated-by) keyed to a program. PK `SEOAProgramParticipationID`. FKs → `Person`, `prgm.Program`.

| Column | Type | Notes |
|---|---|---|
| `SEOAProgramParticipationID` | int IDENTITY | PK |
| `StudentID` | int | FK → `Person`; indexed |
| `ProgramID` | int | FK → `prgm.Program`; indexed |
| `BeginDate` / `EndDate` / `DesignatedBy` | mixed | Participation span |

---

### `System.Activities.DurableInstancing` schema — Windows Workflow Foundation instance store

> **Third-party framework schema, not application data.** This is the standard **Microsoft SQL Workflow Instance Store** (`System.Activities.DurableInstancing`) used by Windows Workflow Foundation to persist long-running workflow instances. The table shapes are fixed by Microsoft (created by the `SqlWorkflowInstanceStoreSchema.sql` install script), not by FACTS — they appear here only because the app uses WF for some durable/background process. Report developers can safely ignore this schema; it holds serialized workflow state, not SIS data.

Documented as a group (Microsoft-defined; no SIS FKs):

| Table | Role (per WF instance store) |
|---|---|
| `InstancesTable` | Core persisted workflow-instance state (serialized data/metadata blobs, status flags, version, lock owner, service deployment) |
| `KeysTable` | Instance keys (correlation) → instances |
| `LockOwnersTable` | Host lock owners holding instances (lock expiration, machine, host type) |
| `IdentityOwnerTable` | Maps workflow-definition identities to lock owners |
| `DefinitionIdentityTable` | Workflow definition identities (name/package/version) |
| `RunnableInstancesTable` | Instances ready to run (runnable time, host type) |
| `InstanceMetadataChangesTable` | Instance metadata change log (binary) |
| `InstancePromotedPropertiesTable` | Promoted instance properties (`Value1`–`Value32` `sql_variant` + `Value33`–`Value64` `varbinary(max)` — generic promotion slots) |
| `ServiceDeploymentsTable` | Workflow service deployment identity (site/service/namespace paths) |
| `SqlWorkflowInstanceStoreVersionTable` | Instance-store schema version |

> No action needed for SIS reporting. Noted for completeness so the schema's presence in the database is explained (a recognized .NET framework artifact, like a vendor-installed plumbing schema).

---

#### `sr` / `System.Activities.DurableInstancing` — cross-reference summary

| Table | Schema | Scope / notes |
|---|---|---|
| `ProgramSponsor` | sr | Program sponsor descriptors; → `prgm.Program` |
| `RestraintEvent` | sr | Restraint/seclusion events; → `Person`, `SchoolYear` |
| `RestraintEventReason` | sr | Restraint reasons; → `sr.RestraintEvent` |
| `StudentEducationOrganizationAssociationProgramParticipation` | sr | Program participation; → `Person`, `prgm.Program` |
| `InstancesTable` + 9 others | System.Activities.DurableInstancing | **WF instance store (Microsoft framework, not SIS data — ignore for reporting)** |
