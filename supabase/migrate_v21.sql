-- v0.49: "Metro stopped" reports now carry a direction: 'a' / 'b' (same meaning as sightings) or 'x' = both directions. Old rows / old app versions have dir NULL (= treated as both).
-- Run once in the Supabase SQL editor. Safe to re-run.
alter table incidents add column if not exists dir text;
do $$ begin
  if not exists (select 1 from pg_constraint where conname='incidents_dir_chk') then
    alter table incidents add constraint incidents_dir_chk check (dir in ('a','b','x'));
  end if;
end $$;

-- live_incidents: same rules as before + dir (new LAST column). A train seen heading the stopped direction clears the alert; a train going the other way does not.
create or replace view live_incidents as
select i.id, st.line_id, i.station_id, i.seen_at, i.up, i.down, i.last_at, i.dir
from incidents i join stations st on st.id=i.station_id
where i.last_at > now()-interval '15 minutes'
  and i.down < i.up
  and not exists(select 1 from sightings s where s.station_id=i.station_id
                 and s.seen_at > i.last_at + interval '2 minutes' and s.down-s.up<2
                 and (i.dir is null or i.dir='x' or s.dir=i.dir));
grant select on live_incidents to anon;

-- report_incident: new optional p_dir. A report joins a live alert at the same station only if the directions overlap (same direction, or either side is 'both'/unknown); otherwise it opens a separate alert.
drop function if exists report_incident(int,text,text);
create or replace function report_incident(p_station int, p_dev text, p_ip text, p_dir text default null) returns text
language plpgsql security definer set search_path=public as $$
declare v_ip text := md5(coalesce(p_ip,'?')); v_id bigint; v_key text; v_line text; v_dir text := case when p_dir in ('a','b','x') then p_dir else null end;
begin
  if p_dev is null or length(p_dev)<16 then return 'bad'; end if;
  if exists(select 1 from banned where k in (p_dev,v_ip)) then return 'bad'; end if;
  if is_blocked(p_dev) then return 'blocked'; end if;
  select station_key(id), line_id into v_key, v_line from stations where id=p_station;
  if v_key is null then return 'bad'; end if;
  if exists(select 1 from incidents where dev=p_dev and seen_at>now()-interval '10 minutes') then
    if exists(select 1 from incidents x join stations sx on sx.id=x.station_id
              where x.dev=p_dev and x.seen_at>now()-interval '10 minutes' and (station_key(sx.id) is distinct from v_key or sx.line_id=v_line))
       or (select count(*) from incidents where dev=p_dev and seen_at>now()-interval '10 minutes')>=3
    then return 'slow'; end if;
  end if;
  if (select count(*) from incidents where ip=v_ip and seen_at>now()-interval '1 hour')>30 then return 'slow'; end if;
  select id into v_id from live_incidents
   where station_id=p_station and (dir is null or v_dir is null or dir='x' or v_dir='x' or dir=v_dir)
   order by seen_at desc limit 1;
  if v_id is not null then  -- already live here (same direction): this device confirms it (once per device) and keeps it alive
    insert into incident_votes(incident_id,dev,v,ip) values(v_id,p_dev,1,v_ip) on conflict do nothing;
    if found then update incidents set up=up+1, last_at=now() where id=v_id; end if;
    return 'ok';
  end if;
  insert into incidents(station_id,dev,ip,up,last_at,dir) values(p_station,p_dev,v_ip,1,now(),v_dir) returning id into v_id;
  insert into incident_votes(incident_id,dev,v,ip) values(v_id,p_dev,1,v_ip);
  return 'ok';
end $$;
revoke all on function report_incident(int,text,text,text) from public, anon, authenticated;
grant execute on function report_incident(int,text,text,text) to service_role;
