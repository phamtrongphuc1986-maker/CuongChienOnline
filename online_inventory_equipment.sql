-- Catalog and server-authoritative player inventory/equipment.
create table if not exists public.game_item_catalog (
 item_code text primary key,item_name text not null,item_type text not null check(item_type in('weapon','armor','helmet','boots','potion')),
 equip_slot text,attack_bonus integer not null default 0,defense_bonus integer not null default 0,hp_bonus integer not null default 0,
 heal_amount integer not null default 0,price bigint not null default 0,max_stack integer not null default 99,
 constraint item_catalog_slot check((item_type in('weapon','armor','helmet','boots') and equip_slot is not null) or (item_type='potion' and equip_slot is null)),
 constraint item_catalog_nonnegative check(attack_bonus>=0 and defense_bonus>=0 and hp_bonus>=0 and heal_amount>=0 and price>=0 and max_stack>0));
insert into public.game_item_catalog(item_code,item_name,item_type,equip_slot,attack_bonus,defense_bonus,hp_bonus,heal_amount,price,max_stack) values
('wood_sword','Kiếm Gỗ','weapon','weapon',5,0,0,0,100,1),
('iron_sword','Kiếm Sắt','weapon','weapon',12,0,0,0,500,1),
('leather_armor','Áo Da','armor','armor',0,5,20,0,250,1),
('iron_helmet','Mũ Sắt','helmet','helmet',0,3,10,0,180,1),
('swift_boots','Giày Nhanh','boots','boots',0,2,0,0,220,1),
('hp_potion','Bình Máu','potion',null,0,0,0,55,30,99)
on conflict(item_code) do update set item_name=excluded.item_name,attack_bonus=excluded.attack_bonus,defense_bonus=excluded.defense_bonus,hp_bonus=excluded.hp_bonus,heal_amount=excluded.heal_amount,price=excluded.price;
alter table public.game_item_catalog enable row level security;
revoke all on public.game_item_catalog from anon,authenticated; grant all on public.game_item_catalog to service_role;

create table if not exists public.player_vitals(user_id uuid primary key references auth.users(id) on delete cascade,hp integer not null default 100,max_hp integer not null default 100,updated_at timestamptz not null default now(),constraint player_vitals_range check(hp>=0 and max_hp>0 and hp<=max_hp));
alter table public.player_vitals enable row level security;
revoke all on public.player_vitals from anon,authenticated; grant all on public.player_vitals to service_role;

create or replace function public.game_inventory_action(p_user_id uuid,p_action text,p_item_code text default null)
returns jsonb language plpgsql security definer set search_path = '' as $function$
declare v_profile public.player_profiles%rowtype; v_item public.game_item_catalog%rowtype; v_inv public.inventory_items%rowtype; v_vitals public.player_vitals%rowtype; v_attack integer; v_defense integer; v_hp_bonus integer;
begin
 if p_user_id is null then raise exception 'invalid_player'; end if;
 select * into v_profile from public.player_profiles where user_id=p_user_id for update;
 if not found then raise exception 'player_profile_not_found'; end if;
 insert into public.player_vitals(user_id,hp,max_hp) values(p_user_id,100,100) on conflict(user_id) do nothing;
 select * into v_vitals from public.player_vitals where user_id=p_user_id for update;
 if p_action='catalog' then return jsonb_build_object('ok',true,'items',(select coalesce(jsonb_agg(jsonb_build_object('item_code',item_code,'item_name',item_name,'item_type',item_type,'price',price) order by price),'[]'::jsonb) from public.game_item_catalog)); end if;
 if p_item_code is null then return jsonb_build_object('ok',false,'code','missing_item_code'); end if;
 select * into v_item from public.game_item_catalog where item_code=p_item_code;
 if not found then return jsonb_build_object('ok',false,'code','unknown_item'); end if;
 if p_action='buy' then
  if v_profile.gold<v_item.price then return jsonb_build_object('ok',false,'code','not_enough_gold','gold',v_profile.gold); end if;
  select * into v_inv from public.inventory_items where user_id=p_user_id and item_code=p_item_code and equipped=false for update;
  if found then if v_inv.quantity>=v_item.max_stack then return jsonb_build_object('ok',false,'code','stack_full'); end if; update public.inventory_items set quantity=quantity+1 where id=v_inv.id;
  else insert into public.inventory_items(user_id,item_code,quantity,equipped) values(p_user_id,p_item_code,1,false); end if;
  update public.player_profiles set gold=gold-v_item.price,updated_at=now() where user_id=p_user_id returning * into v_profile;
 elsif p_action='equip' then
  if v_item.item_type='potion' then return jsonb_build_object('ok',false,'code','cannot_equip'); end if;
  select * into v_inv from public.inventory_items where user_id=p_user_id and item_code=p_item_code and quantity>0 for update;
  if not found then return jsonb_build_object('ok',false,'code','item_not_owned'); end if;
  update public.inventory_items i set equipped=false from public.game_item_catalog c where i.user_id=p_user_id and i.equipped=true and c.item_code=i.item_code and c.equip_slot=v_item.equip_slot;
  update public.inventory_items set equipped=true where id=v_inv.id;
 elsif p_action='unequip' then update public.inventory_items set equipped=false where user_id=p_user_id and item_code=p_item_code;
 elsif p_action='use' then
  if v_item.item_type<>'potion' then return jsonb_build_object('ok',false,'code','not_consumable'); end if;
  select * into v_inv from public.inventory_items where user_id=p_user_id and item_code=p_item_code and quantity>0 and equipped=false for update;
  if not found then return jsonb_build_object('ok',false,'code','item_not_owned'); end if;
  update public.player_vitals set hp=least(max_hp,hp+v_item.heal_amount),updated_at=now() where user_id=p_user_id returning * into v_vitals;
  if v_inv.quantity=1 then delete from public.inventory_items where id=v_inv.id; else update public.inventory_items set quantity=quantity-1 where id=v_inv.id; end if;
 else return jsonb_build_object('ok',false,'code','unknown_inventory_action'); end if;
 select coalesce(sum(c.attack_bonus),0),coalesce(sum(c.defense_bonus),0),coalesce(sum(c.hp_bonus),0) into v_attack,v_defense,v_hp_bonus
 from public.inventory_items i join public.game_item_catalog c on c.item_code=i.item_code where i.user_id=p_user_id and i.equipped=true;
 update public.player_vitals set max_hp=100+v_hp_bonus,hp=least(hp,100+v_hp_bonus),updated_at=now() where user_id=p_user_id returning * into v_vitals;
 return jsonb_build_object('ok',true,'action',p_action,'gold',v_profile.gold,'attack_bonus',v_attack,'defense_bonus',v_defense,'max_hp',v_vitals.max_hp,'hp',v_vitals.hp,
 'inventory',(select coalesce(jsonb_agg(jsonb_build_object('item_code',i.item_code,'quantity',i.quantity,'equipped',i.equipped,'item_name',c.item_name,'item_type',c.item_type,'attack_bonus',c.attack_bonus,'defense_bonus',c.defense_bonus,'hp_bonus',c.hp_bonus)), '[]'::jsonb) from public.inventory_items i join public.game_item_catalog c on c.item_code=i.item_code where i.user_id=p_user_id));
end;$function$;
revoke all on function public.game_inventory_action(uuid,text,text) from public,anon,authenticated; grant execute on function public.game_inventory_action(uuid,text,text) to service_role;

create or replace function public.get_inventory_state(p_user_id uuid)
returns jsonb language plpgsql security definer set search_path = '' as $function$
declare v_vitals public.player_vitals%rowtype;v_profile public.player_profiles%rowtype;v_attack integer;v_defense integer;v_hp_bonus integer;
begin
 select * into v_profile from public.player_profiles where user_id=p_user_id;if not found then raise exception 'player_profile_not_found';end if;
 insert into public.player_vitals(user_id,hp,max_hp) values(p_user_id,100,100) on conflict(user_id) do nothing;
 select * into v_vitals from public.player_vitals where user_id=p_user_id;
 select coalesce(sum(c.attack_bonus),0),coalesce(sum(c.defense_bonus),0),coalesce(sum(c.hp_bonus),0) into v_attack,v_defense,v_hp_bonus from public.inventory_items i join public.game_item_catalog c on c.item_code=i.item_code where i.user_id=p_user_id and i.equipped=true;
 return jsonb_build_object('ok',true,'gold',v_profile.gold,'hp',v_vitals.hp,'max_hp',v_vitals.max_hp,'attack_bonus',v_attack,'defense_bonus',v_defense,
 'items',(select coalesce(jsonb_agg(jsonb_build_object('item_code',c.item_code,'item_name',c.item_name,'item_type',c.item_type,'quantity',coalesce(i.quantity,0),'equipped',coalesce(i.equipped,false),'price',c.price,'attack_bonus',c.attack_bonus,'defense_bonus',c.defense_bonus,'hp_bonus',c.hp_bonus,'heal_amount',c.heal_amount) order by c.price),'[]'::jsonb) from public.game_item_catalog c left join public.inventory_items i on i.item_code=c.item_code and i.user_id=p_user_id));
end;$function$;
revoke all on function public.get_inventory_state(uuid) from public,anon,authenticated;grant execute on function public.get_inventory_state(uuid) to service_role;
