-- v0.14: sightings = the 2 newest per line+direction, never expire (shown dimmed after 90 min by the app).
-- Same station + same direction within 4 min = same train reported twice -> only the newest counts.
-- Rows hidden by votes (down-up>=2) are skipped, so the next older one takes the slot. Scans at most 30 days (index on seen_at).
-- Result is at most 2 x 2 x 7 = 28 rows, whatever the traffic. Safe to re-run. Columns unchanged.
create or replace view live as
select id, line_id, station_id, dir, seen_at, up, down from (
  select s.id, st.line_id, s.station_id, s.dir, s.seen_at, s.up, s.down,
         row_number() over (partition by st.line_id, s.dir order by s.seen_at desc, s.id desc) rn
  from sightings s join stations st on st.id=s.station_id
  where s.seen_at > now()-interval '30 days' and s.down-s.up<2
    and not exists(select 1 from sightings n where n.station_id=s.station_id and n.dir=s.dir
                   and n.seen_at>s.seen_at and n.seen_at<=s.seen_at+interval '4 minutes' and n.down-n.up<2)
) x where rn<=2;
