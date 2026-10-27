# PROGRESS
## Status (all untested: nothing run against a real Supabase project or real phones)
- v0.12 (UNTESTED, JS syntax-checked only): Lenis smooth scroll (decision 10), Louage tab removed (decision 11), sw cache mh12. No SQL changes.
- v0.11 (UNTESTED, SQL not run anywhere, JS syntax-checked only): stop reports reworked (bug 4). Run `supabase/migrate_v5.sql`, redeploy, sw cache mh10. Cards now always expanded and not collapsible (decision 8). Sticky line-jump bar added (decision 9), stop lifetime now 15 min, sw cache mh11.
- v0.10 (UNTESTED, only syntax-checked): `MAXT` switch for direction cards, default 1 = latest sighting only as before (owner prefers this; bug 3 notes why multi-train was considered), live endpoint cut to 1 Supabase query + 20s edge cache, client skips redundant re-renders, rate-limit indexes. Run `supabase/migrate_v4.sql`, redeploy Worker, sw cache now mh8.
- v0.1 written: UI, i18n, PWA, schema, anti-spam.
- v0.2: full line 4 station list. Existing DBs: run `supabase/update_line4.sql`.
- v0.3: stations for all lines from map. Existing DBs: run `supabase/update_stations.sql`.
- v0.4: full redesign (dark glass UI, animated cards, expandable station tracks, bottom-sheet report flow, louage coming-soon tab), Arabic default, new line colors (`supabase/update_colors.sql`), sw cache v2. UNTESTED on real devices; animation performance on low-end phones unchecked.
- v0.5: restyled away from dark/glass look (transit-signage light/dark-auto theme, real tram photo hero, Transtu map tab, labeled yellow CTA 'I saw the metro' instead of + icon, nav 'Metro/Map/Louage'). Station lists replaced by owner-supplied official lists incl. TGM (line id `TGM`). Existing DBs: run `supabase/update_stations.sql` (wipes sightings). UNTESTED.
- v0.6 (UNTESTED): breakdown reports + votes; Cloudflare Worker proxy (cache, Turnstile, secret-key writes, cron purge); `banned` table; poll 20s.
- DB (Supabase project 'Mitrou', pxbekofgpogrootrnowq): migrate_v2 APPLIED and verified (tables+RLS present, write functions executable by service_role only, 108 stations, 0 sightings). Worker, Turnstile, cron, site deploy: NOT done yet.
- v0.7: stations replaced by owner's accurate lists (103 stations; names identical in ar/fr/en for now) and APPLIED to Supabase 'Mitrou' (migration v3_accurate_stations, verified counts 11/12/11/20/14/18/17). All lines now ordered city-centre first. Deployment status: site uploaded to Cloudflare worker 'mitrohelper-api'; API worker + config.js still pending.
- v0.9.1: fixed Turnstile race (send() now waits for token + one retry; 403 {"r":"bot"} seen when tapping fast). favicon added.
- v0.9: disclaimer+privacy footer (ar/fr/en), sw cache mh6. Turnstile: owner enabling.
- v0.8 (UNTESTED): frontend+API merged into one Worker (wrangler.toml, assets binding). Service worker now bypasses /api/ (otherwise live data would be served stale).
## Bugs / lessons
1. Supabase grants EXECUTE on new functions to `anon` by default, so `revoke ... from public` alone did NOT lock the write functions. v0.6 revokes from anon/authenticated explicitly.
2. Per-IP 2-minute limit would block different people sharing one mobile-carrier IP (CGNAT). Replaced with generous hourly caps; per-device limits unchanged.
3. Direction card shows only the newest sighting per direction, so a second train reported later replaces the first. Owner CHOSE to keep this (prefers the latest sight over risking the same train listed twice). v0.10 adds `MAXT` in app.js (1 = current behaviour; 2-3 lists several trains). Not a bug by decision.
4. Stop alerts lingered 90 min after the first report and were hidden only if 'running again' beat confirmations by 2. Owner's scenario: stopped 15 min, many confirm, then it runs again but few people bother to say so (people mostly report sightings) -> false alert for up to 90 min. Fixed in v0.11: 15 min lifetime from the LAST confirmation, hidden when running-again >= stopped, auto-resolved by a sighting at the same station (+2 min grace), UI shows both counts.
## Decisions
1. Polling every 15s instead of Supabase Realtime: zero dependencies, fast load, enough for this use.
2. No framework/build: vanilla JS, ~10 KB, fastest load.
3. Writes only through RPC functions so RLS can stay closed.
4. Edge cache TTL (20s) equals poll interval: before (8s TTL vs 20s poll) nearly every poll was a cache miss -> Supabase. Now Supabase load is bounded per Cloudflare datacenter, independent of user count. Cache API has no stale-while-revalidate, so none is used.
5. (Only matters if MAXT>1.) Merge only same-station reports within 4 min (headways are longer, so two trains that close at one station is unlikely). Do NOT merge across stations: a train seen at stations 3 then 7 is indistinguishable from two trains, and wrongly merging would hide a real one.
6. Stop lifetime is activity-based (15 min since last 'still stopped'), not a fixed 90 min: an outage stays up only while distinct people keep confirming. Absence of sightings is NOT treated as a stop (quiet hours / few users would look like an outage); sightings only ever clear a stop.
7b. Sighting-clears-stop rule is same-station only: a train ahead of the blockage reported elsewhere proves nothing. Risk: someone reporting the stuck train at that station as a sighting >2 min after the last confirmation clears the alert wrongly (they can re-confirm to revive it as a fresh alert).
8. Line cards are permanently expanded (owner request): station track always visible, so the page is long (7 lines). If scrolling becomes a problem, consider a sticky line-jump bar rather than bringing collapse back.
9. Navigation for always-expanded cards = sticky badge bar under the header (not collapse). Red dot on a badge = live stop alert on that line. No scroll-spy/active highlight (extra compute, not needed).
10. Lenis is desktop/mouse only by design: on touch devices it adds nothing (it does not smooth touch) and would cost a rAF loop + a download. Loaded from jsDelivr, pinned 1.3.11 (no SRI hash: file not available offline when this was written; not in the service-worker cache, so offline = native scroll).
11. Louage tab removed at owner request. Re-adding means a new nav button + view branch + i18n strings (see git history before v0.12).
## Known limitations / TODO
8. FIXED in v0.11 (see bug 4). Was: breakdown lifetime 90 min counted from the FIRST report; later confirmations add +1 but do NOT extend it, so a long outage vanishes 90 min after the first report even if people keep confirming. Hidden earlier when 'running again' votes exceed confirmations by 2 (one reporter alone needs 3 such votes). Idea: refresh seen_at on confirmation.
7. (Only if MAXT>1.) Same train reported at two different stations shows as two trains (see decision 5). Fix would need a 'same train' tap or timing model.
1. Stations: owner-supplied list (v0.5). Differences vs the Transtu map to confirm: line 6 lacks Mourouj 2 and uses 'Cité Ennasr' where the map shows Cité Municipale; line 5 lacks Ettadhamen; 'Cité Sportive' (list) vs 'Cité Olympique' (map) on line 2; 'Habib Thameur' not on the map. OLD NOTE (superseded): Unverified by a rider: (a) lines 3 and 5 are assumed to share the trunk Barcelone..Les Jasmins; (b) line 1 starts at Tunis Marine, line 6 at Barcelone; (c) line 2 starts at La République.
2. All Arabic station names are my best effort: unreviewed.
3. Arabic/French wording is mine; have a native reader review it.
4. No Turnstile CAPTCHA yet (needs a Worker to verify). IP limit relies on `x-forwarded-for` seen by Supabase.
5. No arrival estimation yet (needs history analysis).
6. Icons are simple placeholders; replace with a designed logo.
