-- v13 (v0.34): typical headway per line/direction/time bucket, learned from past sightings.
-- Only data on/after a line's "regime" date is used, so a schedule change (e.g. line 4 after 2026-11-04) is not polluted by old data.
create table if not exists line_regimes(line_id text primary key, since date not null);
alter table line_regimes enable row level security;
insert into line_regimes values('4','2026-11-04') on conflict do nothing;   -- owner: update this date when a line's service changes

-- bucket: 'wd'/'we' (weekday/weekend) x period 1 (6-9) 2 (9-16) 3 (16-20) 4 (other), plus 'all'
create or replace function typical_gaps() returns json language sql stable security definer set search_path=public as $$
  with ev as (
    select st.line_id, s.station_id, s.dir, s.seen_at,
      (s.seen_at at time zone 'Africa/Tunis') lt
    from sightings s join stations st on st.id=s.station_id
    left join line_regimes r on r.line_id=st.line_id
    where s.seen_at>now()-interval '21 days' and s.down-s.up<2
      and (r.since is null or (s.seen_at at time zone 'Africa/Tunis')::date>=r.since)),
  g as (select line_id, dir, lt, extract(epoch from (seen_at-lag(seen_at) over (partition by station_id,dir order by seen_at)))/60 gap from ev),
  b as (select line_id, dir, gap, lt::date d,
      case when extract(isodow from lt)<=5 then 'wd' else 'we' end||
      case when extract(hour from lt)>=6 and extract(hour from lt)<9 then '1' when extract(hour from lt)>=9 and extract(hour from lt)<16 then '2'
           when extract(hour from lt)>=16 and extract(hour from lt)<20 then '3' else '4' end k
    from g where gap between 3 and 40),
  a as (select line_id, dir, k, gap, d from b union all select line_id, dir, 'all', gap, d from b),
  r as (select line_id l, dir, k, count(*)::int n, count(distinct d)::int days,
      round((percentile_cont(.25) within group (order by gap))::numeric,1) p25,
      round((percentile_cont(.5) within group (order by gap))::numeric,1) p50,
      round((percentile_cont(.75) within group (order by gap))::numeric,1) p75
    from a group by line_id, dir, k)
  select json_build_object('rows',coalesce((select json_agg(json_build_object('l',l,'d',dir,'k',k,'n',n,'dy',days,'a',p25,'m',p50,'b',p75)) from r where n>=8),'[]'::json)) $$;
revoke all on function typical_gaps() from public, anon, authenticated;
grant execute on function typical_gaps() to service_role;
