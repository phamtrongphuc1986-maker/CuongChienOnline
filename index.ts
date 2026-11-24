import { createClient } from "npm:@supabase/supabase-js@2";
const corsHeaders = {"Access-Control-Allow-Origin":"*","Access-Control-Allow-Headers":"authorization, x-client-info, apikey, content-type","Access-Control-Allow-Methods":"POST, OPTIONS"};
function json(data:unknown,status=200){return new Response(JSON.stringify(data),{status,headers:{...corsHeaders,"Content-Type":"application/json"}});}
Deno.serve(async(req:Request)=>{
 if(req.method==="OPTIONS")return new Response("ok",{headers:corsHeaders});
 if(req.method!=="POST")return json({ok:false,error:"method_not_allowed"},405);
 const h=req.headers.get("Authorization")??"";const token=h.startsWith("Bearer ")?h.slice(7):"";
 if(!token)return json({ok:false,error:"missing_bearer_token"},401);
 const url=Deno.env.get("SUPABASE_URL"),anon=Deno.env.get("SUPABASE_ANON_KEY"),service=Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
 if(!url||!anon||!service)return json({ok:false,error:"server_environment_not_configured"},500);
 const auth=createClient(url,anon,{auth:{persistSession:false,autoRefreshToken:false}});
 const {data:u,error:ae}=await auth.auth.getUser(token);if(ae||!u.user)return json({ok:false,error:"invalid_or_expired_session"},401);
 const admin=createClient(url,service,{auth:{persistSession:false,autoRefreshToken:false}});
 let body:{action?:string;skill_code?:string;item_action?:string;item_code?:string};
 try{body=await req.json();}catch{return json({ok:false,error:"invalid_json"},400);}
 const uid=u.user.id;
 if(body.action==="inventory_state"){
  const {data,error}=await admin.rpc("get_inventory_state",{p_user_id:uid});
  if(error)return json({ok:false,error:"inventory_state_failed"},500);return json(data);
 }
 if(body.action==="inventory"){
  const {data,error}=await admin.rpc("game_inventory_action",{p_user_id:uid,p_action:body.item_action??"catalog",p_item_code:body.item_code??null});
  if(error)return json({ok:false,error:"inventory_action_failed"},500);return json(data);
 }
 if(body.action==="state"||body.action==="skill_state"){
  const [{data:profile,error:pe},{data:monster,error:me},{data:skills,error:se},{data:vitals,error:ve}]=await Promise.all([
   admin.from("player_profiles").select("nickname,level,experience,gold").eq("user_id",uid).maybeSingle(),
   admin.from("world_monsters").select("monster_code,monster_hp,monster_max_hp").eq("room_code","village").eq("monster_code","slime").maybeSingle(),
   admin.rpc("get_player_skill_state",{p_user_id:uid}),
   admin.from("player_vitals").select("hp,max_hp").eq("user_id",uid).maybeSingle()]);
  if(pe||me||se||ve)return json({ok:false,error:"state_read_failed"},500);if(!profile)return json({ok:false,error:"player_profile_not_found"},404);
  return json({ok:true,action:"state",profile,monster:{monster_code:"slime",hp:monster?.monster_hp??(100+profile.level*20),max_hp:monster?.monster_max_hp??(100+profile.level*20)},skills:skills??{mana:100,max_mana:100},vitals:vitals??{hp:100,max_hp:100}});
 }
 if(body.action==="move_position"){
  const x=Number(body.x),y=Number(body.y);
  if(!Number.isFinite(x)||!Number.isFinite(y))return json({ok:false,error:"invalid_position"},400);
  const {data,error}=await admin.rpc("submit_player_position",{p_user_id:uid,p_x:x,p_y:y});
  if(error)return json({ok:false,error:"movement_validation_failed",detail:error.message},500);return json(data);
 }
 if(body.action==="player_hit"){
  const {data,error}=await admin.rpc("resolve_player_monster_hit",{p_user_id:uid,p_monster_code:body.monster_code??"slime"});
  if(error)return json({ok:false,error:"player_hit_resolution_failed"},500);return json(data);
 }
 if(body.action==="attack"){const {data,error}=await admin.rpc("resolve_combat_attack",{p_user_id:uid});if(error)return json({ok:false,error:"combat_resolution_failed"},500);return json(data);}
 if(body.action==="skill_attack"){const {data,error}=await admin.rpc("resolve_skill_attack",{p_user_id:uid,p_skill_code:body.skill_code??""});if(error)return json({ok:false,error:"skill_resolution_failed"},500);return json(data);}
 if(body.action==="boss_state"){
  const [{data:profile,error:pe},{data:boss,error:be}]=await Promise.all([
   admin.from("player_profiles").select("nickname,level,experience,gold").eq("user_id",uid).maybeSingle(),
   admin.from("world_boss").select("boss_name,boss_hp,boss_max_hp,is_defeated").eq("boss_id","village_dragon").maybeSingle()]);
  if(pe||be)return json({ok:false,error:"boss_state_read_failed"},500);if(!profile||!boss)return json({ok:false,error:"boss_or_profile_not_found"},404);
  return json({ok:true,action:"boss_state",profile,boss:{name:boss.boss_name,hp:boss.boss_hp,max_hp:boss.boss_max_hp,defeated:boss.is_defeated}});
 }
 if(body.action==="boss_attack"){const {data,error}=await admin.rpc("resolve_boss_attack",{p_user_id:uid});if(error)return json({ok:false,error:"boss_combat_resolution_failed"},500);return json(data);}
 if(body.action==="boss_leaderboard"){
  const {data,error}=await admin.from("world_boss_damage").select("nickname,total_damage,attacks,reward_claimed").eq("boss_id","village_dragon").order("total_damage",{ascending:false}).limit(10);
  if(error)return json({ok:false,error:"boss_leaderboard_failed"},500);return json({ok:true,action:"boss_leaderboard",entries:data??[]});
 }
 return json({ok:false,error:"unknown_action"},400);
});