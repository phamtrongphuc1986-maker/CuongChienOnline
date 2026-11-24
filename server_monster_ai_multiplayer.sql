-- Server-side Slime AI and shared player position state.
create table if not exists public.world_monster_ai (
 room_code text not null default 'village',
 monster_code text not null default 'slime',
 x double precision not null default 640,
 y double precision not null default 350,
 target_user_id uuid,
 last_tick_at timestamptz not null default now(),
 updated_at timestamptz not null default now(),
 primary key(room_code,monster_code)
);
alter table public.world_monster_ai enable row level security;
revoke all on public.world_monster_ai from anon,authenticated;
grant all on public.world_monster_ai to service_role;

-- Deployed RPC submit_player_position:
-- 1) validates bounds and movement speed;
-- 2) persists authenticated player's village position in game_presence;
-- 3) chooses the nearest recently active player;
-- 4) moves the shared Slime toward that player at 90 world units/second;
-- 5) applies contact damage through resolve_player_monster_hit;
-- 6) returns the authoritative monster coordinates and active player list.
-- The full function is deployed in Supabase project CuongChienOnline.
