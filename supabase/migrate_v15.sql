-- v15 (v0.36): admin filters + scored suspects + device profile + "reviewed OK" list + undo downvotes.
-- Safe to re-run. Needs migrate_v14.sql first. Run on staging, then production, BEFORE deploying the Worker.
-- Like every admin_* function: security definer, callable by service_role only (revoked from anon/authenticated).

create table if not exists admin_reviewed(k text primary key, at timestamptz not null default now(), note text);
alter table admin_reviewed enable row level security;   -- no policies: only service_role
revoke all on admin_reviewed from public, anon, authenticated;

-- ---- 1) latest sightings with filters. Returns {rows,total,more}. p_status: hidden | rejected | confirmed | paused | banned | flagged ----
drop function if exists admin_recent(int,text);
drop function if exists admin_recent(int,text,text,text,text,int,bigint,text);
create or replace function admin_recent(p_limit int default 80, p_line text default null, p_dir text default null, p_status text default null,
    p_dev text default null, p_hours int default null, p_before bigint default null, p_station text default null)
returns json language sql stable security definer set search_path=public as $$
  with f as (
    select s.id, s.seen_at, st.line_id line, coalesce(st.fr,st.en,st.ar) station, s.dir, s.dev, s.ip, s.up, s.down,
           (s.down-s.up>=2) hidden, exists(select 1 from banned b where b.k in (s.dev,s.ip)) banned, is_blocked(s.dev) paused
    from sightings s join stations st on st.id=s.station_id
    where (p_line is null or st.line_id=p_line)
      and (p_dir is null or s.dir=p_dir)
      and (p_hours is null or s.seen_at>now()-make_interval(hours=>least(greatest(p_hours,1),24*90)))
      and (p_dev is null or left(s.dev,length(p_dev))=p_dev or left(s.ip,length(p_dev))=p_dev)
      and (p_station is null or position(lower(p_station) in lower(coalesce(st.fr,'')||' '||coalesce(st.en,'')||' '||coalesce(st.ar,'')))>0)
  ), g as (
    select * from f where
      case coalesce(p_status,'')
        when 'hidden' then hidden when 'rejected' then down>0 when 'confirmed' then up>0
        when 'paused' then paused when 'banned' then banned when 'flagged' then (hidden or paused or banned)
        else true end
  ), pg as (select * from g where p_before is null or id<p_before order by id desc limit least(greatest(coalesce(p_limit,80),1),200))
  select json_build_object(
    'rows', (select coalesce(json_agg(pg order by pg.id desc),'[]'::json) from pg),
    'total', (select count(*) from g),
    'more', (select count(*) from g where p_before is null or id<p_before) > (select count(*) from pg)) $$;

-- ---- 2) suspects: ONE ranked list, each device with score + reasons. p_days = look-back window (1..30) ----
drop function if exists admin_suspects();
drop function if exists admin_suspects(int);
create or replace function admin_suspects(p_days int default 7) returns json language sql stable security definer set search_path=public as $$
  with win as (
    select s.id, s.dev, s.ip, s.seen_at, s.station_id, s.dir, s.up, s.down, st.line_id
    from sightings s join stations st on st.id=s.station_id
    where s.seen_at>now()-make_interval(days=>least(greatest(coalesce(p_days,7),1),30))),
  base as (
    select dev, count(*) total, count(*) filter (where down-up>=2) hidden, coalesce(sum(up),0) ups, coalesce(sum(down),0) downs,
           count(distinct line_id) lines, count(distinct station_id) stations, min(seen_at) first_at, max(seen_at) last_at,
           count(*) filter (where seen_at>now()-interval '24 hours') r24
    from win group by dev),
  spot as (select dev, max(c) same_spot from (select dev, count(*) c from win group by dev, station_id, dir) z group by dev),
  hop as (select dev, max(lc) hop_lines from (select dev, count(distinct line_id) lc from win group by dev, date_trunc('hour',seen_at)) z group by dev),
  vt as (select dev, count(*) filter (where v=-1) vdown, count(*) filter (where v=1) vup, max(at) vlast from votes
         where at>now()-make_interval(days=>least(greatest(coalesce(p_days,7),1),30)) group by dev),
  ipc as (select ip, count(distinct dev) n from sightings where seen_at>now()-interval '24 hours' group by ip),
  net as (select w.dev, max(ipc.n) net_devs from (select distinct dev, ip from win) w join ipc using(ip) group by w.dev),
  devs as (select dev from win union select dev from vt),   -- vote-only devices (downvote bombers) have no sightings
  j as (
    select d.dev, coalesce(b.total,0) total, coalesce(b.hidden,0) hidden, coalesce(b.ups,0) ups, coalesce(b.downs,0) downs,
           coalesce(b.lines,0) lines, coalesce(b.stations,0) stations, b.first_at, coalesce(b.last_at,v.vlast) last_at, coalesce(b.r24,0) r24,
           coalesce(sp.same_spot,0) same_spot, coalesce(h.hop_lines,0) hop_lines, coalesce(v.vdown,0) vdown, coalesce(v.vup,0) vup,
           coalesce(n.net_devs,1) net_devs, r.at rev_at,
           (select count(*) from win x where x.dev=d.dev and x.down-x.up>=2 and (r.at is null or x.seen_at>r.at)) hidden_since
    from devs d left join base b using(dev) left join spot sp using(dev) left join hop h using(dev)
      left join vt v using(dev) left join net n using(dev) left join admin_reviewed r on r.k=d.dev),
  sc as (
    select j.*,
      array_remove(array[
        case when hidden>=1 then 'rejected' end,
        case when hidden=0 and downs>=3 and downs>ups*2 then 'downvoted' end,
        case when r24>=15 then 'busy' end,
        case when hop_lines>=3 then 'hopper' end,
        case when same_spot>=5 and ups=0 then 'repeat' end,
        case when vdown>=8 and vdown>=3*greatest(vup,1) then 'downvoter' end],null) reasons,
      least(hidden*5,25) + case when hidden=0 and downs>=3 and downs>ups*2 then 3 else 0 end
        + case when r24>=15 then 2+(r24-15)/5 else 0 end + case when hop_lines>=3 then 6 else 0 end
        + case when same_spot>=5 and ups=0 then 4 else 0 end
        + case when vdown>=8 and vdown>=3*greatest(vup,1) then 4 else 0 end score
    from j)
  select json_build_object(
    'days', least(greatest(coalesce(p_days,7),1),30),
    'devices', (select coalesce(json_agg(x order by x.score desc, x.last_at desc),'[]'::json) from (
        select dev, score, reasons, total, hidden, ups, downs, lines, stations, r24, first_at, last_at, same_spot, hop_lines, vdown, vup, net_devs,
               is_blocked(dev) paused, exists(select 1 from banned b where b.k=dev) banned,
               (rev_at is not null and hidden_since=0) reviewed, rev_at
        from sc where score>0 order by score desc, last_at desc limit 80) x),
    'shared_ips', (select coalesce(json_agg(x),'[]'::json) from (
        select ip, count(distinct dev) devices, count(*) reports, exists(select 1 from banned b where b.k=ip) banned
        from sightings where seen_at>now()-interval '24 hours' group by ip having count(distinct dev)>=5 order by devices desc limit 20) x)) $$;

-- ---- 3) profile of one device (or one network hash) ----
create or replace function admin_device(p_k text) returns json language plpgsql stable security definer set search_path=public as $$
declare r json;
begin
  if p_k is null or p_k !~ '^[A-Za-z0-9_-]{16,64}$' then return null; end if;
  if exists(select 1 from sightings where dev=p_k) or exists(select 1 from incidents where dev=p_k) or exists(select 1 from votes where dev=p_k) then
    select json_build_object('kind','device','k',p_k,
      'banned', exists(select 1 from banned where k=p_k), 'paused', is_blocked(p_k),
      'reviewed_at', (select at from admin_reviewed where k=p_k),
      'first_seen', (select min(seen_at) from sightings where dev=p_k),
      'total30', (select count(*) from sightings where dev=p_k and seen_at>now()-interval '30 days'),
      'hidden30', (select count(*) from sightings where dev=p_k and seen_at>now()-interval '30 days' and down-up>=2),
      'ups', (select coalesce(sum(up),0) from sightings where dev=p_k and seen_at>now()-interval '30 days'),
      'downs', (select coalesce(sum(down),0) from sightings where dev=p_k and seen_at>now()-interval '30 days'),
      'vote_up', (select count(*) from votes where dev=p_k and v=1 and at>now()-interval '30 days'),
      'vote_down', (select count(*) from votes where dev=p_k and v=-1 and at>now()-interval '30 days'),
      'networks', (select count(distinct ip) from sightings where dev=p_k and seen_at>now()-interval '7 days'),
      'lines', (select coalesce(json_agg(z),'[]'::json) from (select st.line_id line, count(*) n from sightings s join stations st on st.id=s.station_id
                where s.dev=p_k and s.seen_at>now()-interval '30 days' group by st.line_id order by n desc) z),
      'stations', (select coalesce(json_agg(z),'[]'::json) from (select st.line_id line, coalesce(st.fr,st.en,st.ar) name, count(*) n from sightings s join stations st on st.id=s.station_id
                where s.dev=p_k and s.seen_at>now()-interval '30 days' group by 1,2 order by n desc limit 5) z),
      'recent', (select coalesce(json_agg(z order by z.id desc),'[]'::json) from (select s.id, s.seen_at, st.line_id line, coalesce(st.fr,st.en,st.ar) station, s.dir, s.up, s.down, (s.down-s.up>=2) hidden
                from sightings s join stations st on st.id=s.station_id where s.dev=p_k order by s.id desc limit 40) z),
      'log', (select coalesce(json_agg(z order by z.at desc),'[]'::json) from (select at, act, note from admin_log where target=p_k order by at desc limit 10) z)) into r;
  elsif exists(select 1 from sightings where ip=p_k) then
    select json_build_object('kind','network','k',p_k, 'banned', exists(select 1 from banned where k=p_k),
      'devices', (select coalesce(json_agg(z order by z.reports desc),'[]'::json) from (select dev, count(*) reports, count(*) filter (where down-up>=2) hidden, max(seen_at) last_at,
                exists(select 1 from banned b where b.k=dev) banned from sightings where ip=p_k and seen_at>now()-interval '7 days' group by dev limit 50) z)) into r;
  else
    select json_build_object('kind','unknown','k',p_k,'banned', exists(select 1 from banned where k=p_k),
      'log', (select coalesce(json_agg(z order by z.at desc),'[]'::json) from (select at, act, note from admin_log where target=p_k order by at desc limit 10) z)) into r;
  end if;
  return r;
end $$;

-- ---- 4) actions: v14 + ok / unok (reviewed list) + undo_votes (remove this device's downvotes of the last 7 days and fix the counters) ----
create or replace function admin_act(p_act text, p_id bigint, p_k text, p_note text, p_ip text) returns text language plpgsql security definer set search_path=public as $$
declare n int := 0;
begin
  if p_act='del_sighting' then
    delete from sightings where id=p_id; get diagnostics n = row_count;
    if n=0 then return 'nf'; end if;
    insert into admin_log(act,target,note,ip) values(p_act,p_id::text,left(p_note,200),p_ip);
  elsif p_act='del_incident' then
    delete from incidents where id=p_id; get diagnostics n = row_count;
    if n=0 then return 'nf'; end if;
    insert into admin_log(act,target,note,ip) values(p_act,p_id::text,left(p_note,200),p_ip);
  elsif p_act in ('ban','unban','purge_dev','ok','unok','undo_votes') then
    if p_k is null or p_k !~ '^[A-Za-z0-9_-]{16,64}$' then return 'bad'; end if;
    if p_act='ban' then insert into banned(k) values(p_k) on conflict do nothing;
    elsif p_act='unban' then delete from banned where k=p_k; get diagnostics n = row_count; if n=0 then return 'nf'; end if;
    elsif p_act='ok' then insert into admin_reviewed(k,note) values(p_k,left(p_note,200)) on conflict(k) do update set at=now(), note=excluded.note;
    elsif p_act='unok' then delete from admin_reviewed where k=p_k; get diagnostics n = row_count; if n=0 then return 'nf'; end if;
    elsif p_act='undo_votes' then
      with d as (delete from votes where dev=p_k and v=-1 and at>now()-interval '7 days' returning sighting_id),
           c as (select sighting_id, count(*) k from d group by sighting_id)
      update sightings s set down=greatest(s.down-c.k,0) from c where s.id=c.sighting_id;
    else
      delete from sightings where dev=p_k and seen_at>now()-interval '7 days';
      delete from incidents where dev=p_k and seen_at>now()-interval '7 days';
    end if;
    insert into admin_log(act,target,note,ip) values(p_act,p_k,left(p_note,200),p_ip);
  else return 'bad'; end if;
  return 'ok';
end $$;

revoke all on function admin_recent(int,text,text,text,text,int,bigint,text), admin_suspects(int), admin_device(text), admin_act(text,bigint,text,text,text) from public, anon, authenticated;
grant execute on function admin_recent(int,text,text,text,text,int,bigint,text), admin_suspects(int), admin_device(text), admin_act(text,bigint,text,text,text) to service_role;
