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
