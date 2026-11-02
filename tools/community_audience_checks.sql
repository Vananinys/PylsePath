-- Run only AFTER community_audience_schema.sql. Entire fixture is rolled back.
-- No real post, upload, friendship or ride is retained.
begin;
create temp table audience_fixture(a uuid,b uuid,c uuid,p uuid,q uuid,r uuid,comment_id uuid,object_path text);
insert into audience_fixture(a,b,c,p,q,r,comment_id)
select a.id,b.id,c.id,gen_random_uuid(),gen_random_uuid(),gen_random_uuid(),gen_random_uuid()
from public.profiles a cross join public.profiles b cross join public.profiles c
where a.id<>b.id and a.id<>c.id and b.id<>c.id
and not exists(select 1 from public.friends f where (f.user_id=a.id and f.friend_id in(b.id,c.id)) or (f.friend_id=a.id and f.user_id in(b.id,c.id))) limit 1;
do $$begin if not exists(select 1 from audience_fixture) then raise exception 'Need three profiles without fixture friendships'; end if; end$$;
update audience_fixture set object_path=a::text||'/privacy_test.jpg';
grant select on audience_fixture to authenticated,anon;
create function pg_temp.assert_true(ok boolean, message text) returns void language plpgsql as $$begin if ok is distinct from true then raise exception '%',message; end if; end$$;
insert into public.friends(user_id,friend_id) select a,b from audience_fixture union all select b,a from audience_fixture;
insert into public.rides(id,user_id,distance_km,duration_seconds,gpx_data) select r,a,1,100,'PRIVATE_TEST_GPX' from audience_fixture;
insert into public.community_posts(id,author_id,body,audience,ride_id,share_gpx,private_photo_paths)
select p,a,'rollback audience fixture','friends',r,true,array[object_path] from audience_fixture;
insert into public.community_posts(id,author_id,body,audience) select q,a,'rollback public fixture','everyone' from audience_fixture;
insert into public.post_comments(id,post_id,author_id,body) select comment_id,p,b,'rollback comment fixture' from audience_fixture;
insert into public.community_post_likes(post_id,user_id) select p,b from audience_fixture;
-- Only metadata fixture; no file is uploaded. Supabase may require direct-operation setting.
set local storage.allow_direct_operations='true';
insert into storage.objects(bucket_id,name,owner_id) select 'community_private',object_path,a::text from audience_fixture;
set local role authenticated;
select set_config('request.jwt.claim.sub',(select a::text from audience_fixture),true);
do $check$ begin
  perform pg_temp.assert_true((select count(*)=1 from public.community_posts where id=(select p from audience_fixture)),'author sees private post');
exception when others then raise exception 'Audience check [author sees private post] failed: %', SQLERRM;
end $check$;
do $check$ begin
  perform pg_temp.assert_true(public.pulsepath_shared_gpx((select r from audience_fixture))='PRIVATE_TEST_GPX','author GPX');
exception when others then raise exception 'Audience check [author GPX] failed: %', SQLERRM;
end $check$;
select set_config('request.jwt.claim.sub',(select b::text from audience_fixture),true);
do $check$ begin
  perform pg_temp.assert_true((select count(*)=1 from public.community_posts where id=(select p from audience_fixture)),'friend sees private post');
exception when others then raise exception 'Audience check [friend sees private post] failed: %', SQLERRM;
end $check$;
do $check$ begin
  perform pg_temp.assert_true((select count(*)=1 from public.post_comments where id=(select comment_id from audience_fixture)),'friend sees comments');
exception when others then raise exception 'Audience check [friend sees comments] failed: %', SQLERRM;
end $check$;
do $check$ begin
  perform pg_temp.assert_true((select count(*)=1 from storage.objects where bucket_id='community_private' and name=(select object_path from audience_fixture)),'friend reads private media');
exception when others then raise exception 'Audience check [friend reads private media] failed: %', SQLERRM;
end $check$;
do $check$ begin
  perform pg_temp.assert_true(public.pulsepath_shared_gpx((select r from audience_fixture))='PRIVATE_TEST_GPX','friend GPX');
exception when others then raise exception 'Audience check [friend GPX] failed: %', SQLERRM;
end $check$;
select set_config('request.jwt.claim.sub',(select c::text from audience_fixture),true);
do $check$ begin
  perform pg_temp.assert_true((select count(*)=0 from public.community_posts where id=(select p from audience_fixture)),'stranger cannot see private post');
exception when others then raise exception 'Audience check [stranger cannot see private post] failed: %', SQLERRM;
end $check$;
do $check$ begin
  perform pg_temp.assert_true((select count(*)=1 from public.community_posts where id=(select q from audience_fixture)),'stranger sees public post');
exception when others then raise exception 'Audience check [stranger sees public post] failed: %', SQLERRM;
end $check$;
do $check$ begin
  perform pg_temp.assert_true((select count(*)=0 from public.post_comments where id=(select comment_id from audience_fixture)),'stranger cannot see private comments');
exception when others then raise exception 'Audience check [stranger cannot see private comments] failed: %', SQLERRM;
end $check$;
do $check$ begin
  perform pg_temp.assert_true((select count(*)=0 from public.community_post_likes where post_id=(select p from audience_fixture)),'stranger cannot see private likes');
exception when others then raise exception 'Audience check [stranger cannot see private likes] failed: %', SQLERRM;
end $check$;
do $check$ begin
  perform pg_temp.assert_true((select count(*)=0 from storage.objects where bucket_id='community_private' and name=(select object_path from audience_fixture)),'stranger cannot read private media');
exception when others then raise exception 'Audience check [stranger cannot read private media] failed: %', SQLERRM;
end $check$;
do $check$ begin
  perform pg_temp.assert_true(public.pulsepath_shared_gpx((select r from audience_fixture)) is null,'stranger GPX denied');
exception when others then raise exception 'Audience check [stranger GPX denied] failed: %', SQLERRM;
end $check$;
reset role;
-- Remove only the two newly created fixture friendship rows, then roll back everything.
delete from public.friends where (user_id,friend_id) in(select a,b from audience_fixture union all select b,a from audience_fixture);
set local role authenticated;
select set_config('request.jwt.claim.sub',(select b::text from audience_fixture),true);
do $check$ begin
  perform pg_temp.assert_true((select count(*)=0 from public.community_posts where id=(select p from audience_fixture)),'former friend loses post');
exception when others then raise exception 'Audience check [former friend loses post] failed: %', SQLERRM;
end $check$;
do $check$ begin
  perform pg_temp.assert_true((select count(*)=0 from storage.objects where bucket_id='community_private' and name=(select object_path from audience_fixture)),'former friend loses media');
exception when others then raise exception 'Audience check [former friend loses media] failed: %', SQLERRM;
end $check$;
do $check$ begin
  perform pg_temp.assert_true(public.pulsepath_shared_gpx((select r from audience_fixture)) is null,'former friend loses GPX');
exception when others then raise exception 'Audience check [former friend loses GPX] failed: %', SQLERRM;
end $check$;
reset role;
set local role anon;
select set_config('request.jwt.claim.sub','',true);
do $check$ begin
  perform pg_temp.assert_true((select count(*)=0 from public.community_posts where id in(select p from audience_fixture union all select q from audience_fixture)),'anon sees no community posts');
exception when others then raise exception 'Audience check [anon sees no community posts] failed: %', SQLERRM;
end $check$;
-- A denied SELECT is also a successful anonymous authorization check.
-- Legacy Storage policies may reference chat_messages, which anon cannot SELECT.
do $check$ begin
  perform pg_temp.assert_true((select count(*)=0 from storage.objects where bucket_id='community_private' and name=(select object_path from audience_fixture)),'anon private media denied');
exception
  when insufficient_privilege then raise notice 'PASS: anon private media SELECT denied (42501)';
  when others then raise exception 'Audience check [anon private media denied] failed: %', SQLERRM;
end $check$;
reset role;
rollback;
