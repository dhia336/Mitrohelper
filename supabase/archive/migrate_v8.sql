-- v0.17 (replaces the `live` view of v7). Safe to re-run. Needs v7 (or schema.sql) applied first.
-- Everything stays visible until its own 90-minute timer ends (max 5 per line+direction, owner's cap),
-- PLUS the 3 newest sightings (one per station+direction) of each line+direction are kept whatever their age (30-day floor),
-- so quiet lines never look empty. Same train reported twice (same station+direction within 4 min of a newer report) = one row.
-- Rows hidden by votes (down-up>=2) are skipped. 90 here must match ST in web/app.js.
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
select id, line_id, station_id, dir, seen_at, up, down from r where seen_at > now()-interval '90 minutes' and rn<=5
union
select id, line_id, station_id, dir, seen_at, up, down from f where rr<=3;
