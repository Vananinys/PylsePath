-- Additive: existing effect enum and permissions remain unchanged.
alter table public.profile_trail_styles add column pulse boolean not null default false;
notify pgrst,'reload schema';
