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
