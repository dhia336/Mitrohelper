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
('1',10,'ساحة برشلونة','Place de Barcelone','Place de Barcelone'),
('1',20,'باب عليوة','Bab Alioua','Bab Alioua'),
('1',30,'محمد مناشو','Mohamed Manachou','Mohamed Manachou'),
('1',40,'13 أوت','13 Aout','13 Aout'),
('1',50,'محمد علي','Mohamed Ali','Mohamed Ali'),
('1',60,'الكبارية','El Kabaria','El Kabaria'),
('1',70,'ابن سينا','Ibn Sina','Ibn Sina'),
('1',80,'الوردية 6','El Ouardia 6','El Ouardia 6'),
('1',90,'حي النور','Cité Ennour','Cité Ennour'),
('1',100,'أبو القاسم الشابي','Abou Kacem Echebbi','Abou Kacem Echebbi'),
('1',110,'بن عروس','Ben Arous','Ben Arous'),
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
('2',110,'L''Independance','L''Independance','L''Independance'),
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
('4',110,'L''Artisanat','L''Artisanat','L''Artisanat'),
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
('6',150,'L''Environnement','L''Environnement','L''Environnement'),
('6',160,'المروج 3','El Mourouj 3','El Mourouj 3'),
('6',170,'الشهداء','Les Martyrs','Les Martyrs'),
('6',180,'المروج 4','El Mourouj 4','El Mourouj 4'),
('TGM',10,'تونس البحرية','Tunis Marine','Tunis Marine'),
('TGM',20,'الباك','Le Bac','Le Bac'),
('TGM',30,'حلق الوادي','La Goulette','La Goulette'),
('TGM',40,'حلق الوادي الجديدة','La Goulette Neuve','La Goulette Neuve'),
('TGM',50,'حلق الوادي الكازينو','La Goulette Casino','La Goulette Casino'),
('TGM',60,'خير الدين','Kheireddine','Kheireddine'),
('TGM',70,'L''Aeroport','L''Aeroport','L''Aeroport'),
('TGM',80,'الكرم','Le Kram','Le Kram'),
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
