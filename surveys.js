// All survey content lives here. Edit text/options here; survey.js draws the forms.
const Y=['Yes','No'], YNU=['Yes','No','Unsure'];
const C4=['1 = No comfort','2 = Little comfort','3 = Comfortable','4 = Very comfortable'];
const K=(id,t,type,o,x)=>Object.assign({id,t,type,o},x);
const S=(i,t,o,x)=>K(i,t,'single',o,x), M=(i,t,o,x)=>K(i,t,'multi',o,x),
 T=(i,t,x)=>K(i,t,'text',0,x), L=(i,t,x)=>K(i,t,'long',0,x), N=(i,t,x)=>K(i,t,'number',0,x),
 E=(i,t,x)=>K(i,t,'email',0,x), D=(i,t,o,x)=>K(i,t,'dropdown',o,x),
 G=(i,t,rows,o,x)=>K(i,t,'grid',o,Object.assign({rows},x)),
 R=(i,t,src,o,x)=>K(i,t,'each',o,Object.assign({src},x));
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

// Current Student: only "Beginning of the Program" (S1 short / L1 long) is loaded so far.
// The other four collection moments are added the same way as extra objects in forms[].
const P=Object.assign;
const SUP=(o)=>o;
SURVEYS.current={title:'Current Student Survey',intro:'Choose a version. (More collection moments will be added to this page.)',forms:[{
 name:'Beginning of the Program',
 short:{intro:'Help us understand your starting point, goals, and support needs as you begin the DSA MS program.',qs:[
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
 long:{intro:'Your responses will help the DSA MS program understand your starting point and provide relevant academic and career support. You may skip optional questions.',qs:[
 T('L1-1','What was your primary undergraduate field of study?',{sec:'A. Background'}),
 S('L1-2','Have you completed other relevant degrees, certificates, or substantial training?',Y),
 T('L1-2a','Describe subject and type.',P({show:a=>a['L1-2']=='Yes'},OPT)),
 M('L1-3','What relevant experience do you bring?',['Data-analysis coursework','Data/technology employment','Internship','Research','Personal projects','Community projects','No experience','Other'],{ex:['No experience'],oo:1}),
 L('L1-3a','Describe one experience representing your abilities.',OPT),
 G('L1-4','Rate your experience in each area.',['Python','SQL/databases','Statistics/probability','Linear algebra','Calculus','Data cleaning/analysis','Visualization','Machine learning','Git/version control','Command-line/development environments','Technical communication'],['No experience','Some exposure','Basic tasks independently','Advanced tasks independently','Unsure'],{sec:'B. Preparation'}),
 M('L1-5','Which activities have you completed?',['Data-processing program','SQL query','Cleaning missing/inconsistent data','Statistical analysis','Training/evaluating a model','Communicating through visualization','Team project with shared tools','Explaining findings to a nontechnical audience','None'],{ex:['None']}),
 S('L1-6','Have you been assigned prerequisites or preparation activities?',YNU),
 T('L1-6a','Course/activity',P({show:a=>a['L1-6']=='Yes',note:'Prototype: one entry only (repeat-per-item not built yet).'},OPT)),
 S('L1-6b','Status',['Completed','In progress','Not started'],P({show:a=>a['L1-6']=='Yes'},OPT)),
 S('L1-6c','Help needed',YNU,P({show:a=>a['L1-6']=='Yes'},OPT)),
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
}]};
