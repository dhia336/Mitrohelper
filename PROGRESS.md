# PROGRESS
## Status (all untested: nothing run against a real Supabase project or real phones)
- v0.1 written: UI, i18n, PWA, schema, anti-spam.
- v0.2: full line 4 station list. Existing DBs: run `supabase/update_line4.sql`.
- v0.3: stations for all lines from map. Existing DBs: run `supabase/update_stations.sql`.
- v0.4: full redesign (dark glass UI, animated cards, expandable station tracks, bottom-sheet report flow, louage coming-soon tab), Arabic default, new line colors (`supabase/update_colors.sql`), sw cache v2. UNTESTED on real devices; animation performance on low-end phones unchecked.
- v0.5: restyled away from dark/glass look (transit-signage light/dark-auto theme, real tram photo hero, Transtu map tab, labeled yellow CTA 'I saw the metro' instead of + icon, nav 'Metro/Map/Louage'). Station lists replaced by owner-supplied official lists incl. TGM (line id `TGM`). Existing DBs: run `supabase/update_stations.sql` (wipes sightings). UNTESTED.
- v0.6 (UNTESTED): breakdown reports + votes; Cloudflare Worker proxy (cache, Turnstile, secret-key writes, cron purge); `banned` table; poll 20s.
- DB (Supabase project 'Mitrou', pxbekofgpogrootrnowq): migrate_v2 APPLIED and verified (tables+RLS present, write functions executable by service_role only, 108 stations, 0 sightings). Worker, Turnstile, cron, site deploy: NOT done yet.
- v0.7: stations replaced by owner's accurate lists (103 stations; names identical in ar/fr/en for now) and APPLIED to Supabase 'Mitrou' (migration v3_accurate_stations, verified counts 11/12/11/20/14/18/17). All lines now ordered city-centre first. Deployment status: site uploaded to Cloudflare worker 'mitrohelper-api'; API worker + config.js still pending.
- v0.8 (UNTESTED): frontend+API merged into one Worker (wrangler.toml, assets binding). Service worker now bypasses /api/ (otherwise live data would be served stale).
## Bugs / lessons
1. Supabase grants EXECUTE on new functions to `anon` by default, so `revoke ... from public` alone did NOT lock the write functions. v0.6 revokes from anon/authenticated explicitly.
2. Per-IP 2-minute limit would block different people sharing one mobile-carrier IP (CGNAT). Replaced with generous hourly caps; per-device limits unchanged.
## Decisions
1. Polling every 15s instead of Supabase Realtime: zero dependencies, fast load, enough for this use.
2. No framework/build: vanilla JS, ~10 KB, fastest load.
3. Writes only through RPC functions so RLS can stay closed.
## Known limitations / TODO
1. Stations: owner-supplied list (v0.5). Differences vs the Transtu map to confirm: line 6 lacks Mourouj 2 and uses 'Cité Ennasr' where the map shows Cité Municipale; line 5 lacks Ettadhamen; 'Cité Sportive' (list) vs 'Cité Olympique' (map) on line 2; 'Habib Thameur' not on the map. OLD NOTE (superseded): Unverified by a rider: (a) lines 3 and 5 are assumed to share the trunk Barcelone..Les Jasmins; (b) line 1 starts at Tunis Marine, line 6 at Barcelone; (c) line 2 starts at La République.
2. All Arabic station names are my best effort: unreviewed.
3. Arabic/French wording is mine; have a native reader review it.
4. No Turnstile CAPTCHA yet (needs a Worker to verify). IP limit relies on `x-forwarded-for` seen by Supabase.
5. No arrival estimation yet (needs history analysis).
6. Icons are simple placeholders; replace with a designed logo.
