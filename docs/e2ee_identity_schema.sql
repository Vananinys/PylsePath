-- Additive identity registry. Does not enable E2EE or block existing clients.
-- Apply only together with the completed client rollout.
begin;
create table if not exists public.e2ee_identities (
  user_id uuid primary key references auth.users(id) on delete cascade,
  public_key text not null check (length(public_key)=44),
  created_at timestamptz not null default now()
);
create table if not exists public.e2ee_recovery_backups (
  user_id uuid primary key references public.e2ee_identities(user_id) on delete cascade,
  envelope text not null check (octet_length(envelope) between 64 and 16384),
  created_at timestamptz not null default now()
);
alter table public.e2ee_identities enable row level security;
alter table public.e2ee_recovery_backups enable row level security;
create policy e2ee_public_identity_read on public.e2ee_identities
  for select to authenticated using (
    user_id=(select auth.uid()) or exists(select 1 from public.friends f
      where f.user_id=(select auth.uid()) and f.friend_id=e2ee_identities.user_id)
    or exists(select 1 from public.chat_messages m where
      (m.sender_id=(select auth.uid()) and m.receiver_id=e2ee_identities.user_id) or
      (m.receiver_id=(select auth.uid()) and m.sender_id=e2ee_identities.user_id))
  );
create policy e2ee_own_backup_read on public.e2ee_recovery_backups
  for select to authenticated using (user_id=(select auth.uid()));
revoke all on public.e2ee_identities,public.e2ee_recovery_backups from anon,authenticated;
grant select on public.e2ee_identities,public.e2ee_recovery_backups to authenticated;
create or replace function public.e2ee_register_identity(p_public_key text,p_backup text)
returns void language plpgsql security definer set search_path='' as $$
declare actor uuid:=auth.uid(); existing text;
begin
  if actor is null then raise exception 'AUTH_REQUIRED' using errcode='42501'; end if;
  if length(p_public_key)<>44 or p_public_key !~ '^[A-Za-z0-9_-]{43}=$'
    or octet_length(p_backup) not between 64 and 16384 then
    raise exception 'INVALID_IDENTITY';
  end if;
  perform pg_advisory_xact_lock(hashtextextended(actor::text,90841));
  select public_key into existing from public.e2ee_identities where user_id=actor;
  if existing is not null then
    if existing<>p_public_key then raise exception 'IDENTITY_IMMUTABLE'; end if;
    return;
  end if;
  -- Identity and encrypted backup are committed together, never separately.
  insert into public.e2ee_identities(user_id,public_key) values(actor,p_public_key);
  insert into public.e2ee_recovery_backups(user_id,envelope) values(actor,p_backup);
end $$;
revoke all on function public.e2ee_register_identity(text,text) from public,anon;
grant execute on function public.e2ee_register_identity(text,text) to authenticated;
commit;
