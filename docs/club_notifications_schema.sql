alter table public.rider_club_members add column notification_mode text not null default 'invitations' check(notification_mode in ('all','invitations','off'));
alter table public.rider_club_members add column last_read_at timestamptz not null default now();

alter function app_private.club_action(text,uuid,jsonb) rename to club_action_base;
create function app_private.club_action(p_action text,p_club uuid default null,p_data jsonb default '{}') returns jsonb language plpgsql security definer set search_path='' as $$
declare uid uuid:=auth.uid(); result jsonb; row jsonb; enriched jsonb:='[]'; member public.rider_club_members;
begin
 if uid is null then raise exception 'AUTH_REQUIRED'; end if;
 if p_action in ('notifications','read') then
  select * into member from public.rider_club_members where club_id=p_club and user_id=uid and left_at is null;
  if member.user_id is null then raise exception 'CLUB_MEMBER_REQUIRED'; end if;
  if p_action='notifications' then
   if coalesce(p_data->>'mode','') not in ('all','invitations','off') then raise exception 'CLUB_ACTION_INVALID'; end if;
   update public.rider_club_members set notification_mode=p_data->>'mode' where club_id=p_club and user_id=uid;
  else update public.rider_club_members set last_read_at=now() where club_id=p_club and user_id=uid; end if;
  result:=app_private.club_action_base('snapshot',p_club,'{}');
 else result:=app_private.club_action_base(p_action,p_club,p_data); end if;
 if p_action='home' then
  for row in select value from jsonb_array_elements(result) loop
   if row->>'member'='true' then
    select * into member from public.rider_club_members where club_id=(row->>'id')::uuid and user_id=uid and left_at is null;
    row:=row||jsonb_build_object('unread_count',(select count(*) from public.rider_club_messages x where x.club_id=member.club_id and x.sender_id<>uid and x.created_at>greatest(member.last_read_at,member.joined_at)));
   end if;
   enriched:=enriched||jsonb_build_array(row);
  end loop;
  return enriched;
 end if;
 if jsonb_typeof(result)='object' and result->>'member'='true' then
  select * into member from public.rider_club_members where club_id=(result->>'id')::uuid and user_id=uid and left_at is null;
  result:=result||jsonb_build_object('notification_mode',member.notification_mode,'unread_count',(select count(*) from public.rider_club_messages x where x.club_id=member.club_id and x.sender_id<>uid and x.created_at>greatest(member.last_read_at,member.joined_at)));
 end if;
 return result;
end $$;
revoke all on function app_private.club_action(text,uuid,jsonb),app_private.club_action_base(text,uuid,jsonb) from public,anon;
grant execute on function app_private.club_action(text,uuid,jsonb) to authenticated;
-- The base is no longer a client API: only the authorization wrapper calls it.
revoke execute on function app_private.club_action_base(text,uuid,jsonb) from authenticated;
create or replace function public.club_action(p_action text,p_club uuid default null,p_data jsonb default '{}') returns jsonb language sql set search_path='' as $$select app_private.club_action(p_action,p_club,p_data)$$;

create table public.club_push_outbox (
 id uuid primary key default gen_random_uuid(), club_id uuid not null references public.rider_clubs(id),
 recipient_id uuid not null references auth.users(id), kind text not null check(kind in ('message','ride','event','event_cancel')),
 reference_id uuid not null, status text not null default 'pending' check(status in ('pending','processing','done','failed')),
 attempts integer not null default 0, created_at timestamptz not null default now(), next_attempt_at timestamptz not null default now(),
 locked_at timestamptz, sent_at timestamptz, last_error text,
 unique(recipient_id,kind,reference_id)
);
create index club_push_retry on public.club_push_outbox(next_attempt_at) where status<>'done';
create table public.club_push_deliveries (
 notification_id uuid not null references public.club_push_outbox(id),token_hash text not null,
 sent_at timestamptz not null default now(),primary key(notification_id,token_hash)
);
alter table public.club_push_outbox enable row level security;
alter table public.club_push_deliveries enable row level security;
revoke all on public.club_push_outbox,public.club_push_deliveries from public,anon,authenticated;
grant all on public.club_push_outbox,public.club_push_deliveries to service_role;
create policy club_outbox_internal on public.club_push_outbox to authenticated using(false) with check(false);
create policy club_delivery_internal on public.club_push_deliveries to authenticated using(false) with check(false);

create function app_private.dispatch_club_push(p_id uuid) returns bigint language plpgsql security definer set search_path='' as $$
declare endpoint text; secret text; request_id bigint;
begin
 select decrypted_secret into endpoint from vault.decrypted_secrets where name='push_function_url' order by created_at desc limit 1;
 select decrypted_secret into secret from vault.decrypted_secrets where name='push_webhook_secret' order by created_at desc limit 1;
 if endpoint is null or endpoint not like 'https://%/functions/v1/send-chat-push' or length(coalesce(secret,''))<32 then
  update public.club_push_outbox set last_error='Missing push configuration',next_attempt_at=now()+interval '5 minutes' where id=p_id;return null;
 end if;
 select net.http_post(url:=regexp_replace(endpoint,'/send-chat-push$','/send-club-push'),headers:=jsonb_build_object('Content-Type','application/json','X-Push-Webhook-Secret',secret),body:=jsonb_build_object('notificationId',p_id),timeout_milliseconds:=10000) into request_id;
 update public.club_push_outbox set next_attempt_at=now()+interval '5 minutes' where id=p_id;
 return request_id;
exception when others then
 update public.club_push_outbox set last_error='Dispatch failed: '||SQLSTATE,next_attempt_at=now()+interval '5 minutes' where id=p_id;return null;
end $$;
revoke all on function app_private.dispatch_club_push(uuid) from public,anon,authenticated;

create function app_private.queue_club_push() returns trigger language plpgsql security definer set search_path='' as $$
declare kind text; sender uuid; r record;
begin
 if TG_TABLE_NAME='rider_club_messages' then kind:=case when new.ride_id is null then 'message' else 'ride' end;sender:=new.sender_id;
 else kind:=case when TG_OP='UPDATE' then 'event_cancel' else 'event' end;sender:=new.author_id;
  if TG_OP='UPDATE' and (old.cancelled_at is not null or new.cancelled_at is null) then return new; end if;
 end if;
 for r in
  insert into public.club_push_outbox(club_id,recipient_id,kind,reference_id)
   select new.club_id,m.user_id,kind,new.id from public.rider_club_members m
   where m.club_id=new.club_id and m.left_at is null and m.user_id<>sender
    and (m.notification_mode='all' or m.notification_mode='invitations' and kind<>'message')
   on conflict do nothing returning id
 loop perform app_private.dispatch_club_push(r.id); end loop;
 return new;
end $$;
revoke all on function app_private.queue_club_push() from public,anon,authenticated;
create trigger club_message_push after insert on public.rider_club_messages for each row execute function app_private.queue_club_push();
create trigger club_event_push after insert or update of cancelled_at on public.rider_club_events for each row execute function app_private.queue_club_push();

create function public.claim_club_push(p_id uuid) returns boolean language sql security definer set search_path='' as $$
 with claimed as(update public.club_push_outbox set status='processing',locked_at=now(),attempts=attempts+1
 where id=p_id and status<>'done' and attempts<10 and (locked_at is null or locked_at<now()-interval '2 minutes') returning id) select exists(select 1 from claimed)
$$;
revoke all on function public.claim_club_push(uuid) from public,anon,authenticated;
grant execute on function public.claim_club_push(uuid) to service_role;
create function app_private.retry_club_push() returns void language plpgsql security definer set search_path='' as $$
declare r record;
begin
 for r in select id from public.club_push_outbox where status<>'done' and attempts<10 and next_attempt_at<=now() and (locked_at is null or locked_at<now()-interval '2 minutes') order by next_attempt_at limit 30 loop
  perform app_private.dispatch_club_push(r.id);
 end loop;
end $$;
revoke all on function app_private.retry_club_push() from public,anon,authenticated;
select cron.schedule('club-push-retry','* * * * *','select app_private.retry_club_push()');
