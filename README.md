# MitroHelper (Tuni-Mitrovic)
Crowd-sourced live sightings for Tunis light metro (lines 1-6). 3 taps to report; live board per line/direction; ar/fr/en; installable PWA. Free stack, no build step.

## Layout
- `web/index.html` shell · `web/style.css` mobile-first styles · `web/app.js` UI, i18n, polling (15s), voting · `web/config.js` Supabase URL+anon key
- `supabase/update_stations.sql`/`update_colors.sql` migrations for existing DBs · `web/sw.js` offline shell cache · `web/manifest.webmanifest` + `web/icons/` install-as-app
- `supabase/schema.sql` tables, RLS, `report()`/`vote()` functions, seed data

## Architecture
Static site (Cloudflare Pages/GitHub Pages) -> Supabase REST. Anon can only SELECT `lines`, `stations`, `live` (view hides device/IP). Writes ONLY via `report()` and `vote()` (security definer).
Anti-spam: 1 report/2 min per device AND per IP hash, max 30/h per IP, one vote per device per sighting, sighting hidden when downvotes exceed upvotes by 2, expires after 45 min.
Directions: `a` = toward highest `pos` station, `b` = toward lowest. Add stations by inserting rows with `pos` between neighbours.

## v0.8: single Worker
`wrangler.toml` deploys ONE Worker named `mitrohelper`: `web/` as static assets (free, unlimited) + `worker/index.js` for `/api/*`. `web/config.js` API is '' (same origin). Deploy: `npx wrangler deploy` or connect the GitHub repo in Workers & Pages (deploy command `npx wrangler deploy`). Secrets via `wrangler secret put` or dashboard. If the URL differs, edit `ALLOWED_ORIGIN` in wrangler.toml.

## v0.6 architecture change
The site no longer talks to Supabase directly. `web/` -> Cloudflare Worker (`worker/index.js`) -> Supabase. The Worker: caches reads (live 8s, lines/stations 1h), verifies Turnstile on reports/breakdowns, passes the real client IP, and is the only caller allowed to run the write functions (Supabase secret key lives only in the Worker). `/api/cron` (header `x-cron-key`) runs `purge_old()` and keeps the free DB awake; call it daily from cron-job.org.
Breakdown reports: `incidents` + `live_incidents` view, 90 min expiry, merged per station, votes "still stopped"/"running again", hidden when 'running again' leads by 2.
Moderation: insert a device id or `md5(ip)` into table `banned`.

## Setup (see PROGRESS for status)
0. Existing DB: run `supabase/migrate_v2.sql`. Fresh DB: `schema.sql` already includes it.
0b. Worker: Cloudflare > Workers & Pages > Create > paste `worker/index.js`; set variables above. Put the Worker URL (and Turnstile site key) in `web/config.js`.
1. Supabase free project -> SQL Editor -> run `supabase/schema.sql`.
2. Put URL + anon key in `web/config.js`.
3. Deploy `web/` to Cloudflare Pages (no build command, output dir `web`). Test locally: `cd web && python3 -m http.server`.
