create table if not exists public.game_presence (
  user_id uuid primary key references auth.users(id) on delete cascade,
  nickname text not null default 'Người chơi',
  room_code text not null default 'village',
  x double precision not null default 620,
  y double precision not null default 390,
  updated_at timestamptz not null default now()
);
create index if not exists game_presence_room_updated_idx
  on public.game_presence (room_code, updated_at desc);
alter table public.game_presence enable row level security;
grant select, insert, update, delete on public.game_presence to authenticated;
drop policy if exists "authenticated players can view room presence" on public.game_presence;
create policy "authenticated players can view room presence"
  on public.game_presence for select to authenticated using (true);
drop policy if exists "players can create own presence" on public.game_presence;
create policy "players can create own presence" on public.game_presence for insert to authenticated
  with check ((select auth.uid()) = user_id);
drop policy if exists "players can update own presence" on public.game_presence;
create policy "players can update own presence" on public.game_presence for update to authenticated
  using ((select auth.uid()) = user_id) with check ((select auth.uid()) = user_id);
drop policy if exists "players can delete own presence" on public.game_presence;
create policy "players can delete own presence"
  on public.game_presence for delete to authenticated using ((select auth.uid()) = user_id);

-- Enable Postgres Changes for the multiplayer presence table.
do $$
begin
  if not exists (
    select 1 from pg_publication_tables
    where pubname = 'supabase_realtime'
      and schemaname = 'public'
      and tablename = 'game_presence'
  ) then
    alter publication supabase_realtime add table public.game_presence;
  end if;
end $$;
