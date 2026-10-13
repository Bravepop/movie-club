-- "Watch this one next": swap the films (and pickers) of two upcoming screenings.
-- Run once in the Supabase SQL editor (already included in schema.sql for new projects).

-- Any member can do it, like editing a screening. Only screenings not yet watched, so ratings
-- never move. The dates stay put; what's scheduled on them trades places.
create function public.swap_screenings(c uuid, a date, b date) returns void
language plpgsql security definer set search_path = public as $$
declare x slots; y slots;
begin
  if not is_member(c) then raise exception 'Only club members can do that.' using errcode = '42501'; end if;
  select * into x from slots where club_id = c and date = a;
  select * into y from slots where club_id = c and date = b;
  if x.date is null or y.date is null then raise exception 'One of those screenings is gone. Refresh and try again.' using errcode = 'P0001'; end if;
  if x.watched or y.watched then raise exception 'Only upcoming screenings can be swapped.' using errcode = 'P0001'; end if;
  update slots set title = y.title, director = y.director, genre = y.genre, mins = y.mins, imdb = y.imdb, poster = y.poster, picker = y.picker
  where club_id = c and date = a;
  update slots set title = x.title, director = x.director, genre = x.genre, mins = x.mins, imdb = x.imdb, poster = x.poster, picker = x.picker
  where club_id = c and date = b;
end;
$$;
revoke execute on function public.swap_screenings(uuid, date, date) from public, anon;
grant execute on function public.swap_screenings(uuid, date, date) to authenticated;
