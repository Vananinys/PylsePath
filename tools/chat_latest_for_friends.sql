-- Read-only API: retain caller RLS, no elevated database privileges.
create or replace function public.chat_latest_for_friends(friend_ids uuid[])
returns setof public.chat_messages
language sql stable security invoker
set search_path = ''
as $$
  select latest.*
  from (select distinct peer from unnest(friend_ids[1:100]) as ids(peer)) peers
  cross join lateral (
    select candidates.* from (
      (select m.* from public.chat_messages m
       where m.sender_id = (select auth.uid()) and m.receiver_id = peers.peer
       order by m.created_at desc, m.id desc limit 1)
      union all
      (select m.* from public.chat_messages m
       where m.sender_id = peers.peer and m.receiver_id = (select auth.uid())
       order by m.created_at desc, m.id desc limit 1)
    ) candidates order by candidates.created_at desc, candidates.id desc limit 1
  ) latest
  where (select auth.uid()) is not null;
$$;
revoke all on function public.chat_latest_for_friends(uuid[]) from public, anon;
grant execute on function public.chat_latest_for_friends(uuid[]) to authenticated;
