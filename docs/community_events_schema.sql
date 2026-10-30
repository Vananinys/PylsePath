-- Events, optional feedback and server-issued challenge receipts.
create table public.app_event_creators(user_id uuid primary key references auth.users(id),granted_at timestamptz not null default now());
create table public.app_events(
 id uuid primary key default gen_random_uuid(), creator_id uuid not null references auth.users(id),
 kind text not null check(kind in ('event','challenge','beta')),
 title text not null check(length(title) between 3 and 100),
 description text not null check(length(description)<=3000),
 starts_at timestamptz not null, ends_at timestamptz not null,
 metric text not null default 'rides' check(metric in ('rides','distance_km','minutes','feedback')),
 target numeric not null default 1 check(target>0 and target<=10000),
 xp integer not null default 50 check(xp between 0 and 500),
 badge text not null default 'Участник PulsePath' check(length(badge)<=80),
 archived boolean not null default false, created_at timestamptz not null default now(),
 check(ends_at>starts_at and ends_at<=starts_at+interval '90 days')
);
create table public.app_event_members(
 event_id uuid references public.app_events(id),user_id uuid references auth.users(id),
 joined_at timestamptz not null default now(), primary key(event_id,user_id));
create table public.app_event_feedback(
 event_id uuid,user_id uuid, usability integer not null check(usability between 1 and 5),
 usefulness integer not null check(usefulness between 1 and 5),
 favorite text not null check(length(favorite) between 1 and 100),
 suggestion text not null check(length(suggestion)<=1000),
 updated_at timestamptz not null default now(),primary key(event_id,user_id),
 foreign key(event_id,user_id) references public.app_event_members(event_id,user_id));
create table public.app_event_rewards(
 event_id uuid,user_id uuid,xp integer not null,badge text not null,issued_at timestamptz not null default now(),
 primary key(event_id,user_id),foreign key(event_id,user_id) references public.app_event_members(event_id,user_id));
create index app_events_dates on public.app_events(archived,ends_at);
create index app_event_members_user on public.app_event_members(user_id,event_id);
create index app_event_rewards_user on public.app_event_rewards(user_id);
alter table public.app_event_creators enable row level security;
alter table public.app_events enable row level security;
alter table public.app_event_members enable row level security;
alter table public.app_event_feedback enable row level security;
alter table public.app_event_rewards enable row level security;
revoke all on public.app_event_creators,public.app_events,public.app_event_members,public.app_event_feedback,public.app_event_rewards from anon,authenticated;
grant select on public.app_event_creators,public.app_events,public.app_event_members,public.app_event_feedback,public.app_event_rewards to authenticated;
create policy self_role on public.app_event_creators for select to authenticated using(user_id=(select auth.uid()) or public.is_app_owner());
create policy visible_events on public.app_events for select to authenticated using(not archived or creator_id=(select auth.uid()) or public.is_app_owner());
create policy own_membership on public.app_event_members for select to authenticated using(user_id=(select auth.uid()));
create policy own_feedback on public.app_event_feedback for select to authenticated using(user_id=(select auth.uid()));
create policy own_reward on public.app_event_rewards for select to authenticated using(user_id=(select auth.uid()));

create function app_private.events_action(p_action text,p_data jsonb default '{}'::jsonb) returns jsonb
language plpgsql security definer set search_path='' as $$
declare
 u uuid:=auth.uid(); e public.app_events; eid uuid; target_user uuid;
 own boolean; editor boolean; moderator boolean; joined timestamptz; progress numeric:=0; result jsonb;
begin
 if u is null then raise exception 'Sign in required' using errcode='42501'; end if;
 own:=app_private.is_app_owner();
 moderator:=app_private.is_community_moderator();
 editor:=own or exists(select 1 from public.app_event_creators where user_id=u);
 if p_action='list' then
  return jsonb_build_object('owner',own,'creator',editor,'moderator',moderator,
   'xp',coalesce((select sum(xp) from public.app_event_rewards where user_id=u),0),
   'items',coalesce((select jsonb_agg(rowdata order by ends_at) from (
     select to_jsonb(v)||jsonb_build_object('joined',m.user_id is not null,'earned',r.user_id is not null) as rowdata,v.ends_at
     from public.app_events v left join public.app_event_members m on m.event_id=v.id and m.user_id=u
     left join public.app_event_rewards r on r.event_id=v.id and r.user_id=u
     where not v.archived and v.ends_at>now()-interval '30 days' limit 100
   ) q),'[]'::jsonb));
 elsif p_action='role' then
  if not own then raise exception 'Owner only' using errcode='42501'; end if;
  target_user:=(p_data->>'user_id')::uuid;
  if app_private.is_app_owner() and exists(select 1 from app_private.app_owner where user_id=target_user) then
   raise exception 'Owner role is protected' using errcode='22023'; end if;
  if p_data->>'role'='creator' then
   if (p_data->>'enabled')::boolean then insert into public.app_event_creators(user_id) values(target_user) on conflict do nothing;
   else delete from public.app_event_creators where user_id=target_user; end if;
  elsif p_data->>'role'='moderator' then
   if (p_data->>'enabled')::boolean then insert into app_private.community_moderators(user_id) values(target_user) on conflict do nothing;
   else delete from app_private.community_moderators where user_id=target_user; end if;
  else raise exception 'Invalid role' using errcode='22023'; end if;
  return '{"ok":true}'::jsonb;
 elsif p_action='create' then
  if not editor then raise exception 'Creator permission required' using errcode='42501'; end if;
  if exists(select 1 from app_private.community_bans where user_id=u and revoked_at is null and (expires_at is null or expires_at>now())) then
   raise exception 'Publishing restricted' using errcode='42501'; end if;
  if (select count(*) from public.app_events where creator_id=u and created_at>now()-interval '1 day')>=10 then
   raise exception 'Daily limit' using errcode='22023'; end if;
  insert into public.app_events(creator_id,kind,title,description,starts_at,ends_at,metric,target,xp,badge)
   values(u,p_data->>'kind',trim(p_data->>'title'),trim(p_data->>'description'),
    (p_data->>'starts_at')::timestamptz,(p_data->>'ends_at')::timestamptz,p_data->>'metric',
    (p_data->>'target')::numeric,case when own then (p_data->>'xp')::integer else 50 end,
    case when own then p_data->>'badge' else 'Участник челленджа' end) returning id into eid;
  return jsonb_build_object('id',eid);
 end if;
 eid:=(p_data->>'event_id')::uuid;
 select * into e from public.app_events where id=eid for update;
 if not found then raise exception 'Event not found' using errcode='22023'; end if;
 if p_action='archive' then
  if not (own or moderator or (editor and e.creator_id=u)) then raise exception 'Not allowed' using errcode='42501'; end if;
  update public.app_events set archived=true where id=eid;
  return '{"ok":true}'::jsonb;
 elsif p_action='results' then
  if not (own or e.creator_id=u) then raise exception 'Not allowed' using errcode='42501'; end if;
  return (select jsonb_build_object('answers',count(*),'usability',round(avg(usability),2),
    'usefulness',round(avg(usefulness),2),'feedback',coalesce(jsonb_agg(jsonb_build_object('favorite',favorite,'suggestion',suggestion)),'[]'::jsonb))
    from (select * from public.app_event_feedback where event_id=eid order by updated_at desc limit 200) q);
 end if;
 if e.archived or now()<e.starts_at or now()>e.ends_at then raise exception 'Event not active' using errcode='22023'; end if;
 if p_action='join' then
  insert into public.app_event_members(event_id,user_id) values(eid,u) on conflict do nothing;
  return '{"ok":true}'::jsonb;
 end if;
 select joined_at into joined from public.app_event_members where event_id=eid and user_id=u;
 if joined is null then raise exception 'Join first' using errcode='22023'; end if;
 if p_action='feedback' then
  insert into public.app_event_feedback(event_id,user_id,usability,usefulness,favorite,suggestion)
   values(eid,u,(p_data->>'usability')::integer,(p_data->>'usefulness')::integer,trim(p_data->>'favorite'),trim(p_data->>'suggestion'))
   on conflict(event_id,user_id) do update set usability=excluded.usability,usefulness=excluded.usefulness,
   favorite=excluded.favorite,suggestion=excluded.suggestion,updated_at=now();
  return '{"ok":true}'::jsonb;
 elsif p_action='claim' then
  if e.metric='feedback' then
   select count(*) into progress from public.app_event_feedback where event_id=eid and user_id=u;
  else
   select case e.metric when 'rides' then count(*) when 'distance_km' then coalesce(sum(greatest(0,least(distance_km,500))),0)
    when 'minutes' then coalesce(sum(greatest(0,least(duration_seconds,86400)))/60.0,0) end into progress
   from public.rides where user_id=u and created_at>=greatest(joined,e.starts_at) and created_at<=least(now(),e.ends_at);
  end if;
  if progress>=e.target then
   insert into public.app_event_rewards(event_id,user_id,xp,badge) values(eid,u,e.xp,e.badge) on conflict do nothing;
  end if;
  return jsonb_build_object('progress',progress,'target',e.target,'earned',exists(select 1 from public.app_event_rewards where event_id=eid and user_id=u));
 end if;
 raise exception 'Invalid action' using errcode='22023';
end $$;
revoke all on function app_private.events_action(text,jsonb) from public,anon;
grant usage on schema app_private to authenticated;
grant execute on function app_private.events_action(text,jsonb) to authenticated;
create function public.events_action(p_action text,p_data jsonb default '{}'::jsonb) returns jsonb
language sql security invoker set search_path='' as $$select app_private.events_action(p_action,p_data)$$;
revoke all on function public.events_action(text,jsonb) from public,anon;
grant execute on function public.events_action(text,jsonb) to authenticated;
notify pgrst,'reload schema';
