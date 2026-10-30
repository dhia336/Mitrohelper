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
