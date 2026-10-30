// v0.21 theme toggle + tap animations. No dependencies. Everything is skipped under prefers-reduced-motion (the theme still switches, instantly).
(()=>{
const H=document.documentElement,rm=matchMedia('(prefers-reduced-motion:reduce)'),mq=matchMedia('(prefers-color-scheme:dark)'),$=(a,b)=>a+Math.random()*(b-a);
const stored=()=>{try{const v=localStorage.theme;return v==='light'||v==='dark'?v:''}catch(_){return''}};

// ---- theme: default = system; the toggle stores an explicit choice ----
const setT=v=>{H.dataset.theme=v};
mq.addEventListener&&mq.addEventListener('change',()=>{if(!stored())setT(mq.matches?'dark':'light')});
const LBL={ar:'تبديل الوضع الفاتح / الداكن',fr:'Changer de thème',en:'Switch theme'},lab=()=>{const b=document.querySelector('.tg');if(b){const l=LBL[H.lang]||LBL.en;b.setAttribute('aria-label',l);b.title=l}};
lab();new MutationObserver(lab).observe(H,{attributes:true,attributeFilter:['lang']});
document.addEventListener('click',e=>{
  const b=e.target.closest('.tg');if(!b)return;
  const n=H.dataset.theme==='dark'?'light':'dark';try{localStorage.theme=n}catch(_){}
  if(navigator.vibrate)navigator.vibrate(8);
  if(!document.startViewTransition||rm.matches){setT(n);return}
  const r=b.getBoundingClientRect(),x=r.left+r.width/2,y=r.top+r.height/2,R=Math.hypot(Math.max(x,innerWidth-x),Math.max(y,innerHeight-y));
  const vt=document.startViewTransition(()=>setT(n));
  vt.ready.then(()=>H.animate({clipPath:[`circle(0px at ${x}px ${y}px)`,`circle(${R}px at ${x}px ${y}px)`]},{duration:650,easing:'cubic-bezier(.2,.85,.2,1)',pseudoElement:'::view-transition-new(root)'})).catch(()=>{});
});

// ---- particle layer ----
let L;const layer=()=>L||(L=document.body.appendChild(Object.assign(document.createElement('div'),{id:'fx'})));
function spawn(x,y,o){
  const e=document.createElement('i');
  if(o.t){e.textContent=o.t;e.style.fontSize=o.s+'px'}else{e.style.width=o.s+'px';e.style.height=(o.r?o.s*o.r:o.s)+'px';e.style.background=o.c;e.style.borderRadius=o.r?'2px':'50%'}
  layer().appendChild(e);
  const a=e.animate([{transform:`translate(${x}px,${y}px) rotate(0deg) scale(.4)`,opacity:1},
    {transform:`translate(${x+o.dx*.65}px,${y+o.dy*.65}px) rotate(${o.rot*.6}deg) scale(1)`,opacity:1,offset:.45},
    {transform:`translate(${x+o.dx}px,${y+o.dy+o.g}px) rotate(${o.rot}deg) scale(.85)`,opacity:0}],{duration:o.d,easing:'cubic-bezier(.2,.7,.3,1)',fill:'forwards'});
  a.onfinish=()=>e.remove();
}
const cols=()=>{const c=[...document.querySelectorAll('.lj')].map(e=>e.style.getPropertyValue('--c').trim()).filter(Boolean);return c.length?c:['#84cc16','#ec4899','#a855f7','#3b82f6','#14b8a6','#f59e0b','#ef4444']};
function confetti(x,y){
  if(rm.matches)return;const c=cols();
  for(let i=0;i<34;i++){const a=$(-Math.PI*.95,-Math.PI*.05),v=$(90,230);
    spawn(x,y,{c:c[i%c.length],s:$(6,10),r:i%3?1.6:0,dx:Math.cos(a)*v,dy:Math.sin(a)*v,g:$(120,220),rot:$(-540,540),d:$(1000,1500)})}
  ['🚇','✨','🚇','✨'].forEach(t=>{const a=$(-Math.PI*.9,-Math.PI*.1),v=$(80,170);spawn(x,y,{t,s:$(18,26),dx:Math.cos(a)*v,dy:Math.sin(a)*v,g:$(60,120),rot:$(-60,60),d:$(1100,1500)})});
}
function pop(x,y,t){
  if(rm.matches)return;
  for(let i=0;i<6;i++)spawn(x,y,{t,s:$(16,26),dx:$(-46,46),dy:$(-120,-60),g:0,rot:$(-40,40),d:$(650,950)});
}
function flash(card,badge){
  if(rm.matches||!card)return;
  badge&&badge.animate([{transform:'scale(1)'},{transform:'scale(1.3)'},{transform:'scale(1)'}],{duration:420,easing:'cubic-bezier(.3,1.6,.5,1)'});
  setTimeout(()=>{const c=getComputedStyle(card).getPropertyValue('--c').trim()||'#999';
    card.animate([{boxShadow:`0 0 0 0 ${c}`},{boxShadow:`0 0 0 4px ${c}, 0 0 28px 2px ${c}`,offset:.35},{boxShadow:`0 0 0 0 transparent`}],{duration:1100,easing:'ease-out'})},380);
}
window.fx={confetti,pop};

// ---- tap feedback (capture phase: runs before app.js re-renders the DOM) ----
const RIP='.cta,.dir,.ln,.pk,.lst,.hx,.shr,.bk,.hq,.tg,.seg button,.vt button';
document.addEventListener('pointerdown',e=>{
  if(rm.matches)return;const b=e.target.closest(RIP);if(!b||b.disabled)return;
  const r=b.getBoundingClientRect(),d=Math.max(r.width,r.height)*2.2,cs=getComputedStyle(b);
  if(cs.position==='static')b.style.position='relative';if(cs.overflow==='visible')b.style.overflow='hidden';
  const s=document.createElement('span');s.className='rp';
  Object.assign(s.style,{width:d+'px',height:d+'px',left:e.clientX-r.left-d/2+'px',top:e.clientY-r.top-d/2+'px'});
  b.appendChild(s);setTimeout(()=>s.remove(),700);
},{passive:true,capture:true});
document.addEventListener('click',e=>{
  const t=e.target;let b=t.closest('[data-v],[data-iv]');
  if(b){const v=+(b.dataset.iv||b.dataset.v),r=b.getBoundingClientRect();pop(r.left+r.width/2,r.top+r.height/2,v>0?'👍':'👎')}
  if(b=t.closest('[data-j]'))flash(document.getElementById('l'+b.dataset.j),b);
  if(b=t.closest('[data-share]')){b.classList.remove('go');void b.offsetWidth;b.classList.add('go')}
},true);
})();
