-- Lets the page ask "does my account have a recovery code yet?" so it can remind people
-- whose username accounts were brought over from the old JBOIZ site to make one.
-- Run once in the Supabase SQL editor (already included in schema.sql for new projects).

create function public.has_recovery_code() returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from recovery_codes where user_id = auth.uid())
$$;
revoke execute on function public.has_recovery_code() from public, anon;
grant execute on function public.has_recovery_code() to authenticated;
