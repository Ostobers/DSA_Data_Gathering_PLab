// Draws a survey from surveys.js, handles show/hide logic, validation and the fake submit.
(function(){
const S=SURVEYS[document.body.dataset.survey];
const app=document.getElementById('app');
let ver='long',fi=0,qs=[],f;
const form=()=>S.forms[fi];
const esc=s=>String(s).replace(/&/g,'&amp;').replace(/"/g,'&quot;').replace(/</g,'&lt;');
const $=s=>f.querySelector(s);

function getQs(){const F=form();return F[ver]?F[ver].qs:F.qs.filter(q=>F.shortIds.includes(q.id));}
function getIntro(){const F=form();return (F[ver]&&F[ver].intro)||F.intro||'';}

function qHTML(q){
 const n=q.id;
 let h=(q.sec?'<h3>'+q.sec+'</h3>':'')+'<fieldset data-q="'+n+'"><legend>'+n+'. '+q.t+(q.req===false?' <em>(optional)</em>':'')+'</legend>';
 if(q.note)h+='<p class="note">'+q.note+'</p>';
 if(q.type=='multi'&&q.max)h+='<p class="note">Select up to '+q.max+'.</p>';
 if(q.type=='single'||q.type=='multi'){
  const t=q.type=='single'?'radio':'checkbox';
  q.o.forEach(o=>{h+='<label><input type="'+t+'" name="'+n+'" value="'+esc(o)+'"> '+o+'</label>';});
 }else if(q.type=='dropdown'){
  h+='<select name="'+n+'"><option value="">-- Select --</option>'+q.o.map(o=>'<option>'+o+'</option>').join('')+'</select>';
 }else if(q.type=='long'){h+='<textarea name="'+n+'" rows="3"></textarea>';
 }else if(q.type=='grid'){
  h+='<div class="scroll"><table><tr><th></th>'+q.o.map(o=>'<th>'+o+'</th>').join('')+'</tr>';
  q.rows.forEach(r=>{h+='<tr class="row"><td>'+r+'</td>'+q.o.map(o=>'<td><input type="radio" name="'+n+'__'+esc(r)+'" value="'+esc(o)+'" aria-label="'+esc(r+': '+o)+'"></td>').join('')+'</tr>';});
  h+='</table></div>';
 }else if(q.type=='each'){h+='<div class="each"></div>';
 }else{h+='<input type="'+(q.type=='number'?'number" min="0':q.type=='email'?'email':'text')+'" name="'+n+'">';}
 if(['single','multi','dropdown'].includes(q.type))h+='<input type="text" class="oth" name="'+n+'__other" placeholder="'+(q.ph||'Please specify')+'" hidden>';
 if(q.why)h+='<label>'+q.why+'<textarea class="why" name="'+n+'__why" rows="2"></textarea></label>';
 return h+'<div class="err" role="alert"></div></fieldset>';
}

function val(q){
 const n=q.id;
 if(q.type=='single'){const c=$('input[name="'+n+'"]:checked');return c?c.value:'';}
 if(q.type=='multi')return [...f.querySelectorAll('input[name="'+n+'"]:checked')].map(x=>x.value);
 if(q.type=='grid'){const o={};q.rows.forEach(r=>{const c=$('input[name="'+n+'__'+r+'"]:checked');if(c)o[r]=c.value;});return o;}
 if(q.type=='each'){const o={};f.querySelectorAll('[data-q="'+n+'"] .row').forEach(d=>{const c=d.querySelector('input:checked');if(c)o[d.dataset.c]=c.value;});return o;}
 return $('[name="'+n+'"]').value.trim();
}

// Shows/hides questions based on earlier answers; returns answers of visible questions.
function refresh(){
 const a={};
 qs.forEach(q=>{
  const fs=$('[data-q="'+q.id+'"]');
  const vis=!q.show||q.show(a);
  fs.hidden=!vis;
  if(q.type=='each'){
   const src=a[q.src]||[],box=fs.querySelector('.each'),key=src.join('|');
   if(box.dataset.k!==key){
    const old=val(q);box.dataset.k=key;
    box.innerHTML=src.map(c=>'<div class="row" data-c="'+esc(c)+'"><p>How comfortable are you with '+c+'?</p>'+q.o.map(o=>'<label><input type="radio" name="'+q.id+'__'+esc(c)+'" value="'+esc(o)+'"'+(old[c]==o?' checked':'')+'> '+o+'</label>').join('')+'</div>').join('');
   }
  }
  fs.querySelectorAll('input,select,textarea').forEach(i=>i.disabled=!vis);
  if(vis)a[q.id]=val(q);
  const oth=fs.querySelector('.oth');
  if(oth){const s=fs.querySelector('select');const o=s?s.value=='Other':fs.querySelector('input[value="Other"]:checked');oth.hidden=!o;}
 });
 return a;
}

function onChange(e){
 const i=e.target,q=qs.find(x=>x.id==i.name),fs=i.closest('fieldset');
 if(fs){fs.querySelector('.err').textContent='';fs.classList.remove('invalid');}
 if(q&&q.type=='multi'){
  const all=[...f.querySelectorAll('input[name="'+q.id+'"]')];
  if(i.checked&&q.ex)all.forEach(x=>{if(x!==i&&(q.ex.includes(i.value)||q.ex.includes(x.value)))x.checked=false;});
  if(q.max&&all.filter(x=>x.checked).length>q.max){i.checked=false;fs.querySelector('.err').textContent='You can select at most '+q.max+'.';}
 }
 refresh();
}

function validate(){
 const a=refresh();let first=null;
 qs.forEach(q=>{
  const fs=$('[data-q="'+q.id+'"]');if(fs.hidden)return;
  const v=a[q.id],rows=fs.querySelectorAll('.row').length;let m='';
  if(q.req!==false){
   if(q.type=='grid'||q.type=='each'){if(Object.keys(v).length<rows)m='Please answer every row.';}
   else if(!v.length)m='This question is required.';
  }
  if(!m&&q.type=='email'&&v&&!/^\S+@\S+\.\S+$/.test(v))m='Please enter a valid email address.';
  if(!m&&q.type=='number'&&v!==''&&(isNaN(v)||+v<0))m='Please enter a number (0 or more).';
  const oth=fs.querySelector('.oth');
  if(!m&&oth&&!oth.hidden&&!q.oo&&!oth.value.trim())m='Please fill in the "Other" box.';
  fs.querySelector('.err').textContent=m;fs.classList.toggle('invalid',!!m);
  if(m&&!first)first=fs;
 });
 if(first)first.scrollIntoView({behavior:'smooth',block:'center'});
 return !first;
}

function collect(){
 const a=refresh(),out={};
 qs.forEach(q=>{
  if(a[q.id]===undefined)return;
  out[q.id]=a[q.id];
  const fs=$('[data-q="'+q.id+'"]'),o=fs.querySelector('.oth'),w=fs.querySelector('.why');
  if(o&&!o.hidden&&o.value.trim())out[q.id+'_other']=o.value.trim();
  if(w&&w.value.trim())out[q.id+'_why']=w.value.trim();
 });
 return out;
}

function drawForm(){
 qs=getQs();
 const F=form();
 box.innerHTML='<h2>'+F.name+' ('+(ver=='short'?'Short':'Long')+' Version)</h2><p>'+getIntro()+'</p><form novalidate>'+qs.map(qHTML).join('')+'<p class="note">Responses are not saved (prototype).</p><button type="submit">Submit</button></form>';
 f=box.querySelector('form');
 f.addEventListener('change',onChange);
 f.addEventListener('submit',e=>{e.preventDefault();if(validate())done();});
 refresh();
}

function done(){
 // submitted_at, form and version are included so repeated check-ins can be stored later.
 const data={survey:S.title,form:form().name,version:ver,submitted_at:new Date().toISOString(),answers:collect()};
 console.log(data);
 box.innerHTML='<h2>Thank you!</h2><p>Your response was submitted. <strong>This is a prototype: responses are not saved anywhere.</strong></p><details><summary>Show the answers (for testing)</summary><pre>'+esc(JSON.stringify(data,null,2))+'</pre></details><p><button id="again" type="button">Fill out again</button></p><p><a href="index.html">Back to all surveys</a></p>';
 document.getElementById('again').onclick=drawForm;
 scrollTo(0,0);
}

app.innerHTML='<h1>'+S.title+'</h1><p>'+(S.intro||'')+'</p><fieldset><legend>Choose a version</legend>'+
 '<label><input type="radio" name="ver" value="short"> Short version (essential questions only)</label>'+
 '<label><input type="radio" name="ver" value="long" checked> Long version (all questions)</label>'+
 (S.forms.length>1?'<label>Survey: <select id="fsel">'+S.forms.map((x,i)=>'<option value="'+i+'">'+x.name+'</option>').join('')+'</select></label>':'')+
 '</fieldset><div id="box"></div>';
const box=document.getElementById('box');
app.querySelectorAll('input[name="ver"]').forEach(r=>r.onchange=()=>{ver=r.value;drawForm();});
const fsel=document.getElementById('fsel');if(fsel)fsel.onchange=()=>{fi=+fsel.value;drawForm();};
drawForm();
})();
