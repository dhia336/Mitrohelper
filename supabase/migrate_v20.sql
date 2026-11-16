-- v0.48: admin 'Messages' tab (read the riders' feedback). Needs migrate_v18.sql (table feedback). Run once in the Supabase SQL editor; safe to re-run.
create or replace function admin_feedback(p_show text, p_limit int) returns json language sql stable security definer set search_path=public as $$
  select json_build_object(
    'unread', (select count(*) from feedback where not done),
    'rows',   (select coalesce(json_agg(r order by r.id desc),'[]'::json) from (
                 select id, created_at, kind, lang, ctx, msg, done from feedback
                 where p_show='all' or (p_show='new' and not done) or (p_show='read' and done)
                 order by id desc limit least(greatest(coalesce(p_limit,100),1),200)) r)) $$;

create or replace function admin_feedback_act(p_act text, p_id bigint, p_ip text) returns text language plpgsql security definer set search_path=public as $$
declare n int;
begin
  if p_act='read' then update feedback set done=true where id=p_id;
  elsif p_act='unread' then update feedback set done=false where id=p_id;
  elsif p_act='delete' then delete from feedback where id=p_id;
  elsif p_act='readall' then update feedback set done=true where not done;
  else return 'bad'; end if;
  get diagnostics n = row_count;
  if n=0 then return 'nf'; end if;
  insert into admin_log(act,target,note,ip) values('fb_'||p_act, coalesce(p_id::text,''), null, p_ip);
  return 'ok';
end $$;

revoke all on function admin_feedback(text,int), admin_feedback_act(text,bigint,text) from public, anon, authenticated;
grant execute on function admin_feedback(text,int), admin_feedback_act(text,bigint,text) to service_role;
