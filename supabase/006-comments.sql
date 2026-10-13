-- Discussion: comments under each watched film.
-- Run once in the Supabase SQL editor (already included in schema.sql for new projects).

create table public.comments (
  id          bigint generated always as identity primary key,
  club_id     uuid not null,
  slot        date not null,
  member      text not null,
  body        text not null check (char_length(btrim(body)) between 1 and 500),
  created_at  timestamptz not null default now(),
  foreign key (club_id, slot) references public.slots (club_id, date) on delete cascade,
  foreign key (club_id, member) references public.members (club_id, name) on update cascade on delete cascade
);
create index on public.comments (club_id, slot);

alter table public.comments enable row level security;
create policy "Members see comments" on public.comments for select to authenticated
  using (public.is_member(club_id));
-- Comment only as yourself, and only on films the club has watched.
create policy "Members comment" on public.comments for insert to authenticated
  with check (member = public.my_name(club_id)
    and exists (select 1 from public.slots s where s.club_id = comments.club_id and s.date = slot and s.watched));
-- Remove your own comments; admins can remove anyone's.
create policy "Members remove comments" on public.comments for delete to authenticated
  using (member = public.my_name(club_id) or public.is_admin(club_id));

revoke all on public.comments from anon;
grant select, insert, delete on public.comments to authenticated;

-- Up to 5,000 comments per club.
create function public.comments_limit() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if (select count(*) from comments where club_id = new.club_id) >= 5000 then
    raise exception 'This club has reached its comment limit.' using errcode = 'P0001';
  end if;
  return new;
end;
$$;
revoke execute on function public.comments_limit() from public, anon, authenticated;
create trigger comments_limit before insert on public.comments for each row execute function public.comments_limit();

alter publication supabase_realtime add table public.comments;
