-- v0.11: stop reports reworked. Safe to re-run. Lifetime/thresholds live ONLY in the view below.
alter table incidents add column if not exists last_at timestamptz;
update incidents set last_at=seen_at where last_at is null;
alter table incidents alter column last_at set default now();
create index if not exists sightings_station_seen on sightings(station_id,seen_at desc);

-- An alert is live while: someone confirmed 'still stopped' in the last 15 min, 'running again' votes < 'stopped' votes,
-- and nobody reported a metro AT THAT STATION more than 2 min after the last confirmation.
create or replace view live_incidents as
select i.id, st.line_id, i.station_id, i.seen_at, i.up, i.down, i.last_at
from incidents i join stations st on st.id=i.station_id
where i.last_at > now()-interval '15 minutes'
  and i.down < i.up
  and not exists(select 1 from sightings s where s.station_id=i.station_id
                 and s.seen_at > i.last_at + interval '2 minutes' and s.down-s.up<2);
grant select on live_incidents to anon;

create or replace function report_incident(p_station int, p_dev text, p_ip text) returns text
language plpgsql security definer set search_path=public as $$
declare v_ip text := md5(coalesce(p_ip,'?')); v_id bigint;
begin
  if p_dev is null or length(p_dev)<16 then return 'bad'; end if;
  if exists(select 1 from banned where k in (p_dev,v_ip)) then return 'bad'; end if;
  if not exists(select 1 from stations where id=p_station) then return 'bad'; end if;
  if exists(select 1 from incidents where dev=p_dev and seen_at>now()-interval '10 minutes') then return 'slow'; end if;
  if (select count(*) from incidents where ip=v_ip and seen_at>now()-interval '1 hour')>30 then return 'slow'; end if;
  select id into v_id from live_incidents where station_id=p_station order by seen_at desc limit 1;
  if v_id is not null then  -- already live here: this device confirms it (once per device) and keeps it alive
    insert into incident_votes(incident_id,dev,v,ip) values(v_id,p_dev,1,v_ip) on conflict do nothing;
    if found then update incidents set up=up+1, last_at=now() where id=v_id; end if;
    return 'ok';
  end if;
  insert into incidents(station_id,dev,ip,up,last_at) values(p_station,p_dev,v_ip,1,now()) returning id into v_id;
  insert into incident_votes(incident_id,dev,v,ip) values(v_id,p_dev,1,v_ip);
  return 'ok';
end $$;

create or replace function vote_incident(p_id bigint, p_v int, p_dev text, p_ip text) returns text
language plpgsql security definer set search_path=public as $$
declare v_ip text := md5(coalesce(p_ip,'?'));
begin
  if p_dev is null or length(p_dev)<16 or p_v not in (1,-1) then return 'bad'; end if;
  if exists(select 1 from banned where k in (p_dev,v_ip)) then return 'bad'; end if;
  if (select count(*) from incident_votes where ip=v_ip and at>now()-interval '1 hour')>200 then return 'slow'; end if;
  insert into incident_votes(incident_id,dev,v,ip) values(p_id,p_dev,p_v,v_ip) on conflict do nothing;
  if not found then return 'dup'; end if;
  update incidents set up=up+(p_v=1)::int, down=down+(p_v=-1)::int,
    last_at=case when p_v=1 and exists(select 1 from live_incidents where id=p_id) then now() else last_at end
  where id=p_id;  -- only 'still stopped' on a live alert extends it
  return 'ok';
end $$;

revoke all on function report_incident(int,text,text), vote_incident(bigint,int,text,text) from public, anon, authenticated;
grant execute on function report_incident(int,text,text), vote_incident(bigint,int,text,text) to service_role;
