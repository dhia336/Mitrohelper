-- v0.21: fresh window back to 45 minutes (was 90). Safe to re-run. Needs v7 + v8 (or schema.sql) applied first.
-- Replaces the `live` view (v8) and live_all() (v7) with 45 instead of 90. 45 here must match ST in web/app.js.
-- Everything else (max 5 fresh per line+direction, the 3 newest distinct station+direction kept whatever their age,
-- same-train collapse within 4 min, votes hiding) is unchanged.
create or replace view live as
with cand as (
  select s.id, st.line_id, s.station_id, s.dir, s.seen_at, s.up, s.down
  from sightings s join stations st on st.id=s.station_id
  where s.seen_at > now()-interval '30 days' and s.down-s.up<2
    and not exists(select 1 from sightings n where n.station_id=s.station_id and n.dir=s.dir
                   and n.seen_at>s.seen_at and n.seen_at<=s.seen_at+interval '4 minutes' and n.down-n.up<2)
), r as (
  select c.*,
    row_number() over (partition by line_id, dir order by seen_at desc, id desc) as rn,
    row_number() over (partition by station_id, dir order by seen_at desc, id desc) as rs
  from cand c
), f as (
  select r.*, row_number() over (partition by line_id, dir order by seen_at desc, id desc) as rr from r where rs=1
)
select id, line_id, station_id, dir, seen_at, up, down from r where seen_at > now()-interval '45 minutes' and rn<=5
union
select id, line_id, station_id, dir, seen_at, up, down from f where rr<=3;

create or replace function live_all() returns json language sql stable set search_path=public as $$
  select json_build_object(
    's',(select coalesce(json_agg(l),'[]'::json) from live l),
    'i',(select coalesce(json_agg(i),'[]'::json) from live_incidents i),
    'n',(select count(*) from sightings where seen_at>now()-interval '45 minutes' and down-up<2)) $$;
revoke all on function live_all() from public, anon, authenticated;
grant execute on function live_all() to service_role;
