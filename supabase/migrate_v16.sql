-- v16 (v0.37): interchange stations. A rider standing at a station that exists on several lines (same name, different line rows)
-- may report a train of ANOTHER line there without waiting 2 minutes. Safe to re-run. Replaces report() and report_incident() (v9/v7 logic kept).
-- Same physical station = same lower(btrim(fr)) (falls back to en, ar). Check what production treats as shared:
--   select lower(btrim(coalesce(fr,en,ar))) n, string_agg(line_id,',' order by line_id) from stations group by 1 having count(*)>1 order by 1;
-- Limits (they never exceed the old sustained rate of 1 report / 2 min = 5 per 10 min):
--   report():          2nd/3rd report inside 2 min only if ALL of the device's reports of the last 2 min are at this same-named station on OTHER lines
--                      (so never the same line twice), at most 3 per 2 min, and < 5 per 10 min. Everything else stays 'slow'.
--   report_incident(): 2nd/3rd stop alert inside 10 min only under the same same-name/other-line rule, at most 3 per 10 min.

create or replace function station_key(p_id int) returns text language sql stable set search_path=public as $$
  select lower(btrim(coalesce(fr,en,ar))) from stations where id=p_id $$;
revoke all on function station_key(int) from public, anon, authenticated;
grant execute on function station_key(int) to service_role;

create or replace function report(p_station int, p_dir text, p_dev text, p_ip text) returns text
language plpgsql security definer set search_path=public as $$
declare v_ip text := md5(coalesce(p_ip,'?')); v_new bigint; v_old record; v_up int := 0; v_mins int := 3; v_key text; v_line text;
begin
  if p_dev is null or length(p_dev)<16 or p_dir not in ('a','b') then return 'bad'; end if;
  if exists(select 1 from banned where k in (p_dev,v_ip)) then return 'bad'; end if;
  if is_blocked(p_dev) then return 'blocked'; end if;
  select station_key(id), line_id into v_key, v_line from stations where id=p_station;
  if v_key is null then return 'bad'; end if;
  if exists(select 1 from sightings where dev=p_dev and seen_at>now()-interval '2 minutes') then
    -- interchange exception (see header); anything else inside 2 minutes is too fast
    if exists(select 1 from sightings x join stations sx on sx.id=x.station_id
              where x.dev=p_dev and x.seen_at>now()-interval '2 minutes' and (station_key(sx.id) is distinct from v_key or sx.line_id=v_line))
       or (select count(*) from sightings where dev=p_dev and seen_at>now()-interval '2 minutes')>=3
       or (select count(*) from sightings where dev=p_dev and seen_at>now()-interval '10 minutes')>=5
    then return 'slow'; end if;
  end if;
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

create or replace function report_incident(p_station int, p_dev text, p_ip text) returns text
language plpgsql security definer set search_path=public as $$
declare v_ip text := md5(coalesce(p_ip,'?')); v_id bigint; v_key text; v_line text;
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

revoke all on function report(int,text,text,text), report_incident(int,text,text) from public, anon, authenticated;
grant execute on function report(int,text,text,text), report_incident(int,text,text) to service_role;
