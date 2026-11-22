"""Thin SQL Server data-access helpers for Flask routing.

Uses MSSQL_* compose env vars and ODBC Driver 18. Keep seed_data as the
UX fallback until later phases migrate reads (USE_SEED_DATA flag).
"""

from __future__ import annotations

import json
import os
import urllib.parse
from typing import Any, Callable, Mapping, Optional

from sqlalchemy import create_engine, text
from sqlalchemy.engine import Engine, Result

# Until Phase D+ replace dashboard reads, keep in-memory seed_data available.
USE_SEED_DATA = os.environ.get("USE_SEED_DATA", "1") == "1"

_engine: Optional[Engine] = None

# Alerts-student extension point: callables invoked after a successful @submit=1.
# Signature: (result_row: Mapping, payload: Mapping, actor_user_id: int) -> None
_AFTER_SUBMIT_HOOKS: list[Callable[..., None]] = []


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
