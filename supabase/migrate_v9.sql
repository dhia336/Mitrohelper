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
