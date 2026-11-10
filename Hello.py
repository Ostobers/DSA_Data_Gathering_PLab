from flask import Flask, render_template, url_for
from flask_sqlalchemy import SQLAlchemy 
from flask_login import UserMixin
from flask_wtf import FlaskForm
from wtforms import StringField, PasswordField, SubmitField
from wtforms.validators import InputRequired, Length, ValidationError
from flask_bcrypt import Bcrypt 

app = Flask(__name__)
bcrypt = Bcrypt(app)

'''
#below instantiates the database (I believe)
db = SQLAlchemy(app)

#below connects the app file to the database which is database.db
app.config['SQLALCHEMY_DATABASE_URI'] = 'sqlite:///database.db'


#app.config['SECRET_KEY'] = 'DONOTSHARE'

class User(db.Model, UserMixin):
	id = db.Column(db.Integer, primary_key=True)
	username = db.Column(db.String(20), nullable=False, unique=True)
#The password is 80 characters long for hashing!
	password = db.Column(db.String(80), nullable=False)
'''
app.config['SECRET_KEY'] = 'DONOTSHARE'


class RegisterForm(FlaskForm):
	username = StringField(validators=[InputRequired(), Length(
		min=4, max=20)], render_kw={"placeholder": "Username"})
	
	password = StringField(validators=[InputRequired(), Length(
		min=4, max=20)], render_kw={"placeholder": "Password"})
	
	submit = SubmitField("Register")
'''
	def validate_username(self, username):
				existing_user_username = User.query.filterby(
			username=username.data).first()

		if existing_user_username:
			raise ValidationError(
				"That Username already exists. Please choose a different one.")
'''
class LoginForm(FlaskForm):
	username = StringField(validators=[InputRequired(), Length(
		min=4, max=20)], render_kw={"placeholder": "Username"})
	
	password = StringField(validators=[InputRequired(), Length(
		min=4, max=20)], render_kw={"placeholder": "Password"})
	
	submit = SubmitField("Login")


@app.route('/')
def index():
	return render_template('index.html')
  
@app.route('/login', methods=['GET', 'POST'])
def login():

	form = LoginForm()
#Line below is supposed to make the password hashed instead of plaintext
#don't know why it isn't working
	#hashed_password = bcrypt.generate_password_hash(form.password.data)


	return render_template('login.html',form=form)

@app.route('/register', methods=['GET', 'POST'])
def register():

	form = RegisterForm()
#Line below is supposed to make the password hashed instead of plaintext
#don't know why it isn't working
	#hashed_password = bcrypt.generate_password_hash(form.password.data)

	return render_template('register.html', form=form)

'''
The below links need to be added to the templates folder in order for it to with this 
specific flask app

@app.route('/after-graduation.html')
def afterGrad():
	return render_template('after-graduation.html')

@app.route('/applicant.html')
def applicant():
	return render_template('applicant.html')

@app.route('/current-student.html')
def currentStudent():
	return render_template('after-graduation.html')

@app.route('/near-graduation.html')
def nearGrad():
	return render_template('near-graduation.html')
'''

if __name__ == '__main__':
	app.run(debug=True)