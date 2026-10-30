const V='mh21',F=['./','index.html','app.js','style.css','config.js','manifest.webmanifest','img/hero.webp'];
self.addEventListener('install',e=>{e.waitUntil(caches.open(V).then(c=>c.addAll(F)));self.skipWaiting()});
self.addEventListener('activate',e=>e.waitUntil(caches.keys().then(k=>Promise.all(k.filter(x=>x!==V).map(x=>caches.delete(x))))));
self.addEventListener('fetch',e=>{const u=new URL(e.request.url);if(u.origin!==location.origin||u.pathname.startsWith('/api/')||e.request.method!=='GET')return;
 e.respondWith(caches.open(V).then(c=>c.match(e.request).then(m=>{const n=fetch(e.request).then(r=>{c.put(e.request,r.clone());return r}).catch(()=>m);return m||n})))});
