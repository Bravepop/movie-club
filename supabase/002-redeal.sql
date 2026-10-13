-- Re-deal open dates: hand every upcoming date without a film back out in pick-order turns.
-- Run once in the Supabase SQL editor (already included in schema.sql for new projects).

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
revoke execute on function public.admin_redeal(uuid) from public, anon;
grant execute on function public.admin_redeal(uuid) to authenticated;
