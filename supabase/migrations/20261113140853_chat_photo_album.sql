-- Old clients continue to read and send individual photo messages.
-- The shared identifier is immutable under the existing chat update guard.
alter table public.chat_messages add column media_group_id uuid;

alter table public.chat_messages
  add constraint chat_photo_group_shape check (
    media_group_id is null or (
      photo_url is not null and audio_url is null and video_url is null
      and encrypted_payload is null
    )
  );

create index chat_messages_media_group_lookup
  on public.chat_messages(sender_id, receiver_id, media_group_id)
  where media_group_id is not null;

-- e2ee_guard_chat serializes inserts per conversation before this trigger.
-- Only the first committed photo in an album needs a push notification.
create or replace function public.notify_chat_push()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  if new.media_group_id is not null and exists (
    select 1 from public.chat_messages m
    where m.sender_id = new.sender_id and m.receiver_id = new.receiver_id
      and m.media_group_id = new.media_group_id and m.id <> new.id
  ) then
    return new;
  end if;
  insert into public.push_outbox(message_id) values(new.id) on conflict do nothing;
  perform public.pulsepath_dispatch_push(new.id);
  return new;
end;
$$;

create function public.pulsepath_chat_unread_counts()
returns table(sender_id uuid, unread_count bigint)
language sql stable security invoker set search_path = '' as $$
  select m.sender_id, count(distinct coalesce(m.media_group_id, m.id))
  from public.chat_messages m
  where m.receiver_id = auth.uid() and m.read_at is null
  group by m.sender_id;
$$;
revoke all on function public.pulsepath_chat_unread_counts() from public, anon;
grant execute on function public.pulsepath_chat_unread_counts() to authenticated;
