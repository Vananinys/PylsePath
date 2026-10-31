do $$declare definition text;begin
 select pg_get_functiondef(p.oid) into definition from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname='app_private' and p.proname='club_action';
 definition:=replace(definition,'member public.rider_club_members;','member public.rider_club_members; current_room uuid; target_room uuid;');
 definition:=replace(definition,'if p_action in (''notifications'',''read'') then',
 'if p_action=''join_ride'' then
    perform pg_advisory_xact_lock(91428,1);
    if not exists(select 1 from public.rider_club_members where club_id=p_club and user_id=uid and left_at is null) then raise exception ''CLUB_MEMBER_REQUIRED'';end if;
    select group_id into current_room from app_private.group_sessions where user_id=uid;
    select x.ride_id into target_room from public.rider_club_messages x join public.group_rides g on g.id=x.ride_id where x.id=(p_data->>''id'')::uuid and x.club_id=p_club and g.closed_at is null;
    if target_room is not null and current_room is not null and target_room<>current_room and coalesce((p_data->>''replace'')::boolean,false) then
      perform app_private.group_ui_action(''depart'',jsonb_build_object(''room_id'',current_room));
    end if;
  elsif p_action=''share_ride'' and p_data->>''room_id'' is not null then
    if not exists(select 1 from app_private.group_sessions where user_id=uid and group_id=(p_data->>''room_id'')::uuid) then raise exception ''CLUB_RIDE_CHANGED''; end if;
  end if;
  if p_action in (''notifications'',''read'') then');
 execute definition;
end $$;
