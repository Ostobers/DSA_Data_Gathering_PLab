from functools import wraps

from flask import Flask, flash, redirect, render_template, request, send_from_directory, session, url_for
from flask_wtf import FlaskForm
from wtforms import PasswordField, StringField, SubmitField
from wtforms.validators import InputRequired, Length

import seed_data

app = Flask(__name__)
app.config["SECRET_KEY"] = "DONOTSHARE"

ACCOUNTS = {key: dict(value) for key, value in seed_data.USERS.items()}


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
        validators=[InputRequired(), Length(max=120)],
        render_kw={"placeholder": "you@buffalostate.edu"},
    )
    submit = SubmitField("Send recovery instructions")


def current_user():
    username = session.get("username")
    if not username:
        return None
    return ACCOUNTS.get(username)


@app.context_processor
def inject_user():
    return {"user": current_user()}


def login_required(view):
    @wraps(view)
    def wrapped(*args, **kwargs):
        if not current_user():
            flash("Log in to continue.", "error")
            return redirect(url_for("login"))
        return view(*args, **kwargs)

    return wrapped


def roles_required(*roles):
    def decorator(view):
        @wraps(view)
        def wrapped(*args, **kwargs):
            user = current_user()
            if not user:
                flash("Log in to continue.", "error")
                return redirect(url_for("login"))
            if user["role"] not in roles:
                return render_template("forbidden.html"), 403
            if user["status"] != "active":
                session.clear()
                flash("This account is disabled.", "error")
                return redirect(url_for("login"))
            return view(*args, **kwargs)

        return wrapped

    return decorator


def student_record_for(user):
    if user.get("student_id"):
        found = seed_data.student_by_id(user["student_id"])
        if found:
            return found
    return {
        "id": "—",
        "name": user["name"],
        "population": user.get("population", "Student / User"),
        "term": "—",
        "gaps": "None reported",
        "confidence": None,
        "belonging": None,
        "workload": None,
        "financial": None,
        "job": None,
        "job_stage": "—",
        "advising": False,
        "latest_checkin": None,
        "checkins": [],
    }


def visible_alerts():
    reviewed = set(session.get("reviewed_alerts", []))
    rows = []
    for alert in seed_data.ALERTS:
        item = dict(alert)
        if item["id"] in reviewed:
            item["status"] = "reviewed"
        rows.append(item)
    return rows


@app.route("/")
def index():
    return render_template("index.html")


@app.route("/login", methods=["GET", "POST"])
def login():
    if current_user():
        return redirect(url_for("home_for_role"))
    form = LoginForm()
    if form.validate_on_submit():
        account = ACCOUNTS.get(form.username.data)
        if not account or account["password"] != form.password.data:
            flash("Username or password is not correct.", "error")
            return render_template("login.html", form=form)
        if account["status"] != "active":
            flash("This account is disabled. Ask an administrator for help.", "error")
            return render_template("login.html", form=form)
        session["username"] = account["username"]
        flash("Signed in as %s." % account["name"])
        return redirect(url_for("home_for_role"))
    return render_template("login.html", form=form)


@app.route("/recover", methods=["GET", "POST"])
def recover():
    form = RecoverForm()
    if form.validate_on_submit():
        return redirect(url_for("recover_sent"))
    return render_template("recover.html", form=form)


@app.route("/recover/sent")
def recover_sent():
    return render_template("recover_sent.html")


@app.route("/logout")
def logout():
    session.clear()
    flash("You have been logged out.")
    return redirect(url_for("index"))


@app.route("/home")
@login_required
def home_for_role():
    role = current_user()["role"]
    if role == "faculty":
        return redirect(url_for("faculty_home"))
    if role == "admin":
        return redirect(url_for("admin_home"))
    return redirect(url_for("student_home"))


@app.route("/dashboard")
@roles_required("student")
def student_home():
    user = current_user()
    return render_template("student_home.html", student=student_record_for(user))


@app.route("/history")
@roles_required("student")
def history():
    user = current_user()
    return render_template("history.html", student=student_record_for(user))


@app.route("/profile", methods=["GET", "POST"])
@login_required
def profile():
    user = current_user()
    if request.method == "POST":
        action = request.form.get("action")
        if action == "profile":
            user["name"] = request.form.get("name", user["name"]).strip() or user["name"]
            user["email"] = request.form.get("email", user["email"]).strip() or user["email"]
            flash("Profile saved in this session.")
        elif action == "password":
            current_pw = request.form.get("current", "")
            new_pw = request.form.get("new_password", "")
            confirm = request.form.get("confirm", "")
            if current_pw != user["password"]:
                flash("Current password is not correct.", "error")
            elif len(new_pw) < 4:
                flash("New password must be at least 4 characters.", "error")
            elif new_pw != confirm:
                flash("New password and confirmation do not match.", "error")
            else:
                user["password"] = new_pw
                flash("Password updated for this demo session.")
        return redirect(url_for("profile"))
    return render_template("profile.html")


@app.route("/faculty")
@roles_required("faculty", "admin")
def faculty_home():
    q = request.args.get("q", "").strip().lower()
    population = request.args.get("population", "")
    flag = request.args.get("flag", "")
    students = list(seed_data.STUDENTS)
    if q:
        students = [s for s in students if q in s["name"].lower()]
    if population:
        students = [s for s in students if s["population"] == population]
    if flag == "advising":
        students = [s for s in students if s["advising"]]
    elif flag == "low_confidence":
        students = [s for s in students if s["confidence"] is not None and s["confidence"] <= 2]
    elif flag == "gaps":
        students = [s for s in students if s["gaps"] != "None reported"]
    elif flag == "job":
        students = [
            s
            for s in students
            if s["population"] == "Current student" and s["job"] is not None and s["job"] <= 2
        ]
    populations = sorted({s["population"] for s in seed_data.STUDENTS})
    return render_template(
        "faculty_home.html",
        students=students,
        alerts=visible_alerts(),
        totals=seed_data.dashboard_totals(),
        q=request.args.get("q", ""),
        population=population,
        flag=flag,
        populations=populations,
    )


@app.route("/faculty/students/<student_id>")
@roles_required("faculty", "admin")
def student_detail(student_id):
    student = seed_data.student_by_id(student_id)
    if not student:
        flash("Student not found.", "error")
        return redirect(url_for("faculty_home"))
    alerts = [a for a in visible_alerts() if a["student_id"] == student_id]
    return render_template("student_detail.html", student=student, alerts=alerts)


@app.route("/faculty/alerts/<alert_id>/review", methods=["POST"])
@roles_required("faculty", "admin")
def review_alert(alert_id):
    reviewed = set(session.get("reviewed_alerts", []))
    reviewed.add(alert_id)
    session["reviewed_alerts"] = list(reviewed)
    flash("Alert marked reviewed.")
    return redirect(url_for("faculty_home"))


@app.route("/admin")
@roles_required("admin")
def admin_home():
    return render_template(
        "admin_home.html",
        totals=seed_data.dashboard_totals(),
        user_count=len(ACCOUNTS),
    )


@app.route("/admin/users", methods=["GET", "POST"])
@roles_required("admin")
def users():
    if request.method == "POST":
        action = request.form.get("action")
        username = (request.form.get("username") or "").strip()
        if action == "create":
            if username in ACCOUNTS:
                flash("That username already exists.", "error")
            elif not username:
                flash("Username is required.", "error")
            else:
                ACCOUNTS[username] = {
                    "username": username,
                    "password": "demo",
                    "name": request.form.get("name", username).strip() or username,
                    "email": request.form.get("email", "").strip(),
                    "role": request.form.get("role", "student"),
                    "status": "active",
                    "population": "Created by administrator",
                    "student_id": None,
                }
                flash("Account created. Temporary password is demo.")
        elif action in {"disable", "enable"} and username in ACCOUNTS:
            if username == current_user()["username"] and action == "disable":
                flash("You cannot disable your own account.", "error")
            else:
                ACCOUNTS[username]["status"] = "disabled" if action == "disable" else "active"
                flash("Account %s." % ("disabled" if action == "disable" else "enabled"))
        return redirect(url_for("users"))
    accounts = sorted(ACCOUNTS.values(), key=lambda row: row["name"])
    return render_template("users.html", accounts=accounts)


@app.route("/surveys/<path:filename>")
def static_page(filename):
    allowed = {
        "applicant.html",
        "current-student.html",
        "near-graduation.html",
        "after-graduation.html",
        "style.css",
        "survey.js",
        "surveys.js",
    }
    if filename not in allowed:
        return render_template("forbidden.html"), 404
    return send_from_directory(app.root_path, filename)


@app.route("/applicant.html")
@app.route("/current-student.html")
@app.route("/near-graduation.html")
@app.route("/after-graduation.html")
@app.route("/style.css")
@app.route("/survey.js")
@app.route("/surveys.js")
def legacy_static():
    return send_from_directory(app.root_path, request.path.lstrip("/"))


if __name__ == "__main__":
    app.run(debug=True)
