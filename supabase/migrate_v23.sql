-- v0.51: a sighting can be reported for BOTH directions at once (p_dir = 'x' -> one sighting per direction, 'a' and 'b').
-- Same checks as before; for 'x' the rate limits count the two rows it creates, and any recent sighting at the same station on the same line blocks it.
-- Leaderboard: already counts max 1 report per station per 15 min, so a both-direction report is worth one point. Run once in the Supabase SQL editor; safe to re-run.
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
  end loop;
  return 'ok';
end $$;
revoke all on function report(int,text,text,text) from public, anon, authenticated;
grant execute on function report(int,text,text,text) to service_role;
