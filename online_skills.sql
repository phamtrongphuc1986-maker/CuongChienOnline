-- Online skills with server-side mana regeneration.
create table if not exists public.player_skill_state (
  user_id uuid primary key references auth.users(id) on delete cascade,
  mana integer not null default 100,
  max_mana integer not null default 100,
  last_skill_at timestamptz,
  updated_at timestamptz not null default now(),
  constraint player_skill_mana_range check (mana >= 0 and max_mana > 0 and mana <= max_mana)
);
alter table public.player_skill_state enable row level security;
revoke all on public.player_skill_state from anon, authenticated;
grant all on public.player_skill_state to service_role;

create or replace function public.get_player_skill_state(p_user_id uuid)
returns jsonb language plpgsql security definer set search_path = '' as $function$
declare v_skill public.player_skill_state%rowtype; v_now timestamptz:=clock_timestamp(); v_gain integer;
begin
 if p_user_id is null then raise exception 'invalid_player'; end if;
 insert into public.player_skill_state(user_id) values(p_user_id) on conflict(user_id) do nothing;
 select * into v_skill from public.player_skill_state where user_id=p_user_id for update;
 v_gain:=greatest(0,floor(extract(epoch from(v_now-v_skill.updated_at))/3)::integer);
 if v_gain>0 then
  update public.player_skill_state set mana=least(max_mana,mana+v_gain),updated_at=v_now
   where user_id=p_user_id returning * into v_skill;
 end if;
 return jsonb_build_object('mana',v_skill.mana,'max_mana',v_skill.max_mana,'regen_per_second',0.333);
end;
$function$;
revoke all on function public.get_player_skill_state(uuid) from public,anon,authenticated;
grant execute on function public.get_player_skill_state(uuid) to service_role;

create or replace function public.resolve_skill_attack(p_user_id uuid,p_skill_code text)
returns jsonb language plpgsql security definer set search_path = '' as $function$
declare
 v_profile public.player_profiles%rowtype; v_skill public.player_skill_state%rowtype;
 v_monster public.world_monsters%rowtype; v_now timestamptz:=clock_timestamp();
 v_cost integer; v_cooldown interval; v_damage integer; v_defeated boolean:=false;
 v_level_up boolean:=false; v_next_level_exp bigint; v_gain integer;
begin
 if p_user_id is null then raise exception 'invalid_player'; end if;
 if p_skill_code not in ('sword_wave','thunder_strike') then return jsonb_build_object('ok',false,'code','unknown_skill'); end if;
 select * into v_profile from public.player_profiles where user_id=p_user_id for update;
 if not found then raise exception 'player_profile_not_found'; end if;
 insert into public.player_skill_state(user_id) values(p_user_id) on conflict(user_id) do nothing;
 select * into v_skill from public.player_skill_state where user_id=p_user_id for update;
 v_gain:=greatest(0,floor(extract(epoch from(v_now-v_skill.updated_at))/3)::integer);
 if v_gain>0 then
  update public.player_skill_state set mana=least(max_mana,mana+v_gain),updated_at=v_now where user_id=p_user_id returning * into v_skill;
 end if;
 if p_skill_code='sword_wave' then
  v_cost:=20; v_cooldown:=interval '5 seconds'; v_damage:=greatest(1,v_profile.level*16+floor(random()*8)::integer);
 else
  v_cost:=35; v_cooldown:=interval '8 seconds'; v_damage:=greatest(1,v_profile.level*25+floor(random()*12)::integer);
 end if;
 if v_skill.last_skill_at is not null and v_now<v_skill.last_skill_at+v_cooldown then
  return jsonb_build_object('ok',false,'code','cooldown','retry_after_ms',greatest(0,ceil(extract(epoch from(v_skill.last_skill_at+v_cooldown-v_now))*1000)::integer),'mana',v_skill.mana,'max_mana',v_skill.max_mana);
 end if;
 if v_skill.mana<v_cost then return jsonb_build_object('ok',false,'code','not_enough_mana','mana',v_skill.mana,'max_mana',v_skill.max_mana); end if;
 insert into public.world_monsters(room_code,monster_code,monster_hp,monster_max_hp) values('village','slime',100+v_profile.level*20,100+v_profile.level*20) on conflict(room_code,monster_code) do nothing;
 select * into v_monster from public.world_monsters where room_code='village' and monster_code='slime' for update;
 if v_monster.monster_hp<=0 then update public.world_monsters set monster_hp=monster_max_hp,updated_at=v_now where room_code='village' and monster_code='slime' returning * into v_monster; end if;
 v_damage:=least(v_monster.monster_hp,v_damage);
 update public.world_monsters set monster_hp=greatest(0,monster_hp-v_damage),updated_at=v_now where room_code='village' and monster_code='slime' returning * into v_monster;
 update public.player_skill_state set mana=mana-v_cost,last_skill_at=v_now,updated_at=v_now where user_id=p_user_id returning * into v_skill;
 v_defeated:=(v_monster.monster_hp=0);
 if v_defeated then
  update public.player_profiles set experience=experience+25,gold=gold+5,updated_at=v_now where user_id=p_user_id returning * into v_profile;
  v_next_level_exp:=v_profile.level*100;
  if v_profile.experience>=v_next_level_exp then
   update public.player_profiles set level=level+1,experience=experience-v_next_level_exp,updated_at=v_now where user_id=p_user_id returning * into v_profile;
   v_level_up:=true;
  end if;
 end if;
 return jsonb_build_object('ok',true,'action','skill_attack','skill_code',p_skill_code,'damage',v_damage,'defeated',v_defeated,'level_up',v_level_up,'experience_gain',case when v_defeated then 25 else 0 end,'gold_gain',case when v_defeated then 5 else 0 end,'mana',v_skill.mana,'max_mana',v_skill.max_mana,'profile',jsonb_build_object('nickname',v_profile.nickname,'level',v_profile.level,'experience',v_profile.experience,'gold',v_profile.gold),'monster',jsonb_build_object('monster_code',v_monster.monster_code,'hp',v_monster.monster_hp,'max_hp',v_monster.monster_max_hp));
end;
$function$;
revoke all on function public.resolve_skill_attack(uuid,text) from public,anon,authenticated;
grant execute on function public.resolve_skill_attack(uuid,text) to service_role;
