-- Only UI Beta clients explicitly register support for club notifications.
create table public.club_push_devices(token text primary key,user_id uuid not null references auth.users(id),updated_at timestamptz not null default now());
create index club_push_devices_owner on public.club_push_devices(user_id);
alter table public.club_push_devices enable row level security;
revoke all on public.club_push_devices from public,anon,authenticated;
grant all on public.club_push_devices to service_role;
create policy club_push_devices_internal on public.club_push_devices to authenticated using(false) with check(false);
create function app_private.register_club_push_device(p_token text) returns void language plpgsql security definer set search_path='' as $$
begin
 if auth.uid() is null or not exists(select 1 from public.fcm_tokens where token=p_token and user_id=auth.uid()) then raise exception 'DEVICE_UNAVAILABLE'; end if;
 insert into public.club_push_devices(token,user_id) values(p_token,auth.uid()) on conflict(token) do update set user_id=excluded.user_id,updated_at=now();
end $$;
revoke all on function app_private.register_club_push_device(text) from public,anon;
grant execute on function app_private.register_club_push_device(text) to authenticated;
create function public.register_club_push_device(p_token text) returns void language sql set search_path='' as $$select app_private.register_club_push_device(p_token)$$;
revoke all on function public.register_club_push_device(text) from public,anon;
grant execute on function public.register_club_push_device(text) to authenticated;
