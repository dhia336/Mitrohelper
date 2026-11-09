# Archived migrations (v2 - v13)

Everything here is ALREADY INCLUDED in `../schema.sql`, so a fresh database never needs these files.
They are kept only to upgrade a database that is older than v14:

1. Find the first missing step (the README section 'Check what production has' lists the checks; PROGRESS.md describes what each version added).
2. Run the files in order, v2, v4, v5 ... v13, then `../migrate_v14.sql` ... `../migrate_v17.sql`.
   Every file is safe to re-run. `prod_catchup_v4_to_v10.sql` is migrate_v4 .. v10 concatenated.

If your production database is already at v14 or later you will never need anything in this folder.
