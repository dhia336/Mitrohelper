# MitroHelper (Tuni-Mitrovic)
Crowd-sourced live sightings for Tunis light metro (lines 1-6). 3 taps to report; live board per line/direction; ar/fr/en; installable PWA. Free stack, no build step.

## Layout
- `web/index.html` shell · `web/style.css` mobile-first styles · `web/app.js` UI, i18n, polling (20s), voting · `web/config.js` Supabase URL+anon key
- `supabase/update_stations.sql`/`update_colors.sql` migrations for existing DBs · `web/sw.js` offline shell cache · `web/manifest.webmanifest` + `web/icons/` install-as-app
- `supabase/migrate_v5.sql` stop-report rules · `supabase/migrate_v4.sql` live_all() + rate-limit indexes · `supabase/schema.sql` tables, RLS, `report()`/`vote()` functions, seed data

## Architecture
Static site (Cloudflare Pages/GitHub Pages) -> Supabase REST. Anon can only SELECT `lines`, `stations`, `live` (view hides device/IP). Writes ONLY via `report()` and `vote()` (security definer).
Anti-spam: 1 report/2 min per device AND per IP hash, max 30/h per IP, one vote per device per sighting, sighting hidden when downvotes exceed upvotes by 2, expires after 45 min.
Directions: `a` = toward highest `pos` station, `b` = toward lowest. Add stations by inserting rows with `pos` between neighbours.

## UI: line cards always expanded
Line cards are always fully expanded (header, direction rows, full station track) with no collapse control. A sticky line-jump bar (`.jb`, one coloured badge per line, red dot if that line has a live stop alert) sits under the header; tapping a badge smooth-scrolls to `#l<id>` (`data-j` handler in app.js; `--hh` = header height set by `hh()`). v0.11 removed the `data-tog` handler, chevron, `open` Set and `.tk` collapse CSS.

## v0.11: stop reports ('Metro stopped')
Rules live ONLY in the `live_incidents` view (`supabase/migrate_v5.sql`): an alert is live while (a) a 'still stopped' confirmation arrived in the last 15 min (`last_at`; each distinct device's confirmation extends it, 'running again' votes do not), (b) running-again votes < stopped votes, (c) nobody reported a metro AT THAT STATION more than 2 min after the last confirmation (a train seen there = moving again). One alert per station; a new report on a live alert is a confirmation, on a dead one it starts a fresh alert with fresh counts. UI shows 'Still stopped · N' / 'Running again · M' on the buttons and 'last confirmed X ago'. Existing DB: run `migrate_v5.sql`. Change the 15 min / 2 min numbers in the view only.

## v0.10: load + multi-train board
`GET /api/live` = ONE Supabase call (`rpc/live_all()`, `supabase/migrate_v4.sql`, falls back to the 2 old queries if the function is missing), edge-cached 20s (same as the client poll interval, so users share one Supabase hit per Cloudflare datacenter per 20s). Client sends `cache:'no-store'` so the browser never adds a second cache layer, and only re-renders when data or a 'min ago' value changed. Direction cards show only the latest sighting per direction (`MAXT=1` in app.js; set 2-3 to list several trains, same-station reports within 4 min collapse). Station track still shows every live sighting. Fresh DB: `schema.sql` already includes v4. Existing DB: run `migrate_v4.sql` BEFORE/with the Worker deploy.

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
