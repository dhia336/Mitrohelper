-- Run ONCE on an existing database (v0.5 or older). Adds breakdown reports and locks writes to the Worker.
-- ===== v2: breakdown reports, hardened functions (writes only via the Worker with the secret key) =====
alter table votes add column if not exists ip text;
alter table votes add column if not exists at timestamptz default now();
create table if not exists banned(k text primary key);
create table if not exists incidents(id bigserial primary key, station_id int references stations on delete cascade,
  seen_at timestamptz default now(), dev text, ip text, up int default 0, down int default 0);
create index if not exists incidents_seen on incidents(seen_at desc);
create table if not exists incident_votes(incident_id bigint references incidents on delete cascade, dev text, v int, ip text,
  at timestamptz default now(), primary key(incident_id,dev));
alter table banned enable row level security; alter table incidents enable row level security; alter table incident_votes enable row level security;
create or replace view live_incidents as select i.id, st.line_id, i.station_id, i.seen_at, i.up, i.down
  from incidents i join stations st on st.id=i.station_id
  where i.seen_at > now()-interval '90 minutes' and i.down - i.up < 2;
grant select on live_incidents to anon;

drop function if exists report(int,text,text); drop function if exists vote(bigint,int,text);

create or replace function report(p_station int, p_dir text, p_dev text, p_ip text) returns text
language plpgsql security definer set search_path=public as $$
declare v_ip text := md5(coalesce(p_ip,'?'));
begin
  if p_dev is null or length(p_dev)<16 or p_dir not in ('a','b') then return 'bad'; end if;
  if exists(select 1 from banned where k in (p_dev,v_ip)) then return 'bad'; end if;
  if not exists(select 1 from stations where id=p_station) then return 'bad'; end if;
  if exists(select 1 from sightings where dev=p_dev and seen_at>now()-interval '2 minutes') then return 'slow'; end if;
  if (select count(*) from sightings where ip=v_ip and seen_at>now()-interval '1 hour')>120 then return 'slow'; end if; -- generous: mobile carriers share IPs
  insert into sightings(station_id,dir,dev,ip) values(p_station,p_dir,p_dev,v_ip);
  return 'ok';
end $$;

create or replace function vote(p_id bigint, p_v int, p_dev text, p_ip text) returns text
language plpgsql security definer set search_path=public as $$
declare v_ip text := md5(coalesce(p_ip,'?'));
begin
  if p_dev is null or length(p_dev)<16 or p_v not in (1,-1) then return 'bad'; end if;
  if exists(select 1 from banned where k in (p_dev,v_ip)) then return 'bad'; end if;
  if (select count(*) from votes where ip=v_ip and at>now()-interval '1 hour')>200 then return 'slow'; end if;
  insert into votes(sighting_id,dev,v,ip) values(p_id,p_dev,p_v,v_ip) on conflict do nothing;
  if not found then return 'dup'; end if;
  update sightings set up=up+(p_v=1)::int, down=down+(p_v=-1)::int where id=p_id;
  return 'ok';
end $$;

create or replace function report_incident(p_station int, p_dev text, p_ip text) returns text
language plpgsql security definer set search_path=public as $$
declare v_ip text := md5(coalesce(p_ip,'?')); v_id bigint;
begin
  if p_dev is null or length(p_dev)<16 then return 'bad'; end if;
  if exists(select 1 from banned where k in (p_dev,v_ip)) then return 'bad'; end if;
  if not exists(select 1 from stations where id=p_station) then return 'bad'; end if;
  if exists(select 1 from incidents where dev=p_dev and seen_at>now()-interval '10 minutes') then return 'slow'; end if;
  if (select count(*) from incidents where ip=v_ip and seen_at>now()-interval '1 hour')>30 then return 'slow'; end if;
  select id into v_id from incidents where station_id=p_station and seen_at>now()-interval '90 minutes' and down-up<2 order by seen_at desc limit 1;
  if v_id is not null then  -- same problem already reported here: count as a confirmation
    insert into incident_votes(incident_id,dev,v,ip) values(v_id,p_dev,1,v_ip) on conflict do nothing;
    if found then update incidents set up=up+1 where id=v_id; end if;
    return 'ok';
  end if;
  insert into incidents(station_id,dev,ip,up) values(p_station,p_dev,v_ip,1) returning id into v_id;
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
  update incidents set up=up+(p_v=1)::int, down=down+(p_v=-1)::int where id=p_id;
  return 'ok';
end $$;

create or replace function purge_old() returns int
language plpgsql security definer set search_path=public as $$
declare n int; m int;
begin
  delete from sightings where seen_at<now()-interval '90 days'; get diagnostics n=row_count;
  delete from incidents where seen_at<now()-interval '90 days'; get diagnostics m=row_count;
  return n+m;
end $$;

-- Supabase grants EXECUTE to anon by default: remove it explicitly. Only the Worker (service_role/secret key) may call these.
revoke all on function report(int,text,text,text), vote(bigint,int,text,text), report_incident(int,text,text), vote_incident(bigint,int,text,text), purge_old() from public, anon, authenticated;
grant execute on function report(int,text,text,text), vote(bigint,int,text,text), report_incident(int,text,text), vote_incident(bigint,int,text,text), purge_old() to service_role;

