-- Shared village monster: one HP pool for all authenticated players.
-- Run only on the CuongChienOnline Supabase project.
create table if not exists public.world_monsters (
  room_code text not null default 'village',
  monster_code text not null default 'slime',
  monster_hp integer not null default 100,
  monster_max_hp integer not null default 100,
  updated_at timestamptz not null default now(),
  primary key (room_code, monster_code),
  constraint world_monsters_hp_nonnegative check (monster_hp >= 0),
  constraint world_monsters_max_hp_positive check (monster_max_hp > 0)
);
alter table public.world_monsters enable row level security;
revoke all on public.world_monsters from anon, authenticated;
grant all on public.world_monsters to service_role;

create or replace function public.resolve_combat_attack(p_user_id uuid)
returns jsonb language plpgsql security definer set search_path = ''
as $function$
declare
  v_profile public.player_profiles%rowtype;
  v_state public.player_combat_state%rowtype;
  v_world public.world_monsters%rowtype;
  v_now timestamptz := clock_timestamp();
  v_damage integer;
  v_exp_gain integer := 25;
  v_gold_gain integer := 5;
  v_level_up boolean := false;
  v_defeated boolean := false;
  v_next_level_exp bigint;
begin
  if p_user_id is null then raise exception 'invalid_player'; end if;
  select * into v_profile from public.player_profiles where user_id = p_user_id for update;
  if not found then raise exception 'player_profile_not_found'; end if;
  insert into public.player_combat_state(user_id) values (p_user_id) on conflict (user_id) do nothing;
  select * into v_state from public.player_combat_state where user_id = p_user_id for update;
  insert into public.world_monsters(room_code, monster_code, monster_hp, monster_max_hp)
    values ('village', 'slime', 100 + v_profile.level * 20, 100 + v_profile.level * 20)
    on conflict (room_code, monster_code) do nothing;
  select * into v_world from public.world_monsters
    where room_code = 'village' and monster_code = 'slime' for update;
  if v_state.last_attack_at is not null and v_now < v_state.last_attack_at + interval '900 milliseconds' then
    return jsonb_build_object('ok', false, 'code', 'cooldown',
      'retry_after_ms', greatest(0, ceil(extract(epoch from (v_state.last_attack_at + interval '900 milliseconds' - v_now)) * 1000)::integer),
      'level', v_profile.level, 'experience', v_profile.experience, 'gold', v_profile.gold,
      'monster_hp', v_world.monster_hp, 'monster_max_hp', v_world.monster_max_hp);
  end if;
  if v_world.monster_hp <= 0 then
    update public.world_monsters set monster_hp = monster_max_hp, updated_at = v_now
      where room_code = 'village' and monster_code = 'slime' returning * into v_world;
  end if;
  v_damage := greatest(1, (v_profile.level * 8) + floor(random() * 4)::integer);
  update public.world_monsters set monster_hp = greatest(0, monster_hp - v_damage), updated_at = v_now
    where room_code = 'village' and monster_code = 'slime' returning * into v_world;
  update public.player_combat_state set last_attack_at = v_now, updated_at = v_now where user_id = p_user_id;
  v_defeated := (v_world.monster_hp = 0);
  if v_defeated then
    v_gold_gain := 5 + floor(random() * 8)::integer;
    update public.player_profiles set experience = experience + v_exp_gain, gold = gold + v_gold_gain, updated_at = v_now
      where user_id = p_user_id returning * into v_profile;
    v_next_level_exp := v_profile.level * 100;
    if v_profile.experience >= v_next_level_exp then
      update public.player_profiles set level = level + 1, experience = experience - v_next_level_exp, updated_at = v_now
        where user_id = p_user_id returning * into v_profile;
      v_level_up := true;
    end if;
  end if;
  return jsonb_build_object('ok', true, 'action', 'attack', 'damage', v_damage,
    'defeated', v_defeated, 'level_up', v_level_up,
    'experience_gain', case when v_defeated then v_exp_gain else 0 end,
    'gold_gain', case when v_defeated then v_gold_gain else 0 end,
    'profile', jsonb_build_object('nickname', v_profile.nickname, 'level', v_profile.level,
      'experience', v_profile.experience, 'gold', v_profile.gold),
    'monster', jsonb_build_object('monster_code', v_world.monster_code,
      'hp', v_world.monster_hp, 'max_hp', v_world.monster_max_hp));
end;
$function$;
revoke all on function public.resolve_combat_attack(uuid) from public, anon, authenticated;
grant execute on function public.resolve_combat_attack(uuid) to service_role;
