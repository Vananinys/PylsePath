-- Read-only production verification: no user records are accessed.
-- Expected: client TRUNCATE=false, service_role TRUNCATE=true.
-- CRUD and RLS must match the baseline captured before the migration.
select c.relname, r.rolname,
       has_table_privilege(r.oid, c.oid, 'TRUNCATE') as can_truncate,
       has_table_privilege(r.oid, c.oid, 'SELECT') as can_select,
       has_table_privilege(r.oid, c.oid, 'INSERT') as can_insert,
       has_table_privilege(r.oid, c.oid, 'UPDATE') as can_update,
       has_table_privilege(r.oid, c.oid, 'DELETE') as can_delete,
       c.relrowsecurity as rls_enabled
from pg_catalog.pg_class c
join pg_catalog.pg_namespace n on n.oid = c.relnamespace
cross join pg_catalog.pg_roles r
where n.nspname = 'public'
  and c.relname in ('rides', 'live_positions', 'fcm_tokens')
  and r.rolname in ('anon', 'authenticated', 'service_role')
order by c.relname, r.rolname;
