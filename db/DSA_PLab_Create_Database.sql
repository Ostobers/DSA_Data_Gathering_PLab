/*
DSA PLab Student Success System | schema 2.0 | SQL Server 2022+
Fresh installation. This replaces the unimplemented v1 design.
Run the whole file in SSMS, or sqlcmd -b -d master -i DSA_PLab_Create_Database.sql.
Requires database creation rights. Existing user tables cause an explicit stop.
Database creation is outside the atomic schema transaction.

One versioned survey model stores every applicant/student/graduate answer.
All 18 repository form variants and three supplements are seeded as DRAFTS. Review question specifications,
configure the renderer/validation, then publish through publish_survey.
Use save_survey_response for draft saving and final submission.
The database stores exact question text including options, scales and branching
instructions. It does not infer executable validation from natural language.

Backend contract
- Hash passwords with a maintained library. Normalize email before writes.
- Provision the account and program record in one transaction when applicable.
  Enforce last-admin protection in the account-management service.
- Resolve actor and owner from authenticated server sessions on every request.
- Save each draft or completed payload through save_survey_response.
- answers_json is the exact collect() answer object from survey.js. Each value
  retains its native JSON type. Keep questionID_other and questionID_why keys.
  Numbers from HTML number inputs arrive as strings and are retained as sent.
- Validate types, allowed options, selection limits, exclusivity, branching and
  required applicable questions in Flask before save_survey_response with @submit=1. The submission
  procedure enforces database ownership, lifecycle and draft finalization.
- Evaluate alert rules in the same transaction as submission. A daily scheduler
  reevaluates career delay. Store triggering values, response ID and rule version.
- Survey definitions and submitted responses are immutable to the backend role.
  Corrections create a new response with supersedes_response_id.
- Identifiable surveys are the default. An anonymous version requires an explicit
  collect_identity=0 definition, no assignment and no account link. Do not attach
  follow-up requests to anonymous response IDs or log identifying request data.
- No AI processing or automatic retention deletion is enabled by this installer.

After install, bootstrap an administrator securely, then execute
  EXEC dbo.seed_initial_alert_rules @admin_user_id = <actual admin ID>;
Map the backend SQL login to a database user and add it to dsa_backend.
Use a separate restricted maintenance principal for purges and restores.
All DATETIME2 values are UTC. No real accounts or default passwords are seeded.
*/
USE [master];
GO
SET IMPLICIT_TRANSACTIONS OFF;
IF @@TRANCOUNT <> 0 THROW 51000, 'Run outside an existing transaction.', 1;
IF DB_ID(N'DSA_Student_Success') IS NULL
    EXEC(N'CREATE DATABASE [DSA_Student_Success];');
GO
USE [DSA_Student_Success];
GO
SET NOCOUNT ON;
SET XACT_ABORT ON;
SET IMPLICIT_TRANSACTIONS OFF;
IF @@TRANCOUNT <> 0 THROW 51000, 'Run outside an existing transaction.', 1;
IF DB_NAME() <> N'DSA_Student_Success' THROW 51001, 'Incorrect database context.', 1;
IF CAST(SERVERPROPERTY('ProductMajorVersion') AS INT) < 16
    THROW 51002, 'SQL Server 2022 or newer is required.', 1;
IF (SELECT compatibility_level FROM sys.databases WHERE name=DB_NAME()) < 130
    THROW 51003, 'Database compatibility level 130 or higher is required.', 1;
BEGIN TRY
BEGIN TRANSACTION;
DECLARE @lock INT;
EXEC @lock = sys.sp_getapplock @Resource=N'DSA_PLab_schema_install',
    @LockMode=N'Exclusive', @LockOwner=N'Transaction', @LockTimeout=10000;
IF @lock < 0 THROW 51004, 'Could not acquire installation lock.', 1;
IF EXISTS (SELECT 1 FROM sys.tables WHERE is_ms_shipped=0)
    OR DATABASE_PRINCIPAL_ID(N'dsa_backend') IS NOT NULL
    THROW 51005, 'User tables or application role already exist. Use a fresh database.', 1;

CREATE TABLE dbo.users (
    id INT IDENTITY(1,1) PRIMARY KEY,
    username NVARCHAR(20) COLLATE Latin1_General_100_BIN2 NOT NULL UNIQUE,
    name NVARCHAR(200) NOT NULL,
    email NVARCHAR(255) COLLATE Latin1_General_100_BIN2 NOT NULL UNIQUE,
    password_hash NVARCHAR(512) NOT NULL,
    role VARCHAR(10) COLLATE Latin1_General_100_BIN2 NOT NULL,
    status VARCHAR(8) COLLATE Latin1_General_100_BIN2 NOT NULL DEFAULT ('active'),
    population VARCHAR(20) COLLATE Latin1_General_100_BIN2 NULL,
    student_id NVARCHAR(30) COLLATE Latin1_General_100_BIN2 NULL,
    preferred_contact VARCHAR(6) NOT NULL DEFAULT ('email'),
    lifecycle_changed_at DATETIME2(7) NOT NULL DEFAULT (SYSUTCDATETIME()),
    created_at DATETIME2(7) NOT NULL DEFAULT (SYSUTCDATETIME()),
    updated_at DATETIME2(7) NOT NULL DEFAULT (SYSUTCDATETIME()),
    credential_version INT NOT NULL DEFAULT (1),
    CHECK (LEN(TRIM(username)) BETWEEN 4 AND 20 AND DATALENGTH(username)=DATALENGTH(TRIM(username))),
    CHECK (LEN(TRIM(name))>0 AND LEN(TRIM(password_hash))>0),
    CHECK (LEN(TRIM(email))>0 AND email=LOWER(email COLLATE Latin1_General_100_CI_AS) COLLATE Latin1_General_100_BIN2 AND DATALENGTH(email)=DATALENGTH(TRIM(email))),
    CHECK (role IN ('student','faculty','admin') AND DATALENGTH(role)=LEN(role)),
    CHECK (status IN ('active','disabled') AND DATALENGTH(status)=LEN(status)),
    CHECK ((role='student' AND population IS NOT NULL AND population IN ('Applicant','Current student','Graduate','Inactive') AND DATALENGTH(population)=LEN(population)) OR (role IN ('faculty','admin') AND population IS NULL AND student_id IS NULL)),
    CHECK (student_id IS NULL OR LEN(TRIM(student_id))>0),
    CHECK (preferred_contact IN ('email','in_app')),
    CHECK (credential_version>=1)
);

CREATE UNIQUE INDEX UX_users_student_id ON dbo.users(student_id) WHERE student_id IS NOT NULL;

CREATE TABLE dbo.academic_terms (
    term_id INT IDENTITY(1,1) PRIMARY KEY,
    term_code VARCHAR(20) NOT NULL UNIQUE,
    label NVARCHAR(60) NOT NULL,
    starts_on DATE NOT NULL,
    ends_on DATE NOT NULL,
    CHECK (ends_on>=starts_on),
    CHECK (LEN(TRIM(term_code))>0 AND LEN(TRIM(label))>0)
);

CREATE TABLE dbo.program_records (
    program_record_id INT IDENTITY(1,1) PRIMARY KEY,
    user_id INT NOT NULL UNIQUE,
    entry_term_id INT NULL,
    expected_graduation DATE NULL,
    graduation_date DATE NULL,
    application_status VARCHAR(12) NULL,
    created_at DATETIME2(7) NOT NULL DEFAULT (SYSUTCDATETIME()),
    updated_at DATETIME2(7) NOT NULL DEFAULT (SYSUTCDATETIME()),
    FOREIGN KEY (user_id) REFERENCES dbo.users(id),
    FOREIGN KEY (entry_term_id) REFERENCES dbo.academic_terms(term_id),
    CHECK (application_status IN ('interested','applied','admitted','declined','enrolled','withdrawn'))
);

CREATE TABLE dbo.courses (
    course_id INT IDENTITY(1,1) PRIMARY KEY,
    course_code VARCHAR(30) NOT NULL UNIQUE,
    title NVARCHAR(200) NOT NULL,
    is_active BIT NOT NULL DEFAULT (1),
    CHECK (LEN(TRIM(course_code))>0 AND LEN(TRIM(title))>0)
);

CREATE TABLE dbo.course_offerings (
    offering_id INT IDENTITY(1,1) PRIMARY KEY,
    course_id INT NOT NULL,
    term_id INT NOT NULL,
    section_code VARCHAR(20) NOT NULL DEFAULT ('01'),
    FOREIGN KEY (course_id) REFERENCES dbo.courses(course_id),
    FOREIGN KEY (term_id) REFERENCES dbo.academic_terms(term_id),
    UNIQUE (course_id,term_id,section_code)
);

CREATE TABLE dbo.student_courses (
    user_id INT NOT NULL,
    offering_id INT NOT NULL,
    enrollment_status VARCHAR(12) NOT NULL DEFAULT ('planned'),
    PRIMARY KEY (user_id,offering_id),
    FOREIGN KEY (user_id) REFERENCES dbo.users(id),
    FOREIGN KEY (offering_id) REFERENCES dbo.course_offerings(offering_id),
    CHECK (enrollment_status IN ('planned','enrolled','completed','withdrawn'))
);

CREATE TABLE dbo.survey_versions (
    survey_version_id INT IDENTITY(1,1) PRIMARY KEY,
    survey_code VARCHAR(60) COLLATE Latin1_General_100_BIN2 NOT NULL,
    version_number INT NOT NULL,
    variant VARCHAR(10) NOT NULL,
    survey_title NVARCHAR(200) NOT NULL,
    form_title NVARCHAR(200) NOT NULL,
    introduction NVARCHAR(MAX) NOT NULL,
    audience VARCHAR(10) NOT NULL,
    publication_status VARCHAR(10) NOT NULL DEFAULT ('draft'),
    collect_identity BIT NOT NULL DEFAULT (1),
    source_reference NVARCHAR(500) NOT NULL,
    source_context_json NVARCHAR(MAX) NOT NULL DEFAULT (N'{}'),
    notice_text NVARCHAR(MAX) NULL,
    created_at DATETIME2(7) NOT NULL DEFAULT (SYSUTCDATETIME()),
    published_at DATETIME2(7) NULL,
    UNIQUE (survey_code,version_number,variant),
    CHECK (ISJSON(source_context_json,OBJECT)=1),
    CHECK (version_number>=1),
    CHECK (variant IN ('single','short','long')),
    CHECK (audience IN ('applicant','current','graduate')),
    CHECK (publication_status IN ('draft','published')),
    CHECK ((publication_status='draft' AND published_at IS NULL) OR (publication_status='published' AND published_at IS NOT NULL))
);

CREATE TABLE dbo.survey_questions (
    question_id INT IDENTITY(1,1) PRIMARY KEY,
    survey_version_id INT NOT NULL,
    question_code NVARCHAR(80) COLLATE Latin1_General_100_BIN2 NOT NULL,
    ordinal INT NOT NULL,
    question_text NVARCHAR(MAX) NOT NULL,
    question_type VARCHAR(10) NOT NULL,
    is_required BIT NOT NULL,
    specification_json NVARCHAR(MAX) NOT NULL,
    FOREIGN KEY (survey_version_id) REFERENCES dbo.survey_versions(survey_version_id),
    UNIQUE (survey_version_id,question_code),
    UNIQUE (survey_version_id,ordinal),
    CHECK (ordinal>=1),
    CHECK (question_type IN ('single','multi','text','long','number','email','dropdown','grid','each','repeat')),
    CHECK (ISJSON(specification_json,OBJECT)=1)
);

CREATE TABLE dbo.survey_assignments (
    assignment_id INT IDENTITY(1,1) PRIMARY KEY,
    user_id INT NOT NULL,
    survey_version_id INT NOT NULL,
    term_id INT NULL,
    event_key VARCHAR(100) NOT NULL,
    due_at DATETIME2(7) NULL,
    followup_month TINYINT NULL,
    cancelled BIT NOT NULL DEFAULT (0),
    created_at DATETIME2(7) NOT NULL DEFAULT (SYSUTCDATETIME()),
    FOREIGN KEY (user_id) REFERENCES dbo.users(id),
    FOREIGN KEY (survey_version_id) REFERENCES dbo.survey_versions(survey_version_id),
    FOREIGN KEY (term_id) REFERENCES dbo.academic_terms(term_id),
    UNIQUE (user_id,survey_version_id,event_key),
    UNIQUE (assignment_id,user_id,survey_version_id),
    CHECK (followup_month IN (3,6,12)),
    CHECK (LEN(TRIM(event_key))>0)
);

CREATE TABLE dbo.survey_responses (
    response_id BIGINT IDENTITY(1,1) PRIMARY KEY,
    request_id UNIQUEIDENTIFIER NOT NULL UNIQUE,
    user_id INT NULL,
    survey_version_id INT NOT NULL,
    assignment_id INT NULL,
    term_id INT NULL,
    supersedes_response_id BIGINT NULL,
    response_status VARCHAR(10) NOT NULL DEFAULT ('draft'),
    revision INT NOT NULL DEFAULT (1),
    answers_json NVARCHAR(MAX) NOT NULL,
    client_submitted_at DATETIME2(7) NULL,
    submitted_at DATETIME2(7) NULL,
    created_at DATETIME2(7) NOT NULL DEFAULT (SYSUTCDATETIME()),
    updated_at DATETIME2(7) NOT NULL DEFAULT (SYSUTCDATETIME()),
    FOREIGN KEY (user_id) REFERENCES dbo.users(id),
    FOREIGN KEY (survey_version_id) REFERENCES dbo.survey_versions(survey_version_id),
    FOREIGN KEY (assignment_id,user_id,survey_version_id) REFERENCES dbo.survey_assignments(assignment_id,user_id,survey_version_id),
    FOREIGN KEY (term_id) REFERENCES dbo.academic_terms(term_id),
    UNIQUE (response_id,user_id),
    UNIQUE (response_id,user_id,survey_version_id),
    FOREIGN KEY (supersedes_response_id,user_id,survey_version_id) REFERENCES dbo.survey_responses(response_id,user_id,survey_version_id),
    CHECK (revision>=1),
    CHECK (ISJSON(answers_json,OBJECT)=1),
    CHECK ((response_status='draft' AND submitted_at IS NULL) OR (response_status='submitted' AND submitted_at IS NOT NULL)),
    CHECK (assignment_id IS NULL OR user_id IS NOT NULL),
    CHECK (supersedes_response_id IS NULL OR (user_id IS NOT NULL AND supersedes_response_id<>response_id))
);

CREATE UNIQUE INDEX UX_response_assignment_submitted ON dbo.survey_responses(assignment_id) WHERE assignment_id IS NOT NULL AND response_status='submitted' AND supersedes_response_id IS NULL;

CREATE UNIQUE INDEX UX_response_correction ON dbo.survey_responses(supersedes_response_id) WHERE supersedes_response_id IS NOT NULL AND response_status='submitted';

CREATE INDEX IX_response_history ON dbo.survey_responses(user_id,survey_version_id,submitted_at DESC,response_id DESC);

CREATE TABLE dbo.contact_preferences (
    user_id INT PRIMARY KEY,
    allow_graduate_contact BIT NOT NULL,
    personal_email NVARCHAR(255) NULL,
    notice_version NVARCHAR(100) NOT NULL,
    recorded_at DATETIME2(7) NOT NULL DEFAULT (SYSUTCDATETIME()),
    FOREIGN KEY (user_id) REFERENCES dbo.users(id),
    CHECK (allow_graduate_contact=1 OR personal_email IS NULL),
    CHECK (personal_email IS NULL OR LEN(TRIM(personal_email))>0)
);

CREATE TABLE dbo.password_reset_tokens (
    token_id BIGINT IDENTITY(1,1) PRIMARY KEY,
    user_id INT NOT NULL,
    token_hash BINARY(32) NOT NULL UNIQUE,
    expires_at DATETIME2(7) NOT NULL,
    used_at DATETIME2(7) NULL,
    created_at DATETIME2(7) NOT NULL DEFAULT (SYSUTCDATETIME()),
    FOREIGN KEY (user_id) REFERENCES dbo.users(id),
    CHECK (expires_at>created_at),
    CHECK (used_at IS NULL OR used_at>=created_at)
);

CREATE TABLE dbo.alert_rules (
    rule_id INT IDENTITY(1,1) PRIMARY KEY,
    rule_code VARCHAR(50) COLLATE Latin1_General_100_BIN2 NOT NULL UNIQUE,
    enabled BIT NOT NULL DEFAULT (1),
    created_at DATETIME2(7) NOT NULL DEFAULT (SYSUTCDATETIME()),
    CHECK (rule_code IN ('LOW_CONFIDENCE','PREREQUISITE_GAP','LOW_BELONGING','HIGH_WORKLOAD','ADVISING_REQUEST','FINANCIAL_PRESSURE','CAREER_DELAY','MULTIPLE_INDICATORS'))
);

CREATE TABLE dbo.alert_rule_versions (
    rule_version_id INT IDENTITY(1,1) PRIMARY KEY,
    rule_id INT NOT NULL,
    version_number INT NOT NULL,
    configuration_json NVARCHAR(4000) NOT NULL,
    severity VARCHAR(6) NOT NULL,
    rule_description NVARCHAR(2000) NOT NULL,
    created_by INT NOT NULL,
    created_at DATETIME2(7) NOT NULL DEFAULT (SYSUTCDATETIME()),
    FOREIGN KEY (rule_id) REFERENCES dbo.alert_rules(rule_id),
    FOREIGN KEY (created_by) REFERENCES dbo.users(id),
    UNIQUE (rule_id,version_number),
    CHECK (version_number>=1),
    CHECK (ISJSON(configuration_json,OBJECT)=1),
    CHECK (severity IN ('low','medium','high'))
);

CREATE TABLE dbo.alerts (
    alert_id BIGINT IDENTITY(1,1) PRIMARY KEY,
    user_id INT NOT NULL,
    source_response_id BIGINT NOT NULL,
    rule_version_id INT NOT NULL,
    event_key VARCHAR(100) NOT NULL,
    trigger_values NVARCHAR(4000) NOT NULL,
    alert_description NVARCHAR(2000) NOT NULL,
    alert_status VARCHAR(8) NOT NULL DEFAULT ('active'),
    reviewed_by INT NULL,
    reviewed_at DATETIME2(7) NULL,
    created_at DATETIME2(7) NOT NULL DEFAULT (SYSUTCDATETIME()),
    FOREIGN KEY (user_id) REFERENCES dbo.users(id),
    FOREIGN KEY (source_response_id,user_id) REFERENCES dbo.survey_responses(response_id,user_id),
    FOREIGN KEY (rule_version_id) REFERENCES dbo.alert_rule_versions(rule_version_id),
    FOREIGN KEY (reviewed_by) REFERENCES dbo.users(id),
    UNIQUE (user_id,rule_version_id,event_key),
    CHECK (ISJSON(trigger_values,OBJECT)=1),
    CHECK ((alert_status='active' AND reviewed_by IS NULL AND reviewed_at IS NULL) OR (alert_status='reviewed' AND reviewed_by IS NOT NULL AND reviewed_at IS NOT NULL))
);

CREATE INDEX IX_alerts_dashboard ON dbo.alerts(user_id,alert_status,created_at DESC);

CREATE INDEX IX_alerts_source ON dbo.alerts(source_response_id,user_id);

CREATE TABLE dbo.follow_up_requests (
    follow_up_id BIGINT IDENTITY(1,1) PRIMARY KEY,
    user_id INT NOT NULL,
    source_response_id BIGINT NULL,
    topic NVARCHAR(100) NOT NULL,
    details NVARCHAR(2000) NULL,
    response_preference NVARCHAR(100) NULL,
    assigned_to INT NULL,
    request_status VARCHAR(10) NOT NULL DEFAULT ('open'),
    closed_at DATETIME2(7) NULL,
    created_at DATETIME2(7) NOT NULL DEFAULT (SYSUTCDATETIME()),
    FOREIGN KEY (user_id) REFERENCES dbo.users(id),
    FOREIGN KEY (source_response_id,user_id) REFERENCES dbo.survey_responses(response_id,user_id),
    FOREIGN KEY (assigned_to) REFERENCES dbo.users(id),
    CHECK ((request_status IN ('open','in_progress') AND closed_at IS NULL) OR (request_status='closed' AND closed_at IS NOT NULL))
);

CREATE TABLE dbo.admin_audit (
    audit_id BIGINT IDENTITY(1,1) PRIMARY KEY,
    actor_user_id INT NOT NULL,
    action_code VARCHAR(50) NOT NULL,
    entity_type VARCHAR(60) NOT NULL,
    entity_key VARCHAR(100) NOT NULL,
    occurred_at DATETIME2(7) NOT NULL DEFAULT (SYSUTCDATETIME()),
    FOREIGN KEY (actor_user_id) REFERENCES dbo.users(id)
);

CREATE TABLE dbo.purge_register (
    purge_id BIGINT IDENTITY(1,1) PRIMARY KEY,
    subject_user_id INT NOT NULL,
    approved_by INT NOT NULL,
    approved_at DATETIME2(7) NOT NULL,
    executed_at DATETIME2(7) NULL,
    reason NVARCHAR(200) NOT NULL,
    FOREIGN KEY (approved_by) REFERENCES dbo.users(id)
);

CREATE TABLE dbo.schema_migrations (
    version VARCHAR(20) PRIMARY KEY,
    description NVARCHAR(200) NOT NULL,
    applied_at DATETIME2(7) NOT NULL DEFAULT (SYSUTCDATETIME())
);

INSERT dbo.survey_versions (survey_code,version_number,variant,survey_title,form_title,introduction,audience,source_reference) VALUES (N'applicant_0',1,N'short',N'Applicant Survey',N'Applicant Survey',N'Please answer the questions below.',N'applicant',N'GitHub dev e3f3b9b5d66b33b60d08a636920165bb01b898e9 / surveys.js');

DECLARE @sv_0 INT = CONVERT(INT,SCOPE_IDENTITY());

INSERT dbo.survey_questions (survey_version_id,question_code,ordinal,question_text,question_type,is_required,specification_json) VALUES (@sv_0,N'A-1',1,N'What is your main reason for pursuing the Data & Analytics program?',N'single',1,N'{"id":"A-1","t":"What is your main reason for pursuing the Data & Analytics program?","type":"single","o":["Career Pivot","Career advancement","Research","Other"],"sec":"Part A: Goals, Motivations, and Program Fit","ph":"Could you specify"}');

INSERT dbo.survey_questions (survey_version_id,question_code,ordinal,question_text,question_type,is_required,specification_json) VALUES (@sv_0,N'A-2',2,N'Which data science tracks or applications areas interest you most?',N'multi',1,N'{"id":"A-2","t":"Which data science tracks or applications areas interest you most?","type":"multi","o":["Predictive modeling","Data analytics","Data engineering","AI/ML"]}');

INSERT dbo.survey_questions (survey_version_id,question_code,ordinal,question_text,question_type,is_required,specification_json) VALUES (@sv_0,N'A-3',3,N'What skills are you looking to build in this program?',N'multi',1,N'{"id":"A-3","t":"What skills are you looking to build in this program?","type":"multi","o":["Analytical","Geographic Information Systems","System Design","Programming","AI prompting"]}');

INSERT dbo.survey_questions (survey_version_id,question_code,ordinal,question_text,question_type,is_required,specification_json) VALUES (@sv_0,N'A-6',4,N'Are you currently employed?',N'single',1,N'{"id":"A-6","t":"Are you currently employed?","type":"single","o":["Yes","No"]}');

INSERT dbo.survey_questions (survey_version_id,question_code,ordinal,question_text,question_type,is_required,specification_json) VALUES (@sv_0,N'A-7',5,N'What sector are you working in?',N'multi',1,N'{"id":"A-7","t":"What sector are you working in?","type":"multi","o":["IT","Healthcare","Real Estate","Retail","Education","Government"],"show":{"javascript_source":"a=>a[''A-6'']==''Yes''"}}');

INSERT dbo.survey_questions (survey_version_id,question_code,ordinal,question_text,question_type,is_required,specification_json) VALUES (@sv_0,N'A-8',6,N'Are you full time or part time?',N'single',1,N'{"id":"A-8","t":"Are you full time or part time?","type":"single","o":["Full time","Part time"],"show":{"javascript_source":"a=>a[''A-6'']==''Yes''"}}');

INSERT dbo.survey_questions (survey_version_id,question_code,ordinal,question_text,question_type,is_required,specification_json) VALUES (@sv_0,N'B-1',7,N'What kind of bachelors did you graduate with?',N'dropdown',1,N'{"id":"B-1","t":"What kind of bachelors did you graduate with?","type":"dropdown","o":["Computer Science","Information Technology / Information Systems","Mathematics","Statistics","Economics","Business / Management","Engineering","Natural Science (Biology, Chemistry, Physics)","Social Science","Arts / Humanities","Other"],"sec":"Part B: Academic and Technical Preparation","note":"Placeholder list: replace with the final list of bachelors."}');

INSERT dbo.survey_questions (survey_version_id,question_code,ordinal,question_text,question_type,is_required,specification_json) VALUES (@sv_0,N'B-2',8,N'Where would you say you focused your studies in your undergrad?',N'multi',1,N'{"id":"B-2","t":"Where would you say you focused your studies in your undergrad?","type":"multi","o":["Math","Business","Economics","Science","Art"]}');

INSERT dbo.survey_questions (survey_version_id,question_code,ordinal,question_text,question_type,is_required,specification_json) VALUES (@sv_0,N'B-4',9,N'What college-level math courses have you completed?',N'multi',1,N'{"id":"B-4","t":"What college-level math courses have you completed?","type":"multi","o":["Calculus","Linear Algebra","Statistics","Discrete Math"],"sec":"Math background"}');

INSERT dbo.survey_questions (survey_version_id,question_code,ordinal,question_text,question_type,is_required,specification_json) VALUES (@sv_0,N'B-5',10,N'How comfortable are you with ___ ?',N'each',1,N'{"id":"B-5","t":"How comfortable are you with ___ ?","type":"each","o":["1 = No comfort","2 = Little comfort","3 = Comfortable","4 = Very comfortable"],"src":"B-4","note":"One question appears for each course selected above.","show":{"javascript_source":"a=>a[''B-4''].length>0"}}');

INSERT dbo.survey_questions (survey_version_id,question_code,ordinal,question_text,question_type,is_required,specification_json) VALUES (@sv_0,N'B-6',11,N'Do you have any coding experiences?',N'single',1,N'{"id":"B-6","t":"Do you have any coding experiences?","type":"single","o":["Yes","No"]}');

INSERT dbo.survey_questions (survey_version_id,question_code,ordinal,question_text,question_type,is_required,specification_json) VALUES (@sv_0,N'B-7',12,N'What programming languages are you familiar with? (select all that apply)',N'multi',1,N'{"id":"B-7","t":"What programming languages are you familiar with? (select all that apply)","type":"multi","o":["Python","R","SQL","Java","Javascript","C++/C#/C","HTML/CSS"],"show":{"javascript_source":"a=>a[''B-6'']==''Yes''"}}');

INSERT dbo.survey_questions (survey_version_id,question_code,ordinal,question_text,question_type,is_required,specification_json) VALUES (@sv_0,N'B-8',13,N'How confident are you in your coding skills?',N'single',1,N'{"id":"B-8","t":"How confident are you in your coding skills?","type":"single","o":["1 = Not confident","2 = Slightly confident","3 = Confident","4 = Very confident"]}');

INSERT dbo.survey_questions (survey_version_id,question_code,ordinal,question_text,question_type,is_required,specification_json) VALUES (@sv_0,N'B-10',14,N'Are you familiar with databases?',N'single',1,N'{"id":"B-10","t":"Are you familiar with databases?","type":"single","o":["Yes","No"]}');

INSERT dbo.survey_questions (survey_version_id,question_code,ordinal,question_text,question_type,is_required,specification_json) VALUES (@sv_0,N'B-11',15,N'What database softwares are you familiar with?',N'multi',1,N'{"id":"B-11","t":"What database softwares are you familiar with?","type":"multi","o":["Postgresql","Microsoft SQL Server","Oracle SQL Developer","MongoDB","SQLite"],"show":{"javascript_source":"a=>a[''B-10'']==''Yes''"}}');

INSERT dbo.survey_versions (survey_code,version_number,variant,survey_title,form_title,introduction,audience,source_reference) VALUES (N'applicant_0',1,N'long',N'Applicant Survey',N'Applicant Survey',N'Please answer the questions below.',N'applicant',N'GitHub dev e3f3b9b5d66b33b60d08a636920165bb01b898e9 / surveys.js');

DECLARE @sv_1 INT = CONVERT(INT,SCOPE_IDENTITY());

INSERT dbo.survey_questions (survey_version_id,question_code,ordinal,question_text,question_type,is_required,specification_json) VALUES (@sv_1,N'A-1',1,N'What is your main reason for pursuing the Data & Analytics program?',N'single',1,N'{"id":"A-1","t":"What is your main reason for pursuing the Data & Analytics program?","type":"single","o":["Career Pivot","Career advancement","Research","Other"],"sec":"Part A: Goals, Motivations, and Program Fit","ph":"Could you specify"}');

INSERT dbo.survey_questions (survey_version_id,question_code,ordinal,question_text,question_type,is_required,specification_json) VALUES (@sv_1,N'A-2',2,N'Which data science tracks or applications areas interest you most?',N'multi',1,N'{"id":"A-2","t":"Which data science tracks or applications areas interest you most?","type":"multi","o":["Predictive modeling","Data analytics","Data engineering","AI/ML"]}');

INSERT dbo.survey_questions (survey_version_id,question_code,ordinal,question_text,question_type,is_required,specification_json) VALUES (@sv_1,N'A-3',3,N'What skills are you looking to build in this program?',N'multi',1,N'{"id":"A-3","t":"What skills are you looking to build in this program?","type":"multi","o":["Analytical","Geographic Information Systems","System Design","Programming","AI prompting"]}');

INSERT dbo.survey_questions (survey_version_id,question_code,ordinal,question_text,question_type,is_required,specification_json) VALUES (@sv_1,N'A-4',4,N'Are you comfortable with using AI?',N'single',1,N'{"id":"A-4","t":"Are you comfortable with using AI?","type":"single","o":["Yes","No"]}');

INSERT dbo.survey_questions (survey_version_id,question_code,ordinal,question_text,question_type,is_required,specification_json) VALUES (@sv_1,N'A-5',5,N'How often do you use AI?',N'single',1,N'{"id":"A-5","t":"How often do you use AI?","type":"single","o":["1 = Not often","2 = Occasionally","3 = Often","4 = Every day"]}');

INSERT dbo.survey_questions (survey_version_id,question_code,ordinal,question_text,question_type,is_required,specification_json) VALUES (@sv_1,N'A-6',6,N'Are you currently employed?',N'single',1,N'{"id":"A-6","t":"Are you currently employed?","type":"single","o":["Yes","No"]}');

INSERT dbo.survey_questions (survey_version_id,question_code,ordinal,question_text,question_type,is_required,specification_json) VALUES (@sv_1,N'A-7',7,N'What sector are you working in?',N'multi',1,N'{"id":"A-7","t":"What sector are you working in?","type":"multi","o":["IT","Healthcare","Real Estate","Retail","Education","Government"],"show":{"javascript_source":"a=>a[''A-6'']==''Yes''"}}');

INSERT dbo.survey_questions (survey_version_id,question_code,ordinal,question_text,question_type,is_required,specification_json) VALUES (@sv_1,N'A-8',8,N'Are you full time or part time?',N'single',1,N'{"id":"A-8","t":"Are you full time or part time?","type":"single","o":["Full time","Part time"],"show":{"javascript_source":"a=>a[''A-6'']==''Yes''"}}');

INSERT dbo.survey_questions (survey_version_id,question_code,ordinal,question_text,question_type,is_required,specification_json) VALUES (@sv_1,N'A-9',9,N'Would you like to know the resources Buffalo State campus provides?',N'single',1,N'{"id":"A-9","t":"Would you like to know the resources Buffalo State campus provides?","type":"single","o":["Yes","No"]}');

INSERT dbo.survey_questions (survey_version_id,question_code,ordinal,question_text,question_type,is_required,specification_json) VALUES (@sv_1,N'B-1',10,N'What kind of bachelors did you graduate with?',N'dropdown',1,N'{"id":"B-1","t":"What kind of bachelors did you graduate with?","type":"dropdown","o":["Computer Science","Information Technology / Information Systems","Mathematics","Statistics","Economics","Business / Management","Engineering","Natural Science (Biology, Chemistry, Physics)","Social Science","Arts / Humanities","Other"],"sec":"Part B: Academic and Technical Preparation","note":"Placeholder list: replace with the final list of bachelors."}');

INSERT dbo.survey_questions (survey_version_id,question_code,ordinal,question_text,question_type,is_required,specification_json) VALUES (@sv_1,N'B-2',11,N'Where would you say you focused your studies in your undergrad?',N'multi',1,N'{"id":"B-2","t":"Where would you say you focused your studies in your undergrad?","type":"multi","o":["Math","Business","Economics","Science","Art"]}');

INSERT dbo.survey_questions (survey_version_id,question_code,ordinal,question_text,question_type,is_required,specification_json) VALUES (@sv_1,N'B-3',12,N'Do you think this focus was well spent?',N'single',1,N'{"id":"B-3","t":"Do you think this focus was well spent?","type":"single","o":["Yes","No"],"why":"Why or why not?"}');

INSERT dbo.survey_questions (survey_version_id,question_code,ordinal,question_text,question_type,is_required,specification_json) VALUES (@sv_1,N'B-4',13,N'What college-level math courses have you completed?',N'multi',1,N'{"id":"B-4","t":"What college-level math courses have you completed?","type":"multi","o":["Calculus","Linear Algebra","Statistics","Discrete Math"],"sec":"Math background"}');

INSERT dbo.survey_questions (survey_version_id,question_code,ordinal,question_text,question_type,is_required,specification_json) VALUES (@sv_1,N'B-5',14,N'How comfortable are you with ___ ?',N'each',1,N'{"id":"B-5","t":"How comfortable are you with ___ ?","type":"each","o":["1 = No comfort","2 = Little comfort","3 = Comfortable","4 = Very comfortable"],"src":"B-4","note":"One question appears for each course selected above.","show":{"javascript_source":"a=>a[''B-4''].length>0"}}');

INSERT dbo.survey_questions (survey_version_id,question_code,ordinal,question_text,question_type,is_required,specification_json) VALUES (@sv_1,N'B-6',15,N'Do you have any coding experiences?',N'single',1,N'{"id":"B-6","t":"Do you have any coding experiences?","type":"single","o":["Yes","No"]}');

INSERT dbo.survey_questions (survey_version_id,question_code,ordinal,question_text,question_type,is_required,specification_json) VALUES (@sv_1,N'B-7',16,N'What programming languages are you familiar with? (select all that apply)',N'multi',1,N'{"id":"B-7","t":"What programming languages are you familiar with? (select all that apply)","type":"multi","o":["Python","R","SQL","Java","Javascript","C++/C#/C","HTML/CSS"],"show":{"javascript_source":"a=>a[''B-6'']==''Yes''"}}');

INSERT dbo.survey_questions (survey_version_id,question_code,ordinal,question_text,question_type,is_required,specification_json) VALUES (@sv_1,N'B-8',17,N'How confident are you in your coding skills?',N'single',1,N'{"id":"B-8","t":"How confident are you in your coding skills?","type":"single","o":["1 = Not confident","2 = Slightly confident","3 = Confident","4 = Very confident"]}');

INSERT dbo.survey_questions (survey_version_id,question_code,ordinal,question_text,question_type,is_required,specification_json) VALUES (@sv_1,N'B-9',18,N'How many completed coding projects do you have?',N'single',1,N'{"id":"B-9","t":"How many completed coding projects do you have?","type":"single","o":["1","A couple","Many"]}');

INSERT dbo.survey_questions (survey_version_id,question_code,ordinal,question_text,question_type,is_required,specification_json) VALUES (@sv_1,N'B-10',19,N'Are you familiar with databases?',N'single',1,N'{"id":"B-10","t":"Are you familiar with databases?","type":"single","o":["Yes","No"]}');

INSERT dbo.survey_questions (survey_version_id,question_code,ordinal,question_text,question_type,is_required,specification_json) VALUES (@sv_1,N'B-11',20,N'What database softwares are you familiar with?',N'multi',1,N'{"id":"B-11","t":"What database softwares are you familiar with?","type":"multi","o":["Postgresql","Microsoft SQL Server","Oracle SQL Developer","MongoDB","SQLite"],"show":{"javascript_source":"a=>a[''B-10'']==''Yes''"}}');

INSERT dbo.survey_questions (survey_version_id,question_code,ordinal,question_text,question_type,is_required,specification_json) VALUES (@sv_1,N'B-12',21,N'How comfortable are you with command line/terminal?',N'single',1,N'{"id":"B-12","t":"How comfortable are you with command line/terminal?","type":"single","o":["1 = No comfort","2 = Little comfort","3 = Comfortable","4 = Very comfortable"]}');

INSERT dbo.survey_questions (survey_version_id,question_code,ordinal,question_text,question_type,is_required,specification_json) VALUES (@sv_1,N'B-13',22,N'How comfortable are you with git/github?',N'single',1,N'{"id":"B-13","t":"How comfortable are you with git/github?","type":"single","o":["1 = No comfort","2 = Little comfort","3 = Comfortable","4 = Very comfortable"]}');

INSERT dbo.survey_questions (survey_version_id,question_code,ordinal,question_text,question_type,is_required,specification_json) VALUES (@sv_1,N'B-14',23,N'How comfortable are you with Jupyter Notebooks?',N'single',1,N'{"id":"B-14","t":"How comfortable are you with Jupyter Notebooks?","type":"single","o":["1 = No comfort","2 = Little comfort","3 = Comfortable","4 = Very comfortable"]}');

INSERT dbo.survey_questions (survey_version_id,question_code,ordinal,question_text,question_type,is_required,specification_json) VALUES (@sv_1,N'B-15',24,N'Are you familiar with IDEs?',N'single',1,N'{"id":"B-15","t":"Are you familiar with IDEs?","type":"single","o":["Yes","No"]}');

INSERT dbo.survey_questions (survey_version_id,question_code,ordinal,question_text,question_type,is_required,specification_json) VALUES (@sv_1,N'B-16',25,N'What is your preferred IDE?',N'single',1,N'{"id":"B-16","t":"What is your preferred IDE?","type":"single","o":["Visual Studio Code","Cursor","Other"],"show":{"javascript_source":"a=>a[''B-15'']==''Yes''"}}');

INSERT dbo.survey_versions (survey_code,version_number,variant,survey_title,form_title,introduction,audience,source_reference) VALUES (N'near_0',1,N'short',N'Near Graduation Survey',N'Near-Graduation Check-in',N'',N'current',N'GitHub dev e3f3b9b5d66b33b60d08a636920165bb01b898e9 / surveys.js');

DECLARE @sv_2 INT = CONVERT(INT,SCOPE_IDENTITY());

INSERT dbo.survey_questions (survey_version_id,question_code,ordinal,question_text,question_type,is_required,specification_json) VALUES (@sv_2,N'A1',1,N'What is your expected graduation term?',N'single',1,N'{"id":"A1","t":"What is your expected graduation term?","type":"single","o":["Fall 2026","Spring 2027","Summer 2027","Fall 2027","Later than Fall 2027"]}');

INSERT dbo.survey_questions (survey_version_id,question_code,ordinal,question_text,question_type,is_required,specification_json) VALUES (@sv_2,N'A2',2,N'What best describes your current status?',N'single',1,N'{"id":"A2","t":"What best describes your current status?","type":"single","o":["I have accepted a job offer","I am actively searching for a job or internship","I plan to search but have not started","I plan to continue my education (PhD or other program)","I am not seeking work after graduation"]}');

INSERT dbo.survey_questions (survey_version_id,question_code,ordinal,question_text,question_type,is_required,specification_json) VALUES (@sv_2,N'A3',3,N'How would you rate your job-search progress so far?',N'single',1,N'{"id":"A3","t":"How would you rate your job-search progress so far?","type":"single","o":["1 = No progress","2 = Very little progress","3 = Some progress","4 = Good progress","5 = Excellent progress / done"],"show":{"javascript_source":"a=>!NOSEARCH.includes(a.A2)"}}');

INSERT dbo.survey_questions (survey_version_id,question_code,ordinal,question_text,question_type,is_required,specification_json) VALUES (@sv_2,N'A4',4,N'Which stage are you at right now?',N'single',1,N'{"id":"A4","t":"Which stage are you at right now?","type":"single","o":["Not started","Preparing materials (resume, LinkedIn, portfolio)","Applying","Interviewing","Have an offer"],"show":{"javascript_source":"a=>!NOSEARCH.includes(a.A2)"}}');

INSERT dbo.survey_questions (survey_version_id,question_code,ordinal,question_text,question_type,is_required,specification_json) VALUES (@sv_2,N'A7',5,N'What are the biggest barriers to your job search right now?',N'multi',1,N'{"id":"A7","t":"What are the biggest barriers to your job search right now?","type":"multi","o":["Technical skills","Projects or portfolio","Networking and connections","Interviewing","Location or relocation","Work authorization or visa","Not enough time","Other","None"],"max":2,"ex":["None"],"show":{"javascript_source":"a=>!NOSEARCH.includes(a.A2)"}}');

INSERT dbo.survey_questions (survey_version_id,question_code,ordinal,question_text,question_type,is_required,specification_json) VALUES (@sv_2,N'A8',6,N'Would you like career or advising help before you graduate?',N'single',1,N'{"id":"A8","t":"Would you like career or advising help before you graduate?","type":"single","o":["Yes","No"],"show":{"javascript_source":"a=>!NOSEARCH.includes(a.A2)"}}');

INSERT dbo.survey_questions (survey_version_id,question_code,ordinal,question_text,question_type,is_required,specification_json) VALUES (@sv_2,N'A9',7,N'May we contact you after graduation to ask about your career?',N'single',1,N'{"id":"A9","t":"May we contact you after graduation to ask about your career?","type":"single","o":["Yes","No"]}');

INSERT dbo.survey_questions (survey_version_id,question_code,ordinal,question_text,question_type,is_required,specification_json) VALUES (@sv_2,N'A10',8,N'What personal email should we use after you graduate?',N'email',1,N'{"id":"A10","t":"What personal email should we use after you graduate?","type":"email","o":0,"show":{"javascript_source":"a=>a.A9==''Yes''"}}');

INSERT dbo.survey_versions (survey_code,version_number,variant,survey_title,form_title,introduction,audience,source_reference) VALUES (N'near_0',1,N'long',N'Near Graduation Survey',N'Near-Graduation Check-in',N'',N'current',N'GitHub dev e3f3b9b5d66b33b60d08a636920165bb01b898e9 / surveys.js');

DECLARE @sv_3 INT = CONVERT(INT,SCOPE_IDENTITY());

INSERT dbo.survey_questions (survey_version_id,question_code,ordinal,question_text,question_type,is_required,specification_json) VALUES (@sv_3,N'A1',1,N'What is your expected graduation term?',N'single',1,N'{"id":"A1","t":"What is your expected graduation term?","type":"single","o":["Fall 2026","Spring 2027","Summer 2027","Fall 2027","Later than Fall 2027"]}');

INSERT dbo.survey_questions (survey_version_id,question_code,ordinal,question_text,question_type,is_required,specification_json) VALUES (@sv_3,N'A2',2,N'What best describes your current status?',N'single',1,N'{"id":"A2","t":"What best describes your current status?","type":"single","o":["I have accepted a job offer","I am actively searching for a job or internship","I plan to search but have not started","I plan to continue my education (PhD or other program)","I am not seeking work after graduation"]}');

INSERT dbo.survey_questions (survey_version_id,question_code,ordinal,question_text,question_type,is_required,specification_json) VALUES (@sv_3,N'A3',3,N'How would you rate your job-search progress so far?',N'single',1,N'{"id":"A3","t":"How would you rate your job-search progress so far?","type":"single","o":["1 = No progress","2 = Very little progress","3 = Some progress","4 = Good progress","5 = Excellent progress / done"],"show":{"javascript_source":"a=>!NOSEARCH.includes(a.A2)"}}');

INSERT dbo.survey_questions (survey_version_id,question_code,ordinal,question_text,question_type,is_required,specification_json) VALUES (@sv_3,N'A4',4,N'Which stage are you at right now?',N'single',1,N'{"id":"A4","t":"Which stage are you at right now?","type":"single","o":["Not started","Preparing materials (resume, LinkedIn, portfolio)","Applying","Interviewing","Have an offer"],"show":{"javascript_source":"a=>!NOSEARCH.includes(a.A2)"}}');

INSERT dbo.survey_questions (survey_version_id,question_code,ordinal,question_text,question_type,is_required,specification_json) VALUES (@sv_3,N'A5',5,N'What type of role are you targeting?',N'single',1,N'{"id":"A5","t":"What type of role are you targeting?","type":"single","o":["Data scientist","Data analyst","Data or machine learning engineer","Database engineer","Business intelligence / business analyst","Research scientist","Statistician / quantitative analyst","Other","Not sure yet"],"show":{"javascript_source":"a=>!NOSEARCH.includes(a.A2)"}}');

INSERT dbo.survey_questions (survey_version_id,question_code,ordinal,question_text,question_type,is_required,specification_json) VALUES (@sv_3,N'A6',6,N'How confident are you that you are ready for a data-science job?',N'single',1,N'{"id":"A6","t":"How confident are you that you are ready for a data-science job?","type":"single","o":["1 = Not at all confident","2 = Slightly confident","3 = Moderately confident","4 = Very confident","5 = Extremely confident"],"show":{"javascript_source":"a=>!NOSEARCH.includes(a.A2)"}}');

INSERT dbo.survey_questions (survey_version_id,question_code,ordinal,question_text,question_type,is_required,specification_json) VALUES (@sv_3,N'A7',7,N'What are the biggest barriers to your job search right now?',N'multi',1,N'{"id":"A7","t":"What are the biggest barriers to your job search right now?","type":"multi","o":["Technical skills","Projects or portfolio","Networking and connections","Interviewing","Location or relocation","Work authorization or visa","Not enough time","Other","None"],"max":2,"ex":["None"],"show":{"javascript_source":"a=>!NOSEARCH.includes(a.A2)"}}');

INSERT dbo.survey_questions (survey_version_id,question_code,ordinal,question_text,question_type,is_required,specification_json) VALUES (@sv_3,N'A8',8,N'Would you like career or advising help before you graduate?',N'single',1,N'{"id":"A8","t":"Would you like career or advising help before you graduate?","type":"single","o":["Yes","No"],"show":{"javascript_source":"a=>!NOSEARCH.includes(a.A2)"}}');

INSERT dbo.survey_questions (survey_version_id,question_code,ordinal,question_text,question_type,is_required,specification_json) VALUES (@sv_3,N'A9',9,N'May we contact you after graduation to ask about your career?',N'single',1,N'{"id":"A9","t":"May we contact you after graduation to ask about your career?","type":"single","o":["Yes","No"]}');

INSERT dbo.survey_questions (survey_version_id,question_code,ordinal,question_text,question_type,is_required,specification_json) VALUES (@sv_3,N'A10',10,N'What personal email should we use after you graduate?',N'email',1,N'{"id":"A10","t":"What personal email should we use after you graduate?","type":"email","o":0,"show":{"javascript_source":"a=>a.A9==''Yes''"}}');

INSERT dbo.survey_questions (survey_version_id,question_code,ordinal,question_text,question_type,is_required,specification_json) VALUES (@sv_3,N'A11',11,N'Anything else we should know?',N'long',0,N'{"id":"A11","t":"Anything else we should know?","type":"long","o":0,"req":false}');

INSERT dbo.survey_questions (survey_version_id,question_code,ordinal,question_text,question_type,is_required,specification_json) VALUES (@sv_3,N'A12',12,N'What method(s) are you using in the course of your job search?',N'long',0,N'{"id":"A12","t":"What method(s) are you using in the course of your job search?","type":"long","o":0,"show":{"javascript_source":"a=>a.A2==''I am actively searching for a job or internship''"},"req":false}');

INSERT dbo.survey_versions (survey_code,version_number,variant,survey_title,form_title,introduction,audience,source_reference) VALUES (N'after_0',1,N'short',N'After Graduation Survey',N'Post-graduation Survey',N'This takes about 3 minutes. Your answers help us improve the program for future students. Salary and comment questions are optional. (Intended to be sent at 3, 6, and 12 months.)',N'graduate',N'GitHub dev e3f3b9b5d66b33b60d08a636920165bb01b898e9 / surveys.js');

DECLARE @sv_4 INT = CONVERT(INT,SCOPE_IDENTITY());

INSERT dbo.survey_questions (survey_version_id,question_code,ordinal,question_text,question_type,is_required,specification_json) VALUES (@sv_4,N'B1',1,N'What term did you graduate?',N'single',1,N'{"id":"B1","t":"What term did you graduate?","type":"single","o":["Fall 2026","Spring 2027","Summer 2027","Fall 2027","Other"]}');

INSERT dbo.survey_questions (survey_version_id,question_code,ordinal,question_text,question_type,is_required,specification_json) VALUES (@sv_4,N'B2',2,N'What is your current status?',N'single',1,N'{"id":"B2","t":"What is your current status?","type":"single","o":["Employed full-time","Employed part-time","Self-employed / freelance","Seeking employment","Continuing education","Not seeking employment"]}');

INSERT dbo.survey_questions (survey_version_id,question_code,ordinal,question_text,question_type,is_required,specification_json) VALUES (@sv_4,N'B3',3,N'How many months after graduation did you start your job?',N'number',1,N'{"id":"B3","t":"How many months after graduation did you start your job?","type":"number","o":0,"note":"Enter 0 if you started before graduating.","show":{"javascript_source":"a=>EMP.includes(a.B2)"}}');

INSERT dbo.survey_questions (survey_version_id,question_code,ordinal,question_text,question_type,is_required,specification_json) VALUES (@sv_4,N'B4',4,N'What is your job title?',N'text',1,N'{"id":"B4","t":"What is your job title?","type":"text","o":0,"note":"Please give a general title (for example \"data analyst\") rather than your exact title.","show":{"javascript_source":"a=>EMP.includes(a.B2)"}}');

INSERT dbo.survey_questions (survey_version_id,question_code,ordinal,question_text,question_type,is_required,specification_json) VALUES (@sv_4,N'B6',5,N'Does your job use data-science skills?',N'single',1,N'{"id":"B6","t":"Does your job use data-science skills?","type":"single","o":["Yes, mostly","Partly","No"],"show":{"javascript_source":"a=>EMP.includes(a.B2)"}}');

INSERT dbo.survey_questions (survey_version_id,question_code,ordinal,question_text,question_type,is_required,specification_json) VALUES (@sv_4,N'B9',6,N'How many months have you been searching?',N'number',1,N'{"id":"B9","t":"How many months have you been searching?","type":"number","o":0,"show":{"javascript_source":"a=>a.B2==''Seeking employment''"}}');

INSERT dbo.survey_questions (survey_version_id,question_code,ordinal,question_text,question_type,is_required,specification_json) VALUES (@sv_4,N'B10',7,N'What is the main barrier to finding a job?',N'multi',1,N'{"id":"B10","t":"What is the main barrier to finding a job?","type":"multi","o":["Not enough interviews","Skills gaps","Lack of experience","Location","Work authorization or visa","Job market conditions","Lack of industry connections","Other"],"note":"You may select more than one.","show":{"javascript_source":"a=>a.B2==''Seeking employment''"}}');

INSERT dbo.survey_questions (survey_version_id,question_code,ordinal,question_text,question_type,is_required,specification_json) VALUES (@sv_4,N'B11',8,N'How well did the program prepare you for employment?',N'single',1,N'{"id":"B11","t":"How well did the program prepare you for employment?","type":"single","o":["1 = Not at all prepared","2 = Slightly prepared","3 = Moderately prepared","4 = Well prepared","5 = Extremely well prepared"]}');

INSERT dbo.survey_versions (survey_code,version_number,variant,survey_title,form_title,introduction,audience,source_reference) VALUES (N'after_0',1,N'long',N'After Graduation Survey',N'Post-graduation Survey',N'This takes about 3 minutes. Your answers help us improve the program for future students. Salary and comment questions are optional. (Intended to be sent at 3, 6, and 12 months.)',N'graduate',N'GitHub dev e3f3b9b5d66b33b60d08a636920165bb01b898e9 / surveys.js');

DECLARE @sv_5 INT = CONVERT(INT,SCOPE_IDENTITY());

INSERT dbo.survey_questions (survey_version_id,question_code,ordinal,question_text,question_type,is_required,specification_json) VALUES (@sv_5,N'B1',1,N'What term did you graduate?',N'single',1,N'{"id":"B1","t":"What term did you graduate?","type":"single","o":["Fall 2026","Spring 2027","Summer 2027","Fall 2027","Other"]}');

INSERT dbo.survey_questions (survey_version_id,question_code,ordinal,question_text,question_type,is_required,specification_json) VALUES (@sv_5,N'B2',2,N'What is your current status?',N'single',1,N'{"id":"B2","t":"What is your current status?","type":"single","o":["Employed full-time","Employed part-time","Self-employed / freelance","Seeking employment","Continuing education","Not seeking employment"]}');

INSERT dbo.survey_questions (survey_version_id,question_code,ordinal,question_text,question_type,is_required,specification_json) VALUES (@sv_5,N'B3',3,N'How many months after graduation did you start your job?',N'number',1,N'{"id":"B3","t":"How many months after graduation did you start your job?","type":"number","o":0,"note":"Enter 0 if you started before graduating.","show":{"javascript_source":"a=>EMP.includes(a.B2)"}}');

INSERT dbo.survey_questions (survey_version_id,question_code,ordinal,question_text,question_type,is_required,specification_json) VALUES (@sv_5,N'B4',4,N'What is your job title?',N'text',1,N'{"id":"B4","t":"What is your job title?","type":"text","o":0,"note":"Please give a general title (for example \"data analyst\") rather than your exact title.","show":{"javascript_source":"a=>EMP.includes(a.B2)"}}');

INSERT dbo.survey_questions (survey_version_id,question_code,ordinal,question_text,question_type,is_required,specification_json) VALUES (@sv_5,N'B5',5,N'What industry do you work in?',N'dropdown',1,N'{"id":"B5","t":"What industry do you work in?","type":"dropdown","o":["Technology / software","Finance, banking, or insurance","Healthcare, pharma, or biotech","Government / public sector","Education or nonprofit","Consulting","Retail, e-commerce, or consumer goods","Manufacturing or energy","Media, entertainment, or sports","Other"],"show":{"javascript_source":"a=>EMP.includes(a.B2)"}}');

INSERT dbo.survey_questions (survey_version_id,question_code,ordinal,question_text,question_type,is_required,specification_json) VALUES (@sv_5,N'B6',6,N'Does your job use data-science skills?',N'single',1,N'{"id":"B6","t":"Does your job use data-science skills?","type":"single","o":["Yes, mostly","Partly","No"],"show":{"javascript_source":"a=>EMP.includes(a.B2)"}}');

INSERT dbo.survey_questions (survey_version_id,question_code,ordinal,question_text,question_type,is_required,specification_json) VALUES (@sv_5,N'B7',7,N'How did you find this job?',N'single',1,N'{"id":"B7","t":"How did you find this job?","type":"single","o":["University career services","Professional or personal network","Online job posting","Internship converted to full-time","Faculty or program referral","Recruiter","Other"],"show":{"javascript_source":"a=>EMP.includes(a.B2)"}}');

INSERT dbo.survey_questions (survey_version_id,question_code,ordinal,question_text,question_type,is_required,specification_json) VALUES (@sv_5,N'B8',8,N'What is your approximate annual salary?',N'single',0,N'{"id":"B8","t":"What is your approximate annual salary?","type":"single","o":["Under $60,000","$60,000 to $79,999","$80,000 to $99,999","$100,000 to $119,999","$120,000 to $149,999","$150,000 or more","Prefer not to say"],"show":{"javascript_source":"a=>EMP.includes(a.B2)"},"req":false}');

INSERT dbo.survey_questions (survey_version_id,question_code,ordinal,question_text,question_type,is_required,specification_json) VALUES (@sv_5,N'B9',9,N'How many months have you been searching?',N'number',1,N'{"id":"B9","t":"How many months have you been searching?","type":"number","o":0,"show":{"javascript_source":"a=>a.B2==''Seeking employment''"}}');

INSERT dbo.survey_questions (survey_version_id,question_code,ordinal,question_text,question_type,is_required,specification_json) VALUES (@sv_5,N'B10',10,N'What is the main barrier to finding a job?',N'multi',1,N'{"id":"B10","t":"What is the main barrier to finding a job?","type":"multi","o":["Not enough interviews","Skills gaps","Lack of experience","Location","Work authorization or visa","Job market conditions","Lack of industry connections","Other"],"note":"You may select more than one.","show":{"javascript_source":"a=>a.B2==''Seeking employment''"}}');

INSERT dbo.survey_questions (survey_version_id,question_code,ordinal,question_text,question_type,is_required,specification_json) VALUES (@sv_5,N'B11',11,N'How well did the program prepare you for employment?',N'single',1,N'{"id":"B11","t":"How well did the program prepare you for employment?","type":"single","o":["1 = Not at all prepared","2 = Slightly prepared","3 = Moderately prepared","4 = Well prepared","5 = Extremely well prepared"]}');

INSERT dbo.survey_questions (survey_version_id,question_code,ordinal,question_text,question_type,is_required,specification_json) VALUES (@sv_5,N'B12',12,N'Which skills do you wish you had developed more?',N'multi',1,N'{"id":"B12","t":"Which skills do you wish you had developed more?","type":"multi","o":["Programming / software engineering","Statistics or machine learning depth","Deep learning / AI","Data engineering, SQL, or cloud tools","Data visualization and communication","Domain or business knowledge","Teamwork and project management","Interviewing and job-search skills","Portfolio projects","Other"],"max":3}');

INSERT dbo.survey_questions (survey_version_id,question_code,ordinal,question_text,question_type,is_required,specification_json) VALUES (@sv_5,N'B13',13,N'How likely are you to recommend this program to a prospective student?',N'single',1,N'{"id":"B13","t":"How likely are you to recommend this program to a prospective student?","type":"single","o":["1 = Very unlikely","2 = Unlikely","3 = Neutral","4 = Likely","5 = Very likely"]}');

INSERT dbo.survey_questions (survey_version_id,question_code,ordinal,question_text,question_type,is_required,specification_json) VALUES (@sv_5,N'B14',14,N'Any other feedback about the program or your career path?',N'long',0,N'{"id":"B14","t":"Any other feedback about the program or your career path?","type":"long","o":0,"req":false}');

INSERT dbo.survey_versions (survey_code,version_number,variant,survey_title,form_title,introduction,audience,source_reference) VALUES (N'current_0',1,N'single',N'Current Student Surveys',N'Recurring Student Check-in',N'Complete this check-in periodically during the semester. It takes less than three minutes and helps faculty notice changes over time and identify requests for support.',N'current',N'GitHub dev e3f3b9b5d66b33b60d08a636920165bb01b898e9 / surveys.js');

DECLARE @sv_6 INT = CONVERT(INT,SCOPE_IDENTITY());

INSERT dbo.survey_questions (survey_version_id,question_code,ordinal,question_text,question_type,is_required,specification_json) VALUES (@sv_6,N'C1',1,N'How confident do you feel about your knowledge and abilities in Data Science and Analytics?',N'single',1,N'{"id":"C1","t":"How confident do you feel about your knowledge and abilities in Data Science and Analytics?","type":"single","o":["1 = Very low","2 = Low","3 = Moderate","4 = High","5 = Very high"],"sec":"Current experience"}');

INSERT dbo.survey_questions (survey_version_id,question_code,ordinal,question_text,question_type,is_required,specification_json) VALUES (@sv_6,N'C2',2,N'How strongly do you feel that you belong in the DSA program?',N'single',1,N'{"id":"C2","t":"How strongly do you feel that you belong in the DSA program?","type":"single","o":["1 = Very low","2 = Low","3 = Moderate","4 = High","5 = Very high"]}');

INSERT dbo.survey_questions (survey_version_id,question_code,ordinal,question_text,question_type,is_required,specification_json) VALUES (@sv_6,N'C3',3,N'How satisfied are you with your overall experience in the DSA program?',N'single',1,N'{"id":"C3","t":"How satisfied are you with your overall experience in the DSA program?","type":"single","o":["1 = Very low","2 = Low","3 = Moderate","4 = High","5 = Very high"]}');

INSERT dbo.survey_questions (survey_version_id,question_code,ordinal,question_text,question_type,is_required,specification_json) VALUES (@sv_6,N'C4',4,N'How much pressure are you currently experiencing from your academic workload?',N'single',1,N'{"id":"C4","t":"How much pressure are you currently experiencing from your academic workload?","type":"single","o":["1 = Very low","2 = Low","3 = Moderate","4 = High","5 = Very high"]}');

INSERT dbo.survey_questions (survey_version_id,question_code,ordinal,question_text,question_type,is_required,specification_json) VALUES (@sv_6,N'C5',5,N'Would you like academic advising or additional support from a faculty member?',N'single',1,N'{"id":"C5","t":"Would you like academic advising or additional support from a faculty member?","type":"single","o":["Yes","No"]}');

INSERT dbo.survey_questions (survey_version_id,question_code,ordinal,question_text,question_type,is_required,specification_json) VALUES (@sv_6,N'C6',6,N'How much are financial concerns affecting your ability to continue and succeed in the program?',N'single',1,N'{"id":"C6","t":"How much are financial concerns affecting your ability to continue and succeed in the program?","type":"single","o":["1 = Very low","2 = Low","3 = Moderate","4 = High","5 = Very high"]}');

INSERT dbo.survey_questions (survey_version_id,question_code,ordinal,question_text,question_type,is_required,specification_json) VALUES (@sv_6,N'C7',7,N'How would you rate your progress toward securing an internship or job related to Data Science and Analytics?',N'single',1,N'{"id":"C7","t":"How would you rate your progress toward securing an internship or job related to Data Science and Analytics?","type":"single","o":["1 = Very low","2 = Low","3 = Moderate","4 = High","5 = Very high"],"sec":"Career progress"}');

INSERT dbo.survey_questions (survey_version_id,question_code,ordinal,question_text,question_type,is_required,specification_json) VALUES (@sv_6,N'C7a',8,N'Which stage best describes your current internship or job search?',N'single',1,N'{"id":"C7a","t":"Which stage best describes your current internship or job search?","type":"single","o":["Not currently searching","Exploring roles or industries","Preparing application materials","Identifying opportunities","Submitting applications","Interviewing or completing assessments","Considering an offer","Accepted an offer","Started an internship or job"]}');

INSERT dbo.survey_questions (survey_version_id,question_code,ordinal,question_text,question_type,is_required,specification_json) VALUES (@sv_6,N'C8',9,N'Is there anything else you would like to share about your academic experience, challenges, or support needs?',N'long',0,N'{"id":"C8","t":"Is there anything else you would like to share about your academic experience, challenges, or support needs?","type":"long","o":0,"req":false}');

INSERT dbo.survey_versions (survey_code,version_number,variant,survey_title,form_title,introduction,audience,source_reference) VALUES (N'current_1',1,N'short',N'Current Student Surveys',N'Beginning of the Program',N'Complete this during the first two weeks of the program. Help us understand your starting point, goals, and support needs. Estimated time: 4–5 minutes.',N'current',N'GitHub dev e3f3b9b5d66b33b60d08a636920165bb01b898e9 / surveys.js');

DECLARE @sv_7 INT = CONVERT(INT,SCOPE_IDENTITY());

INSERT dbo.survey_questions (survey_version_id,question_code,ordinal,question_text,question_type,is_required,specification_json) VALUES (@sv_7,N'S1-1',1,N'What was your primary undergraduate field of study?',N'text',1,N'{"id":"S1-1","t":"What was your primary undergraduate field of study?","type":"text","o":0,"note":"You may type \"Other\" or \"Prefer not to answer\"."}');

INSERT dbo.survey_questions (survey_version_id,question_code,ordinal,question_text,question_type,is_required,specification_json) VALUES (@sv_7,N'S1-2',2,N'How much experience do you have in each area?',N'grid',1,N'{"id":"S1-2","t":"How much experience do you have in each area?","type":"grid","o":["No experience","Introductory exposure","Can complete basic tasks independently","Can complete advanced tasks independently"],"rows":["Python programming","SQL and relational databases","Statistics and probability","Linear algebra","Data cleaning and analysis","Data visualization"]}');

INSERT dbo.survey_questions (survey_version_id,question_code,ordinal,question_text,question_type,is_required,specification_json) VALUES (@sv_7,N'S1-3',3,N'Have you been told that you need to complete any prerequisites or preparation activities?',N'single',1,N'{"id":"S1-3","t":"Have you been told that you need to complete any prerequisites or preparation activities?","type":"single","o":["Yes","No","Unsure"]}');

INSERT dbo.survey_questions (survey_version_id,question_code,ordinal,question_text,question_type,is_required,specification_json) VALUES (@sv_7,N'S1-3a',4,N'Which remain incomplete?',N'text',0,N'{"id":"S1-3a","t":"Which remain incomplete?","type":"text","o":0,"show":{"javascript_source":"a=>a[''S1-3'']==''Yes''"},"req":false}');

INSERT dbo.survey_questions (survey_version_id,question_code,ordinal,question_text,question_type,is_required,specification_json) VALUES (@sv_7,N'S1-4',5,N'In which areas would you most benefit from introductory support?',N'multi',1,N'{"id":"S1-4","t":"In which areas would you most benefit from introductory support?","type":"multi","o":["Programming","Databases and SQL","Mathematics","Statistics","Using development tools","Academic writing or communicating results","Study strategies or time management","Unsure","Other","No introductory support needed"],"ex":["Unsure","No introductory support needed"],"oo":1}');

INSERT dbo.survey_questions (survey_version_id,question_code,ordinal,question_text,question_type,is_required,specification_json) VALUES (@sv_7,N'S1-5',6,N'What are your main goals for completing this program?',N'multi',1,N'{"id":"S1-5","t":"What are your main goals for completing this program?","type":"multi","o":["Begin a career in data science or analytics","Advance in my current career","Change careers","Prepare for further study or research","Apply data skills within another field","Develop technical skills","Explore career possibilities","Other"],"max":3,"oo":1}');

INSERT dbo.survey_questions (survey_version_id,question_code,ordinal,question_text,question_type,is_required,specification_json) VALUES (@sv_7,N'S1-6',7,N'Which career areas currently interest you?',N'multi',1,N'{"id":"S1-6","t":"Which career areas currently interest you?","type":"multi","o":["Data analysis or business intelligence","Data science or machine learning","Data engineering or database work","Research","Applying data science in a specific industry","Still exploring","Other"],"oo":1}');

INSERT dbo.survey_questions (survey_version_id,question_code,ordinal,question_text,question_type,is_required,specification_json) VALUES (@sv_7,N'S1-6a',8,N'Specify an industry or role.',N'text',0,N'{"id":"S1-6a","t":"Specify an industry or role.","type":"text","o":0,"req":false}');

INSERT dbo.survey_questions (survey_version_id,question_code,ordinal,question_text,question_type,is_required,specification_json) VALUES (@sv_7,N'S1-7',9,N'What do you most want to learn or accomplish during your first semester?',N'long',0,N'{"id":"S1-7","t":"What do you most want to learn or accomplish during your first semester?","type":"long","o":0,"req":false}');

INSERT dbo.survey_questions (survey_version_id,question_code,ordinal,question_text,question_type,is_required,specification_json) VALUES (@sv_7,N'S1-8',10,N'Which resources would help you get started?',N'multi',1,N'{"id":"S1-8","t":"Which resources would help you get started?","type":"multi","o":["Preparation materials or refresher exercises","Tutoring or academic support","Course-planning guidance","Software and tool setup","Career information","Classmates or a study group","University support-service information","Unsure","Other","None at this time"],"ex":["Unsure","None at this time"],"oo":1}');

INSERT dbo.survey_versions (survey_code,version_number,variant,survey_title,form_title,introduction,audience,source_reference) VALUES (N'current_1',1,N'long',N'Current Student Surveys',N'Beginning of the Program',N'Complete this during the first two weeks of the program. Your responses help the DSA MS program understand your starting point and provide relevant academic and career support. You may skip optional questions. Estimated time: 12–15 minutes.',N'current',N'GitHub dev e3f3b9b5d66b33b60d08a636920165bb01b898e9 / surveys.js');

DECLARE @sv_8 INT = CONVERT(INT,SCOPE_IDENTITY());

INSERT dbo.survey_questions (survey_version_id,question_code,ordinal,question_text,question_type,is_required,specification_json) VALUES (@sv_8,N'L1-1',1,N'What was your primary undergraduate field of study?',N'text',1,N'{"id":"L1-1","t":"What was your primary undergraduate field of study?","type":"text","o":0,"sec":"A. Background"}');

INSERT dbo.survey_questions (survey_version_id,question_code,ordinal,question_text,question_type,is_required,specification_json) VALUES (@sv_8,N'L1-2',2,N'Have you completed other relevant degrees, certificates, or substantial training?',N'single',1,N'{"id":"L1-2","t":"Have you completed other relevant degrees, certificates, or substantial training?","type":"single","o":["Yes","No"]}');

INSERT dbo.survey_questions (survey_version_id,question_code,ordinal,question_text,question_type,is_required,specification_json) VALUES (@sv_8,N'L1-2a',3,N'Describe subject and type.',N'text',0,N'{"id":"L1-2a","t":"Describe subject and type.","type":"text","o":0,"show":{"javascript_source":"a=>a[''L1-2'']==''Yes''"},"req":false}');

INSERT dbo.survey_questions (survey_version_id,question_code,ordinal,question_text,question_type,is_required,specification_json) VALUES (@sv_8,N'L1-3',4,N'What relevant experience do you bring?',N'multi',1,N'{"id":"L1-3","t":"What relevant experience do you bring?","type":"multi","o":["Data-analysis coursework","Data/technology employment","Internship","Research","Personal projects","Community projects","No experience","Other"],"ex":["No experience"],"oo":1}');

INSERT dbo.survey_questions (survey_version_id,question_code,ordinal,question_text,question_type,is_required,specification_json) VALUES (@sv_8,N'L1-3a',5,N'Describe one experience representing your abilities.',N'long',0,N'{"id":"L1-3a","t":"Describe one experience representing your abilities.","type":"long","o":0,"req":false}');

INSERT dbo.survey_questions (survey_version_id,question_code,ordinal,question_text,question_type,is_required,specification_json) VALUES (@sv_8,N'L1-4',6,N'Rate your experience in each area.',N'grid',1,N'{"id":"L1-4","t":"Rate your experience in each area.","type":"grid","o":["No experience","Some exposure","Basic tasks independently","Advanced tasks independently","Unsure"],"rows":["Python","SQL/databases","Statistics/probability","Linear algebra","Calculus","Data cleaning/analysis","Visualization","Machine learning","Git/version control","Command-line/development environments","Technical communication"],"sec":"B. Preparation"}');

INSERT dbo.survey_questions (survey_version_id,question_code,ordinal,question_text,question_type,is_required,specification_json) VALUES (@sv_8,N'L1-5',7,N'Which activities have you completed?',N'multi',1,N'{"id":"L1-5","t":"Which activities have you completed?","type":"multi","o":["Data-processing program","SQL query","Cleaning missing/inconsistent data","Statistical analysis","Training/evaluating a model","Communicating through visualization","Team project with shared tools","Explaining findings to a nontechnical audience","None"],"ex":["None"]}');

INSERT dbo.survey_questions (survey_version_id,question_code,ordinal,question_text,question_type,is_required,specification_json) VALUES (@sv_8,N'L1-6',8,N'Have you been assigned prerequisites or preparation activities?',N'single',1,N'{"id":"L1-6","t":"Have you been assigned prerequisites or preparation activities?","type":"single","o":["Yes","No","Unsure"]}');

INSERT dbo.survey_questions (survey_version_id,question_code,ordinal,question_text,question_type,is_required,specification_json) VALUES (@sv_8,N'L1-6-items',9,N'Assigned preparation activities',N'repeat',1,N'{"id":"L1-6-items","t":"Assigned preparation activities","type":"repeat","o":[{"id":"activity","t":"Prerequisite or preparation activity","type":"text","o":0},{"id":"status","t":"Status","type":"single","o":["Completed","In progress","Not started"]},{"id":"help","t":"Do you need help with this activity?","type":"single","o":["Yes","No","Unsure"]}],"show":{"javascript_source":"a=>a[''L1-6'']==''Yes''"},"itemLabel":"Activity","addLabel":"Add another activity"}');

INSERT dbo.survey_questions (survey_version_id,question_code,ordinal,question_text,question_type,is_required,specification_json) VALUES (@sv_8,N'L1-7',10,N'Which subjects need additional preparation?',N'multi',1,N'{"id":"L1-7","t":"Which subjects need additional preparation?","type":"multi","o":["Python","SQL/databases","Statistics/probability","Linear algebra","Calculus","Data cleaning/analysis","Visualization","Machine learning","Git/version control","Command-line/development environments","Technical communication","None","Unsure"],"ex":["None","Unsure"]}');

INSERT dbo.survey_questions (survey_version_id,question_code,ordinal,question_text,question_type,is_required,specification_json) VALUES (@sv_8,N'L1-8',11,N'Which preparation formats would help?',N'multi',1,N'{"id":"L1-8","t":"Which preparation formats would help?","type":"multi","o":["Tutorials","Workshops","Exercises with solutions","Tutoring","Peer groups","Prerequisite course","Faculty office hours","Unsure","Other"],"ex":["Unsure"],"oo":1}');

INSERT dbo.survey_questions (survey_version_id,question_code,ordinal,question_text,question_type,is_required,specification_json) VALUES (@sv_8,N'L1-9',12,N'Main reasons for the degree?',N'multi',1,N'{"id":"L1-9","t":"Main reasons for the degree?","type":"multi","o":["Enter data career","Advance career","Change career","Doctoral study/research","Apply data in another field","Technical expertise","Explore careers","Other"],"max":3,"oo":1,"sec":"C. Goals and expectations"}');

INSERT dbo.survey_questions (survey_version_id,question_code,ordinal,question_text,question_type,is_required,specification_json) VALUES (@sv_8,N'L1-10',13,N'Roles of interest?',N'multi',1,N'{"id":"L1-10","t":"Roles of interest?","type":"multi","o":["Data analyst","Business intelligence analyst","Data scientist","Machine-learning engineer","Data engineer","Database role","Research","Other","Still exploring"],"oo":1}');

INSERT dbo.survey_questions (survey_version_id,question_code,ordinal,question_text,question_type,is_required,specification_json) VALUES (@sv_8,N'L1-11',14,N'Industries or application areas of interest?',N'long',0,N'{"id":"L1-11","t":"Industries or application areas of interest?","type":"long","o":0,"req":false}');

INSERT dbo.survey_questions (survey_version_id,question_code,ordinal,question_text,question_type,is_required,specification_json) VALUES (@sv_8,N'L1-12',15,N'What should the program help you develop?',N'multi',1,N'{"id":"L1-12","t":"What should the program help you develop?","type":"multi","o":["Mathematics/statistics","Programming","Data management","Machine learning","Realistic problem experience","Research","Portfolio","Communication","Teamwork","Professional connections","Internship opportunities","Career/job-search skills"],"max":5}');

INSERT dbo.survey_questions (survey_version_id,question_code,ordinal,question_text,question_type,is_required,specification_json) VALUES (@sv_8,N'L1-13',16,N'What would make your first year successful?',N'long',0,N'{"id":"L1-13","t":"What would make your first year successful?","type":"long","o":0,"req":false}');

INSERT dbo.survey_questions (survey_version_id,question_code,ordinal,question_text,question_type,is_required,specification_json) VALUES (@sv_8,N'L1-14',17,N'Are requirements, sequencing, or career possibilities unclear?',N'single',1,N'{"id":"L1-14","t":"Are requirements, sequencing, or career possibilities unclear?","type":"single","o":["Yes","No","Unsure"]}');

INSERT dbo.survey_questions (survey_version_id,question_code,ordinal,question_text,question_type,is_required,specification_json) VALUES (@sv_8,N'L1-14a',18,N'What needs clarification?',N'long',0,N'{"id":"L1-14a","t":"What needs clarification?","type":"long","o":0,"show":{"javascript_source":"a=>a[''L1-14'']==''Yes''"},"req":false}');

INSERT dbo.survey_questions (survey_version_id,question_code,ordinal,question_text,question_type,is_required,specification_json) VALUES (@sv_8,N'L1-15',19,N'Do you have reliable access to needed resources?',N'grid',1,N'{"id":"L1-15","t":"Do you have reliable access to needed resources?","type":"grid","o":["Yes","Sometimes","No","Unsure"],"rows":["Suitable computer","Internet","Software/computing environments","Study space","Reserved coursework time"],"sec":"D. Access and support"}');

INSERT dbo.survey_questions (survey_version_id,question_code,ordinal,question_text,question_type,is_required,specification_json) VALUES (@sv_8,N'L1-16',20,N'What circumstances should the program consider in planning?',N'multi',0,N'{"id":"L1-16","t":"What circumstances should the program consider in planning?","type":"multi","o":["Employment","Caregiving","Commuting","Scheduling","Financial constraints","Technology access","Other","Prefer not to answer","None"],"ex":["Prefer not to answer","None"],"oo":1,"req":false}');

INSERT dbo.survey_questions (survey_version_id,question_code,ordinal,question_text,question_type,is_required,specification_json) VALUES (@sv_8,N'L1-17',21,N'What support would help?',N'multi',1,N'{"id":"L1-17","t":"What support would help?","type":"multi","o":["Preparation","Course planning","Software setup","Study strategies","Peer connections","Career exploration","University resources","Other","None"],"ex":["None"],"oo":1}');

INSERT dbo.survey_questions (survey_version_id,question_code,ordinal,question_text,question_type,is_required,specification_json) VALUES (@sv_8,N'L1-18',22,N'Would you like follow-up?',N'single',1,N'{"id":"L1-18","t":"Would you like follow-up?","type":"single","o":["Yes","No"]}');

INSERT dbo.survey_questions (survey_version_id,question_code,ordinal,question_text,question_type,is_required,specification_json) VALUES (@sv_8,N'L1-18a',23,N'Topic',N'text',0,N'{"id":"L1-18a","t":"Topic","type":"text","o":0,"show":{"javascript_source":"a=>a[''L1-18'']==''Yes''"},"req":false}');

INSERT dbo.survey_versions (survey_code,version_number,variant,survey_title,form_title,introduction,audience,source_reference) VALUES (N'current_2',1,N'short',N'Current Student Surveys',N'Beginning of a Semester',N'Complete this during the first two weeks of the semester. Help us understand your plans and any support you may need. Estimated time: 3–4 minutes.',N'current',N'GitHub dev e3f3b9b5d66b33b60d08a636920165bb01b898e9 / surveys.js');

DECLARE @sv_9 INT = CONVERT(INT,SCOPE_IDENTITY());

INSERT dbo.survey_questions (survey_version_id,question_code,ordinal,question_text,question_type,is_required,specification_json) VALUES (@sv_9,N'S2-1',1,N'Which semester of the DSA MS program are you beginning?',N'single',1,N'{"id":"S2-1","t":"Which semester of the DSA MS program are you beginning?","type":"single","o":["First","Second","Third","Fourth or later"],"sec":"Semester plan"}');

INSERT dbo.survey_questions (survey_version_id,question_code,ordinal,question_text,question_type,is_required,specification_json) VALUES (@sv_9,N'S2-2',2,N'Which DSA courses are you taking this semester?',N'long',1,N'{"id":"S2-2","t":"Which DSA courses are you taking this semester?","type":"long","o":0,"note":"List each course, or enter \"Enrollment not finalized.\""}');

INSERT dbo.survey_questions (survey_version_id,question_code,ordinal,question_text,question_type,is_required,specification_json) VALUES (@sv_9,N'S2-3',3,N'Are there prerequisites or foundational skills you still need to strengthen for these courses?',N'single',1,N'{"id":"S2-3","t":"Are there prerequisites or foundational skills you still need to strengthen for these courses?","type":"single","o":["Yes","No","Unsure"]}');

INSERT dbo.survey_questions (survey_version_id,question_code,ordinal,question_text,question_type,is_required,specification_json) VALUES (@sv_9,N'S2-3a',4,N'Which areas need strengthening?',N'multi',1,N'{"id":"S2-3a","t":"Which areas need strengthening?","type":"multi","o":["Programming","Databases and SQL","Mathematics","Statistics","Data analysis","Other","I need help identifying the gaps"],"show":{"javascript_source":"a=>a[''S2-3'']!=''No''"},"oo":1}');

INSERT dbo.survey_questions (survey_version_id,question_code,ordinal,question_text,question_type,is_required,specification_json) VALUES (@sv_9,N'S2-4',5,N'What are your main goals for this semester?',N'multi',1,N'{"id":"S2-4","t":"What are your main goals for this semester?","type":"multi","o":["Strengthen foundational skills","Complete planned courses","Complete a portfolio project","Gain research experience","Explore career options","Prepare internship applications","Apply for internships","Prepare job applications","Apply for jobs","Other"],"max":3,"oo":1}');

INSERT dbo.survey_questions (survey_version_id,question_code,ordinal,question_text,question_type,is_required,specification_json) VALUES (@sv_9,N'S2-5',6,N'Approximately how much time can you usually reserve for coursework outside scheduled classes each week?',N'single',1,N'{"id":"S2-5","t":"Approximately how much time can you usually reserve for coursework outside scheduled classes each week?","type":"single","o":["Fewer than 5 hours","5–9 hours","10–14 hours","15–19 hours","20 or more hours","Unsure"]}');

INSERT dbo.survey_questions (survey_version_id,question_code,ordinal,question_text,question_type,is_required,specification_json) VALUES (@sv_9,N'S2-6',7,N'Are any commitments likely to affect your participation this semester?',N'multi',0,N'{"id":"S2-6","t":"Are any commitments likely to affect your participation this semester?","type":"multi","o":["Paid work","Caregiving or family responsibilities","Transportation or commuting","Scheduling conflicts","Reliable computer or internet access","Other commitments","Prefer not to answer","None anticipated"],"ex":["Prefer not to answer","None anticipated"],"oo":1,"req":false}');

INSERT dbo.survey_questions (survey_version_id,question_code,ordinal,question_text,question_type,is_required,specification_json) VALUES (@sv_9,N'S2-7',8,N'Has your career direction changed since your last profile update?',N'single',1,N'{"id":"S2-7","t":"Has your career direction changed since your last profile update?","type":"single","o":["Yes","No","I am still exploring"],"sec":"Goals and support"}');

INSERT dbo.survey_questions (survey_version_id,question_code,ordinal,question_text,question_type,is_required,specification_json) VALUES (@sv_9,N'S2-7a',9,N'Describe your current direction.',N'long',0,N'{"id":"S2-7a","t":"Describe your current direction.","type":"long","o":0,"show":{"javascript_source":"a=>a[''S2-7'']==''Yes''"},"req":false}');

INSERT dbo.survey_questions (survey_version_id,question_code,ordinal,question_text,question_type,is_required,specification_json) VALUES (@sv_9,N'S2-8',10,N'What support would help you accomplish your semester goals?',N'multi',1,N'{"id":"S2-8","t":"What support would help you accomplish your semester goals?","type":"multi","o":["Academic preparation or tutoring","Course or program planning","Project or research guidance","Career exploration","Resume, portfolio, or interview preparation","Internship or job-search guidance","University support referrals","Unsure","Other","None at this time"],"ex":["Unsure","None at this time"],"oo":1}');

INSERT dbo.survey_versions (survey_code,version_number,variant,survey_title,form_title,introduction,audience,source_reference) VALUES (N'current_2',1,N'long',N'Current Student Surveys',N'Beginning of a Semester',N'Complete this during the first two weeks of the semester. Update your plan, preparation needs for each course, goals, and support needs. Estimated time: 10–15 minutes for about three courses.',N'current',N'GitHub dev e3f3b9b5d66b33b60d08a636920165bb01b898e9 / surveys.js');

DECLARE @sv_10 INT = CONVERT(INT,SCOPE_IDENTITY());

INSERT dbo.survey_questions (survey_version_id,question_code,ordinal,question_text,question_type,is_required,specification_json) VALUES (@sv_10,N'L2-1',1,N'Which semester of the DSA MS program are you beginning?',N'single',1,N'{"id":"L2-1","t":"Which semester of the DSA MS program are you beginning?","type":"single","o":["First","Second","Third","Fourth or later"],"sec":"A. Semester plan"}');

INSERT dbo.survey_questions (survey_version_id,question_code,ordinal,question_text,question_type,is_required,specification_json) VALUES (@sv_10,N'L2-courses',2,N'Courses and preparation',N'repeat',1,N'{"id":"L2-courses","t":"Courses and preparation","type":"repeat","o":[{"id":"course","t":"Course","type":"text","o":0},{"id":"clarity","t":"How clear is this course’s place in your program plan?","type":"single","o":["Very unclear","Somewhat unclear","Neither","Somewhat clear","Very clear"]},{"id":"prepared","t":"How prepared are you for its expected starting knowledge?","type":"single","o":["Not at all","Slightly","Moderately","Well","Very well","Unsure what is expected"]},{"id":"review","t":"Which areas need review?","type":"multi","o":["Programming","SQL and databases","Statistics","Linear algebra or calculus","Data cleaning","Machine learning","Development tools","Technical communication","Other","Unsure","None"],"ex":["Unsure","None"],"oo":1},{"id":"clear","t":"Were expected skills and prerequisites clear before enrollment?","type":"single","o":["Yes","Partly","No","I did not review them"]},{"id":"preparation","t":"What preparation would help?","type":"multi","o":["Expected-skill list","Refreshers","Exercises","Workshop","Tutoring or study group","Instructor or adviser discussion","Other","None"],"ex":["None"],"oo":1}],"itemLabel":"Course","addLabel":"Add another course"}');

INSERT dbo.survey_questions (survey_version_id,question_code,ordinal,question_text,question_type,is_required,specification_json) VALUES (@sv_10,N'L2-4',3,N'Do you have concerns about your course sequence?',N'multi',1,N'{"id":"L2-4","t":"Do you have concerns about your course sequence?","type":"multi","o":["Needed course unavailable","Schedule conflict","Unsure what comes next","Taking a course before I am prepared","Repeated content","Elective guidance needed","Other","None"],"ex":["None"],"oo":1}');

INSERT dbo.survey_questions (survey_version_id,question_code,ordinal,question_text,question_type,is_required,specification_json) VALUES (@sv_10,N'L2-9',4,N'What are your three highest priorities this semester?',N'multi',1,N'{"id":"L2-9","t":"What are your three highest priorities this semester?","type":"multi","o":["Courses","Foundational skills","Portfolio","Research","Teamwork or communication","Career exploration","Internship preparation","Internship applications","Job preparation","Job applications","Other"],"max":3,"oo":1,"sec":"C. Goals and progress"}');

INSERT dbo.survey_questions (survey_version_id,question_code,ordinal,question_text,question_type,is_required,specification_json) VALUES (@sv_10,N'L2-10',5,N'Do you have saved goals from a previous update? ',N'single',1,N'{"id":"L2-10","t":"Do you have saved goals from a previous update? ","type":"single","o":["Yes","No"]}');

INSERT dbo.survey_questions (survey_version_id,question_code,ordinal,question_text,question_type,is_required,specification_json) VALUES (@sv_10,N'L2-goals',6,N'Progress on previous goals',N'repeat',1,N'{"id":"L2-goals","t":"Progress on previous goals","type":"repeat","o":[{"id":"goal","t":"Saved goal","type":"text","o":0},{"id":"status","t":"Status","type":"single","o":["Completed","Partly completed","In progress","Not started","No longer relevant"]},{"id":"context","t":"What helped or prevented progress?","type":"long","o":0,"req":false}],"show":{"javascript_source":"a=>a[''L2-10'']==''Yes''"},"itemLabel":"Goal","addLabel":"Add another goal"}');

INSERT dbo.survey_questions (survey_version_id,question_code,ordinal,question_text,question_type,is_required,specification_json) VALUES (@sv_10,N'L2-11',7,N'Are you planning an applied experience this semester?',N'single',1,N'{"id":"L2-11","t":"Are you planning an applied experience this semester?","type":"single","o":["Yes","No","Exploring"]}');

INSERT dbo.survey_questions (survey_version_id,question_code,ordinal,question_text,question_type,is_required,specification_json) VALUES (@sv_10,N'L2-11a',8,N'Describe the activity, desired skills, and any help needed finding or defining it.',N'long',0,N'{"id":"L2-11a","t":"Describe the activity, desired skills, and any help needed finding or defining it.","type":"long","o":0,"show":{"javascript_source":"a=>a[''L2-11'']!=''No''"},"req":false}');

INSERT dbo.survey_questions (survey_version_id,question_code,ordinal,question_text,question_type,is_required,specification_json) VALUES (@sv_10,N'L2-12',9,N'Has your career direction changed?',N'single',1,N'{"id":"L2-12","t":"Has your career direction changed?","type":"single","o":["Yes","No","Still exploring"]}');

INSERT dbo.survey_questions (survey_version_id,question_code,ordinal,question_text,question_type,is_required,specification_json) VALUES (@sv_10,N'L2-12a',10,N'Describe your updated roles or industries of interest.',N'long',0,N'{"id":"L2-12a","t":"Describe your updated roles or industries of interest.","type":"long","o":0,"show":{"javascript_source":"a=>a[''L2-12'']==''Yes''"},"req":false}');

INSERT dbo.survey_questions (survey_version_id,question_code,ordinal,question_text,question_type,is_required,specification_json) VALUES (@sv_10,N'L2-13',11,N'How many hours per week can you reserve for coursework outside class?',N'single',1,N'{"id":"L2-13","t":"How many hours per week can you reserve for coursework outside class?","type":"single","o":["Fewer than 5","5–9","10–14","15–19","20–24","25 or more","Unsure"],"sec":"D. Time and support"}');

INSERT dbo.survey_questions (survey_version_id,question_code,ordinal,question_text,question_type,is_required,specification_json) VALUES (@sv_10,N'L2-14',12,N'Which circumstances may affect your plans?',N'multi',0,N'{"id":"L2-14","t":"Which circumstances may affect your plans?","type":"multi","o":["Employment","Caregiving","Commuting","Scheduling","Technology","Finances","Other","Prefer not to answer","None"],"ex":["Prefer not to answer","None"],"oo":1,"req":false}');

INSERT dbo.survey_questions (survey_version_id,question_code,ordinal,question_text,question_type,is_required,specification_json) VALUES (@sv_10,N'L2-15',13,N'Do you have the required software, equipment, and access?',N'single',1,N'{"id":"L2-15","t":"Do you have the required software, equipment, and access?","type":"single","o":["Yes","Partly","No","Unsure"]}');

INSERT dbo.survey_questions (survey_version_id,question_code,ordinal,question_text,question_type,is_required,specification_json) VALUES (@sv_10,N'L2-15a',14,N'What is missing?',N'long',0,N'{"id":"L2-15a","t":"What is missing?","type":"long","o":0,"show":{"javascript_source":"a=>[''Partly'',''No'',''Unsure''].includes(a[''L2-15''])"},"req":false}');

INSERT dbo.survey_questions (survey_version_id,question_code,ordinal,question_text,question_type,is_required,specification_json) VALUES (@sv_10,N'L2-16',15,N'What support would be useful?',N'multi',1,N'{"id":"L2-16","t":"What support would be useful?","type":"multi","o":["Preparation or tutoring","Course planning","Projects or research","Career planning","Portfolio","Internship or job search","Study strategies","Referrals","Other","None"],"ex":["None"],"oo":1}');

INSERT dbo.survey_questions (survey_version_id,question_code,ordinal,question_text,question_type,is_required,specification_json) VALUES (@sv_10,N'L2-17',16,N'What decision or concern should an adviser address early?',N'long',0,N'{"id":"L2-17","t":"What decision or concern should an adviser address early?","type":"long","o":0,"req":false}');

INSERT dbo.survey_questions (survey_version_id,question_code,ordinal,question_text,question_type,is_required,specification_json) VALUES (@sv_10,N'L2-18',17,N'Would you like follow-up?',N'single',1,N'{"id":"L2-18","t":"Would you like follow-up?","type":"single","o":["Yes","No"]}');

INSERT dbo.survey_questions (survey_version_id,question_code,ordinal,question_text,question_type,is_required,specification_json) VALUES (@sv_10,N'L2-18a',18,N'What would you like help with?',N'long',0,N'{"id":"L2-18a","t":"What would you like help with?","type":"long","o":0,"show":{"javascript_source":"a=>a[''L2-18'']==''Yes''"},"req":false}');

INSERT dbo.survey_versions (survey_code,version_number,variant,survey_title,form_title,introduction,audience,source_reference) VALUES (N'current_3',1,N'short',N'Current Student Surveys',N'Advising Milestone',N'Tell your adviser what you would like to address so the discussion can focus on your priorities. Estimated time: about 3 minutes.',N'current',N'GitHub dev e3f3b9b5d66b33b60d08a636920165bb01b898e9 / surveys.js');

DECLARE @sv_11 INT = CONVERT(INT,SCOPE_IDENTITY());

INSERT dbo.survey_questions (survey_version_id,question_code,ordinal,question_text,question_type,is_required,specification_json) VALUES (@sv_11,N'S3-1',1,N'What is the main reason for this advising update?',N'single',1,N'{"id":"S3-1","t":"What is the main reason for this advising update?","type":"single","o":["Routine academic planning","Choosing or changing courses","Reviewing prerequisites","Difficulty in a course","Project or research planning","Career direction","Considering an enrollment change","Follow-up on earlier advising","Other"],"sec":"Advising priorities"}');

INSERT dbo.survey_questions (survey_version_id,question_code,ordinal,question_text,question_type,is_required,specification_json) VALUES (@sv_11,N'S3-2',2,N'Which topics would you like to discuss?',N'multi',1,N'{"id":"S3-2","t":"Which topics would you like to discuss?","type":"multi","o":["Course selection or sequencing","Academic progress","Foundational skill gaps","Study strategies or academic resources","Project or research opportunities","Internship or career preparation","Commitments affecting study","University support resources","Other"],"oo":1}');

INSERT dbo.survey_questions (survey_version_id,question_code,ordinal,question_text,question_type,is_required,specification_json) VALUES (@sv_11,N'S3-3',3,N'Is anything preventing you from following your current academic plan?',N'single',1,N'{"id":"S3-3","t":"Is anything preventing you from following your current academic plan?","type":"single","o":["Yes","No","Unsure"]}');

INSERT dbo.survey_questions (survey_version_id,question_code,ordinal,question_text,question_type,is_required,specification_json) VALUES (@sv_11,N'S3-3a',4,N'Describe the issue, sharing only what you are comfortable providing.',N'long',0,N'{"id":"S3-3a","t":"Describe the issue, sharing only what you are comfortable providing.","type":"long","o":0,"show":{"javascript_source":"a=>a[''S3-3'']!=''No''"},"req":false}');

INSERT dbo.survey_questions (survey_version_id,question_code,ordinal,question_text,question_type,is_required,specification_json) VALUES (@sv_11,N'S3-4',5,N'If you previously agreed on action items with an adviser, what is their status?',N'single',1,N'{"id":"S3-4","t":"If you previously agreed on action items with an adviser, what is their status?","type":"single","o":["All completed","Some completed","In progress","Not started","Need clarification","No previous action items"]}');

INSERT dbo.survey_questions (survey_version_id,question_code,ordinal,question_text,question_type,is_required,specification_json) VALUES (@sv_11,N'S3-4a',6,N'Which item needs discussion or support?',N'long',0,N'{"id":"S3-4a","t":"Which item needs discussion or support?","type":"long","o":0,"show":{"javascript_source":"a=>![''All completed'',''No previous action items''].includes(a[''S3-4''])"},"req":false}');

INSERT dbo.survey_questions (survey_version_id,question_code,ordinal,question_text,question_type,is_required,specification_json) VALUES (@sv_11,N'S3-5',7,N'What decision or outcome would make this advising discussion useful to you?',N'long',0,N'{"id":"S3-5","t":"What decision or outcome would make this advising discussion useful to you?","type":"long","o":0,"req":false}');

INSERT dbo.survey_questions (survey_version_id,question_code,ordinal,question_text,question_type,is_required,specification_json) VALUES (@sv_11,N'S3-6',8,N'When would you like a response or meeting?',N'single',1,N'{"id":"S3-6","t":"When would you like a response or meeting?","type":"single","o":["Within the next few business days","Within the next two weeks","At my next scheduled advising meeting","No additional meeting requested"]}');

INSERT dbo.survey_questions (survey_version_id,question_code,ordinal,question_text,question_type,is_required,specification_json) VALUES (@sv_11,N'S3-7',9,N'Is there anything else your adviser should know beforehand?',N'long',0,N'{"id":"S3-7","t":"Is there anything else your adviser should know beforehand?","type":"long","o":0,"req":false}');

INSERT dbo.survey_versions (survey_code,version_number,variant,survey_title,form_title,introduction,audience,source_reference) VALUES (N'current_3',1,N'long',N'Current Student Surveys',N'Advising Milestone',N'Prepare for an advising discussion and review earlier actions. Share only personal context you are comfortable providing. Estimated time: 8–12 minutes before the meeting. Use the separate Advising Follow-up afterward.',N'current',N'GitHub dev e3f3b9b5d66b33b60d08a636920165bb01b898e9 / surveys.js');

DECLARE @sv_12 INT = CONVERT(INT,SCOPE_IDENTITY());

INSERT dbo.survey_questions (survey_version_id,question_code,ordinal,question_text,question_type,is_required,specification_json) VALUES (@sv_12,N'L3-1',1,N'What prompted this update?',N'multi',1,N'{"id":"L3-1","t":"What prompted this update?","type":"multi","o":["Academic planning","Course selection","Prerequisites","Course difficulty","Project or research","Career planning","Internship planning","Enrollment change","Earlier-discussion follow-up","Other"],"sec":"A. Before the discussion","oo":1}');

INSERT dbo.survey_questions (survey_version_id,question_code,ordinal,question_text,question_type,is_required,specification_json) VALUES (@sv_12,N'L3-2',2,N'What is your most important priority?',N'long',0,N'{"id":"L3-2","t":"What is your most important priority?","type":"long","o":0,"req":false}');

INSERT dbo.survey_questions (survey_version_id,question_code,ordinal,question_text,question_type,is_required,specification_json) VALUES (@sv_12,N'L3-3',3,N'Which decisions need help?',N'multi',1,N'{"id":"L3-3","t":"Which decisions need help?","type":"multi","o":["Courses or electives","Course load","Preparation gaps","Academic progress","Project or research direction","Career connections","Internship fit","Continuing, pausing, or changing enrollment","Other","None"],"ex":["None"],"oo":1}');

INSERT dbo.survey_questions (survey_version_id,question_code,ordinal,question_text,question_type,is_required,specification_json) VALUES (@sv_12,N'L3-4',4,N'Is your academic plan achievable now?',N'single',1,N'{"id":"L3-4","t":"Is your academic plan achievable now?","type":"single","o":["Yes","Partly","No","Unsure"]}');

INSERT dbo.survey_questions (survey_version_id,question_code,ordinal,question_text,question_type,is_required,specification_json) VALUES (@sv_12,N'L3-4a',5,N'What needs adjustment?',N'long',0,N'{"id":"L3-4a","t":"What needs adjustment?","type":"long","o":0,"show":{"javascript_source":"a=>a[''L3-4'']!=''Yes''"},"req":false}');

INSERT dbo.survey_questions (survey_version_id,question_code,ordinal,question_text,question_type,is_required,specification_json) VALUES (@sv_12,N'L3-5',6,N'What barriers are affecting progress?',N'multi',1,N'{"id":"L3-5","t":"What barriers are affecting progress?","type":"multi","o":["Foundational skills","Course material","Unclear requirements","Availability or sequencing","Time","Technology","Opportunity access","Personal circumstances to discuss privately","Other","None"],"ex":["None"],"oo":1}');

INSERT dbo.survey_questions (survey_version_id,question_code,ordinal,question_text,question_type,is_required,specification_json) VALUES (@sv_12,N'L3-6',7,N'Which resources have you already tried?',N'multi',1,N'{"id":"L3-6","t":"Which resources have you already tried?","type":"multi","o":["Instructor office hours","Adviser","Tutoring","Study group","Tutorials or practice","Career services","University services","Other","None"],"ex":["None"],"oo":1}');

INSERT dbo.survey_questions (survey_version_id,question_code,ordinal,question_text,question_type,is_required,specification_json) VALUES (@sv_12,N'L3-6a',8,N'What helped and what remains unresolved?',N'long',0,N'{"id":"L3-6a","t":"What helped and what remains unresolved?","type":"long","o":0,"req":false}');

INSERT dbo.survey_questions (survey_version_id,question_code,ordinal,question_text,question_type,is_required,specification_json) VALUES (@sv_12,N'L3-7',9,N'Were action items agreed previously?',N'single',1,N'{"id":"L3-7","t":"Were action items agreed previously?","type":"single","o":["Yes","No","Unsure","No previous discussion"],"sec":"B. Earlier actions"}');

INSERT dbo.survey_questions (survey_version_id,question_code,ordinal,question_text,question_type,is_required,specification_json) VALUES (@sv_12,N'L3-actions',10,N'Earlier action-item status',N'repeat',1,N'{"id":"L3-actions","t":"Earlier action-item status","type":"repeat","o":[{"id":"action","t":"Earlier action item","type":"text","o":0},{"id":"status","t":"Status","type":"single","o":["Completed","In progress","Not started","No longer applicable"]},{"id":"clarity","t":"Was the action clear?","type":"single","o":["Yes","Partly","No"]},{"id":"obstacle","t":"What obstacle affected this action?","type":"long","o":0,"req":false},{"id":"help","t":"Is further help needed?","type":"single","o":["Yes","No","Unsure"]}],"show":{"javascript_source":"a=>a[''L3-7'']==''Yes''"},"itemLabel":"Action item","addLabel":"Add another action item"}');

INSERT dbo.survey_questions (survey_version_id,question_code,ordinal,question_text,question_type,is_required,specification_json) VALUES (@sv_12,N'L3-8',11,N'Did previous advising help you move forward?',N'single',1,N'{"id":"L3-8","t":"Did previous advising help you move forward?","type":"single","o":["Not at all","A little","Somewhat","Quite a bit","A great deal","Not applicable"]}');

INSERT dbo.survey_questions (survey_version_id,question_code,ordinal,question_text,question_type,is_required,specification_json) VALUES (@sv_12,N'L3-8a',12,N'What was useful or missing?',N'long',0,N'{"id":"L3-8a","t":"What was useful or missing?","type":"long","o":0,"req":false}');

INSERT dbo.survey_questions (survey_version_id,question_code,ordinal,question_text,question_type,is_required,specification_json) VALUES (@sv_12,N'L3-9',13,N'What would make this discussion successful?',N'multi',1,N'{"id":"L3-9","t":"What would make this discussion successful?","type":"multi","o":["Course plan","Skill-development plan","Referral","Project or research step","Career direction","Barrier-resolution plan","Requirements clarification","Other"],"sec":"C. Desired outcome","oo":1}');

INSERT dbo.survey_questions (survey_version_id,question_code,ordinal,question_text,question_type,is_required,specification_json) VALUES (@sv_12,N'L3-10',14,N'When would you like a response?',N'single',1,N'{"id":"L3-10","t":"When would you like a response?","type":"single","o":["Within a few business days","Within two weeks","At the next scheduled meeting","No extra meeting"]}');

INSERT dbo.survey_questions (survey_version_id,question_code,ordinal,question_text,question_type,is_required,specification_json) VALUES (@sv_12,N'L3-11',15,N'Is there anything else your adviser should know?',N'long',0,N'{"id":"L3-11","t":"Is there anything else your adviser should know?","type":"long","o":0,"req":false}');

INSERT dbo.survey_versions (survey_code,version_number,variant,survey_title,form_title,introduction,audience,source_reference) VALUES (N'current_4',1,N'single',N'Current Student Surveys',N'Advising Follow-up',N'Complete this short follow-up after an advising discussion. Estimated time: 3–5 minutes.',N'current',N'GitHub dev e3f3b9b5d66b33b60d08a636920165bb01b898e9 / surveys.js');

DECLARE @sv_13 INT = CONVERT(INT,SCOPE_IDENTITY());

INSERT dbo.survey_questions (survey_version_id,question_code,ordinal,question_text,question_type,is_required,specification_json) VALUES (@sv_13,N'L3-12',1,N'Were your main questions addressed?',N'single',1,N'{"id":"L3-12","t":"Were your main questions addressed?","type":"single","o":["Fully","Mostly","Partly","Not at all"],"sec":"After the discussion"}');

INSERT dbo.survey_questions (survey_version_id,question_code,ordinal,question_text,question_type,is_required,specification_json) VALUES (@sv_13,N'L3-13',2,N'How clear are your next steps?',N'single',1,N'{"id":"L3-13","t":"How clear are your next steps?","type":"single","o":["Very unclear","Somewhat unclear","Neither","Somewhat clear","Very clear"]}');

INSERT dbo.survey_questions (survey_version_id,question_code,ordinal,question_text,question_type,is_required,specification_json) VALUES (@sv_13,N'L3-14',3,N'Were the next steps realistic?',N'single',1,N'{"id":"L3-14","t":"Were the next steps realistic?","type":"single","o":["Yes","Partly","No","No actions agreed"]}');

INSERT dbo.survey_questions (survey_version_id,question_code,ordinal,question_text,question_type,is_required,specification_json) VALUES (@sv_13,N'L3-15',4,N'Is anything unresolved?',N'single',1,N'{"id":"L3-15","t":"Is anything unresolved?","type":"single","o":["Yes","No"]}');

INSERT dbo.survey_questions (survey_version_id,question_code,ordinal,question_text,question_type,is_required,specification_json) VALUES (@sv_13,N'L3-15a',5,N'Describe what remains unresolved.',N'long',0,N'{"id":"L3-15a","t":"Describe what remains unresolved.","type":"long","o":0,"show":{"javascript_source":"a=>a[''L3-15'']==''Yes''"},"req":false}');

INSERT dbo.survey_questions (survey_version_id,question_code,ordinal,question_text,question_type,is_required,specification_json) VALUES (@sv_13,N'L3-16',6,N'What could improve advising?',N'multi',1,N'{"id":"L3-16","t":"What could improve advising?","type":"multi","o":["Scheduling","Pre-meeting information","Continuity","Course guidance","Career guidance","Clear actions","Follow-up","Referrals","Other","No change needed"],"ex":["No change needed"],"oo":1}');

INSERT dbo.survey_versions (survey_code,version_number,variant,survey_title,form_title,introduction,audience,source_reference) VALUES (N'current_5',1,N'short',N'Current Student Surveys',N'Internship or Job-Search Milestone',N'Complete this when beginning a search, applying, interviewing, receiving an offer, or starting an opportunity. Update your career progress so the program can offer relevant support. Estimated time: 3–4 minutes.',N'current',N'GitHub dev e3f3b9b5d66b33b60d08a636920165bb01b898e9 / surveys.js');

DECLARE @sv_14 INT = CONVERT(INT,SCOPE_IDENTITY());

INSERT dbo.survey_questions (survey_version_id,question_code,ordinal,question_text,question_type,is_required,specification_json) VALUES (@sv_14,N'S4-1',1,N'What are you currently pursuing?',N'single',1,N'{"id":"S4-1","t":"What are you currently pursuing?","type":"single","o":["Internship","Full-time job","Part-time job involving data skills","Multiple opportunity types","Career exploration","Not currently pursuing an opportunity"],"sec":"Career progress"}');

INSERT dbo.survey_questions (survey_version_id,question_code,ordinal,question_text,question_type,is_required,specification_json) VALUES (@sv_14,N'S4-2',2,N'Which stage best describes your current progress?',N'single',1,N'{"id":"S4-2","t":"Which stage best describes your current progress?","type":"single","o":["Exploring roles or industries","Preparing applications","Identifying opportunities","Submitting applications","Interviewing or completing assessments","Considering an offer","Accepted but not started","Started an internship or job","Paused the search"],"show":{"javascript_source":"a=>a[''S4-1'']!=''Not currently pursuing an opportunity''"}}');

INSERT dbo.survey_questions (survey_version_id,question_code,ordinal,question_text,question_type,is_required,specification_json) VALUES (@sv_14,N'S4-3',3,N'Which roles or industries are you targeting?',N'long',0,N'{"id":"S4-3","t":"Which roles or industries are you targeting?","type":"long","o":0,"show":{"javascript_source":"a=>a[''S4-1'']!=''Not currently pursuing an opportunity''"},"req":false}');

INSERT dbo.survey_questions (survey_version_id,question_code,ordinal,question_text,question_type,is_required,specification_json) VALUES (@sv_14,N'S4-4',4,N'When do you hope to begin?',N'single',1,N'{"id":"S4-4","t":"When do you hope to begin?","type":"single","o":["Within three months","In three to six months","More than six months","Already started","Unsure"],"show":{"javascript_source":"a=>a[''S4-1'']!=''Not currently pursuing an opportunity''"}}');

INSERT dbo.survey_questions (survey_version_id,question_code,ordinal,question_text,question_type,is_required,specification_json) VALUES (@sv_14,N'S4-5',5,N'Which steps have you completed since your last career update or since beginning this search?',N'multi',1,N'{"id":"S4-5","t":"Which steps have you completed since your last career update or since beginning this search?","type":"multi","o":["Updated resume","Updated portfolio","Sought advice or attended a career event","Contacted employers or professional connections","Submitted applications","Completed interviews or assessments","Received an offer","Accepted an offer","Started the opportunity","No steps yet"],"ex":["No steps yet"],"show":{"javascript_source":"a=>a[''S4-1'']!=''Not currently pursuing an opportunity''"}}');

INSERT dbo.survey_questions (survey_version_id,question_code,ordinal,question_text,question_type,is_required,specification_json) VALUES (@sv_14,N'S4-6',6,N'What is making progress difficult?',N'multi',1,N'{"id":"S4-6","t":"What is making progress difficult?","type":"multi","o":["Unclear direction","Finding suitable opportunities","Limited experience or portfolio","Application preparation","Interview or assessment preparation","Limited connections","Time constraints","Location or work arrangement","Eligibility requirements","Unsure","Other","No current difficulty"],"ex":["Unsure","No current difficulty"],"show":{"javascript_source":"a=>a[''S4-1'']!=''Not currently pursuing an opportunity''"},"oo":1}');

INSERT dbo.survey_questions (survey_version_id,question_code,ordinal,question_text,question_type,is_required,specification_json) VALUES (@sv_14,N'S4-7',7,N'What career support would be useful now?',N'multi',1,N'{"id":"S4-7","t":"What career support would be useful now?","type":"multi","o":["Identifying roles or employers","Opportunity listings","Resume review","Portfolio review","Interview or assessment practice","Networking guidance","Discussing an offer","Fitting an internship with coursework","Unsure","Other","None"],"ex":["Unsure","None"],"oo":1}');

INSERT dbo.survey_questions (survey_version_id,question_code,ordinal,question_text,question_type,is_required,specification_json) VALUES (@sv_14,N'S4-8',8,N'Would you like faculty or adviser follow-up about your career plans?',N'single',1,N'{"id":"S4-8","t":"Would you like faculty or adviser follow-up about your career plans?","type":"single","o":["Yes","No"]}');

INSERT dbo.survey_questions (survey_version_id,question_code,ordinal,question_text,question_type,is_required,specification_json) VALUES (@sv_14,N'S4-8a',9,N'What would you most like help with?',N'long',0,N'{"id":"S4-8a","t":"What would you most like help with?","type":"long","o":0,"show":{"javascript_source":"a=>a[''S4-8'']==''Yes''"},"req":false}');

INSERT dbo.survey_versions (survey_code,version_number,variant,survey_title,form_title,introduction,audience,source_reference) VALUES (N'current_5',1,N'long',N'Current Student Surveys',N'Internship or Job-Search Milestone',N'Complete this when beginning a search, applying, interviewing, receiving an offer, or starting an opportunity. Describe your career activity, employer requirements, obstacles, and support needs. Students not currently pursuing an opportunity receive a shorter path. Estimated time: 10–15 minutes.',N'current',N'GitHub dev e3f3b9b5d66b33b60d08a636920165bb01b898e9 / surveys.js');

DECLARE @sv_15 INT = CONVERT(INT,SCOPE_IDENTITY());

INSERT dbo.survey_questions (survey_version_id,question_code,ordinal,question_text,question_type,is_required,specification_json) VALUES (@sv_15,N'L4-1',1,N'What are you currently pursuing?',N'single',1,N'{"id":"L4-1","t":"What are you currently pursuing?","type":"single","o":["Internship","Full-time job","Part-time data work","Multiple opportunity types","Career exploration","Not currently pursuing an opportunity"],"sec":"A. Goals and stage"}');

INSERT dbo.survey_questions (survey_version_id,question_code,ordinal,question_text,question_type,is_required,specification_json) VALUES (@sv_15,N'L4-2',2,N'Which stage best describes your current progress?',N'single',1,N'{"id":"L4-2","t":"Which stage best describes your current progress?","type":"single","o":["Exploring","Preparing materials","Identifying openings","Applying","Interviews or assessments","Considering an offer","Accepted but not started","Started","Paused"],"show":{"javascript_source":"a=>a[''L4-1'']!=''Not currently pursuing an opportunity''"}}');

INSERT dbo.survey_questions (survey_version_id,question_code,ordinal,question_text,question_type,is_required,specification_json) VALUES (@sv_15,N'L4-3a',3,N'Which roles are you targeting?',N'text',0,N'{"id":"L4-3a","t":"Which roles are you targeting?","type":"text","o":0,"show":{"javascript_source":"a=>a[''L4-1'']!=''Not currently pursuing an opportunity''"},"req":false}');

INSERT dbo.survey_questions (survey_version_id,question_code,ordinal,question_text,question_type,is_required,specification_json) VALUES (@sv_15,N'L4-3b',4,N'Which industries are you targeting?',N'text',0,N'{"id":"L4-3b","t":"Which industries are you targeting?","type":"text","o":0,"show":{"javascript_source":"a=>a[''L4-1'']!=''Not currently pursuing an opportunity''"},"req":false}');

INSERT dbo.survey_questions (survey_version_id,question_code,ordinal,question_text,question_type,is_required,specification_json) VALUES (@sv_15,N'L4-4',5,N'When do you hope to begin?',N'single',1,N'{"id":"L4-4","t":"When do you hope to begin?","type":"single","o":["Within three months","Three to six months","More than six months","Already started","Unsure"],"show":{"javascript_source":"a=>a[''L4-1'']!=''Not currently pursuing an opportunity''"}}');

INSERT dbo.survey_questions (survey_version_id,question_code,ordinal,question_text,question_type,is_required,specification_json) VALUES (@sv_15,N'L4-5',6,N'Which requirements affect the opportunities you can pursue?',N'multi',0,N'{"id":"L4-5","t":"Which requirements affect the opportunities you can pursue?","type":"multi","o":["Location","Work arrangement","Schedule","Compensation","Duration","Eligibility","Coursework compatibility","Other","Prefer not to answer","None"],"ex":["Prefer not to answer","None"],"show":{"javascript_source":"a=>a[''L4-1'']!=''Not currently pursuing an opportunity''"},"oo":1,"req":false}');

INSERT dbo.survey_questions (survey_version_id,question_code,ordinal,question_text,question_type,is_required,specification_json) VALUES (@sv_15,N'L4-6',7,N'How many applications have you submitted in the past 30 days?',N'single',1,N'{"id":"L4-6","t":"How many applications have you submitted in the past 30 days?","type":"single","o":["0","1–5","6–10","11–20","More than 20","Unsure"],"sec":"B. Past 30 days","show":{"javascript_source":"a=>a[''L4-1'']!=''Not currently pursuing an opportunity''"}}');

INSERT dbo.survey_questions (survey_version_id,question_code,ordinal,question_text,question_type,is_required,specification_json) VALUES (@sv_15,N'L4-7',8,N'How many employers have interviewed you or given you an assessment in the past 30 days?',N'single',1,N'{"id":"L4-7","t":"How many employers have interviewed you or given you an assessment in the past 30 days?","type":"single","o":["0","1–2","3–5","More than 5","Unsure"],"show":{"javascript_source":"a=>a[''L4-1'']!=''Not currently pursuing an opportunity''"}}');

INSERT dbo.survey_questions (survey_version_id,question_code,ordinal,question_text,question_type,is_required,specification_json) VALUES (@sv_15,N'L4-8',9,N'How many offers have you received?',N'single',1,N'{"id":"L4-8","t":"How many offers have you received?","type":"single","o":["0","1","2 or more","Prefer not to answer"],"show":{"javascript_source":"a=>a[''L4-1'']!=''Not currently pursuing an opportunity''"}}');

INSERT dbo.survey_questions (survey_version_id,question_code,ordinal,question_text,question_type,is_required,specification_json) VALUES (@sv_15,N'L4-9',10,N'Which sources have produced useful opportunities or contacts?',N'multi',1,N'{"id":"L4-9","t":"Which sources have produced useful opportunities or contacts?","type":"multi","o":["Faculty or staff","Career services","Classmates or alumni","Events","Networking","Job boards","Employer websites","Prior employers","Other","None yet"],"ex":["None yet"],"show":{"javascript_source":"a=>a[''L4-1'']!=''Not currently pursuing an opportunity''"},"oo":1}');

INSERT dbo.survey_questions (survey_version_id,question_code,ordinal,question_text,question_type,is_required,specification_json) VALUES (@sv_15,N'L4-10',11,N'Which skills have employers requested?',N'multi',1,N'{"id":"L4-10","t":"Which skills have employers requested?","type":"multi","o":["Python","SQL","Statistics","Machine learning","Data cleaning","Visualization or BI","Engineering or cloud","Software practices","Communication","Teamwork","Domain knowledge","Other","Not reached this stage"],"sec":"C. Skills and obstacles","ex":["Not reached this stage"],"show":{"javascript_source":"a=>a[''L4-1'']!=''Not currently pursuing an opportunity''"},"oo":1}');

INSERT dbo.survey_questions (survey_version_id,question_code,ordinal,question_text,question_type,is_required,specification_json) VALUES (@sv_15,N'L4-11',12,N'How well has coursework prepared you for requirements you encountered?',N'single',1,N'{"id":"L4-11","t":"How well has coursework prepared you for requirements you encountered?","type":"single","o":["Not at all","Slightly","Moderately","Well","Very well","Insufficient experience"],"show":{"javascript_source":"a=>a[''L4-1'']!=''Not currently pursuing an opportunity''"}}');

INSERT dbo.survey_questions (survey_version_id,question_code,ordinal,question_text,question_type,is_required,specification_json) VALUES (@sv_15,N'L4-11a',13,N'Describe one preparation strength and one gap.',N'long',0,N'{"id":"L4-11a","t":"Describe one preparation strength and one gap.","type":"long","o":0,"show":{"javascript_source":"a=>a[''L4-1'']!=''Not currently pursuing an opportunity''"},"req":false}');

INSERT dbo.survey_questions (survey_version_id,question_code,ordinal,question_text,question_type,is_required,specification_json) VALUES (@sv_15,N'L4-12',14,N'Which course, project, or assignment has been most useful, and why?',N'long',0,N'{"id":"L4-12","t":"Which course, project, or assignment has been most useful, and why?","type":"long","o":0,"show":{"javascript_source":"a=>a[''L4-1'']!=''Not currently pursuing an opportunity''"},"req":false}');

INSERT dbo.survey_questions (survey_version_id,question_code,ordinal,question_text,question_type,is_required,specification_json) VALUES (@sv_15,N'L4-13',15,N'What obstacles are affecting your progress?',N'multi',1,N'{"id":"L4-13","t":"What obstacles are affecting your progress?","type":"multi","o":["Unclear direction","Finding openings","Limited experience","Portfolio","Applications","Assessments","Interviews","Connections","Time","Location or work arrangement","Eligibility","Little feedback","Other","None"],"ex":["None"],"show":{"javascript_source":"a=>a[''L4-1'']!=''Not currently pursuing an opportunity''"},"oo":1}');

INSERT dbo.survey_questions (survey_version_id,question_code,ordinal,question_text,question_type,is_required,specification_json) VALUES (@sv_15,N'L4-14',16,N'What employer feedback could improve preparation?',N'long',0,N'{"id":"L4-14","t":"What employer feedback could improve preparation?","type":"long","o":0,"show":{"javascript_source":"a=>a[''L4-1'']!=''Not currently pursuing an opportunity''"},"note":"Do not name interviewers or share confidential assessment content.","req":false}');

INSERT dbo.survey_questions (survey_version_id,question_code,ordinal,question_text,question_type,is_required,specification_json) VALUES (@sv_15,N'L4-15',17,N'What career support would be useful now?',N'multi',1,N'{"id":"L4-15","t":"What career support would be useful now?","type":"multi","o":["Career direction","Opportunity listings","Resume review","Portfolio review","Interview practice","Assessment practice","Networking guidance","Discussing an offer","Internship and coursework planning","Other","None"],"sec":"D. Support","ex":["None"],"oo":1}');

INSERT dbo.survey_questions (survey_version_id,question_code,ordinal,question_text,question_type,is_required,specification_json) VALUES (@sv_15,N'L4-16',18,N'What is your next planned career step?',N'long',0,N'{"id":"L4-16","t":"What is your next planned career step?","type":"long","o":0,"req":false}');

INSERT dbo.survey_questions (survey_version_id,question_code,ordinal,question_text,question_type,is_required,specification_json) VALUES (@sv_15,N'L4-17',19,N'Would you like faculty or adviser follow-up?',N'single',1,N'{"id":"L4-17","t":"Would you like faculty or adviser follow-up?","type":"single","o":["Yes","No"]}');

INSERT dbo.survey_questions (survey_version_id,question_code,ordinal,question_text,question_type,is_required,specification_json) VALUES (@sv_15,N'L4-18',20,N'What type of opportunity did you accept or start?',N'single',1,N'{"id":"L4-18","t":"What type of opportunity did you accept or start?","type":"single","o":["Internship","Full-time","Part-time","Other"],"sec":"E. Accepted or started opportunity","show":{"javascript_source":"a=>[''Accepted but not started'',''Started''].includes(a[''L4-2''])"}}');

INSERT dbo.survey_questions (survey_version_id,question_code,ordinal,question_text,question_type,is_required,specification_json) VALUES (@sv_15,N'L4-19a',21,N'What is the general role title?',N'text',0,N'{"id":"L4-19a","t":"What is the general role title?","type":"text","o":0,"show":{"javascript_source":"a=>[''Accepted but not started'',''Started''].includes(a[''L4-2''])"},"note":"Employer name is not required.","req":false}');

INSERT dbo.survey_questions (survey_version_id,question_code,ordinal,question_text,question_type,is_required,specification_json) VALUES (@sv_15,N'L4-19b',22,N'What industry is the opportunity in?',N'text',0,N'{"id":"L4-19b","t":"What industry is the opportunity in?","type":"text","o":0,"show":{"javascript_source":"a=>[''Accepted but not started'',''Started''].includes(a[''L4-2''])"},"req":false}');

INSERT dbo.survey_questions (survey_version_id,question_code,ordinal,question_text,question_type,is_required,specification_json) VALUES (@sv_15,N'L4-20',23,N'How closely does the opportunity relate to DSA learning or goals?',N'single',1,N'{"id":"L4-20","t":"How closely does the opportunity relate to DSA learning or goals?","type":"single","o":["Not at all","Slightly","Moderately","Closely","Very closely","Unsure"],"show":{"javascript_source":"a=>[''Accepted but not started'',''Started''].includes(a[''L4-2''])"}}');

INSERT dbo.survey_questions (survey_version_id,question_code,ordinal,question_text,question_type,is_required,specification_json) VALUES (@sv_15,N'L4-21',24,N'If you started, which skills have you used?',N'multi',1,N'{"id":"L4-21","t":"If you started, which skills have you used?","type":"multi","o":["Python","SQL","Statistics","Machine learning","Data cleaning","Visualization or BI","Engineering or cloud","Software practices","Communication","Teamwork","Domain knowledge","Other","Not started","None yet"],"ex":["Not started","None yet"],"show":{"javascript_source":"a=>[''Accepted but not started'',''Started''].includes(a[''L4-2''])"},"oo":1}');

INSERT dbo.survey_questions (survey_version_id,question_code,ordinal,question_text,question_type,is_required,specification_json) VALUES (@sv_15,N'L4-22',25,N'What would have made you better prepared?',N'long',0,N'{"id":"L4-22","t":"What would have made you better prepared?","type":"long","o":0,"show":{"javascript_source":"a=>[''Accepted but not started'',''Started''].includes(a[''L4-2''])"},"req":false}');

INSERT dbo.survey_questions (survey_version_id,question_code,ordinal,question_text,question_type,is_required,specification_json) VALUES (@sv_15,N'L4-23',26,N'How could the department support similar opportunities?',N'long',0,N'{"id":"L4-23","t":"How could the department support similar opportunities?","type":"long","o":0,"show":{"javascript_source":"a=>[''Accepted but not started'',''Started''].includes(a[''L4-2''])"},"req":false}');

INSERT dbo.survey_versions (survey_code,version_number,variant,survey_title,form_title,introduction,audience,source_reference) VALUES (N'current_6',1,N'short',N'Current Student Surveys',N'End-of-Semester Feedback',N'Complete this after coursework, ideally after final grades are posted. Review each course, then share program-wide curriculum and career feedback. Estimated time for three courses: 12–20 minutes.',N'current',N'GitHub dev e3f3b9b5d66b33b60d08a636920165bb01b898e9 / surveys.js');

DECLARE @sv_16 INT = CONVERT(INT,SCOPE_IDENTITY());

INSERT dbo.survey_questions (survey_version_id,question_code,ordinal,question_text,question_type,is_required,specification_json) VALUES (@sv_16,N'S5-courses',1,N'A. Course reviews',N'repeat',1,N'{"id":"S5-courses","t":"A. Course reviews","type":"repeat","o":[{"id":"course","t":"Course","type":"text","o":0},{"id":"prepared","t":"How well did your prior knowledge prepare you?","type":"single","o":["Not at all","Slightly","Moderately","Well","Very well"]},{"id":"preparation","t":"Would a prerequisite or preparation requirement have helped?","type":"single","o":["Required prerequisite course","Refresher, workshop, or module","Both","Existing requirements were sufficient","No requirement needed","Unsure"]},{"id":"preparation_skills","t":"Which skills needed more preparation?","type":"multi","o":["Python","Other programming","SQL or databases","Statistics","Linear algebra","Calculus","Data cleaning","Visualization","Machine learning","Development tools","Technical communication","Other"],"show":{"javascript_source":"a=>[''Required prerequisite course'',''Refresher, workshop, or module'',''Both''].includes(a.preparation)"},"oo":1},{"id":"preparation_activity","t":"Name a recommended course or preparation activity.","type":"long","o":0,"show":{"javascript_source":"a=>[''Required prerequisite course'',''Refresher, workshop, or module'',''Both''].includes(a.preparation)"},"req":false},{"id":"preparation_communicated","t":"Were these preparation needs communicated before enrollment?","type":"single","o":["Yes","Partly","No","Unsure"],"show":{"javascript_source":"a=>[''Required prerequisite course'',''Refresher, workshop, or module'',''Both''].includes(a.preparation)"}},{"id":"connections","t":"How did this course connect with other courses?","type":"multi","o":["Built on earlier work","Useful reinforcement","Repetition without added depth","Assumed untaught knowledge","Would be better earlier","Would be better later","Unclear connections","Insufficient experience to judge"]},{"id":"connection_context","t":"Identify a topic, overlapping course, or sequence change.","type":"long","o":0,"req":false},{"id":"development","t":"How much did this course develop each area?","type":"grid","o":["Not at all","A little","Somewhat","Quite a bit","A great deal","Not applicable"],"rows":["Technical knowledge","Realistic open-ended problem solving","Working with messy or incomplete data","Nontechnical communication","Collaboration","Responsible data practices","Independent tool learning"]},{"id":"portfolio","t":"Did the course produce work you could show an employer?","type":"single","o":["Ready to share","With revision","Possibly, with guidance","No","Unsure"]},{"id":"portfolio_context","t":"What would make the work portfolio-ready?","type":"long","o":0,"req":false},{"id":"improvements","t":"What would most improve the course’s learning and career value?","type":"multi","o":["Preparation resources","Realistic data or problems","Relevant tools","Underlying concepts","Open-ended projects","Documentation or presentation guidance","Nontechnical communication","Teamwork with shared tools","Industry examples","Course coordination","Assignment and goal alignment","Other","No major changes"],"max":3,"ex":["No major changes"],"oo":1},{"id":"preserve","t":"What should the department preserve about this course?","type":"long","o":0,"req":false},{"id":"change","t":"What should the department change about this course?","type":"long","o":0,"req":false}],"itemLabel":"Course review","addLabel":"Add another course"}');

INSERT dbo.survey_questions (survey_version_id,question_code,ordinal,question_text,question_type,is_required,specification_json) VALUES (@sv_16,N'S5-9',2,N'Were there important gaps or unnecessary overlaps this semester?',N'single',1,N'{"id":"S5-9","t":"Were there important gaps or unnecessary overlaps this semester?","type":"single","o":["Gaps","Overlaps","Both","Neither","Unsure"],"sec":"B. Across the program"}');

INSERT dbo.survey_questions (survey_version_id,question_code,ordinal,question_text,question_type,is_required,specification_json) VALUES (@sv_16,N'S5-9a',3,N'Identify the topics and courses involved.',N'long',0,N'{"id":"S5-9a","t":"Identify the topics and courses involved.","type":"long","o":0,"show":{"javascript_source":"a=>[''Gaps'',''Overlaps'',''Both''].includes(a[''S5-9''])"},"req":false}');

INSERT dbo.survey_questions (survey_version_id,question_code,ordinal,question_text,question_type,is_required,specification_json) VALUES (@sv_16,N'S5-10',4,N'How manageable was major-assignment timing across courses?',N'single',1,N'{"id":"S5-10","t":"How manageable was major-assignment timing across courses?","type":"single","o":["Consistently manageable","Usually manageable","Occasionally difficult due to clustering","Frequently difficult due to clustering","I took one course"]}');

INSERT dbo.survey_questions (survey_version_id,question_code,ordinal,question_text,question_type,is_required,specification_json) VALUES (@sv_16,N'S5-10a',5,N'Suggest a coordination change.',N'long',0,N'{"id":"S5-10a","t":"Suggest a coordination change.","type":"long","o":0,"req":false}');

INSERT dbo.survey_questions (survey_version_id,question_code,ordinal,question_text,question_type,is_required,specification_json) VALUES (@sv_16,N'S5-11',6,N'Which areas need more attention for your career goals?',N'multi',1,N'{"id":"S5-11","t":"Which areas need more attention for your career goals?","type":"multi","o":["Programming or software practices","SQL or data engineering","Statistics or experimental design","Machine learning or evaluation","Real-world data","Visualization or communication","Deployment","Responsible AI, privacy, or ethics","Domain knowledge","Teamwork","Portfolio","Career exploration or employer connections","Other","Unsure","No additional areas"],"max":3,"ex":["Unsure","No additional areas"],"oo":1}');

INSERT dbo.survey_questions (survey_version_id,question_code,ordinal,question_text,question_type,is_required,specification_json) VALUES (@sv_16,N'S5-12',7,N'Have you applied this semester’s learning outside class?',N'multi',1,N'{"id":"S5-12","t":"Have you applied this semester’s learning outside class?","type":"multi","o":["Internship","Paid work","Research","Personal project","Community project","Interview or assessment","Other","No opportunity"],"ex":["No opportunity"],"oo":1}');

INSERT dbo.survey_questions (survey_version_id,question_code,ordinal,question_text,question_type,is_required,specification_json) VALUES (@sv_16,N'S5-12a',8,N'What learning was useful, and what preparation was missing?',N'long',0,N'{"id":"S5-12a","t":"What learning was useful, and what preparation was missing?","type":"long","o":0,"show":{"javascript_source":"a=>!a[''S5-12''].includes(''No opportunity'')"},"req":false}');

INSERT dbo.survey_questions (survey_version_id,question_code,ordinal,question_text,question_type,is_required,specification_json) VALUES (@sv_16,N'S5-13',9,N'What would better connect coursework to careers?',N'multi',1,N'{"id":"S5-13","t":"What would better connect coursework to careers?","type":"multi","o":["External projects","Employer or alumni connections","Skill-to-role explanations","Portfolio guidance","Interview or assessment practice","Opportunity access","Research or applied projects","Elective guidance","Other","Unsure","Current opportunities are sufficient"],"max":3,"ex":["Unsure","Current opportunities are sufficient"],"oo":1}');

INSERT dbo.survey_questions (survey_version_id,question_code,ordinal,question_text,question_type,is_required,specification_json) VALUES (@sv_16,N'S5-14',10,N'What single change would be most valuable for future students?',N'long',0,N'{"id":"S5-14","t":"What single change would be most valuable for future students?","type":"long","o":0,"req":false}');

INSERT dbo.survey_questions (survey_version_id,question_code,ordinal,question_text,question_type,is_required,specification_json) VALUES (@sv_16,N'S5-15',11,N'Would you discuss your feedback further?',N'single',1,N'{"id":"S5-15","t":"Would you discuss your feedback further?","type":"single","o":["Yes","No"]}');

INSERT dbo.survey_versions (survey_code,version_number,variant,survey_title,form_title,introduction,audience,source_reference) VALUES (N'current_6',1,N'long',N'Current Student Surveys',N'End-of-Semester Feedback',N'Complete this after coursework, ideally after final grades are posted. Review each course in detail, then provide program-wide feedback. Written comments are optional; avoid naming classmates or sharing personal information. Estimated time for three courses: 25–35 minutes.',N'current',N'GitHub dev e3f3b9b5d66b33b60d08a636920165bb01b898e9 / surveys.js');

DECLARE @sv_17 INT = CONVERT(INT,SCOPE_IDENTITY());

INSERT dbo.survey_questions (survey_version_id,question_code,ordinal,question_text,question_type,is_required,specification_json) VALUES (@sv_17,N'L5-courses',1,N'A. Course reviews',N'repeat',1,N'{"id":"L5-courses","t":"A. Course reviews","type":"repeat","o":[{"id":"course","t":"Course","type":"text","o":0},{"id":"prepared","t":"How well did your prior knowledge prepare you?","type":"single","o":["Not at all","Slightly","Moderately","Well","Very well"]},{"id":"missing_skills","t":"Which necessary starting skills were insufficiently developed?","type":"multi","o":["Programming","SQL or databases","Statistics","Linear algebra","Calculus","Data cleaning or analysis","Machine learning","Development tools","Technical communication","Other","No substantial gaps"],"ex":["No substantial gaps"],"oo":1},{"id":"preparation","t":"Would different preparation requirements have helped?","type":"single","o":["Prerequisite course","Refresher module","Both","Clearer expected skills","Existing requirements were sufficient","No requirement needed","Unsure"]},{"id":"preparation_detail","t":"Describe the specific prior content, a suggested course or activity, and when the gap became apparent.","type":"long","o":0,"show":{"javascript_source":"a=>[''Prerequisite course'',''Refresher module'',''Both'',''Clearer expected skills''].includes(a.preparation)"},"req":false},{"id":"prerequisite_quality","t":"If you completed listed prerequisites, did they prepare you adequately?","type":"single","o":["Fully","Mostly","Partly","Not at all","Did not complete","None listed","Unsure"]},{"id":"prerequisite_gap","t":"What was missing?","type":"long","o":0,"show":{"javascript_source":"a=>[''Partly'',''Not at all''].includes(a.prerequisite_quality)"},"req":false},{"id":"connections","t":"How did this course connect with the curriculum?","type":"multi","o":["Built on earlier work","Useful reinforcement","Repetition without depth","Assumed untaught material","Unclear connections","Would be better earlier","Would be better later","Insufficient experience"],"oo":1},{"id":"connection_context","t":"Identify related courses or topics and a suggested change.","type":"long","o":0,"req":false},{"id":"depth","t":"How appropriate was the depth of coverage?","type":"single","o":["Too introductory","Somewhat introductory","Appropriate","Somewhat advanced","Too advanced","Varied by topic"]},{"id":"depth_context","t":"Which topics needed more or less depth?","type":"long","o":0,"req":false},{"id":"assignment_alignment","t":"How well did assignments demonstrate the stated learning goals?","type":"single","o":["Not at all","Slightly","Moderately","Well","Very well","Unsure"]},{"id":"assignment_context","t":"Describe an effective assignment or a mismatch.","type":"long","o":0,"req":false},{"id":"tools","t":"Which tools or methods did you use meaningfully?","type":"long","o":0,"req":false},{"id":"development","t":"How much did the course develop each area?","type":"grid","o":["Not at all","A little","Somewhat","Quite a bit","A great deal","Not applicable"],"rows":["Technical knowledge","Open-ended problem solving","Working with messy data","Method selection and evaluation","Reproducibility","Documenting decisions","Nontechnical communication","Collaboration","Ethics, privacy, and limitations","Independent tool learning"]},{"id":"realism","t":"How closely did assignments resemble employment or research problems?","type":"single","o":["Not at all","Slightly","Moderately","Closely","Very closely","Unsure"]},{"id":"realism_context","t":"How could the assignments be more realistic?","type":"long","o":0,"req":false},{"id":"portfolio","t":"Did you produce evidence of your skills?","type":"single","o":["Ready to share","With revision","Possibly with guidance","No","Unsure"]},{"id":"portfolio_context","t":"What help would make it portfolio-ready?","type":"long","o":0,"req":false},{"id":"preserve","t":"What should be preserved?","type":"long","o":0,"req":false},{"id":"change","t":"What should change?","type":"long","o":0,"req":false},{"id":"priority","t":"What is the highest-priority change and expected benefit?","type":"long","o":0,"req":false}],"itemLabel":"Course review","addLabel":"Add another course"}');

INSERT dbo.survey_questions (survey_version_id,question_code,ordinal,question_text,question_type,is_required,specification_json) VALUES (@sv_17,N'L5-14',2,N'Were there important curriculum gaps or unnecessary duplication?',N'long',0,N'{"id":"L5-14","t":"Were there important curriculum gaps or unnecessary duplication?","type":"long","o":0,"sec":"B. Curriculum across courses","note":"Name relevant topics or courses and distinguish useful reinforcement from repetition.","req":false}');

INSERT dbo.survey_questions (survey_version_id,question_code,ordinal,question_text,question_type,is_required,specification_json) VALUES (@sv_17,N'L5-15',3,N'Would you change a course or topic sequence?',N'single',1,N'{"id":"L5-15","t":"Would you change a course or topic sequence?","type":"single","o":["Yes","No","Unsure"]}');

INSERT dbo.survey_questions (survey_version_id,question_code,ordinal,question_text,question_type,is_required,specification_json) VALUES (@sv_17,N'L5-15a',4,N'Describe the proposed sequence and reason.',N'long',0,N'{"id":"L5-15a","t":"Describe the proposed sequence and reason.","type":"long","o":0,"show":{"javascript_source":"a=>a[''L5-15'']==''Yes''"},"req":false}');

INSERT dbo.survey_questions (survey_version_id,question_code,ordinal,question_text,question_type,is_required,specification_json) VALUES (@sv_17,N'L5-16',5,N'How manageable was combined assignment timing?',N'single',1,N'{"id":"L5-16","t":"How manageable was combined assignment timing?","type":"single","o":["Consistently manageable","Usually manageable","Occasionally difficult due to clustering","Frequently difficult due to clustering","I took one course"]}');

INSERT dbo.survey_questions (survey_version_id,question_code,ordinal,question_text,question_type,is_required,specification_json) VALUES (@sv_17,N'L5-16a',6,N'Suggest a coordination improvement.',N'long',0,N'{"id":"L5-16a","t":"Suggest a coordination improvement.","type":"long","o":0,"req":false}');

INSERT dbo.survey_questions (survey_version_id,question_code,ordinal,question_text,question_type,is_required,specification_json) VALUES (@sv_17,N'L5-17',7,N'Which areas need more attention?',N'multi',1,N'{"id":"L5-17","t":"Which areas need more attention?","type":"multi","o":["Programming or software practices","Databases or engineering","Statistics or experimental design","Machine learning or evaluation","Real-world data","Communication","Deployment","Responsible AI, privacy, or ethics","Domain knowledge","Teamwork or project management","Research methods","Portfolio","Career preparation","Other","Unsure","None"],"max":5,"ex":["Unsure","None"],"oo":1}');

INSERT dbo.survey_questions (survey_version_id,question_code,ordinal,question_text,question_type,is_required,specification_json) VALUES (@sv_17,N'L5-18',8,N'Which electives or applied experiences would support your goals?',N'long',0,N'{"id":"L5-18","t":"Which electives or applied experiences would support your goals?","type":"long","o":0,"req":false}');

INSERT dbo.survey_questions (survey_version_id,question_code,ordinal,question_text,question_type,is_required,specification_json) VALUES (@sv_17,N'L5-19',9,N'Did you apply learning outside class?',N'multi',1,N'{"id":"L5-19","t":"Did you apply learning outside class?","type":"multi","o":["Internship","Employment","Research","Personal project","Community work","Interview or assessment","Other","No opportunity"],"sec":"C. Application outside class","ex":["No opportunity"],"oo":1}');

INSERT dbo.survey_questions (survey_version_id,question_code,ordinal,question_text,question_type,is_required,specification_json) VALUES (@sv_17,N'L5-19a',10,N'What learning was useful, what skills were missing, and what course or activity could address the gap?',N'long',0,N'{"id":"L5-19a","t":"What learning was useful, what skills were missing, and what course or activity could address the gap?","type":"long","o":0,"show":{"javascript_source":"a=>!a[''L5-19''].includes(''No opportunity'')"},"req":false}');

INSERT dbo.survey_questions (survey_version_id,question_code,ordinal,question_text,question_type,is_required,specification_json) VALUES (@sv_17,N'L5-20',11,N'How much did the semester clarify suitable career roles?',N'single',1,N'{"id":"L5-20","t":"How much did the semester clarify suitable career roles?","type":"single","o":["Not at all","A little","Somewhat","Quite a bit","A great deal"]}');

INSERT dbo.survey_questions (survey_version_id,question_code,ordinal,question_text,question_type,is_required,specification_json) VALUES (@sv_17,N'L5-21',12,N'What would better connect the program to careers?',N'multi',1,N'{"id":"L5-21","t":"What would better connect the program to careers?","type":"multi","o":["External projects","Employer or alumni participation","Skill-to-role links","Portfolio guidance","Interview or assessment practice","Opportunity access","Research or applied projects","Career-oriented elective pathways","Other","Unsure","Current connections are sufficient"],"max":3,"ex":["Unsure","Current connections are sufficient"],"oo":1}');

INSERT dbo.survey_questions (survey_version_id,question_code,ordinal,question_text,question_type,is_required,specification_json) VALUES (@sv_17,N'L5-22',13,N'How helpful were these resources?',N'grid',1,N'{"id":"L5-22","t":"How helpful were these resources?","type":"grid","o":["Not helpful","Slightly helpful","Moderately helpful","Very helpful","Did not use","Unaware of availability"],"rows":["Advising","Office hours","Tutoring or preparation","Career guidance","Projects or research","Peer learning","Computing or software"],"sec":"D. Department priorities"}');

INSERT dbo.survey_questions (survey_version_id,question_code,ordinal,question_text,question_type,is_required,specification_json) VALUES (@sv_17,N'L5-23',14,N'Was there support you needed but could not access?',N'long',0,N'{"id":"L5-23","t":"Was there support you needed but could not access?","type":"long","o":0,"req":false}');

INSERT dbo.survey_questions (survey_version_id,question_code,ordinal,question_text,question_type,is_required,specification_json) VALUES (@sv_17,N'L5-24',15,N'What single change would be most valuable for future students?',N'long',0,N'{"id":"L5-24","t":"What single change would be most valuable for future students?","type":"long","o":0,"req":false}');

INSERT dbo.survey_questions (survey_version_id,question_code,ordinal,question_text,question_type,is_required,specification_json) VALUES (@sv_17,N'L5-25',16,N'What is one departmental strength to preserve?',N'long',0,N'{"id":"L5-25","t":"What is one departmental strength to preserve?","type":"long","o":0,"req":false}');

INSERT dbo.survey_questions (survey_version_id,question_code,ordinal,question_text,question_type,is_required,specification_json) VALUES (@sv_17,N'L5-26',17,N'Would you discuss your feedback further?',N'single',1,N'{"id":"L5-26","t":"Would you discuss your feedback further?","type":"single","o":["Yes","No"]}');

UPDATE dbo.survey_versions SET source_context_json=N'{"EMP":["Employed full-time","Employed part-time","Self-employed / freelance"],"NOSEARCH":["I plan to continue my education (PhD or other program)","I am not seeking work after graduation"]}';

INSERT dbo.survey_versions (survey_code,version_number,variant,survey_title,form_title,introduction,audience,source_reference)
VALUES ('peer_connections',1,'single',N'Peer connections',N'Peer connections',N'Optional proposed supplement to end-of-semester feedback.','current',N'Prior project request. Faculty wording review pending.');
DECLARE @peer INT=CONVERT(INT,SCOPE_IDENTITY());
INSERT dbo.survey_questions (survey_version_id,question_code,ordinal,question_text,question_type,is_required,specification_json)
VALUES (@peer,'PEER1',1,N'How often did you meet DSA classmates outside scheduled classes this semester?','single',0,
N'{"id":"PEER1","t":"How often did you meet DSA classmates outside scheduled classes this semester?","type":"single","req":false,"o":["Never","Less than monthly","Monthly","Weekly","Several times a week","Prefer not to answer"]}');

EXEC(N'CREATE TRIGGER dbo.tr_survey_questions_guard ON dbo.survey_questions
AFTER INSERT, UPDATE, DELETE AS
BEGIN
    SET NOCOUNT ON;
    IF EXISTS (
        SELECT 1 FROM dbo.survey_versions v WITH (UPDLOCK,HOLDLOCK)
        WHERE v.survey_version_id IN (SELECT survey_version_id FROM inserted UNION SELECT survey_version_id FROM deleted)
        AND v.publication_status<>''draft''
    ) THROW 51100, ''Published survey questions are immutable. Create a new version.'', 1;
END;');

EXEC(N'CREATE TRIGGER dbo.tr_survey_versions_guard ON dbo.survey_versions
AFTER UPDATE, DELETE AS
BEGIN
    SET NOCOUNT ON;
    IF EXISTS (SELECT 1 FROM deleted WHERE publication_status<>''draft'')
        THROW 51101, ''Published survey versions are immutable. Create a new version.'', 1;
END;');

EXEC(N'CREATE TRIGGER dbo.tr_response_guard ON dbo.survey_responses
AFTER INSERT, UPDATE, DELETE AS
BEGIN
    SET NOCOUNT ON;
    IF EXISTS (SELECT 1 FROM deleted WHERE response_status=''submitted'')
        THROW 51102, ''Submitted response history is immutable. Add a correction.'', 1;
    IF EXISTS (
        SELECT 1 FROM inserted r JOIN dbo.survey_versions v WITH (UPDLOCK,HOLDLOCK)
            ON v.survey_version_id=r.survey_version_id
        WHERE v.publication_status<>''published''
            OR (v.collect_identity=1 AND r.user_id IS NULL)
            OR (v.collect_identity=0 AND (r.user_id IS NOT NULL OR r.assignment_id IS NOT NULL))
    ) THROW 51103, ''Response identity or publication status conflicts with its survey.'', 1;
    IF EXISTS (
        SELECT 1 FROM inserted r JOIN dbo.survey_assignments a ON a.assignment_id=r.assignment_id
        WHERE a.cancelled=1 OR ISNULL(a.term_id,-1)<>ISNULL(r.term_id,-1)
    ) THROW 51104, ''Assignment is cancelled or has a different term.'', 1;
    IF EXISTS (
        SELECT 1 FROM inserted r JOIN dbo.survey_responses old ON old.response_id=r.supersedes_response_id
        WHERE old.response_status<>''submitted''
    ) THROW 51105, ''A correction must reference a submitted response.'', 1;
END;');

EXEC(N'CREATE TRIGGER dbo.tr_alert_rule_versions_guard ON dbo.alert_rule_versions
AFTER UPDATE, DELETE AS
BEGIN
    IF EXISTS (SELECT 1 FROM deleted)
        THROW 51106, ''Alert rule versions are immutable. Insert a new version.'', 1;
END;');

EXEC(N'CREATE TRIGGER dbo.tr_alert_source_guard ON dbo.alerts
AFTER INSERT, UPDATE AS
BEGIN
    SET NOCOUNT ON;
    IF EXISTS (SELECT 1 FROM inserted a JOIN dbo.survey_responses r ON r.response_id=a.source_response_id
               WHERE r.response_status<>''submitted'')
        THROW 51107, ''Alerts require a submitted source response.'', 1;
    IF EXISTS (SELECT 1 FROM inserted a JOIN dbo.users u ON u.id=a.reviewed_by
               WHERE u.role NOT IN (''faculty'',''admin'') OR u.status<>''active'')
        THROW 51108, ''Alert reviewer must be active faculty or administrator.'', 1;
END;');

EXEC(N'CREATE TRIGGER dbo.tr_users_last_admin ON dbo.users
AFTER UPDATE,DELETE AS
BEGIN
    SET NOCOUNT ON;
    IF EXISTS (SELECT 1 FROM deleted WHERE role=''admin'' AND status=''active'')
        AND NOT EXISTS (SELECT 1 FROM dbo.users WITH (UPDLOCK,HOLDLOCK) WHERE role=''admin'' AND status=''active'')
        THROW 51109, ''The final active administrator must be retained.'', 1;
END;');

EXEC(N'CREATE TRIGGER dbo.tr_program_record_owner ON dbo.program_records
AFTER INSERT,UPDATE AS
BEGIN
    SET NOCOUNT ON;
    IF EXISTS (SELECT 1 FROM inserted p JOIN dbo.users u ON u.id=p.user_id
               WHERE u.role<>''student'' OR p.graduation_date>CONVERT(DATE,SYSUTCDATETIME()))
        THROW 51110, ''Program records require a student account and a nonfuture graduation date.'', 1;
END;');

EXEC(N'CREATE PROCEDURE dbo.save_survey_response
    @actor_user_id INT,
    @survey_version_id INT,
    @request_id UNIQUEIDENTIFIER,
    @answers_json NVARCHAR(MAX),
    @submit BIT=0,
    @expected_revision INT=NULL,
    @assignment_id INT=NULL,
    @term_id INT=NULL,
    @supersedes_response_id BIGINT=NULL,
    @client_submitted_at DATETIME2(7)=NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    BEGIN TRY
        BEGIN TRANSACTION;
        DECLARE @identity BIT, @audience VARCHAR(10), @owner INT,
            @response_id BIGINT, @revision INT, @state VARCHAR(10), @old_json NVARCHAR(MAX);
        IF NOT EXISTS (SELECT 1 FROM dbo.users WITH (UPDLOCK,HOLDLOCK)
                       WHERE id=@actor_user_id AND role=''student'' AND status=''active'')
            THROW 51200, ''An active student account is required.'', 1;
        SELECT @identity=collect_identity,@audience=audience
        FROM dbo.survey_versions WITH (UPDLOCK,HOLDLOCK)
        WHERE survey_version_id=@survey_version_id AND publication_status=''published'';
        IF @identity IS NULL THROW 51201, ''Survey is not published.'', 1;
        IF NOT EXISTS (SELECT 1 FROM dbo.users WHERE id=@actor_user_id AND
            ((@audience=''applicant'' AND population=''Applicant'') OR
             (@audience=''current'' AND population=''Current student'') OR
             (@audience=''graduate'' AND population=''Graduate'')))
            THROW 51202, ''The current lifecycle category is not eligible for this survey.'', 1;
        SET @owner=CASE WHEN @identity=1 THEN @actor_user_id ELSE NULL END;
        IF @identity=0 AND (@assignment_id IS NOT NULL OR @supersedes_response_id IS NOT NULL)
            THROW 51203, ''Anonymous responses cannot carry assignments or corrections.'', 1;
        IF @assignment_id IS NOT NULL AND NOT EXISTS (
            SELECT 1 FROM dbo.survey_assignments WITH (UPDLOCK,HOLDLOCK)
            WHERE assignment_id=@assignment_id AND user_id=@owner AND survey_version_id=@survey_version_id
                AND cancelled=0 AND ISNULL(term_id,-1)=ISNULL(@term_id,-1)
        ) THROW 51204, ''Assignment does not belong to the respondent, survey and term.'', 1;
        IF ISJSON(@answers_json,OBJECT)<>1 OR @answers_json IS NULL
            THROW 51205, ''Answers must be a JSON object.'', 1;
        IF EXISTS (SELECT [key] COLLATE Latin1_General_100_BIN2 FROM OPENJSON(@answers_json)
                   GROUP BY [key] COLLATE Latin1_General_100_BIN2 HAVING COUNT(*)>1)
            THROW 51206, ''Duplicate answer keys are not allowed.'', 1;
        IF EXISTS (
            SELECT 1 FROM OPENJSON(@answers_json) j
            WHERE NOT EXISTS (SELECT 1 FROM dbo.survey_questions q
                WHERE q.survey_version_id=@survey_version_id AND
                (j.[key]=q.question_code OR j.[key]=q.question_code+N''_other'' OR j.[key]=q.question_code+N''_why''))
        ) THROW 51207, ''An answer key does not belong to this questionnaire version.'', 1;
        IF EXISTS (
            SELECT 1 FROM OPENJSON(@answers_json) j
            JOIN dbo.survey_questions q ON q.survey_version_id=@survey_version_id AND j.[key]=q.question_code
            WHERE j.type<>0 AND (
                (q.question_type IN (''single'',''dropdown'',''text'',''long'',''email'') AND j.type<>1)
                OR (q.question_type=''number'' AND (j.type NOT IN (1,2) OR
                    (j.value<>'''' AND (TRY_CONVERT(DECIMAL(18,4),j.value) IS NULL OR TRY_CONVERT(DECIMAL(18,4),j.value)<0))))
                OR (q.question_type IN (''multi'',''repeat'') AND j.type<>4)
                OR (q.question_type IN (''grid'',''each'') AND j.type<>5)
            )
        ) THROW 51208, ''An answer has an incompatible JSON type.'', 1;
        IF @submit=1 AND EXISTS (
            SELECT 1 FROM dbo.survey_questions q
            WHERE q.survey_version_id=@survey_version_id AND q.is_required=1
                AND JSON_QUERY(q.specification_json,''$.show'') IS NULL
                AND q.question_type<>''each''
                AND NOT EXISTS (SELECT 1 FROM OPENJSON(@answers_json) j WHERE j.[key]=q.question_code
                    AND j.type<>0 AND j.value NOT IN ('''',''[]'',''{}''))
        ) THROW 51209, ''An unconditional required question is unanswered.'', 1;
        -- Validate top-level choice membership, selection counts and exclusive options.
        IF @submit=1 AND EXISTS (
            SELECT 1 FROM dbo.survey_questions q
            JOIN OPENJSON(@answers_json) j ON j.[key]=q.question_code
            WHERE q.survey_version_id=@survey_version_id AND q.question_type IN (''single'',''dropdown'')
                AND j.value<>'''' AND NOT EXISTS (SELECT 1 FROM OPENJSON(q.specification_json,''$.o'') opt WHERE opt.value=j.value)
        ) THROW 51210, ''A selected option does not belong to its question.'', 1;
        IF @submit=1 AND EXISTS (
            SELECT 1 FROM dbo.survey_questions q
            JOIN OPENJSON(@answers_json) j ON j.[key]=q.question_code
            CROSS APPLY (SELECT CASE WHEN j.type=4 THEN j.value ELSE N''[]'' END AS choices) safe
            WHERE q.survey_version_id=@survey_version_id AND q.question_type=''multi'' AND (
                EXISTS (SELECT 1 FROM OPENJSON(safe.choices) selected
                        WHERE selected.type<>1 OR NOT EXISTS (SELECT 1 FROM OPENJSON(q.specification_json,''$.o'') opt WHERE opt.value=selected.value))
                OR (SELECT COUNT(*) FROM OPENJSON(safe.choices))>TRY_CONVERT(INT,JSON_VALUE(q.specification_json,''$.max''))
                OR EXISTS (SELECT value FROM OPENJSON(safe.choices) GROUP BY value HAVING COUNT(*)>1)
                OR ((SELECT COUNT(*) FROM OPENJSON(safe.choices))>1 AND EXISTS (
                    SELECT 1 FROM OPENJSON(safe.choices) selected JOIN OPENJSON(q.specification_json,''$.ex'') ex ON ex.value=selected.value))
            )
        ) THROW 51211, ''Multiple selections violate the option list, limit or exclusivity rule.'', 1;
        SELECT @response_id=response_id,@revision=revision,@state=response_status,@old_json=answers_json
        FROM dbo.survey_responses WITH (UPDLOCK,HOLDLOCK) WHERE request_id=@request_id;
        IF @response_id IS NOT NULL AND NOT EXISTS (
            SELECT 1 FROM dbo.survey_responses WHERE response_id=@response_id
                AND ISNULL(user_id,-1)=ISNULL(@owner,-1) AND survey_version_id=@survey_version_id
                AND ISNULL(assignment_id,-1)=ISNULL(@assignment_id,-1)
                AND ISNULL(term_id,-1)=ISNULL(@term_id,-1)
                AND ISNULL(supersedes_response_id,-1)=ISNULL(@supersedes_response_id,-1)
        ) THROW 51212, ''Request key was already used for a different response.'', 1;
        IF @state=''submitted''
        BEGIN
            IF @submit<>1 OR DATALENGTH(@old_json)<>DATALENGTH(@answers_json)
                OR @old_json COLLATE Latin1_General_100_BIN2<>@answers_json COLLATE Latin1_General_100_BIN2
                THROW 51213, ''A submitted response cannot be edited.'', 1;
        END
        ELSE IF @response_id IS NULL
        BEGIN
            IF @expected_revision IS NOT NULL THROW 51214, ''The draft no longer exists.'', 1;
            INSERT dbo.survey_responses(request_id,user_id,survey_version_id,assignment_id,term_id,
                supersedes_response_id,answers_json,response_status,submitted_at,client_submitted_at)
            VALUES (@request_id,@owner,@survey_version_id,@assignment_id,@term_id,@supersedes_response_id,
                @answers_json,CASE WHEN @submit=1 THEN ''submitted'' ELSE ''draft'' END,
                CASE WHEN @submit=1 THEN SYSUTCDATETIME() END,@client_submitted_at);
            SET @response_id=CONVERT(BIGINT,SCOPE_IDENTITY());
        END
        ELSE
        BEGIN
            IF @expected_revision IS NULL OR @expected_revision<>@revision
                THROW 51215, ''Draft changed since it was loaded. Reload before saving.'', 1;
            UPDATE dbo.survey_responses SET answers_json=@answers_json,revision=revision+1,
                updated_at=SYSUTCDATETIME(),client_submitted_at=@client_submitted_at,
                response_status=CASE WHEN @submit=1 THEN ''submitted'' ELSE ''draft'' END,
                submitted_at=CASE WHEN @submit=1 THEN SYSUTCDATETIME() END
            WHERE response_id=@response_id;
        END;
        COMMIT TRANSACTION;
        SELECT response_id,request_id,revision,response_status,submitted_at FROM dbo.survey_responses WHERE response_id=@response_id;
    END TRY
    BEGIN CATCH
        IF XACT_STATE()<>0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH;
END;');

EXEC(N'CREATE PROCEDURE dbo.publish_survey @actor_user_id INT,@survey_version_id INT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    BEGIN TRY
        BEGIN TRANSACTION;
        IF NOT EXISTS (SELECT 1 FROM dbo.users WITH (UPDLOCK,HOLDLOCK)
                       WHERE id=@actor_user_id AND role=''admin'' AND status=''active'')
            THROW 51220, ''An active administrator is required.'', 1;
        IF NOT EXISTS (SELECT 1 FROM dbo.survey_versions WITH (UPDLOCK,HOLDLOCK)
                       WHERE survey_version_id=@survey_version_id AND publication_status=''draft'')
            THROW 51221, ''Survey must be a draft.'', 1;
        IF NOT EXISTS (SELECT 1 FROM dbo.survey_versions WHERE survey_version_id=@survey_version_id AND LEN(TRIM(notice_text))>0)
            THROW 51223, ''Supply the faculty-approved use notice before publication.'', 1;
        IF NOT EXISTS (SELECT 1 FROM dbo.survey_questions WHERE survey_version_id=@survey_version_id)
            THROW 51222, ''A survey must contain questions before publishing.'', 1;
        UPDATE dbo.survey_versions SET publication_status=''published'',published_at=SYSUTCDATETIME()
        WHERE survey_version_id=@survey_version_id;
        INSERT dbo.admin_audit(actor_user_id,action_code,entity_type,entity_key)
        VALUES (@actor_user_id,''publish'',''survey_versions'',CONVERT(VARCHAR(100),@survey_version_id));
        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF XACT_STATE()<>0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH;
END;');

INSERT dbo.survey_versions (survey_code,version_number,variant,survey_title,form_title,introduction,audience,source_reference)
VALUES ('applicant_readiness_supplement',1,'single',N'Applicant readiness supplement',N'Applicant readiness supplement',N'Draft supplement for framework measures absent from the current applicant form. Review overlap before administering.','applicant',N'Completed DBDD section 4 and project framework section 7');
DECLARE @readiness INT=CONVERT(INT,SCOPE_IDENTITY());

INSERT dbo.survey_questions (survey_version_id,question_code,ordinal,question_text,question_type,is_required,specification_json) VALUES (@readiness,N'ACADEMIC_BACKGROUND',1,N'Describe your academic background and relevant technical preparation.',N'long',0,N'{"id": "ACADEMIC_BACKGROUND", "t": "Describe your academic background and relevant technical preparation.", "type": "long", "req": false, "o": 0}');

INSERT dbo.survey_questions (survey_version_id,question_code,ordinal,question_text,question_type,is_required,specification_json) VALUES (@readiness,N'PROGRAMMING_PREPARATION',2,N'Rate your programming preparation from 1 not prepared to 5 very prepared.',N'single',0,N'{"id": "PROGRAMMING_PREPARATION", "t": "Rate your programming preparation from 1 not prepared to 5 very prepared.", "type": "single", "req": false, "o": ["1", "2", "3", "4", "5"]}');

INSERT dbo.survey_questions (survey_version_id,question_code,ordinal,question_text,question_type,is_required,specification_json) VALUES (@readiness,N'STATISTICS_PREPARATION',3,N'Rate your statistics preparation from 1 not prepared to 5 very prepared.',N'single',0,N'{"id": "STATISTICS_PREPARATION", "t": "Rate your statistics preparation from 1 not prepared to 5 very prepared.", "type": "single", "req": false, "o": ["1", "2", "3", "4", "5"]}');

INSERT dbo.survey_questions (survey_version_id,question_code,ordinal,question_text,question_type,is_required,specification_json) VALUES (@readiness,N'MATHEMATICS_PREPARATION',4,N'Rate your mathematics preparation from 1 not prepared to 5 very prepared.',N'single',0,N'{"id": "MATHEMATICS_PREPARATION", "t": "Rate your mathematics preparation from 1 not prepared to 5 very prepared.", "type": "single", "req": false, "o": ["1", "2", "3", "4", "5"]}');

INSERT dbo.survey_questions (survey_version_id,question_code,ordinal,question_text,question_type,is_required,specification_json) VALUES (@readiness,N'PREREQUISITE_GAPS',5,N'Which prerequisites or preparation activities do you still need? Explicit none is allowed.',N'long',0,N'{"id": "PREREQUISITE_GAPS", "t": "Which prerequisites or preparation activities do you still need? Explicit none is allowed.", "type": "long", "req": false, "o": 0}');

INSERT dbo.survey_questions (survey_version_id,question_code,ordinal,question_text,question_type,is_required,specification_json) VALUES (@readiness,N'DS_EXPECTATIONS',6,N'What do you expect from studying data science?',N'long',0,N'{"id": "DS_EXPECTATIONS", "t": "What do you expect from studying data science?", "type": "long", "req": false, "o": 0}');

INSERT dbo.survey_questions (survey_version_id,question_code,ordinal,question_text,question_type,is_required,specification_json) VALUES (@readiness,N'CAREER_GOALS',7,N'What are your career goals?',N'long',0,N'{"id": "CAREER_GOALS", "t": "What are your career goals?", "type": "long", "req": false, "o": 0}');

INSERT dbo.survey_questions (survey_version_id,question_code,ordinal,question_text,question_type,is_required,specification_json) VALUES (@readiness,N'FIELD_CONFIDENCE',8,N'Rate confidence in the field from 1 very low to 5 very high.',N'single',0,N'{"id": "FIELD_CONFIDENCE", "t": "Rate confidence in the field from 1 very low to 5 very high.", "type": "single", "req": false, "o": ["1", "2", "3", "4", "5"]}');

INSERT dbo.survey_questions (survey_version_id,question_code,ordinal,question_text,question_type,is_required,specification_json) VALUES (@readiness,N'PROGRAM_CHOICE_REASONS',9,N'Why did you choose this program?',N'long',0,N'{"id": "PROGRAM_CHOICE_REASONS", "t": "Why did you choose this program?", "type": "long", "req": false, "o": 0}');

INSERT dbo.survey_questions (survey_version_id,question_code,ordinal,question_text,question_type,is_required,specification_json) VALUES (@readiness,N'GRADUATE_STUDY_PREPARATION',10,N'Rate preparation for graduate study from 1 not prepared to 5 very prepared.',N'single',0,N'{"id": "GRADUATE_STUDY_PREPARATION", "t": "Rate preparation for graduate study from 1 not prepared to 5 very prepared.", "type": "single", "req": false, "o": ["1", "2", "3", "4", "5"]}');

INSERT dbo.survey_versions(survey_code,version_number,variant,survey_title,form_title,introduction,audience,source_reference)
VALUES ('department_resources',1,'single',N'Department resources and spaces',N'Department resources and spaces',N'Draft supplement from the updated current-student survey specification.','current',N'DSA_Current_Student_Surveys.html, October 11 resource additions');
DECLARE @resources INT=CONVERT(INT,SCOPE_IDENTITY());

INSERT dbo.survey_questions(survey_version_id,question_code,ordinal,question_text,question_type,is_required,specification_json) VALUES (@resources,N'RES1',1,N'For each department resource, how aware are you of it and have you used it this semester?',N'grid',0,N'{"id": "RES1", "t": "For each department resource, how aware are you of it and have you used it this semester?", "type": "grid", "req": false, "rows": ["Advising", "Office hours", "Tutoring or preparation", "Career guidance", "Projects or research", "Peer learning", "Computing or software"], "o": ["Unaware it existed", "Aware, but unsure how to access it", "Know how to access it, but have not used it", "Used it this semester"], "note": "Draft resource list. Replace with the faculty-confirmed actual resources before publication."}');

INSERT dbo.survey_questions(survey_version_id,question_code,ordinal,question_text,question_type,is_required,specification_json) VALUES (@resources,N'RES2',2,N'For each unused resource, what prevented you from using it?',N'repeat',0,N'{"id": "RES2", "t": "For each unused resource, what prevented you from using it?", "type": "repeat", "req": false, "o": [{"id": "resource", "t": "Resource", "type": "text", "req": false}, {"id": "reasons", "t": "Reasons", "type": "multi", "req": false, "o": ["No need", "Hours conflict", "Unsure whether eligible", "Unsure how it would help", "Access difficulty", "Other", "Prefer not to answer"], "ex": ["Prefer not to answer"]}], "note": "Show only for resources not marked Used it this semester in RES1."}');

INSERT dbo.survey_questions(survey_version_id,question_code,ordinal,question_text,question_type,is_required,specification_json) VALUES (@resources,N'SPACE1',3,N'How often did you use department common spaces this semester?',N'single',0,N'{"id": "SPACE1", "t": "How often did you use department common spaces this semester?", "type": "single", "req": false, "o": ["Never", "Less than monthly", "Monthly", "Weekly", "Several times a week", "Unaware of available spaces", "No department common spaces available", "Prefer not to answer"]}');

INSERT dbo.survey_questions(survey_version_id,question_code,ordinal,question_text,question_type,is_required,specification_json) VALUES (@resources,N'SPACE2',4,N'What did you use department spaces for?',N'multi',0,N'{"id": "SPACE2", "t": "What did you use department spaces for?", "type": "multi", "req": false, "o": ["Individual study", "Group coursework", "Meeting classmates", "Informal help or discussion", "Department events", "Other"], "note": "Show only if spaces were used."}');

INSERT dbo.survey_questions(survey_version_id,question_code,ordinal,question_text,question_type,is_required,specification_json) VALUES (@resources,N'SPACE3',5,N'What would make department spaces more useful or accessible?',N'multi',0,N'{"id": "SPACE3", "t": "What would make department spaces more useful or accessible?", "type": "multi", "req": false, "o": ["Clearer access information", "Different hours", "More suitable seating or equipment", "Quiet study options", "Group-work options", "Organized activities", "Other", "Unsure", "No changes needed"], "ex": ["Unsure", "No changes needed"], "note": "Show only if spaces are available."}');

EXEC(N'CREATE VIEW dbo.v_accounts AS
SELECT id,username,name,email,role,status,
    CASE WHEN role=''faculty'' THEN ''Faculty adviser'' WHEN role=''admin'' THEN ''Program administrator'' ELSE population END AS population,
    student_id,preferred_contact,created_at,updated_at FROM dbo.users;');

EXEC(N'CREATE VIEW dbo.v_survey_answer_items AS
SELECT r.response_id,r.user_id,r.survey_version_id,v.survey_code,v.variant,r.submitted_at,
    j.[key] AS answer_key,j.type AS json_type,j.value AS answer_value
FROM dbo.survey_responses r JOIN dbo.survey_versions v ON v.survey_version_id=r.survey_version_id
CROSS APPLY OPENJSON(r.answers_json) j WHERE r.response_status=''submitted'';');

EXEC(N'CREATE VIEW dbo.v_checkin_history AS
SELECT r.response_id,r.user_id,r.term_id,r.submitted_at AS date,
    TRY_CONVERT(TINYINT,LEFT(JSON_VALUE(r.answers_json,''$.C1''),1)) AS confidence,
    TRY_CONVERT(TINYINT,LEFT(JSON_VALUE(r.answers_json,''$.C2''),1)) AS belonging,
    TRY_CONVERT(TINYINT,LEFT(JSON_VALUE(r.answers_json,''$.C3''),1)) AS satisfaction,
    TRY_CONVERT(TINYINT,LEFT(JSON_VALUE(r.answers_json,''$.C4''),1)) AS workload,
    TRY_CONVERT(TINYINT,LEFT(JSON_VALUE(r.answers_json,''$.C6''),1)) AS financial,
    TRY_CONVERT(TINYINT,LEFT(JSON_VALUE(r.answers_json,''$.C7''),1)) AS job,
    JSON_VALUE(r.answers_json,''$.C7a'') AS job_stage,
    CONVERT(BIT,CASE JSON_VALUE(r.answers_json,''$.C5'') WHEN ''Yes'' THEN 1 WHEN ''No'' THEN 0 END) AS advising,
    comments.answer_value AS comment
FROM dbo.survey_responses r JOIN dbo.survey_versions v ON v.survey_version_id=r.survey_version_id
OUTER APPLY (SELECT value AS answer_value FROM OPENJSON(r.answers_json) WHERE [key]=''C8'') comments
WHERE r.response_status=''submitted'' AND v.survey_code=''current_0''
    AND NOT EXISTS (SELECT 1 FROM dbo.survey_responses newer WHERE newer.supersedes_response_id=r.response_id AND newer.response_status=''submitted'');');

EXEC(N'CREATE VIEW dbo.v_latest_checkin AS
WITH ranked AS (
    SELECT h.*,ROW_NUMBER() OVER (PARTITION BY user_id ORDER BY date DESC,response_id DESC) AS rn
    FROM dbo.v_checkin_history h
)
SELECT response_id,user_id,term_id,date,confidence,belonging,satisfaction,workload,financial,job,job_stage,advising,comment
FROM ranked WHERE rn=1;');

EXEC(N'CREATE VIEW dbo.v_student_dashboard AS
SELECT u.id AS user_id,u.student_id,u.name,u.email,u.population,u.status,
    p.entry_term_id,p.expected_graduation,p.graduation_date,
    h.date AS latest_checkin,h.confidence,h.belonging,h.satisfaction,h.workload,h.financial,h.job,h.job_stage,h.advising,
    (SELECT COUNT_BIG(*) FROM dbo.alerts a WHERE a.user_id=u.id AND a.alert_status=''active'') AS active_alerts
FROM dbo.users u LEFT JOIN dbo.program_records p ON p.user_id=u.id
LEFT JOIN dbo.v_latest_checkin h ON h.user_id=u.id WHERE u.role=''student'';');

EXEC(N'CREATE VIEW dbo.v_current_collection AS
SELECT * FROM dbo.v_student_dashboard WHERE status=''active'' AND population=''Current student'';');

EXEC(N'CREATE VIEW dbo.v_active_alerts AS
SELECT a.alert_id,u.id AS user_id,u.student_id,u.name AS student,r.rule_code,rv.version_number,
    rv.severity,rv.rule_description,a.source_response_id,a.trigger_values,a.alert_description,
    a.alert_status,a.created_at
FROM dbo.alerts a JOIN dbo.users u ON u.id=a.user_id
JOIN dbo.alert_rule_versions rv ON rv.rule_version_id=a.rule_version_id
JOIN dbo.alert_rules r ON r.rule_id=rv.rule_id WHERE a.alert_status=''active'';');

EXEC(N'CREATE VIEW dbo.v_assignment_status AS
SELECT a.assignment_id,a.user_id,a.survey_version_id,a.event_key,a.due_at,a.followup_month,a.cancelled,
    CASE WHEN a.cancelled=1 THEN ''cancelled'' WHEN EXISTS (
        SELECT 1 FROM dbo.survey_responses r WHERE r.assignment_id=a.assignment_id AND r.response_status=''submitted''
    ) THEN ''completed'' ELSE ''pending'' END AS assignment_status
FROM dbo.survey_assignments a;');

EXEC(N'CREATE VIEW dbo.v_latest_graduate_outcomes AS
WITH ranked AS (
    SELECT r.*,ROW_NUMBER() OVER (PARTITION BY r.user_id ORDER BY r.submitted_at DESC,r.response_id DESC) AS rn
    FROM dbo.survey_responses r JOIN dbo.survey_versions v ON v.survey_version_id=r.survey_version_id
    WHERE r.response_status=''submitted'' AND v.survey_code=''after_0''
    AND NOT EXISTS (SELECT 1 FROM dbo.survey_responses newer WHERE newer.supersedes_response_id=r.response_id AND newer.response_status=''submitted'')
)
SELECT r.user_id,r.response_id,r.submitted_at,
    JSON_VALUE(r.answers_json,''$.B1'') AS graduation_term,
    JSON_VALUE(r.answers_json,''$.B2'') AS employment_status,
    TRY_CONVERT(INT,JSON_VALUE(r.answers_json,''$.B3'')) AS months_to_job,
    JSON_VALUE(r.answers_json,''$.B4'') AS job_title,
    JSON_VALUE(r.answers_json,''$.B5'') AS industry,
    JSON_VALUE(r.answers_json,''$.B6'') AS uses_ds_skills,
    JSON_VALUE(r.answers_json,''$.B7'') AS job_source,
    JSON_VALUE(r.answers_json,''$.B8'') AS salary_range,
    TRY_CONVERT(INT,JSON_VALUE(r.answers_json,''$.B9'')) AS months_searching,
    TRY_CONVERT(TINYINT,LEFT(JSON_VALUE(r.answers_json,''$.B11''),1)) AS employment_preparation
FROM ranked r WHERE rn=1;');

EXEC(N'CREATE PROCEDURE dbo.seed_initial_alert_rules @admin_user_id INT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    BEGIN TRY
        BEGIN TRANSACTION;
        DECLARE @lock INT;
        EXEC @lock=sys.sp_getapplock @Resource=N''DSA_PLab_rule_seed'',@LockMode=N''Exclusive'',@LockOwner=N''Transaction'',@LockTimeout=10000;
        IF @lock<0 THROW 51230, ''Could not acquire rule initialization lock.'', 1;
        IF NOT EXISTS (SELECT 1 FROM dbo.users WITH (UPDLOCK,HOLDLOCK)
            WHERE id=@admin_user_id AND role=''admin'' AND status=''active'')
            THROW 51231, ''An active administrator is required.'', 1;
        DECLARE @rules TABLE (rule_code VARCHAR(50) PRIMARY KEY,config NVARCHAR(4000),severity VARCHAR(6),description NVARCHAR(2000));
        INSERT @rules VALUES
        (N''LOW_CONFIDENCE'',N''{"threshold": 2, "window_count": 1}'',N''medium'',N''Latest confidence is at or below the threshold.''),
        (N''PREREQUISITE_GAP'',N''{"window_count": 1}'',N''medium'',N''Reported prerequisite gap in the latest relevant applicant or student readiness response, other than explicit none. Faculty verifies interpretation.''),
        (N''LOW_BELONGING'',N''{"threshold": 2, "window_count": 2}'',N''medium'',N''Belonging is at or below the threshold on each of the latest two submitted pulse check-ins.''),
        (N''HIGH_WORKLOAD'',N''{"threshold": 4, "window_count": 1}'',N''medium'',N''Latest workload is at or above the threshold.''),
        (N''ADVISING_REQUEST'',N''{"threshold": 1, "window_count": 1}'',N''high'',N''Latest pulse response C5 is Yes.''),
        (N''FINANCIAL_PRESSURE'',N''{"threshold": 4, "window_count": 1}'',N''medium'',N''Latest financial pressure is at or above the threshold.''),
        (N''CAREER_DELAY'',N''{"threshold": 2, "window_count": 1, "near_graduation_days": 90}'',N''medium'',N''Expected graduation is today or within 90 days, progress is non-NULL and at or below threshold, and stage is exploring or preparing. Not currently searching requires faculty interpretation.''),
        (N''MULTIPLE_INDICATORS'',N''{"threshold": 2, "window_count": 1, "confidence_max": 2, "belonging_max": 2, "workload_min": 4, "financial_min": 4}'',N''high'',N''At least the threshold number of negative pulse indicators. Fixed evaluator cutoffs are included in configuration.'');
        INSERT dbo.alert_rules(rule_code)
        SELECT x.rule_code FROM @rules x WHERE NOT EXISTS (SELECT 1 FROM dbo.alert_rules r WHERE r.rule_code=x.rule_code);
        INSERT dbo.alert_rule_versions(rule_id,version_number,configuration_json,severity,rule_description,created_by)
        SELECT r.rule_id,1,x.config,x.severity,x.description,@admin_user_id
        FROM @rules x JOIN dbo.alert_rules r ON r.rule_code=x.rule_code
        WHERE NOT EXISTS (SELECT 1 FROM dbo.alert_rule_versions v WITH (UPDLOCK,HOLDLOCK) WHERE v.rule_id=r.rule_id);
        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF XACT_STATE()<>0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH;
END;');

CREATE ROLE dsa_backend AUTHORIZATION dbo;
GRANT SELECT,INSERT,UPDATE ON dbo.users TO dsa_backend;
GRANT SELECT,INSERT,UPDATE ON dbo.program_records TO dsa_backend;
GRANT SELECT,INSERT,UPDATE ON dbo.contact_preferences TO dsa_backend;
GRANT SELECT,INSERT,UPDATE ON dbo.password_reset_tokens TO dsa_backend;
GRANT SELECT,INSERT,UPDATE ON dbo.academic_terms TO dsa_backend;
GRANT SELECT,INSERT,UPDATE ON dbo.courses TO dsa_backend;
GRANT SELECT,INSERT,UPDATE ON dbo.course_offerings TO dsa_backend;
GRANT SELECT,INSERT,UPDATE ON dbo.student_courses TO dsa_backend;
GRANT SELECT,INSERT,UPDATE ON dbo.survey_versions TO dsa_backend;
GRANT SELECT,INSERT,UPDATE,DELETE ON dbo.survey_questions TO dsa_backend;
GRANT SELECT,INSERT,UPDATE ON dbo.survey_assignments TO dsa_backend;
GRANT SELECT ON dbo.survey_responses TO dsa_backend;
GRANT EXECUTE ON dbo.save_survey_response TO dsa_backend;
GRANT EXECUTE ON dbo.publish_survey TO dsa_backend;
GRANT SELECT ON dbo.alert_rules TO dsa_backend;
GRANT UPDATE ON dbo.alert_rules (enabled) TO dsa_backend;
GRANT SELECT,INSERT ON dbo.alert_rule_versions TO dsa_backend;
GRANT EXECUTE ON dbo.seed_initial_alert_rules TO dsa_backend;
GRANT SELECT,INSERT ON dbo.alerts TO dsa_backend;
GRANT UPDATE ON dbo.alerts (alert_status,reviewed_by,reviewed_at) TO dsa_backend;
GRANT SELECT,INSERT,UPDATE ON dbo.follow_up_requests TO dsa_backend;
GRANT INSERT ON dbo.admin_audit TO dsa_backend;
GRANT SELECT ON dbo.schema_migrations TO dsa_backend;

GRANT SELECT ON dbo.v_accounts TO dsa_backend;

GRANT SELECT ON dbo.v_survey_answer_items TO dsa_backend;

GRANT SELECT ON dbo.v_checkin_history TO dsa_backend;

GRANT SELECT ON dbo.v_latest_checkin TO dsa_backend;

GRANT SELECT ON dbo.v_student_dashboard TO dsa_backend;

GRANT SELECT ON dbo.v_current_collection TO dsa_backend;

GRANT SELECT ON dbo.v_active_alerts TO dsa_backend;

GRANT SELECT ON dbo.v_assignment_status TO dsa_backend;

GRANT SELECT ON dbo.v_latest_graduate_outcomes TO dsa_backend;

INSERT dbo.schema_migrations(version,description) VALUES ('2.0',N'Unified versioned surveys aligned with dev and role-access');
COMMIT TRANSACTION;
END TRY
BEGIN CATCH
    IF XACT_STATE()<>0 ROLLBACK TRANSACTION;
    THROW;
END CATCH;
GO
