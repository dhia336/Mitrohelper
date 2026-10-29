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

## v0.15: frontend polish (no server/SQL change)
**Freshness label** (`#upd`, `upd()` in app.js): 'Updated 25s ago' under the hero. If a refresh fails (network error or a response without data) it turns red ('Can't refresh, last update 3 min ago') and the sticky line bar gets a red underline (`.jb.off`), so stale data is never silently trusted. Updated by a local 10s timer, no extra requests.
**Remembered last report**: after a successful report/stop, `localStorage.lastRep = {l,s,d}` (line, station, direction). In the 'I saw the metro' sheet a 'Same as last time' button (`data-last`) jumps straight to the direction step (3 taps -> 2). The remembered line, station and direction are also outlined (`.last`) in every step, and the station list scrolls to the remembered station. 'Metro stopped' never submits in one tap (accident-safe): it only highlights. Ignored if the saved line/station no longer exists.
**How it works sheet**: the round `?` button in the header opens a 6-point plain-language sheet (`hwi` in the i18n objects, 3 languages). It states the current rules (2 sightings per direction, 90 min fresh, stop = 15 min, votes). If you change those numbers, update `hwi`.

## v0.14: sightings, timers, polling
**Slots:** each line+direction shows its 2 newest sightings; a new one pushes out the oldest. Done in the `live` view (`supabase/migrate_v6.sql`): top 2 per line+direction via `row_number()`, skipping rows hidden by votes (down-up>=2) and collapsing the same station+direction within 4 min (same train reported twice). Max 28 rows whatever the traffic; scans at most 30 days. **Never expire:** sightings no longer vanish at 45 min; after 90 min (`ST` in app.js) a sighting is shown dimmed ('3 h ago', no bar, no vote buttons, no mark on the station track) until 2 newer ones replace it. Only a line with no sighting for 30 days shows 'No report yet'. Purge stays at 90 days (`purge_old`).
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
