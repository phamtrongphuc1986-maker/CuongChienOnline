-- Cuong Chien Online: boss contribution leaderboard, participation rewards and admin reset
create table if not exists public.world_boss_damage (
  boss_id text not null references public.world_boss(boss_id) on delete cascade,
  user_id uuid not null references auth.users(id) on delete cascade,
  nickname text not null,
  total_damage bigint not null default 0,
  attacks integer not null default 0,
  reward_claimed boolean not null default false,
  updated_at timestamptz not null default now(),
  primary key (boss_id,user_id),
  constraint world_boss_damage_nonnegative check (total_damage >= 0)
);
alter table public.world_boss_damage enable row level security;
revoke all on public.world_boss_damage from anon, authenticated;
grant all on public.world_boss_damage to service_role;

-- This function is called only by the authenticated Edge Function using service_role.
create or replace function public.resolve_boss_attack(p_user_id uuid)
returns jsonb language plpgsql security definer set search_path = '' as $function$
declare
  v_profile public.player_profiles%rowtype;
  v_state public.player_combat_state%rowtype;
  v_boss public.world_boss%rowtype;
  v_contrib public.world_boss_damage%rowtype;
  v_now timestamptz := clock_timestamp();
  v_damage bigint;
  v_level_up boolean := false;
  v_defeated boolean := false;
  v_next_level_exp bigint;
  v_rewarded integer := 0;
begin
  if p_user_id is null then raise exception 'invalid_player'; end if;
  select * into v_profile from public.player_profiles where user_id=p_user_id for update;
  if not found then raise exception 'player_profile_not_found'; end if;
  insert into public.player_combat_state(user_id) values (p_user_id) on conflict (user_id) do nothing;
  select * into v_state from public.player_combat_state where user_id=p_user_id for update;
  select * into v_boss from public.world_boss where boss_id='village_dragon' for update;
  if not found then raise exception 'boss_not_configured'; end if;

  if v_state.last_attack_at is not null and v_now < v_state.last_attack_at + interval '1200 milliseconds' then
    return jsonb_build_object('ok',false,'code','cooldown',
      'retry_after_ms',greatest(0,ceil(extract(epoch from (v_state.last_attack_at + interval '1200 milliseconds' - v_now))*1000)::integer),
      'boss',jsonb_build_object('name',v_boss.boss_name,'hp',v_boss.boss_hp,'max_hp',v_boss.boss_max_hp,'defeated',v_boss.is_defeated));
  end if;
  if v_boss.is_defeated or v_boss.boss_hp<=0 then
    return jsonb_build_object('ok',false,'code','boss_defeated',
      'boss',jsonb_build_object('name',v_boss.boss_name,'hp',v_boss.boss_hp,'max_hp',v_boss.boss_max_hp,'defeated',true));
  end if;

  v_damage:=least(v_boss.boss_hp,greatest(1,(v_profile.level*12)::bigint+floor(random()*8)::bigint));
  update public.world_boss set boss_hp=greatest(0,boss_hp-v_damage),is_defeated=(boss_hp-v_damage<=0),updated_at=v_now
    where boss_id='village_dragon' returning * into v_boss;
  update public.player_combat_state set last_attack_at=v_now,updated_at=v_now where user_id=p_user_id;

  insert into public.world_boss_damage(boss_id,user_id,nickname,total_damage,attacks,updated_at)
  values ('village_dragon',p_user_id,v_profile.nickname,v_damage,1,v_now)
  on conflict (boss_id,user_id) do update set nickname=excluded.nickname,
    total_damage=public.world_boss_damage.total_damage+excluded.total_damage,
    attacks=public.world_boss_damage.attacks+1,updated_at=excluded.updated_at;

  v_defeated:=v_boss.is_defeated;
  if v_defeated then
    -- Participation reward: 75 EXP + 150 gold to every contributor.
    -- Last hitter receives an additional 250 EXP + 500 gold.
    for v_contrib in
      select * from public.world_boss_damage
      where boss_id='village_dragon' and reward_claimed=false
      order by total_damage desc
      for update
    loop
      update public.player_profiles
        set experience=experience+case when user_id=p_user_id then 325 else 75 end,
            gold=gold+case when user_id=p_user_id then 700 else 150 end,
            updated_at=v_now
        where user_id=v_contrib.user_id returning * into v_profile;

      if found then
        v_next_level_exp:=v_profile.level*100;
        while v_profile.experience>=v_next_level_exp loop
          update public.player_profiles set level=level+1,
            experience=experience-v_next_level_exp,updated_at=v_now
            where user_id=v_contrib.user_id returning * into v_profile;
          v_next_level_exp:=v_profile.level*100;
        end loop;
        v_rewarded:=v_rewarded+1;
      end if;
      update public.world_boss_damage set reward_claimed=true
        where boss_id='village_dragon' and user_id=v_contrib.user_id;
    end loop;
    select * into v_profile from public.player_profiles where user_id=p_user_id;
  end if;

  return jsonb_build_object('ok',true,'action','boss_attack','damage',v_damage,
    'defeated',v_defeated,'level_up',v_level_up,
    'experience_gain',case when v_defeated then 325 else 0 end,
    'gold_gain',case when v_defeated then 700 else 0 end,
    'participants_rewarded',case when v_defeated then v_rewarded else 0 end,
    'profile',jsonb_build_object('nickname',v_profile.nickname,'level',v_profile.level,'experience',v_profile.experience,'gold',v_profile.gold),
    'boss',jsonb_build_object('name',v_boss.boss_name,'hp',v_boss.boss_hp,'max_hp',v_boss.boss_max_hp,'defeated',v_boss.is_defeated));
end;
$function$;
revoke all on function public.resolve_boss_attack(uuid) from public,anon,authenticated;
grant execute on function public.resolve_boss_attack(uuid) to service_role;

-- Administrative reset only; not exposed to normal player accounts.
create or replace function public.reset_world_boss(p_hp bigint default 10000)
returns jsonb language plpgsql security definer set search_path = '' as $function$
begin
  if p_hp < 1 or p_hp > 100000000 then raise exception 'invalid_boss_hp'; end if;
  update public.world_boss set boss_hp=p_hp,boss_max_hp=p_hp,is_defeated=false,updated_at=clock_timestamp()
    where boss_id='village_dragon';
  delete from public.world_boss_damage where boss_id='village_dragon';
  return jsonb_build_object('ok',true,'hp',p_hp);
end;
$function$;
revoke all on function public.reset_world_boss(bigint) from public,anon,authenticated;
grant execute on function public.reset_world_boss(bigint) to service_role;
