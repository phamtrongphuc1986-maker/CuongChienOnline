-- Authoritative movement validation and server-triggered contact damage.
create table if not exists public.player_movement_guard (
 user_id uuid primary key references auth.users(id) on delete cascade,
 x double precision not null default 620,
 y double precision not null default 390,
 last_move_at timestamptz not null default now(),
 updated_at timestamptz not null default now(),
 constraint movement_guard_bounds check(x between 0 and 1280 and y between 0 and 720)
);
alter table public.player_movement_guard enable row level security;
revoke all on public.player_movement_guard from anon,authenticated;
grant all on public.player_movement_guard to service_role;

create or replace function public.submit_player_position(p_user_id uuid,p_x double precision,p_y double precision)
returns jsonb language plpgsql security definer set search_path = '' as $function$
declare
 v_old public.player_movement_guard%rowtype;
 v_now timestamptz:=clock_timestamp();
 v_elapsed double precision;
 v_distance double precision;
 v_limit double precision;
 v_ai public.world_monster_ai%rowtype;
 v_players jsonb;
begin
 if p_user_id is null then raise exception 'invalid_player'; end if;
 if p_x is null or p_y is null or p_x<0 or p_x>1280 or p_y<0 or p_y>720 then
  return jsonb_build_object('ok',false,'code','position_out_of_bounds');
 end if;
 insert into public.player_movement_guard(user_id,x,y,last_move_at,updated_at)
 values(p_user_id,620,390,v_now,v_now) on conflict(user_id) do nothing;
 select * into v_old from public.player_movement_guard where user_id=p_user_id for update;
 v_elapsed:=greatest(0.05,extract(epoch from(v_now-v_old.last_move_at)));
 v_distance:=sqrt(power(p_x-v_old.x,2)+power(p_y-v_old.y,2));
 v_limit:=450*v_elapsed+12;
 if v_distance>v_limit then
  return jsonb_build_object('ok',false,'code','movement_too_fast','server_x',v_old.x,'server_y',v_old.y);
 end if;
 update public.player_movement_guard set x=p_x,y=p_y,last_move_at=v_now,updated_at=v_now where user_id=p_user_id;
 insert into public.game_presence(user_id,nickname,room_code,x,y,updated_at)
 select p_user_id,coalesce(pp.nickname,'Người chơi'),'village',p_x,p_y,v_now
 from public.player_profiles pp where pp.user_id=p_user_id
 on conflict(user_id) do update
 set nickname=excluded.nickname,room_code='village',x=excluded.x,y=excluded.y,updated_at=excluded.updated_at;
 select * into v_ai from public.world_monster_ai where room_code='village' and monster_code='slime';
 select coalesce(jsonb_agg(jsonb_build_object('user_id',gp.user_id,'nickname',gp.nickname,'x',gp.x,'y',gp.y,'updated_at',gp.updated_at)),'[]'::jsonb)
 into v_players from public.game_presence gp
 where gp.room_code='village' and gp.updated_at>v_now-interval '15 seconds';
 return jsonb_build_object('ok',true,'x',p_x,'y',p_y,
  'monster',jsonb_build_object('code','slime','x',coalesce(v_ai.x,640),'y',coalesce(v_ai.y,350)),
  'players',v_players);
end;
$function$;
revoke all on function public.submit_player_position(uuid,double precision,double precision) from public,anon,authenticated;
grant execute on function public.submit_player_position(uuid,double precision,double precision) to service_role;
