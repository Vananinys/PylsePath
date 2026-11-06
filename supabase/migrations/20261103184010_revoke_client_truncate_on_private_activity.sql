-- TRUNCATE is table-wide and is not constrained by row-level security.
-- Mobile clients only need row-level CRUD; maintenance keeps service_role.
-- This migration changes privileges only, never reads or removes user rows.
revoke truncate on table public.rides, public.live_positions, public.fcm_tokens
  from public, anon, authenticated;

do $check$
declare
  target regclass;
begin
  foreach target in array array[
    'public.rides'::regclass,
    'public.live_positions'::regclass,
    'public.fcm_tokens'::regclass
  ] loop
    if has_table_privilege('anon', target, 'TRUNCATE')
       or has_table_privilege('authenticated', target, 'TRUNCATE') then
      raise exception 'Client TRUNCATE remains available on %', target;
    end if;
    if not has_table_privilege('service_role', target, 'TRUNCATE') then
      raise exception 'Maintenance TRUNCATE unexpectedly unavailable on %', target;
    end if;
  end loop;
end;
$check$;
