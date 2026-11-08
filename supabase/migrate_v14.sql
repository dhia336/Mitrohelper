-- v14 (v0.35): admin page backend. Safe to re-run. Run on staging first, then production, BEFORE deploying the Worker.
-- Everything here is callable ONLY by the Worker (service_role). anon/authenticated are revoked explicitly (PROGRESS bug 1).

create table if not exists admin_log(id bigserial primary key, at timestamptz not null default now(), act text not null, target text, note text, ip text);
create table if not exists admin_fails(id bigserial primary key, at timestamptz not null default now(), ip text not null);
create index if not exists admin_fails_ip_at on admin_fails(ip, at);
create table if not exists admin_otp_used(step bigint primary key, at timestamptz not null default now());
alter table admin_log enable row level security;       -- no policies: nobody but service_role can read/write
alter table admin_fails enable row level security;
alter table admin_otp_used enable row level security;
revoke all on admin_log, admin_fails, admin_otp_used from public, anon, authenticated;
revoke all on sequence admin_log_id_seq, admin_fails_id_seq from public, anon, authenticated;

-- ---- login throttling + one-time-code replay protection ----
create or replace function admin_login_fails(p_ip text) returns int language sql stable security definer set search_path=public as $$
  select count(*)::int from admin_fails where ip=p_ip and at>now()-interval '15 minutes' $$;

drop function if exists admin_login_fail(text);
create or replace function admin_login_fail(p_ip text) returns text language plpgsql security definer set search_path=public as $$
begin
  insert into admin_fails(ip) values(p_ip);
  delete from admin_fails where at<now()-interval '2 days';
  return 'ok';
end $$;

-- true = this 30-second code step was not used before (now recorded); false = replay
create or replace function admin_otp_use(p_step bigint) returns boolean language plpgsql security definer set search_path=public as $$
declare n int;
begin
  insert into admin_otp_used(step) values(p_step) on conflict do nothing;
  get diagnostics n = row_count;
  delete from admin_otp_used where at<now()-interval '1 day';
  return n=1;
end $$;

-- ---- statistics (one call, read-only) ----
create or replace function admin_stats() returns json language sql stable security definer set search_path=public as $$
with tz as (select 'Africa/Tunis'::text z),
days as (select d::date d from generate_series((now() at time zone 'Africa/Tunis')::date-13,(now() at time zone 'Africa/Tunis')::date,'1 day') d),
rep as (select (seen_at at time zone 'Africa/Tunis')::date d, count(*) n, count(distinct dev) dv from sightings
        where seen_at>now()-interval '15 days' group by 1),
vis as (select day d, count(*) n from visits where day>=current_date-14 group by 1)
select json_build_object(
  'now', now(),
  'live45',   (select count(*) from sightings where seen_at>now()-interval '45 minutes'),
  'rep24',    (select count(*) from sightings where seen_at>now()-interval '24 hours'),
  'rep7',     (select count(*) from sightings where seen_at>now()-interval '7 days'),
  'rep30',    (select count(*) from sightings where seen_at>now()-interval '30 days'),
  'repAll',   (select count(*) from sightings),
  'dev24',    (select count(distinct dev) from sightings where seen_at>now()-interval '24 hours'),
  'dev7',     (select count(distinct dev) from sightings where seen_at>now()-interval '7 days'),
  'conf24',   (select coalesce(sum(up),0) from sightings where seen_at>now()-interval '24 hours'),
  'rej24',    (select coalesce(sum(down),0) from sightings where seen_at>now()-interval '24 hours'),
  'hidden7',  (select count(*) from sightings where seen_at>now()-interval '7 days' and down-up>=2),
  'blocked',  (select count(*) from (select distinct dev from sightings where seen_at>now()-interval '7 days') x where is_blocked(dev)),
  'banned',   (select count(*) from banned),
  'inc_live', (select count(*) from live_incidents),
  'inc7',     (select count(*) from incidents where seen_at>now()-interval '7 days'),
  'vis_today',(select count(*) from visits where day=current_date),
  'vis7',     (select count(distinct dev) from visits where day>=current_date-6),
  'new_today',(select count(*) from (select dev from visits group by dev having min(day)=current_date) x),
  'app_today',(select count(*) from visits where day=current_date and standalone),
  'daily', (select coalesce(json_agg(json_build_object('d',days.d,'rep',coalesce(rep.n,0),'dev',coalesce(rep.dv,0),'vis',coalesce(vis.n,0)) order by days.d),'[]'::json)
            from days left join rep on rep.d=days.d left join vis on vis.d=days.d),
  'hourly', (select coalesce(json_agg(json_build_object('h',h,'n',coalesce(c.n,0)) order by h),'[]'::json)
             from generate_series(0,23) h left join (select extract(hour from seen_at at time zone 'Africa/Tunis')::int hh, count(*) n
               from sightings where seen_at>now()-interval '14 days' group by 1) c on c.hh=h),
  'lines', (select coalesce(json_agg(json_build_object('line',l.id,'color',l.color,
              'r24',(select count(*) from sightings s join stations st on st.id=s.station_id where st.line_id=l.id and s.seen_at>now()-interval '24 hours'),
              'r7',(select count(*) from sightings s join stations st on st.id=s.station_id where st.line_id=l.id and s.seen_at>now()-interval '7 days'),
              'last',(select max(s.seen_at) from sightings s join stations st on st.id=s.station_id where st.line_id=l.id)) order by l.sort),'[]'::json) from lines l),
  'stations', (select coalesce(json_agg(x),'[]'::json) from (select st.line_id line, coalesce(st.fr,st.en,st.ar) name, count(*) n
               from sightings s join stations st on st.id=s.station_id where s.seen_at>now()-interval '7 days'
               group by 1,2 order by n desc limit 10) x),
  'src', (select coalesce(json_agg(x),'[]'::json) from (
            with f as (select distinct on (dev) dev, src, day from visits order by dev, day)
            select coalesce(nullif(src,''),'(none)') src, count(*) devices,
                   count(*) filter (where exists(select 1 from visits v where v.dev=f.dev and v.day>f.day)) came_back
            from f where day>=current_date-30 group by 1 order by devices desc limit 10) x)
) $$;

-- ---- moderation lists ----
create or replace function admin_recent(p_limit int default 60, p_line text default null) returns json language sql stable security definer set search_path=public as $$
  select coalesce(json_agg(x order by x.seen_at desc),'[]'::json) from (
    select s.id, s.seen_at, st.line_id line, coalesce(st.fr,st.en,st.ar) station, s.dir, s.dev, s.ip, s.up, s.down,
           (s.down-s.up>=2) hidden, exists(select 1 from banned b where b.k in (s.dev,s.ip)) banned, is_blocked(s.dev) paused
    from sightings s join stations st on st.id=s.station_id
    where p_line is null or st.line_id=p_line
    order by s.seen_at desc limit least(greatest(coalesce(p_limit,60),1),200)) x $$;

create or replace function admin_incidents() returns json language sql stable security definer set search_path=public as $$
  select coalesce(json_agg(x order by x.seen_at desc),'[]'::json) from (
    select i.id, i.seen_at, st.line_id line, coalesce(st.fr,st.en,st.ar) station, i.dev, i.ip, i.up, i.down,
           exists(select 1 from live_incidents li where li.id=i.id) live,
           exists(select 1 from banned b where b.k in (i.dev,i.ip)) banned
    from incidents i join stations st on st.id=i.station_id
    where i.seen_at>now()-interval '48 hours' order by i.seen_at desc limit 40) x $$;

create or replace function admin_suspects() returns json language sql stable security definer set search_path=public as $$
  select json_build_object(
    'rejected', (select coalesce(json_agg(x),'[]'::json) from (
        select dev, count(*) filter (where down-up>=2) as hidden, count(*) as total, max(seen_at) as last_seen, is_blocked(dev) as paused,
               exists(select 1 from banned b where b.k=dev) banned
        from sightings where seen_at>now()-interval '7 days' group by dev
        having count(*) filter (where down-up>=2)>0 order by hidden desc, total desc limit 30) x),
    'busy', (select coalesce(json_agg(x),'[]'::json) from (
        select dev, count(*) reports, min(seen_at) as first_at, max(seen_at) as last_at, exists(select 1 from banned b where b.k=dev) banned
        from sightings where seen_at>now()-interval '24 hours' group by dev having count(*)>=15 order by reports desc limit 20) x),
    'hoppers', (select coalesce(json_agg(x),'[]'::json) from (
        select s.dev, date_trunc('hour',s.seen_at) as hr, count(distinct st.line_id) as line_count, count(*) as reports
        from sightings s join stations st on st.id=s.station_id where s.seen_at>now()-interval '24 hours'
        group by s.dev, date_trunc('hour',s.seen_at) having count(distinct st.line_id)>=3 order by line_count desc, reports desc limit 20) x),
    'shared_ips', (select coalesce(json_agg(x),'[]'::json) from (
        select ip, count(distinct dev) devices, count(*) reports, exists(select 1 from banned b where b.k=ip) banned
        from sightings where seen_at>now()-interval '24 hours' group by ip having count(distinct dev)>=5 order by devices desc limit 20) x)
  ) $$;

create or replace function admin_banned() returns json language sql stable security definer set search_path=public as $$
  select coalesce(json_agg(x order by x.last_seen desc nulls last),'[]'::json) from (
    select b.k, (select max(seen_at) from sightings s where s.dev=b.k or s.ip=b.k) last_seen,
           (select count(*) from sightings s where (s.dev=b.k or s.ip=b.k) and s.seen_at>now()-interval '30 days') reports30
    from banned b limit 200) x $$;

create or replace function admin_log_list(p_limit int default 50) returns json language sql stable security definer set search_path=public as $$
  select coalesce(json_agg(x order by x.at desc),'[]'::json) from (
    select at, act, target, note from admin_log order by at desc limit least(greatest(coalesce(p_limit,50),1),200)) x $$;

-- ---- moderation actions (each one is written to admin_log) ----
-- p_act: del_sighting(p_id) | del_incident(p_id) | ban(p_k) | unban(p_k) | purge_dev(p_k = device id: deletes its sightings + incidents of the last 7 days)
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
  elsif p_act in ('ban','unban','purge_dev') then
    if p_k is null or p_k !~ '^[A-Za-z0-9_-]{16,64}$' then return 'bad'; end if;
    if p_act='ban' then insert into banned(k) values(p_k) on conflict do nothing;
    elsif p_act='unban' then delete from banned where k=p_k; get diagnostics n = row_count; if n=0 then return 'nf'; end if;
    else
      delete from sightings where dev=p_k and seen_at>now()-interval '7 days';
      delete from incidents where dev=p_k and seen_at>now()-interval '7 days';
    end if;
    insert into admin_log(act,target,note,ip) values(p_act,p_k,left(p_note,200),p_ip);
  else return 'bad'; end if;
  return 'ok';
end $$;

-- lock everything to the Worker
revoke all on function admin_login_fails(text), admin_login_fail(text), admin_otp_use(bigint), admin_stats(), admin_recent(int,text),
  admin_incidents(), admin_suspects(), admin_banned(), admin_log_list(int), admin_act(text,bigint,text,text,text) from public, anon, authenticated;
grant execute on function admin_login_fails(text), admin_login_fail(text), admin_otp_use(bigint), admin_stats(), admin_recent(int,text),
  admin_incidents(), admin_suspects(), admin_banned(), admin_log_list(int), admin_act(text,bigint,text,text,text) to service_role;
