-- v0.53: a train that STANDS at a station no longer turns into a new sighting every few minutes.
-- The 'same train' window used to be a fixed 3 min (report merge) / 4 min (live view). It now grows with the confirmations the sighting already has:
-- report merge window = 3 + 2*min(up,4) min (3..11), live view window = 4 + 2*min(up,4) min (4..12). Each merge keeps the confirmations, so a stationary train stays ONE entry.
-- Cost: a genuinely new train arriving at the same station within that window after a well-confirmed one is merged into it (the board still shows the newest time).
-- Run once in the Supabase SQL editor; safe to re-run. Needs migrate_v16/v23 (station_key, report).
create or replace view live as
with cand as (
  select s.id, st.line_id, s.station_id, s.dir, s.seen_at, s.up, s.down
  from sightings s join stations st on st.id=s.station_id
  where s.seen_at > now()-interval '30 days' and s.down-s.up<2
    and not exists(select 1 from sightings n where n.station_id=s.station_id and n.dir=s.dir
                   and n.seen_at>s.seen_at and n.seen_at<=s.seen_at+make_interval(mins => 4+2*least(s.up,4)) and n.down-n.up<2)
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

create or replace function report(p_station int, p_dir text, p_dev text, p_ip text) returns text
language plpgsql security definer set search_path=public as $$
declare v_ip text := md5(coalesce(p_ip,'?')); v_new bigint; v_old record; v_up int; v_mins int := 3; v_key text; v_line text; d text;
begin
  if p_dev is null or length(p_dev)<16 or p_dir not in ('a','b','x') then return 'bad'; end if;
  if exists(select 1 from banned where k in (p_dev,v_ip)) then return 'bad'; end if;
  if is_blocked(p_dev) then return 'blocked'; end if;
  select station_key(id), line_id into v_key, v_line from stations where id=p_station;
  if v_key is null then return 'bad'; end if;
  if exists(select 1 from sightings where dev=p_dev and seen_at>now()-interval '2 minutes') then
    -- interchange exception (see header); anything else inside 2 minutes is too fast
    if exists(select 1 from sightings x join stations sx on sx.id=x.station_id
              where x.dev=p_dev and x.seen_at>now()-interval '2 minutes' and (station_key(sx.id) is distinct from v_key or (sx.line_id=v_line and (sx.id<>p_station or p_dir='x' or x.dir=p_dir))))
       or (select count(*) from sightings where dev=p_dev and seen_at>now()-interval '2 minutes')>=3-(p_dir='x')::int
       or (select count(*) from sightings where dev=p_dev and seen_at>now()-interval '10 minutes')>=5-(p_dir='x')::int
    then return 'slow'; end if;
  end if;
  if (select count(*) from sightings where ip=v_ip and seen_at>now()-interval '1 hour')>120 then return 'slow'; end if; -- generous: mobile carriers share IPs
  foreach d in array (case when p_dir='x' then array['a','b'] else array[p_dir] end) loop
    v_up := 0;
    insert into sightings(station_id,dir,dev,ip) values(p_station,d,p_dev,v_ip) returning id into v_new;
    select * into v_old from sightings
    where station_id=p_station and dir=d and id<>v_new
      and seen_at>now()-make_interval(mins => v_mins+2*least(up,4)) and down-up<2
    order by seen_at desc limit 1;
    if found then
      update votes set sighting_id=v_new where sighting_id=v_old.id;                                    -- keep who already voted
      if v_old.dev<>p_dev then
        insert into votes(sighting_id,dev,v,ip) values(v_new,v_old.dev,1,v_old.ip) on conflict do nothing; -- the old reporter cannot also tap 👍
        if found then v_up := 1; end if;
      end if;
      update sightings set up=v_old.up+v_up, down=v_old.down where id=v_new;
      delete from sightings where id=v_old.id;
    end if;
  end loop;
  return 'ok';
end $$;
revoke all on function report(int,text,text,text) from public, anon, authenticated;
grant execute on function report(int,text,text,text) to service_role;
