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
