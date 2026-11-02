create policy community_outbox_internal on public.community_push_outbox to authenticated using(false) with check(false);
create policy community_deliveries_internal on public.community_push_deliveries to authenticated using(false) with check(false);
create policy community_devices_internal on public.community_push_devices to authenticated using(false) with check(false);
alter function public.register_community_push_device(text) set schema app_private;
revoke all on function app_private.register_community_push_device(text) from public,anon;
grant execute on function app_private.register_community_push_device(text) to authenticated;
create function public.register_community_push_device(p_token text) returns void language sql set search_path='' as $$select app_private.register_community_push_device(p_token)$$;
revoke all on function public.register_community_push_device(text) from public,anon;
grant execute on function public.register_community_push_device(text) to authenticated;
