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
