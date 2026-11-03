alter table public.chat_messages add column community_post_id uuid;
-- No FK: historic chat references remain harmless when a publication is removed.
create function app_private.can_share_community_post(post_id uuid, recipient uuid)
returns boolean language sql stable security definer set search_path='' as $$
 select auth.uid() is not null and recipient <> auth.uid()
 and exists(select 1 from public.friends f where f.user_id=auth.uid() and f.friend_id=recipient)
 and not exists(select 1 from public.chat_blocks b where
  (b.blocker_id=auth.uid() and b.blocked_id=recipient) or (b.blocker_id=recipient and b.blocked_id=auth.uid()))
 and exists(select 1 from public.community_posts p where p.id=post_id
   and p.moderation_hidden_at is null
   and (p.author_id=auth.uid() or p.audience='everyone' or exists(select 1 from public.friends f where f.user_id=auth.uid() and f.friend_id=p.author_id))
   and (p.author_id=recipient or p.audience='everyone' or exists(select 1 from public.friends f where f.user_id=recipient and f.friend_id=p.author_id)));
$$;
revoke all on function app_private.can_share_community_post(uuid,uuid) from public,anon;
grant execute on function app_private.can_share_community_post(uuid,uuid) to authenticated;
create policy "Community post share recipient access" on public.chat_messages
as restrictive for insert to authenticated with check (
 community_post_id is null or (sender_id=auth.uid() and
 app_private.can_share_community_post(community_post_id,receiver_id) and
 body='Публикация сообщества' and sticker is null and photo_url is null
 and audio_url is null and video_url is null and video_poster_url is null
 and video_metadata is null and route_attachment is null and group_invitation is null));

