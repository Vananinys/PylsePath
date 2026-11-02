-- Combine with uncommitted migration for a rollback-only verification.
begin;
create temp table notice_fixture(a uuid,b uuid,c uuid,p uuid,q uuid,comment_id uuid);
insert into notice_fixture select a.id,b.id,c.id,gen_random_uuid(),gen_random_uuid(),gen_random_uuid()
from public.profiles a cross join public.profiles b cross join public.profiles c
where a.id<>b.id and a.id<>c.id and b.id<>c.id and not exists(select 1 from public.friends f where (f.user_id=a.id and f.friend_id in(b.id,c.id)) or (f.friend_id=a.id and f.user_id in(b.id,c.id))) limit 1;
do $$begin if not exists(select 1 from notice_fixture)then raise exception 'Need three profiles without fixture friendships';end if;end$$;
grant select on notice_fixture to authenticated,anon;
create function pg_temp.notice_assert(ok boolean,stage text) returns void language plpgsql as $$begin if ok is distinct from true then raise exception 'Notice check failed: %',stage;end if;end$$;
insert into public.community_posts(id,author_id,body,audience) select p,a,'PRIVATE_POST_TEXT','friends' from notice_fixture;
insert into public.community_posts(id,author_id,body,audience) select q,c,'FOREIGN_POST','everyone' from notice_fixture;
insert into public.friends(user_id,friend_id) select a,b from notice_fixture union all select b,a from notice_fixture;
insert into public.community_post_likes(post_id,user_id) select p,b from notice_fixture;
insert into public.post_comments(id,post_id,author_id,body) select comment_id,p,b,'PRIVATE_COMMENT_TEXT' from notice_fixture;
select pg_temp.notice_assert((select count(*)=1 from public.community_notifications where recipient_id=(select a from notice_fixture) and kind='like' and reference_id=(select p from notice_fixture)),'like exactly once');
delete from public.community_post_likes where post_id=(select p from notice_fixture) and user_id=(select b from notice_fixture);
insert into public.community_post_likes(post_id,user_id) select p,b from notice_fixture;
select pg_temp.notice_assert((select count(*)=1 from public.community_notifications where recipient_id=(select a from notice_fixture) and kind='like' and reference_id=(select p from notice_fixture)),'repeat like idempotent');
set local role authenticated;
select set_config('request.jwt.claim.sub',(select a::text from notice_fixture),true);
select pg_temp.notice_assert((select count(*)=3 from public.community_notifications where recipient_id=(select a from notice_fixture) and (post_id=(select p from notice_fixture) or kind='friend' and actor_id=(select b from notice_fixture))),'recipient sees own activity');
with updated as(update public.community_posts set body='EDITED_PRIVATE_POST' where id=(select p from notice_fixture) returning id) select pg_temp.notice_assert((select count(*)=1 from updated),'owner update succeeds');
with updated as(update public.community_posts set body='BAD_FOREIGN_EDIT' where id=(select q from notice_fixture) returning id) select pg_temp.notice_assert((select count(*)=0 from updated),'foreign update denied');
do $$begin insert into public.community_notifications(recipient_id,actor_id,kind,reference_id) select a,b,'friend',gen_random_uuid() from notice_fixture;raise exception 'Client forged inbox row';exception when insufficient_privilege then null;end$$;
select set_config('request.jwt.claim.sub',(select c::text from notice_fixture),true);
select pg_temp.notice_assert((select count(*)=0 from public.community_notifications where recipient_id=(select a from notice_fixture)),'stranger cannot read inbox');
reset role;
select pg_temp.notice_assert((select bool_and(public.community_push_allowed(id)) from public.community_notifications where recipient_id=(select a from notice_fixture) and post_id=(select p from notice_fixture)),'visible reaction may dispatch');
update public.community_posts set moderation_hidden_at=now() where id=(select p from notice_fixture);
select pg_temp.notice_assert((select bool_and(not public.community_push_allowed(id)) from public.community_notifications where post_id=(select p from notice_fixture)),'hidden post never dispatches');
update public.community_posts set moderation_hidden_at=null where id=(select p from notice_fixture);
delete from public.friends where (user_id,friend_id) in(select a,b from notice_fixture union all select b,a from notice_fixture);
select pg_temp.notice_assert((select bool_and(not public.community_push_allowed(id)) from public.community_notifications where kind='friend' and recipient_id=(select a from notice_fixture) and actor_id=(select b from notice_fixture)),'removed friendship does not dispatch');
set local role anon;
select set_config('request.jwt.claim.sub','',true);
do $$begin perform count(*) from public.community_notifications;raise exception 'Anonymous inbox SELECT unexpectedly granted';exception when insufficient_privilege then null;end$$;
reset role;
select 'community notifications recipient/stranger/anon, idempotence, moderation, friendship, owner edit checks passed' as result;
rollback;
