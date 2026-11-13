-- Multi-row INSERT fires AFTER ROW triggers after all rows are visible.
-- Suppress a push only after another photo has actually queued one.
create or replace function public.notify_chat_push()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  if new.media_group_id is not null and exists (
    select 1 from public.chat_messages m
    join public.push_outbox o on o.message_id = m.id
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
