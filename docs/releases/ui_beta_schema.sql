-- Separate Android application: com.pulsepath.app (PulsePath UI Beta).
-- No UI beta artifact is inserted into the regular stable/beta catalogs.
create table public.app_ui_beta_releases
  (like public.app_beta_releases including defaults including constraints including indexes);
alter table public.app_ui_beta_releases enable row level security;
revoke all on public.app_ui_beta_releases from public, anon, authenticated;
grant select on public.app_ui_beta_releases to anon, authenticated;
grant all on public.app_ui_beta_releases to service_role;
create policy ui_beta_published_read on public.app_ui_beta_releases
  for select to anon, authenticated using (published_at is not null and published_at <= now());
create trigger ui_beta_release_file_guard before insert or update
  on public.app_ui_beta_releases for each row execute function public.pulsepath_check_release_file();

create table public.app_ui_beta_release_push_outbox
  (like public.app_release_push_outbox including defaults including constraints including indexes);
alter table public.app_ui_beta_release_push_outbox
  add constraint ui_beta_outbox_release_fk foreign key (version_code)
  references public.app_ui_beta_releases(version_code);
alter table public.app_ui_beta_release_push_outbox enable row level security;
revoke all on public.app_ui_beta_release_push_outbox from public, anon, authenticated;
grant all on public.app_ui_beta_release_push_outbox to service_role;
create policy ui_beta_outbox_client_denied on public.app_ui_beta_release_push_outbox
  for all to anon, authenticated using (false) with check (false);

-- Clone the currently deployed, reviewed dispatch/claim/retry behavior.
-- Definitions keep SECURITY DEFINER and search_path='', and only the internal
-- catalog, outbox, RPC names and fixed destination endpoint are substituted.
do $$
declare signature text; definition text;
begin
  foreach signature in array array[
    'public.pulsepath_dispatch_release_push(integer)',
    'public.pulsepath_claim_release_push(integer)',
    'public.pulsepath_notify_release()',
    'public.pulsepath_retry_release_push()'
  ] loop
    definition := pg_get_functiondef(signature::regprocedure);
    definition := replace(definition, 'pulsepath_dispatch_release_push', 'pulsepath_dispatch_ui_beta_release_push');
    definition := replace(definition, 'pulsepath_claim_release_push', 'pulsepath_claim_ui_beta_release_push');
    definition := replace(definition, 'pulsepath_notify_release', 'pulsepath_notify_ui_beta_release');
    definition := replace(definition, 'pulsepath_retry_release_push', 'pulsepath_retry_ui_beta_release_push');
    definition := replace(definition, 'app_release_push_outbox', 'app_ui_beta_release_push_outbox');
    definition := replace(definition, '/send-release-push', '/send-ui-beta-release-push');
    execute definition;
  end loop;
end;
$$;

revoke all on function public.pulsepath_dispatch_ui_beta_release_push(integer) from public, anon, authenticated;
revoke all on function public.pulsepath_claim_ui_beta_release_push(integer) from public, anon, authenticated;
revoke all on function public.pulsepath_notify_ui_beta_release() from public, anon, authenticated;
revoke all on function public.pulsepath_retry_ui_beta_release_push() from public, anon, authenticated;
grant execute on function public.pulsepath_dispatch_ui_beta_release_push(integer) to service_role;
grant execute on function public.pulsepath_claim_ui_beta_release_push(integer) to service_role;
grant execute on function public.pulsepath_retry_ui_beta_release_push() to service_role;
create trigger ui_beta_release_publish_push after insert or update of published_at
  on public.app_ui_beta_releases for each row execute function public.pulsepath_notify_ui_beta_release();
select cron.schedule('ui-beta-release-push-retry', '* * * * *', 'select public.pulsepath_retry_ui_beta_release_push();');
comment on table public.app_ui_beta_releases is
  'APK catalog for the separate PulsePath UI Beta app; never consumed by regular PulsePath.';
