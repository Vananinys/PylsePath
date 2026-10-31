-- The sender belongs to the ride already; that must not mean the invitee accepted.
do $$declare definition text;begin
 select pg_get_functiondef(p.oid) into definition from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname='app_private' and p.proname='group_ui_action';
 definition:=replace(definition,'return app_private.group_invite_action(i.id,p_action,coalesce((p_data->>''replace'')::boolean,false));',
 'if p_action=''view'' and uid=i.sender_id and not exists(select 1 from app_private.group_sessions peer where peer.user_id=i.receiver_id and peer.group_id=i.group_id) and i.accepted_at is null and i.revoked_at is null and i.expires_at>now() and exists(select 1 from public.group_rides where id=i.group_id and closed_at is null) then
    return app_private.group_invite_action(i.id,p_action,false)||jsonb_build_object(''status'',''active'');
  end if;
  return app_private.group_invite_action(i.id,p_action,coalesce((p_data->>''replace'')::boolean,false));');
 execute definition;
end $$;
