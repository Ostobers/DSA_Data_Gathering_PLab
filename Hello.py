from functools import wraps

from flask import (
    Flask,
    flash,
    redirect,
    render_template,
    request,
    session,
    url_for,
)
from flask_wtf import FlaskForm
from wtforms import PasswordField, StringField, SubmitField
from wtforms.validators import InputRequired, Length

from seed_data import ALERTS, STUDENTS, USERS, alerts_for, dashboard_totals, student_by_id

app = Flask(__name__)
app.config["SECRET_KEY"] = "DONOTSHARE"

STUDENT_ROLES = ("student", "admin")
FACULTY_ROLES = ("faculty", "admin")
ADMIN_ROLES = ("admin",)


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


def roles_required(*roles):
    def decorator(view):
        @wraps(view)
        @login_required
        def wrapped(*args, **kwargs):
            user = current_user()
            if user["role"] not in roles:
                return render_template("forbidden.html"), 403
            return view(*args, **kwargs)

        return wrapped

    return decorator


def home_for(user):
    if user["role"] == "faculty":
        return url_for("faculty_home")
    if user["role"] == "admin":
        return url_for("admin_home")
    return url_for("student_home")


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
@login_required
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


@app.route("/profile", methods=["GET", "POST"])
@login_required
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
@roles_required(*STUDENT_ROLES)
def student_home():
    user = current_user()
    student = student_by_id(user.get("student_id")) if user.get("student_id") else None
    if student is None and user["role"] == "admin":
        student = STUDENTS[3]
    if student is None:
        return render_template("forbidden.html"), 403
    return render_template("student_home.html", student=student)


@app.route("/history")
@roles_required(*STUDENT_ROLES)
def history():
    user = current_user()
    student = student_by_id(user.get("student_id")) if user.get("student_id") else None
    if student is None and user["role"] == "admin":
        student = STUDENTS[3]
    if student is None:
        return render_template("forbidden.html"), 403
    return render_template("history.html", student=student)


@app.route("/faculty")
@roles_required(*FACULTY_ROLES)
def faculty_home():
    q = request.args.get("q", "").strip().lower()
    population = request.args.get("population", "")
    flag = request.args.get("flag", "")
    students = list(STUDENTS)
    if q:
        students = [s for s in students if q in s["name"].lower()]
    if population:
        students = [s for s in students if s["population"] == population]
    if flag == "advising":
        students = [s for s in students if s["advising"]]
    elif flag == "low_confidence":
        students = [
            s
            for s in students
            if s["confidence"] is not None and s["confidence"] <= 2
        ]
    elif flag == "gaps":
        students = [s for s in students if s["gaps"] != "None reported"]
    elif flag == "job":
        students = [
            s
            for s in students
            if s["population"] == "Current student"
            and s["job"] is not None
            and s["job"] <= 2
        ]
    populations = sorted({s["population"] for s in STUDENTS})
    return render_template(
        "faculty_home.html",
        alerts=ALERTS,
        students=students,
        totals=dashboard_totals(),
        q=request.args.get("q", ""),
        population=population,
        flag=flag,
        populations=populations,
    )


@app.route("/faculty/students/<student_id>")
@roles_required(*FACULTY_ROLES)
def student_detail(student_id):
    student = student_by_id(student_id)
    if student is None:
        return render_template("forbidden.html"), 404
    return render_template(
        "student_detail.html",
        student=student,
        alerts=alerts_for(student_id),
    )


@app.route("/faculty/alerts/<alert_id>/review", methods=["POST"])
@roles_required(*FACULTY_ROLES)
def review_alert(alert_id):
    for alert in ALERTS:
        if alert["id"] == alert_id:
            alert["status"] = "reviewed"
            flash("Alert marked reviewed.")
            break
    return redirect(url_for("faculty_home"))


@app.route("/admin")
@roles_required(*ADMIN_ROLES)
def admin_home():
    return render_template(
        "admin_home.html",
        totals=dashboard_totals(),
        user_count=len(USERS),
    )


@app.route("/users", methods=["GET", "POST"])
@roles_required(*ADMIN_ROLES)
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
                    "role": request.form.get("role") or "student",
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
@roles_required(*STUDENT_ROLES)
def surveys():
    return survey_page("surveys.html")


@app.route("/applicant.html")
@app.route("/applicant")
@roles_required(*STUDENT_ROLES)
def applicant():
    return survey_page(
        "survey_form.html",
        title="Applicant Survey",
        survey_key="applicant",
    )


@app.route("/current-student.html")
@app.route("/current-student")
@roles_required(*STUDENT_ROLES)
def current_student():
    return survey_page(
        "survey_form.html",
        title="Current Student Surveys",
        survey_key="current",
    )


@app.route("/near-graduation.html")
@app.route("/near-graduation")
@roles_required(*STUDENT_ROLES)
def near_graduation():
    return survey_page(
        "survey_form.html",
        title="Near Graduation Survey",
        survey_key="near",
    )


@app.route("/after-graduation.html")
@app.route("/after-graduation")
@roles_required(*STUDENT_ROLES)
def after_graduation():
    return survey_page(
        "survey_form.html",
        title="After Graduation Survey",
        survey_key="after",
    )


if __name__ == "__main__":
    app.run(debug=True)
