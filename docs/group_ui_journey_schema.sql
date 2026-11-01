-- Additive UI Beta API. Existing clients keep their previous RPCs.
alter table public.group_ride_invitations add column declined_at timestamptz;

create function app_private.group_ui_snapshot() returns jsonb language plpgsql security definer set search_path='' as $$
declare uid uuid:=auth.uid(); room jsonb; invites jsonb;
begin
 if uid is null then raise exception 'AUTH_REQUIRED'; end if;
 room:=public.group_room_snapshot_v2();
 select coalesce(jsonb_agg(to_jsonb(x) order by x.created_at desc),'[]'::jsonb) into invites from (
  select i.id,i.group_id,i.sender_id,i.receiver_id,i.created_at,g.title,
   case when i.sender_id=uid then coalesce(p.username,'Райдер') else coalesce(s.username,'Райдер') end username,
   case when g.closed_at is not null then 'closed' when i.revoked_at is not null then 'revoked'
    when i.declined_at is not null then 'declined' when i.accepted_at is not null or exists(select 1 from app_private.group_sessions peer where peer.user_id=i.receiver_id and peer.group_id=i.group_id) then 'accepted'
    when i.expires_at<=now() then 'expired' else 'pending' end status
  from public.group_ride_invitations i join public.group_rides g on g.id=i.group_id
  left join public.profiles p on p.id=i.receiver_id left join public.profiles s on s.id=i.sender_id
  where (i.receiver_id=uid or (i.sender_id=uid and i.group_id=(room->>'id')::uuid))
   and i.created_at>now()-interval '7 days'
  order by i.created_at desc limit 100) x;
 return jsonb_build_object('room',room,'invitations',invites);
end $$;

create function app_private.group_ui_action(p_action text,p_data jsonb default '{}') returns jsonb language plpgsql security definer set search_path='' as $$
declare uid uuid:=auth.uid(); room uuid; next_host uuid; code text; old jsonb; i public.group_ride_invitations;
begin
 if uid is null then raise exception 'AUTH_REQUIRED'; end if;
 perform pg_advisory_xact_lock(91427,1);
 select s.group_id,g.code into room,code from app_private.group_sessions s join public.group_rides g on g.id=s.group_id where s.user_id=uid;
 if p_action in ('fresh','depart') then
  if room is not null and room<>coalesce((p_data->>'room_id')::uuid,room) then raise exception 'ROOM_CHANGED'; end if;
  if p_action='fresh' and room is not null and coalesce((p_data->>'replace')::boolean,false)=false then raise exception 'REPLACE_REQUIRED'; end if;
  old:=public.group_room_snapshot_v2();
  if room is not null then
   -- Transfer before leaving, so a personal finish never closes other people's ride.
   if exists(select 1 from public.group_rides where id=room and host_id=uid) then
    select user_id into next_host from app_private.group_sessions where group_id=room and user_id<>uid order by user_id limit 1;
    if next_host is not null then
     update public.group_rides set host_id=next_host where id=room;
     update public.group_ride_invitations set revoked_at=coalesce(revoked_at,now()) where group_id=room and accepted_at is null;
    end if;
   end if;
   perform public.group_room_action('leave',code);
  end if;
  if p_action='fresh' then perform public.group_room_action('create',null,false,coalesce(p_data->>'title','Совместная тренировка')); end if;
  return app_private.group_ui_snapshot()||jsonb_build_object('previous',old);
 elsif p_action='invite' then
  if exists(select 1 from app_private.group_sessions where user_id=(p_data->>'receiver_id')::uuid and group_id=room) then raise exception 'ALREADY_JOINED'; end if;
  return app_private.group_send_invite((p_data->>'receiver_id')::uuid,(p_data->>'id')::uuid);
 elsif p_action in ('accept','view','revoke','decline') then
  select * into i from public.group_ride_invitations where id=(p_data->>'id')::uuid and uid in(sender_id,receiver_id);
  if i.id is null then raise exception 'INVITATION_UNAVAILABLE'; end if;
  if p_action='decline' then
   if uid<>i.receiver_id or i.accepted_at is not null then raise exception 'RECIPIENT_REQUIRED'; end if;
   update public.group_ride_invitations set declined_at=coalesce(declined_at,now()) where id=i.id;
   return jsonb_build_object('status','declined');
  end if;
  if i.declined_at is not null and p_action in ('view','accept') then
   if p_action='accept' then raise exception 'INVITATION_UNAVAILABLE'; end if;
   return jsonb_build_object('status','declined','sender_id',i.sender_id,'receiver_id',i.receiver_id);
  end if;
  return app_private.group_invite_action(i.id,p_action,coalesce((p_data->>'replace')::boolean,false));
 else raise exception 'INVALID_ACTION'; end if;
end $$;

revoke all on function app_private.group_ui_snapshot(),app_private.group_ui_action(text,jsonb) from public,anon;
grant execute on function app_private.group_ui_snapshot(),app_private.group_ui_action(text,jsonb) to authenticated;
create function public.group_ui_snapshot() returns jsonb language sql set search_path='' as $$select app_private.group_ui_snapshot()$$;
create function public.group_ui_action(p_action text,p_data jsonb default '{}') returns jsonb language sql set search_path='' as $$select app_private.group_ui_action(p_action,p_data)$$;
revoke all on function public.group_ui_snapshot(),public.group_ui_action(text,jsonb) from public,anon;
grant execute on function public.group_ui_snapshot(),public.group_ui_action(text,jsonb) to authenticated;
