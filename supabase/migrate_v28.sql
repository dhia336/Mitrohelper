-- v0.56: admin "Insights" tab (share images per line). Run once in the Supabase SQL editor; safe to re-run.
-- Aggregates the last p_days days (7..90, ending yesterday, Tunis time) of sightings. Left out: banned devices/IPs and every report riders rated net-negative (down > up).
-- VOTES: a report confirmed by riders counts more in the hour chart and in the tie-break (weight 1 + min(up,2), so 1 to 3).
-- p_bucket = size of the time slots in the repeating-times list: 15, 30 or 60 minutes (default 15). Rows return 'm' = minutes since midnight (Tunis).
-- Hour arrays = report counts per Tunis hour 6..22 (weekdays Mon-Fri / weekend Sat-Sun). Rows ('rw' weekdays top 8, 're' weekend top 3) = the
-- station + direction + hour slots seen on the MOST DIFFERENT days (dd), at least 2 days. a = toward the last station of the line, b = toward the first.
drop function if exists admin_insights(int);
create or replace function admin_insights(p_days int, p_bucket int default 15) returns json
language plpgsql stable security definer set search_path=public as $$
declare v_to date := (now() at time zone 'Africa/Tunis')::date - 1; v_days int := greatest(7, least(coalesce(p_days,21), 90)); v_b int := case when p_bucket in (15,30,60) then p_bucket else 15 end; v_from date; r json;
begin
  v_from := v_to - (v_days-1);
  with base as (
    select st.line_id lid, st.ar st_ar, s.dir,
           (s.seen_at at time zone 'Africa/Tunis')::date d,
           extract(hour from s.seen_at at time zone 'Africa/Tunis')::int h,
           ((extract(hour from s.seen_at at time zone 'Africa/Tunis')::int*60 + extract(minute from s.seen_at at time zone 'Africa/Tunis')::int) / v_b) * v_b m,
           1 + least(coalesce(s.up,0), 2) w,
           (extract(isodow from s.seen_at at time zone 'Africa/Tunis') >= 6) we
    from sightings s join stations st on st.id=s.station_id
    where s.seen_at >= (v_from::timestamp at time zone 'Africa/Tunis')
      and s.seen_at <  ((v_to+1)::timestamp at time zone 'Africa/Tunis')
      and coalesce(s.down,0) <= coalesce(s.up,0)
      and not exists (select 1 from banned b where b.k in (s.dev, s.ip))
  ), hrs as (
    select lid, we, h, sum(w)::int c from base where h between 6 and 22 group by 1,2,3
  ), rep as (
    select lid, we, st_ar, dir, m, count(distinct d) dd, sum(w)::int nn from base where h between 6 and 22 group by 1,2,3,4,5 having count(distinct d) >= 2
  ), repr as (
    select *, row_number() over (partition by lid, we order by dd desc, nn desc, m, st_ar) rn from rep
  )
  select json_build_object(
    'from', v_from, 'to', v_to, 'days', v_days, 'bucket', v_b,
    'wd_days', (select count(*) from generate_series(v_from::timestamp, v_to::timestamp, interval '1 day') g where extract(isodow from g) < 6),
    'we_days', (select count(*) from generate_series(v_from::timestamp, v_to::timestamp, interval '1 day') g where extract(isodow from g) >= 6),
    'lines', (select coalesce(json_agg(x order by x.sort), '[]'::json) from (
      select l.id, l.color, l.sort,
        (select ar from stations where line_id=l.id order by pos desc limit 1) a,
        (select ar from stations where line_id=l.id order by pos asc  limit 1) b,
        (select count(*) from base where lid=l.id) n,
        (select coalesce(json_object_agg(h, c), '{}'::json) from hrs where lid=l.id and not we) hw,
        (select coalesce(json_object_agg(h, c), '{}'::json) from hrs where lid=l.id and we) he,
        (select coalesce(json_agg(json_build_object('st',st_ar,'dir',dir,'m',m,'dd',dd,'nn',nn) order by rn), '[]'::json) from repr where lid=l.id and not we and rn<=8) rw,
        (select coalesce(json_agg(json_build_object('st',st_ar,'dir',dir,'m',m,'dd',dd,'nn',nn) order by rn), '[]'::json) from repr where lid=l.id and we and rn<=3) re
      from lines l) x)
  ) into r;
  return r;
end $$;
revoke all on function admin_insights(int,int) from public, anon, authenticated;
grant execute on function admin_insights(int,int) to service_role;
