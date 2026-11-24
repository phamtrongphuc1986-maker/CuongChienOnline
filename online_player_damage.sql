-- Server-authoritative incoming damage and HP.
create table if not exists public.player_incoming_hit_state (
 user_id uuid primary key references auth.users(id) on delete cascade,
 last_hit_at timestamptz,
 updated_at timestamptz not null default now()
);
alter table public.player_incoming_hit_state enable row level security;
revoke all on public.player_incoming_hit_state from anon, authenticated;
grant all on public.player_incoming_hit_state to service_role;

create or replace function public.resolve_player_monster_hit(p_user_id uuid,p_monster_code text default 'slime')
returns jsonb language plpgsql security definer set search_path = '' as $function$
declare
 v_profile public.player_profiles%rowtype; v_vitals public.player_vitals%rowtype;
 v_hit public.player_incoming_hit_state%rowtype; v_defense integer:=0;
 v_raw integer; v_damage integer; v_now timestamptz:=clock_timestamp(); v_dead boolean:=false;
begin
 if p_user_id is null then raise exception 'invalid_player'; end if;
 if p_monster_code not in ('slime','village_dragon') then return jsonb_build_object('ok',false,'code','invalid_monster'); end if;
 select * into v_profile from public.player_profiles where user_id=p_user_id for update;
 if not found then raise exception 'player_profile_not_found'; end if;
 insert into public.player_vitals(user_id,hp,max_hp) values(p_user_id,100,100) on conflict(user_id) do nothing;
 select * into v_vitals from public.player_vitals where user_id=p_user_id for update;
 insert into public.player_incoming_hit_state(user_id) values(p_user_id) on conflict(user_id) do nothing;
 select * into v_hit from public.player_incoming_hit_state where user_id=p_user_id for update;
 if v_hit.last_hit_at is not null and v_now<v_hit.last_hit_at+interval '900 milliseconds' then
  return jsonb_build_object('ok',false,'code','hit_cooldown','hp',v_vitals.hp,'max_hp',v_vitals.max_hp,
   'retry_after_ms',greatest(0,ceil(extract(epoch from(v_hit.last_hit_at+interval '900 milliseconds'-v_now))*1000)::integer));
 end if;
 select coalesce(sum(c.defense_bonus),0) into v_defense from public.inventory_items i
 join public.game_item_catalog c on c.item_code=i.item_code where i.user_id=p_user_id and i.equipped=true;
 v_raw:=case when p_monster_code='village_dragon' then 12 else 5 end;
 v_damage:=greatest(1,v_raw-v_defense);
 update public.player_vitals set hp=greatest(0,hp-v_damage),updated_at=v_now where user_id=p_user_id returning * into v_vitals;
 update public.player_incoming_hit_state set last_hit_at=v_now,updated_at=v_now where user_id=p_user_id;
 v_dead:=(v_vitals.hp=0);
 if v_dead then update public.player_vitals set hp=max_hp,updated_at=v_now where user_id=p_user_id returning * into v_vitals; end if;
 return jsonb_build_object('ok',true,'action','player_hit','raw_damage',v_raw,'defense',v_defense,
  'damage',v_damage,'dead',v_dead,'hp',v_vitals.hp,'max_hp',v_vitals.max_hp);
end;
$function$;
revoke all on function public.resolve_player_monster_hit(uuid,text) from public,anon,authenticated;
grant execute on function public.resolve_player_monster_hit(uuid,text) to service_role;
