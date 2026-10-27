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
