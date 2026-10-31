-- Additive club API. No existing tables, messages or workouts are removed.
create table public.rider_clubs (
 id uuid primary key default gen_random_uuid(), owner_id uuid not null references auth.users(id),
 name text not null check(char_length(name) between 3 and 80),
 description text not null default '' check(char_length(description)<=2000),
 is_open boolean not null default true,
 invite_code text not null unique default replace(gen_random_uuid()::text,'-',''),
 created_at timestamptz not null default now(), archived_at timestamptz
);
create table public.rider_club_members (
 club_id uuid not null references public.rider_clubs(id), user_id uuid not null references auth.users(id),
 role text not null default 'member' check(role in ('member','admin')),
 joined_at timestamptz not null default now(), left_at timestamptz,
 primary key(club_id,user_id)
);
create index rider_club_members_user on public.rider_club_members(user_id,club_id) where left_at is null;
create table public.rider_club_messages (
 id uuid primary key default gen_random_uuid(), club_id uuid not null references public.rider_clubs(id),
 sender_id uuid not null references auth.users(id), body text not null default '' check(char_length(body)<=2000),
 ride_id uuid references public.group_rides(id), created_at timestamptz not null default now()
);
create index rider_club_messages_history on public.rider_club_messages(club_id,created_at desc,id);
create table public.rider_club_events (
 id uuid primary key default gen_random_uuid(), club_id uuid not null references public.rider_clubs(id),
 author_id uuid not null references auth.users(id), title text not null check(char_length(title) between 3 and 100),
 description text not null default '' check(char_length(description)<=2000),
 starts_at timestamptz not null, created_at timestamptz not null default now(), cancelled_at timestamptz
);
create index rider_club_events_time on public.rider_club_events(club_id,starts_at);
create table public.rider_club_event_attendees (
 event_id uuid not null references public.rider_club_events(id), user_id uuid not null references auth.users(id),
 attending boolean not null default true, primary key(event_id,user_id)
);

-- RPC-only tables: clients cannot read private rows or modify membership directly.
alter table public.rider_clubs enable row level security;
alter table public.rider_club_members enable row level security;
alter table public.rider_club_messages enable row level security;
alter table public.rider_club_events enable row level security;
alter table public.rider_club_event_attendees enable row level security;
revoke all on public.rider_clubs,public.rider_club_members,public.rider_club_messages,
 public.rider_club_events,public.rider_club_event_attendees from anon,authenticated;
create policy clubs_rpc_only on public.rider_clubs to authenticated using(false) with check(false);
create policy club_members_rpc_only on public.rider_club_members to authenticated using(false) with check(false);
create policy club_messages_rpc_only on public.rider_club_messages to authenticated using(false) with check(false);
create policy club_events_rpc_only on public.rider_club_events to authenticated using(false) with check(false);
create policy club_attendees_rpc_only on public.rider_club_event_attendees to authenticated using(false) with check(false);

create function app_private.club_action(p_action text,p_club uuid default null,p_data jsonb default '{}')
returns jsonb language plpgsql security definer set search_path='' as $$
declare uid uuid:=auth.uid(); c public.rider_clubs; m public.rider_club_members;
 e public.rider_club_events; msg public.rider_club_messages; g public.group_rides;
 cid uuid:=p_club; target uuid; admin boolean; eid uuid; body text; result jsonb;
begin
 if uid is null then raise exception 'AUTH_REQUIRED'; end if;
 if p_action='home' then
  return coalesce((select jsonb_agg(x.row) from (
   select jsonb_build_object('id',a.id,'name',a.name,'description',a.description,'is_open',a.is_open,
    'member',b.user_id is not null,'role',case when a.owner_id=uid then 'owner' else b.role end,
    'members_count',(select count(*) from public.rider_club_members z where z.club_id=a.id and z.left_at is null)) row
   from public.rider_clubs a left join public.rider_club_members b on b.club_id=a.id and b.user_id=uid and b.left_at is null
   where a.archived_at is null and (a.is_open or b.user_id is not null)
   order by (b.user_id is not null) desc,a.created_at desc limit 200
  ) x),'[]'::jsonb);
 end if;
 -- Serialize membership/ownership transitions, including a join by secret code.
 if p_action not in ('snapshot','messages') then perform pg_advisory_xact_lock(91428,1); end if;
 if p_action='create' then
  cid:=(p_data->>'id')::uuid;
  if not exists(select 1 from public.rider_clubs where id=cid) then
   if (select count(*) from public.rider_clubs where owner_id=uid and created_at>now()-interval '1 day')>=5 then raise exception 'CLUB_RATE_LIMIT'; end if;
   if (select count(*) from public.rider_club_members where user_id=uid and left_at is null)>=50 then raise exception 'CLUB_LIMIT'; end if;
  end if;
  if exists(select 1 from public.rider_clubs where id=cid and owner_id<>uid) then raise exception 'CLUB_ACTION_INVALID'; end if;
  insert into public.rider_clubs(id,owner_id,name,description,is_open)
   values(cid,uid,trim(p_data->>'name'),coalesce(trim(p_data->>'description'),''),coalesce((p_data->>'is_open')::boolean,true)) on conflict(id) do nothing;
  insert into public.rider_club_members(club_id,user_id) values(cid,uid) on conflict do nothing;
 elsif p_action='join_code' then
  select id into cid from public.rider_clubs where invite_code=lower(trim(p_data->>'code')) and archived_at is null;
  if cid is null then raise exception 'CLUB_CODE_INVALID'; end if;
 end if;
 if p_action in ('snapshot','messages') then
  select * into c from public.rider_clubs where id=cid and archived_at is null;
 else
  select * into c from public.rider_clubs where id=cid and archived_at is null for update;
 end if;
 if c.id is null then raise exception 'CLUB_UNAVAILABLE'; end if;
 select * into m from public.rider_club_members where club_id=cid and user_id=uid and left_at is null;
 if p_action in ('join','join_code') then
  if not c.is_open and p_action<>'join_code' then raise exception 'CLUB_INVITE_REQUIRED'; end if;
  if (select count(*) from public.rider_club_members where user_id=uid and left_at is null)>=50 and m.user_id is null then raise exception 'CLUB_LIMIT'; end if;
  insert into public.rider_club_members(club_id,user_id) values(cid,uid)
   on conflict(club_id,user_id) do update set left_at=null,role='member',joined_at=now() where public.rider_club_members.left_at is not null;
  select * into m from public.rider_club_members where club_id=cid and user_id=uid;
 end if;
 if m.user_id is null then
  if p_action='snapshot' and c.is_open then
   return jsonb_build_object('id',c.id,'name',c.name,'description',c.description,'is_open',true,'member',false);
  end if;
  raise exception 'CLUB_MEMBER_REQUIRED';
 end if;
 admin:=c.owner_id=uid or m.role='admin';
 if p_action='leave' then
  if c.owner_id=uid then raise exception 'CLUB_TRANSFER_FIRST'; end if;
  update public.rider_club_members set left_at=now(),role='member' where club_id=cid and user_id=uid;
  return jsonb_build_object('left',true);
 elsif p_action in ('role','transfer','remove') then
  target:=(p_data->>'user_id')::uuid;
  if not exists(select 1 from public.rider_club_members where club_id=cid and user_id=target and left_at is null) then raise exception 'CLUB_MEMBER_REQUIRED'; end if;
  if target=c.owner_id or target=uid then raise exception 'CLUB_ACTION_INVALID'; end if;
  if p_action='remove' then
   if not admin or (c.owner_id<>uid and exists(select 1 from public.rider_club_members where club_id=cid and user_id=target and role='admin')) then raise exception 'CLUB_OWNER_REQUIRED'; end if;
   update public.rider_club_members set left_at=now(),role='member' where club_id=cid and user_id=target;
  else
   if c.owner_id<>uid then raise exception 'CLUB_OWNER_REQUIRED'; end if;
   if p_action='transfer' then update public.rider_clubs set owner_id=target where id=cid; c.owner_id:=target;
   else update public.rider_club_members set role=case when p_data->>'role'='admin' then 'admin' else 'member' end where club_id=cid and user_id=target; end if;
  end if;
 elsif p_action='update' then
  if not admin then raise exception 'CLUB_OWNER_REQUIRED'; end if;
  update public.rider_clubs set name=trim(p_data->>'name'),description=coalesce(trim(p_data->>'description'),''),is_open=(p_data->>'is_open')::boolean where id=cid returning * into c;
 elsif p_action='rotate_code' then
  if c.owner_id<>uid then raise exception 'CLUB_OWNER_REQUIRED'; end if;
  update public.rider_clubs set invite_code=replace(gen_random_uuid()::text,'-','') where id=cid returning * into c;
 elsif p_action in ('message','share_ride') then
  eid:=(p_data->>'id')::uuid;
  select * into msg from public.rider_club_messages where id=eid;
  if msg.id is not null then
   if msg.club_id<>cid or msg.sender_id<>uid then raise exception 'CLUB_ACTION_INVALID'; end if;
  else
   if (select count(*) from public.rider_club_messages where sender_id=uid and created_at>now()-interval '1 minute')>=30 then raise exception 'CLUB_RATE_LIMIT'; end if;
   body:=trim(coalesce(p_data->>'body',''));
   if p_action='share_ride' then
    select r.* into g from public.group_rides r join app_private.group_sessions s on s.group_id=r.id where s.user_id=uid and r.host_id=uid and r.closed_at is null;
    if g.id is null then raise exception 'CLUB_RIDE_HOST_REQUIRED'; end if;
    body:='Приглашаю на совместную тренировку';
   elsif body='' then raise exception 'CLUB_TEXT_REQUIRED'; end if;
   insert into public.rider_club_messages(id,club_id,sender_id,body,ride_id) values(eid,cid,uid,body,g.id);
  end if;
 elsif p_action='join_ride' then
  select r.* into g from public.group_rides r join public.rider_club_messages x on x.ride_id=r.id where x.id=(p_data->>'id')::uuid and x.club_id=cid and r.closed_at is null;
  if g.id is null then raise exception 'CLUB_RIDE_CLOSED'; end if;
  -- Keep the existing group serialization and replacement confirmation semantics.
  result:=app_private.group_action('join',g.code,coalesce((p_data->>'replace')::boolean,false));
  return jsonb_build_object('room_id',g.id);
 elsif p_action='event_create' then
  eid:=(p_data->>'id')::uuid;
  if exists(select 1 from public.rider_club_events where id=eid and (club_id<>cid or author_id<>uid)) then raise exception 'CLUB_ACTION_INVALID'; end if;
  if not exists(select 1 from public.rider_club_events where id=eid) and (select count(*) from public.rider_club_events where author_id=uid and created_at>now()-interval '1 day')>=20 then raise exception 'CLUB_RATE_LIMIT'; end if;
  if (p_data->>'starts_at')::timestamptz<now() or (p_data->>'starts_at')::timestamptz>now()+interval '2 years' then raise exception 'CLUB_EVENT_TIME'; end if;
  insert into public.rider_club_events(id,club_id,author_id,title,description,starts_at)
   values(eid,cid,uid,trim(p_data->>'title'),coalesce(trim(p_data->>'description'),''),(p_data->>'starts_at')::timestamptz)
   on conflict(id) do nothing;
 elsif p_action in ('event_attend','event_cancel') then
  select * into e from public.rider_club_events where id=(p_data->>'id')::uuid and club_id=cid;
  if e.id is null then raise exception 'CLUB_ACTION_INVALID'; end if;
  if p_action='event_cancel' then
   if not admin and e.author_id<>uid then raise exception 'CLUB_OWNER_REQUIRED'; end if;
   update public.rider_club_events set cancelled_at=coalesce(cancelled_at,now()) where id=e.id;
  else
   if e.cancelled_at is not null or e.starts_at<now() then raise exception 'CLUB_EVENT_CLOSED'; end if;
   insert into public.rider_club_event_attendees(event_id,user_id,attending) values(e.id,uid,(p_data->>'attending')::boolean)
    on conflict(event_id,user_id) do update set attending=excluded.attending;
  end if;
 elsif p_action not in ('create','join','join_code','snapshot','messages') then raise exception 'CLUB_ACTION_INVALID';
 end if;
 if p_action='messages' then
  return coalesce((select jsonb_agg(to_jsonb(x) order by x.created_at,x.id) from (
   select a.id,a.body,a.ride_id,a.created_at,a.sender_id,p.username,(r.id is not null and r.closed_at is null) ride_open
   from public.rider_club_messages a left join public.profiles p on p.id=a.sender_id left join public.group_rides r on r.id=a.ride_id
   where a.club_id=cid and (p_data->>'before' is null or a.created_at<(p_data->>'before')::timestamptz)
   order by a.created_at desc,a.id desc limit 50) x),'[]'::jsonb);
 end if;
 return jsonb_build_object('id',c.id,'name',c.name,'description',c.description,'is_open',c.is_open,'member',true,
  'owner_id',c.owner_id,'role',case when c.owner_id=uid then 'owner' else m.role end,
  'invite_code',case when admin then c.invite_code else null end,
  'members',coalesce((select jsonb_agg(jsonb_build_object('user_id',a.user_id,'username',p.username,'role',case when a.user_id=c.owner_id then 'owner' else a.role end) order by a.joined_at) from public.rider_club_members a left join public.profiles p on p.id=a.user_id where a.club_id=cid and a.left_at is null),'[]'::jsonb),
  'messages',app_private.club_action('messages',cid),
  'events',coalesce((select jsonb_agg(to_jsonb(x) order by x.starts_at) from (
   select a.*,exists(select 1 from public.rider_club_event_attendees z where z.event_id=a.id and z.user_id=uid and z.attending) attending,
    coalesce((select jsonb_agg(jsonb_build_object('user_id',z.user_id,'username',p.username)) from public.rider_club_event_attendees z join public.rider_club_members cm on cm.club_id=cid and cm.user_id=z.user_id and cm.left_at is null left join public.profiles p on p.id=z.user_id where z.event_id=a.id and z.attending),'[]'::jsonb) attendees
   from public.rider_club_events a where a.club_id=cid order by a.starts_at desc limit 100) x),'[]'::jsonb));
end $$;
revoke all on function app_private.club_action(text,uuid,jsonb) from public,anon;
grant execute on function app_private.club_action(text,uuid,jsonb) to authenticated;
create function public.club_action(p_action text,p_club uuid default null,p_data jsonb default '{}')
returns jsonb language sql set search_path='' as $$select app_private.club_action(p_action,p_club,p_data)$$;
revoke all on function public.club_action(text,uuid,jsonb) from public,anon;
grant execute on function public.club_action(text,uuid,jsonb) to authenticated;
