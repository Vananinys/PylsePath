create table app_private.group_ui_requests(user_id uuid not null references auth.users(id),request_id uuid not null,room_id uuid not null references public.group_rides(id),created_at timestamptz not null default now(),primary key(user_id,request_id));
alter table app_private.group_ui_requests enable row level security;
revoke all on app_private.group_ui_requests from public,anon,authenticated;
create policy group_ui_requests_internal on app_private.group_ui_requests to authenticated using(false) with check(false);
-- Preserve the old API's authorization checks, including refusal after decline.
do $$declare definition text;begin
 select pg_get_functiondef(p.oid) into definition from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname='app_private' and p.proname='group_invite_action';
 definition:=replace(definition,'when inv.revoked_at is not null then ''revoked''','when inv.revoked_at is not null then ''revoked'' when inv.declined_at is not null then ''declined''');
 execute definition;
end $$;
-- Add durable idempotence to creating a fresh ride.
do $$declare definition text;begin
 select pg_get_functiondef(p.oid) into definition from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname='app_private' and p.proname='group_ui_action';
 definition:=replace(definition,'old jsonb; i public.group_ride_invitations;','old jsonb; i public.group_ride_invitations; intent_id uuid; result_room uuid;');
 definition:=replace(definition,'if p_action in (''fresh'',''depart'') then',
 'if p_action=''fresh'' then
   intent_id:=coalesce((p_data->>''request_id'')::uuid,gen_random_uuid());
   select r.room_id into result_room from app_private.group_ui_requests r where r.user_id=uid and r.request_id=intent_id;
   if result_room is not null then
     if result_room is distinct from room then raise exception ''ROOM_CHANGED''; end if;
     return app_private.group_ui_snapshot();
   end if;
  end if;
  if p_action in (''fresh'',''depart'') then');
 definition:=replace(definition,'return app_private.group_ui_snapshot()||jsonb_build_object(''previous'',old);',
 'if p_action=''fresh'' then
    select group_id into result_room from app_private.group_sessions where user_id=uid;
    insert into app_private.group_ui_requests(user_id,request_id,room_id) values(uid,intent_id,result_room);
  end if;
  return app_private.group_ui_snapshot()||jsonb_build_object(''previous'',old);');
 execute definition;
end $$;
