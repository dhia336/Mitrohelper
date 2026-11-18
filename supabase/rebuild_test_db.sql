-- MitroHelper v0.53: FULL REBUILD of a TEST database. Run once in Supabase > SQL Editor on an EMPTY project.
-- = schema.sql (up to v17) + migrate_v18..v28 + test_seed.sql. NEVER run on production (test_seed empties sightings/incidents).

-- ===== schema.sql =====
-- Run once in Supabase > SQL Editor. Safe to extend later (add rows, not code).
create table lines(id text primary key, color text not null, sort int);
create table stations(id serial primary key, line_id text references lines on delete cascade, pos int not null, ar text, fr text, en text);
create table sightings(id bigserial primary key, station_id int references stations on delete cascade, dir char(1) check (dir in ('a','b')),
  seen_at timestamptz default now(), dev text, ip text, up int default 0, down int default 0);
create index on sightings(seen_at desc);
create table votes(sighting_id bigint references sightings on delete cascade, dev text, v int, primary key(sighting_id,dev));
alter table lines enable row level security; alter table stations enable row level security;
alter table sightings enable row level security; alter table votes enable row level security;
create policy rd on lines for select using (true);
create policy rd on stations for select using (true);
-- sightings/votes: NO policies => anon cannot read or write them directly. Only the functions below.
create view live as select s.id, st.line_id, s.station_id, s.dir, s.seen_at, s.up, s.down
  from sightings s join stations st on st.id=s.station_id
  where s.seen_at > now()-interval '45 minutes' and s.down - s.up < 2;
grant select on lines, stations, live to anon;

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

-- Data. pos = order along the line (gaps of 10 so you can insert stations between). First pos = direction "b" end, last = "a" end.
insert into lines values ('1','#ff4d5e',1),('2','#ffa31a',2),('3','#1fd1b0',3),('4','#3b82f6',4),('5','#a855f7',5),('6','#ec4899',6),('TGM','#84cc16',7);
insert into stations(line_id,pos,ar,fr,en) values
('1',10,'تونس البحرية','Tunis Marine','Tunis Marine'),
('1',20,'فرحات حشاد','Farhat Hached','Farhat Hached'),
('1',30,'ساحة برشلونة','Place de Barcelone','Place de Barcelone'),
('1',40,'باب عليوة','Bab Alioua','Bab Alioua'),
('1',50,'محمد مناشو','Mohamed Manachou','Mohamed Manachou'),
('1',60,'13 أوت','13 Aout','13 Aout'),
('1',70,'محمد علي','Mohamed Ali','Mohamed Ali'),
('1',80,'الكبارية','El Kabaria','El Kabaria'),
('1',90,'ابن سينا','Ibn Sina','Ibn Sina'),
('1',100,'الوردية 6','El Ouardia 6','El Ouardia 6'),
('1',110,'حي النور','Cité Ennour','Cité Ennour'),
('1',120,'أبو القاسم الشابي','Abou Kacem Echebbi','Abou Kacem Echebbi'),
('1',130,'بن عروس','Ben Arous','Ben Arous'),
('2',10,'ساحة الجمهورية','Place de la République','Place de la République'),
('2',20,'نيلسون مانديلا','Nelson Mandela','Nelson Mandela'),
('2',30,'محمد الخامس','Mohamed V','Mohamed V'),
('2',40,'ساحة فلسطين','Place de Palestine','Place de Palestine'),
('2',50,'الحدائق','Les Jardins','Les Jardins'),
('2',60,'حي الخضراء','Cité El Khadhra','Cité El Khadhra'),
('2',70,'الشباب','La Jeunesse','La Jeunesse'),
('2',80,'المدينة الرياضية','Cité Sportive','Cité Sportive'),
('2',90,'10 ديسمبر 1948','10 Décembre 1948','10 Décembre 1948'),
('2',100,'مدينة العلوم','Cité des Sciences','Cité des Sciences'),
('2',110,'الاستقلال','L''Independance','L''Independance'),
('2',120,'أريانة','Ariana','Ariana'),
('3',10,'تونس البحرية','Tunis Marine','Tunis Marine'),
('3',20,'فرحات حشاد','Farhat Hached','Farhat Hached'),
('3',30,'ساحة برشلونة','Place de Barcelone','Place de Barcelone'),
('3',40,'ساحة الجمهورية','Place de la République','Place de la République'),
('3',50,'باب الخضراء','Bab El Khadhra','Bab El Khadhra'),
('3',60,'باب العسل','Bab Laassal','Bab Laassal'),
('3',70,'باب سعدون','Bab Saadoun','Bab Saadoun'),
('3',80,'الحرم الجامعي المنار','Campus Manar','Campus Manar'),
('3',90,'14 جانفي 2011','14 Jan 2011','14 Jan 2011'),
('3',100,'الياسمين','Les Jasmins','Les Jasmins'),
('3',110,'ابن خلدون','Ibn Khaldoun','Ibn Khaldoun'),
('4',10,'ساحة برشلونة','Place de Barcelone','Place de Barcelone'),
('4',20,'ساحة الجمهورية','Place de la République','Place de la République'),
('4',30,'باب الخضراء','Bab El Khadhra','Bab El Khadhra'),
('4',40,'باب العسل','Bab Laassal','Bab Laassal'),
('4',50,'باب سعدون','Bab Saadoun','Bab Saadoun'),
('4',60,'بوشوشة','Bouchoucha','Bouchoucha'),
('4',70,'20 مارس','20 Mars','20 Mars'),
('4',80,'باردو','Bardo','Bardo'),
('4',90,'السعيدية','Essaidia','Essaidia'),
('4',100,'خزندار','Khaznadar','Khaznadar'),
('4',110,'الصناعات التقليدية','L''Artisanat','L''Artisanat'),
('4',120,'الدندان','Denden','Denden'),
('4',130,'منوبة','Manouba','Manouba'),
('4',140,'سليمان كاهية','Slimane Kahia','Slimane Kahia'),
('4',150,'منصف باي','Moncef Bey','Moncef Bey'),
('4',160,'أبو بكر الرازي','Aboubaker El Razi','Aboubaker El Razi'),
('4',170,'القطب التكنولوجي','Le Pole Tech','Le Pole Tech'),
('4',180,'قصر الوردة','Ksar El Warda','Ksar El Warda'),
('4',190,'الحرم الجامعي','Le Campus','Le Campus'),
('4',200,'خير الدين','Kheireddine','Kheireddine'),
('5',10,'ساحة برشلونة','Place de Barcelone','Place de Barcelone'),
('5',20,'ساحة الجمهورية','Place de la République','Place de la République'),
('5',30,'باب الخضراء','Bab El Khadhra','Bab El Khadhra'),
('5',40,'باب العسل','Bab Laassal','Bab Laassal'),
('5',50,'باب سعدون','Bab Saadoun','Bab Saadoun'),
('5',60,'مفتاح سعد الله','Mefteh Saadallah','Mefteh Saadallah'),
('5',70,'الرمانة','Rommana','Rommana'),
('5',80,'الحرم الجامعي المنار','Campus Manar','Campus Manar'),
('5',90,'14 جانفي 2011','14 Jan 2011','14 Jan 2011'),
('5',100,'الياسمين','Les Jasmins','Les Jasmins'),
('5',110,'التحرير','Ettahrir','Ettahrir'),
('5',120,'العمران الأعلى','Omrane Sup','Omrane Sup'),
('5',130,'التضامن','Ettadhamen','Ettadhamen'),
('5',140,'الانطلاقة','Intikala','Intikala'),
('6',10,'تونس البحرية','Tunis Marine','Tunis Marine'),
('6',20,'فرحات حشاد','Farhat Hached','Farhat Hached'),
('6',30,'ساحة برشلونة','Place de Barcelone','Place de Barcelone'),
('6',40,'باب عليوة','Bab Alioua','Bab Alioua'),
('6',50,'محمد مناشو','Mohamed Manachou','Mohamed Manachou'),
('6',60,'13 أوت','13 Aout','13 Aout'),
('6',70,'محمد علي','Mohamed Ali','Mohamed Ali'),
('6',80,'الطاهر الحداد','Taher Haddad','Taher Haddad'),
('6',90,'الغزالي','Ghazeli','Ghazeli'),
('6',100,'الحي البلدي','Cité Municipale','Cité Municipale'),
('6',110,'النسري','Ennesri','Ennesri'),
('6',120,'المنتزه','El Montazah','El Montazah'),
('6',130,'المروج 2','El Mourouj 2','El Mourouj 2'),
('6',140,'المروج 1','El Mourouj 1','El Mourouj 1'),
('6',150,'البيئة','L''Environnement','L''Environnement'),
('6',160,'المروج 3','El Mourouj 3','El Mourouj 3'),
('6',170,'الشهداء','Les Martyrs','Les Martyrs'),
('6',180,'المروج 4','El Mourouj 4','El Mourouj 4'),
('TGM',10,'تونس البحرية','Tunis Marine','Tunis Marine'),
('TGM',20,'الباك','Le Bac','Le Bac'),
('TGM',30,'حلق الوادي','La Goulette','La Goulette'),
('TGM',40,'حلق الوادي الجديدة','La Goulette Neuve','La Goulette Neuve'),
('TGM',50,'حلق الوادي الكازينو','La Goulette Casino','La Goulette Casino'),
('TGM',60,'خير الدين','Kheireddine','Kheireddine'),
('TGM',70,'المطار','L''Aeroport','L''Aeroport'),
('TGM',80,'الكرم','Le Kram','Le Kram'),
('TGM',85,'قرطاج سلامبو','Carthage Salammbô','Carthage Salammbô'),
('TGM',90,'قرطاج بيرصة','Carthage Byrsa','Carthage Byrsa'),
('TGM',100,'قرطاج درمش','Carthage Dermech','Carthage Dermech'),
('TGM',110,'قرطاج حنبعل','Carthage Hannibal','Carthage Hannibal'),
('TGM',120,'قرطاج الرئاسة','Carthage Presidence','Carthage Presidence'),
('TGM',130,'قرطاج أميلكار','Carthage Amilcar','Carthage Amilcar'),
('TGM',140,'سيدي بوسعيد','Sidi Bou Said','Sidi Bou Said'),
('TGM',150,'سيدي الظريف','Sidi Dhrif','Sidi Dhrif'),
('TGM',160,'الكورنيش','La Corniche','La Corniche'),
('TGM',170,'المرسى الشاطئ','Marsa Plage','Marsa Plage');

-- Optional cleanup (enable pg_cron in Database > Extensions first):
-- select cron.schedule('purge','0 3 * * *',$$delete from sightings where seen_at<now()-interval '60 days'$$);

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

-- ===== v10 (v0.21): fresh window 45 min (supersedes the 90-minute `live` view and live_all above) =====
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
-- v11: anonymous retention measurement + 'riders confirmed your reports' feedback. Safe to re-run. Run BEFORE deploying Worker/web v0.28.
-- visits = one row per device per day the app was opened (random device id + day + source tag + installed flag). No IP, no account.
create table if not exists visits(dev text not null, day date not null default current_date, src text not null default '', standalone boolean not null default false, primary key(dev,day));
create index if not exists visits_day on visits(day);
alter table visits enable row level security; -- no policies: anon cannot read or write

create or replace function hit(p_dev text, p_src text, p_sa boolean) returns text language plpgsql security definer set search_path=public as $$
begin
  if p_dev is null or length(p_dev)<16 then return 'bad'; end if;
  insert into visits(dev,day,src,standalone) values(p_dev,current_date,left(coalesce(p_src,''),20),coalesce(p_sa,false)) on conflict (dev,day) do nothing;
  return 'ok';
end $$;

-- reports the device made in the last 30 days (not hidden by votes) and the confirmations ('up') they received
create or replace function my_stats(p_dev text) returns json language sql security definer set search_path=public as $$
  select json_build_object('reports',count(*),'confirms',coalesce(sum(up),0)) from sightings where dev=p_dev and seen_at>now()-interval '30 days' and down-up<2 $$;

revoke all on function hit(text,text,boolean), my_stats(text) from public, anon, authenticated;
grant execute on function hit(text,text,boolean), my_stats(text) to service_role;
-- v12: weekly contributor leaderboard with generated nicknames. Safe to re-run. Needs v7 (is_blocked), and `banned`. Run BEFORE deploying web/Worker v0.29.
-- Everything is computed from `sightings`/`incidents` (permanent server data, 90 days), nothing is stored per user, so a page refresh never loses it.
-- Score = valid reports (not hidden by votes) + confirmations received (max 3 per report). Anti-farming: max 1 report per station per 15 min and 8 reports per device per day count,
-- hidden/banned/auto-paused devices are excluded, minimum 3 reports to be listed. Weeks run Monday-Sunday, Tunis time.

-- deterministic nickname indexes from the device id: [adjective 0-11, noun 0-11, number 10-99]. The words live in app.js (3 languages): users type nothing.
create or replace function nick(p_dev text) returns int[] language sql immutable as $$
  select array[(h%12)::int, ((h/12)%12)::int, (10+(h/144)%90)::int] from (select ('x'||substr(md5(p_dev),1,7))::bit(28)::bigint as h) t $$;

create or replace function lb_range(p_period text, out f timestamptz, out t timestamptz) language sql stable as $$
  select case p_period when 'last' then w-interval '7 days' when 'month' then now()-interval '30 days' else w end,
         case p_period when 'last' then w when 'month' then now()+interval '1 minute' else w+interval '7 days' end
  from (select (date_trunc('week', now() at time zone 'Africa/Tunis')) at time zone 'Africa/Tunis' as w) x $$;

create or replace function lb_scores(p_from timestamptz, p_to timestamptz)
returns table(dev text, points int, reports int, confirms int, days int, line_id text, station_id int)
language sql stable security definer set search_path=public as $$
  with ev as (
    select s.dev, s.station_id, s.seen_at ts, s.up from sightings s where s.seen_at>=p_from and s.seen_at<p_to and s.down-s.up<2 and s.dev is not null
    union all
    select i.dev, i.station_id, i.seen_at, i.up from incidents i where i.seen_at>=p_from and i.seen_at<p_to and i.down-i.up<2 and i.dev is not null),
  dd as (select e.*, row_number() over (partition by e.dev, e.station_id, floor(extract(epoch from e.ts)/900) order by e.ts) k from ev e),
  cap as (select e.*, (e.ts at time zone 'Africa/Tunis')::date d, row_number() over (partition by e.dev, (e.ts at time zone 'Africa/Tunis')::date order by e.ts) rn from dd e where e.k=1),
  ok as (select c.* from cap c where c.rn<=8 and not exists(select 1 from banned b where b.k=c.dev)),
  agg as (select o.dev, count(*)::int reports, coalesce(sum(least(o.up,3)),0)::int confirms, count(distinct o.d)::int days from ok o group by o.dev),
  tl as (select x.dev, x.line_id from (select o.dev, st.line_id, row_number() over (partition by o.dev order by count(*) desc, st.line_id) r from ok o join stations st on st.id=o.station_id group by o.dev, st.line_id) x where x.r=1),
  tst as (select x.dev, x.station_id from (select o.dev, o.station_id, row_number() over (partition by o.dev order by count(*) desc, o.station_id) r from ok o group by o.dev, o.station_id) x where x.r=1)
  select a.dev, a.reports+a.confirms, a.reports, a.confirms, a.days, tl.line_id, tst.station_id
  from agg a join tl using(dev) join tst using(dev) where a.reports>=3 and not is_blocked(a.dev) $$;

-- public top 10 (no device ids leave the database)
create or replace function leaderboard(p_period text default 'week') returns json language sql stable security definer set search_path=public as $$
  with r as (select * from lb_range(p_period)),
  s as (select x.*, row_number() over (order by x.points desc, x.reports desc, x.dev) rk from lb_scores((select f from r),(select t from r)) x)
  select json_build_object('from',(select f from r),'to',(select t from r),'n',(select count(*) from s),
    'rows',(select coalesce(json_agg(json_build_object('r',rk,'n',nick(dev),'l',line_id,'s',station_id,'p',points,'rp',reports,'cf',confirms,'dy',days) order by rk),'[]'::json) from s where rk<=10)) $$;

-- replaces v11's my_stats: same reports/confirms (30 days) + this week's rank, points, nickname, number of ranked riders, own valid reports this week (wr)
create or replace function my_stats(p_dev text) returns json language sql stable security definer set search_path=public as $$
  with r as (select * from lb_range('week')),
  s as (select x.*, row_number() over (order by x.points desc, x.reports desc, x.dev) rk from lb_scores((select f from r),(select t from r)) x),
  m as (select * from s where s.dev=p_dev)
  select json_build_object(
    'reports',(select count(*) from sightings where dev=p_dev and seen_at>now()-interval '30 days' and down-up<2),
    'confirms',(select coalesce(sum(up),0) from sightings where dev=p_dev and seen_at>now()-interval '30 days' and down-up<2),
    'nk',nick(p_dev),'rank',(select rk from m),'points',(select points from m),'n',(select count(*) from s),
    'wr',(select count(*) from sightings where dev=p_dev and seen_at>=(select f from r) and down-up<2)) $$;

revoke all on function nick(text), lb_range(text), lb_scores(timestamptz,timestamptz), leaderboard(text), my_stats(text) from public, anon, authenticated;
grant execute on function leaderboard(text), my_stats(text) to service_role;
-- v13 (v0.34): typical headway per line/direction/time bucket, learned from past sightings.
-- Only data on/after a line's "regime" date is used, so a schedule change (e.g. line 4 after 2026-11-04) is not polluted by old data.
create table if not exists line_regimes(line_id text primary key, since date not null);
alter table line_regimes enable row level security;
insert into line_regimes values('4','2026-11-04') on conflict do nothing;   -- owner: update this date when a line's service changes

-- bucket: 'wd'/'we' (weekday/weekend) x period 1 (6-9) 2 (9-16) 3 (16-20) 4 (other), plus 'all'
create or replace function typical_gaps() returns json language sql stable security definer set search_path=public as $$
  with ev as (
    select st.line_id, s.station_id, s.dir, s.seen_at,
      (s.seen_at at time zone 'Africa/Tunis') lt
    from sightings s join stations st on st.id=s.station_id
    left join line_regimes r on r.line_id=st.line_id
    where s.seen_at>now()-interval '21 days' and s.down-s.up<2
      and (r.since is null or (s.seen_at at time zone 'Africa/Tunis')::date>=r.since)),
  g as (select line_id, dir, lt, extract(epoch from (seen_at-lag(seen_at) over (partition by station_id,dir order by seen_at)))/60 gap from ev),
  b as (select line_id, dir, gap, lt::date d,
      case when extract(isodow from lt)<=5 then 'wd' else 'we' end||
      case when extract(hour from lt)>=6 and extract(hour from lt)<9 then '1' when extract(hour from lt)>=9 and extract(hour from lt)<16 then '2'
           when extract(hour from lt)>=16 and extract(hour from lt)<20 then '3' else '4' end k
    from g where gap between 3 and 40),
  a as (select line_id, dir, k, gap, d from b union all select line_id, dir, 'all', gap, d from b),
  r as (select line_id l, dir, k, count(*)::int n, count(distinct d)::int days,
      round((percentile_cont(.25) within group (order by gap))::numeric,1) p25,
      round((percentile_cont(.5) within group (order by gap))::numeric,1) p50,
      round((percentile_cont(.75) within group (order by gap))::numeric,1) p75
    from a group by line_id, dir, k)
  select json_build_object('rows',coalesce((select json_agg(json_build_object('l',l,'d',dir,'k',k,'n',n,'dy',days,'a',p25,'m',p50,'b',p75)) from r where n>=8),'[]'::json)) $$;
revoke all on function typical_gaps() from public, anon, authenticated;
grant execute on function typical_gaps() to service_role;
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

-- ===== v15 (v0.36): admin filters, scored suspects, device profile, reviewed list, undo downvotes =====
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

-- ===== v16 (v0.37): interchange stations =====
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

-- ===== v17 (v0.38): same station, opposite direction =====
-- v17 (v0.38): v16 + the SAME station and line in the OPPOSITE direction. Safe to re-run. Replaces report() only (needs migrate_v16.sql for station_key()).
-- A second report inside the 2-minute window is accepted when every report of the device in that window is at a station with the same name and is NOT
-- (same line AND same direction). So allowed: other line (any direction); same line at the same station in the other direction.
-- Still refused: the same line + same direction again, the same line at a different station, any other station name.
-- Caps unchanged: at most 3 reports per 2 min and fewer than 5 per 10 min (= the old sustained maximum of 1 per 2 min).

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
              where x.dev=p_dev and x.seen_at>now()-interval '2 minutes' and (station_key(sx.id) is distinct from v_key or (sx.line_id=v_line and (sx.id<>p_station or x.dir=p_dir))))
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

revoke all on function report(int,text,text,text) from public, anon, authenticated;
grant execute on function report(int,text,text,text) to service_role;

-- ===== migrate_v18.sql =====
-- v0.45: "message the developers" (suggestions / bug reports). Run once in the Supabase SQL editor. Safe to re-run.
create table if not exists feedback(
  id bigserial primary key, created_at timestamptz default now(),
  kind text not null check (kind in ('idea','bug','other')),
  msg text not null check (length(msg) between 5 and 1000),
  lang text, ctx text,            -- ctx = app version + screen size (+ 'pwa'), nothing personal
  dev text, ip text,              -- dev = random device id, ip = md5 hash; only used for rate limits / bans
  done boolean not null default false);
create index if not exists feedback_new on feedback(created_at desc);
alter table feedback enable row level security;   -- no policies: anon can neither read nor write; only the function below (via the Worker)

create or replace function send_feedback(p_kind text, p_msg text, p_lang text, p_ctx text, p_dev text, p_ip text) returns text
language plpgsql security definer set search_path=public as $$
declare v_ip text := md5(coalesce(p_ip,'?')); v_m text := btrim(coalesce(p_msg,''));
begin
  if p_dev is null or length(p_dev)<16 then return 'bad'; end if;
  if exists(select 1 from banned where k in (p_dev,v_ip)) then return 'bad'; end if;
  if p_kind is null or p_kind not in ('idea','bug','other') or length(v_m)<5 or length(v_m)>1000 then return 'bad'; end if;
  if (select count(*) from feedback where dev=p_dev and created_at>now()-interval '1 hour')>=3 then return 'slow'; end if;
  if (select count(*) from feedback where ip=v_ip and created_at>now()-interval '1 day')>=10 then return 'slow'; end if;
  insert into feedback(kind,msg,lang,ctx,dev,ip) values(p_kind,v_m,left(p_lang,2),left(p_ctx,60),p_dev,v_ip);
  return 'ok';
end $$;
revoke all on function send_feedback(text,text,text,text,text,text) from public, anon, authenticated;
grant execute on function send_feedback(text,text,text,text,text,text) to service_role;

-- ===== migrate_v19.sql =====
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

-- ===== migrate_v20.sql =====
-- v0.48: admin 'Messages' tab (read the riders' feedback). Needs migrate_v18.sql (table feedback). Run once in the Supabase SQL editor; safe to re-run.
create or replace function admin_feedback(p_show text, p_limit int) returns json language sql stable security definer set search_path=public as $$
  select json_build_object(
    'unread', (select count(*) from feedback where not done),
    'rows',   (select coalesce(json_agg(r order by r.id desc),'[]'::json) from (
                 select id, created_at, kind, lang, ctx, msg, done from feedback
                 where p_show='all' or (p_show='new' and not done) or (p_show='read' and done)
                 order by id desc limit least(greatest(coalesce(p_limit,100),1),200)) r)) $$;

create or replace function admin_feedback_act(p_act text, p_id bigint, p_ip text) returns text language plpgsql security definer set search_path=public as $$
declare n int;
begin
  if p_act='read' then update feedback set done=true where id=p_id;
  elsif p_act='unread' then update feedback set done=false where id=p_id;
  elsif p_act='delete' then delete from feedback where id=p_id;
  elsif p_act='readall' then update feedback set done=true where not done;
  else return 'bad'; end if;
  get diagnostics n = row_count;
  if n=0 then return 'nf'; end if;
  insert into admin_log(act,target,note,ip) values('fb_'||p_act, coalesce(p_id::text,''), null, p_ip);
  return 'ok';
end $$;

revoke all on function admin_feedback(text,int), admin_feedback_act(text,bigint,text) from public, anon, authenticated;
grant execute on function admin_feedback(text,int), admin_feedback_act(text,bigint,text) to service_role;

-- ===== migrate_v21.sql =====
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

-- ===== migrate_v22.sql =====
-- v0.50: Line 1 really runs Ben Arous <-> TUNIS MARINE (Transtu map; reported by a rider). Adds "Tunis Marine" and "Farhat Hached" before "Place de Barcelone".
-- Same spelling as lines 3 and 6, so interchange grouping (station_key = lower(fr)) works. Positions of line 1 shift by +20 (no unique constraint on pos).
-- ALSO adds the missing TGM station 'Carthage Salammbo' (between Le Kram and Carthage Byrsa, on the Transtu map).
-- Safe to re-run (does nothing once Tunis Marine exists on line 1). Existing sightings/incidents keep their station ids; direction 'b' on line 1 now means "toward Tunis Marine".
do $$ begin
  if not exists (select 1 from stations where line_id='1' and lower(fr)='tunis marine') then
    update stations set pos=pos+20 where line_id='1';
    insert into stations(line_id,pos,ar,fr,en) values
      ('1',10,'تونس البحرية','Tunis Marine','Tunis Marine'),
      ('1',20,'فرحات حشاد','Farhat Hached','Farhat Hached');
  end if;
end $$;

do $$ begin
  if not exists (select 1 from stations where line_id='TGM' and lower(fr) like 'carthage salamm%')
     and exists (select 1 from stations where line_id='TGM' and fr='Le Kram') then
    insert into stations(line_id,pos,ar,fr,en)
      select 'TGM', pos+5, 'قرطاج سلامبو', 'Carthage Salammbô', 'Carthage Salammbô' from stations where line_id='TGM' and fr='Le Kram';
  end if;
end $$;

-- ===== migrate_v23.sql =====
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

-- ===== migrate_v24.sql =====
-- v0.52: buses. lines get a 'kind' ('metro' default, 'bus'); adds bus line 4C with its stations (live sightings + stop reports work exactly like metro).
-- Bus stations whose name equals a metro station (Bab Saadoun, 20 Mars, Denden...) are treated like an interchange (station_key = lower(fr)): a rider may report both within 2 minutes.
-- live_all(): the 45-minute counter now counts METRO sightings only (the metro page counter must not change). Run once in the Supabase SQL editor; safe to re-run.
alter table lines add column if not exists kind text not null default 'metro';
insert into lines(id,color,sort,kind) values ('4C','#d62828',100,'bus') on conflict (id) do update set kind='bus';
do $$ begin
  if not exists (select 1 from stations where line_id='4C') then
    insert into stations(line_id,pos,ar,fr,en) values
    ('4C',10,'حديقة ثامر','Jardin Thameur','Jardin Thameur'),
    ('4C',20,'شارع مريد','Rue Mrid','Mrid Street'),
    ('4C',30,'جامع البرج باب العسل','Mosquée El Bordj, Bab El Assel','El Bordj Mosque, Bab El Assel'),
    ('4C',40,'باب سعدون','Bab Saadoun','Bab Saadoun'),
    ('4C',50,'بوشوشة','Bouchoucha','Bouchoucha'),
    ('4C',60,'20 مارس','20 Mars','20 Mars'),
    ('4C',70,'محطة القطار بباردو','Gare du Bardo','Bardo Train Station'),
    ('4C',80,'الصناعات التقليدية','Industries Traditionnelles','Traditional Industries'),
    ('4C',90,'الدندان','Denden','Denden'),
    ('4C',100,'محطة منوبة','Gare de la Manouba','Manouba Station'),
    ('4C',110,'سليمان كاهية','Slimane Kahia','Slimane Kahia'),
    ('4C',120,'المنصف باي','Moncef Bey','Moncef Bey'),
    ('4C',130,'الرازي','Er-Razi','Er-Razi'),
    ('4C',140,'القطب التكنولوجي','Pôle Technologique','Technology Hub'),
    ('4C',150,'قصر الوردة','Ksar El Ward','Ksar El Ward'),
    ('4C',160,'المركب الجامعي','Complexe Universitaire','University Campus'),
    ('4C',170,'خير الدين','Khéreddine','Khereddine');
  end if;
end $$;
create or replace function live_all() returns json language sql stable set search_path=public as $$
  select json_build_object(
    's',(select coalesce(json_agg(l),'[]'::json) from live l),
    'i',(select coalesce(json_agg(i),'[]'::json) from live_incidents i),
    'n',(select count(*) from sightings s join stations st on st.id=s.station_id join lines ln on ln.id=st.line_id
         where ln.kind='metro' and s.seen_at>now()-interval '45 minutes' and s.down-s.up<2)) $$;
revoke all on function live_all() from public, anon, authenticated;
grant execute on function live_all() to service_role;

-- ===== migrate_v25.sql =====
-- v0.53: a train that STANDS at a station no longer turns into a new sighting every few minutes.
-- The 'same train' window used to be a fixed 3 min (report merge) / 4 min (live view). It now grows with the confirmations the sighting already has:
-- report merge window = 3 + 2*min(up,4) min (3..11), live view window = 4 + 2*min(up,4) min (4..12). Each merge keeps the confirmations, so a stationary train stays ONE entry.
-- Cost: a genuinely new train arriving at the same station within that window after a well-confirmed one is merged into it (the board still shows the newest time).
-- Run once in the Supabase SQL editor; safe to re-run. Needs migrate_v16/v23 (station_key, report).
create or replace view live as
with cand as (
  select s.id, st.line_id, s.station_id, s.dir, s.seen_at, s.up, s.down
  from sightings s join stations st on st.id=s.station_id
  where s.seen_at > now()-interval '30 days' and s.down-s.up<2
    and not exists(select 1 from sightings n where n.station_id=s.station_id and n.dir=s.dir
                   and n.seen_at>s.seen_at and n.seen_at<=s.seen_at+make_interval(mins => 4+2*least(s.up,4)) and n.down-n.up<2)
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
      and seen_at>now()-make_interval(mins => v_mins+2*least(up,4)) and down-up<2
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

-- ===== test_seed.sql =====
-- STAGING / TEST PROJECT ONLY. NEVER RUN ON PRODUCTION (it empties the sightings and incidents tables).
-- Fills the board with every state the UI can show: fresh, 1h+ old, days old, empty lines, a stop alert, a paused (auto-blocked) device.
truncate sightings, incidents restart identity cascade;

with v(l,o,d,m,n) as (values
  ('4',3,'a',4,1),('4',3,'a',5,14),('4',3,'a',40,13),('4',6,'a',13,2),('4',9,'a',31,3),('4',2,'b',7,4),('4',5,'b',26,5),   -- line 4: busy. Station #4: 4 min + 5 min = same train reported twice (shows ONE), 40 min = a 2nd train (shows TWO entries)
  ('1',4,'a',61,6),('1',8,'b',125,7),                                                      -- line 1: '1h 1min ago' and '2h 5min ago'
  ('2',3,'a',1500,8),('2',5,'b',3000,9),                                                   -- line 2: '1d 1h ago' and '2d 2h ago'
  ('5',2,'a',20,10),('6',2,'b',8,11),('TGM',2,'a',100,12))                                 -- line 3 has nothing -> 'No report yet'
insert into sightings(station_id,dir,dev,ip,seen_at)
select s.id, v.d, 'seed-device-000000'||v.n, md5('seed'||v.n), now()-(v.m||' minutes')::interval
from v cross join lateral (select id from stations where line_id=v.l order by pos offset v.o limit 1) s;

-- a live stop alert on line 5 (3 confirmations)
insert into incidents(station_id,dev,ip,up,down,last_at)
select id,'seed-incident-0000001',md5('seed-i'),3,0,now()-interval '4 minutes' from stations where line_id='5' order by pos offset 4 limit 1;

-- a troll: 3 sightings already rejected by riders (down=2) -> this device is auto-paused.
-- To test the pause: open the test site, DevTools console: localStorage.dev='seed-troll-device-000001'; location.reload(); then try to report.
insert into sightings(station_id,dir,dev,ip,seen_at,down)
select id,'a','seed-troll-device-000001',md5('seed-t'),now()-interval '30 minutes',2 from stations where line_id='3' order by pos limit 3;

-- bus 4C (needs migrate_v24.sql): one fresh sighting each way and a stop alert
insert into sightings(station_id,dir,dev,ip,seen_at)
select id,'a','seed-device-0000000b1',md5('seed-b1'),now()-interval '6 minutes' from stations where line_id='4C' order by pos offset 5 limit 1;
insert into sightings(station_id,dir,dev,ip,seen_at)
select id,'b','seed-device-0000000b2',md5('seed-b2'),now()-interval '12 minutes' from stations where line_id='4C' order by pos offset 9 limit 1;
insert into incidents(station_id,dev,ip,up,down,last_at,dir)
select id,'seed-incident-0000002',md5('seed-i2'),2,0,now()-interval '3 minutes','a' from stations where line_id='4C' order by pos offset 11 limit 1;

-- ===== migrate_v26.sql =====
-- v0.54: line 4C is ONLY Bab Saadoun <-> Khereddine for now (it temporarily backs up the metro during the works; rider report).
-- Removes the 3 stations that are not served (Jardin Thameur, Rue Mrid, El Bordj Mosque / Bab El Assel) and the separate "4C/" line
-- ('4Cx') that an earlier draft of this file created. Their sightings/stop reports are deleted with them (ON DELETE CASCADE).
-- Direction a = toward Khereddine, b = toward Bab Saadoun. Run once in the Supabase SQL editor; safe to re-run.
delete from lines where id='4Cx';
delete from stations where line_id='4C' and pos<40;

-- ===== migrate_v27.sql =====
-- v0.55: adaptive CAPTCHA. Riders may post a few times WITHOUT a CAPTCHA token (it was refusing real people);
-- the Worker asks for the CAPTCHA only when this function says no. Run once in the Supabase SQL editor; safe to re-run.
-- Limits (tune here): per device 6 unverified posts / 24 h, per IP 20 / hour (carriers share IPs, so generous),
-- and a global SURGE switch: 40 unverified posts in 10 minutes anywhere = everybody must pass the CAPTCHA until it calms down.
-- Stores only the device id and md5(IP) (same as the other tables) and is pruned after 2 days.
create table if not exists unverified_log(dev text, ip text, at timestamptz default now());
create index if not exists unverified_log_dev on unverified_log(dev, at desc);
create index if not exists unverified_log_ip on unverified_log(ip, at desc);
create index if not exists unverified_log_at on unverified_log(at desc);
alter table unverified_log enable row level security;   -- no policies: Worker only

create or replace function unverified_ok(p_dev text, p_ip text) returns boolean
language plpgsql security definer set search_path=public as $$
declare v_ip text := md5(coalesce(p_ip,'?'));
begin
  if p_dev is null or length(p_dev)<16 then return false; end if;
  delete from unverified_log where at < now()-interval '2 days';
  if (select count(*) from unverified_log where at>now()-interval '10 minutes')>=40 then return false; end if;   -- surge: captcha for everyone
  if (select count(*) from unverified_log where dev=p_dev and at>now()-interval '1 day')>=6 then return false; end if;
  if (select count(*) from unverified_log where ip=v_ip and at>now()-interval '1 hour')>=20 then return false; end if;
  insert into unverified_log(dev,ip) values(p_dev,v_ip);
  return true;
end $$;
revoke all on function unverified_ok(text,text) from public, anon, authenticated;
grant execute on function unverified_ok(text,text) to service_role;

-- ===== migrate_v28.sql =====
-- v0.56: admin "Insights" tab (share images per line). Run once in the Supabase SQL editor; safe to re-run.
-- Aggregates the last p_days days (7..90, ending yesterday, Tunis time) of sightings. Left out: banned devices/IPs and every report riders rated net-negative (down > up).
-- VOTES: a report confirmed by riders counts more in the hour chart and in the tie-break (weight 1 + min(up,2), so 1 to 3).
-- p_bucket = size of the time slots in the repeating-times list: 15, 30 or 60 minutes (default 15). Rows return 'm' = minutes since midnight (Tunis).
-- Hour arrays = report counts per Tunis hour 6..22 (weekdays Mon-Fri / weekend Sat-Sun). Rows ('rw' weekdays top 8, 're' weekend top 3) = the
-- station + direction + hour slots seen on the MOST DIFFERENT days (dd), at least 2 days. a = toward the last station of the line, b = toward the first.
drop function if exists admin_insights(int);
create or replace function admin_insights(p_days int, p_bucket int default 15) returns json
language plpgsql stable security definer set search_path=public as $$
declare v_to date := (now() at time zone 'Africa/Tunis')::date - 1; v_days int := greatest(7, least(coalesce(p_days,21), 90)); v_b int := case when p_bucket in (15,30,60) then p_bucket else 15 end; v_from date; r json;
begin
  v_from := v_to - (v_days-1);
  with base as (
    select st.line_id lid, st.ar st_ar, s.dir,
           (s.seen_at at time zone 'Africa/Tunis')::date d,
           extract(hour from s.seen_at at time zone 'Africa/Tunis')::int h,
           ((extract(hour from s.seen_at at time zone 'Africa/Tunis')::int*60 + extract(minute from s.seen_at at time zone 'Africa/Tunis')::int) / v_b) * v_b m,
           1 + least(coalesce(s.up,0), 2) w,
           (extract(isodow from s.seen_at at time zone 'Africa/Tunis') >= 6) we
    from sightings s join stations st on st.id=s.station_id
    where s.seen_at >= (v_from::timestamp at time zone 'Africa/Tunis')
      and s.seen_at <  ((v_to+1)::timestamp at time zone 'Africa/Tunis')
      and coalesce(s.down,0) <= coalesce(s.up,0)
      and not exists (select 1 from banned b where b.k in (s.dev, s.ip))
  ), hrs as (
    select lid, we, h, sum(w)::int c from base where h between 6 and 22 group by 1,2,3
  ), rep as (
    select lid, we, st_ar, dir, m, count(distinct d) dd, sum(w)::int nn from base where h between 6 and 22 group by 1,2,3,4,5 having count(distinct d) >= 2
  ), repr as (
    select *, row_number() over (partition by lid, we order by dd desc, nn desc, m, st_ar) rn from rep
  )
  select json_build_object(
    'from', v_from, 'to', v_to, 'days', v_days, 'bucket', v_b,
    'wd_days', (select count(*) from generate_series(v_from::timestamp, v_to::timestamp, interval '1 day') g where extract(isodow from g) < 6),
    'we_days', (select count(*) from generate_series(v_from::timestamp, v_to::timestamp, interval '1 day') g where extract(isodow from g) >= 6),
    'lines', (select coalesce(json_agg(x order by x.sort), '[]'::json) from (
      select l.id, l.color, l.sort,
        (select ar from stations where line_id=l.id order by pos desc limit 1) a,
        (select ar from stations where line_id=l.id order by pos asc  limit 1) b,
        (select count(*) from base where lid=l.id) n,
        (select coalesce(json_object_agg(h, c), '{}'::json) from hrs where lid=l.id and not we) hw,
        (select coalesce(json_object_agg(h, c), '{}'::json) from hrs where lid=l.id and we) he,
        (select coalesce(json_agg(json_build_object('st',st_ar,'dir',dir,'m',m,'dd',dd,'nn',nn) order by rn), '[]'::json) from repr where lid=l.id and not we and rn<=8) rw,
        (select coalesce(json_agg(json_build_object('st',st_ar,'dir',dir,'m',m,'dd',dd,'nn',nn) order by rn), '[]'::json) from repr where lid=l.id and we and rn<=3) re
      from lines l) x)
  ) into r;
  return r;
end $$;
revoke all on function admin_insights(int,int) from public, anon, authenticated;
grant execute on function admin_insights(int,int) to service_role;
