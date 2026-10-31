do $$declare definition text;begin
 select pg_get_functiondef(p.oid) into definition from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname='app_private' and p.proname='group_ui_action';
 definition:=replace(definition,'return app_private.group_invite_action(i.id,p_action,coalesce((p_data->>''replace'')::boolean,false));',
 'if p_action=''accept'' and uid=i.receiver_id and room is not null and room<>i.group_id and coalesce((p_data->>''replace'')::boolean,false) then
    perform app_private.group_ui_action(''depart'',jsonb_build_object(''room_id'',room));
  end if;
  return app_private.group_invite_action(i.id,p_action,coalesce((p_data->>''replace'')::boolean,false));');
 execute definition;
end $$;
