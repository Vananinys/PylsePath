-- Inbox and push queue, after community audience migration. Review before applying.
begin;
do $$begin if not exists(select 1 from pg_policies where schemaname='public' and tablename='community_posts' and cmd in('UPDATE','ALL') and permissive='PERMISSIVE') then
 create policy "Posts update own" on public.community_posts for update to authenticated using(author_id=auth.uid()) with check(author_id=auth.uid());
end if;end$$;

create table public.community_notifications(id uuid primary key default gen_random_uuid(),recipient_id uuid not null references auth.users(id) on delete cascade,actor_id uuid not null references auth.users(id) on delete cascade,kind text not null check(kind in('like','comment','friend')),reference_id uuid not null,post_id uuid references public.community_posts(id) on delete cascade,created_at timestamptz not null default now(),read_at timestamptz,unique(recipient_id,kind,actor_id,reference_id),check(recipient_id<>actor_id));
alter table public.community_notifications enable row level security;
revoke all on public.community_notifications from public,anon,authenticated;
grant select,update(read_at) on public.community_notifications to authenticated;
grant all on public.community_notifications to service_role;
create policy community_notice_recipient on public.community_notifications for select to authenticated using(recipient_id=auth.uid() and ((post_id is not null and exists(select 1 from public.community_posts p where p.id=post_id)) or (kind='friend' and exists(select 1 from public.friends f where f.user_id=auth.uid() and f.friend_id=actor_id))));
create policy community_notice_read on public.community_notifications for update to authenticated using(recipient_id=auth.uid()) with check(recipient_id=auth.uid());
create table public.community_push_outbox(id uuid primary key references public.community_notifications(id) on delete cascade,recipient_id uuid not null,kind text not null,status text not null default 'pending',attempts int not null default 0,next_attempt_at timestamptz not null default now(),locked_at timestamptz,sent_at timestamptz,last_error text);
create table public.community_push_deliveries(notification_id uuid references public.community_push_outbox(id) on delete cascade,token_hash text not null,sent_at timestamptz default now(),primary key(notification_id,token_hash));
create table public.community_push_devices(user_id uuid not null references auth.users(id) on delete cascade,token text not null,primary key(user_id,token));
alter table public.community_push_outbox enable row level security;
alter table public.community_push_deliveries enable row level security;
alter table public.community_push_devices enable row level security;
revoke all on public.community_push_outbox,public.community_push_deliveries,public.community_push_devices from public,anon,authenticated;
grant all on public.community_push_outbox,public.community_push_deliveries,public.community_push_devices to service_role;
create function public.register_community_push_device(p_token text) returns void language plpgsql security definer set search_path='' as $$begin
 if auth.uid() is null or length(coalesce(p_token,'')) not between 20 and 8192 or not exists(select 1 from public.fcm_tokens where user_id=auth.uid() and token=p_token) then raise exception 'DEVICE_REQUIRED'; end if;
 insert into public.community_push_devices(user_id,token) values(auth.uid(),p_token) on conflict do nothing;
end$$;
revoke all on function public.register_community_push_device(text) from public,anon;
grant execute on function public.register_community_push_device(text) to authenticated;
create function public.community_push_allowed(p_id uuid) returns boolean language sql stable security definer set search_path='' as $$
 select exists(select 1 from public.community_notifications n where n.id=p_id and n.read_at is null and
 ((n.kind='friend' and exists(select 1 from public.friends f where f.user_id=n.recipient_id and f.friend_id=n.actor_id)) or
 (exists(select 1 from public.community_posts p where p.id=n.post_id and p.author_id=n.recipient_id and p.moderation_hidden_at is null) and
 ((n.kind='like' and exists(select 1 from public.community_post_likes l where l.post_id=n.post_id and l.user_id=n.actor_id)) or
 (n.kind='comment' and exists(select 1 from public.post_comments c where c.id=n.reference_id and c.post_id=n.post_id and c.author_id=n.actor_id and c.moderation_hidden_at is null))))));
$$;
revoke all on function public.community_push_allowed(uuid) from public,anon,authenticated;
grant execute on function public.community_push_allowed(uuid) to service_role;
create function app_private.queue_community_notice() returns trigger language plpgsql security definer set search_path='' as $$declare recipient uuid; actor uuid; kind text; ref uuid; post uuid; notice uuid; begin
 if tg_table_name='friends' then recipient:=new.user_id;actor:=new.friend_id;kind:='friend';ref:=actor;
 elsif tg_table_name='community_post_likes' then post:=new.post_id;actor:=new.user_id;kind:='like';ref:=post;select author_id into recipient from public.community_posts where id=post and moderation_hidden_at is null and (author_id=actor or audience='everyone' or exists(select 1 from public.friends f where f.user_id=actor and f.friend_id=author_id));
 else post:=new.post_id;actor:=new.author_id;kind:='comment';ref:=new.id;select author_id into recipient from public.community_posts where id=post and moderation_hidden_at is null and (author_id=actor or audience='everyone' or exists(select 1 from public.friends f where f.user_id=actor and f.friend_id=author_id));end if;
 if recipient is null or recipient=actor then return new; end if;
 insert into public.community_notifications(recipient_id,actor_id,kind,reference_id,post_id) values(recipient,actor,kind,ref,post) on conflict do nothing returning id into notice;
 if notice is not null then insert into public.community_push_outbox(id,recipient_id,kind) values(notice,recipient,kind);perform app_private.dispatch_community_push(notice);end if;return new;
end$$;
revoke all on function app_private.queue_community_notice() from public,anon,authenticated;
create function app_private.dispatch_community_push(p_id uuid) returns bigint language plpgsql security definer set search_path='' as $$
declare endpoint text; secret text; request_id bigint;
begin
 select decrypted_secret into endpoint from vault.decrypted_secrets where name='push_function_url' order by created_at desc limit 1;
 select decrypted_secret into secret from vault.decrypted_secrets where name='push_webhook_secret' order by created_at desc limit 1;
 if endpoint is null or endpoint not like 'https://%/functions/v1/send-chat-push' or length(coalesce(secret,''))<32 then
  update public.community_push_outbox set last_error='Missing push configuration',next_attempt_at=now()+interval '5 minutes' where id=p_id;return null;
 end if;
 select net.http_post(url:=regexp_replace(endpoint,'/send-chat-push$','/send-community-push'),headers:=jsonb_build_object('Content-Type','application/json','X-Push-Webhook-Secret',secret),body:=jsonb_build_object('notificationId',p_id),timeout_milliseconds:=10000) into request_id;
 update public.community_push_outbox set next_attempt_at=now()+interval '5 minutes' where id=p_id;
 return request_id;
exception when others then
 update public.community_push_outbox set last_error='Dispatch failed: '||SQLSTATE,next_attempt_at=now()+interval '5 minutes' where id=p_id;return null;
end $$;
revoke all on function app_private.dispatch_community_push(uuid) from public,anon,authenticated;

create function public.claim_community_push(p_id uuid) returns boolean language sql security definer set search_path='' as $$
 with claimed as(update public.community_push_outbox set status='processing',locked_at=now(),attempts=attempts+1
 where id=p_id and status<>'done' and attempts<10 and (locked_at is null or locked_at<now()-interval '2 minutes') returning id) select exists(select 1 from claimed)
$$;
revoke all on function public.claim_community_push(uuid) from public,anon,authenticated;
grant execute on function public.claim_community_push(uuid) to service_role;
create function app_private.retry_community_push() returns void language plpgsql security definer set search_path='' as $$
declare r record;
begin
 for r in select id from public.community_push_outbox where status<>'done' and attempts<10 and next_attempt_at<=now() and (locked_at is null or locked_at<now()-interval '2 minutes') order by next_attempt_at limit 30 loop
  perform app_private.dispatch_community_push(r.id);
 end loop;
end $$;
revoke all on function app_private.retry_community_push() from public,anon,authenticated;
select cron.schedule('community-push-retry','* * * * *','select app_private.retry_community_push()');

create trigger community_like_notice after insert on public.community_post_likes for each row execute function app_private.queue_community_notice();
create trigger community_comment_notice after insert on public.post_comments for each row execute function app_private.queue_community_notice();
create trigger community_friend_notice after insert on public.friends for each row execute function app_private.queue_community_notice();
-- Realtime uses recipient RLS; no message/post content is duplicated into notifications.
alter publication supabase_realtime add table public.community_notifications;
commit;
