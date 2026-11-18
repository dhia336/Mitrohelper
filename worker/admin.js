// v0.35 admin backend (v0.36: filters on /recent, scored /suspects, /device profile, actions ok/unok/undo_votes). Disabled (404) unless ALL THREE secrets exist: ADMIN_PASSWORD_HASH, ADMIN_TOTP_SECRET, ADMIN_SESSION_SECRET.
// Create them with `node tools/admin-setup.mjs` (see README "Admin page"). Nothing here is reachable cross-origin: no CORS headers at all.
import PAGE from './admin.html';

const enc = new TextEncoder();
const b64u = b => btoa(String.fromCharCode(...new Uint8Array(b))).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
const unb64u = s => Uint8Array.from(atob(s.replace(/-/g, '+').replace(/_/g, '/')), c => c.charCodeAt(0));
const sha = async s => b64u(await crypto.subtle.digest('SHA-256', enc.encode(s)));
const same = (a, b) => { // constant-time compare of two equal-purpose byte arrays
  if (a.length !== b.length) return false;
  let d = 0; for (let i = 0; i < a.length; i++) d |= a[i] ^ b[i]; return d === 0;
};
const hmac = async (secret, data, hash = 'SHA-256') => new Uint8Array(await crypto.subtle.sign('HMAC',
  await crypto.subtle.importKey('raw', typeof secret === 'string' ? enc.encode(secret) : secret, { name: 'HMAC', hash }, false, ['sign']), enc.encode(data)));

const SESSION_IDLE = 30 * 60, SESSION_MAX = 8 * 3600; // seconds: 30 min idle, 8 h absolute
const KEY = /^[A-Za-z0-9_-]{16,64}$/;

// ---- password: "pbkdf2$100000$<salt>$<hash>" (Workers cap PBKDF2 at 100000 iterations) ----
async function pwOk(env, pw) {
  const [alg, it, salt, hash] = String(env.ADMIN_PASSWORD_HASH || '').split('$');
  if (alg !== 'pbkdf2' || !salt || !hash) return false;
  const k = await crypto.subtle.importKey('raw', enc.encode(String(pw).slice(0, 200)), 'PBKDF2', false, ['deriveBits']);
  const out = new Uint8Array(await crypto.subtle.deriveBits({ name: 'PBKDF2', hash: 'SHA-256', salt: unb64u(salt), iterations: Math.min(+it || 100000, 100000) }, k, 256));
  return same(out, unb64u(hash));
}

// ---- TOTP (RFC 6238, SHA-1, 6 digits, 30 s). Returns the matching time step or null ----
const B32 = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ234567';
function b32(s) { let bits = '', out = []; for (const c of s.replace(/[\s=]/g, '').toUpperCase()) { const v = B32.indexOf(c); if (v < 0) return null; bits += v.toString(2).padStart(5, '0'); } for (let i = 0; i + 8 <= bits.length; i += 8) out.push(parseInt(bits.slice(i, i + 8), 2)); return new Uint8Array(out); }
async function totpStep(env, code) {
  const key = b32(env.ADMIN_TOTP_SECRET || ''); if (!key || !/^\d{6}$/.test(String(code))) return null;
  const now = Math.floor(Date.now() / 30000);
  let hit = null;
  for (const step of [now - 1, now, now + 1]) { // always check all three (no early exit)
    const buf = new ArrayBuffer(8); new DataView(buf).setUint32(4, step);
    const h = new Uint8Array(await crypto.subtle.sign('HMAC', await crypto.subtle.importKey('raw', key, { name: 'HMAC', hash: 'SHA-1' }, false, ['sign']), buf));
    const o = h[19] & 15, n = (((h[o] & 127) << 24) | (h[o + 1] << 16) | (h[o + 2] << 8) | h[o + 3]) % 1e6;
    if (same(enc.encode(String(n).padStart(6, '0')), enc.encode(String(code)))) hit = step;
  }
  return hit;
}

// ---- session cookie: base64url("iat.exp.uaHash") + "." + HMAC ----
const cookieName = u => (u.hostname === 'localhost' ? 'mhadm' : '__Host-mhadm');
async function mint(env, u, ua, iat) {
  const now = Math.floor(Date.now() / 1000), exp = Math.min(now + SESSION_IDLE, iat + SESSION_MAX);
  const body = b64u(enc.encode(`${iat}.${exp}.${(await sha(ua)).slice(0, 16)}`));
  const sig = b64u(await hmac(env.ADMIN_SESSION_SECRET, body));
  const secure = u.hostname === 'localhost' ? '' : '; Secure';
  return `${cookieName(u)}=${body}.${sig}; Path=/; HttpOnly; SameSite=Strict${secure}; Max-Age=${exp - now}`;
}
async function session(env, req, u) {
  const m = (req.headers.get('cookie') || '').split(/;\s*/).find(c => c.startsWith(cookieName(u) + '='));
  if (!m) return null;
  const [body, sig] = m.slice(cookieName(u).length + 1).split('.');
  if (!body || !sig) return null;
  if (!same(await hmac(env.ADMIN_SESSION_SECRET, body), (() => { try { return unb64u(sig); } catch { return new Uint8Array(0); } })())) return null;
  const [iat, exp, ua] = new TextDecoder().decode(unb64u(body)).split('.');
  const now = Math.floor(Date.now() / 1000);
  if (+exp < now || +iat + SESSION_MAX < now) return null;
  if (ua !== (await sha(req.headers.get('user-agent') || '')).slice(0, 16)) return null;
  return { iat: +iat };
}

const SEC = { 'cache-control': 'no-store', 'x-content-type-options': 'nosniff', 'referrer-policy': 'no-referrer', 'x-robots-tag': 'noindex, nofollow, noarchive', 'cross-origin-resource-policy': 'same-origin', 'strict-transport-security': 'max-age=31536000' };
const ipKey = async req => { const ip = req.headers.get('CF-Connecting-IP') || '?'; return (await sha(ip.includes(':') ? ip.split(':').slice(0, 4).join(':') : ip)).slice(0, 22); }; // IPv6 grouped by /64-ish prefix

export async function adminRoute(req, env, ctx, u, sb) {
  const p = u.pathname;
  if (!env.ADMIN_PASSWORD_HASH || !env.ADMIN_TOTP_SECRET || (env.ADMIN_SESSION_SECRET || '').length < 32) return new Response('Not found', { status: 404, headers: SEC });

  if (p === '/admin' || p === '/admin/') {
    if (req.method !== 'GET') return new Response('Method not allowed', { status: 405, headers: SEC });
    const nonce = b64u(crypto.getRandomValues(new Uint8Array(16)));
    return new Response(PAGE.replaceAll('__NONCE__', nonce), { headers: { ...SEC, 'content-type': 'text/html; charset=utf-8',
      'content-security-policy': `default-src 'none'; script-src 'nonce-${nonce}'; style-src 'unsafe-inline'; connect-src 'self'; img-src data:; base-uri 'none'; form-action 'none'; frame-ancestors 'none'`,
      'x-frame-options': 'DENY', 'cross-origin-opener-policy': 'same-origin', 'permissions-policy': 'camera=(), microphone=(), geolocation=()' } });
  }

  const R = (b, s = 200, h = {}) => new Response(JSON.stringify(b), { status: s, headers: { ...SEC, 'content-type': 'application/json', ...h } });
  const sub = p.slice('/api/admin/'.length);
  // same-origin only: custom header (forces a CORS preflight that we never answer) + Origin check on POST + Fetch-Metadata
  if (req.headers.get('x-mh-admin') !== '1') return R({ r: 'bad' }, 400);
  if (req.method === 'POST' && req.headers.get('origin') !== u.origin) return R({ r: 'bad' }, 403);
  const fs = req.headers.get('sec-fetch-site'); if (fs && fs !== 'same-origin') return R({ r: 'bad' }, 403);
  const ua = req.headers.get('user-agent') || '';

  if (sub === 'login' && req.method === 'POST') {
    const ik = await ipKey(req);
    const nf = await sb('rpc/admin_login_fails', { p_ip: ik });
    if (typeof nf !== 'number' || nf >= 5) return R({ r: 'locked' }, 429); // fails CLOSED if the database errors
    const b = await req.json().catch(() => ({}));
    const okPw = await pwOk(env, b.pw || '');        // always computed, whatever the code is
    const step = await totpStep(env, b.otp || '');
    const fresh = okPw && step !== null ? await sb('rpc/admin_otp_use', { p_step: step }) : false; // a code works once
    if (okPw && step !== null && fresh === true) {
      return R({ r: 'ok' }, 200, { 'set-cookie': await mint(env, u, ua, Math.floor(Date.now() / 1000)) });
    }
    await sb('rpc/admin_login_fail', { p_ip: ik });
    return R({ r: 'fail' }, 401);
  }

  const s = await session(env, req, u);
  if (!s) return R({ r: 'auth' }, 401);
  const renew = { 'set-cookie': await mint(env, u, ua, s.iat) }; // sliding 30 min, hard stop 8 h after login
  const ok = b => R(b, 200, renew);
  const ik = await ipKey(req);

  if (sub === 'logout' && req.method === 'POST') return R({ r: 'ok' }, 200, { 'set-cookie': `${cookieName(u)}=; Path=/; HttpOnly; SameSite=Strict${u.hostname === 'localhost' ? '' : '; Secure'}; Max-Age=0` });
  if (req.method === 'GET') {
    if (sub === 'ping') return ok({ r: 'ok' });
    if (sub === 'stats') return ok(await sb('rpc/admin_stats', {}));
    if (sub === 'insights') { const d = +(u.searchParams.get('days') || 21); const bk = +(u.searchParams.get('bucket') || 15); return ok(await sb('rpc/admin_insights', { p_days: Number.isInteger(d) && d >= 7 && d <= 90 ? d : 21, p_bucket: [15, 30, 60].includes(bk) ? bk : 15 })); } // v0.56 share images
    if (sub === 'recent') { // v0.36 filters: every value is validated here AND bound as a function argument in SQL (no string building)
      const q = u.searchParams, g = k => (q.get(k) || '').trim(), n = (k, lo, hi) => { const v = g(k); return /^\d{1,10}$/.test(v) && +v >= lo && +v <= hi ? +v : null; };
      const line = g('line'), dev = g('dev'), st = g('status'), dir = g('dir'), station = g('station').slice(0, 40);
      return ok(await sb('rpc/admin_recent', {
        p_limit: n('limit', 1, 200) || 80,
        p_line: /^[0-9A-Za-z]{1,6}$/.test(line) ? line : null,
        p_dir: dir === 'a' || dir === 'b' ? dir : null,
        p_status: ['hidden', 'rejected', 'confirmed', 'paused', 'banned', 'flagged'].includes(st) ? st : null,
        p_dev: /^[A-Za-z0-9_-]{4,64}$/.test(dev) ? dev : null,
        p_hours: n('hours', 1, 2160),
        p_before: n('before', 1, 9e15),
        p_station: station.length >= 2 ? station : null }));
    }
    if (sub === 'feedback') { const q = u.searchParams, sh = q.get('show'), l = +(q.get('limit') || 100); return ok(await sb('rpc/admin_feedback', { p_show: ['new', 'read', 'all'].includes(sh) ? sh : 'new', p_limit: Number.isInteger(l) && l >= 1 && l <= 200 ? l : 100 })); } // v0.48 riders' messages
    if (sub === 'incidents') return ok(await sb('rpc/admin_incidents', {}));
    if (sub === 'suspects') { const d = +(u.searchParams.get('days') || 7); return ok(await sb('rpc/admin_suspects', { p_days: Number.isInteger(d) && d >= 1 && d <= 30 ? d : 7 })); }
    if (sub === 'device') { const k = u.searchParams.get('k') || ''; if (!KEY.test(k)) return R({ r: 'bad' }, 400); return ok(await sb('rpc/admin_device', { p_k: k })); }
    if (sub === 'banned') return ok(await sb('rpc/admin_banned', {}));
    if (sub === 'log') return ok(await sb('rpc/admin_log_list', { p_limit: 80 }));
  }
  if (sub === 'fb' && req.method === 'POST') { // v0.48: mark read / unread / delete a rider message
    const b = await req.json().catch(() => ({}));
    const id = Number.isInteger(b.id) && b.id > 0 ? b.id : null;
    if (!['read', 'unread', 'delete', 'readall'].includes(b.a) || (b.a !== 'readall' && !id)) return R({ r: 'bad' }, 400);
    const r = await sb('rpc/admin_feedback_act', { p_act: b.a, p_id: id, p_ip: ik });
    if (typeof r !== 'string') return R({ r: 'db' }, 500);
    return ok({ r });
  }
  if (sub === 'act' && req.method === 'POST') {
    const b = await req.json().catch(() => ({}));
    if (!['del_sighting', 'del_incident', 'ban', 'unban', 'purge_dev', 'ok', 'unok', 'undo_votes'].includes(b.a)) return R({ r: 'bad' }, 400);
    const id = Number.isInteger(b.id) && b.id > 0 ? b.id : null, k = typeof b.k === 'string' && KEY.test(b.k) ? b.k : null;
    if ((b.a.startsWith('del_') && !id) || (!b.a.startsWith('del_') && !k)) return R({ r: 'bad' }, 400);
    const r = await sb('rpc/admin_act', { p_act: b.a, p_id: id, p_k: k, p_note: typeof b.note === 'string' ? b.note.slice(0, 200) : null, p_ip: ik });
    if (typeof r !== 'string') return R({ r: 'db' }, 500);
    if (r === 'ok') for (const q of ['/api/live', '/api/lb?p=week', '/api/lb?p=last', '/api/lb?p=month']) ctx.waitUntil(caches.default.delete(new Request(u.origin + q))); // moderation shows up for riders within seconds
    return ok({ r });
  }
  return R({ r: 'bad' }, 404);
}
