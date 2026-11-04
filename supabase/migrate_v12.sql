-- v12: weekly contributor leaderboard with generated nicknames. Safe to re-run. Needs v7 (is_blocked), and `banned`. Run BEFORE deploying web/Worker v0.29.
-- Everything is computed from `sightings`/`incidents` (permanent server data, 90 days), nothing is stored per user, so a page refresh never loses it.
-- Score = valid reports (not hidden by votes) + confirmations received (max 3 per report). Anti-farming: max 1 report per station per 15 min and 8 reports per device per day count,
-- hidden/banned/auto-paused devices are excluded, minimum 3 reports to be listed. Weeks run Monday-Sunday, Tunis time.

-- deterministic nickname indexes from the device id: [adjective 0-11, noun 0-11, number 10-99]. The words live in app.js (3 languages): users type nothing.
create or replace function nick(p_dev text) returns int[] language sql immutable as $$
  select array[(h%12)::int, ((h/12)%12)::int, (10+(h/144)%90)::int] from (select ('x'||substr(md5(p_dev),1,7))::bit(28)::bigint as h) t $$;

create or replace function lb_range(p_period text, out f timestamptz, out t timestamptz) language sql stable as $$
  select case p_period when 'last' then w-interval '7 days' when 'month' then now()-interval '30 days' else w end,
         case p_period when 'last' then w when 'month' then now()+interval '1 minute' else w+interval '7 days' end
  from (select (date_trunc('week', now() at time zone 'Africa/Tunis')) at time zone 'Africa/Tunis' as w) x $$;

create or replace function lb_scores(p_from timestamptz, p_to timestamptz)
returns table(dev text, points int, reports int, confirms int, days int, line_id text, station_id int)
language sql stable security definer set search_path=public as $$
  with ev as (
    select s.dev, s.station_id, s.seen_at ts, s.up from sightings s where s.seen_at>=p_from and s.seen_at<p_to and s.down-s.up<2 and s.dev is not null
    union all
    select i.dev, i.station_id, i.seen_at, i.up from incidents i where i.seen_at>=p_from and i.seen_at<p_to and i.down-i.up<2 and i.dev is not null),
  dd as (select e.*, row_number() over (partition by e.dev, e.station_id, floor(extract(epoch from e.ts)/900) order by e.ts) k from ev e),
  cap as (select e.*, (e.ts at time zone 'Africa/Tunis')::date d, row_number() over (partition by e.dev, (e.ts at time zone 'Africa/Tunis')::date order by e.ts) rn from dd e where e.k=1),
  ok as (select c.* from cap c where c.rn<=8 and not exists(select 1 from banned b where b.k=c.dev)),
  agg as (select o.dev, count(*)::int reports, coalesce(sum(least(o.up,3)),0)::int confirms, count(distinct o.d)::int days from ok o group by o.dev),
  tl as (select x.dev, x.line_id from (select o.dev, st.line_id, row_number() over (partition by o.dev order by count(*) desc, st.line_id) r from ok o join stations st on st.id=o.station_id group by o.dev, st.line_id) x where x.r=1),
  tst as (select x.dev, x.station_id from (select o.dev, o.station_id, row_number() over (partition by o.dev order by count(*) desc, o.station_id) r from ok o group by o.dev, o.station_id) x where x.r=1)
  select a.dev, a.reports+a.confirms, a.reports, a.confirms, a.days, tl.line_id, tst.station_id
  from agg a join tl using(dev) join tst using(dev) where a.reports>=3 and not is_blocked(a.dev) $$;

-- public top 10 (no device ids leave the database)
create or replace function leaderboard(p_period text default 'week') returns json language sql stable security definer set search_path=public as $$
  with r as (select * from lb_range(p_period)),
  s as (select x.*, row_number() over (order by x.points desc, x.reports desc, x.dev) rk from lb_scores((select f from r),(select t from r)) x)
  select json_build_object('from',(select f from r),'to',(select t from r),'n',(select count(*) from s),
    'rows',(select coalesce(json_agg(json_build_object('r',rk,'n',nick(dev),'l',line_id,'s',station_id,'p',points,'rp',reports,'cf',confirms,'dy',days) order by rk),'[]'::json) from s where rk<=10)) $$;

-- replaces v11's my_stats: same reports/confirms (30 days) + this week's rank, points, nickname, number of ranked riders, own valid reports this week (wr)
create or replace function my_stats(p_dev text) returns json language sql stable security definer set search_path=public as $$
  with r as (select * from lb_range('week')),
  s as (select x.*, row_number() over (order by x.points desc, x.reports desc, x.dev) rk from lb_scores((select f from r),(select t from r)) x),
  m as (select * from s where s.dev=p_dev)
  select json_build_object(
    'reports',(select count(*) from sightings where dev=p_dev and seen_at>now()-interval '30 days' and down-up<2),
    'confirms',(select coalesce(sum(up),0) from sightings where dev=p_dev and seen_at>now()-interval '30 days' and down-up<2),
    'nk',nick(p_dev),'rank',(select rk from m),'points',(select points from m),'n',(select count(*) from s),
    'wr',(select count(*) from sightings where dev=p_dev and seen_at>=(select f from r) and down-up<2)) $$;

revoke all on function nick(text), lb_range(text), lb_scores(timestamptz,timestamptz), leaderboard(text), my_stats(text) from public, anon, authenticated;
grant execute on function leaderboard(text), my_stats(text) to service_role;
