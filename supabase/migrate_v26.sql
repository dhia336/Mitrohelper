-- v0.54: line 4C is ONLY Bab Saadoun <-> Khereddine for now (it temporarily backs up the metro during the works; rider report).
-- Removes the 3 stations that are not served (Jardin Thameur, Rue Mrid, El Bordj Mosque / Bab El Assel) and the separate "4C/" line
-- ('4Cx') that an earlier draft of this file created. Their sightings/stop reports are deleted with them (ON DELETE CASCADE).
-- Direction a = toward Khereddine, b = toward Bab Saadoun. Run once in the Supabase SQL editor; safe to re-run.
delete from lines where id='4Cx';
delete from stations where line_id='4C' and pos<40;
