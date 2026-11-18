-- v0.56: admin "Insights" tab (share images per line). Run once in the Supabase SQL editor; safe to re-run.
-- Aggregates the last p_days days (7..90, ending yesterday, Tunis time) of sightings. Hidden reports (down-up>=2) and banned devices/IPs are left out.
-- Hour arrays = report counts per Tunis hour 6..22 (weekdays Mon-Fri / weekend Sat-Sun). Rows ('rw' weekdays top 8, 're' weekend top 3) = the
-- station + direction + hour slots seen on the MOST DIFFERENT days (dd), at least 2 days. a = toward the last station of the line, b = toward the first.
create or replace function admin_insights(p_days int) returns json
language plpgsql stable security definer set search_path=public as $$
declare v_to date := (now() at time zone 'Africa/Tunis')::date - 1; v_days int := greatest(7, least(coalesce(p_days,21), 90)); v_from date; r json;
begin
  v_from := v_to - (v_days-1);
  with base as (
    select st.line_id lid, st.ar st_ar, s.dir,
           (s.seen_at at time zone 'Africa/Tunis')::date d,
           extract(hour from s.seen_at at time zone 'Africa/Tunis')::int h,
           (extract(isodow from s.seen_at at time zone 'Africa/Tunis') >= 6) we
    from sightings s join stations st on st.id=s.station_id
    where s.seen_at >= (v_from::timestamp at time zone 'Africa/Tunis')
      and s.seen_at <  ((v_to+1)::timestamp at time zone 'Africa/Tunis')
      and s.down - s.up < 2
      and not exists (select 1 from banned b where b.k in (s.dev, s.ip))
  ), hrs as (
    select lid, we, h, count(*) c from base where h between 6 and 22 group by 1,2,3
  ), rep as (
    select lid, we, st_ar, dir, h, count(distinct d) dd, count(*) nn from base where h between 6 and 22 group by 1,2,3,4,5 having count(distinct d) >= 2
  ), repr as (
    select *, row_number() over (partition by lid, we order by dd desc, nn desc, h, st_ar) rn from rep
  )
  select json_build_object(
    'from', v_from, 'to', v_to, 'days', v_days,
    'wd_days', (select count(*) from generate_series(v_from::timestamp, v_to::timestamp, interval '1 day') g where extract(isodow from g) < 6),
    'we_days', (select count(*) from generate_series(v_from::timestamp, v_to::timestamp, interval '1 day') g where extract(isodow from g) >= 6),
    'lines', (select coalesce(json_agg(x order by x.sort), '[]'::json) from (
      select l.id, l.color, l.sort,
        (select ar from stations where line_id=l.id order by pos desc limit 1) a,
        (select ar from stations where line_id=l.id order by pos asc  limit 1) b,
        (select count(*) from base where lid=l.id) n,
        (select coalesce(json_object_agg(h, c), '{}'::json) from hrs where lid=l.id and not we) hw,
        (select coalesce(json_object_agg(h, c), '{}'::json) from hrs where lid=l.id and we) he,
        (select coalesce(json_agg(json_build_object('st',st_ar,'dir',dir,'h',h,'dd',dd,'nn',nn) order by rn), '[]'::json) from repr where lid=l.id and not we and rn<=8) rw,
        (select coalesce(json_agg(json_build_object('st',st_ar,'dir',dir,'h',h,'dd',dd,'nn',nn) order by rn), '[]'::json) from repr where lid=l.id and we and rn<=3) re
      from lines l) x)
  ) into r;
  return r;
end $$;
revoke all on function admin_insights(int) from public, anon, authenticated;
grant execute on function admin_insights(int) to service_role;
