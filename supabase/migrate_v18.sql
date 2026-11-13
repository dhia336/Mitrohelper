-- v0.45: "message the developers" (suggestions / bug reports). Run once in the Supabase SQL editor. Safe to re-run.
create table if not exists feedback(
  id bigserial primary key, created_at timestamptz default now(),
  kind text not null check (kind in ('idea','bug','other')),
  msg text not null check (length(msg) between 5 and 1000),
  lang text, ctx text,            -- ctx = app version + screen size (+ 'pwa'), nothing personal
  dev text, ip text,              -- dev = random device id, ip = md5 hash; only used for rate limits / bans
  done boolean not null default false);
create index if not exists feedback_new on feedback(created_at desc);
alter table feedback enable row level security;   -- no policies: anon can neither read nor write; only the function below (via the Worker)

create or replace function send_feedback(p_kind text, p_msg text, p_lang text, p_ctx text, p_dev text, p_ip text) returns text
language plpgsql security definer set search_path=public as $$
declare v_ip text := md5(coalesce(p_ip,'?')); v_m text := btrim(coalesce(p_msg,''));
begin
  if p_dev is null or length(p_dev)<16 then return 'bad'; end if;
  if exists(select 1 from banned where k in (p_dev,v_ip)) then return 'bad'; end if;
  if p_kind is null or p_kind not in ('idea','bug','other') or length(v_m)<5 or length(v_m)>1000 then return 'bad'; end if;
  if (select count(*) from feedback where dev=p_dev and created_at>now()-interval '1 hour')>=3 then return 'slow'; end if;
  if (select count(*) from feedback where ip=v_ip and created_at>now()-interval '1 day')>=10 then return 'slow'; end if;
  insert into feedback(kind,msg,lang,ctx,dev,ip) values(p_kind,v_m,left(p_lang,2),left(p_ctx,60),p_dev,v_ip);
  return 'ok';
end $$;
revoke all on function send_feedback(text,text,text,text,text,text) from public, anon, authenticated;
grant execute on function send_feedback(text,text,text,text,text,text) to service_role;
