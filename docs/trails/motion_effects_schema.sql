-- Applied 2026-10-30: additive, existing choices and RLS preserved.
alter table public.profile_trail_styles add column effect text not null default 'none'
 check(effect in ('none','ember','confetti','orbit','pixel','bloom'));
notify pgrst,'reload schema';
