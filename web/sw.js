const V='mh59',F=['./','index.html','app.js','style.css','config.js','manifest.webmanifest','img/hero.webp','fx.js','icons/logo.svg'];
self.addEventListener('install',e=>{e.waitUntil(caches.open(V).then(c=>c.addAll(F)));self.skipWaiting()});
self.addEventListener('activate',e=>e.waitUntil(caches.keys().then(k=>Promise.all(k.filter(x=>x!==V).map(x=>caches.delete(x)))).then(()=>self.clients.claim())));
self.addEventListener('fetch',e=>{const u=new URL(e.request.url);if(u.origin!==location.origin||u.pathname.startsWith('/api/')||u.pathname.startsWith('/admin')||e.request.method!=='GET')return;
 // v0.52: network first (4 s), cache only as offline fallback: the page, JS and CSS always come from the same release
 e.respondWith(caches.open(V).then(c=>{const n=fetch(e.request).then(r=>{if(r.ok)c.put(e.request,r.clone());return r});return Promise.race([n,new Promise((_,j)=>setTimeout(j,4000))]).catch(()=>c.match(e.request).then(m=>m||n))}))});
