-- Additive audience protection. Review and apply in one transaction.
-- Legacy posts keep their existing public audience and URLs.
begin;
alter table public.community_posts add column audience text not null default 'everyone' check (audience in ('everyone','friends'));
alter table public.community_posts add column private_photo_paths text[] not null default '{}';
alter table public.post_comments add column private_photo_path text;
alter table public.community_posts add constraint community_private_photos_shape check (
 cardinality(private_photo_paths)<=4 and
 (cardinality(private_photo_paths)=0 or array_to_string(private_photo_paths,',') ~ ('^('||author_id::text||'/[A-Za-z0-9_-]+[.][A-Za-z0-9]+)(,'||author_id::text||'/[A-Za-z0-9_-]+[.][A-Za-z0-9]+)*$')) and
 (audience<>'friends' or cardinality(coalesce(photo_urls,'{}'::text[]))=0));
alter table public.post_comments add constraint community_comment_private_photo_shape check (private_photo_path is null or (photo_url is null and private_photo_path ~ ('^'||author_id::text||'/[A-Za-z0-9_-]+[.][A-Za-z0-9]+$')));
create policy "Community audience visible" on public.community_posts as restrictive for select to authenticated using (
 author_id=auth.uid() or audience='everyone' or exists(select 1 from public.friends f where f.user_id=auth.uid() and f.friend_id=author_id));
create policy "Community anonymous denied" on public.community_posts as restrictive for select to anon using (false);
-- Existing comments/likes restrictive policies already require visibility of parent post.
-- Guard new comments against public image URLs on friends-only posts.
create policy "Community comment private media" on public.post_comments as restrictive for insert to authenticated with check (
 photo_url is null or exists(select 1 from public.community_posts p where p.id=post_id and p.audience='everyone'));
create policy "Community comment edit private media" on public.post_comments as restrictive for update to authenticated using (true) with check (
 photo_url is null or exists(select 1 from public.community_posts p where p.id=post_id and p.audience='everyone'));
insert into storage.buckets(id,name,public,file_size_limit,allowed_mime_types) values('community_private','community_private',false,20971520,array['image/jpeg','image/png','image/webp','image/gif','image/heic','image/heif']);
create policy "Community private upload" on storage.objects for insert to authenticated with check (bucket_id='community_private' and (storage.foldername(name))[1]=auth.uid()::text);
create policy "Community private read" on storage.objects for select to authenticated using (bucket_id='community_private' and (
 (storage.foldername(name))[1]=auth.uid()::text or
 exists(select 1 from public.community_posts p where name=any(p.private_photo_paths) and (storage.foldername(name))[1]=p.author_id::text) or
 exists(select 1 from public.post_comments c where c.private_photo_path=name and (storage.foldername(name))[1]=c.author_id::text)));
-- Keep old RPC compatible while making its SECURITY DEFINER body honor audience.
create or replace function app_private.pulsepath_shared_gpx(p_ride_id uuid) returns text language sql stable security definer set search_path='' as $function$
 select r.gpx_data from public.rides r where r.id=p_ride_id and auth.uid() is not null and
 (r.user_id=auth.uid() or exists(select 1 from public.community_posts p where p.ride_id=r.id and p.author_id=r.user_id and p.share_gpx and p.moderation_hidden_at is null and
 (p.audience='everyone' or p.author_id=auth.uid() or exists(select 1 from public.friends f where f.user_id=auth.uid() and f.friend_id=p.author_id))));
$function$;
commit;
