-- Abuse review. Run in the Supabase SQL editor (PRODUCTION is fine: these are read-only until the ban section).

-- 1) Devices whose sightings other riders keep rejecting (last 7 days). 3 hidden in 24h or 6 in 7 days = automatically paused already.
select dev, count(*) filter (where down-up>=2) as hidden, count(*) as total, max(seen_at) as last_seen
from sightings where seen_at>now()-interval '7 days'
group by dev having count(*) filter (where down-up>=2)>0 order by hidden desc, total desc limit 30;

-- 2) Who is auto-paused RIGHT NOW (same rule as is_blocked())
select dev from (select distinct dev from sightings where seen_at>now()-interval '7 days') d where is_blocked(dev);

-- 3) Very active devices in the last 24h (bots usually look like 50+ reports)
select dev, count(*) as reports, min(seen_at) as first, max(seen_at) as last
from sightings where seen_at>now()-interval '24 hours' group by dev order by reports desc limit 20;

-- 4) Devices reporting on 3+ different lines inside one clock hour (commuter changing lines = 2, bot/tester = often more)
select s.dev, date_trunc('hour',s.seen_at) as hour, count(distinct st.line_id) as lines, count(*) as reports
from sightings s join stations st on st.id=s.station_id where s.seen_at>now()-interval '24 hours'
group by s.dev, date_trunc('hour',s.seen_at) having count(distinct st.line_id)>=3 order by lines desc, reports desc;

-- 5) IP hashes with many devices. Mobile carriers share ONE address between many riders, so NEVER ban an IP hash on this alone.
select ip, count(distinct dev) as devices, count(*) as reports
from sightings where seen_at>now()-interval '24 hours' group by ip having count(distinct dev)>=5 order by devices desc limit 20;

-- ===== manual ban / unban (k = a device id from the queries above) =====
-- insert into banned(k) values ('PASTE-DEVICE-ID') on conflict do nothing;
-- delete from banned where k='PASTE-DEVICE-ID';
-- select * from banned;
