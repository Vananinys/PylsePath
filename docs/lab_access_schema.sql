create table public.app_lab_testers(user_id uuid primary key references auth.users(id),granted_at timestamptz not null default now());
alter table public.app_lab_testers enable row level security;
revoke all on public.app_lab_testers from public,anon,authenticated;
grant select on public.app_lab_testers to authenticated;
create policy own_lab_access on public.app_lab_testers for select to authenticated using(user_id=(select auth.uid()));
create function app_private.my_lab_access() returns jsonb language sql stable security definer set search_path='' as $$
 select jsonb_build_object('is_owner',auth.uid() is not null and app_private.is_app_owner(),
 'can_simulate',auth.uid() is not null and (app_private.is_app_owner() or exists(select 1 from public.app_lab_testers where user_id=auth.uid())))
$$;
revoke all on function app_private.my_lab_access() from public,anon;
grant execute on function app_private.my_lab_access() to authenticated;
create function public.my_lab_access() returns jsonb language sql stable security invoker set search_path='' as $$ select app_private.my_lab_access() $$;
revoke all on function public.my_lab_access() from public,anon;
grant execute on function public.my_lab_access() to authenticated;
notify pgrst,'reload schema';
