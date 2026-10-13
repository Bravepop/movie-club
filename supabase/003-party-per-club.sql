-- Party mode only for clubs that have it switched on (just JBOIZ), and a 3 MB image cap.
-- Run once in the Supabase SQL editor (already included in schema.sql for new projects).
-- To switch it on for another club later: update public.clubs set party = true where slug = '<club>';

alter table public.clubs add column party boolean not null default false;
update public.clubs set party = true where slug = 'jboiz';

update storage.buckets set file_size_limit = 3145728 where id = 'party';

-- Does this club have party mode?
create function public.party_on(c uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select coalesce((select party from clubs where id = c), false)
$$;
revoke execute on function public.party_on(uuid) from public, anon;
grant execute on function public.party_on(uuid) to authenticated;

-- New images only in clubs with party mode (existing ones can still be moved and removed).
drop policy "Members add stickers" on public.stickers;
create policy "Members add stickers" on public.stickers for insert to authenticated
  with check (added_by = public.my_name(club_id) and public.party_on(club_id));

drop policy "Members upload party images" on storage.objects;
create policy "Members upload party images" on storage.objects for insert to authenticated
  with check (bucket_id = 'party'
    and public.is_member(((storage.foldername(name))[1])::uuid)
    and public.party_on(((storage.foldername(name))[1])::uuid));
