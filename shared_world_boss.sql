-- Cuong Chien Online: shared boss database migration
create table if not exists public.world_boss (
  boss_id text primary key,
  boss_name text not null default 'Hắc Long Vương',
  boss_hp bigint not null default 10000,
  boss_max_hp bigint not null default 10000,
  is_defeated boolean not null default false,
  updated_at timestamptz not null default now(),
  constraint world_boss_hp_nonnegative check (boss_hp >= 0),
  constraint world_boss_max_hp_positive check (boss_max_hp > 0)
);
insert into public.world_boss(boss_id,boss_name,boss_hp,boss_max_hp)
values ('village_dragon','Hắc Long Vương',10000,10000)
on conflict (boss_id) do nothing;
alter table public.world_boss enable row level security;
revoke all on public.world_boss from anon, authenticated;
grant all on public.world_boss to service_role;

create or replace function public.resolve_boss_attack(p_user_id uuid)
returns jsonb language plpgsql security definer set search_path = '' as $function$
declare
  v_profile public.player_profiles%rowtype;
  v_state public.player_combat_state%rowtype;
  v_boss public.world_boss%rowtype;
  v_now timestamptz := clock_timestamp();
  v_damage bigint;
  v_exp_gain integer := 250;
  v_gold_gain integer := 500;
  v_level_up boolean := false;
  v_defeated boolean := false;
  v_next_level_exp bigint;
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
  v_damage:=greatest(1,(v_profile.level*12)::bigint+floor(random()*8)::bigint);
  update public.world_boss set boss_hp=greatest(0,boss_hp-v_damage),is_defeated=(boss_hp-v_damage<=0),updated_at=v_now
    where boss_id='village_dragon' returning * into v_boss;
  update public.player_combat_state set last_attack_at=v_now,updated_at=v_now where user_id=p_user_id;
  v_defeated:=v_boss.is_defeated;
  if v_defeated then
    update public.player_profiles set experience=experience+v_exp_gain,gold=gold+v_gold_gain,updated_at=v_now
      where user_id=p_user_id returning * into v_profile;
    v_next_level_exp:=v_profile.level*100;
    if v_profile.experience>=v_next_level_exp then
      update public.player_profiles set level=level+1,experience=experience-v_next_level_exp,updated_at=v_now
        where user_id=p_user_id returning * into v_profile;
      v_level_up:=true;
    end if;
  end if;
  return jsonb_build_object('ok',true,'action','boss_attack','damage',v_damage,'defeated',v_defeated,'level_up',v_level_up,
    'experience_gain',case when v_defeated then v_exp_gain else 0 end,'gold_gain',case when v_defeated then v_gold_gain else 0 end,
    'profile',jsonb_build_object('nickname',v_profile.nickname,'level',v_profile.level,'experience',v_profile.experience,'gold',v_profile.gold),
    'boss',jsonb_build_object('name',v_boss.boss_name,'hp',v_boss.boss_hp,'max_hp',v_boss.boss_max_hp,'defeated',v_boss.is_defeated));
end;
$function$;
revoke all on function public.resolve_boss_attack(uuid) from public,anon,authenticated;
grant execute on function public.resolve_boss_attack(uuid) to service_role;
