-- v0.47: people can see what they posted and remove their own sightings / incidents / votes (no accounts). Run once in the Supabase SQL editor. Safe to re-run.
-- Ownership = the random device id (never exposed by any public view). Removals need no CAPTCHA but are rate limited (undo_log).
create index if not exists sightings_dev on sightings(dev, seen_at desc);
create index if not exists incidents_dev on incidents(dev, seen_at desc);
create index if not exists votes_dev on votes(dev);
create index if not exists incident_votes_dev on incident_votes(dev);
create table if not exists undo_log(dev text, ip text, at timestamptz default now());
create index if not exists undo_log_dev on undo_log(dev, at desc);
create index if not exists undo_log_ip on undo_log(ip, at desc);
alter table undo_log enable row level security;   -- no policies: Worker only

-- what this device posted / voted on (ids only, newest first). Called by the app on load and after posting.
create or replace function my_posts(p_dev text) returns json language sql stable security definer set search_path=public as $$
  select case when length(coalesce(p_dev,''))<16 then '{}'::json else json_build_object(
    's',  (select coalesce(json_agg(id),'[]'::json) from (select id from sightings where dev=p_dev and seen_at>now()-interval '30 days' order by id desc limit 40) a),
    'i',  (select coalesce(json_agg(id),'[]'::json) from (select id from incidents where dev=p_dev and seen_at>now()-interval '30 days' order by id desc limit 40) b),
    'sv', (select coalesce(json_object_agg(sighting_id::text, v),'{}'::json) from (select sighting_id, v from votes where dev=p_dev order by at desc nulls last limit 80) c),
    'iv', (select coalesce(json_object_agg(incident_id::text, v),'{}'::json) from (select incident_id, v from incident_votes where dev=p_dev order by at desc nulls last limit 80) d)
  ) end $$;

-- remove MY sighting ('s') or incident ('i'). Only if nobody marked it wrong (down=0): a bad report cannot be deleted to dodge the auto-pause.
create or replace function remove_post(p_kind text, p_id bigint, p_dev text, p_ip text) returns text
language plpgsql security definer set search_path=public as $$
declare v_ip text := md5(coalesce(p_ip,'?')); v_down int;
begin
  if p_dev is null or length(p_dev)<16 or p_kind not in ('s','i') then return 'bad'; end if;
  if exists(select 1 from banned where k in (p_dev,v_ip)) then return 'bad'; end if;
  if is_blocked(p_dev) then return 'blocked'; end if;
  if (select count(*) from undo_log where dev=p_dev and at>now()-interval '1 hour')>=30
     or (select count(*) from undo_log where ip=v_ip and at>now()-interval '1 hour')>=120 then return 'slow'; end if;
  if p_kind='s' then select down into v_down from sightings where id=p_id and dev=p_dev;
  else select down into v_down from incidents where id=p_id and dev=p_dev; end if;
  if not found then return 'gone'; end if;                 -- not yours, or already gone
  if v_down>0 then return 'locked'; end if;                -- someone marked it wrong: it stays so the auto-pause can count it
  if p_kind='s' then delete from sightings where id=p_id and dev=p_dev;  -- votes go with it (on delete cascade)
  else delete from incidents where id=p_id and dev=p_dev; end if;
  insert into undo_log(dev,ip) values(p_dev,v_ip);
  if random()<0.02 then delete from undo_log where at<now()-interval '1 day'; end if;
  return 'ok';
end $$;

-- remove MY vote on a sighting ('s') or an incident ('i') and take it out of the counts
create or replace function remove_vote(p_kind text, p_id bigint, p_dev text, p_ip text) returns text
language plpgsql security definer set search_path=public as $$
declare v_ip text := md5(coalesce(p_ip,'?')); v_v int;
begin
  if p_dev is null or length(p_dev)<16 or p_kind not in ('s','i') then return 'bad'; end if;
  if exists(select 1 from banned where k in (p_dev,v_ip)) then return 'bad'; end if;
  if is_blocked(p_dev) then return 'blocked'; end if;
  if (select count(*) from undo_log where dev=p_dev and at>now()-interval '1 hour')>=30
     or (select count(*) from undo_log where ip=v_ip and at>now()-interval '1 hour')>=120 then return 'slow'; end if;
  if p_kind='s' then
    delete from votes where sighting_id=p_id and dev=p_dev returning v into v_v;
    if not found then return 'gone'; end if;
    update sightings set up=greatest(0,up-(v_v=1)::int), down=greatest(0,down-(v_v=-1)::int) where id=p_id;
  else
    delete from incident_votes where incident_id=p_id and dev=p_dev returning v into v_v;
    if not found then return 'gone'; end if;
    update incidents set up=greatest(0,up-(v_v=1)::int), down=greatest(0,down-(v_v=-1)::int) where id=p_id;
  end if;
  insert into undo_log(dev,ip) values(p_dev,v_ip);
  if random()<0.02 then delete from undo_log where at<now()-interval '1 day'; end if;
  return 'ok';
end $$;

-- vote(): same as before + you cannot vote on your own sighting (stops self-confirmation)
create or replace function vote(p_id bigint, p_v int, p_dev text, p_ip text) returns text
language plpgsql security definer set search_path=public as $$
declare v_ip text := md5(coalesce(p_ip,'?'));
begin
  if p_dev is null or length(p_dev)<16 or p_v not in (1,-1) then return 'bad'; end if;
  if exists(select 1 from banned where k in (p_dev,v_ip)) then return 'bad'; end if;
  if is_blocked(p_dev) then return 'blocked'; end if;
  if (select count(*) from votes where ip=v_ip and at>now()-interval '1 hour')>200 then return 'slow'; end if;
  if exists(select 1 from sightings where id=p_id and dev=p_dev) then return 'dup'; end if;
  insert into votes(sighting_id,dev,v,ip) values(p_id,p_dev,p_v,v_ip) on conflict do nothing;
  if not found then return 'dup'; end if;
  update sightings set up=up+(p_v=1)::int, down=down+(p_v=-1)::int where id=p_id;
  return 'ok';
end $$;

-- vote_incident(): same as before + no voting on your own incident; a device that removed something in the last 90 min cannot extend an alert (stops vote/undo cycles keeping a fake alert alive)
create or replace function vote_incident(p_id bigint, p_v int, p_dev text, p_ip text) returns text
language plpgsql security definer set search_path=public as $$
declare v_ip text := md5(coalesce(p_ip,'?'));
begin
  if p_dev is null or length(p_dev)<16 or p_v not in (1,-1) then return 'bad'; end if;
  if exists(select 1 from banned where k in (p_dev,v_ip)) then return 'bad'; end if;
  if is_blocked(p_dev) then return 'blocked'; end if;
  if (select count(*) from incident_votes where ip=v_ip and at>now()-interval '1 hour')>200 then return 'slow'; end if;
  if exists(select 1 from incidents where id=p_id and dev=p_dev) then return 'dup'; end if;
  insert into incident_votes(incident_id,dev,v,ip) values(p_id,p_dev,p_v,v_ip) on conflict do nothing;
  if not found then return 'dup'; end if;
  update incidents set up=up+(p_v=1)::int, down=down+(p_v=-1)::int,
    last_at=case when p_v=1 and exists(select 1 from live_incidents where id=p_id)
                  and not exists(select 1 from undo_log where dev=p_dev and at>now()-interval '90 minutes') then now() else last_at end
  where id=p_id;
  return 'ok';
end $$;

revoke all on function my_posts(text), remove_post(text,bigint,text,text), remove_vote(text,bigint,text,text), vote(bigint,int,text,text), vote_incident(bigint,int,text,text) from public, anon, authenticated;
grant execute on function my_posts(text), remove_post(text,bigint,text,text), remove_vote(text,bigint,text,text), vote(bigint,int,text,text), vote_incident(bigint,int,text,text) to service_role;
