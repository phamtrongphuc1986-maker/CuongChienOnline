extends Node2D

# CUONG CHIEN ONLINE - Prototype V2
# Chạy offline để kiểm tra gameplay. Chưa bật multiplayer server.

const WORLD := Vector2(1280, 720)
const PLAYER_SPEED := 255.0
const ATTACK_RANGE := 165.0
const ATTACK_COOLDOWN := 0.55
const SAVE_PATH := "user://player_save.json"

var player := Vector2(620, 390)
var joystick_origin := Vector2.ZERO
var joystick_vector := Vector2.ZERO
var joystick_active := false
var attack_timer := 0.0
var skill_timer := 0.0
var attack_flash := 0.0
var hp := 120
var max_hp := 120
var level := 1
var exp := 0
var exp_need := 60
var gold := 0
var potions := 3
var weapon_level := 1
var skill_level := 1
var inventory_open := false
var status_message := "KÉO BÊN TRÁI ĐỂ DI CHUYỂN • CHẠM BÊN PHẢI ĐỂ ĐÁNH"
var mobs: Array[Dictionary] = []
var effects: Array[Dictionary] = []
var rng := RandomNumberGenerator.new()
var boss_spawned := false
var boss_defeated := 0

# Supabase Realtime WebSocket: shared-room presence + position broadcast.
# This is a prototype presence/movement layer, not an authoritative combat server.
const SUPABASE_URL := "https://slupzdmsahhhqbeetoig.supabase.co"
const SUPABASE_KEY := "sb_publishable_mysIN9YPv8JrUmPInapQ_OvtnzomQ"
const REALTIME_TOPIC := "realtime:game-village"

var realtime_socket := WebSocketPeer.new()
var realtime_joined := false
var realtime_join_ref := ""
var realtime_ref_counter := 0
var network_send_timer := 0.0
var movement_sync_timer := 0.0
var incoming_hit_pending := false
var heartbeat_timer := 0.0
var reconnect_timer := 0.0
var remote_players: Dictionary = {}
var remote_player_seen: Dictionary = {}
var network_status := "ĐANG KẾT NỐI..."
var multiplayer_enabled := false

# Combat server API. Never put the service-role key in the Android client.
const COMBAT_ENDPOINT := "https://slupzdmsahhhqbeetoig.supabase.co/functions/v1/game-combat"
var combat_http: HTTPRequest
var combat_pending := false
var online_combat_enabled := false
var server_monster_hp := 100
var server_monster_max_hp := 100
var mana := 100
var max_mana := 100
var inventory_entries: Array = []
var inventory_attack_bonus := 0
var inventory_defense_bonus := 0
var equipped_weapon_code := ""
var equipped_armor_code := ""
var equipped_helmet_code := ""
var equipped_boots_code := ""
var shared_state_timer := 2.0
var boss_panel_open := false
var boss_hp := 10000
var boss_max_hp := 10000
var boss_is_defeated := false
var boss_leaderboard_open := false
var boss_leaderboard_entries: Array = []
var combat_request_action := ""

var attack_damage: int:
	get: return 22 + level * 5 + weapon_level * 9

func _ready() -> void:
	rng.randomize()
	combat_http = HTTPRequest.new()
	combat_http.timeout = 15.0
	add_child(combat_http)
	combat_http.request_completed.connect(_on_combat_request_completed)
	_setup_multiplayer()
	if GameSession.is_authenticated:
		online_combat_enabled = true
		_request_combat_state()
		_request_boss_state()
	_load_save()
	if online_combat_enabled:
		_spawn_mob(false)
	else:
		for i in range(7):
			_spawn_mob(false)
	queue_redraw()

func _process(delta: float) -> void:
	_process_multiplayer(delta)
	if online_combat_enabled and not combat_pending:
		shared_state_timer -= delta
		if shared_state_timer <= 0.0:
			shared_state_timer = 2.0
			if boss_panel_open:
				_request_boss_state()
			else:
				_request_combat_state()
	var move := joystick_vector
	if Input.is_action_pressed("ui_left"): move.x -= 1.0
	if Input.is_action_pressed("ui_right"): move.x += 1.0
	if Input.is_action_pressed("ui_up"): move.y -= 1.0
	if Input.is_action_pressed("ui_down"): move.y += 1.0
	if move.length() > 1.0: move = move.normalized()
	player += move * PLAYER_SPEED * delta
	player.x = clampf(player.x, 35, WORLD.x - 35)
	player.y = clampf(player.y, 120, WORLD.y - 35)
	if online_combat_enabled:
		movement_sync_timer -= delta
		if movement_sync_timer <= 0.0 and not combat_pending:
			movement_sync_timer = 0.25
			_send_combat_request({"action": "move_position", "x": player.x, "y": player.y})

	attack_timer = maxf(0.0, attack_timer - delta)
	skill_timer = maxf(0.0, skill_timer - delta)
	attack_flash = maxf(0.0, attack_flash - delta)

	# Tự động đánh mục tiêu gần nhất trong tầm.
	if attack_timer <= 0.0:
		var target := _nearest_mob()
		if target >= 0 and player.distance_to(mobs[target].pos) <= ATTACK_RANGE:
			_attack(target)

	# Quái đuổi người chơi và gây sát thương khi áp sát.
	for i in range(mobs.size() - 1, -1, -1):
		var mob: Dictionary = mobs[i]
		var toward: Vector2 = player - mob.pos
		var dist := toward.length()
		if online_combat_enabled:
			# Monster position is supplied by server AI in move_position response.
			pass
		elif dist > 38.0:
			mob.pos += toward.normalized() * float(mob.speed) * delta
		else:
			mob.hit_timer = float(mob.get("hit_timer", 0.0)) - delta
			if mob.hit_timer <= 0.0:
				hp = maxi(0, hp - maxi(1, (12 if mob.boss else 5) - inventory_defense_bonus))
				mob.hit_timer = 1.0
				if hp <= 0:
					hp = max_hp
					player = Vector2(620, 390)
					status_message = "BẠN ĐÃ HỒI SINH TẠI ĐIỂM AN TOÀN"
		if int(mob.hp) <= 0:
			_kill_mob(mob)
			mobs.remove_at(i)
			if online_combat_enabled:
				# Online rewards and progression are issued only by the server.
				if bool(mob.boss): boss_spawned = false
				_spawn_mob(false)
				if not mobs.is_empty():
					# The server returns 0 HP for the defeated monster; show the next spawn full.
					mobs[mobs.size() - 1].hp = server_monster_max_hp
					mobs[mobs.size() - 1].max_hp = server_monster_max_hp
			else:
				if bool(mob.boss):
					boss_spawned = false
					boss_defeated += 1
					gold += 100
					exp += 100
					status_message = "HẠ BOSS THÀNH CÔNG! +100 VÀNG"
				else:
					gold += rng.randi_range(2, 8)
					exp += 14
					if rng.randf() < 0.16: potions += 1
				_check_level()
				_spawn_mob(false)
		else:
			mobs[i] = mob

	for i in range(effects.size() - 1, -1, -1):
		effects[i].life -= delta
		effects[i].pos += effects[i].vel * delta
		if effects[i].life <= 0.0: effects.remove_at(i)

	queue_redraw()

func _input(event: InputEvent) -> void:
	if event is InputEventScreenTouch:
		if event.pressed:
			_handle_press(event.position)
		else:
			joystick_active = false
			joystick_vector = Vector2.ZERO
	elif event is InputEventScreenDrag and joystick_active:
		joystick_vector = ((event.position - joystick_origin) / 76.0).limit_length(1.0)
	elif event is InputEventMouseButton:
		if event.pressed: _handle_press(event.position)
		else:
			joystick_active = false
			joystick_vector = Vector2.ZERO
	elif event is InputEventMouseMotion and joystick_active and Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT):
		joystick_vector = ((event.position - joystick_origin) / 76.0).limit_length(1.0)

func _handle_press(p: Vector2) -> void:
	var view := get_viewport_rect().size
	var sx := p.x * WORLD.x / maxf(1.0, view.x)
	var sy := p.y * WORLD.y / maxf(1.0, view.y)
	var q := Vector2(sx, sy)
	if q.y < 105.0 and q.x > 1040.0:
		if q.y < 52.0:
			_save_game()
			status_message = "ĐÃ LƯU NHÂN VẬT"
		else:
			inventory_open = not inventory_open
			if inventory_open and online_combat_enabled:
				_request_inventory_state()
	elif inventory_open and q.x >= 350.0 and q.x <= 930.0 and q.y >= 155.0 and q.y <= 545.0:
		if q.x >= 850.0 and q.y <= 225.0:
			inventory_open = false
		else:
			var row_index := int((q.y - 245.0) / 43.0)
			if row_index >= 0 and row_index < inventory_entries.size():
				var selected: Dictionary = inventory_entries[row_index]
				var item_code := str(selected.get("item_code",""))
				var qty := int(selected.get("quantity",0))
				var item_type := str(selected.get("item_type",""))
				if qty <= 0:
					_inventory_action("buy",item_code)
				elif item_type == "potion":
					_inventory_action("use",item_code)
				else:
					_inventory_action("equip" if not bool(selected.get("equipped",false)) else "unequip",item_code)
	elif q.y > 545.0 and q.x > 1120.0:
		_use_potion()
	elif q.y > 545.0 and q.x > 1015.0:
		_use_skill("thunder_strike")
	elif q.y > 545.0 and q.x > 910.0:
		_use_skill("sword_wave")
	elif q.y > 545.0 and q.x > 600.0 and q.x <= 760.0:
		boss_leaderboard_open = not boss_leaderboard_open
		if boss_leaderboard_open:
			_request_boss_leaderboard()
			status_message = "ĐANG TẢI BẢNG XẾP HẠNG BOSS"
		else:
			status_message = "ĐÃ ĐÓNG BẢNG XẾP HẠNG"
	elif q.y > 545.0 and q.x > 760.0:
		_summon_boss()
	elif q.x < WORLD.x * 0.5:
		joystick_active = true
		joystick_origin = q
		joystick_vector = Vector2.ZERO
	else:
		_manual_attack()

func _manual_attack() -> void:
	if attack_timer > 0.0: return
	var idx := _nearest_mob()
	if idx >= 0 and player.distance_to(mobs[idx].pos) <= ATTACK_RANGE + 100.0:
		_attack(idx)

func _summon_boss() -> void:
	if online_combat_enabled:
		if not boss_panel_open:
			boss_panel_open = true
			_request_boss_state()
			status_message = "ĐANG MỞ THÔNG TIN HẮC LONG VƯƠNG"
		else:
			_request_boss_attack()
		return
	if boss_spawned:
		status_message = "BOSS ĐÃ XUẤT HIỆN TRÊN BẢN ĐỒ"
		return
	boss_spawned = true
	_spawn_mob(true)
	status_message = "BOSS ĐÃ XUẤT HIỆN! HÃY CHUẨN BỊ!"

func _use_skill(skill_code: String = "sword_wave") -> void:
	if online_combat_enabled:
		if skill_timer > 0.0 or combat_pending:
			return
		skill_timer = 5.0 if skill_code == "sword_wave" else 8.0
		attack_flash = 0.35
		_send_combat_request({"action": "skill_attack", "skill_code": skill_code})
		return
	if skill_timer > 0.0: return
	skill_timer = 5.0
	attack_flash = 0.35
	var hit_count := 0
	for i in range(mobs.size()):
		if player.distance_to(mobs[i].pos) <= 245.0:
			mobs[i].hp -= attack_damage * (2 + skill_level)
			hit_count += 1
			for j in range(9):
				_add_effect(mobs[i].pos, Color("#8eeaff"))
	status_message = "KỸ NĂNG KIẾM KHÍ! TRÚNG %d MỤC TIÊU" % hit_count

func _use_potion() -> void:
	if potions <= 0:
		status_message = "ĐÃ HẾT BÌNH MÁU"
		return
	if hp >= max_hp:
		status_message = "HP ĐANG ĐẦY"
		return
	potions -= 1
	hp = mini(max_hp, hp + 55)
	status_message = "ĐÃ DÙNG BÌNH MÁU +55 HP"

func _nearest_mob() -> int:
	var best := -1
	var best_d := INF
	for i in range(mobs.size()):
		var d: float = player.distance_to(mobs[i].pos)
		if d < best_d:
			best_d = d
			best = i
	return best

func _attack(index: int) -> void:
	if online_combat_enabled:
		_request_combat_attack(index)
		return
	attack_timer = ATTACK_COOLDOWN
	attack_flash = 0.20
	mobs[index].hp -= attack_damage
	var dir: Vector2 = (mobs[index].pos - player).normalized()
	mobs[index].pos += dir * 18.0
	for j in range(6): _add_effect(mobs[index].pos, Color("#ffe18a"))

func _spawn_mob(is_boss: bool) -> void:
	var p := Vector2(rng.randf_range(80, WORLD.x - 80), rng.randf_range(155, WORLD.y - 70))
	if p.distance_to(player) < 240.0: p.x = WORLD.x - p.x
	var hp_value := 420 if is_boss else 65 + level * 10
	mobs.append({"pos":p, "hp":hp_value, "max_hp":hp_value,
		"speed":24.0 if is_boss else rng.randf_range(34.0, 55.0),
		"boss":is_boss, "hit_timer":0.5})

func _kill_mob(mob: Dictionary) -> void:
	for j in range(18 if mob.boss else 8):
		_add_effect(mob.pos, Color("#ffd65c") if mob.boss else Color("#ff9c6b"))

func _add_effect(p: Vector2, c: Color) -> void:
	effects.append({"pos":p, "vel":Vector2(rng.randf_range(-100,100),rng.randf_range(-100,100)), "life":0.35, "color":c})

func _check_level() -> void:
	while exp >= exp_need:
		exp -= exp_need
		level += 1
		exp_need = int(float(exp_need) * 1.32)
		max_hp += 18
		hp = max_hp
		status_message = "CHÚC MỪNG! ĐẠT CẤP %d" % level

func _save_game() -> void:
	var data := {"level":level,"exp":exp,"exp_need":exp_need,"gold":gold,"hp":hp,
		"max_hp":max_hp,"potions":potions,"weapon_level":weapon_level,
		"skill_level":skill_level,"boss_defeated":boss_defeated}
	var f := FileAccess.open(SAVE_PATH, FileAccess.WRITE)
	if f:
		f.store_string(JSON.stringify(data))
		f.close()

func _load_save() -> void:
	if not FileAccess.file_exists(SAVE_PATH): return
	var f := FileAccess.open(SAVE_PATH, FileAccess.READ)
	if not f: return
	var parsed = JSON.parse_string(f.get_as_text())
	f.close()
	if typeof(parsed) != TYPE_DICTIONARY: return
	level = int(parsed.get("level", 1))
	exp = int(parsed.get("exp", 0))
	exp_need = int(parsed.get("exp_need", 60))
	gold = int(parsed.get("gold", 0))
	hp = int(parsed.get("hp", 120))
	max_hp = int(parsed.get("max_hp", 120))
	potions = int(parsed.get("potions", 3))
	weapon_level = int(parsed.get("weapon_level", 1))
	skill_level = int(parsed.get("skill_level", 1))
	boss_defeated = int(parsed.get("boss_defeated", 0))

func _draw() -> void:
	draw_rect(Rect2(Vector2.ZERO, WORLD), Color("#294b35"))
	for x in range(0, 1280, 64):
		for y in range(100, 720, 64):
			draw_circle(Vector2(x+18,y+20),2,Color("#426447"))
			if (x+y)%5 == 0: draw_circle(Vector2(x+42,y+44),13,Color(0.12,0.25,0.16,0.25))
	# Lối mòn
	draw_rect(Rect2(0, 310, WORLD.x, 105), Color("#65533b"))
	for x in range(0,1280,90): draw_circle(Vector2(x,362),2,Color("#8b7653"))
	draw_rect(Rect2(0,0,1280,105),Color("#171e24"))
	draw_string(ThemeDB.fallback_font,Vector2(22,34),"CUỒNG CHIẾN • MOBILE",HORIZONTAL_ALIGNMENT_LEFT,-1,22,Color.WHITE)
	draw_string(ThemeDB.fallback_font,Vector2(22,72),"Cấp %d   EXP %d/%d   Vàng %d" % [level,exp,exp_need,gold],HORIZONTAL_ALIGNMENT_LEFT,-1,18,Color("#ffe59a"))
	draw_rect(Rect2(690,24,260,17),Color("#542c32"))
	draw_rect(Rect2(690,24,260.0*float(hp)/max_hp,17),Color("#d94b50"))
	draw_string(ThemeDB.fallback_font,Vector2(965,39),"HP %d/%d" % [hp,max_hp],HORIZONTAL_ALIGNMENT_LEFT,-1,15,Color.WHITE)
	draw_rect(Rect2(690,49,260,10),Color("#263a59"))
	draw_rect(Rect2(690,49,260.0*float(mana)/maxi(1,max_mana),10),Color("#3f9ee8"))
	draw_string(ThemeDB.fallback_font,Vector2(965,59),"MP %d/%d" % [mana,max_mana],HORIZONTAL_ALIGNMENT_LEFT,-1,12,Color("#b8e3ff"))
	draw_string(ThemeDB.fallback_font,Vector2(1060,73),"☰ TÚI",HORIZONTAL_ALIGNMENT_LEFT,-1,16,Color.WHITE)
	draw_string(ThemeDB.fallback_font,Vector2(1070,100),"LƯU",HORIZONTAL_ALIGNMENT_LEFT,-1,12,Color("#aee6ff"))

	for mob in mobs:
		var p: Vector2 = mob.pos
		var boss: bool = mob.boss
		var r := 31.0 if boss else 19.0
		draw_circle(p+Vector2(0,9),r+4,Color(0,0,0,0.25))
		draw_circle(p,r,Color("#6e3a9c") if boss else Color("#a94d43"))
		draw_circle(p+Vector2(-7,-5),4,Color.WHITE)
		draw_circle(p+Vector2(7,-5),4,Color.WHITE)
		draw_rect(Rect2(p.x-r,p.y-r-13,r*2,5),Color("#35232c"))
		draw_rect(Rect2(p.x-r,p.y-r-13,r*2*float(mob.hp)/mob.max_hp,5),Color("#f05454"))
		draw_string(ThemeDB.fallback_font,p+Vector2(-r,p.y*0+ r+17),"BOSS" if boss else "Yêu thú",HORIZONTAL_ALIGNMENT_LEFT,-1,12,Color("#ffe49b") if boss else Color.WHITE)

	# Draw other signed-in players in the shared village.
	for remote_id in remote_players.keys():
		var remote: Dictionary = remote_players[remote_id]
		var remote_pos := Vector2(float(remote.get("x",620.0)),float(remote.get("y",390.0)))
		draw_circle(remote_pos+Vector2(0,10),22,Color(0,0,0,0.22))
		draw_circle(remote_pos,19,Color("#58b9d8"))
		draw_circle(remote_pos+Vector2(-6,-5),3,Color.WHITE)
		draw_circle(remote_pos+Vector2(6,-5),3,Color.WHITE)
		draw_string(ThemeDB.fallback_font,remote_pos+Vector2(-42,-28),str(remote.get("nickname","Người chơi")),HORIZONTAL_ALIGNMENT_LEFT,110,13,Color("#b9f0ff"))
	draw_string(ThemeDB.fallback_font,Vector2(1000,26),"ONLINE • %d" % remote_players.size(),HORIZONTAL_ALIGNMENT_LEFT,240,15,Color("#8ef0b1"))
	draw_string(ThemeDB.fallback_font,Vector2(1000,47),network_status,HORIZONTAL_ALIGNMENT_LEFT,260,12,Color("#c7d4df"))
	if boss_panel_open:
		draw_rect(Rect2(360,112,560,68),Color(0.04,0.03,0.08,0.88),true)
		draw_string(ThemeDB.fallback_font,Vector2(385,136),"HẮC LONG VƯƠNG" + (" • ĐÃ BỊ HẠ" if boss_is_defeated else ""),HORIZONTAL_ALIGNMENT_LEFT,-1,18,Color("#ffd78a"))
		draw_rect(Rect2(385,146,500,12),Color("#3d252d"))
		var boss_ratio := clampf(float(boss_hp) / maxf(1.0,float(boss_max_hp)),0.0,1.0)
		draw_rect(Rect2(385,146,500.0*boss_ratio,12),Color("#c94c56"))
		draw_string(ThemeDB.fallback_font,Vector2(385,177),"HP %d / %d" % [boss_hp,boss_max_hp],HORIZONTAL_ALIGNMENT_LEFT,-1,13,Color.WHITE)
	if boss_leaderboard_open:
		draw_rect(Rect2(390,195,500,350),Color(0.025,0.035,0.055,0.96),true)
		draw_rect(Rect2(390,195,500,350),Color("#d2b36c"),false,2)
		draw_string(ThemeDB.fallback_font,Vector2(420,235),"TOP 10 SÁT THƯƠNG HẮC LONG VƯƠNG",HORIZONTAL_ALIGNMENT_LEFT,-1,19,Color("#ffe49b"))
		if boss_leaderboard_entries.is_empty():
			draw_string(ThemeDB.fallback_font,Vector2(420,280),"Chưa có dữ liệu đóng góp hoặc chưa tải được.",HORIZONTAL_ALIGNMENT_LEFT,440,15,Color.WHITE)
		else:
			for row_i in range(mini(10,boss_leaderboard_entries.size())):
				var entry: Dictionary = boss_leaderboard_entries[row_i]
				var row_text := "%d. %s     %s sát thương     %s lượt" % [row_i+1,str(entry.get("nickname","Người chơi")),str(entry.get("total_damage",0)),str(entry.get("attacks",0))]
				draw_string(ThemeDB.fallback_font,Vector2(420,275+row_i*25),row_text,HORIZONTAL_ALIGNMENT_LEFT,440,15,Color.WHITE)

	draw_circle(player+Vector2(0,13),25,Color(0,0,0,0.28))
	draw_circle(player,21,Color("#e6bd82"))
	var torso_color := Color("#2867a5") if equipped_armor_code == "" else Color("#8c6246")
	draw_rect(Rect2(player.x-15,player.y-2,30,26),torso_color)
	if equipped_armor_code == "leather_armor":
		draw_rect(Rect2(player.x-17,player.y-3,34,25),Color("#9a6845"),false,3)
	draw_circle(player+Vector2(0,-17),14,Color("#f1d1a4"))
	if equipped_helmet_code != "":
		draw_rect(Rect2(player.x-14,player.y-33,28,10),Color("#9ca8b5"))
		draw_rect(Rect2(player.x-11,player.y-39,22,8),Color("#c4ced7"))
	if equipped_weapon_code != "":
		draw_line(player+Vector2(15,1),player+Vector2(30,-22),Color("#d9e2eb"),5.0)
		draw_line(player+Vector2(12,-2),player+Vector2(22,5),Color("#80552f"),4.0)
	if equipped_boots_code != "":
		draw_rect(Rect2(player.x-15,player.y+20,12,7),Color("#694a36"))
		draw_rect(Rect2(player.x+3,player.y+20,12,7),Color("#694a36"))
	if attack_flash > 0: draw_arc(player,82,0,TAU,40,Color("#fff0a0"),7.0)
	for e in effects: draw_circle(e.pos,5,e.color)

	# Nút cảm ứng
	var joy := joystick_origin if joystick_active else Vector2(112,WORLD.y-110)
	draw_circle(joy,60,Color(0.05,0.07,0.09,0.35))
	draw_circle(joy+joystick_vector*42,26,Color(0.75,0.82,0.88,0.5))
	_draw_button(Vector2(680,620),"TOP BOSS",Color("#8a6730"))
	_draw_button(Vector2(850,620),"BOSS" if not online_combat_enabled else ("ĐÁNH BOSS" if boss_panel_open else "BOSS"),Color("#70428e"))
	_draw_button(Vector2(955,620),"KIẾM KHÍ",Color("#356d9c"))
	_draw_button(Vector2(1065,620),"LÔI ĐÌNH",Color("#5a4b9b"))
	_draw_button(Vector2(1190,620),"MÁU x%d" % potions,Color("#8d343b"))
	draw_string(ThemeDB.fallback_font,Vector2(22, WORLD.y-20),status_message,HORIZONTAL_ALIGNMENT_LEFT,-1,14,Color("#fff2c4"))

	if inventory_open:
		draw_rect(Rect2(350,155,580,390),Color(0.04,0.06,0.09,0.96),true)
		draw_rect(Rect2(350,155,580,390),Color("#d2b36c"),false,3)
		draw_string(ThemeDB.fallback_font,Vector2(390,205),"TÚI ĐỒ • CỬA HÀNG • TRANG BỊ",HORIZONTAL_ALIGNMENT_LEFT,-1,23,Color("#ffe49b"))
		draw_string(ThemeDB.fallback_font,Vector2(390,230),"Vàng %d  |  Công +%d  |  Thủ +%d" % [gold,inventory_attack_bonus,inventory_defense_bonus],HORIZONTAL_ALIGNMENT_LEFT,-1,16,Color.WHITE)
		if online_combat_enabled:
			if inventory_entries.is_empty():
				draw_string(ThemeDB.fallback_font,Vector2(390,280),"Đang tải danh sách vật phẩm...",HORIZONTAL_ALIGNMENT_LEFT,-1,16,Color.WHITE)
			else:
				for item_i in range(mini(6,inventory_entries.size())):
					var it: Dictionary = inventory_entries[item_i]
					var state_text := "ĐANG MẶC" if bool(it.get("equipped",false)) else ("SỞ HỮU x%d" % int(it.get("quantity",0)) if int(it.get("quantity",0))>0 else "MUA %d vàng" % int(it.get("price",0)))
					var line := "%s  •  %s  •  %s" % [str(it.get("item_name",it.get("item_code",""))),state_text,str(it.get("item_type",""))]
					draw_string(ThemeDB.fallback_font,Vector2(390,270+item_i*40),line,HORIZONTAL_ALIGNMENT_LEFT,500,15,Color.WHITE)
			draw_string(ThemeDB.fallback_font,Vector2(390,520),"Chạm một dòng: mua / mặc / dùng. Chạm TÚI để đóng.",HORIZONTAL_ALIGNMENT_LEFT,510,14,Color("#b8c7d9"))
		else:
			draw_string(ThemeDB.fallback_font,Vector2(390,280),"Đăng nhập để đồng bộ túi đồ online.",HORIZONTAL_ALIGNMENT_LEFT,-1,17,Color.WHITE)
		draw_string(ThemeDB.fallback_font,Vector2(870,205),"ĐÓNG",HORIZONTAL_ALIGNMENT_LEFT,-1,14,Color("#ffe49b"))

func _draw_button(p: Vector2, label: String, c: Color) -> void:
	draw_circle(p,54,c)
	draw_circle(p,54,Color(1,1,1,0.22),false,3.0)
	draw_string(ThemeDB.fallback_font,p+Vector2(-47,7),label,HORIZONTAL_ALIGNMENT_LEFT,-1,15,Color.WHITE)


func _setup_multiplayer() -> void:
	if not GameSession.is_authenticated:
		multiplayer_enabled = false
		network_status = "CHẾ ĐỘ NGOẠI TUYẾN"
		return
	multiplayer_enabled = true
	_connect_realtime()


func _connect_realtime() -> void:
	if not multiplayer_enabled:
		return
	realtime_socket = WebSocketPeer.new()
	realtime_joined = false
	var ws_url := "wss://slupzdmsahhhqbeetoig.supabase.co/realtime/v1/websocket?apikey=" + SUPABASE_KEY.uri_encode() + "&vsn=1.0.0"
	var err := realtime_socket.connect_to_url(ws_url)
	if err != OK:
		network_status = "KHÔNG TẠO ĐƯỢC KẾT NỐI REALTIME"
		reconnect_timer = 5.0
		return
	network_status = "ĐANG KẾT NỐI REALTIME..."


func _process_multiplayer(delta: float) -> void:
	if not multiplayer_enabled:
		return

	if realtime_socket.get_ready_state() == WebSocketPeer.STATE_CLOSED:
		realtime_joined = false
		reconnect_timer -= delta
		if reconnect_timer <= 0.0:
			reconnect_timer = 5.0
			_connect_realtime()
		return

	realtime_socket.poll()
	if realtime_socket.get_ready_state() == WebSocketPeer.STATE_OPEN and not realtime_joined:
		_join_realtime_channel()

	while realtime_socket.get_available_packet_count() > 0:
		var packet_text := realtime_socket.get_packet().get_string_from_utf8()
		var message = JSON.parse_string(packet_text)
		if message is Dictionary:
			_handle_realtime_message(message)

	var now_ms := Time.get_ticks_msec()
	for remote_id in remote_player_seen.keys():
		if now_ms - int(remote_player_seen[remote_id]) > 20000:
			remote_player_seen.erase(remote_id)
			remote_players.erase(remote_id)

	if realtime_joined:
		heartbeat_timer -= delta
		if heartbeat_timer <= 0.0:
			heartbeat_timer = 20.0
			_send_realtime_message("phoenix", "heartbeat", {}, false)


func _next_realtime_ref() -> String:
	realtime_ref_counter += 1
	return str(realtime_ref_counter)


func _send_realtime_message(topic: String, event_name: String, payload: Dictionary, include_join_ref: bool = true) -> void:
	if realtime_socket.get_ready_state() != WebSocketPeer.STATE_OPEN:
		return
	var ref := _next_realtime_ref()
	var message := {
		"topic": topic,
		"event": event_name,
		"payload": payload,
		"ref": ref
	}
	if include_join_ref:
		message["join_ref"] = realtime_join_ref
	realtime_socket.send_text(JSON.stringify(message))


func _join_realtime_channel() -> void:
	realtime_join_ref = _next_realtime_ref()
	var payload := {
		"config": {
			"broadcast": {"ack": false, "self": false},
			"presence": {"enabled": true, "key": GameSession.user_id},
			"postgres_changes": [],
			"private": true
		},
		"access_token": GameSession.access_token
	}
	var message := {
		"topic": REALTIME_TOPIC,
		"event": "phx_join",
		"payload": payload,
		"ref": realtime_join_ref,
		"join_ref": realtime_join_ref
	}
	realtime_socket.send_text(JSON.stringify(message))
	network_status = "ĐANG VÀO PHÒNG..."


func _handle_realtime_message(message: Dictionary) -> void:
	var event_name := str(message.get("event", ""))
	var payload = message.get("payload", {})

	if event_name == "phx_reply":
		if payload is Dictionary and str(payload.get("status", "")) == "ok":
			if str(message.get("ref", "")) == realtime_join_ref:
				realtime_joined = true
				network_status = "REALTIME ĐÃ KẾT NỐI"
				_track_presence()
		elif str(message.get("ref", "")) == realtime_join_ref:
			realtime_joined = false
			network_status = "MÁY CHỦ TỪ CHỐI VÀO PHÒNG"
	elif event_name == "phx_error" or event_name == "phx_close":
		realtime_joined = false
		network_status = "REALTIME BỊ NGẮT"
	elif event_name == "presence_state":
		_apply_presence_state(payload)
	elif event_name == "presence_diff":
		_apply_presence_diff(payload)
	elif event_name == "broadcast" and payload is Dictionary:
		var broadcast_event := str(payload.get("event", ""))
		var broadcast_data = payload.get("payload", {})
		if broadcast_data is Dictionary:
			if broadcast_event == "player_position":
				var remote_id := str(broadcast_data.get("user_id", ""))
				if not remote_id.is_empty() and remote_id != GameSession.user_id:
					remote_players[remote_id] = broadcast_data
					remote_player_seen[remote_id] = Time.get_ticks_msec()
			elif broadcast_event == "monster_position":
				if not mobs.is_empty():
					mobs[0].pos = Vector2(
						float(broadcast_data.get("x", mobs[0].pos.x)),
						float(broadcast_data.get("y", mobs[0].pos.y))
					)
				queue_redraw()


func _track_presence() -> void:
	var player_presence := {
		"nickname": GameSession.nickname,
		"level": level,
		"online": true
	}
	_send_realtime_message(REALTIME_TOPIC, "presence", {
		"type": "presence",
		"event": "track",
		"payload": player_presence
	})


func _broadcast_player_position() -> void:
	var data := {
		"user_id": GameSession.user_id,
		"nickname": GameSession.nickname,
		"level": level,
		"x": player.x,
		"y": player.y
	}
	_send_realtime_message(REALTIME_TOPIC, "broadcast", {
		"type": "broadcast",
		"event": "player_position",
		"payload": data
	})


func _presence_meta_to_player(user_key: String, meta: Dictionary) -> Dictionary:
	# Supabase Presence metas are commonly flattened; tolerate nested presence too.
	var source: Dictionary = meta
	if meta.get("presence", null) is Dictionary:
		source = meta["presence"]
	return {
		"user_id": user_key,
		"nickname": str(source.get("nickname", "Người chơi")),
		"level": int(source.get("level", 1)),
		"x": float(source.get("x", 620.0)),
		"y": float(source.get("y", 390.0))
	}


func _apply_presence_state(payload: Variant) -> void:
	if not (payload is Dictionary):
		return
	remote_players.clear()
	remote_player_seen.clear()
	for key in payload.keys():
		var user_key := str(key)
		if user_key == GameSession.user_id:
			continue
		var entries = payload[key]
		if entries is Array and not entries.is_empty() and entries[0] is Dictionary:
			remote_players[user_key] = _presence_meta_to_player(user_key, entries[0])
			remote_player_seen[user_key] = Time.get_ticks_msec()


func _apply_presence_diff(payload: Variant) -> void:
	if not (payload is Dictionary):
		return
	var joins = payload.get("joins", {})
	if joins is Dictionary:
		for key in joins.keys():
			var user_key := str(key)
			if user_key == GameSession.user_id:
				continue
			var entries = joins[key]
			if entries is Array and not entries.is_empty() and entries[0] is Dictionary:
				remote_players[user_key] = _presence_meta_to_player(user_key, entries[0])
				remote_player_seen[user_key] = Time.get_ticks_msec()
	var leaves = payload.get("leaves", {})
	if leaves is Dictionary:
		for key in leaves.keys():
			remote_players.erase(str(key))
			remote_player_seen.erase(str(key))


func _request_inventory_state() -> void:
	_send_combat_request({"action": "inventory_state"})

func _inventory_action(action: String, item_code: String) -> void:
	_send_combat_request({"action": "inventory", "item_action": action, "item_code": item_code})

func _request_boss_state() -> void:
	_send_combat_request({"action": "boss_state"})

func _request_boss_leaderboard() -> void:
	_send_combat_request({"action": "boss_leaderboard"})

func _request_boss_attack() -> void:
	if boss_is_defeated:
		status_message = "BOSS ĐÃ BỊ HẠ • CHỜ QUẢN TRỊ VIÊN HỒI SINH"
		return
	_send_combat_request({"action": "boss_attack"})

func _request_combat_state() -> void:
	_send_combat_request({"action": "state"})


func _request_combat_attack(mob_index: int) -> void:
	if combat_pending or mob_index < 0 or mob_index >= mobs.size():
		return
	attack_timer = 0.95
	attack_flash = 0.20
	for j in range(6): _add_effect(mobs[mob_index].pos, Color("#ffe18a"))
	_send_combat_request({"action": "attack"})


func _send_combat_request(body: Dictionary) -> void:
	if not GameSession.is_authenticated:
		status_message = "CẦN ĐĂNG NHẬP ĐỂ ĐÁNH ONLINE"
		return
	if combat_pending:
		return
	combat_pending = true
	combat_request_action = str(body.get("action", ""))
	var headers := PackedStringArray([
		"Content-Type: application/json",
		"apikey: " + SUPABASE_KEY,
		"Authorization: Bearer " + GameSession.access_token
	])
	var err := combat_http.request(COMBAT_ENDPOINT, headers, HTTPClient.METHOD_POST, JSON.stringify(body))
	if err != OK:
		combat_pending = false
		status_message = "KHÔNG GỬI ĐƯỢC LỆNH CHIẾN ĐẤU"


func _on_combat_request_completed(result: int, response_code: int, _headers: PackedStringArray, body: PackedByteArray) -> void:
	combat_pending = false
	var requested_action := combat_request_action
	combat_request_action = ""
	if requested_action == "player_hit":
		incoming_hit_pending = false
	if result != HTTPRequest.RESULT_SUCCESS:
		status_message = "LỖI KẾT NỐI MÁY CHỦ CHIẾN ĐẤU"
		return
	var parsed = JSON.parse_string(body.get_string_from_utf8())
	if response_code < 200 or response_code >= 300 or not (parsed is Dictionary):
		status_message = "MÁY CHỦ TỪ CHỐI: HTTP %d" % response_code
		return

	if requested_action == "move_position":
		if bool(parsed.get("ok", false)):
			var monster_data = parsed.get("monster", {})
			if monster_data is Dictionary and not mobs.is_empty():
				mobs[0].pos = Vector2(float(monster_data.get("x", 640.0)), float(monster_data.get("y", 350.0)))
			var players_data = parsed.get("players", [])
			if players_data is Array:
				for player_data in players_data:
					if player_data is Dictionary:
						var remote_id := str(player_data.get("user_id", ""))
						if not remote_id.is_empty() and remote_id != GameSession.user_id:
							remote_players[remote_id] = player_data
							remote_player_seen[remote_id] = Time.get_ticks_msec()
			var hit_data = parsed.get("monster_hit", null)
			if hit_data is Dictionary and bool(hit_data.get("ok", false)):
				hp = int(hit_data.get("hp", hp))
				max_hp = int(hit_data.get("max_hp", max_hp))
				if bool(hit_data.get("dead", false)):
					player = Vector2(620, 390)
					status_message = "BẠN ĐÃ GỤC NGÃ • HỒI SINH TẠI LÀNG"
				else:
					status_message = "QUÁI TẤN CÔNG -%d HP" % int(hit_data.get("damage", 0))
		elif str(parsed.get("code", "")) == "movement_too_fast":
			player = Vector2(float(parsed.get("server_x", player.x)), float(parsed.get("server_y", player.y)))
			status_message = "DI CHUYỂN QUÁ NHANH - ĐÃ ĐỒNG BỘ LẠI"
		queue_redraw()
		return

	if requested_action == "player_hit":
		incoming_hit_pending = false
		if bool(parsed.get("ok", false)):
			hp = int(parsed.get("hp", hp))
			max_hp = int(parsed.get("max_hp", max_hp))
			var received := int(parsed.get("damage", 0))
			if bool(parsed.get("dead", false)):
				player = Vector2(620, 390)
				status_message = "BẠN ĐÃ GỤC NGÃ • HỒI SINH TẠI LÀNG"
			else:
				status_message = "BỊ QUÁI TẤN CÔNG -%d HP" % received
		else:
			var hit_code := str(parsed.get("code", parsed.get("error", "")))
			if hit_code != "hit_cooldown":
				status_message = "LỖI ĐỒNG BỘ HP: " + hit_code
		queue_redraw()
		return

	if requested_action == "inventory_state" or requested_action == "inventory":
		if not bool(parsed.get("ok",false)):
			status_message = "TÚI ĐỒ: " + str(parsed.get("code",parsed.get("error","LỖI")))
			queue_redraw()
			return
		gold = int(parsed.get("gold",gold))
		hp = int(parsed.get("hp",hp))
		max_hp = int(parsed.get("max_hp",max_hp))
		inventory_attack_bonus = int(parsed.get("attack_bonus",inventory_attack_bonus))
		inventory_defense_bonus = int(parsed.get("defense_bonus",inventory_defense_bonus))
		var rows = parsed.get("items",parsed.get("inventory",[]))
		if rows is Array:
			inventory_entries.clear()
			equipped_weapon_code = ""
			equipped_armor_code = ""
			equipped_helmet_code = ""
			equipped_boots_code = ""
			for row in rows:
				if row is Dictionary:
					inventory_entries.append(row)
					if bool(row.get("equipped", false)):
						match str(row.get("item_type", "")):
							"weapon": equipped_weapon_code = str(row.get("item_code", ""))
							"armor": equipped_armor_code = str(row.get("item_code", ""))
							"helmet": equipped_helmet_code = str(row.get("item_code", ""))
							"boots": equipped_boots_code = str(row.get("item_code", ""))
		status_message = "ĐÃ CẬP NHẬT TÚI ĐỒ ONLINE"
		queue_redraw()
		return

	if requested_action == "boss_leaderboard":
		var entries = parsed.get("entries", [])
		boss_leaderboard_entries.clear()
		if entries is Array:
			for entry in entries:
				if entry is Dictionary:
					boss_leaderboard_entries.append(entry)
		status_message = "ĐÃ TẢI TOP %d NGƯỜI ĐÁNH BOSS" % boss_leaderboard_entries.size()
		queue_redraw()
		return

	if requested_action == "boss_state" or requested_action == "boss_attack":
		var boss_data = parsed.get("boss", {})
		if boss_data is Dictionary:
			boss_hp = int(boss_data.get("hp", boss_hp))
			boss_max_hp = int(boss_data.get("max_hp", boss_max_hp))
			boss_is_defeated = bool(boss_data.get("defeated", false))
		if not bool(parsed.get("ok", false)):
			var code := str(parsed.get("code", parsed.get("error", "boss_request_failed")))
			status_message = "BOSS: ĐÃ BỊ HẠ" if code == "boss_defeated" else ("BOSS: ĐANG HỒI CHIÊU" if code == "cooldown" else "LỖI BOSS: " + code)
			queue_redraw()
			return
		var boss_profile = parsed.get("profile", {})
		if boss_profile is Dictionary:
			level = int(boss_profile.get("level", level))
			exp = int(boss_profile.get("experience", exp))
			gold = int(boss_profile.get("gold", gold))
			exp_need = maxi(100, level * 100)
		if requested_action == "boss_attack":
			var boss_damage := int(parsed.get("damage", 0))
			status_message = "ĐÁNH BOSS %d SÁT THƯƠNG%s" % [boss_damage, " • BẠN HẠ BOSS! +250 EXP +500 VÀNG" if boss_is_defeated and int(parsed.get("experience_gain",0)) > 0 else ""]
		else:
			status_message = "ĐÃ ĐỒNG BỘ HẮC LONG VƯƠNG"
		queue_redraw()
		return

	if not bool(parsed.get("ok", false)):
		if parsed.has("mana"):
			mana = int(parsed.get("mana", mana))
			max_mana = int(parsed.get("max_mana", max_mana))
		var code := str(parsed.get("code", parsed.get("error", "LỆNH CHIẾN ĐẤU THẤT BẠI")))
		status_message = "KỸ NĂNG ĐANG HỒI CHIÊU" if code == "cooldown" else ("KHÔNG ĐỦ MP" if code == "not_enough_mana" else code)
		queue_redraw()
		return
	online_combat_enabled = true
	var profile = parsed.get("profile", parsed.get("player", {}))
	var monster = parsed.get("monster", {})
	if profile is Dictionary:
		level = int(profile.get("level", level))
		exp = int(profile.get("experience", exp))
		gold = int(profile.get("gold", gold))
		exp_need = maxi(100, level * 100)
	if monster is Dictionary:
		server_monster_hp = int(monster.get("hp", monster.get("monster_hp", parsed.get("monster_hp", server_monster_hp))))
		server_monster_max_hp = int(monster.get("max_hp", monster.get("monster_max_hp", parsed.get("monster_max_hp", server_monster_max_hp))))
	var skill_state = parsed.get("skills", {})
	if skill_state is Dictionary:
		mana = int(skill_state.get("mana", mana))
		max_mana = int(skill_state.get("max_mana", max_mana))
	if parsed.has("mana"):
		mana = int(parsed.get("mana", mana))
		max_mana = int(parsed.get("max_mana", max_mana))
	if requested_action == "skill_attack":
		var skill_damage := int(parsed.get("damage", 0))
		var skill_defeated := bool(parsed.get("defeated", false))
		var skill_target := _nearest_mob()
		if skill_target >= 0:
			mobs[skill_target].hp = 0 if skill_defeated else server_monster_hp
			mobs[skill_target].max_hp = server_monster_max_hp
			for fx in range(14):
				_add_effect(mobs[skill_target].pos, Color("#8eeaff"))
		status_message = "KIẾM KHÍ %d SÁT THƯƠNG%s" % [skill_damage, " • HẠ QUÁI" if skill_defeated else ""]
	elif requested_action == "attack":
		var damage := int(parsed.get("damage", 0))
		var defeated := bool(parsed.get("defeated", parsed.get("monster_defeated", false)))
		var target := _nearest_mob()
		if target >= 0:
			mobs[target].hp = 0 if defeated else server_monster_hp
			mobs[target].max_hp = server_monster_max_hp
		status_message = "ĐÁNH %d SÁT THƯƠNG%s" % [damage, " • HẠ QUÁI" if defeated else ""]
	elif requested_action == "state":
		var vitals = parsed.get("vitals", {})
		if vitals is Dictionary:
			hp = int(vitals.get("hp", hp))
			max_hp = int(vitals.get("max_hp", max_hp))
		if not mobs.is_empty():
			mobs[0].hp = server_monster_max_hp if server_monster_hp <= 0 else server_monster_hp
			mobs[0].max_hp = server_monster_max_hp
		status_message = "ĐÃ ĐỒNG BỘ QUÁI CHUNG VỚI MÁY CHỦ"
	queue_redraw()


func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_CLOSE_REQUEST:
		_leave_multiplayer()


func _leave_multiplayer() -> void:
	if realtime_socket.get_ready_state() == WebSocketPeer.STATE_OPEN:
		_send_realtime_message(REALTIME_TOPIC, "phx_leave", {})
		realtime_socket.close()
	realtime_joined = false
