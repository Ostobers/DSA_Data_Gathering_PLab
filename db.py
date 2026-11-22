"""Thin SQL Server data-access helpers for Flask routing.

Uses MSSQL_* compose env vars and ODBC Driver 18. Phase D view helpers
prefer SQL when connected; USE_SEED_DATA still allows seed_data fallback
when SQL is unavailable or empty.

Phase E adds users CRUD (list/create/status/profile) plus admin_audit.
Password verify, bcrypt, recovery tokens, and credential_version flows
belong to the login student — see hash_password / register_password_hasher.
"""

from __future__ import annotations

import hashlib
import json
import os
import urllib.parse
from typing import Any, Callable, Mapping, Optional

from sqlalchemy import create_engine, text
from sqlalchemy.engine import Connection, Engine, Result

# When True, allow in-memory seed_data fallback if SQL is unavailable or empty.
# Prefer SQL view reads whenever the engine connects successfully.
USE_SEED_DATA = os.environ.get("USE_SEED_DATA", "1") == "1"

_engine: Optional[Engine] = None

# Alerts-student extension point: callables invoked after a successful @submit=1.
# Signature: (result_row: Mapping, payload: Mapping, actor_user_id: int) -> None
_AFTER_SUBMIT_HOOKS: list[Callable[..., None]] = []

# Login-student extension point: replace TEMP_SHA256 placeholder with bcrypt/argon2.
# Signature: (plain_password: str) -> str  (≤ 512 chars for dbo.users.password_hash)
_PASSWORD_HASHER: Optional[Callable[[str], str]] = None

STUDENT_POPULATIONS = frozenset(
    {"Applicant", "Current student", "Graduate", "Inactive"}
)
ACCOUNT_ROLES = frozenset({"student", "faculty", "admin"})
ACCOUNT_STATUSES = frozenset({"active", "disabled"})


def register_after_submit_hook(hook: Callable[..., None]) -> None:
    """Register a post-submit callback (alerts student attaches evaluators here)."""
    _AFTER_SUBMIT_HOOKS.append(hook)


def run_after_submit_hooks(
    result_row: Mapping[str, Any],
    payload: Mapping[str, Any],
    actor_user_id: int,
) -> None:
    for hook in list(_AFTER_SUBMIT_HOOKS):
        hook(result_row, payload, actor_user_id)


def register_password_hasher(hasher: Callable[[str], str]) -> None:
    """Login student: register production password hasher (bcrypt/argon2).

    Until registered, create-account uses a TEMP_SHA256 placeholder so the
    NOT NULL password_hash column can be filled. Do not use that placeholder
    for login verify — login student owns verify + credential_version.
    """
    global _PASSWORD_HASHER
    _PASSWORD_HASHER = hasher


def hash_password(plain: str) -> str:
    """Hash a plaintext password for dbo.users.password_hash (NVARCHAR(512)).

    Temporary default is a labeled SHA-256 placeholder so routing can INSERT
    accounts without inventing production bcrypt wiring. Login student must
    call register_password_hasher(...) and implement verify on /login.
    """
    if not plain:
        raise ValueError("password must be non-empty")
    if _PASSWORD_HASHER is not None:
        hashed = _PASSWORD_HASHER(plain)
        if not hashed or len(hashed) > 512:
            raise ValueError("password hasher must return 1..512 characters")
        return hashed
    digest = hashlib.sha256(plain.encode("utf-8")).hexdigest()
    # Prefix makes the placeholder obvious in SQL and unfit for silent verify.
    return f"TEMP_SHA256:{digest}"


def normalize_email(email: str) -> str:
    """Lowercase + trim to satisfy dbo.users email CHECK."""
    return (email or "").strip().lower()


def normalize_username(username: str) -> str:
    return (username or "").strip()


def normalize_name(name: str) -> str:
    return (name or "").strip()


def check_safe_population(*, role: str, population: Optional[str]) -> Optional[str]:
    """Return population for INSERT/UPDATE, or raise ValueError.

    Faculty/admin must store population NULL (v_accounts supplies display labels).
    Students require a CHECK-allowed lifecycle category.
    """
    role = (role or "").strip()
    if role not in ACCOUNT_ROLES:
        raise ValueError(f"role must be one of {sorted(ACCOUNT_ROLES)}")
    if role in {"faculty", "admin"}:
        return None
    pop = (population or "").strip()
    if pop not in STUDENT_POPULATIONS:
        raise ValueError(
            "student population must be one of "
            + ", ".join(sorted(STUDENT_POPULATIONS))
        )
    return pop


def _odbc_connect_string() -> str:
    host = os.environ.get("MSSQL_HOST", "db")
    port = os.environ.get("MSSQL_PORT", "1433")
    database = os.environ.get("MSSQL_DATABASE", "DSA_Student_Success")
    user = os.environ.get("MSSQL_USER", "")
    password = os.environ.get("MSSQL_PASSWORD", "")
    if not user or not password:
        raise RuntimeError(
            "MSSQL_USER and MSSQL_PASSWORD are required for SQL Server access."
        )
    # TrustServerCertificate for lab compose TLS (self-signed).
    return (
        "DRIVER={ODBC Driver 18 for SQL Server};"
        f"SERVER={host},{port};"
        f"DATABASE={database};"
        f"UID={user};"
        f"PWD={password};"
        "Encrypt=yes;"
        "TrustServerCertificate=yes;"
    )


def database_url() -> str:
    return "mssql+pyodbc:///?odbc_connect=" + urllib.parse.quote_plus(
        _odbc_connect_string()
    )


def get_engine() -> Engine:
    global _engine
    if _engine is None:
        _engine = create_engine(database_url(), pool_pre_ping=True, future=True)
    return _engine


def smoke_select() -> dict[str, Any]:
    """Phase A exit check: schema_migrations + published survey_versions count."""
    with get_engine().connect() as conn:
        migrations = (
            conn.execute(
                text(
                    "SELECT version, description, applied_at "
                    "FROM dbo.schema_migrations ORDER BY applied_at"
                )
            )
            .mappings()
            .all()
        )
        versions = conn.execute(
            text(
                "SELECT COUNT(*) AS published_count FROM dbo.survey_versions "
                "WHERE publication_status = 'published'"
            )
        ).mappings().one()
    return {
        "schema_migrations": [dict(r) for r in migrations],
        "published_survey_versions": int(versions["published_count"]),
    }


def fetch_all(sql: str, params: Optional[Mapping[str, Any]] = None) -> list[dict]:
    with get_engine().connect() as conn:
        rows = conn.execute(text(sql), params or {}).mappings().all()
    return [dict(r) for r in rows]


def fetch_one(sql: str, params: Optional[Mapping[str, Any]] = None) -> Optional[dict]:
    with get_engine().connect() as conn:
        row = conn.execute(text(sql), params or {}).mappings().first()
    return dict(row) if row else None


def exec_proc(
    proc_name: str,
    params: Mapping[str, Any],
) -> list[dict]:
    """Execute a stored procedure and return result-set rows as dicts.

    Avoid wrapping callers in nested app transactions; procs manage their own.
    """
    # Named params via pyodbc-friendly CALL with bind params.
    keys = list(params.keys())
    placeholders = ", ".join(f"@{k}=:{k}" for k in keys)
    sql = text(f"EXEC {proc_name} {placeholders}")
    with get_engine().connect() as conn:
        result: Result = conn.execute(sql, dict(params))
        rows = result.mappings().all() if result.returns_rows else []
        conn.commit()
    return [dict(r) for r in rows]


def resolve_published_survey_version_id(
    survey_title: str,
    form_title: str,
    variant: str,
) -> Optional[int]:
    row = fetch_one(
        """
        SELECT survey_version_id
        FROM dbo.survey_versions
        WHERE survey_title = :survey_title
          AND form_title = :form_title
          AND variant = :variant
          AND publication_status = 'published'
        """,
        {
            "survey_title": survey_title,
            "form_title": form_title,
            "variant": variant,
        },
    )
    return int(row["survey_version_id"]) if row else None


def lookup_user_id_by_username(username: str) -> Optional[int]:
    row = fetch_one(
        """
        SELECT id FROM dbo.users
        WHERE username = :username AND status = 'active'
        """,
        {"username": username},
    )
    return int(row["id"]) if row else None


def fetch_survey_version_bundle(survey_version_id: int) -> Optional[dict[str, Any]]:
    """Published version row + question specs for Flask validation."""
    version = fetch_one(
        """
        SELECT survey_version_id, survey_code, variant, survey_title, form_title,
               audience, source_context_json, publication_status
        FROM dbo.survey_versions
        WHERE survey_version_id = :survey_version_id
        """,
        {"survey_version_id": survey_version_id},
    )
    if not version:
        return None
    questions = fetch_all(
        """
        SELECT question_code, ordinal, question_text, question_type,
               is_required, specification_json
        FROM dbo.survey_questions
        WHERE survey_version_id = :survey_version_id
        ORDER BY ordinal, question_code
        """,
        {"survey_version_id": survey_version_id},
    )
    ctx_raw = version.get("source_context_json") or "{}"
    if isinstance(ctx_raw, str):
        try:
            source_context = json.loads(ctx_raw)
        except json.JSONDecodeError:
            source_context = {}
    elif isinstance(ctx_raw, dict):
        source_context = ctx_raw
    else:
        source_context = {}
    return {
        "version": version,
        "questions": questions,
        "source_context": source_context,
    }


def fetch_response_by_request_id(
    request_id: str,
    *,
    actor_user_id: Optional[int] = None,
) -> Optional[dict[str, Any]]:
    """Load a response (draft or submitted) by request_id.

    When actor_user_id is set, require ownership (or anonymous owner NULL).
    """
    row = fetch_one(
        """
        SELECT response_id, request_id, user_id, survey_version_id, assignment_id,
               term_id, supersedes_response_id, answers_json, revision,
               response_status, submitted_at, client_submitted_at, updated_at
        FROM dbo.survey_responses
        WHERE request_id = :request_id
        """,
        {"request_id": request_id},
    )
    if not row:
        return None
    if actor_user_id is not None:
        owner = row.get("user_id")
        if owner is not None and int(owner) != int(actor_user_id):
            return None
    answers_raw = row.get("answers_json")
    if isinstance(answers_raw, str):
        row["answers"] = json.loads(answers_raw)
    else:
        row["answers"] = answers_raw or {}
    return row


def fetch_latest_draft(
    *,
    actor_user_id: int,
    survey_version_id: int,
) -> Optional[dict[str, Any]]:
    """Most recently updated draft for this student + published version."""
    row = fetch_one(
        """
        SELECT TOP 1 response_id, request_id, user_id, survey_version_id,
               assignment_id, term_id, supersedes_response_id, answers_json,
               revision, response_status, submitted_at, client_submitted_at,
               updated_at
        FROM dbo.survey_responses
        WHERE user_id = :actor_user_id
          AND survey_version_id = :survey_version_id
          AND response_status = 'draft'
        ORDER BY updated_at DESC, response_id DESC
        """,
        {
            "actor_user_id": actor_user_id,
            "survey_version_id": survey_version_id,
        },
    )
    if not row:
        return None
    answers_raw = row.get("answers_json")
    if isinstance(answers_raw, str):
        row["answers"] = json.loads(answers_raw)
    else:
        row["answers"] = answers_raw or {}
    return row


def canonical_answers_json(answers: Mapping[str, Any]) -> str:
    """Stable JSON used for proc writes and identical-retry idempotency."""
    return json.dumps(answers, ensure_ascii=False, separators=(",", ":"))


# ---------------------------------------------------------------------------
# Phase D — view helpers (faculty / student / admin reads)
# ---------------------------------------------------------------------------


def sql_configured() -> bool:
    """True when MSSQL credentials are present (compose/.env)."""
    return bool(os.environ.get("MSSQL_USER") and os.environ.get("MSSQL_PASSWORD"))


def _iso_date(value: Any) -> Optional[str]:
    if value is None:
        return None
    if hasattr(value, "isoformat"):
        # datetime → date portion for template display
        if hasattr(value, "hour"):
            return value.date().isoformat()
        return value.isoformat()
    text_value = str(value).strip()
    return text_value[:10] if text_value else None


def _as_bool(value: Any) -> bool:
    if value is None:
        return False
    if isinstance(value, bool):
        return value
    if isinstance(value, (int, float)):
        return value != 0
    return str(value).strip().lower() in {"1", "true", "yes"}


def _as_int_or_none(value: Any) -> Optional[int]:
    if value is None:
        return None
    try:
        return int(value)
    except (TypeError, ValueError):
        return None


def map_checkin_row(row: Mapping[str, Any]) -> dict[str, Any]:
    """Map v_checkin_history / v_latest_checkin columns to template check-in dict."""
    return {
        "date": _iso_date(row.get("date")),
        "confidence": _as_int_or_none(row.get("confidence")),
        "belonging": _as_int_or_none(row.get("belonging")),
        "satisfaction": _as_int_or_none(row.get("satisfaction")),
        "workload": _as_int_or_none(row.get("workload")),
        "financial": _as_int_or_none(row.get("financial")),
        "job": _as_int_or_none(row.get("job")),
        "job_stage": row.get("job_stage") or "—",
        "advising": _as_bool(row.get("advising")),
        "comment": row.get("comment") or "",
        "response_id": row.get("response_id"),
        "user_id": row.get("user_id"),
        "term_id": row.get("term_id"),
    }


def map_student_dashboard_row(
    row: Mapping[str, Any],
    *,
    checkins: Optional[list[Mapping[str, Any]]] = None,
) -> dict[str, Any]:
    """Map v_student_dashboard (+ optional history) to seed_data student shape."""
    term = None
    if row.get("expected_graduation"):
        term = str(row["expected_graduation"])
    elif row.get("entry_term_id") is not None:
        term = f"Term {row['entry_term_id']}"
    else:
        term = "—"
    # Gaps live in applicant survey answers, not the dashboard view yet.
    gaps = "None reported"
    checkin_rows = [map_checkin_row(c) for c in (checkins or [])]
    latest = _iso_date(row.get("latest_checkin"))
    if latest is None and checkin_rows:
        latest = checkin_rows[0].get("date")
    return {
        "id": row.get("student_id") or f"U-{row.get('user_id')}",
        "user_id": _as_int_or_none(row.get("user_id")),
        "name": row.get("name") or "",
        "email": row.get("email") or "",
        "population": row.get("population") or "",
        "status": row.get("status") or "",
        "term": term,
        "gaps": gaps,
        "confidence": _as_int_or_none(row.get("confidence")),
        "belonging": _as_int_or_none(row.get("belonging")),
        "workload": _as_int_or_none(row.get("workload")),
        "financial": _as_int_or_none(row.get("financial")),
        "job": _as_int_or_none(row.get("job")),
        "job_stage": row.get("job_stage") or "—",
        "advising": _as_bool(row.get("advising")),
        "latest_checkin": latest,
        "active_alerts": _as_int_or_none(row.get("active_alerts")) or 0,
        "checkins": checkin_rows,
    }


def map_active_alert_row(row: Mapping[str, Any]) -> dict[str, Any]:
    """Map v_active_alerts to seed_data ALERTS shape used by templates."""
    return {
        "id": str(row.get("alert_id")),
        "student_id": row.get("student_id"),
        "student": row.get("student") or "",
        "type": row.get("title") or row.get("alert_description") or row.get("rule_code") or "",
        "rule": row.get("rule_description") or row.get("rule_code") or "",
        "value": row.get("trigger_values") or row.get("alert_description") or "",
        "status": row.get("alert_status") or "active",
        "user_id": _as_int_or_none(row.get("user_id")),
    }


def fetch_student_dashboard_by_user_id(user_id: int) -> Optional[dict[str, Any]]:
    return fetch_one(
        """
        SELECT user_id, student_id, name, email, population, status,
               entry_term_id, expected_graduation, graduation_date,
               latest_checkin, confidence, belonging, satisfaction,
               workload, financial, job, job_stage, advising, active_alerts
        FROM dbo.v_student_dashboard
        WHERE user_id = :user_id
        """,
        {"user_id": user_id},
    )


def fetch_student_dashboard_by_student_id(student_id: str) -> Optional[dict[str, Any]]:
    return fetch_one(
        """
        SELECT user_id, student_id, name, email, population, status,
               entry_term_id, expected_graduation, graduation_date,
               latest_checkin, confidence, belonging, satisfaction,
               workload, financial, job, job_stage, advising, active_alerts
        FROM dbo.v_student_dashboard
        WHERE student_id = :student_id
        """,
        {"student_id": student_id},
    )


def fetch_latest_checkin(user_id: int) -> Optional[dict[str, Any]]:
    return fetch_one(
        """
        SELECT response_id, user_id, term_id, date, confidence, belonging,
               satisfaction, workload, financial, job, job_stage, advising, comment
        FROM dbo.v_latest_checkin
        WHERE user_id = :user_id
        """,
        {"user_id": user_id},
    )


def fetch_checkin_history(user_id: int) -> list[dict[str, Any]]:
    return fetch_all(
        """
        SELECT response_id, user_id, term_id, date, confidence, belonging,
               satisfaction, workload, financial, job, job_stage, advising, comment
        FROM dbo.v_checkin_history
        WHERE user_id = :user_id
        ORDER BY date DESC, response_id DESC
        """,
        {"user_id": user_id},
    )


def fetch_current_collection() -> list[dict[str, Any]]:
    """Active Current-student rows (v_current_collection)."""
    return fetch_all(
        """
        SELECT user_id, student_id, name, email, population, status,
               entry_term_id, expected_graduation, graduation_date,
               latest_checkin, confidence, belonging, satisfaction,
               workload, financial, job, job_stage, advising, active_alerts
        FROM dbo.v_current_collection
        ORDER BY name
        """
    )


def fetch_student_dashboard_rows(
    *,
    population: Optional[str] = None,
    active_only: bool = True,
) -> list[dict[str, Any]]:
    """Faculty list source: v_student_dashboard with optional population filter."""
    clauses = ["1=1"]
    params: dict[str, Any] = {}
    if active_only:
        clauses.append("status = 'active'")
    if population:
        clauses.append("population = :population")
        params["population"] = population
    where = " AND ".join(clauses)
    return fetch_all(
        f"""
        SELECT user_id, student_id, name, email, population, status,
               entry_term_id, expected_graduation, graduation_date,
               latest_checkin, confidence, belonging, satisfaction,
               workload, financial, job, job_stage, advising, active_alerts
        FROM dbo.v_student_dashboard
        WHERE {where}
        ORDER BY name
        """,
        params,
    )


def fetch_active_alerts(
    *,
    user_id: Optional[int] = None,
    student_id: Optional[str] = None,
) -> list[dict[str, Any]]:
    clauses = ["1=1"]
    params: dict[str, Any] = {}
    if user_id is not None:
        clauses.append("user_id = :user_id")
        params["user_id"] = user_id
    if student_id is not None:
        clauses.append("student_id = :student_id")
        params["student_id"] = student_id
    where = " AND ".join(clauses)
    return fetch_all(
        f"""
        SELECT alert_id, user_id, student_id, student, rule_code, version_number,
               title, rule_description, source_response_id, trigger_values,
               alert_description, alert_status, created_at
        FROM dbo.v_active_alerts
        WHERE {where}
        ORDER BY created_at DESC, alert_id DESC
        """,
        params,
    )


def fetch_account_count() -> int:
    row = fetch_one("SELECT COUNT(*) AS n FROM dbo.v_accounts")
    return int(row["n"]) if row else 0


def fetch_dashboard_totals_from_views() -> dict[str, int]:
    """Aggregate counts for faculty/admin dashboards from SQL views."""
    people = fetch_one(
        "SELECT COUNT(*) AS n FROM dbo.v_student_dashboard"
    )
    current = fetch_one(
        "SELECT COUNT(*) AS n FROM dbo.v_current_collection"
    )
    alerts = fetch_one(
        "SELECT COUNT(*) AS n FROM dbo.v_active_alerts"
    )
    advising = fetch_one(
        """
        SELECT COUNT(*) AS n FROM dbo.v_current_collection
        WHERE advising = 1
        """
    )
    low_conf = fetch_one(
        """
        SELECT COUNT(*) AS n FROM dbo.v_current_collection
        WHERE confidence IS NOT NULL AND confidence <= 2
        """
    )
    # Prerequisite gaps are not on the dashboard views yet (applicant answers).
    gaps = 0
    return {
        "people": int(people["n"]) if people else 0,
        "current": int(current["n"]) if current else 0,
        "alerts": int(alerts["n"]) if alerts else 0,
        "advising": int(advising["n"]) if advising else 0,
        "low_confidence": int(low_conf["n"]) if low_conf else 0,
        "gaps": gaps,
    }


def save_survey_response(
    *,
    actor_user_id: int,
    survey_version_id: int,
    request_id: str,
    answers: Mapping[str, Any],
    submit: bool = True,
    client_submitted_at: Optional[str] = None,
    expected_revision: Optional[int] = None,
    assignment_id: Optional[int] = None,
    term_id: Optional[int] = None,
    supersedes_response_id: Optional[int] = None,
) -> dict[str, Any]:
    answers_json = canonical_answers_json(answers)
    rows = exec_proc(
        "dbo.save_survey_response",
        {
            "actor_user_id": actor_user_id,
            "survey_version_id": survey_version_id,
            "request_id": request_id,
            "answers_json": answers_json,
            "submit": 1 if submit else 0,
            "expected_revision": expected_revision,
            "assignment_id": assignment_id,
            "term_id": term_id,
            "supersedes_response_id": supersedes_response_id,
            "client_submitted_at": client_submitted_at,
        },
    )
    if not rows:
        raise RuntimeError("save_survey_response returned no result row")
    return rows[0]


# ---------------------------------------------------------------------------
# Phase E — users CRUD (non-auth) + admin_audit
# ---------------------------------------------------------------------------


def map_account_row(row: Mapping[str, Any]) -> dict[str, Any]:
    """Map v_accounts / users columns to the users.html account dict."""
    return {
        "id": _as_int_or_none(row.get("id")),
        "username": row.get("username") or "",
        "name": row.get("name") or "",
        "email": row.get("email") or "",
        "role": row.get("role") or "",
        "status": row.get("status") or "",
        "population": row.get("population") or "",
        "student_id": row.get("student_id"),
        "preferred_contact": row.get("preferred_contact") or "email",
    }


def fetch_accounts() -> list[dict[str, Any]]:
    """List accounts from dbo.v_accounts (display population for staff)."""
    rows = fetch_all(
        """
        SELECT id, username, name, email, role, status, population,
               student_id, preferred_contact, created_at, updated_at
        FROM dbo.v_accounts
        ORDER BY name
        """
    )
    return [map_account_row(r) for r in rows]


def fetch_account_by_username(username: str) -> Optional[dict[str, Any]]:
    row = fetch_one(
        """
        SELECT id, username, name, email, role, status, population,
               student_id, preferred_contact, created_at, updated_at
        FROM dbo.v_accounts
        WHERE username = :username
        """,
        {"username": normalize_username(username)},
    )
    return map_account_row(row) if row else None


def _insert_admin_audit(
    conn: Connection,
    *,
    actor_user_id: int,
    action_code: str,
    entity_type: str,
    entity_key: str,
) -> None:
    conn.execute(
        text(
            """
            INSERT dbo.admin_audit(actor_user_id, action_code, entity_type, entity_key)
            VALUES (:actor_user_id, :action_code, :entity_type, :entity_key)
            """
        ),
        {
            "actor_user_id": actor_user_id,
            "action_code": action_code,
            "entity_type": entity_type,
            "entity_key": str(entity_key)[:100],
        },
    )


def insert_admin_audit(
    *,
    actor_user_id: int,
    action_code: str,
    entity_type: str,
    entity_key: str,
) -> None:
    """Standalone admin_audit INSERT (prefer same-transaction helpers below)."""
    with get_engine().begin() as conn:
        _insert_admin_audit(
            conn,
            actor_user_id=actor_user_id,
            action_code=action_code,
            entity_type=entity_type,
            entity_key=entity_key,
        )


def create_user(
    *,
    username: str,
    name: str,
    email: str,
    role: str,
    password_plain: str = "demo",
    population: Optional[str] = None,
    student_id: Optional[str] = None,
    preferred_contact: str = "email",
    actor_user_id: Optional[int] = None,
    create_program_record: bool = True,
) -> dict[str, Any]:
    """INSERT dbo.users with CHECK-safe fields; optional program_records + audit.

    population is forced NULL for faculty/admin. password_hash comes from
    hash_password (pluggable; TEMP_SHA256 until login student registers hasher).
    """
    username = normalize_username(username)
    name = normalize_name(name)
    email = normalize_email(email)
    role = (role or "").strip()
    preferred_contact = (preferred_contact or "email").strip()

    if not (4 <= len(username) <= 20):
        raise ValueError("username must be 4–20 characters")
    if not name:
        raise ValueError("name is required")
    if not email:
        raise ValueError("email is required")
    if preferred_contact not in {"email", "in_app"}:
        raise ValueError("preferred_contact must be email or in_app")

    safe_population = check_safe_population(role=role, population=population)
    if role in {"faculty", "admin"}:
        student_id = None
    elif student_id is not None:
        student_id = student_id.strip() or None

    password_hash = hash_password(password_plain)

    with get_engine().begin() as conn:
        result = conn.execute(
            text(
                """
                INSERT dbo.users (
                    username, name, email, password_hash, role, status,
                    population, student_id, preferred_contact
                )
                OUTPUT INSERTED.id, INSERTED.username, INSERTED.name,
                       INSERTED.email, INSERTED.role, INSERTED.status,
                       INSERTED.population, INSERTED.student_id,
                       INSERTED.preferred_contact
                VALUES (
                    :username, :name, :email, :password_hash, :role, 'active',
                    :population, :student_id, :preferred_contact
                )
                """
            ),
            {
                "username": username,
                "name": name,
                "email": email,
                "password_hash": password_hash,
                "role": role,
                "population": safe_population,
                "student_id": student_id,
                "preferred_contact": preferred_contact,
            },
        )
        row = result.mappings().one()
        user_id = int(row["id"])

        if role == "student" and create_program_record:
            conn.execute(
                text(
                    """
                    INSERT dbo.program_records (user_id)
                    VALUES (:user_id)
                    """
                ),
                {"user_id": user_id},
            )

        if actor_user_id is not None:
            _insert_admin_audit(
                conn,
                actor_user_id=actor_user_id,
                action_code="create_user",
                entity_type="users",
                entity_key=str(user_id),
            )

    account = map_account_row(row)
    # Staff display labels match v_accounts CASE expression.
    if account["role"] == "faculty":
        account["population"] = "Faculty adviser"
    elif account["role"] == "admin":
        account["population"] = "Program administrator"
    return account


def set_user_status(
    *,
    username: str,
    status: str,
    actor_user_id: int,
) -> dict[str, Any]:
    """UPDATE users.status (active/disabled) and write admin_audit."""
    username = normalize_username(username)
    status = (status or "").strip()
    if status not in ACCOUNT_STATUSES:
        raise ValueError(f"status must be one of {sorted(ACCOUNT_STATUSES)}")

    with get_engine().begin() as conn:
        result = conn.execute(
            text(
                """
                UPDATE dbo.users
                SET status = :status,
                    updated_at = SYSUTCDATETIME()
                OUTPUT INSERTED.id, INSERTED.username, INSERTED.name,
                       INSERTED.email, INSERTED.role, INSERTED.status,
                       INSERTED.population, INSERTED.student_id,
                       INSERTED.preferred_contact
                WHERE username = :username
                """
            ),
            {"username": username, "status": status},
        )
        row = result.mappings().first()
        if not row:
            raise ValueError(f"user not found: {username}")
        action = "disable_user" if status == "disabled" else "enable_user"
        _insert_admin_audit(
            conn,
            actor_user_id=actor_user_id,
            action_code=action,
            entity_type="users",
            entity_key=str(row["id"]),
        )
    return map_account_row(row)


def update_user_profile(
    *,
    username: str,
    name: str,
    email: str,
    actor_user_id: Optional[int] = None,
    audit: bool = False,
) -> dict[str, Any]:
    """UPDATE users name/email only (password/credential_version → login student).

    audit=True writes admin_audit when an admin changes another account's
    profile; self-service profile saves leave audit=False.
    """
    username = normalize_username(username)
    name = normalize_name(name)
    email = normalize_email(email)
    if not name:
        raise ValueError("name is required")
    if not email:
        raise ValueError("email is required")

    with get_engine().begin() as conn:
        result = conn.execute(
            text(
                """
                UPDATE dbo.users
                SET name = :name,
                    email = :email,
                    updated_at = SYSUTCDATETIME()
                OUTPUT INSERTED.id, INSERTED.username, INSERTED.name,
                       INSERTED.email, INSERTED.role, INSERTED.status,
                       INSERTED.population, INSERTED.student_id,
                       INSERTED.preferred_contact
                WHERE username = :username
                """
            ),
            {"username": username, "name": name, "email": email},
        )
        row = result.mappings().first()
        if not row:
            raise ValueError(f"user not found: {username}")
        if audit and actor_user_id is not None:
            _insert_admin_audit(
                conn,
                actor_user_id=actor_user_id,
                action_code="update_profile",
                entity_type="users",
                entity_key=str(row["id"]),
            )
    return map_account_row(row)


def update_user_lifecycle(
    *,
    user_id: int,
    population: str,
    actor_user_id: int,
    entry_term_id: Optional[int] = None,
    expected_graduation: Optional[str] = None,
    graduation_date: Optional[str] = None,
    application_status: Optional[str] = None,
) -> dict[str, Any]:
    """Atomic student lifecycle + program_records update with admin_audit.

    Only for role=student. Faculty/admin must keep population NULL.
    UI for this helper is optional; routes may stub until a lifecycle form ships.
    """
    population = check_safe_population(role="student", population=population)
    assert population is not None

    allowed_app = {
        None,
        "interested",
        "applied",
        "admitted",
        "declined",
        "enrolled",
        "withdrawn",
    }
    if application_status not in allowed_app:
        raise ValueError("invalid application_status")

    with get_engine().begin() as conn:
        user_row = conn.execute(
            text(
                """
                SELECT id, role, status FROM dbo.users WITH (UPDLOCK, HOLDLOCK)
                WHERE id = :user_id
                """
            ),
            {"user_id": user_id},
        ).mappings().first()
        if not user_row:
            raise ValueError(f"user not found: {user_id}")
        if user_row["role"] != "student":
            raise ValueError("lifecycle updates apply only to student accounts")

        result = conn.execute(
            text(
                """
                UPDATE dbo.users
                SET population = :population,
                    lifecycle_changed_at = SYSUTCDATETIME(),
                    updated_at = SYSUTCDATETIME()
                OUTPUT INSERTED.id, INSERTED.username, INSERTED.name,
                       INSERTED.email, INSERTED.role, INSERTED.status,
                       INSERTED.population, INSERTED.student_id,
                       INSERTED.preferred_contact
                WHERE id = :user_id
                """
            ),
            {"user_id": user_id, "population": population},
        )
        row = result.mappings().one()

        # Upsert program_records in the same transaction.
        existing = conn.execute(
            text(
                "SELECT program_record_id FROM dbo.program_records WHERE user_id = :user_id"
            ),
            {"user_id": user_id},
        ).first()
        if existing:
            conn.execute(
                text(
                    """
                    UPDATE dbo.program_records
                    SET entry_term_id = COALESCE(:entry_term_id, entry_term_id),
                        expected_graduation = COALESCE(:expected_graduation, expected_graduation),
                        graduation_date = COALESCE(:graduation_date, graduation_date),
                        application_status = COALESCE(:application_status, application_status),
                        updated_at = SYSUTCDATETIME()
                    WHERE user_id = :user_id
                    """
                ),
                {
                    "user_id": user_id,
                    "entry_term_id": entry_term_id,
                    "expected_graduation": expected_graduation,
                    "graduation_date": graduation_date,
                    "application_status": application_status,
                },
            )
        else:
            conn.execute(
                text(
                    """
                    INSERT dbo.program_records (
                        user_id, entry_term_id, expected_graduation,
                        graduation_date, application_status
                    )
                    VALUES (
                        :user_id, :entry_term_id, :expected_graduation,
                        :graduation_date, :application_status
                    )
                    """
                ),
                {
                    "user_id": user_id,
                    "entry_term_id": entry_term_id,
                    "expected_graduation": expected_graduation,
                    "graduation_date": graduation_date,
                    "application_status": application_status,
                },
            )

        _insert_admin_audit(
            conn,
            actor_user_id=actor_user_id,
            action_code="update_lifecycle",
            entity_type="users",
            entity_key=str(user_id),
        )

    return map_account_row(row)
