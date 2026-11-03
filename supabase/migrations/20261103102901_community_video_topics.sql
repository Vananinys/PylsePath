-- Additive community media. Existing ride/chat policies remain unchanged.
begin;
alter table public.community_posts add column video_path text;
alter table public.community_posts add column topics text[] not null default '{}';
alter table public.community_posts add constraint community_video_path_shape check (
 video_path is null or video_path ~ ('^'||author_id::text||'/video_[A-Za-z0-9_-]+[.](mp4|m4v|mov|webm)$'));
alter table public.community_posts add constraint community_topics_shape check (
 cardinality(topics)<=6 and array_position(topics,null) is null and
 topics <@ array['travel','memes','routes','cycling','running','other']::text[]);
create index community_posts_topics_gin on public.community_posts using gin(topics);
insert into storage.buckets(id,name,public,file_size_limit,allowed_mime_types)
 values ('community_videos','community_videos',false,52428800,array['video/mp4','video/quicktime','video/webm']);
create policy "Community video upload" on storage.objects for insert to authenticated with check (
 bucket_id='community_videos' and name ~ ('^'||auth.uid()::text||'/video_[A-Za-z0-9_-]+[.](mp4|m4v|mov|webm)$'));
create policy "Community video upload guard" on storage.objects as restrictive for insert to authenticated with check (
 bucket_id<>'community_videos' or name ~ ('^'||auth.uid()::text||'/video_[A-Za-z0-9_-]+[.](mp4|m4v|mov|webm)$'));
create policy "Community video read" on storage.objects for select to authenticated using (
 bucket_id='community_videos' and (
 (storage.foldername(name))[1]=auth.uid()::text or
 exists(select 1 from public.community_posts p where p.video_path=objects.name and p.author_id::text=(storage.foldername(objects.name))[1])));
create policy "Community video read guard" on storage.objects as restrictive for select to authenticated using (
 bucket_id<>'community_videos' or (
 (storage.foldername(name))[1]=auth.uid()::text or
 exists(select 1 from public.community_posts p where p.video_path=objects.name and p.author_id::text=(storage.foldername(objects.name))[1])));
create policy "Community video anonymous guard" on storage.objects as restrictive for select to anon using (bucket_id<>'community_videos');
-- Uploads use unique paths, replacement and deletion are not part of the client API.
create policy "Community video update guard" on storage.objects as restrictive for update to authenticated using (bucket_id<>'community_videos') with check (bucket_id<>'community_videos');
create policy "Community video delete guard" on storage.objects as restrictive for delete to authenticated using (bucket_id<>'community_videos');
commit;
