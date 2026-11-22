"""Flask app with server-side role gates for Jinja templates."""

import os
import uuid
from functools import wraps

from flask import (
    Flask,
    flash,
    jsonify,
    redirect,
    render_template,
    request,
    session,
    url_for,
)
from flask_wtf import FlaskForm
from sqlalchemy.exc import DBAPIError, SQLAlchemyError
from wtforms import PasswordField, StringField, SubmitField
from wtforms.validators import InputRequired, Length

import db
from seed_data import ALERTS, STUDENTS, USERS, alerts_for, dashboard_totals, student_by_id
from survey_validation import validate_survey_answers

app = Flask(__name__)
# Prefer SECRET_KEY from the environment (compose/.env). Lab fallback keeps
# bare `python Hello.py` working locally; docker-compose supplies a real value.
app.config["SECRET_KEY"] = os.environ.get("SECRET_KEY", "DONOTSHARE")

# Canonical role values (match seed_data / templates). Spec "administrator" == admin.
ROLE_STUDENT = "student"
ROLE_FACULTY = "faculty"
ROLE_ADMIN = "admin"
ALL_ROLES = (ROLE_STUDENT, ROLE_FACULTY, ROLE_ADMIN)

STUDENT_ROLES = (ROLE_STUDENT, ROLE_ADMIN)
FACULTY_ROLES = (ROLE_FACULTY, ROLE_ADMIN)
ADMIN_ROLES = (ROLE_ADMIN,)


class LoginForm(FlaskForm):
    username = StringField(
        validators=[InputRequired(), Length(min=4, max=20)],
        render_kw={"placeholder": "Username"},
    )
    password = PasswordField(
        validators=[InputRequired(), Length(min=4, max=20)],
        render_kw={"placeholder": "Password"},
    )
    submit = SubmitField("Login")


class RecoverForm(FlaskForm):
    email = StringField(
        validators=[InputRequired(), Length(min=5, max=80)],
        render_kw={"placeholder": "Email"},
    )
    submit = SubmitField("Send recovery instructions")


def current_user():
    username = session.get("username")
    if not username:
        return None
    return USERS.get(username)


def actor_user_id():
    """Temporary session → dbo.users.id seam (login student replaces later).

    Looks up the demo session username in SQL. Returns None when the account
    has not been provisioned in dbo.users yet.
    """
    user = current_user()
    if not user:
        return None
    # Optional override for lab smoke (e.g. DSA_ACTOR_USER_ID=2).
    override = os.environ.get("DSA_ACTOR_USER_ID")
    if override:
        try:
            return int(override)
        except ValueError:
            pass
    try:
        return db.lookup_user_id_by_username(user["username"])
    except (RuntimeError, SQLAlchemyError, DBAPIError):
        return None


@app.context_processor
def inject_user():
    return {"user": current_user()}


def login_required(view):
    @wraps(view)
    def wrapped(*args, **kwargs):
        if not current_user():
            flash("Please log in to continue.", "error")
            return redirect(url_for("login", next=request.path))
        return view(*args, **kwargs)

    return wrapped


def require_roles(*roles):
    """Redirect unsigned users to login; render forbidden for wrong role."""

    def decorator(view):
        @wraps(view)
        def wrapped(*args, **kwargs):
            user = current_user()
            if not user:
                flash("Log in to continue.", "error")
                return redirect(url_for("login", next=request.path))
            if user["status"] != "active":
                session.clear()
                flash("This account is disabled.", "error")
                return redirect(url_for("login"))
            if user["role"] not in roles:
                return render_template("forbidden.html"), 403
            return view(*args, **kwargs)

        return wrapped

    return decorator


def home_for(user):
    if user["role"] == ROLE_FACULTY:
        return url_for("faculty_home")
    if user["role"] == ROLE_ADMIN:
        return url_for("admin_home")
    return url_for("student_home")


def _try_sql(loader):
    """Run a SQL loader; return None on connection/query failure."""
    if not db.sql_configured():
        return None
    try:
        return loader()
    except (RuntimeError, SQLAlchemyError, DBAPIError):
        app.logger.exception("SQL view read failed; considering seed fallback")
        return None


def _use_sql_result(sql_value):
    """Prefer non-empty SQL; allow empty SQL only when seed fallback is off."""
    if sql_value is None:
        return False
    if isinstance(sql_value, (list, tuple, dict)) and len(sql_value) == 0:
        return not db.USE_SEED_DATA
    if isinstance(sql_value, int) and sql_value == 0:
        return not db.USE_SEED_DATA
    return True


def _student_from_sql_user_id(user_id, *, with_history=False):
    row = _try_sql(lambda: db.fetch_student_dashboard_by_user_id(user_id))
    if not row:
        return None
    checkins = None
    if with_history:
        history = _try_sql(lambda: db.fetch_checkin_history(user_id))
        checkins = history if history is not None else []
    return db.map_student_dashboard_row(row, checkins=checkins)


def _student_from_sql_student_id(student_id, *, with_history=False):
    row = _try_sql(lambda: db.fetch_student_dashboard_by_student_id(student_id))
    if not row:
        return None
    checkins = None
    if with_history:
        uid = row.get("user_id")
        history = _try_sql(lambda: db.fetch_checkin_history(int(uid))) if uid else []
        checkins = history if history is not None else []
    return db.map_student_dashboard_row(row, checkins=checkins)


def _resolve_student_for_session(user, *, with_history=False):
    """D1/D2: prefer v_student_dashboard / history for session actor; seed fallback."""
    actor_id = actor_user_id()
    if actor_id is not None:
        student = _student_from_sql_user_id(actor_id, with_history=with_history)
        if student is not None:
            return student

    seed_id = user.get("student_id")
    if seed_id and db.USE_SEED_DATA:
        student = student_by_id(seed_id)
        if student is not None:
            return student
    if user["role"] == ROLE_ADMIN and db.USE_SEED_DATA:
        return STUDENTS[3]
    return None


def _filter_faculty_students(students, q, population, flag):
    """Apply faculty_home filters (shared by SQL-mapped and seed rows)."""
    rows = list(students)
    if q:
        q_lower = q.lower()
        rows = [s for s in rows if q_lower in (s.get("name") or "").lower()]
    if population:
        rows = [s for s in rows if s.get("population") == population]
    if flag == "advising":
        rows = [s for s in rows if s.get("advising")]
    elif flag == "low_confidence":
        rows = [
            s
            for s in rows
            if s.get("confidence") is not None and s["confidence"] <= 2
        ]
    elif flag == "gaps":
        rows = [s for s in rows if s.get("gaps") and s["gaps"] != "None reported"]
    elif flag == "job":
        rows = [
            s
            for s in rows
            if s.get("population") == "Current student"
            and s.get("job") is not None
            and s["job"] <= 2
        ]
    return rows


def _faculty_students_from_sql(population):
    """D3: v_current_collection by default; v_student_dashboard when filtering pop."""
    if population and population != "Current student":
        rows = _try_sql(
            lambda: db.fetch_student_dashboard_rows(population=population)
        )
    elif population == "Current student":
        rows = _try_sql(db.fetch_current_collection)
    else:
        # All populations: full dashboard (superset of current collection).
        rows = _try_sql(lambda: db.fetch_student_dashboard_rows(population=None))
        if rows is None:
            return None
        if len(rows) == 0:
            # Empty lab: try current collection specifically.
            rows = _try_sql(db.fetch_current_collection) or []
    if rows is None:
        return None
    return [db.map_student_dashboard_row(r) for r in rows]


def _active_alerts_from_sql(*, user_id=None, student_id=None):
    rows = _try_sql(
        lambda: db.fetch_active_alerts(user_id=user_id, student_id=student_id)
    )
    if rows is None:
        return None
    return [db.map_active_alert_row(r) for r in rows]


def _totals_from_sql():
    return _try_sql(db.fetch_dashboard_totals_from_views)


def _account_count_from_sql():
    return _try_sql(db.fetch_account_count)


@app.route("/")
def index():
    return render_template("index.html")


@app.route("/dashboard")
def dashboard_redirect():
    """Compatibility redirect from former student home path."""
    return redirect(url_for("student_home"))


@app.route("/admin/users")
def admin_users_redirect():
    """Compatibility redirect from former admin accounts path."""
    return redirect(url_for("users"))


@app.route("/home")
@require_roles(*ALL_ROLES)
def home_redirect():
    """Compatibility redirect to the role-appropriate dashboard."""
    return redirect(home_for(current_user()))


@app.route("/login", methods=["GET", "POST"])
def login():
    if current_user():
        return redirect(home_for(current_user()))

    form = LoginForm()
    if form.validate_on_submit():
        account = USERS.get(form.username.data)
        if (
            account
            and account["status"] == "active"
            and account["password"] == form.password.data
        ):
            session["username"] = account["username"]
            nxt = request.args.get("next")
            if nxt and nxt.startswith("/"):
                return redirect(nxt)
            return redirect(home_for(account))
        flash("Invalid username or password.", "error")
    return render_template("login.html", form=form)


@app.route("/logout")
def logout():
    session.clear()
    flash("You have been logged out.")
    return redirect(url_for("index"))


@app.route("/register")
@require_roles(ROLE_ADMIN)
def register():
    return render_template("register.html")


@app.route("/recover", methods=["GET", "POST"])
def recover():
    form = RecoverForm()
    if form.validate_on_submit():
        return redirect(url_for("recover_sent"))
    return render_template("recover.html", form=form)


@app.route("/recover/sent")
def recover_sent():
    return render_template("recover_sent.html")


@app.route("/forbidden")
@require_roles(*ALL_ROLES)
def forbidden():
    return render_template("forbidden.html"), 403


@app.route("/profile", methods=["GET", "POST"])
@require_roles(*ALL_ROLES)
def profile():
    user = current_user()
    if request.method == "POST":
        action = request.form.get("action")
        if action == "profile":
            user["name"] = request.form.get("name", user["name"]).strip() or user["name"]
            user["email"] = request.form.get("email", user["email"]).strip() or user["email"]
            flash("Profile updated.")
        elif action == "password":
            current = request.form.get("current", "")
            new_password = request.form.get("new_password", "")
            confirm = request.form.get("confirm", "")
            if current != user["password"]:
                flash("Current password is incorrect.", "error")
            elif len(new_password) < 4:
                flash("New password must be at least 4 characters.", "error")
            elif new_password != confirm:
                flash("New passwords do not match.", "error")
            else:
                user["password"] = new_password
                flash("Password updated for this demo session.")
        return redirect(url_for("profile"))
    return render_template("profile.html")


@app.route("/student")
@require_roles(*STUDENT_ROLES)
def student_home():
    # D1: v_latest_checkin / v_student_dashboard for session user.
    student = _resolve_student_for_session(current_user(), with_history=False)
    if student is None:
        return render_template("forbidden.html"), 403
    return render_template("student_home.html", student=student)


@app.route("/history")
@require_roles(*STUDENT_ROLES)
def history():
    # D2: v_checkin_history for session user.
    student = _resolve_student_for_session(current_user(), with_history=True)
    if student is None:
        return render_template("forbidden.html"), 403
    return render_template("history.html", student=student)


@app.route("/faculty")
@require_roles(*FACULTY_ROLES)
def faculty_home():
    # D3 + D5: v_current_collection / dashboard filters + view aggregates.
    q = request.args.get("q", "").strip()
    population = request.args.get("population", "")
    flag = request.args.get("flag", "")

    sql_students = _faculty_students_from_sql(population or None)
    if _use_sql_result(sql_students):
        # Population already applied in SQL when set.
        students = _filter_faculty_students(sql_students, q, "", flag)
        pop_rows = _try_sql(lambda: db.fetch_student_dashboard_rows())
        if pop_rows:
            populations = sorted(
                {r["population"] for r in pop_rows if r.get("population")}
            )
        else:
            populations = sorted(
                {s["population"] for s in sql_students if s.get("population")}
            ) or ["Current student"]
    elif db.USE_SEED_DATA:
        students = _filter_faculty_students(STUDENTS, q, population, flag)
        populations = sorted({s["population"] for s in STUDENTS})
    else:
        students = []
        populations = ["Current student"]

    sql_alerts = _active_alerts_from_sql()
    if _use_sql_result(sql_alerts):
        alerts = sql_alerts
    elif db.USE_SEED_DATA:
        alerts = ALERTS
    else:
        alerts = []

    sql_totals = _totals_from_sql()
    if sql_totals is not None and (
        sql_totals.get("people", 0) > 0 or not db.USE_SEED_DATA
    ):
        totals = sql_totals
    elif db.USE_SEED_DATA:
        totals = dashboard_totals()
    else:
        totals = {
            "people": 0,
            "current": 0,
            "alerts": 0,
            "advising": 0,
            "low_confidence": 0,
            "gaps": 0,
        }

    return render_template(
        "faculty_home.html",
        alerts=alerts,
        students=students,
        totals=totals,
        q=request.args.get("q", ""),
        population=population,
        flag=flag,
        populations=populations,
    )


@app.route("/faculty/students/<student_id>")
@require_roles(*FACULTY_ROLES)
def student_detail(student_id):
    # D4: dashboard + checkins + v_active_alerts.
    student = _student_from_sql_student_id(student_id, with_history=True)
    if student is None and db.USE_SEED_DATA:
        student = student_by_id(student_id)
    if student is None:
        return render_template("forbidden.html"), 404

    sql_alerts = _active_alerts_from_sql(
        user_id=student.get("user_id"),
        student_id=student_id,
    )
    if _use_sql_result(sql_alerts):
        detail_alerts = sql_alerts
    elif db.USE_SEED_DATA:
        detail_alerts = alerts_for(student_id)
    else:
        detail_alerts = []

    return render_template(
        "student_detail.html",
        student=student,
        alerts=detail_alerts,
    )


@app.route("/faculty/alerts/<alert_id>/review", methods=["POST"])
@require_roles(*FACULTY_ROLES)
def review_alert(alert_id):
    # Alert review UPDATE is Phase F; keep seed-list mutation for demo only.
    for alert in ALERTS:
        if alert["id"] == alert_id:
            alert["status"] = "reviewed"
            flash("Alert marked reviewed.")
            break
    return redirect(url_for("faculty_home"))


@app.route("/admin")
@require_roles(*ADMIN_ROLES)
def admin_home():
    # D5: aggregates from views + v_accounts count.
    sql_totals = _totals_from_sql()
    if sql_totals is not None and (
        sql_totals.get("people", 0) > 0 or not db.USE_SEED_DATA
    ):
        totals = sql_totals
    elif db.USE_SEED_DATA:
        totals = dashboard_totals()
    else:
        totals = {
            "people": 0,
            "current": 0,
            "alerts": 0,
            "advising": 0,
            "low_confidence": 0,
            "gaps": 0,
        }

    sql_count = _account_count_from_sql()
    if _use_sql_result(sql_count):
        user_count = sql_count
    else:
        user_count = len(USERS)

    return render_template(
        "admin_home.html",
        totals=totals,
        user_count=user_count,
    )


@app.route("/users", methods=["GET", "POST"])
@require_roles(*ADMIN_ROLES)
def users():
    if request.method == "POST":
        action = request.form.get("action")
        if action == "create":
            username = (request.form.get("username") or "").strip()
            if not username:
                flash("Username is required.", "error")
            elif username in USERS:
                flash("That username already exists.", "error")
            else:
                USERS[username] = {
                    "username": username,
                    "password": "demo",
                    "name": (request.form.get("name") or username).strip(),
                    "email": (request.form.get("email") or "").strip(),
                    "role": request.form.get("role") or ROLE_STUDENT,
                    "status": "active",
                    "population": "Created in prototype",
                    "student_id": None,
                }
                flash("Account created with temporary password demo.")
        elif action in {"disable", "enable"}:
            username = request.form.get("username")
            account = USERS.get(username)
            if account and account["username"] != current_user()["username"]:
                account["status"] = "disabled" if action == "disable" else "active"
                flash("Account updated.")
            elif account:
                flash("You cannot disable your own account.", "error")
        return redirect(url_for("users"))
    accounts = sorted(USERS.values(), key=lambda a: a["name"].lower())
    return render_template("users.html", accounts=accounts)


def survey_page(template, **kwargs):
    return render_template(template, **kwargs)


# Prefer clean paths for url_for (first-registered rule wins). Keep .html aliases.
@app.route("/surveys/index.html")
@app.route("/surveys")
@require_roles(*STUDENT_ROLES)
def surveys():
    return survey_page("surveys.html")


@app.route("/applicant.html")
@app.route("/applicant")
@require_roles(*STUDENT_ROLES)
def applicant():
    return survey_page(
        "survey_form.html",
        title="Applicant Survey",
        survey_key="applicant",
    )


@app.route("/current-student.html")
@app.route("/current-student")
@require_roles(*STUDENT_ROLES)
def current_student():
    return survey_page(
        "survey_form.html",
        title="Current Student Surveys",
        survey_key="current",
    )


@app.route("/near-graduation.html")
@app.route("/near-graduation")
@require_roles(*STUDENT_ROLES)
def near_graduation():
    return survey_page(
        "survey_form.html",
        title="Near Graduation Survey",
        survey_key="near",
    )


@app.route("/after-graduation.html")
@app.route("/after-graduation")
@require_roles(*STUDENT_ROLES)
def after_graduation():
    return survey_page(
        "survey_form.html",
        title="After Graduation Survey",
        survey_key="after",
    )


def _basic_survey_payload_ok(body, *, submit):
    """Reject empty/malformed envelopes before DB work."""
    if not isinstance(body, dict):
        return False, "Request body must be a JSON object."
    survey = body.get("survey")
    form = body.get("form")
    version = body.get("version")
    answers = body.get("answers")
    if not isinstance(survey, str) or not survey.strip():
        return False, "Missing survey title."
    if not isinstance(form, str) or not form.strip():
        return False, "Missing form title."
    if not isinstance(version, str) or version not in ("single", "short", "long"):
        return False, "version must be single, short, or long."
    if not isinstance(answers, dict):
        return False, "answers must be a JSON object."
    if submit and len(answers) == 0:
        return False, "answers must be a non-empty object."
    return True, None


def _parse_optional_int(value, field_name):
    if value is None or value == "":
        return True, None
    try:
        return True, int(value)
    except (TypeError, ValueError):
        return False, f"{field_name} must be an integer."


def _response_payload(result, request_id, survey_version_id):
    return {
        "ok": True,
        "response_id": result.get("response_id"),
        "request_id": str(result.get("request_id", request_id)),
        "revision": result.get("revision"),
        "response_status": result.get("response_status"),
        "submitted_at": (
            result["submitted_at"].isoformat()
            if hasattr(result.get("submitted_at"), "isoformat")
            else result.get("submitted_at")
        ),
        "survey_version_id": survey_version_id,
        # Correction chain: accepted by POST when provided; UI/workflow later.
        "supersedes_response_id": result.get("supersedes_response_id"),
    }


@app.route("/api/surveys/responses", methods=["POST"])
@require_roles(*STUDENT_ROLES)
def api_survey_responses():
    """Draft (@submit=0) or final submit via dbo.save_survey_response.

    Idempotent final retry: same request_id + identical answers_json returns
    the existing submitted row (SQL 51213 rejects mismatched payloads).
    """
    body = request.get_json(silent=True)
    submit = True
    if isinstance(body, dict) and "submit" in body:
        submit = bool(body.get("submit"))

    ok, err = _basic_survey_payload_ok(body, submit=submit)
    if not ok:
        return jsonify({"ok": False, "error": err}), 400

    actor_id = actor_user_id()
    if actor_id is None:
        return (
            jsonify(
                {
                    "ok": False,
                    "error": (
                        "No dbo.users row mapped for this session username. "
                        "Login student must provision SQL accounts; lab may "
                        "set DSA_ACTOR_USER_ID temporarily."
                    ),
                }
            ),
            403,
        )

    try:
        survey_version_id = db.resolve_published_survey_version_id(
            body["survey"].strip(),
            body["form"].strip(),
            body["version"].strip(),
        )
    except (RuntimeError, SQLAlchemyError, DBAPIError) as exc:
        return jsonify({"ok": False, "error": f"Database error: {exc}"}), 503

    if survey_version_id is None:
        return (
            jsonify(
                {
                    "ok": False,
                    "error": "No published survey_version matches survey/form/version.",
                }
            ),
            404,
        )

    request_id = body.get("request_id")
    if not request_id:
        request_id = str(uuid.uuid4())
    try:
        uuid.UUID(str(request_id))
    except (ValueError, TypeError, AttributeError):
        return jsonify({"ok": False, "error": "request_id must be a UUID."}), 400

    client_submitted_at = body.get("submitted_at")
    if client_submitted_at is not None and not isinstance(client_submitted_at, str):
        return jsonify({"ok": False, "error": "submitted_at must be a string."}), 400

    ok_rev, expected_revision = _parse_optional_int(
        body.get("expected_revision"), "expected_revision"
    )
    if not ok_rev:
        return jsonify({"ok": False, "error": expected_revision}), 400

    ok_sup, supersedes_response_id = _parse_optional_int(
        body.get("supersedes_response_id"), "supersedes_response_id"
    )
    if not ok_sup:
        return jsonify({"ok": False, "error": supersedes_response_id}), 400

    # Trusted Flask validation (show / repeats / grids / each / emails).
    # Does not execute javascript_source from the database.
    try:
        bundle = db.fetch_survey_version_bundle(survey_version_id)
    except (RuntimeError, SQLAlchemyError, DBAPIError) as exc:
        return jsonify({"ok": False, "error": f"Database error: {exc}"}), 503
    if not bundle:
        return jsonify({"ok": False, "error": "Survey version not found."}), 404

    valid, verr = validate_survey_answers(
        bundle["questions"],
        body["answers"],
        submit=submit,
        source_context=bundle["source_context"],
    )
    if not valid:
        return jsonify({"ok": False, "error": verr}), 400

    try:
        result = db.save_survey_response(
            actor_user_id=actor_id,
            survey_version_id=survey_version_id,
            request_id=str(request_id),
            answers=body["answers"],
            submit=submit,
            client_submitted_at=client_submitted_at,
            expected_revision=expected_revision,
            supersedes_response_id=supersedes_response_id,
        )
    except (RuntimeError, SQLAlchemyError, DBAPIError) as exc:
        # Surface SQL THROW messages when available (pyodbc).
        message = str(exc.orig) if getattr(exc, "orig", None) else str(exc)
        return jsonify({"ok": False, "error": message}), 400

    # Alerts-student hook only after successful final submit (Phase B seam).
    if submit:
        try:
            db.run_after_submit_hooks(result, body, actor_id)
        except Exception:
            # Persist succeeded; alert evaluation failures must not undo submit.
            app.logger.exception("after-submit hook failed")

    return jsonify(_response_payload(result, request_id, survey_version_id)), 200


@app.route("/api/surveys/responses/<request_id>", methods=["GET"])
@require_roles(*STUDENT_ROLES)
def api_get_survey_response(request_id):
    """Resume a draft (or inspect a submitted response) by request_id."""
    try:
        uuid.UUID(str(request_id))
    except (ValueError, TypeError, AttributeError):
        return jsonify({"ok": False, "error": "request_id must be a UUID."}), 400

    actor_id = actor_user_id()
    if actor_id is None:
        return (
            jsonify(
                {
                    "ok": False,
                    "error": "No dbo.users row mapped for this session username.",
                }
            ),
            403,
        )

    try:
        row = db.fetch_response_by_request_id(request_id, actor_user_id=actor_id)
    except (RuntimeError, SQLAlchemyError, DBAPIError) as exc:
        return jsonify({"ok": False, "error": f"Database error: {exc}"}), 503

    if not row:
        return jsonify({"ok": False, "error": "Response not found."}), 404

    return (
        jsonify(
            {
                "ok": True,
                "response_id": row.get("response_id"),
                "request_id": str(row.get("request_id")),
                "revision": row.get("revision"),
                "response_status": row.get("response_status"),
                "survey_version_id": row.get("survey_version_id"),
                "answers": row.get("answers") or {},
                "supersedes_response_id": row.get("supersedes_response_id"),
                "submitted_at": (
                    row["submitted_at"].isoformat()
                    if hasattr(row.get("submitted_at"), "isoformat")
                    else row.get("submitted_at")
                ),
            }
        ),
        200,
    )


@app.route("/api/surveys/drafts", methods=["GET"])
@require_roles(*STUDENT_ROLES)
def api_latest_survey_draft():
    """Latest draft for the published survey/form/version triple."""
    survey = (request.args.get("survey") or "").strip()
    form = (request.args.get("form") or "").strip()
    version = (request.args.get("version") or "").strip()
    if not survey or not form or version not in ("single", "short", "long"):
        return (
            jsonify(
                {
                    "ok": False,
                    "error": "Query params survey, form, and version are required.",
                }
            ),
            400,
        )

    actor_id = actor_user_id()
    if actor_id is None:
        return (
            jsonify(
                {
                    "ok": False,
                    "error": "No dbo.users row mapped for this session username.",
                }
            ),
            403,
        )

    try:
        survey_version_id = db.resolve_published_survey_version_id(
            survey, form, version
        )
        if survey_version_id is None:
            return (
                jsonify(
                    {
                        "ok": False,
                        "error": "No published survey_version matches survey/form/version.",
                    }
                ),
                404,
            )
        row = db.fetch_latest_draft(
            actor_user_id=actor_id, survey_version_id=survey_version_id
        )
    except (RuntimeError, SQLAlchemyError, DBAPIError) as exc:
        return jsonify({"ok": False, "error": f"Database error: {exc}"}), 503

    if not row:
        return jsonify({"ok": True, "draft": None}), 200

    return (
        jsonify(
            {
                "ok": True,
                "draft": {
                    "response_id": row.get("response_id"),
                    "request_id": str(row.get("request_id")),
                    "revision": row.get("revision"),
                    "response_status": row.get("response_status"),
                    "survey_version_id": survey_version_id,
                    "answers": row.get("answers") or {},
                    "supersedes_response_id": row.get("supersedes_response_id"),
                },
            }
        ),
        200,
    )


@app.route("/api/db/smoke", methods=["GET"])
@require_roles(*ADMIN_ROLES)
def api_db_smoke():
    """Phase A smoke: schema_migrations + published survey_versions count."""
    try:
        return jsonify({"ok": True, **db.smoke_select()}), 200
    except (RuntimeError, SQLAlchemyError, DBAPIError) as exc:
        return jsonify({"ok": False, "error": str(exc)}), 503


if __name__ == "__main__":
    # Bind 0.0.0.0 so Docker published ports reach the process; debug stays
    # lab-only until a production WSGI server is adopted.
    host = os.environ.get("FLASK_RUN_HOST", "0.0.0.0")
    port = int(os.environ.get("FLASK_RUN_PORT", "5000"))
    debug = os.environ.get("FLASK_DEBUG", "1") == "1"
    app.run(host=host, port=port, debug=debug)

