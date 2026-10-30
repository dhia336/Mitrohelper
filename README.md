# MitroHelper (Tuni-Mitrovic)
Crowd-sourced live sightings for Tunis light metro (lines 1-6). 3 taps to report; live board per line/direction; ar/fr/en; installable PWA. Free stack, no build step.

## Layout
- `web/index.html` shell · `web/style.css` mobile-first styles · `web/app.js` UI, i18n, polling (20s), voting · `web/config.js` Supabase URL+anon key
- `supabase/update_stations.sql`/`update_colors.sql` migrations for existing DBs · `web/sw.js` offline shell cache · `web/manifest.webmanifest` + `web/icons/` install-as-app
- `supabase/migrate_v5.sql` stop-report rules · `supabase/migrate_v4.sql` live_all() + rate-limit indexes · `supabase/schema.sql` tables, RLS, `report()`/`vote()` functions, seed data

## Architecture
Static site (Cloudflare Pages/GitHub Pages) -> Supabase REST. Anon can only SELECT `lines`, `stations`, `live` (view hides device/IP). Writes ONLY via `report()` and `vote()` (security definer).
Anti-spam: 1 report/2 min per device AND per IP hash, max 30/h per IP, one vote per device per sighting, sighting hidden when downvotes exceed upvotes by 2, never expires (shown dimmed after 90 min, see v0.14).
Directions: `a` = toward highest `pos` station, `b` = toward lowest. Add stations by inserting rows with `pos` between neighbours.

## UI: line cards always expanded
Line cards are always fully expanded (header, direction rows, full station track) with no collapse control. A sticky line-jump bar (`.jb`, one coloured badge per line, red dot if that line has a live stop alert) sits under the header; tapping a badge smooth-scrolls to `#l<id>` (`data-j` handler in app.js; `--hh` = header height set by `hh()`). v0.11 removed the `data-tog` handler, chevron, `open` Set and `.tk` collapse CSS.

## v0.20: card readability (frontend only)
- **Arrows** are bold SVG icons (`ARW(d)`, `.aw`), not the thin text glyphs ↓ ↑ ⇄: a round badge `.dg` in the line colour next to 'toward X' (a = down = toward the last station, b = up), and inside every chip.
- **Sighting row** = station name as the headline (`.sn`, 1.25rem bold) + a time pill (`.tm`) coloured by freshness (`fz()`: green < 20 min, amber < 1 h, orange < 90 min, grey dashed = older = last known) + a thicker bar in the same colour. Old sightings are no longer faded with opacity (it hurt readability), they use a dashed pill and muted name.
- **Vote buttons** are 44px tall (`.vt button`). The stop-alert buttons are one line each.
- **Station list**: bigger rows and chips; chip text is compact without 'ago' (`durX`: `18min`, `1h 18min`, `1d 1h`; fr/ar equivalents); chip arrow + `aria-label`/`title` 'toward X · time ago'.
- **Text colour on line colours**: `fg()` picks dark text for light line colours (lime TGM, teal 3, amber 2) and white for the rest, via `--ct` on the card, jump bar and sheet buttons.
- Looked at with a headless Chromium on mock data (Arabic dark, English light, 360px and 390px wide, TGM, stop alert, old sightings); not yet on a real phone.

## Testing before deploying (v0.16)
Never test on the live site. Use a second (free) Supabase project and a `staging` environment of the same Worker (`[env.staging]` in wrangler.toml); no code is duplicated.
1. Supabase: create a project `mitrohelper-test`. SQL editor: run `supabase/schema.sql` (contains everything up to the latest migration, v8), then `supabase/test_seed.sql` for sample data. NEVER run test_seed.sql on production (it empties the tables).
2. wrangler.toml: put the test project URL in `[env.staging.vars] SUPABASE_URL`.
3. Secrets (not inherited by environments): `npx wrangler secret put SUPABASE_SERVICE_KEY --env staging` (TEST project key) and `npx wrangler secret put TURNSTILE_SECRET --env staging` with Cloudflare's dummy secret `1x0000000000000000000000000000000AA`. For local runs copy `.dev.vars.staging.example` to `.dev.vars.staging` (gitignored; when it exists only it is loaded).
4. Local: `npx wrangler dev --env staging` -> http://localhost:8787. Online test copy (for phones): `npx wrangler deploy --env staging` -> https://mitrohelper-staging.dhia336.workers.dev. `web/config.js` automatically uses Turnstile's dummy always-pass key on localhost and on any host containing 'staging'; every other host gets the real key (safe default).
5. Release routine: change -> local -> staging on a phone -> run the SQL migration on production -> plain `npx wrangler deploy` for production (Wrangler may warn that several environments exist; add `--env=""` to silence). Order: SQL first, then Worker/web.
6. Service worker: while testing, DevTools > Application > 'Update on reload', or clear site data, otherwise you may see the old cached files.
Test the auto-pause: after test_seed.sql, in the test site's console run `localStorage.dev='seed-troll-device-000001'; location.reload()` then try to report: you get the 'Reports paused' message.

## v0.18: same-train merge + Arabic station names
**Merge** (`supabase/migrate_v9.sql`, new `report()`): a new sighting that matches an older one (same station and direction, i.e. same line; older one <= 3 min old; not hidden by votes) deletes the older one and counts as +1 confirmation on the new one (its votes move over; the old reporter is recorded as having voted so they cannot also tap 👍; if the SAME device reported twice it is only replaced, no +1). A report at a different station is a separate sighting. Tune `v_mins` in the function. The `live` view's 4-min same-station collapse stays as a fallback. Stats note: merged old reports no longer exist in `sightings` (a `votes` row keeps their device).
**Arabic names**: `supabase/station_names_ar.sql` fills the `ar` column for all 99 stations by (line, pos) without touching ids or sightings. `schema.sql` and `update_stations.sql` seeds already contain them. Edit one: `update stations set ar='...' where line_id='4' and pos=80;`. `/api/data` (lines + stations) is cached 5 min at the edge AND in the browser (v0.19; it was 1 h, which hid name changes), so edits show up by themselves. For an instant refresh bump `?v=` in `get('/data?v=10')` in app.js. The service worker serves the previous app.js first: open the site twice after a deploy. Stations added directly in the database (L'Artisanat, L'Independance, L'Environnement, L'Aeroport) are NOT in `update_stations.sql`/`schema.sql`: the repo seed is out of sync with the live data; Arabic for them is in `station_names_ar.sql` (matched by name).

## v0.16: card top vs station list, durations, share, auto-pause
**Card top** = only the latest sighting of each direction (`SLOTS=1`). **Station list** (the expanded track) = EVERY sighting until its own 90-minute timer ends (`ST`), so busy hours show everything; plus the last 3 of the line (`TRK=3`, different station/direction) which never disappear, so quiet lines never look empty. Old ones (>90 min) are dimmed. A station can show several entries (different trains, or both directions). The `live` view (`migrate_v8.sql`, replaces the v7 view) returns: all fresh sightings (cap 5 per line+direction, `rn<=5` in the view) + the 3 newest distinct station+direction per line+direction (30-day floor). Same train reported twice (same station+direction within 4 min of a newer report) = one row; rows hidden by votes are skipped. `live_all()` also returns `n` = real count of sightings in the last 90 min (hero chip).
**Durations**: under 60 min `5 min ago`; then `1h 1min ago`; from 24 h `1d 1h ago` (also fr `il y a 1 h 1 min`, ar `منذ 1 س 1 د`). Function `agoX` in app.js.
**Share**: a white pill button in the top corner of the hero image (always visible on load, 44px tall, labelled), plus on the 'thanks' screen after a report (it stays 3.5 s) and in the How-it-works sheet. Uses the phone's share sheet (`navigator.share`), otherwise copies the link and shows 'Link copied'.
**Automatic pause (no ban table, no cron)**: `is_blocked(dev)` = riders hid >=3 of the device's sightings in 24 h, or >=6 in 7 days (hidden = downvotes exceed upvotes by 2). `report`, `vote`, `report_incident`, `vote_incident` return `'blocked'` (toast 'Reports paused...') and it ends by itself as those sightings age out. Not counted: stop alerts (a real stop that ended quickly also gets voted away) and IP hashes (mobile carriers share one IP between many riders). Manual bans stay in the `banned` table; `supabase/admin_queries.sql` has review queries (rejected devices, bots, line-hopping, shared IPs) and the ban/unban statements.

## v0.15: frontend polish (no server/SQL change)
**Freshness label** (`#upd`, `upd()` in app.js): 'Updated 25s ago' under the hero. If a refresh fails (network error or a response without data) it turns red ('Can't refresh, last update 3 min ago') and the sticky line bar gets a red underline (`.jb.off`), so stale data is never silently trusted. Updated by a local 10s timer, no extra requests.
**Remembered last report**: after a successful report/stop, `localStorage.lastRep = {l,s,d}` (line, station, direction). In the 'I saw the metro' sheet a 'Same as last time' button (`data-last`) jumps straight to the direction step (3 taps -> 2). The remembered line, station and direction are also outlined (`.last`) in every step, and the station list scrolls to the remembered station. 'Metro stopped' never submits in one tap (accident-safe): it only highlights. Ignored if the saved line/station no longer exists.
**How it works sheet**: the round `?` button in the header opens a 6-point plain-language sheet (`hwi` in the i18n objects, 3 languages). It states the current rules (2 sightings per direction, 90 min fresh, stop = 15 min, votes). If you change those numbers, update `hwi`.

## v0.14: sightings, timers, polling
**Slots (superseded by v0.16: card top 1 per direction, station list 3 per line):** each line+direction showed its 2 newest sightings. Done in the `live` view (`supabase/migrate_v6.sql`): top 2 per line+direction via `row_number()`, skipping rows hidden by votes (down-up>=2) and collapsing the same station+direction within 4 min (same train reported twice). Max 28 rows whatever the traffic; scans at most 30 days. **Never expire:** sightings no longer vanish at 45 min; after 90 min (`ST` in app.js) a sighting is shown dimmed ('3 h ago', no bar, no vote buttons, no mark on the station track) until 2 newer ones replace it. Only a line with no sighting for 30 days shows 'No report yet'. Purge stays at 90 days (`purge_old`).
**Timers:** the server sends absolute timestamps; the phone computes 'min ago' itself (`mins()`), so nothing is fetched to keep timers moving. `/api/live` also returns `t` (server time, up to 20s old because of the edge cache); the client keeps the offset (`clk`) so a wrong phone clock does not shift 'min ago'.
**Polling:** a poll every 20s while data changes; if two polls in a row return identical data the delay grows 20s -> 30s -> 45s -> 60s (max), and resets to 20s on any change, on your own report/vote, or when the tab becomes visible. Hidden tabs do not poll.

## Single page + scrolling (v0.13)
No tabs and no bottom nav: the app is the Metro board only (Louage tab removed v0.12; Map tab, `img/map.webp`, nav bar and tab logic removed v0.13). The two report buttons (`.ctas`) are pinned to the bottom. Smooth scroll: Lenis 1.3.11 loaded from jsDelivr by app.js ONLY when `(any-pointer:fine)` and not `prefers-reduced-motion` (touch devices keep native scrolling and download nothing); falls back to native scroll if the script is blocked. `data-lenis-prevent` on the report sheet (`#pan`) and map (`.mz`); jump-bar uses `lz.scrollTo` with a header+bar offset. To self-host: save the file as `web/lenis.min.js` and change the `sc.src` in app.js.

## v0.11: stop reports ('Metro stopped')
Rules live ONLY in the `live_incidents` view (`supabase/migrate_v5.sql`): an alert is live while (a) a 'still stopped' confirmation arrived in the last 15 min (`last_at`; each distinct device's confirmation extends it, 'running again' votes do not), (b) running-again votes < stopped votes, (c) nobody reported a metro AT THAT STATION more than 2 min after the last confirmation (a train seen there = moving again). One alert per station; a new report on a live alert is a confirmation, on a dead one it starts a fresh alert with fresh counts. UI shows 'Still stopped · N' / 'Running again · M' on the buttons and 'last confirmed X ago'. Existing DB: run `migrate_v5.sql`. Change the 15 min / 2 min numbers in the view only.

## v0.10: load + multi-train board
`GET /api/live` = ONE Supabase call (`rpc/live_all()`, `supabase/migrate_v4.sql`, falls back to the 2 old queries if the function is missing), edge-cached 20s (same as the client poll interval, so users share one Supabase hit per Cloudflare datacenter per 20s). Client sends `cache:'no-store'` so the browser never adds a second cache layer, and only re-renders when data or a 'min ago' value changed. Direction cards: see v0.14. Station track still shows every live sighting. Fresh DB: `schema.sql` already includes v4. Existing DB: run `migrate_v4.sql` BEFORE/with the Worker deploy.

## v0.8: single Worker
`wrangler.toml` deploys ONE Worker named `mitrohelper`: `web/` as static assets (free, unlimited) + `worker/index.js` for `/api/*`. `web/config.js` API is '' (same origin). Deploy: `npx wrangler deploy` or connect the GitHub repo in Workers & Pages (deploy command `npx wrangler deploy`). Secrets via `wrangler secret put` or dashboard. If the URL differs, edit `ALLOWED_ORIGIN` in wrangler.toml.

## v0.6 architecture change
The site no longer talks to Supabase directly. `web/` -> Cloudflare Worker (`worker/index.js`) -> Supabase. The Worker: caches reads (live 20s, lines/stations 1h), verifies Turnstile on reports/breakdowns, passes the real client IP, and is the only caller allowed to run the write functions (Supabase secret key lives only in the Worker). `/api/cron` (header `x-cron-key`) runs `purge_old()` and keeps the free DB awake; call it daily from cron-job.org.
Breakdown reports: `incidents` + `live_incidents` view, lifetime/vote rules: see v0.11.
Moderation: insert a device id or `md5(ip)` into table `banned`.

## Setup (see PROGRESS for status)
0. Existing DB: run `supabase/migrate_v2.sql`. Fresh DB: `schema.sql` already includes it.
0b. Worker: Cloudflare > Workers & Pages > Create > paste `worker/index.js`; set variables above. Put the Worker URL (and Turnstile site key) in `web/config.js`.
1. Supabase free project -> SQL Editor -> run `supabase/schema.sql`.
2. Put URL + anon key in `web/config.js`.
3. Deploy `web/` to Cloudflare Pages (no build command, output dir `web`). Test locally: `cd web && python3 -m http.server`.
