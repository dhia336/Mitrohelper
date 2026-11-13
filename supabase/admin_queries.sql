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

-- ===== v11 retention (table visits). Run in the SQL editor =====
-- Daily visitors, new vs returning (first_day = first day the device was ever seen in visits)
-- with f as (select dev, min(day) first_day from visits group by dev)
-- select v.day, count(*) visitors, count(*) filter (where f.first_day=v.day) new_devs, count(*) filter (where f.first_day<v.day) returning_devs, count(*) filter (where v.standalone) installed_app
-- from visits v join f using(dev) group by v.day order by v.day;
-- Retention by first-visit day: D1 / D7 (share of that day's new devices seen again exactly N days later). Recent days are incomplete.
-- with f as (select dev, min(day) d0 from visits group by dev)
-- select d0, count(*) new_devs, round(100.0*count(*) filter (where exists(select 1 from visits x where x.dev=f.dev and x.day=d0+1))/count(*),1) d1_pct, round(100.0*count(*) filter (where exists(select 1 from visits x where x.dev=f.dev and x.day=d0+7))/count(*),1) d7_pct
-- from f group by d0 order by d0;
-- Traffic source (links like https://.../?src=fb-ariana): first source per device, how many came back, how many ever reported
-- with f as (select distinct on (dev) dev, src, day from visits order by dev, day)
-- select coalesce(nullif(src,''),'(none)') src, count(*) devices, count(*) filter (where exists(select 1 from visits x where x.dev=f.dev and x.day>f.day)) came_back, count(*) filter (where exists(select 1 from sightings s where s.dev=f.dev) or exists(select 1 from incidents i where i.dev=f.dev)) reported
-- from f group by 1 order by 2 desc;

-- ===== v12 leaderboard audit: look at the top 20 of this week for farming signs (run before trusting the board) =====
-- other_devs_same_ip > 0 on a top device = several devices on one IP (could be a farm, or a family / mobile carrier: judge by the other columns). Ban: insert into banned(k) values ('DEVICE-ID'); it leaves the board at once.
-- with r as (select * from lb_range('week')), s as (select * from lb_scores((select f from r),(select t from r)) order by points desc limit 20)
-- select s.dev, nick(s.dev) nick, s.points, s.reports, s.confirms, s.days, round(s.reports::numeric/s.days,1) per_day,
--  (select count(distinct station_id) from sightings x where x.dev=s.dev and x.seen_at>=(select f from r)) stations,
--  (select count(*) from sightings x where x.dev=s.dev and x.seen_at>=(select f from r) and x.down>0) downvoted,
--  (select count(distinct y.dev) from sightings y where y.dev<>s.dev and y.seen_at>=(select f from r) and y.ip in (select z.ip from sightings z where z.dev=s.dev and z.seen_at>=(select f from r))) other_devs_same_ip
-- from s order by s.points desc;

-- v0.34: detect a structural break (schedule change) per line: median gap and sightings per Tunis day. A sudden step = add/update line_regimes.
select st.line_id, (s.seen_at at time zone 'Africa/Tunis')::date d, count(*) sightings
from sightings s join stations st on st.id=s.station_id where s.down-s.up<2 and s.seen_at>now()-interval '30 days' group by 1,2 order by 1,2;
-- current prediction table and regimes
select * from line_regimes;
select r->>'l' line, r->>'d' dir, r->>'k' bucket, r->>'n' n, r->>'dy' days, r->>'a' p25, r->>'m' median, r->>'b' p75 from json_array_elements(typical_gaps()->'rows') r order by 1,2,3;
-- backtest idea (run after ~2 weeks): for each (station,dir) compare each real gap with the bucket median; report mean abs error vs naive "always 10 min".

-- 9) v0.45 messages from riders (newest unread first). Mark as read afterwards with the update below.
select id, created_at, kind, lang, ctx, msg from feedback where not done order by id desc limit 50;
-- update feedback set done=true where id in (/* ids */);
-- Delete old read ones: delete from feedback where done and created_at<now()-interval '180 days';
