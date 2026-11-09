-- PRODUCTION CATCH-UP (v0.25): applies migrate_v4 .. migrate_v10 in order. Every part is 'create or replace' / 'if not exists', so it is safe to run on a DB that already has some of them.
-- Needs migrate_v2 (tables, banned, incidents) applied. Run in the Supabase SQL editor of the PRODUCTION project. NEVER run test_seed.sql on production.

-- ===== migrate_v4 =====
-- v0.10: one-query live board + indexes for the anti-spam checks. Safe to re-run.
create or replace function live_all() returns json language sql stable set search_path=public as $$
  select json_build_object(
    's',(select coalesce(json_agg(l),'[]'::json) from live l),
    'i',(select coalesce(json_agg(i),'[]'::json) from live_incidents i)) $$;
revoke all on function live_all() from public, anon, authenticated;
grant execute on function live_all() to service_role;
create index if not exists sightings_dev_seen on sightings(dev,seen_at desc);
create index if not exists sightings_ip_seen on sightings(ip,seen_at desc);
create index if not exists incidents_dev_seen on incidents(dev,seen_at desc);
create index if not exists incidents_ip_seen on incidents(ip,seen_at desc);
create index if not exists votes_ip_at on votes(ip,at desc);
create index if not exists incident_votes_ip_at on incident_votes(ip,at desc);

-- ===== migrate_v5 =====
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

-- ===== migrate_v6 =====
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

-- ===== migrate_v7 =====
-- v0.16. Safe to re-run.
-- 1) live view: per line+direction the 3 newest sightings at DIFFERENT stations (one row per station+direction = the newest there).
--    The app shows the newest of each direction on the card top, and the 3 newest of the line in the station list.
--    Rows hidden by votes (down-up>=2) are skipped. Never expires (30-day floor, index on seen_at). Max 3 x 2 x 7 = 42 rows. Columns unchanged.
create or replace view live as
select id, line_id, station_id, dir, seen_at, up, down from (
  select x.*, row_number() over (partition by x.line_id, x.dir order by x.seen_at desc, x.id desc) rn
  from (
    select distinct on (s.station_id, s.dir) s.id, st.line_id, s.station_id, s.dir, s.seen_at, s.up, s.down
    from sightings s join stations st on st.id=s.station_id
    where s.seen_at > now()-interval '30 days' and s.down-s.up<2
    order by s.station_id, s.dir, s.seen_at desc, s.id desc
  ) x
) y where rn<=3;

-- 2) live_all also returns n = real number of sightings in the last 90 min (the view is capped, so it cannot be counted from it)
create or replace function live_all() returns json language sql stable set search_path=public as $$
  select json_build_object(
    's',(select coalesce(json_agg(l),'[]'::json) from live l),
    'i',(select coalesce(json_agg(i),'[]'::json) from live_incidents i),
    'n',(select count(*) from sightings where seen_at>now()-interval '90 minutes' and down-up<2)) $$;
revoke all on function live_all() from public, anon, authenticated;
grant execute on function live_all() to service_role;

-- 3) AUTOMATIC BLOCK (no table, nothing to maintain): a device is paused when other riders hid >=3 of its sightings in 24 h,
--    or >=6 in 7 days (a sighting is hidden when downvotes exceed upvotes by 2). It ends by itself as those sightings age out of the window.
--    Applies to reports and votes. Stop alerts are NOT counted: a real stop that ended quickly also gets voted away.
create or replace function is_blocked(p_dev text) returns boolean language sql stable set search_path=public as $$
  select (select count(*) from sightings where dev=p_dev and seen_at>now()-interval '24 hours' and down-up>=2)>=3
      or (select count(*) from sightings where dev=p_dev and seen_at>now()-interval '7 days' and down-up>=2)>=6 $$;
revoke all on function is_blocked(text) from public, anon, authenticated;
grant execute on function is_blocked(text) to service_role;

-- 4) the same functions as before, plus: if is_blocked(p_dev) then return 'blocked'
create or replace function report(p_station int, p_dir text, p_dev text, p_ip text) returns text
language plpgsql security definer set search_path=public as $$
declare v_ip text := md5(coalesce(p_ip,'?'));
begin
  if p_dev is null or length(p_dev)<16 or p_dir not in ('a','b') then return 'bad'; end if;
  if exists(select 1 from banned where k in (p_dev,v_ip)) then return 'bad'; end if;
  if is_blocked(p_dev) then return 'blocked'; end if;
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
  if is_blocked(p_dev) then return 'blocked'; end if;
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
  if is_blocked(p_dev) then return 'blocked'; end if;
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
  if is_blocked(p_dev) then return 'blocked'; end if;
  if (select count(*) from incident_votes where ip=v_ip and at>now()-interval '1 hour')>200 then return 'slow'; end if;
  insert into incident_votes(incident_id,dev,v,ip) values(p_id,p_dev,p_v,v_ip) on conflict do nothing;
  if not found then return 'dup'; end if;
  update incidents set up=up+(p_v=1)::int, down=down+(p_v=-1)::int,
    last_at=case when p_v=1 and exists(select 1 from live_incidents where id=p_id) then now() else last_at end
  where id=p_id;  -- only 'still stopped' on a live alert extends it
  return 'ok';
end $$;

revoke all on function report(int,text,text,text), vote(bigint,int,text,text), report_incident(int,text,text), vote_incident(bigint,int,text,text) from public, anon, authenticated;
grant execute on function report(int,text,text,text), vote(bigint,int,text,text), report_incident(int,text,text), vote_incident(bigint,int,text,text) to service_role;

-- ===== migrate_v8 =====
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

-- ===== migrate_v9 =====
-- v0.18: a 2nd report of the SAME TRAIN replaces the first and counts as +1 confirmation. Safe to re-run.
-- Same train = same STATION (so same line) + same direction, and the older report is <= 3 min old and not hidden by votes.
-- The old report is deleted; its votes move to the new one; its reporter counts as +1 (unless it was the SAME device: then it is only replaced).
create or replace function report(p_station int, p_dir text, p_dev text, p_ip text) returns text
language plpgsql security definer set search_path=public as $$
declare v_ip text := md5(coalesce(p_ip,'?')); v_new bigint; v_old record; v_up int := 0; v_mins int := 3;
begin
  if p_dev is null or length(p_dev)<16 or p_dir not in ('a','b') then return 'bad'; end if;
  if exists(select 1 from banned where k in (p_dev,v_ip)) then return 'bad'; end if;
  if is_blocked(p_dev) then return 'blocked'; end if;
  if not exists(select 1 from stations where id=p_station) then return 'bad'; end if;
  if exists(select 1 from sightings where dev=p_dev and seen_at>now()-interval '2 minutes') then return 'slow'; end if;
  if (select count(*) from sightings where ip=v_ip and seen_at>now()-interval '1 hour')>120 then return 'slow'; end if; -- generous: mobile carriers share IPs
  insert into sightings(station_id,dir,dev,ip) values(p_station,p_dir,p_dev,v_ip) returning id into v_new;

  select * into v_old from sightings
  where station_id=p_station and dir=p_dir and id<>v_new
    and seen_at>now()-make_interval(mins => v_mins) and down-up<2
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
  return 'ok';
end $$;
revoke all on function report(int,text,text,text) from public, anon, authenticated;
grant execute on function report(int,text,text,text) to service_role;

-- ===== migrate_v10 =====
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
