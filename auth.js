// Shared page-access check. Loaded in the <head> of every page.
// PROTOTYPE ONLY: the "role" is picked on login.html and kept in sessionStorage.
// This hides pages in the browser; it is NOT real security. Flask must enforce roles later.
(function(){
 const ALL=['student','faculty','administrator'];

 // ONE place to change who can open what. A page not listed here is denied to everyone.
 const PAGES={
  'index.html':{name:'Home',roles:ALL},
  'applicant.html':{name:'Applicant Survey',roles:['student','administrator']},
  'current-student.html':{name:'Current Student Survey',roles:['student','administrator']},
  'near-graduation.html':{name:'Near Graduation Survey',roles:['student','administrator']},
  'after-graduation.html':{name:'After Graduation Survey',roles:['student','administrator']},
  'dashboard.html':{name:'Faculty Dashboard',roles:['faculty','administrator']},
  'admin.html':{name:'Administration',roles:['administrator']}
 };
 const HOME={student:'index.html',faculty:'dashboard.html',administrator:'admin.html'};

 let role=null;
 try{role=sessionStorage.getItem('role');}catch(e){}
 if(!ALL.includes(role))role=null;

 const page=location.pathname.split('/').pop()||'index.html';
 const isLogin=page==='login.html';
 const rule=PAGES[page];
 const allowed=isLogin||!!(role&&rule&&rule.roles.includes(role));

 window.ACCESS_OK=allowed;            // survey.js checks this before drawing a form
 window.Auth={role,PAGES,HOME};

 document.documentElement.style.visibility='hidden';   // nothing shows until the check is done
 if(!isLogin&&!role){location.replace('login.html');return;}

 const cap=s=>s.charAt(0).toUpperCase()+s.slice(1);
 const navHTML=()=>Object.keys(PAGES).filter(p=>PAGES[p].roles.includes(role))
   .map(p=>'<a href="'+p+'">'+PAGES[p].name+'</a>').join('')+
   (role?'<span class="who">Signed in as '+cap(role)+' <button type="button" id="logout">Log out</button></span>':'');

 document.addEventListener('DOMContentLoaded',()=>{
  if(!allowed){
   const nm=rule?rule.name:page;
   document.body.innerHTML='<nav id="nav"></nav><h1>Access denied</h1><p>Your role ('+cap(role)+') cannot open "'+nm+'".</p><p><a href="'+HOME[role]+'">Go to your start page</a></p>';
  }
  const nv=document.getElementById('nav');if(nv&&role)nv.innerHTML=navHTML();
  const lo=document.getElementById('logout');
  if(lo)lo.onclick=()=>{try{sessionStorage.removeItem('role');}catch(e){}location.href='login.html';};
  const ln=document.getElementById('links');
  if(ln&&allowed&&role)ln.innerHTML=Object.keys(PAGES).filter(p=>p!=='index.html'&&PAGES[p].roles.includes(role))
   .map(p=>'<li><a href="'+p+'">'+PAGES[p].name+'</a></li>').join('');
  document.documentElement.style.visibility='visible';
 });
 // Back button after logging out: reload so the check runs again.
 window.addEventListener('pageshow',e=>{if(e.persisted)location.reload();});
})();
