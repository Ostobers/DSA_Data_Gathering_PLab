// All survey content lives here. Edit text/options here; survey.js draws the forms.
const Y=['Yes','No'], YNU=['Yes','No','Unsure'];
const C4=['1 = No comfort','2 = Little comfort','3 = Comfortable','4 = Very comfortable'];
const K=(id,t,type,o,x)=>Object.assign({id,t,type,o},x);
const S=(i,t,o,x)=>K(i,t,'single',o,x), M=(i,t,o,x)=>K(i,t,'multi',o,x),
 T=(i,t,x)=>K(i,t,'text',0,x), L=(i,t,x)=>K(i,t,'long',0,x), N=(i,t,x)=>K(i,t,'number',0,x),
 E=(i,t,x)=>K(i,t,'email',0,x), D=(i,t,o,x)=>K(i,t,'dropdown',o,x),
 G=(i,t,rows,o,x)=>K(i,t,'grid',o,Object.assign({rows},x)),
 R=(i,t,src,o,x)=>K(i,t,'each',o,Object.assign({src},x)),
 REP=(i,t,fields,x)=>K(i,t,'repeat',fields,x);
const OPT={req:false};

const SURVEYS={};

SURVEYS.applicant={title:'Applicant Survey',intro:'Please answer the questions below.',forms:[{
 name:'Applicant Survey',
 shortIds:['A-1','A-2','A-3','A-6','A-7','A-8','B-1','B-2','B-4','B-5','B-6','B-7','B-8','B-10','B-11'],
 qs:[
 S('A-1','What is your main reason for pursuing the Data & Analytics program?',['Career Pivot','Career advancement','Research','Other'],{sec:'Part A: Goals, Motivations, and Program Fit',ph:'Could you specify'}),
 M('A-2','Which data science tracks or applications areas interest you most?',['Predictive modeling','Data analytics','Data engineering','AI/ML']),
 M('A-3','What skills are you looking to build in this program?',['Analytical','Geographic Information Systems','System Design','Programming','AI prompting']),
 S('A-4','Are you comfortable with using AI?',Y),
 S('A-5','How often do you use AI?',['1 = Not often','2 = Occasionally','3 = Often','4 = Every day']),
 S('A-6','Are you currently employed?',Y),
 M('A-7','What sector are you working in?',['IT','Healthcare','Real Estate','Retail','Education','Government'],{show:a=>a['A-6']=='Yes'}),
 S('A-8','Are you full time or part time?',['Full time','Part time'],{show:a=>a['A-6']=='Yes'}),
 S('A-9','Would you like to know the resources Buffalo State campus provides?',Y),
 D('B-1','What kind of bachelors did you graduate with?',['Computer Science','Information Technology / Information Systems','Mathematics','Statistics','Economics','Business / Management','Engineering','Natural Science (Biology, Chemistry, Physics)','Social Science','Arts / Humanities','Other'],{sec:'Part B: Academic and Technical Preparation',note:'Placeholder list: replace with the final list of bachelors.'}),
 M('B-2','Where would you say you focused your studies in your undergrad?',['Math','Business','Economics','Science','Art']),
 S('B-3','Do you think this focus was well spent?',Y,{why:'Why or why not?'}),
 M('B-4','What college-level math courses have you completed?',['Calculus','Linear Algebra','Statistics','Discrete Math'],{sec:'Math background'}),
 R('B-5','How comfortable are you with ___ ?','B-4',C4,{note:'One question appears for each course selected above.',show:a=>a['B-4'].length>0}),
 S('B-6','Do you have any coding experiences?',Y),
 M('B-7','What programming languages are you familiar with? (select all that apply)',['Python','R','SQL','Java','Javascript','C++/C#/C','HTML/CSS'],{show:a=>a['B-6']=='Yes'}),
 S('B-8','How confident are you in your coding skills?',['1 = Not confident','2 = Slightly confident','3 = Confident','4 = Very confident']),
 S('B-9','How many completed coding projects do you have?',['1','A couple','Many']),
 S('B-10','Are you familiar with databases?',Y),
 M('B-11','What database softwares are you familiar with?',['Postgresql','Microsoft SQL Server','Oracle SQL Developer','MongoDB','SQLite'],{show:a=>a['B-10']=='Yes'}),
 S('B-12','How comfortable are you with command line/terminal?',C4),
 S('B-13','How comfortable are you with git/github?',C4),
 S('B-14','How comfortable are you with Jupyter Notebooks?',C4),
 S('B-15','Are you familiar with IDEs?',Y),
 S('B-16','What is your preferred IDE?',['Visual Studio Code','Cursor','Other'],{show:a=>a['B-15']=='Yes'})
]}]};

const NOSEARCH=['I plan to continue my education (PhD or other program)','I am not seeking work after graduation'];
SURVEYS.near={title:'Near Graduation Survey',intro:'',forms:[{
 name:'Near-Graduation Check-in',
 shortIds:['A1','A2','A3','A4','A7','A8','A9','A10'],
 qs:[
 S('A1','What is your expected graduation term?',['Fall 2026','Spring 2027','Summer 2027','Fall 2027','Later than Fall 2027']),
 S('A2','What best describes your current status?',['I have accepted a job offer','I am actively searching for a job or internship','I plan to search but have not started','I plan to continue my education (PhD or other program)','I am not seeking work after graduation']),
 S('A3','How would you rate your job-search progress so far?',['1 = No progress','2 = Very little progress','3 = Some progress','4 = Good progress','5 = Excellent progress / done'],{show:a=>!NOSEARCH.includes(a.A2)}),
 S('A4','Which stage are you at right now?',['Not started','Preparing materials (resume, LinkedIn, portfolio)','Applying','Interviewing','Have an offer'],{show:a=>!NOSEARCH.includes(a.A2)}),
 S('A5','What type of role are you targeting?',['Data scientist','Data analyst','Data or machine learning engineer','Database engineer','Business intelligence / business analyst','Research scientist','Statistician / quantitative analyst','Other','Not sure yet'],{show:a=>!NOSEARCH.includes(a.A2)}),
 S('A6','How confident are you that you are ready for a data-science job?',['1 = Not at all confident','2 = Slightly confident','3 = Moderately confident','4 = Very confident','5 = Extremely confident'],{show:a=>!NOSEARCH.includes(a.A2)}),
 M('A7','What are the biggest barriers to your job search right now?',['Technical skills','Projects or portfolio','Networking and connections','Interviewing','Location or relocation','Work authorization or visa','Not enough time','Other','None'],{max:2,ex:['None'],show:a=>!NOSEARCH.includes(a.A2)}),
 S('A8','Would you like career or advising help before you graduate?',Y,{show:a=>!NOSEARCH.includes(a.A2)}),
 S('A9','May we contact you after graduation to ask about your career?',Y),
 E('A10','What personal email should we use after you graduate?',{show:a=>a.A9=='Yes'}),
 L('A11','Anything else we should know?',OPT),
 L('A12','What method(s) are you using in the course of your job search?',Object.assign({show:a=>a.A2=='I am actively searching for a job or internship'},OPT))
]}]};

const EMP=['Employed full-time','Employed part-time','Self-employed / freelance'];
SURVEYS.after={title:'After Graduation Survey',intro:'This takes about 3 minutes. Your answers help us improve the program for future students. Salary and comment questions are optional. (Intended to be sent at 3, 6, and 12 months.)',forms:[{
 name:'Post-graduation Survey',
 shortIds:['B1','B2','B3','B4','B6','B9','B10','B11'],
 qs:[
 S('B1','What term did you graduate?',['Fall 2026','Spring 2027','Summer 2027','Fall 2027','Other']),
 S('B2','What is your current status?',['Employed full-time','Employed part-time','Self-employed / freelance','Seeking employment','Continuing education','Not seeking employment']),
 N('B3','How many months after graduation did you start your job?',{note:'Enter 0 if you started before graduating.',show:a=>EMP.includes(a.B2)}),
 T('B4','What is your job title?',{note:'Please give a general title (for example "data analyst") rather than your exact title.',show:a=>EMP.includes(a.B2)}),
 D('B5','What industry do you work in?',['Technology / software','Finance, banking, or insurance','Healthcare, pharma, or biotech','Government / public sector','Education or nonprofit','Consulting','Retail, e-commerce, or consumer goods','Manufacturing or energy','Media, entertainment, or sports','Other'],{show:a=>EMP.includes(a.B2)}),
 S('B6','Does your job use data-science skills?',['Yes, mostly','Partly','No'],{show:a=>EMP.includes(a.B2)}),
 S('B7','How did you find this job?',['University career services','Professional or personal network','Online job posting','Internship converted to full-time','Faculty or program referral','Recruiter','Other'],{show:a=>EMP.includes(a.B2)}),
 S('B8','What is your approximate annual salary?',['Under $60,000','$60,000 to $79,999','$80,000 to $99,999','$100,000 to $119,999','$120,000 to $149,999','$150,000 or more','Prefer not to say'],Object.assign({show:a=>EMP.includes(a.B2)},OPT)),
 N('B9','How many months have you been searching?',{show:a=>a.B2=='Seeking employment'}),
 M('B10','What is the main barrier to finding a job?',['Not enough interviews','Skills gaps','Lack of experience','Location','Work authorization or visa','Job market conditions','Lack of industry connections','Other'],{note:'You may select more than one.',show:a=>a.B2=='Seeking employment'}),
 S('B11','How well did the program prepare you for employment?',['1 = Not at all prepared','2 = Slightly prepared','3 = Moderately prepared','4 = Well prepared','5 = Extremely well prepared']),
 M('B12','Which skills do you wish you had developed more?',['Programming / software engineering','Statistics or machine learning depth','Deep learning / AI','Data engineering, SQL, or cloud tools','Data visualization and communication','Domain or business knowledge','Teamwork and project management','Interviewing and job-search skills','Portfolio projects','Other'],{max:3}),
 S('B13','How likely are you to recommend this program to a prospective student?',['1 = Very unlikely','2 = Unlikely','3 = Neutral','4 = Likely','5 = Very likely']),
 L('B14','Any other feedback about the program or your career path?',OPT)
]}]};

const P=Object.assign;
const SCALE5=['1 = Very low','2 = Low','3 = Moderate','4 = High','5 = Very high'];
const PREP=['Programming','Databases and SQL','Mathematics','Statistics','Data analysis','Other'];
const CAREER_SUPPORT=['Identifying roles or employers','Opportunity listings','Resume review','Portfolio review','Interview or assessment practice','Networking guidance','Discussing an offer','Fitting an internship with coursework','Unsure','Other','None'];
const PREREQUISITE_FIELDS=[
 T('activity','Prerequisite or preparation activity'),
 S('status','Status',['Completed','In progress','Not started']),
 S('help','Do you need help with this activity?',YNU)
];
const SEMESTER_COURSE_FIELDS=[
 T('course','Course'),
 S('clarity','How clear is this course’s place in your program plan?',['Very unclear','Somewhat unclear','Neither','Somewhat clear','Very clear']),
 S('prepared','How prepared are you for its expected starting knowledge?',['Not at all','Slightly','Moderately','Well','Very well','Unsure what is expected']),
 M('review','Which areas need review?',['Programming','SQL and databases','Statistics','Linear algebra or calculus','Data cleaning','Machine learning','Development tools','Technical communication','Other','Unsure','None'],{ex:['Unsure','None'],oo:1}),
 S('clear','Were expected skills and prerequisites clear before enrollment?',['Yes','Partly','No','I did not review them']),
 M('preparation','What preparation would help?',['Expected-skill list','Refreshers','Exercises','Workshop','Tutoring or study group','Instructor or adviser discussion','Other','None'],{ex:['None'],oo:1})
];
const PREVIOUS_GOAL_FIELDS=[
 T('goal','Saved goal'),
 S('status','Status',['Completed','Partly completed','In progress','Not started','No longer relevant']),
 L('context','What helped or prevented progress?',OPT)
];
const PRIOR_ACTION_FIELDS=[
 T('action','Earlier action item'),
 S('status','Status',['Completed','In progress','Not started','No longer applicable']),
 S('clarity','Was the action clear?',['Yes','Partly','No']),
 L('obstacle','What obstacle affected this action?',OPT),
 S('help','Is further help needed?',YNU)
];
const SHORT_COURSE_REVIEW_FIELDS=[
 T('course','Course'),
 S('prepared','How well did your prior knowledge prepare you?',['Not at all','Slightly','Moderately','Well','Very well']),
 S('preparation','Would a prerequisite or preparation requirement have helped?',['Required prerequisite course','Refresher, workshop, or module','Both','Existing requirements were sufficient','No requirement needed','Unsure']),
 M('preparation_skills','Which skills needed more preparation?',['Python','Other programming','SQL or databases','Statistics','Linear algebra','Calculus','Data cleaning','Visualization','Machine learning','Development tools','Technical communication','Other'],{show:a=>['Required prerequisite course','Refresher, workshop, or module','Both'].includes(a.preparation),oo:1}),
 L('preparation_activity','Name a recommended course or preparation activity.',P({show:a=>['Required prerequisite course','Refresher, workshop, or module','Both'].includes(a.preparation)},OPT)),
 S('preparation_communicated','Were these preparation needs communicated before enrollment?',['Yes','Partly','No','Unsure'],{show:a=>['Required prerequisite course','Refresher, workshop, or module','Both'].includes(a.preparation)}),
 M('connections','How did this course connect with other courses?',['Built on earlier work','Useful reinforcement','Repetition without added depth','Assumed untaught knowledge','Would be better earlier','Would be better later','Unclear connections','Insufficient experience to judge']),
 L('connection_context','Identify a topic, overlapping course, or sequence change.',OPT),
 G('development','How much did this course develop each area?',['Technical knowledge','Realistic open-ended problem solving','Working with messy or incomplete data','Nontechnical communication','Collaboration','Responsible data practices','Independent tool learning'],['Not at all','A little','Somewhat','Quite a bit','A great deal','Not applicable']),
 S('portfolio','Did the course produce work you could show an employer?',['Ready to share','With revision','Possibly, with guidance','No','Unsure']),
 L('portfolio_context','What would make the work portfolio-ready?',OPT),
 M('improvements','What would most improve the course’s learning and career value?',['Preparation resources','Realistic data or problems','Relevant tools','Underlying concepts','Open-ended projects','Documentation or presentation guidance','Nontechnical communication','Teamwork with shared tools','Industry examples','Course coordination','Assignment and goal alignment','Other','No major changes'],{max:3,ex:['No major changes'],oo:1}),
 L('preserve','What should the department preserve about this course?',OPT),
 L('change','What should the department change about this course?',OPT)
];
const LONG_COURSE_REVIEW_FIELDS=[
 T('course','Course'),
 S('prepared','How well did your prior knowledge prepare you?',['Not at all','Slightly','Moderately','Well','Very well']),
 M('missing_skills','Which necessary starting skills were insufficiently developed?',['Programming','SQL or databases','Statistics','Linear algebra','Calculus','Data cleaning or analysis','Machine learning','Development tools','Technical communication','Other','No substantial gaps'],{ex:['No substantial gaps'],oo:1}),
 S('preparation','Would different preparation requirements have helped?',['Prerequisite course','Refresher module','Both','Clearer expected skills','Existing requirements were sufficient','No requirement needed','Unsure']),
 L('preparation_detail','Describe the specific prior content, a suggested course or activity, and when the gap became apparent.',P({show:a=>['Prerequisite course','Refresher module','Both','Clearer expected skills'].includes(a.preparation)},OPT)),
 S('prerequisite_quality','If you completed listed prerequisites, did they prepare you adequately?',['Fully','Mostly','Partly','Not at all','Did not complete','None listed','Unsure']),
 L('prerequisite_gap','What was missing?',P({show:a=>['Partly','Not at all'].includes(a.prerequisite_quality)},OPT)),
 M('connections','How did this course connect with the curriculum?',['Built on earlier work','Useful reinforcement','Repetition without depth','Assumed untaught material','Unclear connections','Would be better earlier','Would be better later','Insufficient experience'],{oo:1}),
 L('connection_context','Identify related courses or topics and a suggested change.',OPT),
 S('depth','How appropriate was the depth of coverage?',['Too introductory','Somewhat introductory','Appropriate','Somewhat advanced','Too advanced','Varied by topic']),
 L('depth_context','Which topics needed more or less depth?',OPT),
 S('assignment_alignment','How well did assignments demonstrate the stated learning goals?',['Not at all','Slightly','Moderately','Well','Very well','Unsure']),
 L('assignment_context','Describe an effective assignment or a mismatch.',OPT),
 L('tools','Which tools or methods did you use meaningfully?',OPT),
 G('development','How much did the course develop each area?',['Technical knowledge','Open-ended problem solving','Working with messy data','Method selection and evaluation','Reproducibility','Documenting decisions','Nontechnical communication','Collaboration','Ethics, privacy, and limitations','Independent tool learning'],['Not at all','A little','Somewhat','Quite a bit','A great deal','Not applicable']),
 S('realism','How closely did assignments resemble employment or research problems?',['Not at all','Slightly','Moderately','Closely','Very closely','Unsure']),
 L('realism_context','How could the assignments be more realistic?',OPT),
 S('portfolio','Did you produce evidence of your skills?',['Ready to share','With revision','Possibly with guidance','No','Unsure']),
 L('portfolio_context','What help would make it portfolio-ready?',OPT),
 L('preserve','What should be preserved?',OPT),
 L('change','What should change?',OPT),
 L('priority','What is the highest-priority change and expected benefit?',OPT)
];
SURVEYS.current={
 title:'Current Student Surveys',
 intro:'Choose the check-in or milestone survey that matches what you need to share today. Milestone surveys offer short and expanded versions.',
 forms:[{
 name:'Recurring Student Check-in',
 singleVersion:true,
 intro:'Complete this check-in periodically during the semester. It takes less than three minutes and helps faculty notice changes over time and identify requests for support.',
 qs:[
 S('C1','How confident do you feel about your knowledge and abilities in Data Science and Analytics?',SCALE5,{sec:'Current experience'}),
 S('C2','How strongly do you feel that you belong in the DSA program?',SCALE5),
 S('C3','How satisfied are you with your overall experience in the DSA program?',SCALE5),
 S('C4','How much pressure are you currently experiencing from your academic workload?',SCALE5),
 S('C5','Would you like academic advising or additional support from a faculty member?',Y),
 S('C6','How much are financial concerns affecting your ability to continue and succeed in the program?',SCALE5),
 S('C7','How would you rate your progress toward securing an internship or job related to Data Science and Analytics?',SCALE5,{sec:'Career progress'}),
 S('C7a','Which stage best describes your current internship or job search?',['Not currently searching','Exploring roles or industries','Preparing application materials','Identifying opportunities','Submitting applications','Interviewing or completing assessments','Considering an offer','Accepted an offer','Started an internship or job']),
 L('C8','Is there anything else you would like to share about your academic experience, challenges, or support needs?',OPT)
 ]},{
 name:'Beginning of the Program',
 short:{intro:'Complete this during the first two weeks of the program. Help us understand your starting point, goals, and support needs. Estimated time: 4–5 minutes.',qs:[
 T('S1-1','What was your primary undergraduate field of study?',{note:'You may type "Other" or "Prefer not to answer".'}),
 G('S1-2','How much experience do you have in each area?',['Python programming','SQL and relational databases','Statistics and probability','Linear algebra','Data cleaning and analysis','Data visualization'],['No experience','Introductory exposure','Can complete basic tasks independently','Can complete advanced tasks independently']),
 S('S1-3','Have you been told that you need to complete any prerequisites or preparation activities?',YNU),
 T('S1-3a','Which remain incomplete?',P({show:a=>a['S1-3']=='Yes'},OPT)),
 M('S1-4','In which areas would you most benefit from introductory support?',['Programming','Databases and SQL','Mathematics','Statistics','Using development tools','Academic writing or communicating results','Study strategies or time management','Unsure','Other','No introductory support needed'],{ex:['Unsure','No introductory support needed'],oo:1}),
 M('S1-5','What are your main goals for completing this program?',['Begin a career in data science or analytics','Advance in my current career','Change careers','Prepare for further study or research','Apply data skills within another field','Develop technical skills','Explore career possibilities','Other'],{max:3,oo:1}),
 M('S1-6','Which career areas currently interest you?',['Data analysis or business intelligence','Data science or machine learning','Data engineering or database work','Research','Applying data science in a specific industry','Still exploring','Other'],{oo:1}),
 T('S1-6a','Specify an industry or role.',OPT),
 L('S1-7','What do you most want to learn or accomplish during your first semester?',OPT),
 M('S1-8','Which resources would help you get started?',['Preparation materials or refresher exercises','Tutoring or academic support','Course-planning guidance','Software and tool setup','Career information','Classmates or a study group','University support-service information','Unsure','Other','None at this time'],{ex:['Unsure','None at this time'],oo:1})
 ]},
 long:{intro:'Complete this during the first two weeks of the program. Your responses help the DSA MS program understand your starting point and provide relevant academic and career support. You may skip optional questions. Estimated time: 12–15 minutes.',qs:[
 T('L1-1','What was your primary undergraduate field of study?',{sec:'A. Background'}),
 S('L1-2','Have you completed other relevant degrees, certificates, or substantial training?',Y),
 T('L1-2a','Describe subject and type.',P({show:a=>a['L1-2']=='Yes'},OPT)),
 M('L1-3','What relevant experience do you bring?',['Data-analysis coursework','Data/technology employment','Internship','Research','Personal projects','Community projects','No experience','Other'],{ex:['No experience'],oo:1}),
 L('L1-3a','Describe one experience representing your abilities.',OPT),
 G('L1-4','Rate your experience in each area.',['Python','SQL/databases','Statistics/probability','Linear algebra','Calculus','Data cleaning/analysis','Visualization','Machine learning','Git/version control','Command-line/development environments','Technical communication'],['No experience','Some exposure','Basic tasks independently','Advanced tasks independently','Unsure'],{sec:'B. Preparation'}),
 M('L1-5','Which activities have you completed?',['Data-processing program','SQL query','Cleaning missing/inconsistent data','Statistical analysis','Training/evaluating a model','Communicating through visualization','Team project with shared tools','Explaining findings to a nontechnical audience','None'],{ex:['None']}),
 S('L1-6','Have you been assigned prerequisites or preparation activities?',YNU),
 REP('L1-6-items','Assigned preparation activities',PREREQUISITE_FIELDS,{show:a=>a['L1-6']=='Yes',itemLabel:'Activity',addLabel:'Add another activity'}),
 M('L1-7','Which subjects need additional preparation?',['Python','SQL/databases','Statistics/probability','Linear algebra','Calculus','Data cleaning/analysis','Visualization','Machine learning','Git/version control','Command-line/development environments','Technical communication','None','Unsure'],{ex:['None','Unsure']}),
 M('L1-8','Which preparation formats would help?',['Tutorials','Workshops','Exercises with solutions','Tutoring','Peer groups','Prerequisite course','Faculty office hours','Unsure','Other'],{ex:['Unsure'],oo:1}),
 M('L1-9','Main reasons for the degree?',['Enter data career','Advance career','Change career','Doctoral study/research','Apply data in another field','Technical expertise','Explore careers','Other'],{max:3,oo:1,sec:'C. Goals and expectations'}),
 M('L1-10','Roles of interest?',['Data analyst','Business intelligence analyst','Data scientist','Machine-learning engineer','Data engineer','Database role','Research','Other','Still exploring'],{oo:1}),
 L('L1-11','Industries or application areas of interest?',OPT),
 M('L1-12','What should the program help you develop?',['Mathematics/statistics','Programming','Data management','Machine learning','Realistic problem experience','Research','Portfolio','Communication','Teamwork','Professional connections','Internship opportunities','Career/job-search skills'],{max:5}),
 L('L1-13','What would make your first year successful?',OPT),
 S('L1-14','Are requirements, sequencing, or career possibilities unclear?',YNU),
 L('L1-14a','What needs clarification?',P({show:a=>a['L1-14']=='Yes'},OPT)),
 G('L1-15','Do you have reliable access to needed resources?',['Suitable computer','Internet','Software/computing environments','Study space','Reserved coursework time'],['Yes','Sometimes','No','Unsure'],{sec:'D. Access and support'}),
 M('L1-16','What circumstances should the program consider in planning?',['Employment','Caregiving','Commuting','Scheduling','Financial constraints','Technology access','Other','Prefer not to answer','None'],P({ex:['Prefer not to answer','None'],oo:1},OPT)),
 M('L1-17','What support would help?',['Preparation','Course planning','Software setup','Study strategies','Peer connections','Career exploration','University resources','Other','None'],{ex:['None'],oo:1}),
 S('L1-18','Would you like follow-up?',Y),
 T('L1-18a','Topic',P({show:a=>a['L1-18']=='Yes'},OPT))
 ]}
},{
 name:'Beginning of a Semester',
 short:{intro:'Complete this during the first two weeks of the semester. Help us understand your plans and any support you may need. Estimated time: 3–4 minutes.',qs:[
 S('S2-1','Which semester of the DSA MS program are you beginning?',['First','Second','Third','Fourth or later'],{sec:'Semester plan'}),
 L('S2-2','Which DSA courses are you taking this semester?',{note:'List each course, or enter "Enrollment not finalized."'}),
 S('S2-3','Are there prerequisites or foundational skills you still need to strengthen for these courses?',YNU),
 M('S2-3a','Which areas need strengthening?',['Programming','Databases and SQL','Mathematics','Statistics','Data analysis','Other','I need help identifying the gaps'],{show:a=>a['S2-3']!='No',oo:1}),
 M('S2-4','What are your main goals for this semester?',['Strengthen foundational skills','Complete planned courses','Complete a portfolio project','Gain research experience','Explore career options','Prepare internship applications','Apply for internships','Prepare job applications','Apply for jobs','Other'],{max:3,oo:1}),
 S('S2-5','Approximately how much time can you usually reserve for coursework outside scheduled classes each week?',['Fewer than 5 hours','5–9 hours','10–14 hours','15–19 hours','20 or more hours','Unsure']),
 M('S2-6','Are any commitments likely to affect your participation this semester?',['Paid work','Caregiving or family responsibilities','Transportation or commuting','Scheduling conflicts','Reliable computer or internet access','Other commitments','Prefer not to answer','None anticipated'],P({ex:['Prefer not to answer','None anticipated'],oo:1},OPT)),
 S('S2-7','Has your career direction changed since your last profile update?',['Yes','No','I am still exploring'],{sec:'Goals and support'}),
 L('S2-7a','Describe your current direction.',P({show:a=>a['S2-7']=='Yes'},OPT)),
 M('S2-8','What support would help you accomplish your semester goals?',['Academic preparation or tutoring','Course or program planning','Project or research guidance','Career exploration','Resume, portfolio, or interview preparation','Internship or job-search guidance','University support referrals','Unsure','Other','None at this time'],{ex:['Unsure','None at this time'],oo:1})
 ]},
 long:{intro:'Complete this during the first two weeks of the semester. Update your plan, preparation needs for each course, goals, and support needs. Estimated time: 10–15 minutes for about three courses.',qs:[
 S('L2-1','Which semester of the DSA MS program are you beginning?',['First','Second','Third','Fourth or later'],{sec:'A. Semester plan'}),
 REP('L2-courses','Courses and preparation',SEMESTER_COURSE_FIELDS,{itemLabel:'Course',addLabel:'Add another course'}),
 M('L2-4','Do you have concerns about your course sequence?',['Needed course unavailable','Schedule conflict','Unsure what comes next','Taking a course before I am prepared','Repeated content','Elective guidance needed','Other','None'],{ex:['None'],oo:1}),
 M('L2-9','What are your three highest priorities this semester?',['Courses','Foundational skills','Portfolio','Research','Teamwork or communication','Career exploration','Internship preparation','Internship applications','Job preparation','Job applications','Other'],{max:3,oo:1,sec:'C. Goals and progress'}),
 S('L2-10','Do you have saved goals from a previous update? ',Y),
 REP('L2-goals','Progress on previous goals',PREVIOUS_GOAL_FIELDS,{show:a=>a['L2-10']=='Yes',itemLabel:'Goal',addLabel:'Add another goal'}),
 S('L2-11','Are you planning an applied experience this semester?',['Yes','No','Exploring']),
 L('L2-11a','Describe the activity, desired skills, and any help needed finding or defining it.',P({show:a=>a['L2-11']!='No'},OPT)),
 S('L2-12','Has your career direction changed?',['Yes','No','Still exploring']),
 L('L2-12a','Describe your updated roles or industries of interest.',P({show:a=>a['L2-12']=='Yes'},OPT)),
 S('L2-13','How many hours per week can you reserve for coursework outside class?',['Fewer than 5','5–9','10–14','15–19','20–24','25 or more','Unsure'],{sec:'D. Time and support'}),
 M('L2-14','Which circumstances may affect your plans?',['Employment','Caregiving','Commuting','Scheduling','Technology','Finances','Other','Prefer not to answer','None'],P({ex:['Prefer not to answer','None'],oo:1},OPT)),
 S('L2-15','Do you have the required software, equipment, and access?',['Yes','Partly','No','Unsure']),
 L('L2-15a','What is missing?',P({show:a=>['Partly','No','Unsure'].includes(a['L2-15'])},OPT)),
 M('L2-16','What support would be useful?',['Preparation or tutoring','Course planning','Projects or research','Career planning','Portfolio','Internship or job search','Study strategies','Referrals','Other','None'],{ex:['None'],oo:1}),
 L('L2-17','What decision or concern should an adviser address early?',OPT),
 S('L2-18','Would you like follow-up?',Y),
 L('L2-18a','What would you like help with?',P({show:a=>a['L2-18']=='Yes'},OPT))
 ]}
},{
 name:'Advising Milestone',
 short:{intro:'Tell your adviser what you would like to address so the discussion can focus on your priorities. Estimated time: about 3 minutes.',qs:[
 S('S3-1','What is the main reason for this advising update?',['Routine academic planning','Choosing or changing courses','Reviewing prerequisites','Difficulty in a course','Project or research planning','Career direction','Considering an enrollment change','Follow-up on earlier advising','Other'],{sec:'Advising priorities'}),
 M('S3-2','Which topics would you like to discuss?',['Course selection or sequencing','Academic progress','Foundational skill gaps','Study strategies or academic resources','Project or research opportunities','Internship or career preparation','Commitments affecting study','University support resources','Other'],{oo:1}),
 S('S3-3','Is anything preventing you from following your current academic plan?',YNU),
 L('S3-3a','Describe the issue, sharing only what you are comfortable providing.',P({show:a=>a['S3-3']!='No'},OPT)),
 S('S3-4','If you previously agreed on action items with an adviser, what is their status?',['All completed','Some completed','In progress','Not started','Need clarification','No previous action items']),
 L('S3-4a','Which item needs discussion or support?',P({show:a=>!['All completed','No previous action items'].includes(a['S3-4'])},OPT)),
 L('S3-5','What decision or outcome would make this advising discussion useful to you?',OPT),
 S('S3-6','When would you like a response or meeting?',['Within the next few business days','Within the next two weeks','At my next scheduled advising meeting','No additional meeting requested']),
 L('S3-7','Is there anything else your adviser should know beforehand?',OPT)
 ]},
 long:{intro:'Prepare for an advising discussion and review earlier actions. Share only personal context you are comfortable providing. Estimated time: 8–12 minutes before the meeting. Use the separate Advising Follow-up afterward.',qs:[
 M('L3-1','What prompted this update?',['Academic planning','Course selection','Prerequisites','Course difficulty','Project or research','Career planning','Internship planning','Enrollment change','Earlier-discussion follow-up','Other'],{sec:'A. Before the discussion',oo:1}),
 L('L3-2','What is your most important priority?',OPT),
 M('L3-3','Which decisions need help?',['Courses or electives','Course load','Preparation gaps','Academic progress','Project or research direction','Career connections','Internship fit','Continuing, pausing, or changing enrollment','Other','None'],{ex:['None'],oo:1}),
 S('L3-4','Is your academic plan achievable now?',['Yes','Partly','No','Unsure']),
 L('L3-4a','What needs adjustment?',P({show:a=>a['L3-4']!='Yes'},OPT)),
 M('L3-5','What barriers are affecting progress?',['Foundational skills','Course material','Unclear requirements','Availability or sequencing','Time','Technology','Opportunity access','Personal circumstances to discuss privately','Other','None'],{ex:['None'],oo:1}),
 M('L3-6','Which resources have you already tried?',['Instructor office hours','Adviser','Tutoring','Study group','Tutorials or practice','Career services','University services','Other','None'],{ex:['None'],oo:1}),
 L('L3-6a','What helped and what remains unresolved?',OPT),
 S('L3-7','Were action items agreed previously?',['Yes','No','Unsure','No previous discussion'],{sec:'B. Earlier actions'}),
 REP('L3-actions','Earlier action-item status',PRIOR_ACTION_FIELDS,{show:a=>a['L3-7']=='Yes',itemLabel:'Action item',addLabel:'Add another action item'}),
 S('L3-8','Did previous advising help you move forward?',['Not at all','A little','Somewhat','Quite a bit','A great deal','Not applicable']),
 L('L3-8a','What was useful or missing?',OPT),
 M('L3-9','What would make this discussion successful?',['Course plan','Skill-development plan','Referral','Project or research step','Career direction','Barrier-resolution plan','Requirements clarification','Other'],{sec:'C. Desired outcome',oo:1}),
 S('L3-10','When would you like a response?',['Within a few business days','Within two weeks','At the next scheduled meeting','No extra meeting']),
 L('L3-11','Is there anything else your adviser should know?',OPT)
 ]}
},{
 name:'Advising Follow-up',
 singleVersion:true,
 intro:'Complete this short follow-up after an advising discussion. Estimated time: 3–5 minutes.',
 qs:[
 S('L3-12','Were your main questions addressed?',['Fully','Mostly','Partly','Not at all'],{sec:'After the discussion'}),
 S('L3-13','How clear are your next steps?',['Very unclear','Somewhat unclear','Neither','Somewhat clear','Very clear']),
 S('L3-14','Were the next steps realistic?',['Yes','Partly','No','No actions agreed']),
 S('L3-15','Is anything unresolved?',Y),
 L('L3-15a','Describe what remains unresolved.',P({show:a=>a['L3-15']=='Yes'},OPT)),
 M('L3-16','What could improve advising?',['Scheduling','Pre-meeting information','Continuity','Course guidance','Career guidance','Clear actions','Follow-up','Referrals','Other','No change needed'],{ex:['No change needed'],oo:1})
 ]
},{
 name:'Internship or Job-Search Milestone',
 short:{intro:'Complete this when beginning a search, applying, interviewing, receiving an offer, or starting an opportunity. Update your career progress so the program can offer relevant support. Estimated time: 3–4 minutes.',qs:[
 S('S4-1','What are you currently pursuing?',['Internship','Full-time job','Part-time job involving data skills','Multiple opportunity types','Career exploration','Not currently pursuing an opportunity'],{sec:'Career progress'}),
 S('S4-2','Which stage best describes your current progress?',['Exploring roles or industries','Preparing applications','Identifying opportunities','Submitting applications','Interviewing or completing assessments','Considering an offer','Accepted but not started','Started an internship or job','Paused the search'],{show:a=>a['S4-1']!='Not currently pursuing an opportunity'}),
 L('S4-3','Which roles or industries are you targeting?',P({show:a=>a['S4-1']!='Not currently pursuing an opportunity'},OPT)),
 S('S4-4','When do you hope to begin?',['Within three months','In three to six months','More than six months','Already started','Unsure'],{show:a=>a['S4-1']!='Not currently pursuing an opportunity'}),
 M('S4-5','Which steps have you completed since your last career update or since beginning this search?',['Updated resume','Updated portfolio','Sought advice or attended a career event','Contacted employers or professional connections','Submitted applications','Completed interviews or assessments','Received an offer','Accepted an offer','Started the opportunity','No steps yet'],{ex:['No steps yet'],show:a=>a['S4-1']!='Not currently pursuing an opportunity'}),
 M('S4-6','What is making progress difficult?',['Unclear direction','Finding suitable opportunities','Limited experience or portfolio','Application preparation','Interview or assessment preparation','Limited connections','Time constraints','Location or work arrangement','Eligibility requirements','Unsure','Other','No current difficulty'],{ex:['Unsure','No current difficulty'],show:a=>a['S4-1']!='Not currently pursuing an opportunity',oo:1}),
 M('S4-7','What career support would be useful now?',CAREER_SUPPORT,{ex:['Unsure','None'],oo:1}),
 S('S4-8','Would you like faculty or adviser follow-up about your career plans?',Y),
 L('S4-8a','What would you most like help with?',P({show:a=>a['S4-8']=='Yes'},OPT))
 ]},
 long:{intro:'Complete this when beginning a search, applying, interviewing, receiving an offer, or starting an opportunity. Describe your career activity, employer requirements, obstacles, and support needs. Students not currently pursuing an opportunity receive a shorter path. Estimated time: 10–15 minutes.',qs:[
 S('L4-1','What are you currently pursuing?',['Internship','Full-time job','Part-time data work','Multiple opportunity types','Career exploration','Not currently pursuing an opportunity'],{sec:'A. Goals and stage'}),
 S('L4-2','Which stage best describes your current progress?',['Exploring','Preparing materials','Identifying openings','Applying','Interviews or assessments','Considering an offer','Accepted but not started','Started','Paused'],{show:a=>a['L4-1']!='Not currently pursuing an opportunity'}),
 T('L4-3a','Which roles are you targeting?',P({show:a=>a['L4-1']!='Not currently pursuing an opportunity'},OPT)),
 T('L4-3b','Which industries are you targeting?',P({show:a=>a['L4-1']!='Not currently pursuing an opportunity'},OPT)),
 S('L4-4','When do you hope to begin?',['Within three months','Three to six months','More than six months','Already started','Unsure'],{show:a=>a['L4-1']!='Not currently pursuing an opportunity'}),
 M('L4-5','Which requirements affect the opportunities you can pursue?',['Location','Work arrangement','Schedule','Compensation','Duration','Eligibility','Coursework compatibility','Other','Prefer not to answer','None'],P({ex:['Prefer not to answer','None'],show:a=>a['L4-1']!='Not currently pursuing an opportunity',oo:1},OPT)),
 S('L4-6','How many applications have you submitted in the past 30 days?',['0','1–5','6–10','11–20','More than 20','Unsure'],{sec:'B. Past 30 days',show:a=>a['L4-1']!='Not currently pursuing an opportunity'}),
 S('L4-7','How many employers have interviewed you or given you an assessment in the past 30 days?',['0','1–2','3–5','More than 5','Unsure'],{show:a=>a['L4-1']!='Not currently pursuing an opportunity'}),
 S('L4-8','How many offers have you received?',['0','1','2 or more','Prefer not to answer'],{show:a=>a['L4-1']!='Not currently pursuing an opportunity'}),
 M('L4-9','Which sources have produced useful opportunities or contacts?',['Faculty or staff','Career services','Classmates or alumni','Events','Networking','Job boards','Employer websites','Prior employers','Other','None yet'],{ex:['None yet'],show:a=>a['L4-1']!='Not currently pursuing an opportunity',oo:1}),
 M('L4-10','Which skills have employers requested?',['Python','SQL','Statistics','Machine learning','Data cleaning','Visualization or BI','Engineering or cloud','Software practices','Communication','Teamwork','Domain knowledge','Other','Not reached this stage'],{sec:'C. Skills and obstacles',ex:['Not reached this stage'],show:a=>a['L4-1']!='Not currently pursuing an opportunity',oo:1}),
 S('L4-11','How well has coursework prepared you for requirements you encountered?',['Not at all','Slightly','Moderately','Well','Very well','Insufficient experience'],{show:a=>a['L4-1']!='Not currently pursuing an opportunity'}),
 L('L4-11a','Describe one preparation strength and one gap.',P({show:a=>a['L4-1']!='Not currently pursuing an opportunity'},OPT)),
 L('L4-12','Which course, project, or assignment has been most useful, and why?',P({show:a=>a['L4-1']!='Not currently pursuing an opportunity'},OPT)),
 M('L4-13','What obstacles are affecting your progress?',['Unclear direction','Finding openings','Limited experience','Portfolio','Applications','Assessments','Interviews','Connections','Time','Location or work arrangement','Eligibility','Little feedback','Other','None'],{ex:['None'],show:a=>a['L4-1']!='Not currently pursuing an opportunity',oo:1}),
 L('L4-14','What employer feedback could improve preparation?',P({show:a=>a['L4-1']!='Not currently pursuing an opportunity',note:'Do not name interviewers or share confidential assessment content.'},OPT)),
 M('L4-15','What career support would be useful now?',['Career direction','Opportunity listings','Resume review','Portfolio review','Interview practice','Assessment practice','Networking guidance','Discussing an offer','Internship and coursework planning','Other','None'],{sec:'D. Support',ex:['None'],oo:1}),
 L('L4-16','What is your next planned career step?',OPT),
 S('L4-17','Would you like faculty or adviser follow-up?',Y),
 S('L4-18','What type of opportunity did you accept or start?',['Internship','Full-time','Part-time','Other'],{sec:'E. Accepted or started opportunity',show:a=>['Accepted but not started','Started'].includes(a['L4-2'])}),
 T('L4-19a','What is the general role title?',P({show:a=>['Accepted but not started','Started'].includes(a['L4-2']),note:'Employer name is not required.'},OPT)),
 T('L4-19b','What industry is the opportunity in?',P({show:a=>['Accepted but not started','Started'].includes(a['L4-2'])},OPT)),
 S('L4-20','How closely does the opportunity relate to DSA learning or goals?',['Not at all','Slightly','Moderately','Closely','Very closely','Unsure'],{show:a=>['Accepted but not started','Started'].includes(a['L4-2'])}),
 M('L4-21','If you started, which skills have you used?',['Python','SQL','Statistics','Machine learning','Data cleaning','Visualization or BI','Engineering or cloud','Software practices','Communication','Teamwork','Domain knowledge','Other','Not started','None yet'],{ex:['Not started','None yet'],show:a=>['Accepted but not started','Started'].includes(a['L4-2']),oo:1}),
 L('L4-22','What would have made you better prepared?',P({show:a=>['Accepted but not started','Started'].includes(a['L4-2'])},OPT)),
 L('L4-23','How could the department support similar opportunities?',P({show:a=>['Accepted but not started','Started'].includes(a['L4-2'])},OPT))
 ]}
},{
 name:'End-of-Semester Feedback',
 short:{intro:'Complete this after coursework, ideally after final grades are posted. Review each course, then share program-wide curriculum and career feedback. Estimated time for three courses: 12–20 minutes.',qs:[
 REP('S5-courses','A. Course reviews',SHORT_COURSE_REVIEW_FIELDS,{itemLabel:'Course review',addLabel:'Add another course'}),
 S('S5-9','Were there important gaps or unnecessary overlaps this semester?',['Gaps','Overlaps','Both','Neither','Unsure'],{sec:'B. Across the program'}),
 L('S5-9a','Identify the topics and courses involved.',P({show:a=>['Gaps','Overlaps','Both'].includes(a['S5-9'])},OPT)),
 S('S5-10','How manageable was major-assignment timing across courses?',['Consistently manageable','Usually manageable','Occasionally difficult due to clustering','Frequently difficult due to clustering','I took one course']),
 L('S5-10a','Suggest a coordination change.',OPT),
 M('S5-11','Which areas need more attention for your career goals?',['Programming or software practices','SQL or data engineering','Statistics or experimental design','Machine learning or evaluation','Real-world data','Visualization or communication','Deployment','Responsible AI, privacy, or ethics','Domain knowledge','Teamwork','Portfolio','Career exploration or employer connections','Other','Unsure','No additional areas'],{max:3,ex:['Unsure','No additional areas'],oo:1}),
 M('S5-12','Have you applied this semester’s learning outside class?',['Internship','Paid work','Research','Personal project','Community project','Interview or assessment','Other','No opportunity'],{ex:['No opportunity'],oo:1}),
 L('S5-12a','What learning was useful, and what preparation was missing?',P({show:a=>!a['S5-12'].includes('No opportunity')},OPT)),
 M('S5-13','What would better connect coursework to careers?',['External projects','Employer or alumni connections','Skill-to-role explanations','Portfolio guidance','Interview or assessment practice','Opportunity access','Research or applied projects','Elective guidance','Other','Unsure','Current opportunities are sufficient'],{max:3,ex:['Unsure','Current opportunities are sufficient'],oo:1}),
 L('S5-14','What single change would be most valuable for future students?',OPT),
 S('S5-15','Would you discuss your feedback further?',Y)
 ]},
 long:{intro:'Complete this after coursework, ideally after final grades are posted. Review each course in detail, then provide program-wide feedback. Written comments are optional; avoid naming classmates or sharing personal information. Estimated time for three courses: 25–35 minutes.',qs:[
 REP('L5-courses','A. Course reviews',LONG_COURSE_REVIEW_FIELDS,{itemLabel:'Course review',addLabel:'Add another course'}),
 L('L5-14','Were there important curriculum gaps or unnecessary duplication?',P({sec:'B. Curriculum across courses',note:'Name relevant topics or courses and distinguish useful reinforcement from repetition.'},OPT)),
 S('L5-15','Would you change a course or topic sequence?',YNU),
 L('L5-15a','Describe the proposed sequence and reason.',P({show:a=>a['L5-15']=='Yes'},OPT)),
 S('L5-16','How manageable was combined assignment timing?',['Consistently manageable','Usually manageable','Occasionally difficult due to clustering','Frequently difficult due to clustering','I took one course']),
 L('L5-16a','Suggest a coordination improvement.',OPT),
 M('L5-17','Which areas need more attention?',['Programming or software practices','Databases or engineering','Statistics or experimental design','Machine learning or evaluation','Real-world data','Communication','Deployment','Responsible AI, privacy, or ethics','Domain knowledge','Teamwork or project management','Research methods','Portfolio','Career preparation','Other','Unsure','None'],{max:5,ex:['Unsure','None'],oo:1}),
 L('L5-18','Which electives or applied experiences would support your goals?',OPT),
 M('L5-19','Did you apply learning outside class?',['Internship','Employment','Research','Personal project','Community work','Interview or assessment','Other','No opportunity'],{sec:'C. Application outside class',ex:['No opportunity'],oo:1}),
 L('L5-19a','What learning was useful, what skills were missing, and what course or activity could address the gap?',P({show:a=>!a['L5-19'].includes('No opportunity')},OPT)),
 S('L5-20','How much did the semester clarify suitable career roles?',['Not at all','A little','Somewhat','Quite a bit','A great deal']),
 M('L5-21','What would better connect the program to careers?',['External projects','Employer or alumni participation','Skill-to-role links','Portfolio guidance','Interview or assessment practice','Opportunity access','Research or applied projects','Career-oriented elective pathways','Other','Unsure','Current connections are sufficient'],{max:3,ex:['Unsure','Current connections are sufficient'],oo:1}),
 G('L5-22','How helpful were these resources?',['Advising','Office hours','Tutoring or preparation','Career guidance','Projects or research','Peer learning','Computing or software'],['Not helpful','Slightly helpful','Moderately helpful','Very helpful','Did not use','Unaware of availability'],{sec:'D. Department priorities'}),
 L('L5-23','Was there support you needed but could not access?',OPT),
 L('L5-24','What single change would be most valuable for future students?',OPT),
 L('L5-25','What is one departmental strength to preserve?',OPT),
 S('L5-26','Would you discuss your feedback further?',Y)
 ]}
}]};
