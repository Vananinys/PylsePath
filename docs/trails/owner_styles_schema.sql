create table public.profile_trail_styles (
 user_id uuid primary key references auth.users(id) on delete cascade,
 version smallint not null default 1 check (version=1),
 style text not null default 'automatic' check (style in ('automatic','line','footprints','boots','running','nordic','bicycle','mountain','road','gravel','scooter','car','arrows','dots')),
 color_index integer not null default 0 check (color_index between 0 and 11),
 marker_size double precision not null default 10 check (marker_size between 6 and 20),
 spacing double precision not null default 28 check (spacing between 16 and 64),
 opacity double precision not null default 0.85 check (opacity between 0.25 and 1),
 enabled boolean not null default true
);
alter table public.profile_trail_styles enable row level security;
revoke all on public.profile_trail_styles from anon, authenticated;
grant select,insert,update on public.profile_trail_styles to authenticated;
grant all on public.profile_trail_styles to service_role;
create policy owner_or_friend_read on public.profile_trail_styles for select to authenticated
 using (user_id=(select auth.uid()) or exists(select 1 from public.friends f where f.user_id=(select auth.uid()) and f.friend_id=profile_trail_styles.user_id));
create policy owner_insert on public.profile_trail_styles for insert to authenticated with check(user_id=(select auth.uid()));
create policy owner_update on public.profile_trail_styles for update to authenticated using(user_id=(select auth.uid())) with check(user_id=(select auth.uid()));
alter publication supabase_realtime add table public.profile_trail_styles;
notify pgrst,'reload schema';
