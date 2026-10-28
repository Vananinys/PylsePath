alter table public.app_releases add column source_commit text
  check (source_commit is null or source_commit ~ '^[0-9a-f]{40}$');
create table public.app_beta_releases
  (like public.app_releases including defaults including constraints including indexes);
alter table public.app_beta_releases enable row level security;
revoke all on public.app_beta_releases from public, anon, authenticated;
grant select on public.app_beta_releases to anon, authenticated;
grant all on public.app_beta_releases to service_role;
alter table public.app_beta_releases alter column source_commit set not null;
alter table public.app_beta_releases add constraint beta_version_name
  check (version_name ~ '-beta[.][0-9]+$');
create policy app_beta_published_read on public.app_beta_releases
  for select to anon, authenticated using (published_at is not null and published_at <= now());
create trigger app_beta_release_file_guard before insert or update
  on public.app_beta_releases for each row execute function public.pulsepath_check_release_file();
comment on table public.app_beta_releases is
  'Opt-in beta APK catalog. No stable release push trigger; never insert beta builds into app_releases.';
-- Apply after the beta clone, so this constraint applies only to stable rows.
alter table public.app_releases add constraint app_releases_stable_name
  check (version_name !~* '-(alpha|beta|rc)([.-]|$)');
