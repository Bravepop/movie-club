-- Movie Club: tables, access rules, club management and live updates.
-- Run once in a fresh Supabase project's SQL editor.
--
-- Everything belongs to a club. Only a club's members can see or change anything in it.
-- Inside a club, screenings are identified by date and members by name, as in the original
-- single-club site; every key and reference carries the club id alongside them.

/* ---------------------------------------------------------------- tables */

create table public.clubs (
  id             uuid primary key default gen_random_uuid(),
  slug           text not null unique check (slug ~ '^[a-z0-9-]{3,48}$'),
  name           text not null check (char_length(btrim(name)) between 1 and 60),
  invite_code    text not null unique default substr(replace(gen_random_uuid()::text, '-', ''), 1, 12),
  schedule_note  text check (char_length(schedule_note) <= 200),
  created_by     uuid references auth.users (id) on delete set null,
  created_at     timestamptz not null default now()
);

-- A member is a name in a club. user_id links the name to a login; it is empty for a
-- name the admin added that nobody has claimed yet (claimed from the invite page).
create table public.members (
  club_id     uuid not null references public.clubs (id) on delete cascade,
  name        text not null check (char_length(btrim(name)) between 1 and 30 and name !~ '&'),
  user_id     uuid references auth.users (id) on delete set null,
  pick_order  int,            -- null = not in the pick rotation (guest critic)
  role        text not null default 'member' check (role in ('admin', 'member')),
  created_at  timestamptz not null default now(),
  primary key (club_id, name),
  unique (club_id, user_id)
);

-- One row per screening date.
create table public.slots (
  club_id   uuid not null references public.clubs (id) on delete cascade,
  date      date not null,
  title     text check (char_length(title) <= 200),
  director  text check (char_length(director) <= 200),
  genre     text check (char_length(genre) <= 200),
  mins      int check (mins > 0),
  imdb      text check (imdb ~ '^tt[0-9]{5,10}$'),
  poster    text check (poster is null or poster = 'none' or poster ~ '^https://'),
  picker    text not null check (char_length(picker) <= 100),
  watched   boolean not null default false,
  primary key (club_id, date)
);

create table public.ratings (
  club_id     uuid not null,
  slot        date not null,
  member      text not null,
  score       smallint not null check (score between 1 and 5),
  review      text check (char_length(review) <= 200),
  updated_at  timestamptz not null default now(),
  primary key (club_id, slot, member),
  foreign key (club_id, slot) references public.slots (club_id, date) on delete cascade,
  foreign key (club_id, member) references public.members (club_id, name) on update cascade on delete cascade
);

-- Screenings a member missed. auto = marked by the daily job, not by the member.
create table public.absences (
  club_id     uuid not null,
  slot        date not null,
  member      text not null,
  auto        boolean not null default false,
  created_at  timestamptz not null default now(),
  primary key (club_id, slot, member),
  foreign key (club_id, slot) references public.slots (club_id, date) on delete cascade,
  foreign key (club_id, member) references public.members (club_id, name) on update cascade on delete cascade
);

-- Upvotes and downvotes on reviews.
create table public.review_votes (
  club_id     uuid not null,
  slot        date not null,
  author      text not null,
  voter       text not null,
  value       smallint not null check (value in (-1, 1)),
  created_at  timestamptz not null default now(),
  primary key (club_id, slot, author, voter),
  foreign key (club_id, slot, author) references public.ratings (club_id, slot, member) on update cascade on delete cascade,
  foreign key (club_id, voter) references public.members (club_id, name) on update cascade on delete cascade,
  check (voter <> author)
);

-- Party mode: images members drop onto the page. x and w are fractions of the page width;
-- y is pixels from the top. The file lives in the private "party" bucket at <club id>/<file>.
create table public.stickers (
  id          uuid primary key default gen_random_uuid(),
  club_id     uuid not null references public.clubs (id) on delete cascade,
  path        text not null,
  tab         text not null default 'next',
  x           real not null,
  y           real not null,
  w           real not null,
  z           int not null default 0,
  added_by    text,
  created_at  timestamptz not null default now(),
  foreign key (club_id, added_by) references public.members (club_id, name) on update cascade on delete set null (added_by),
  check (path like club_id::text || '/%')
);

-- Personal watchlists: films someone wants to pick someday. Private, and shared across all
-- of that person's clubs.
create table public.watchlist (
  id        bigint generated always as identity primary key,
  user_id   uuid not null default auth.uid() references auth.users (id) on delete cascade,
  tmdb_id   integer not null,
  title     text not null check (char_length(title) <= 200),
  year      text check (char_length(year) <= 10),
  poster    text check (char_length(poster) <= 300),
  added_at  timestamptz not null default now(),
  unique (user_id, tmdb_id)
);

create index on public.members (user_id);
create index on public.stickers (club_id);

/* ---------------------------------------------------------------- limits */

-- Keeps one person or club from filling up the free database.
create function public.enforce_limits() returns trigger
language plpgsql security definer set search_path = public as $$
declare n int;
begin
  if tg_table_name = 'clubs' then
    select count(*) into n from clubs where created_by = new.created_by;
    if n >= 5 then raise exception 'You can create up to 5 clubs.' using errcode = 'P0001'; end if;
  elsif tg_table_name = 'members' then
    if tg_op = 'INSERT' then
      select count(*) into n from members where club_id = new.club_id;
      if n >= 40 then raise exception 'A club can have up to 40 members.' using errcode = 'P0001'; end if;
    end if;
    if new.user_id is not null and (tg_op = 'INSERT' or old.user_id is distinct from new.user_id) then
      select count(*) into n from members where user_id = new.user_id;
      if n >= 20 then raise exception 'You can be in up to 20 clubs.' using errcode = 'P0001'; end if;
    end if;
  elsif tg_table_name = 'slots' then
    select count(*) into n from slots where club_id = new.club_id;
    if n >= 1500 then raise exception 'A club can have up to 1,500 screenings.' using errcode = 'P0001'; end if;
  elsif tg_table_name = 'stickers' then
    select count(*) into n from stickers where club_id = new.club_id;
    if n >= 60 then raise exception 'A club can have up to 60 party images. Remove some first.' using errcode = 'P0001'; end if;
  elsif tg_table_name = 'watchlist' then
    select count(*) into n from watchlist where user_id = new.user_id;
    if n >= 300 then raise exception 'Your watchlist is full (300 films).' using errcode = 'P0001'; end if;
  end if;
  return new;
end;
$$;
create trigger clubs_limit     before insert on public.clubs     for each row execute function public.enforce_limits();
create trigger members_limit   before insert or update of user_id on public.members for each row execute function public.enforce_limits();
create trigger slots_limit     before insert on public.slots     for each row execute function public.enforce_limits();
create trigger stickers_limit  before insert on public.stickers  for each row execute function public.enforce_limits();
create trigger watchlist_limit before insert on public.watchlist for each row execute function public.enforce_limits();

/* ---------------------------------------------------------------- who am I */

-- Is the logged-in person a member (or admin) of this club? Their name in it, or null.
create function public.is_member(c uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from members where club_id = c and user_id = auth.uid())
$$;
create function public.is_admin(c uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from members where club_id = c and user_id = auth.uid() and role = 'admin')
$$;
create function public.my_name(c uuid) returns text
language sql stable security definer set search_path = public as $$
  select name from members where club_id = c and user_id = auth.uid()
$$;

/* ---------------------------------------------------------------- access rules */

alter table public.clubs        enable row level security;
alter table public.members      enable row level security;
alter table public.slots        enable row level security;
alter table public.ratings      enable row level security;
alter table public.absences     enable row level security;
alter table public.review_votes enable row level security;
alter table public.stickers     enable row level security;
alter table public.watchlist    enable row level security;

-- Only members see a club and anything in it. Club and member changes go through the
-- functions further down, which check who is asking.
create policy "Members see their club"   on public.clubs        for select to authenticated using (public.is_member(id));
create policy "Members see members"      on public.members      for select to authenticated using (public.is_member(club_id));
create policy "Members see screenings"   on public.slots        for select to authenticated using (public.is_member(club_id));
create policy "Members see ratings"      on public.ratings      for select to authenticated using (public.is_member(club_id));
create policy "Members see absences"     on public.absences     for select to authenticated using (public.is_member(club_id));
create policy "Members see votes"        on public.review_votes for select to authenticated using (public.is_member(club_id));
create policy "Members see stickers"     on public.stickers     for select to authenticated using (public.is_member(club_id));

-- Any member can fill in or edit a screening (adding and removing dates is for admins).
create policy "Members edit screenings" on public.slots for update to authenticated
  using (public.is_member(club_id)) with check (public.is_member(club_id));

-- Members rate only as themselves, and only films the club has watched.
create policy "Members add their own rating" on public.ratings for insert to authenticated
  with check (member = public.my_name(club_id)
    and exists (select 1 from public.slots s where s.club_id = ratings.club_id and s.date = slot and s.watched));
create policy "Members change their own rating" on public.ratings for update to authenticated
  using (member = public.my_name(club_id)) with check (member = public.my_name(club_id));
create policy "Members remove their own rating" on public.ratings for delete to authenticated
  using (member = public.my_name(club_id));

create policy "Members record their own absence" on public.absences for insert to authenticated
  with check (member = public.my_name(club_id) and not auto);
create policy "Members remove their own absence" on public.absences for delete to authenticated
  using (member = public.my_name(club_id));

create policy "Members vote" on public.review_votes for insert to authenticated
  with check (voter = public.my_name(club_id));
create policy "Members change their vote" on public.review_votes for update to authenticated
  using (voter = public.my_name(club_id)) with check (voter = public.my_name(club_id));
create policy "Members take back their vote" on public.review_votes for delete to authenticated
  using (voter = public.my_name(club_id));

-- Like the old spreadsheet, any member can add, move, resize or remove any image.
create policy "Members add stickers" on public.stickers for insert to authenticated
  with check (added_by = public.my_name(club_id));
create policy "Members move stickers" on public.stickers for update to authenticated
  using (public.is_member(club_id)) with check (public.is_member(club_id));
create policy "Members remove stickers" on public.stickers for delete to authenticated
  using (public.is_member(club_id));

create policy "People see their own watchlist" on public.watchlist for select to authenticated
  using (user_id = auth.uid());
create policy "People add to their watchlist" on public.watchlist for insert to authenticated
  with check (user_id = auth.uid());
create policy "People remove from their watchlist" on public.watchlist for delete to authenticated
  using (user_id = auth.uid());

-- Logged-out visitors get nothing.
revoke all on public.clubs, public.members, public.slots, public.ratings, public.absences,
  public.review_votes, public.stickers, public.watchlist from anon;
grant select on public.clubs, public.members, public.slots, public.ratings, public.absences,
  public.review_votes, public.stickers, public.watchlist to authenticated;
grant update (title, director, genre, mins, imdb, poster, picker, watched) on public.slots to authenticated;
grant insert, update, delete on public.ratings, public.review_votes to authenticated;
grant insert, delete on public.absences to authenticated;
grant insert, delete on public.stickers to authenticated;
grant update (tab, x, y, w, z) on public.stickers to authenticated;
grant insert, delete on public.watchlist to authenticated;

/* ---------------------------------------------------------------- clubs: create and join */

-- A URL-friendly id from the club name, plus a random tail so it can't be guessed.
create function public.make_slug(n text) returns text
language sql volatile set search_path = public as $$
  select coalesce(nullif(left(trim(both '-' from regexp_replace(lower(n), '[^a-z0-9]+', '-', 'g')), 32), ''), 'club')
    || '-' || substr(replace(gen_random_uuid()::text, '-', ''), 1, 6)
$$;

-- Start a club. The creator is its admin and first in the pick order. Returns the club's slug.
create function public.create_club(club_name text, my_name text) returns text
language plpgsql security definer set search_path = public as $$
declare c uuid; s text;
begin
  if auth.uid() is null then raise exception 'Sign in first.' using errcode = 'P0001'; end if;
  s := make_slug(club_name);
  insert into clubs (slug, name, created_by) values (s, btrim(club_name), auth.uid()) returning id into c;
  insert into members (club_id, name, user_id, pick_order, role) values (c, btrim(my_name), auth.uid(), 1, 'admin');
  return s;
end;
$$;

-- What the invite page shows before joining: the club's name and the names nobody has claimed.
create function public.invite_preview(code text)
returns table (club_name text, slug text, already_member boolean, open_names text[], member_count int)
language sql stable security definer set search_path = public as $$
  select c.name, c.slug,
         exists (select 1 from members m where m.club_id = c.id and m.user_id = auth.uid()),
         coalesce(array(select m.name from members m where m.club_id = c.id and m.user_id is null order by m.pick_order nulls last, m.name), '{}'),
         (select count(*)::int from members m where m.club_id = c.id)
  from clubs c
  where c.invite_code = code and auth.uid() is not null
$$;

-- Join with an invite code, either as a new name or by claiming a name the admin added
-- (which keeps that name's ratings). New names join the end of the pick order.
create function public.join_club(code text, as_name text) returns text
language plpgsql security definer set search_path = public as $$
declare c clubs; claimed int;
begin
  if auth.uid() is null then raise exception 'Sign in first.' using errcode = 'P0001'; end if;
  select * into c from clubs where invite_code = code;
  if c.id is null then raise exception 'That invite link has expired. Ask the club for a new one.' using errcode = 'P0001'; end if;
  if exists (select 1 from members where club_id = c.id and user_id = auth.uid()) then return c.slug; end if;
  update members set user_id = auth.uid() where club_id = c.id and name = btrim(as_name) and user_id is null;
  get diagnostics claimed = row_count;
  if claimed = 0 then
    if exists (select 1 from members where club_id = c.id and lower(name) = lower(btrim(as_name))) then
      raise exception 'Someone in the club already has that name. Pick another.' using errcode = 'P0001';
    end if;
    insert into members (club_id, name, user_id, pick_order)
    values (c.id, btrim(as_name), auth.uid(), (select coalesce(max(pick_order), 0) + 1 from members where club_id = c.id));
  end if;
  return c.slug;
end;
$$;

-- Leave a club. Your name and ratings stay (unclaimed) so the club's history is intact.
-- The last admin has to hand over first, unless nobody else is left, in which case the club is deleted.
create function public.leave_club(c uuid) returns void
language plpgsql security definer set search_path = public as $$
declare me members;
begin
  select * into me from members where club_id = c and user_id = auth.uid();
  if me.name is null then return; end if;
  if me.role = 'admin' and not exists (select 1 from members where club_id = c and role = 'admin' and name <> me.name) then
    if exists (select 1 from members where club_id = c and user_id is not null and name <> me.name) then
      raise exception 'Make someone else an admin before you leave.' using errcode = 'P0001';
    end if;
    delete from clubs where id = c;
    return;
  end if;
  update members set user_id = null, role = 'member' where club_id = c and name = me.name;
end;
$$;

/* ---------------------------------------------------------------- admin tools */

create function public.require_admin(c uuid) returns void
language plpgsql stable security definer set search_path = public as $$
begin
  if not is_admin(c) then raise exception 'Only club admins can do that.' using errcode = '42501'; end if;
end;
$$;

create function public.admin_update_club(c uuid, new_name text, note text) returns void
language plpgsql security definer set search_path = public as $$
begin
  perform require_admin(c);
  update clubs set name = btrim(new_name), schedule_note = nullif(btrim(note), '') where id = c;
end;
$$;

-- A new invite link; the old one stops working.
create function public.admin_new_invite(c uuid) returns text
language plpgsql security definer set search_path = public as $$
declare code text := substr(replace(gen_random_uuid()::text, '-', ''), 1, 12);
begin
  perform require_admin(c);
  update clubs set invite_code = code where id = c;
  return code;
end;
$$;

create function public.admin_invite_code(c uuid) returns text
language sql stable security definer set search_path = public as $$
  select invite_code from clubs where id = c and is_admin(c)
$$;

-- Add a name for someone who hasn't joined yet; they claim it from the invite page.
create function public.admin_add_member(c uuid, new_name text, in_rotation boolean) returns void
language plpgsql security definer set search_path = public as $$
begin
  perform require_admin(c);
  if exists (select 1 from members where club_id = c and lower(name) = lower(btrim(new_name))) then
    raise exception 'Someone in the club already has that name.' using errcode = 'P0001';
  end if;
  insert into members (club_id, name, pick_order)
  values (c, btrim(new_name), case when in_rotation then (select coalesce(max(pick_order), 0) + 1 from members where club_id = c) end);
end;
$$;

-- Rename a member everywhere, including "X's pick" on screenings.
create function public.admin_rename_member(c uuid, old_name text, new_name text) returns void
language plpgsql security definer set search_path = public as $$
declare n text := btrim(new_name);
begin
  perform require_admin(c);
  if lower(n) <> lower(old_name) and exists (select 1 from members where club_id = c and lower(name) = lower(n)) then
    raise exception 'Someone in the club already has that name.' using errcode = 'P0001';
  end if;
  update members set name = n where club_id = c and name = old_name;
  update slots set picker = array_to_string(array(
           select case when p = old_name then n else p end
           from unnest(regexp_split_to_array(picker, '\s*&\s*')) p), ' & ')
  where club_id = c and old_name = any (regexp_split_to_array(picker, '\s*&\s*'));
end;
$$;

-- Set the pick order: names in turn order. Everyone else rates as a guest.
create function public.admin_set_order(c uuid, names text[]) returns void
language plpgsql security definer set search_path = public as $$
begin
  perform require_admin(c);
  update members m set pick_order = o.i
  from unnest(names) with ordinality o(name, i)
  where m.club_id = c and m.name = o.name;
  update members set pick_order = null where club_id = c and not (name = any (names));
end;
$$;

create function public.admin_set_role(c uuid, who text, new_role text) returns void
language plpgsql security definer set search_path = public as $$
begin
  perform require_admin(c);
  if new_role = 'member' and not exists (select 1 from members where club_id = c and role = 'admin' and name <> who) then
    raise exception 'A club needs at least one admin.' using errcode = 'P0001';
  end if;
  if new_role = 'admin' and not exists (select 1 from members where club_id = c and name = who and user_id is not null) then
    raise exception 'Only someone who has joined can be an admin.' using errcode = 'P0001';
  end if;
  update members set role = new_role where club_id = c and name = who;
end;
$$;

-- Remove someone from the club. keep_history = their name and ratings stay, unlinked from
-- their login (it can be claimed again from the invite page); otherwise everything of theirs goes.
create function public.admin_remove_member(c uuid, who text, keep_history boolean) returns void
language plpgsql security definer set search_path = public as $$
begin
  perform require_admin(c);
  if who = my_name(c) then raise exception 'To remove yourself, leave the club instead.' using errcode = 'P0001'; end if;
  if keep_history then
    update members set user_id = null, role = 'member', pick_order = null where club_id = c and name = who;
  else
    delete from members where club_id = c and name = who;
  end if;
end;
$$;

-- Add screening dates. Pickers follow the pick order, carrying on from the latest screening.
-- Dates already on the calendar are skipped. Returns how many were added.
create function public.admin_add_dates(c uuid, dates date[]) returns int
language plpgsql security definer set search_path = public as $$
declare
  rot text[];
  last_picker text;
  i int := 0;
  d date;
  added int := 0;
begin
  perform require_admin(c);
  rot := array(select name from members where club_id = c and pick_order is not null order by pick_order);
  if coalesce(array_length(rot, 1), 0) = 0 then
    raise exception 'Put at least one member in the pick order first.' using errcode = 'P0001';
  end if;
  select picker into last_picker from slots where club_id = c order by date desc limit 1;
  if last_picker is not null and array_position(rot, last_picker) is not null then
    i := array_position(rot, last_picker);   -- 1-based, so this is already "the next one"
  end if;
  for d in select distinct x from unnest(dates) x order by x loop
    if not exists (select 1 from slots where club_id = c and date = d) then
      insert into slots (club_id, date, picker) values (c, d, rot[(i % array_length(rot, 1)) + 1]);
      i := i + 1;
      added := added + 1;
    end if;
  end loop;
  return added;
end;
$$;

-- Re-deal open dates: every upcoming date without a film gets a new picker in pick-order turns.
-- Turns carry on from whoever picked the latest watched screening. Dates that already have a
-- film keep their picker, and the turns continue after them. Returns how many dates changed hands.
create function public.admin_redeal(c uuid) returns int
language plpgsql security definer set search_path = public as $$
declare
  rot text[];
  n int;
  i int := 0;
  p int;
  s record;
  changed int := 0;
begin
  perform require_admin(c);
  rot := array(select name from members where club_id = c and pick_order is not null order by pick_order);
  n := coalesce(array_length(rot, 1), 0);
  if n = 0 then
    raise exception 'Put at least one member in the pick order first.' using errcode = 'P0001';
  end if;
  select array_position(rot, picker) into p from slots where club_id = c and watched order by date desc limit 1;
  i := coalesce(p, 0);
  for s in select date, picker, title from slots where club_id = c and not watched order by date loop
    if s.title is not null then
      p := array_position(rot, s.picker);
      if p is not null then i := p; end if;
    else
      if s.picker is distinct from rot[(i % n) + 1] then
        update slots set picker = rot[(i % n) + 1] where club_id = c and date = s.date;
        changed := changed + 1;
      end if;
      i := i + 1;
    end if;
  end loop;
  return changed;
end;
$$;

-- Take a date off the calendar (only dates not yet watched).
create function public.admin_remove_date(c uuid, d date) returns void
language plpgsql security definer set search_path = public as $$
begin
  perform require_admin(c);
  delete from slots where club_id = c and date = d and not watched;
end;
$$;

-- Delete the club and everything in it. The page removes the club's party images first.
create function public.admin_delete_club(c uuid) returns void
language plpgsql security definer set search_path = public as $$
begin
  perform require_admin(c);
  delete from clubs where id = c;
end;
$$;

/* ---------------------------------------------------------------- your account */

-- Delete your login. In each club your name and ratings stay, unclaimed. Clubs where you were
-- the only admin get a new admin (whoever joined earliest), or are deleted if nobody else is in them.
create function public.delete_my_account() returns void
language plpgsql security definer set search_path = public, auth as $$
declare r record; heir text;
begin
  if auth.uid() is null then return; end if;
  for r in select m.club_id, m.name, m.role from members m where m.user_id = auth.uid() loop
    if r.role = 'admin' and not exists (select 1 from members where club_id = r.club_id and role = 'admin' and name <> r.name) then
      select name into heir from members where club_id = r.club_id and user_id is not null and name <> r.name order by created_at limit 1;
      if heir is null then delete from clubs where id = r.club_id; continue; end if;
      update members set role = 'admin' where club_id = r.club_id and name = heir;
    end if;
    update members set user_id = null, role = 'member' where club_id = r.club_id and name = r.name;
  end loop;
  delete from auth.users where id = auth.uid();
end;
$$;

/* ---------------------------------------------------------------- daily job */

-- Rating a film later clears an automatic "missed" for it.
create function public.clear_auto_missed() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  delete from absences where club_id = new.club_id and slot = new.slot and member = new.member and auto;
  return new;
end;
$$;
create trigger ratings_clear_auto_missed
  after insert or update on public.ratings
  for each row execute function public.clear_auto_missed();

-- Marks rotation members as having missed a watched screening they haven't rated within a week.
create function public.mark_missed() returns integer
language sql security definer set search_path = public as $$
  with marked as (
    insert into absences (club_id, slot, member, auto)
    select s.club_id, s.date, m.name, true
    from slots s
    join members m on m.club_id = s.club_id
    where s.watched
      and s.date <= current_date - 7
      and m.pick_order is not null
      and m.created_at::date <= s.date
      and not exists (select 1 from ratings r where r.club_id = s.club_id and r.slot = s.date and r.member = m.name)
      and not exists (select 1 from absences a where a.club_id = s.club_id and a.slot = s.date and a.member = m.name)
    on conflict do nothing
    returning 1
  )
  select count(*)::int from marked;
$$;

create extension if not exists pg_cron with schema pg_catalog;
select cron.schedule('mark-missed-screenings', '0 7 * * *', $$select public.mark_missed()$$);

/* ---------------------------------------------------------------- function permissions */

revoke execute on all functions in schema public from public, anon;
grant execute on function
  public.is_member(uuid), public.is_admin(uuid), public.my_name(uuid),
  public.create_club(text, text), public.invite_preview(text), public.join_club(text, text), public.leave_club(uuid),
  public.admin_update_club(uuid, text, text), public.admin_new_invite(uuid), public.admin_invite_code(uuid),
  public.admin_add_member(uuid, text, boolean), public.admin_rename_member(uuid, text, text),
  public.admin_set_order(uuid, text[]), public.admin_set_role(uuid, text, text),
  public.admin_remove_member(uuid, text, boolean), public.admin_add_dates(uuid, date[]),
  public.admin_redeal(uuid), public.admin_remove_date(uuid, date), public.admin_delete_club(uuid), public.delete_my_account()
  to authenticated;
-- New functions shouldn't be callable by everyone by default.
alter default privileges in schema public revoke execute on functions from public, anon;

/* ---------------------------------------------------------------- party images */

-- Private bucket: files sit under <club id>/ and only that club's members can see or change them.
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('party', 'party', false, 2097152, array['image/png', 'image/jpeg', 'image/gif', 'image/webp']);

create policy "Members see party images" on storage.objects for select to authenticated
  using (bucket_id = 'party' and public.is_member(((storage.foldername(name))[1])::uuid));
create policy "Members upload party images" on storage.objects for insert to authenticated
  with check (bucket_id = 'party' and public.is_member(((storage.foldername(name))[1])::uuid));
create policy "Members delete party images" on storage.objects for delete to authenticated
  using (bucket_id = 'party' and public.is_member(((storage.foldername(name))[1])::uuid));

/* ---------------------------------------------------------------- live updates */

-- Open pages refresh when anything in their club changes. Realtime applies the access rules
-- above, so people only hear about their own clubs.
alter publication supabase_realtime add table
  public.clubs, public.members, public.slots, public.ratings, public.absences, public.review_votes, public.stickers;
