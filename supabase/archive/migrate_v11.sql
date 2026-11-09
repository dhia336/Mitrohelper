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
