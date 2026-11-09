// ONE Worker = website (web/ via the ASSETS binding) + API (/api/*). The only thing allowed to write to Supabase.
// Plain vars live in wrangler.toml (SUPABASE_URL, ALLOWED_ORIGIN). Secrets (set once): SUPABASE_SERVICE_KEY, CRON_KEY, TURNSTILE_SECRET (optional).
import{adminRoute}from'./admin.js';
const int=x=>Number.isInteger(x)&&x>0&&x<1e12, devOk=d=>typeof d=='string'&&d.length>=16&&d.length<=64;
export default{async fetch(req,env,ctx){
 const u=new URL(req.url),p=u.pathname;
 if(p=='/admin'||p=='/admin/'||p.startsWith('/api/admin/')){ // v0.35 admin: own auth, own headers, NO cors (see worker/admin.js)
  const ah={apikey:env.SUPABASE_SERVICE_KEY,Authorization:'Bearer '+env.SUPABASE_SERVICE_KEY,'Content-Type':'application/json'};
  const asb=async(path,body)=>(await fetch(env.SUPABASE_URL+'/rest/v1/'+path,{method:'POST',headers:ah,body:JSON.stringify(body||{})})).json();
  return adminRoute(req,env,ctx,u,asb).catch(e=>{console.log('admin error',String(e));return new Response('{"r":"err"}',{status:500,headers:{'content-type':'application/json','cache-control':'no-store'}})})}
 if(!p.startsWith('/api/'))return env.ASSETS.fetch(req); // everything else = the website files (web/)
 const o=req.headers.get('origin')||'',al=(env.ALLOWED_ORIGIN||'*').split(',').map(s=>s.trim());
 const cors={'access-control-allow-origin':al.includes('*')?'*':al.includes(o)?o:al[0],'access-control-allow-headers':'content-type','access-control-allow-methods':'GET,POST,OPTIONS',vary:'origin'};
 const J=(b,s=200,h={})=>new Response(JSON.stringify(b),{status:s,headers:{...cors,'content-type':'application/json',...h}});
 const hd={apikey:env.SUPABASE_SERVICE_KEY,Authorization:'Bearer '+env.SUPABASE_SERVICE_KEY,'Content-Type':'application/json'};
 const sb=async(path,body)=>(await fetch(env.SUPABASE_URL+'/rest/v1/'+path,{method:body?'POST':'GET',headers:hd,body:body?JSON.stringify(body):undefined})).json();
 const liveKey=new Request(u.origin+'/api/live');
 const cached=async(key,ttl,build)=>{const c=caches.default;let r=await c.match(key);if(r)return r;r=J(await build(),200,{'cache-control':'public, max-age='+ttl});ctx.waitUntil(c.put(key,r.clone()));return r};
 try{
  if(req.method=='OPTIONS')return new Response(null,{headers:cors});
  if(req.method=='GET'&&p=='/api/data')return cached(req,300,async()=>{const[lines,stations]=await Promise.all([sb('lines?select=*&order=sort'),sb('stations?select=*&order=line_id,pos')]);return{lines,stations}});
  if(req.method=='GET'&&p=='/api/live')return cached(liveKey,20,async()=>{let r=await sb('rpc/live_all',{}); // one query (supabase/archive/migrate_v4.sql, included in schema.sql); fallback to 2 queries if the function is not installed yet
   if(!r||!Array.isArray(r.s)){const[s,i]=await Promise.all([sb('live?select=*'),sb('live_incidents?select=*')]);if(!Array.isArray(s))throw 0;r={s,i}}r.t=Date.now();return r});
  if(req.method=='GET'&&p=='/api/typ'){ // v0.34 typical headways, edge-cached 10 min
   return cached(new Request(u.origin+'/api/typ'),600,async()=>{const r=await sb('rpc/typical_gaps',{});if(!r||!Array.isArray(r.rows))throw 0;return r})}
  if(req.method=='GET'&&p=='/api/lb'){const per=['week','last','month'].includes(u.searchParams.get('p'))?u.searchParams.get('p'):'week'; // v0.29 public top 10 (no device ids), edge-cached 60s per period
   return cached(new Request(u.origin+'/api/lb?p='+per),60,async()=>{const r=await sb('rpc/leaderboard',{p_period:per});if(!r||!Array.isArray(r.rows))throw 0;return r})}
  if(p=='/api/cron'){if(!env.CRON_KEY||req.headers.get('x-cron-key')!==env.CRON_KEY)return J({r:'denied'},403);return J({r:'ok',purged:await sb('rpc/purge_old',{})})}
  if(req.method!='POST')return J({r:'bad'},404);
  if(!al.includes('*')&&o&&!al.includes(o))return J({r:'bad'},403);
  const b=await req.json().catch(()=>null);if(!b||!devOk(b.dev))return J({r:'bad'},400);
  if(p=='/api/hit'){const src=typeof b.src=='string'&&/^[a-z0-9_-]{0,20}$/i.test(b.src)?b.src:'';const r=await sb('rpc/hit',{p_dev:b.dev,p_src:src,p_sa:b.sa===true});return typeof r=='string'?J({r}):J({r:'db'},500)} // v0.28: anonymous once-a-day visit (no IP stored)
  if(p=='/api/me'){const r=await sb('rpc/my_stats',{p_dev:b.dev});return r&&typeof r=='object'?J({r}):J({r:'db'},500)} // v0.28: {reports,confirms} of this device, last 30 days
  const ip=req.headers.get('CF-Connecting-IP')||'?',base={p_dev:b.dev,p_ip:ip};let fn,args,human=false;
  if(p=='/api/report'&&int(b.station)&&(b.dir=='a'||b.dir=='b')){fn='report';args={...base,p_station:b.station,p_dir:b.dir};human=true}
  else if(p=='/api/incident'&&int(b.station)){fn='report_incident';args={...base,p_station:b.station};human=true}
  else if((p=='/api/vote'||p=='/api/ivote')&&int(b.id)&&(b.v==1||b.v==-1)){fn=p=='/api/vote'?'vote':'vote_incident';args={...base,p_id:b.id,p_v:b.v}}
  else return J({r:'bad'},400);
  if(human&&env.TURNSTILE_SECRET){const f=new FormData();f.append('secret',env.TURNSTILE_SECRET);f.append('response',b.ts||'');f.append('remoteip',ip);
   const v=await(await fetch('https://challenges.cloudflare.com/turnstile/v0/siteverify',{method:'POST',body:f})).json();if(!v.success){console.log('turnstile rejected',JSON.stringify(v['error-codes']),'host',v.hostname);return J({r:'bot',c:v['error-codes']||[]},403)}}
  const r=await sb('rpc/'+fn,args);if(r==='ok')ctx.waitUntil(caches.default.delete(liveKey));
  if(typeof r!='string'){console.log('rpc failed',fn,JSON.stringify(r).slice(0,300));return J({r:'db'},500)}return J({r});
 }catch(e){console.log('worker error',String(e));return J({r:'err'},500)}}};
