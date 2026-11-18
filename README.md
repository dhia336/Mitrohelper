# MitroHelper (Tuni-Mitrovic)
Crowd-sourced live sightings for Tunis light metro (lines 1-6). 3 taps to report; live board per line/direction; ar/fr/en; installable PWA. Free stack, no build step.

## Layout
One line per file (everything else in the repo is generated or ignored, see `.gitignore`).
```
wrangler.toml                    Worker config: SUPABASE_URL, ALLOWED_ORIGIN, ASSETS binding, staging env
.dev.vars.staging.example        template for local/staging secrets (copy to .dev.vars.staging, never commit the real one)
tools/admin-setup.mjs            one-time generator of the admin secrets (password hash, TOTP secret, session secret)
worker/index.js                  the ONE Worker: serves web/ (ASSETS) + /api/*; the only writer to Supabase; edge cache; Turnstile
worker/admin.js                  admin backend: login (password + TOTP), session cookie, /api/admin/* routes and input validation
worker/admin.html                admin page (one file: CSS + JS, light/dark, phone layout)
web/index.html                   page shell, header, SVG icon sprite
web/app.js                       all rider-site logic: i18n dictionary T (ar/fr/en), render, report/vote sheet, leaderboard, What's new, Metro/Others tabs (setTab) and the static Others page (B4 bus data, othHTML)
web/style.css                    all rider-site styles (design tokens, light/dark)
web/fx.js                        theme toggle + tap animations (ripple, vote bursts, confetti)
web/config.js                    API base and Turnstile site key (localhost/staging use Cloudflare's dummy key)
web/sw.js                        offline shell cache; bump the version string V on EVERY release that changes web files
web/manifest.webmanifest         install-as-app manifest
web/icons/logo.svg, 192.png, 512.png   the one logo and its PNG renders
web/img/hero.webp                header photo
web/robots.txt, web/sitemap.xml  SEO files (canonical URL = the workers.dev address, see PROGRESS 27)
web/google7f4e3cc9d4fededa.html  Google Search Console ownership verification: DO NOT DELETE
supabase/schema.sql              complete fresh install: tables, RLS, functions, seed data, everything up to the latest migration (v17)
supabase/migrate_v14.sql         admin tables/functions (also inside schema.sql)
supabase/migrate_v15.sql         admin filters, scored suspects, device profile, reviewed list, undo downvotes (also inside schema.sql)
supabase/migrate_v16.sql         interchange stations: other lines inside the 2-minute window (also inside schema.sql)
supabase/migrate_v17.sql         same station + line, opposite direction (also inside schema.sql)
supabase/archive/                migrate_v2 .. v13 and prod_catchup: already inside schema.sql, kept only to upgrade a DB older than v14 (see its README)
supabase/migrate_v24.sql         buses: lines.kind + line 4C (also in rebuild_test_db.sql)
supabase/migrate_v25.sql         same-train window grows with confirmations (report merge 3..11 min, live view 4..12 min)
supabase/test_seed.sql           STAGING ONLY sample data (empties sightings and incidents): NEVER run on production
supabase/admin_queries.sql       read-only abuse-review and retention queries (the admin Suspects tab covers the abuse ones)
README.md, PROGRESS.md           this overview and the numbered log (older entries: docs/PROGRESS_ARCHIVE.md)
```

## Architecture
One Cloudflare Worker serves the site (web/, ASSETS binding) and the API (/api/*) -> Supabase REST. Anon can only SELECT `lines`, `stations`, `live` (view hides device/IP). Writes ONLY via `report()` and `vote()` (security definer).
Anti-spam: 1 report/2 min per device AND per IP hash, max 30/h per IP, one vote per device per sighting, sighting hidden when downvotes exceed upvotes by 2, never expires (shown dimmed after 45 min, see v0.21).
Directions: `a` = toward highest `pos` station, `b` = toward lowest. Add stations by inserting rows with `pos` between neighbours.

## v0.21: theme toggle, one logo, 45-min timer, animations
- **Theme**: `<html data-theme="light|dark">`, set by an inline script in `index.html` BEFORE first paint: stored choice (`localStorage.theme`) else the system setting. The header moon/sun button (`.tg`, `fx.js`) flips it and stores the choice; with no stored choice the page follows live changes of the system setting. CSS: dark variables live under `:root[data-theme=dark]` (+ a `prefers-color-scheme` fallback on `:root:not([data-theme])`). Switching uses a circular reveal from the button (View Transitions API; instant where unsupported or with reduced motion). There is no way back to 'follow system' from the UI (clear `theme` in site data).
- **Logo**: `web/icons/logo.svg` (yellow rounded square, green tram) is used by the header (`<img class="lg">`) and the tab (`<link rel=icon>` svg + 192 png). `icons/192.png`/`512.png` (home-screen/maskable) are full-bleed renders of the same logo. To change the logo, edit `logo.svg` and re-render the two PNGs.
- **45 minutes** (`ST=45` in app.js; SQL `supabase/archive/migrate_v10.sql`: `live` view + `live_all().n`). Freshness colours: green < 15 min, amber < 30, orange < 45, then dimmed/dashed 'last known' (`fz()`). Wording in `hwi` and `n45` (3 languages) updated. Sightings 45-90 min old are now dimmed immediately, unless they are among the last 3 of the line (the floor). Stop alerts stay 15 min.
- **Animations** (`fx.js`, all skipped with `prefers-reduced-motion`): ripple on buttons, 👍/👎 burst on votes, card flash + badge bounce when using the jump bar, upload-icon fly + confetti when sharing succeeds (native share finished or link copied), confetti on the report 'thanks' screen. Particles live in `#fx` (fixed overlay, `pointer-events:none`, Web Animations API, nothing runs when idle). `window.fx.confetti(x,y)` / `fx.pop(x,y,emoji)` are called from app.js (`share()`, `finish()`).
- **v0.25 error codes** (CAPTCHA codes extended in v0.42, see the section below): failed report/vote toast ends with `[code]`: `bot` = Turnstile rejected (`: <cloudflare error code>`), `db` = Supabase RPC returned an error (details in `npx wrangler tail`), `net` = no/invalid response, `err` = Worker exception.
- **v0.23: line numbers black in light mode, white in dark mode** (`--nt` var in style.css; `fg()` returns `var(--nt)`). v0.22 was all dark (`fg()` returned `#10241a`; old black/white rule kept as `fgOld`). Looping CTA pulse + icon wiggle (`.cta:not(.bad)`, CSS). Before v0.22 the numbers mixed black/white: `fg()` picks dark digits on light line colours (TGM lime, 3 teal, 2 amber) and white digits on the others, because white on those three fails contrast. Make all white: `fg=c=>'#fff'` in app.js.

## UI: line cards always expanded
Line cards are always fully expanded (header, direction rows, full station track) with no collapse control. A sticky line-jump bar (`.jb`, one coloured badge per line, red dot if that line has a live stop alert) sits under the header; tapping a badge smooth-scrolls to `#l<id>` (`data-j` handler in app.js; `--hh` = header height set by `hh()`). v0.11 removed the `data-tog` handler, chevron, `open` Set and `.tk` collapse CSS.

## v0.20: card readability (frontend only)
- **Arrows** are bold SVG icons (`ARW(d)`, `.aw`), not the thin text glyphs ↓ ↑ ⇄: a round badge `.dg` in the line colour next to 'toward X' (a = down = toward the last station, b = up), and inside every chip.
- **Sighting row** = station name as the headline (`.sn`, 1.25rem bold) + a time pill (`.tm`) coloured by freshness (`fz()`: green < 20 min, amber < 1 h, orange < 90 min, grey dashed = older = last known) + a thicker bar in the same colour. Old sightings are no longer faded with opacity (it hurt readability), they use a dashed pill and muted name.
- **Vote buttons** are 44px tall (`.vt button`). The stop-alert buttons are one line each.
- **Station list**: bigger rows and chips; chip text is compact without 'ago' (`durX`: `18min`, `1h 18min`, `1d 1h`; fr/ar equivalents); chip arrow + `aria-label`/`title` 'toward X · time ago'.
- **Text colour on line colours**: `fg()` picks dark text for light line colours (lime TGM, teal 3, amber 2) and white for the rest, via `--ct` on the card, jump bar and sheet buttons.
- Looked at with a headless Chromium on mock data (Arabic dark, English light, 360px and 390px wide, TGM, stop alert, old sightings); not yet on a real phone.

## Production catch-up (v0.26)
`supabase/archive/prod_catchup_v4_to_v10.sql` = migrate_v4..v10 concatenated in order; safe to re-run. Use it when production reports `[db]` (see v0.25 error codes) or after a long time without migrating. Check what production has: `select proname from pg_proc where proname in ('is_blocked','live_all','report','vote','report_incident','vote_incident');` (must return 6 rows) and `select count(*) from information_schema.columns where table_name='votes' and column_name='ip';` (must be 1).

## Testing before deploying (v0.16)
Never test on the live site. Use a second (free) Supabase project and a `staging` environment of the same Worker (`[env.staging]` in wrangler.toml); no code is duplicated.
1. Supabase: create a project `mitrohelper-test`. SQL editor: run `supabase/schema.sql` (contains everything up to the latest migration, v17), then `supabase/test_seed.sql` for sample data. NEVER run test_seed.sql on production (it empties the tables).
2. wrangler.toml: put the test project URL in `[env.staging.vars] SUPABASE_URL`.
3. Secrets (not inherited by environments): `npx wrangler secret put SUPABASE_SERVICE_KEY --env staging` (TEST project key) and `npx wrangler secret put TURNSTILE_SECRET --env staging` with Cloudflare's dummy secret `1x0000000000000000000000000000000AA`. For local runs copy `.dev.vars.staging.example` to `.dev.vars.staging` (gitignored; when it exists only it is loaded).
4. Local: `npx wrangler dev --env staging` -> http://localhost:8787. Online test copy (for phones): `npx wrangler deploy --env staging` -> https://mitrohelper-staging.dhia336.workers.dev. `web/config.js` automatically uses Turnstile's dummy always-pass key on localhost and on any host containing 'staging'; every other host gets the real key (safe default).
5. Release routine: change -> local -> staging on a phone -> run the SQL migration on production -> plain `npx wrangler deploy` for production (Wrangler may warn that several environments exist; add `--env=""` to silence). Order: SQL first, then Worker/web.
6. Service worker: while testing, DevTools > Application > 'Update on reload', or clear site data, otherwise you may see the old cached files.
Test the auto-pause: after test_seed.sql, in the test site's console run `localStorage.dev='seed-troll-device-000001'; location.reload()` then try to report: you get the 'Reports paused' message.

## v0.18: same-train merge + Arabic station names
**Merge** (`supabase/archive/migrate_v9.sql`, new `report()`): a new sighting that matches an older one (same station and direction, i.e. same line; older one <= 3 min old; not hidden by votes) deletes the older one and counts as +1 confirmation on the new one (its votes move over; the old reporter is recorded as having voted so they cannot also tap 👍; if the SAME device reported twice it is only replaced, no +1). A report at a different station is a separate sighting. Tune `v_mins` in the function. The `live` view's 4-min same-station collapse stays as a fallback. Stats note: merged old reports no longer exist in `sightings` (a `votes` row keeps their device).
**Arabic names**: The `ar` (Arabic name) column is seeded in `schema.sql` for all 106 stations (103 + Tunis Marine and Farhat Hached on line 1 + Carthage Salammbô on TGM, v0.50). (The old one-off scripts `station_names_ar.sql` and `update_stations.sql` were deleted in v0.40: `schema.sql` holds the same data, and the second one wiped all sightings.) Edit one: `update stations set ar='...' where line_id='4' and pos=80;`. `/api/data` (lines + stations) is cached 5 min at the edge AND in the browser (v0.19; it was 1 h, which hid name changes), so edits show up by themselves. For an instant refresh bump `?v=` in `get('/data?v=10')` in app.js. The service worker serves the previous app.js first: open the site twice after a deploy. The four stations that were once added directly in the database (L'Artisanat, L'Independance, L'Environnement, L'Aeroport) ARE in `schema.sql` (103 stations) and, since v0.40, with their Arabic names. A production DB that still shows French text for them in Arabic can be fixed with: `update stations set ar='الاستقلال' where fr ilike 'L%pendance'; update stations set ar='الصناعات التقليدية' where fr ilike 'L%Artisanat'; update stations set ar='البيئة' where fr ilike 'L%Environnement'; update stations set ar='المطار' where fr ilike 'L%roport';`

## v0.16: card top vs station list, durations, share, auto-pause
**Card top** = only the latest sighting of each direction (`SLOTS=1`). **Station list** (the expanded track) = EVERY sighting until its own 90-minute timer ends (`ST`), so busy hours show everything; plus the last 3 of the line (`TRK=3`, different station/direction) which never disappear, so quiet lines never look empty. Old ones (>90 min) are dimmed. A station can show several entries (different trains, or both directions). The `live` view (`archive/migrate_v8.sql`, replaces the v7 view) returns: all fresh sightings (cap 5 per line+direction, `rn<=5` in the view) + the 3 newest distinct station+direction per line+direction (30-day floor). Same train reported twice (same station+direction within 4 min of a newer report) = one row; rows hidden by votes are skipped. `live_all()` also returns `n` = real count of sightings in the last 90 min (hero chip).
**Durations**: under 60 min `5 min ago`; then `1h 1min ago`; from 24 h `1d 1h ago` (also fr `il y a 1 h 1 min`, ar `منذ 1 س 1 د`). Function `agoX` in app.js.
**Share**: a white pill button in the top corner of the hero image (always visible on load, 44px tall, labelled), plus on the 'thanks' screen after a report (it stays 3.5 s) and in the How-it-works sheet. Uses the phone's share sheet (`navigator.share`), otherwise copies the link and shows 'Link copied'.
**Automatic pause (no ban table, no cron)**: `is_blocked(dev)` = riders hid >=3 of the device's sightings in 24 h, or >=6 in 7 days (hidden = downvotes exceed upvotes by 2). `report`, `vote`, `report_incident`, `vote_incident` return `'blocked'` (toast 'Reports paused...') and it ends by itself as those sightings age out. Not counted: stop alerts (a real stop that ended quickly also gets voted away) and IP hashes (mobile carriers share one IP between many riders). Manual bans stay in the `banned` table; `supabase/admin_queries.sql` has review queries (rejected devices, bots, line-hopping, shared IPs) and the ban/unban statements.

## v0.15: frontend polish (no server/SQL change)
**Freshness label** (`#upd`, `upd()` in app.js): 'Updated 25s ago' under the hero. If a refresh fails (network error or a response without data) it turns red ('Can't refresh, last update 3 min ago') and the sticky line bar gets a red underline (`.jb.off`), so stale data is never silently trusted. Updated by a local 10s timer, no extra requests.
**Remembered last report**: after a successful report/stop, `localStorage.lastRep = {l,s,d}` (line, station, direction). In the 'I saw the metro' sheet a 'Same as last time' button (`data-last`) jumps straight to the direction step (3 taps -> 2). The remembered line, station and direction are also outlined (`.last`) in every step, and the station list scrolls to the remembered station. 'Metro stopped' never submits in one tap (accident-safe): it only highlights. Ignored if the saved line/station no longer exists.
**How it works sheet**: the round `?` button in the header opens a 6-point plain-language sheet (`hwi` in the i18n objects, 3 languages). It states the current rules (2 sightings per direction, 90 min fresh, stop = 15 min, votes). If you change those numbers, update `hwi`.

## v0.14: sightings, timers, polling
**Slots (superseded by v0.16: card top 1 per direction, station list 3 per line):** each line+direction showed its 2 newest sightings. Done in the `live` view (`supabase/archive/migrate_v6.sql`): top 2 per line+direction via `row_number()`, skipping rows hidden by votes (down-up>=2) and collapsing the same station+direction within 4 min (same train reported twice). Max 28 rows whatever the traffic; scans at most 30 days. **Never expire:** sightings no longer vanish at 45 min; after 90 min (`ST` in app.js) a sighting is shown dimmed ('3 h ago', no bar, no vote buttons, no mark on the station track) until 2 newer ones replace it. Only a line with no sighting for 30 days shows 'No report yet'. Purge stays at 90 days (`purge_old`).
**Timers:** the server sends absolute timestamps; the phone computes 'min ago' itself (`mins()`), so nothing is fetched to keep timers moving. `/api/live` also returns `t` (server time, up to 20s old because of the edge cache); the client keeps the offset (`clk`) so a wrong phone clock does not shift 'min ago'.
**Polling:** a poll every 20s while data changes; if two polls in a row return identical data the delay grows 20s -> 30s -> 45s -> 60s (max), and resets to 20s on any change, on your own report/vote, or when the tab becomes visible. Hidden tabs do not poll.

## Single page + scrolling (v0.13)
No tabs and no bottom nav: the app is the Metro board only (Louage tab removed v0.12; Map tab, `img/map.webp`, nav bar and tab logic removed v0.13). The two report buttons (`.ctas`) are pinned to the bottom. Smooth scroll: Lenis 1.3.11 (`dist/lenis.mjs`, dynamic `import()` since v0.24, NOT the classic min.js) loaded from jsDelivr by app.js ONLY when `(any-pointer:fine)` and not `prefers-reduced-motion` (touch devices keep native scrolling and download nothing); falls back to native scroll if the script is blocked. `data-lenis-prevent` on the report sheet (`#pan`) and map (`.mz`); jump-bar uses `lz.scrollTo` with a header+bar offset. To self-host: save the file as `web/lenis.min.js` and change the `sc.src` in app.js.

## v0.11: stop reports ('Metro stopped')
Rules live ONLY in the `live_incidents` view (`supabase/archive/migrate_v5.sql`): an alert is live while (a) a 'still stopped' confirmation arrived in the last 15 min (`last_at`; each distinct device's confirmation extends it, 'running again' votes do not), (b) running-again votes < stopped votes, (c) nobody reported a metro AT THAT STATION more than 2 min after the last confirmation (a train seen there = moving again). One alert per station; a new report on a live alert is a confirmation, on a dead one it starts a fresh alert with fresh counts. UI shows 'Still stopped · N' / 'Running again · M' on the buttons and 'last confirmed X ago'. Existing DB: run `archive/migrate_v5.sql`. Change the 15 min / 2 min numbers in the view only.

## v0.10: load + multi-train board
`GET /api/live` = ONE Supabase call (`rpc/live_all()`, `supabase/archive/migrate_v4.sql`, falls back to the 2 old queries if the function is missing), edge-cached 20s (same as the client poll interval, so users share one Supabase hit per Cloudflare datacenter per 20s). Client sends `cache:'no-store'` so the browser never adds a second cache layer, and only re-renders when data or a 'min ago' value changed. Direction cards: see v0.14. Station track still shows every live sighting. Fresh DB: `schema.sql` already includes v4. Existing DB: run `archive/migrate_v4.sql` BEFORE/with the Worker deploy.

## v0.8: single Worker
`wrangler.toml` deploys ONE Worker named `mitrohelper`: `web/` as static assets (free, unlimited) + `worker/index.js` for `/api/*`. `web/config.js` API is '' (same origin). Deploy: `npx wrangler deploy` or connect the GitHub repo in Workers & Pages (deploy command `npx wrangler deploy`). Secrets via `wrangler secret put` or dashboard. If the URL differs, edit `ALLOWED_ORIGIN` in wrangler.toml.

## v0.6 architecture change
The site no longer talks to Supabase directly. `web/` -> Cloudflare Worker (`worker/index.js`) -> Supabase. The Worker: caches reads (live 20s, lines/stations 1h), verifies Turnstile on reports/breakdowns, passes the real client IP, and is the only caller allowed to run the write functions (Supabase secret key lives only in the Worker). `/api/cron` (header `x-cron-key`) runs `purge_old()` and keeps the free DB awake; call it daily from cron-job.org.
Breakdown reports: `incidents` + `live_incidents` view, lifetime/vote rules: see v0.11.
Moderation: insert a device id or `md5(ip)` into table `banned`.

## Setup (see PROGRESS for status)
0. Existing DB: run `supabase/archive/migrate_v2.sql`. Fresh DB: `schema.sql` already includes it.
0b. Worker: Cloudflare > Workers & Pages > Create > paste `worker/index.js`; set variables above. Put the Worker URL (and Turnstile site key) in `web/config.js`.
1. Supabase free project -> SQL Editor -> run `supabase/schema.sql`.
2. Put URL + anon key in `web/config.js`.
3. Deploy `web/` to Cloudflare Pages (no build command, output dir `web`). Test locally: `cd web && python3 -m http.server`.

## v0.28: retention
`POST /api/hit {src,sa}` once a day per device (anonymous, no IP) -> table `visits`. `POST /api/me` -> `{reports,confirms}` (30 days) for the 'riders confirmed your reports' toast. Tag share links with `?src=<group>` to see which Facebook group brings people who come back. Details and rationale: PROGRESS 29.

## v0.29: leaderboard
🏆 pill in the hero opens a sheet (`S.mode=='lb'`, `lbHTML()` in app.js): weekly / last week / 30 days top 10 with generated nicknames, most-reported line badge, points, reports, 👍, days, station, plus the user's own rank. Server: `GET /api/lb?p=` (public, cached 60s) and `POST /api/me` (own rank). Rules and anti-farming: PROGRESS 30; audit query at the bottom of `supabase/admin_queries.sql`.

## v0.31: look and icons
Station-signage design (PROGRESS 32): coloured sign band per line card, departure-board line bar with minutes since the last sighting, hero tram on a rail. Icons are an inline SVG sprite at the top of `web/index.html`; use `IC('name')` in app.js, add a `<symbol id="i-name">` to add one. No web font (system stack) to keep first paint fast; how to add one is in PROGRESS 32.


## Prediction (v0.34, untested on production)
`typical_gaps()` (archive/migrate_v13.sql) learns, from the last 21 days of sightings, the gap between consecutive sightings at the same station and direction, per line/direction and bucket (weekday/weekend x 6-9, 9-16, 16-20, other). `GET /api/typ` (edge-cached 10 min) serves it; the client (`tyG`, `pred` in app.js) shows "Next at X: in A-B min" and "Usually every A-B min (estimate)" only when a bucket has n>=12 and >=3 distinct days (else all-day bucket, else nothing). `line_regimes(line_id, since)` makes a line ignore data before a schedule change (line 4: 2026-11-04). Kill switch: `CFG.PREDICT=false` in web/config.js. Gaps are biased upward (unreported trains), so A = p25 and B = median are shown.

## Admin page (v0.35, `/admin`)
**v0.48: 'Messages' tab** shows the riders' feedback (unread badge, mark read/unread, delete). SQL `migrate_v20.sql`, routes `GET /api/admin/feedback`, `POST /api/admin/fb`. See PROGRESS 63.

Statistics + moderation for the owner only. Disabled (answers 404) until all three secrets exist.
**Setup (once):** `node tools/admin-setup.mjs --put` (add `--env staging` for the test copy). It asks for a password (16+ chars, hidden input), stores `ADMIN_PASSWORD_HASH`, `ADMIN_TOTP_SECRET`, `ADMIN_SESSION_SECRET` with `wrangler secret put` and prints the authenticator key ONCE (add it to an authenticator app). Then run `supabase/migrate_v14.sql` (SQL first), `npx wrangler deploy`, open `https://<your-worker>/admin`. Re-running the script rotates everything and signs out all sessions.
**Security model (each layer independent):**
- Login = password (PBKDF2-SHA256, 100000 iterations, the Workers maximum) **and** a 6-digit authenticator code (RFC 6238). Both are always checked, the error is always the generic `Login failed`. A code works only once (`admin_otp_used`).
- 5 failed logins per network in 15 min -> locked (HTTP 429, table `admin_fails`); if the database errors the lock fails CLOSED.
- Session = HMAC-signed cookie (`__Host-` prefix, `HttpOnly`, `Secure`, `SameSite=Strict`), 30 min idle (sliding), 8 h hard limit, bound to the browser's user-agent. Stateless: to kill every session at once re-run the setup script (new session secret).
- CSRF/cross-site: no CORS headers on admin routes, every request needs header `x-mh-admin: 1`, POSTs must carry `Origin` = the site itself, `Sec-Fetch-Site` must be same-origin.
- Page: strict CSP (nonce script, no external resources, `frame-ancestors 'none'`), `no-store`, `noindex`; all data is inserted with `textContent` (no HTML injection from reports). The service worker never caches `/admin`.
- Database: all `admin_*` functions are `security definer`, callable by `service_role` only (explicitly revoked from `anon`/`authenticated`); the tables have RLS on with no policies. Every moderation action is written to `admin_log`.
**Screens:** Overview (reports 24h/7d/30d, reporters, visitors, new, installed app, live, alerts, hidden/paused/banned, 14-day chart, hour-of-day chart, per-line table with last sighting, top stations, `?src=` sources) · Moderate (latest 80 sightings + stop alerts: delete, ban device, purge a device's last 7 days; line filter) · Suspects (rejected / very active / line-hopping devices, shared networks) · Banned (unban) · Log. Deleting or banning clears the edge cache of `/api/live` and the leaderboards, so riders see it within seconds.

## v0.36: vote scroll fix, voted state, admin filters + suspects
**Rider page (`web/app.js`, `style.css`, `sw.js` mh37):** `render()` now inserts the new cards BEFORE removing the old ones and restores `scrollY` (before, the page got short for an instant and the browser jumped to the top after a vote). Votes give instant feedback: the tapped button is highlighted (`.on`), the other dimmed (`.dn`), count +1 at once, state remembered in `localStorage.vd` (`s<id>`/`i<id>` -> 1, -1, or 0 = server said already voted; newest 400 kept); a failed vote rolls the count back and shows the error toast. The jump bar marks the line card in view (`.lj.cur`, `spy()`).
**Admin (`worker/admin.js`, `worker/admin.html`, `supabase/migrate_v15.sql`; needs migrate_v14 first):**
- `GET /api/admin/recent` query params: `line, dir(a|b), status(hidden|rejected|confirmed|paused|banned|flagged), dev(prefix of device or network key, 4-64 chars), hours(1-2160), station(text, 2+ chars), before(id cursor), limit(1-200)`. Returns `{rows,total,more}`. All values validated in the Worker and bound as SQL function arguments.
- `GET /api/admin/suspects?days=1..30` returns `{days,devices[],shared_ips[]}`; each device has `score` + `reasons`: rejected (5 per hidden sighting, max 25), downvoted (3), busy (15+ reports/24 h: 2+), hopper (3+ lines in an hour: 6), repeat (5+ at one station+direction, none confirmed: 4), downvoter (8+ 👎 cast and >=3x its 👍: 4; uses `votes.at`, so it needs the `votes.at` column). Shared network (5+ devices) is shown, not scored.
- `GET /api/admin/device?k=` profile of a device (or network hash: lists its devices).
- New actions (`POST /api/admin/act`): `ok`/`unok` (table `admin_reviewed`; a device counts as reviewed only until riders hide another of its sightings), `undo_votes` (deletes the device's 👎 of the last 7 days and decrements `sightings.down`).
- UI: Moderate = persistent filter bar (state kept in `sessionStorage.mhF`), load more, bulk delete; Suspects = ranked list with client-side filters; device/network drawer. On phones the header scrolls sideways, the filter bar is not sticky and secondary columns are hidden.
**Deploy order:** run `migrate_v15.sql` on production (check first: `select count(*) from information_schema.columns where table_name='votes' and column_name in ('ip','at');` must be 2), then replace the files, `npx wrangler deploy`.

## v0.37: interchange stations (same station on several lines)
15 station names exist on 2-5 lines in the repo seed (e.g. Place de Barcelone = lines 1,3,4,5,6; since v0.50 Tunis Marine = lines 1,3,6,TGM and Farhat Hached = lines 1,3,6; list: `select lower(btrim(coalesce(fr,en,ar))) n, string_agg(line_id,',' order by line_id) from stations group by 1 having count(*)>1`). Each line has its own `stations` row; the same physical station = same `station_key(id)` = `lower(btrim(coalesce(fr,en,ar)))`.
**Server (`supabase/migrate_v16.sql`, replaces `report()` and `report_incident()`):** the normal limit stays (1 report / 2 min per device, 1 stop alert / 10 min). Exception: a further report inside that window is accepted only if EVERY report of the device in the window is at a station with the same name on a DIFFERENT line (never the same line twice), at most 3 per 2 min (stop alerts: 3 per 10 min) and fewer than 5 per 10 min for reports. That 10-minute cap equals the old sustained maximum, so the exception allows a burst, not a higher rate. Everything else is still `slow`. Same-line merge, bans, auto-pause and IP limits are unchanged.
**Client:** no special UI (the 'Also saw another line here?' buttons were removed in v0.39). Riders just report again the normal way (line > station > direction); the server accepts it under the rules above.
**Deploy:** run `migrate_v16.sql`, then web files (`sw.js` mh38) and `npx wrangler deploy`.

## v0.38: same station, opposite direction
`supabase/migrate_v17.sql` (also appended to `schema.sql`; needs v16) replaces `report()`: inside the 2-minute window a report is also accepted for the SAME station and line in the OTHER direction. The rule is now: every report of the device in the window must be at a station with the same name and must NOT be (same line AND same direction). Allowed: other line (any direction), same station + same line + opposite direction. Refused: same line + same direction again, same line at another station, any other station name. Caps unchanged (3 per 2 min, <5 per 10 min). Stop alerts have no direction, so they are unchanged.
Client: no special UI (the one-tap 'toward X' button was removed in v0.39); riders report again the normal way. Deploy: run `migrate_v17.sql`.

## v0.39: chips removed, admin redesign
**Rider page (`web/app.js`, `style.css`, `sw.js` mh40):** the post-report buttons for other lines / opposite direction are gone. The server rules of v16/v17 stay, so a rider can still report several lines and both directions at one station inside 2 minutes, just by reporting again the normal way.
**Admin (`worker/admin.html` only; no backend change):** same design tokens as the rider site (light/dark with a header toggle, `localStorage.mhTheme`, default = system), green branded header, icon tabs. Phones (<=720 px): tabs become a fixed bottom bar, every table becomes a list of cards (JS `lab()` writes `data-l` on each cell and CSS prints it as the label; empty cells are hidden), Moderate/Suspects filters collapse behind a 'Filters' button with an active count, the profile drawer is a bottom sheet. Overview KPIs are grouped (Right now / Reports / People / Quality and moderation). Content swaps (`show()`) restore `scrollY`. Any new table built with `h('table')` or `tbl()` gets mobile cards automatically.

## v0.40: What's new, cleanup
**What's new (`web/app.js`, `style.css`, `sw.js` mh41):** a highlighted block at the top of the 'How it works' sheet (the ? button), texts `nwt` (title) and `nwi` (list of [icon, text]) in ar/fr/en. Returning riders (localStorage `nrep`, `lastRep` or `seenUp` exist) get a yellow dot on the ? button until they open the sheet; new visitors never see it (first load stores `nwSeen`). **For each release worth announcing:** edit `nwi` in all three languages and bump `NEWV` in app.js (every rider who has an older `nwSeen` then sees the dot again). Keep it to 2-4 short lines written for riders.
**Cleanup:** deleted `supabase/update_stations.sql` (deleted every line, station and sighting; same data is in `schema.sql`) and `supabase/station_names_ar.sql` (superseded: its four extra Arabic names are now in `schema.sql`); moved migrate_v2..v13 and `prod_catchup_v4_to_v10.sql` to `supabase/archive/`; removed the unused `arr` helper and the unused translation key `lme` from app.js; README layout rewritten one line per file; older PROGRESS entries moved to `docs/PROGRESS_ARCHIVE.md`.

## v0.41: Tunisian Arabic improved
Arabic UI text (`T.ar`, nickname words in `NKW`, theme button label in `web/fx.js`) rewritten from formal MSA / unnatural phrasing into clean everyday Tunisian: 22 dictionary entries changed (full old to new list in PROGRESS 55). Rules followed (same as the separate `tunisian-arabic` skill, delivered as `tunisian-arabic.skill`): negation `ما ... ش` (ما فماش, not "ما فما حتى"), `باش`/`موش`/`متاع`/`توّا`/`برشا`, `الأسبوع هذا` (never `جمعة`, which also means Friday), no MSA passive `تم`, no other-dialect words, no slang or vulgar words. SEO title/meta in `index.html` stay MSA on purpose (people search in MSA). Placeholders ({s}, {a}, {b}, {n}, {y}) are unchanged. `sw.js` is mh50 (v0.51).

## v0.42: CAPTCHA token handling (`web/app.js`)
Toast `[bot: missing-input-response]` = the browser sent NO Turnstile token (server and keys are fine). `ts()` loads/renders the invisible Turnstile widget on the first touch/scroll of the page (v0.43 pre-warm; the report button only starts it if no token exists); `send()` waits for the token (15 s, 45 s if a visible challenge appears), never posts an empty one, and on failure shows 'Could not verify you are human...' with a client code: `[bot: ts-blocked]` script blocked/not loaded, `[bot: ts-e<n>]` widget error (Cloudflare client error number), `[bot: ts-timeout]` no token in time, `[bot: ts-js]` render exception. Codes without `ts-` come from the server's siteverify. Details, causes and phone checklist: PROGRESS 57.

## v0.45: message the developers
Hero chat button (next to Share) or footer button -> sheet (`mode:'fb'` in `sheet()`, handlers `data-fb/fk/fs`) -> POST `/api/feedback` (Turnstile-gated, Worker validates) -> SQL `send_feedback()` -> table `feedback` (`supabase/migrate_v18.sql`, no public access). Read with admin_queries.sql section 9. Details, limits and deploy order: PROGRESS 60. `sw.js` is mh46.

## v0.47: your posts + remove
App asks `POST /api/mine` (SQL `my_posts`) for the ids this device posted/voted; own items get a 'Your report' tag and a two-tap Remove (`/api/unpost` -> `remove_post`), your votes are removed by tapping them again (`/api/unvote` -> `remove_vote`). Rules, limits and caveats: PROGRESS 62. SQL in `supabase/migrate_v19.sql`. `sw.js` is mh48.

## v0.49: direction on stop reports
Stop reports are line -> station -> direction (a / b / both). Column `incidents.dir`, view `live_incidents.dir`, `report_incident(..., p_dir)` in `supabase/migrate_v21.sql`; the alert card shows the direction. Rules and deploy order: PROGRESS 64.

## v0.50: station fixes from the Transtu map
Line 1 now runs Tunis Marine - Farhat Hached - Place de Barcelone - ... - Ben Arous (13 stations); TGM got Carthage Salammbô. SQL `supabase/migrate_v22.sql` (idempotent) + seed in schema.sql. PROGRESS 65.

## v0.51: 'both directions' on sightings
Sighting step 3 = toward A / toward B / both (`dir` a|b|x). `report()` in `supabase/migrate_v23.sql` creates one sighting per direction for x. Rules and deploy order: PROGRESS 66.

## Before deploying (two 5-second checks, added after PROGRESS 56)
1. `find web worker supabase -type f -size 0` must print NOTHING (an empty file means a broken edit).
2. `grep -o "const V='[a-z0-9]*'" web/sw.js` must print the new cache version (mh50 for this release). If it prints nothing, sw.js is broken.


## Others page + live buses (v0.52)
Two tabs under the header: **Metro** (unchanged) and **Others** (`tab='others'`, `setTab()`). Others lists **bus lines** (table `lines.kind='bus'`, currently **4C**, stations in `stations` like metro). The bus card is the SAME card as the metro one (`card()` inside `render()`): live sightings per direction, stop alerts, votes, remove-own. The report CTAs switch wording on the Others tab and the report sheet then lists bus lines only (metro sheet lists metro lines only). Client keeps metro lines in `lines`, bus lines in `bl`, `AL()` = both. Metro page counters ignore buses (`live_all().n` counts metro only; hero chips filter `isB()`).
Direction a = toward Khéreddine, b = toward Bab Saadoun (4C temporarily runs ONLY Bab Saadoun to Khéreddine while it backs up the metro during the works; `migrate_v26.sql` removed Jardin Thameur, Rue Mrid and El Bordj). SQL: `supabase/migrate_v24.sql` + `migrate_v26.sql`. `supabase/rebuild_test_db.sql` = schema + v18..v24 + test_seed in one file (TEST DB ONLY). To add a bus line: insert into `lines` (kind 'bus') + `stations`; no code change.

## v0.55: adaptive CAPTCHA (a few posts without it, CAPTCHA only when needed)
Real riders were refused as "robots". Now `/api/report`, `/api/incident` and `/api/feedback` accept a post with a valid Turnstile token (verified), OR without one while `unverified_ok(dev, ip)` (`supabase/migrate_v27.sql`) allows it: max 6 unverified posts per device per 24 h, 20 per IP per hour, and a SURGE switch (40 unverified posts in 10 min anywhere = CAPTCHA for everybody until it calms down). Otherwise the Worker answers 403 `bot` (code `captcha-needed`) and the app solves the CAPTCHA and retries once. The app's first try never waits for the token, and the token now refreshes itself when it expires. Tune the numbers in `unverified_ok()`. Deploy order: SQL, then Worker, then web (a Worker deployed before the SQL just keeps requiring the CAPTCHA).

## v0.56: admin "Insights" tab (share images for every line)
In `/admin` the new **Insights** tab draws two 1080x1350 PNGs per line in Tunisian Arabic, ready to post: **"الأوقات اللي تتعاود"** (the station + direction + hour slots reported on the most different days, e.g. "10 من 16 يوم", top 8 on weekdays and top 3 at weekends, at least 2 days each) and **"توقّعات الخط"** (share of reports per Tunis hour 6 to 22, weekdays vs weekend, the tallest bars highlighted). Pick a line (button shows its report count) and a period (14 to 90 days, ending yesterday), then "Download PNG" or "Download all lines". Hidden reports and banned devices are left out. Data comes from `admin_insights(p_days)` (`supabase/migrate_v28.sql`) via `GET /api/admin/insights?days=N`; the images are drawn in the browser (canvas), nothing is uploaded anywhere. Deploy: run migrate_v28.sql, then deploy the Worker (`worker/admin.js`, `worker/admin.html`); no change to the rider app.

**v0.56b:** the repeating-times list now has minutes (slot size 15 / 30 / 60 min, default 15; the label is the slot start, e.g. 07:15) and uses votes: reports riders rated net-negative (down > up) are left out, confirmed reports weigh 1 to 3 (1 + min(up,2)) in the hour chart and in tie-breaks. `admin_insights(p_days, p_bucket)` replaces the one-argument version (migrate_v28.sql drops the old one).
