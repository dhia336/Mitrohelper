const C=window.CFG,A=C.API.replace(/\/$/,'')+'/api';
const get=p=>fetch(A+p).then(r=>r.json());
let dev=localStorage.dev||(localStorage.dev=crypto.randomUUID());
const post=(p,b)=>fetch(A+p,{method:'POST',headers:{'content-type':'application/json'},body:JSON.stringify({...b,dev})}).then(r=>r.json()).then(d=>d.r).catch(()=>'err');
const T={
ar:{dis:'المعلومات مقدمة من المستعملين وليست رسمية، وقد تكون غير دقيقة. الموقع غير تابع لشركة نقل تونس. بدون حسابات: نحفظ فقط معرّفا عشوائيا للجهاز.',nm:'المترو',np:'الخريطة',cta:'شفت المترو؟',stp:'المترو واقف',tg:'وين وصل المترو ؟',mh:'كبّر بإصبعين وحرّك الخريطة',no:'اللواج',line:'خط',to:'باتجاه',ago:m=>m<1?'الآن':'منذ '+m+' د',none:'لا توجد إشارة منذ 45 دقيقة',n45:'إشارة في آخر 45 دقيقة',l1:'أي خط؟',l2:'في أي محطة؟',l2s:'وين واقف؟',l3:'لأي اتجاه يمشي؟',ok:'شكرا! الكل يشوفها الآن',slow:'انتظر شوية قبل إشارة أخرى',err:'مشكل، أعد المحاولة',dup:'أجبت من قبل',hw:'متوقف',still:'مازال واقف',run:'رجع يخدم',conf:'تأكيد',
 cs:'اللواج قريبا',csd:'نحضّرو لتتبع محطات اللواج مباشرة. ترقّبوا!',soon:'قريبا',inst:'📲 ثبّت التطبيق',ios:'آيفون: مشاركة ثم «إضافة إلى الشاشة الرئيسية»'},
fr:{dis:'Informations signalées par les usagers, non officielles et parfois inexactes. Ce site n’est pas affilié à Transtu. Sans compte : seul un identifiant aléatoire d’appareil est conservé.',nm:'Métro',np:'Plan',cta:'J’ai vu le métro',stp:'Métro en panne',tg:'Où est le métro en ce moment ?',mh:'Zoomez à deux doigts, faites glisser',no:'Louage',line:'Ligne',to:'vers',ago:m=>m<1?'à l’instant':'il y a '+m+' min',none:'Aucun signalement depuis 45 min',n45:'signalements (45 min)',l1:'Quelle ligne ?',l2:'Quelle station ?',l2s:'Où est-il arrêté ?',l3:'Quel sens ?',ok:'Merci ! Tout le monde le voit',slow:'Patientez un peu',err:'Problème, réessayez',dup:'Déjà voté',hw:'Arrêté',still:'Toujours en panne',run:'Ça roule',conf:'confirmations',
 cs:'Louage bientôt',csd:'Nous préparons le suivi en direct des stations de louage. Restez connectés !',soon:'BIENTÔT',inst:'📲 Installer l’app',ios:'iPhone : Partager puis « Sur l’écran d’accueil »'},
en:{dis:'Community-reported information: not official and may be inaccurate. This site is not affiliated with Transtu. No accounts: only a random device ID is stored.',nm:'Metro',np:'Map',cta:'I saw the metro',stp:'Metro stopped',tg:'Where is the metro right now?',mh:'Pinch to zoom, drag to move',no:'Louage',line:'Line',to:'toward',ago:m=>m<1?'just now':m+' min ago',none:'No report in the last 45 min',n45:'reports (last 45 min)',l1:'Which line?',l2:'Which station?',l2s:'Where is it stopped?',l3:'Which direction?',ok:'Thanks! Everyone can see it',slow:'Please wait a bit',err:'Problem, try again',dup:'Already voted',hw:'Stopped',still:'Still stopped',run:'Running again',conf:'confirmations',
 cs:'Louage coming soon',csd:'We’re building live tracking for louage stations. Stay tuned!',soon:'COMING SOON',inst:'📲 Install app',ios:'iPhone: Share, then “Add to Home Screen”'}};
const $=s=>document.querySelector(s),buzz=()=>navigator.vibrate&&navigator.vibrate(8);
let lang=localStorage.lang||'ar',lines=[],sts=[],lv=[],li=[],tab='metro',seen=0,S={},open=new Set(),tok='',tid;
const t=k=>T[lang][k],nm=s=>s[lang]||s.fr;
const LN=l=>l=='TGM'?'TGM':t('line')+' '+l,bc=l=>l.length>1?' t':'';
const byLine=l=>sts.filter(s=>s.line_id==l).sort((a,b)=>a.pos-b.pos);
const ends=l=>{const x=byLine(l);return{a:x[x.length-1],b:x[0]}};
const mins=d=>Math.max(0,Math.floor((Date.now()-new Date(d))/6e4));
const arr=d=>d=='a'?'↓':'↑',stn=id=>nm(sts.find(s=>s.id==id));
function toast(m){const e=$('#toast');e.textContent=m;e.classList.add('s');clearTimeout(toast.i);toast.i=setTimeout(()=>e.classList.remove('s'),2800)}
function ts(){if(!C.TS)return;const go=()=>{tid!=null?turnstile.reset(tid):tid=turnstile.render('#tsw',{sitekey:C.TS,appearance:'interaction-only',callback:x=>tok=x,'expired-callback':()=>tok=''})};
 if(window.turnstile)go();else{const s=document.createElement('script');s.src='https://challenges.cloudflare.com/turnstile/v0/api.js?render=explicit';s.async=true;s.onload=go;document.head.appendChild(s)}}
async function send(p,b){const r=await post(p,{...b,ts:tok});tok='';ts();return r}
function setLang(l){lang=localStorage.lang=l;document.documentElement.lang=l;document.documentElement.dir=l=='ar'?'rtl':'ltr';
 document.querySelectorAll('[data-g]').forEach(b=>b.classList.toggle('on',b.dataset.g==l));
 $('#nM').textContent=t('nm');$('#nP').textContent=t('np');$('#cT').textContent=t('cta');$('#cS').textContent=t('stp');$('#nO').textContent=t('no');document.title='MitroHelper';seen=0;render();sheet()}
function render(){
 document.querySelectorAll('nav [data-t]').forEach(b=>b.classList.toggle('on',b.dataset.t==tab));
 const v=$('#v');v.classList.toggle('noani',!!seen);document.body.dataset.tab=tab;
 if(tab=='map'){seen=0;v.innerHTML=`<div class="mp"><p class="mu">${t('mh')}</p><div class="mz"><img src="img/map.webp" alt="" decoding="async"></div></div>`;return}
 if(tab=='louage'){seen=0;v.innerHTML=`<div class="cs"><div class="rd"><div class="van"><svg viewBox="0 0 64 36"><path d="M3 26V13a3 3 0 013-3h30l14 10h8v6M3 26h6m10 0h24M16 10v8h14"/><circle cx="14" cy="28" r="4"/><circle cx="48" cy="28" r="4"/></svg></div></div><span class="tag">${t('soon')}</span><h2>${t('cs')}</h2><p>${t('csd')}</p></div>`;return}
 if(!lines.length){v.innerHTML='<div class="sk"></div>'.repeat(4);return}
 v.innerHTML=`<div class="hero"><img src="img/hero.webp" alt="" fetchpriority="high"><div class="hc"><span class="chip"><i class="pd"></i>${lv.length} ${t('n45')}</span>${li.length?`<span class="chip warn">⚠ ${li.length} ${t('hw')}</span>`:''}<h2>${t('tg')}</h2></div></div>`+lines.map((l,i)=>{
  const e=ends(l.id),ss=byLine(l.id);
  const inc=li.filter(x=>x.line_id==l.id).map(x=>`<div class="al"><div class="dt">⚠ ${t('hw')} · ${t('ago')(mins(x.seen_at))} · ${x.up} ${t('conf')}</div><div class="st">${stn(x.station_id)}</div><div class="vt"><button data-iv="1" data-id="${x.id}">${t('still')}</button><button data-iv="-1" data-id="${x.id}">${t('run')}</button></div></div>`).join('');
  const rows=['a','b'].map(d=>{const x=lv.filter(s=>s.line_id==l.id&&s.dir==d).sort((p,q)=>new Date(q.seen_at)-new Date(p.seen_at))[0],m=x&&mins(x.seen_at);
   return `<div class="dr"><div class="dt">${arr(d)} ${t('to')} ${nm(e[d])}</div>`+(x?`<div class="st"><span class="pd"></span>${t('ago')(m)} · ${stn(x.station_id)}</div><div class="fr"><b style="--w:${Math.max(4,100-m*100/45)}%"></b></div><div class="vt"><button data-v="1" data-id="${x.id}">👍 ${x.up}</button><button data-v="-1" data-id="${x.id}">👎 ${x.down}</button></div>`:`<div class="st mu">${t('none')}</div>`)+`</div>`}).join('');
  const tr=ss.map(s=>{const h=lv.filter(z=>z.station_id==s.id),b=li.some(z=>z.station_id==s.id);return `<li class="${b?'bad':h.length?'hit':''}"><i class="dot"></i>${nm(s)}${b?`<em class="w">⚠ ${t('hw')}</em>`:''}${h.map(z=>`<em>${arr(z.dir)} ${t('ago')(mins(z.seen_at))}</em>`).join('')}</li>`}).join('');
  return `<section class="card${open.has(l.id)?' open':''}" style="--c:${l.color};--i:${i}"><div class="hd" data-tog="${l.id}"><span class="b${bc(l.id)}">${l.id}</span><div><div class="ti">${LN(l.id)}</div><div class="mu sm">${nm(ss[0])} ⇄ ${nm(ss[ss.length-1])}</div></div><svg class="cv" viewBox="0 0 24 24"><path d="M6 9l6 6 6-6"/></svg></div>${inc}${rows}<div class="tk"><div><ol class="sl">${tr}</ol></div></div></section>`}).join('')+`<p class="ft">${t('dis')}</p>`;
 seen=1}
function sheet(){const w=$('#sh'),p=$('#pan');w.classList.toggle('on',!!S.on);if(!S.on)return;p.dataset.m=S.mode;
 const n=S.mode=='stop'?2:3,hd=h=>`<div class="top">${S.step>1?'<button class="bk" data-bk><span class="mir">←</span></button>':''}<h2>${h}</h2><div class="pg">${Array.from({length:n},(_,i)=>`<i class="${i<S.step?'on':''}"></i>`).join('')}</div></div>`;
 if(S.done){p.innerHTML=`<div class="ok"><svg viewBox="0 0 24 24"><circle cx="12" cy="12" r="10"/><path d="M7 12.5l3.2 3.2L17 9"/></svg>${t('ok')}</div>`;return}
 let h='';
 if(S.step==1)h=hd(t('l1'))+`<div class="stp lns">`+lines.map(l=>`<button class="ln" style="--c:${l.color}" data-ln="${l.id}"><span class="b${bc(l.id)}">${l.id}</span>${LN(l.id)}</button>`).join('')+`</div>`;
 if(S.step==2){const c=lines.find(l=>l.id==S.l).color;h=hd(t(S.mode=='stop'?'l2s':'l2'))+`<div class="stp">`+byLine(S.l).map(s=>`<button class="pk" style="--c:${c}" data-s="${s.id}">${nm(s)}</button>`).join('')+`</div>`}
 if(S.step==3){const e=ends(S.l);h=hd(t('l3'))+`<div class="stp">`+['a','b'].map(d=>`<button class="dir" data-d="${d}"><svg viewBox="0 0 24 24"><path d="${d=='a'?'M12 5v14M6 13l6 6 6-6':'M12 19V5M6 11l6-6 6 6'}"/></svg>${t('to')} ${nm(e[d])}</button>`).join('')+`</div>`}
 p.innerHTML=h}
function finish(r){if(r=='ok'){S.done=1;sheet();tab='metro';seen=0;refresh();setTimeout(()=>{S={};sheet()},1700)}else{toast(t(r=='slow'?'slow':'err'));S={};sheet()}}
document.addEventListener('click',async e=>{const g=s=>e.target.closest(s);let b;
 if(b=g('[data-v],[data-iv]')){buzz();const r=await post(b.dataset.iv?'/ivote':'/vote',{id:+b.dataset.id,v:+(b.dataset.iv||b.dataset.v)});if(r=='dup')toast(t('dup'));else if(r!='ok')toast(t(r=='slow'?'slow':'err'));refresh()}
 else if(b=g('[data-tog]')){const k=b.dataset.tog;open.has(k)?open.delete(k):open.add(k);b.parentElement.classList.toggle('open');buzz()}
 else if(b=g('[data-t]')){buzz();const x=b.dataset.t;if(x=='rep'||x=='stop'){S={on:1,step:1,mode:x};ts();sheet()}else{tab=x;seen=0;render();refresh()}}
 else if(b=g('[data-g]'))setLang(b.dataset.g);
 else if(g('.scrim')){S={};sheet()}
 else if(b=g('[data-ln]')){buzz();S.l=b.dataset.ln;S.step=2;sheet()}
 else if(b=g('[data-s]')){buzz();S.s=+b.dataset.s;if(S.mode=='stop')finish(await send('/incident',{station:S.s}));else{S.step=3;sheet()}}
 else if(g('[data-bk]')){S.step--;sheet()}
 else if(b=g('[data-d]')){buzz();finish(await send('/report',{station:S.s,dir:b.dataset.d}))}});
async function refresh(){try{const d=await get('/live');if(d.s)lv=d.s;if(d.i)li=d.i}catch(_){}if(tab=='metro')render()}
(async()=>{setLang(lang);try{const d=await get('/data');lines=d.lines;sts=d.stations}catch(_){toast(t('err'))}
 seen=0;await refresh();
 setInterval(()=>{if(!document.hidden)refresh()},20000);setInterval(()=>{if(tab=='metro'&&!document.hidden)render()},20000);
 document.addEventListener('visibilitychange',()=>!document.hidden&&refresh())})();
let dp;addEventListener('beforeinstallprompt',e=>{e.preventDefault();dp=e;$('#inst').innerHTML=`<button>${t('inst')}</button>`;$('#inst button').onclick=()=>{dp.prompt();$('#inst').innerHTML=''}});
if(/iphone|ipad/i.test(navigator.userAgent)&&!navigator.standalone)$('#inst').innerHTML=`<p>${t('ios')}</p>`;
if('serviceWorker'in navigator)navigator.serviceWorker.register('sw.js');
