-- Username + password accounts with a recovery code (no email involved).
-- Run once in the Supabase SQL editor (already included in schema.sql for new projects).
--
-- Supabase needs an email behind every password account, so a username is stored as
-- <username>@users.bravepop.app. Nothing is ever sent there. Supabase's Email provider must be
-- on, with "Confirm email" off.
--
-- At sign-up the page asks for a recovery code and shows it once. With their username and that
-- code, anyone can set a new password themselves. Only a scrambled copy of the code is kept.

create table public.recovery_codes (
  user_id      uuid primary key references auth.users (id) on delete cascade,
  code_hash    text not null,
  failed       int not null default 0,   -- wrong tries since the last lockout
  locked_until timestamptz,
  created_at   timestamptz not null default now()
);
-- No access rules on purpose: only the functions below can read or change it.
alter table public.recovery_codes enable row level security;
revoke all on public.recovery_codes from anon, authenticated;

-- 20 characters (100 bits) from an alphabet without look-alikes, shown as XXXX-XXXX-XXXX-XXXX-XXXX.
create function public.new_recovery_code() returns text
language plpgsql volatile set search_path = public, extensions as $$
declare
  a text := 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
  b bytea := gen_random_bytes(20);
  s text := '';
begin
  for i in 0..19 loop
    s := s || substr(a, (get_byte(b, i) % 32) + 1, 1);
    if i % 4 = 3 and i < 19 then s := s || '-'; end if;
  end loop;
  return s;
end;
$$;

-- Typed codes are compared without dashes, spaces or case.
create function public.clean_recovery_code(code text) returns text
language sql immutable as $$
  select upper(regexp_replace(coalesce(code, ''), '[^A-Za-z0-9]', '', 'g'))
$$;

-- Make (or replace) the signed-in person's recovery code. Returned once, never stored readable.
create function public.make_recovery_code() returns text
language plpgsql security definer set search_path = public, extensions as $$
declare code text;
begin
  if auth.uid() is null then raise exception 'Sign in first.' using errcode = 'P0001'; end if;
  code := new_recovery_code();
  insert into recovery_codes (user_id, code_hash) values (auth.uid(), crypt(clean_recovery_code(code), gen_salt('bf')))
  on conflict (user_id) do update set code_hash = excluded.code_hash, failed = 0, locked_until = null, created_at = now();
  return code;
end;
$$;

-- Set a new password with a username and recovery code. The code is used up: the answer carries a
-- fresh one to save. Five wrong codes lock that username's resets for 15 minutes.
-- Answers {"ok": true, "code": "..."} or {"ok": false, "error": "..."}.
create function public.reset_password(username text, code text, new_password text) returns jsonb
language plpgsql security definer set search_path = public, extensions, auth as $$
declare
  u uuid;
  r recovery_codes;
  fresh text;
  nope constant jsonb := jsonb_build_object('ok', false, 'error', 'That username and recovery code don''t match.');
begin
  if char_length(coalesce(new_password, '')) < 8 then
    return jsonb_build_object('ok', false, 'error', 'Use at least 8 characters for the new password.');
  end if;
  select id into u from auth.users where email = lower(btrim(username)) || '@users.bravepop.app';
  if u is null then return nope; end if;
  select * into r from recovery_codes where user_id = u;
  if r.user_id is null then return nope; end if;
  if r.locked_until > now() then
    return jsonb_build_object('ok', false, 'error', 'Too many wrong tries. Wait 15 minutes and try again.');
  end if;
  if r.code_hash <> crypt(clean_recovery_code(code), r.code_hash) then
    update recovery_codes
    set failed = case when failed + 1 >= 5 then 0 else failed + 1 end,
        locked_until = case when failed + 1 >= 5 then now() + interval '15 minutes' end
    where user_id = u;
    return nope;
  end if;
  update auth.users set encrypted_password = crypt(new_password, gen_salt('bf')), updated_at = now() where id = u;
  delete from auth.sessions where user_id = u;   -- sign out everywhere else
  fresh := new_recovery_code();
  update recovery_codes set code_hash = crypt(clean_recovery_code(fresh), gen_salt('bf')), failed = 0, locked_until = null, created_at = now()
  where user_id = u;
  return jsonb_build_object('ok', true, 'code', fresh);
end;
$$;

revoke execute on function public.new_recovery_code(), public.clean_recovery_code(text),
  public.make_recovery_code(), public.reset_password(text, text, text) from public, anon, authenticated;
grant execute on function public.make_recovery_code() to authenticated;
grant execute on function public.reset_password(text, text, text) to anon, authenticated;
