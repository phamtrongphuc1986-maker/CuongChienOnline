extends Control

const SUPABASE_URL := "https://slupzdmsahhhqbeetoig.supabase.co"
const SUPABASE_KEY := "sb_publishable_mysIN9YPv8JrUmPInapQ_OvtnzomQ"
const SESSION_PATH := "user://session.json"

var http: HTTPRequest
var email_input: LineEdit
var pass_input: LineEdit
var nick_input: LineEdit
var status_label: Label
var title_label: Label
var access_token := ""
var refresh_token := ""
var user_id := ""
var busy := false

func _ready() -> void:
	_build_ui()
	http = HTTPRequest.new()
	http.timeout = 25.0
	add_child(http)
	http.request_completed.connect(_on_request_completed)
	_try_refresh_session()

func _build_ui() -> void:
	var bg := ColorRect.new()
	bg.color = Color("#17212b")
	bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(bg)
	var panel := VBoxContainer.new()
	panel.set_anchors_preset(Control.PRESET_CENTER)
	panel.position = Vector2(-250,-275)
	panel.size = Vector2(500,550)
	panel.add_theme_constant_override("separation",14)
	add_child(panel)
	title_label=Label.new()
	title_label.text="CUỒNG CHIẾN TRUYỀN KỲ"
	title_label.horizontal_alignment=HORIZONTAL_ALIGNMENT_CENTER
	title_label.add_theme_font_size_override("font_size",28)
	panel.add_child(title_label)
	var sub:=Label.new()
	sub.text="ĐĂNG NHẬP / TẠO TÀI KHOẢN ONLINE"
	sub.horizontal_alignment=HORIZONTAL_ALIGNMENT_CENTER
	sub.add_theme_color_override("font_color",Color("#e7c77d"))
	panel.add_child(sub)
	nick_input=_field("Tên nhân vật (3–20 ký tự)")
	panel.add_child(nick_input)
	email_input=_field("Email")
	panel.add_child(email_input)
	pass_input=_field("Mật khẩu (ít nhất 6 ký tự)")
	pass_input.secret=true
	panel.add_child(pass_input)
	var login:=Button.new()
	login.text="ĐĂNG NHẬP"
	login.custom_minimum_size.y=58
	login.pressed.connect(_login)
	panel.add_child(login)
	var signup:=Button.new()
	signup.text="TẠO TÀI KHOẢN MỚI"
	signup.custom_minimum_size.y=58
	signup.pressed.connect(_signup)
	panel.add_child(signup)
	status_label=Label.new()
	status_label.text="Kết nối máy chủ Singapore • Bản thử nghiệm"
	status_label.autowrap_mode=TextServer.AUTOWRAP_WORD_SMART
	status_label.horizontal_alignment=HORIZONTAL_ALIGNMENT_CENTER
	status_label.add_theme_color_override("font_color",Color("#b9c7d5"))
	panel.add_child(status_label)

func _field(placeholder:String)->LineEdit:
	var f:=LineEdit.new()
	f.placeholder_text=placeholder
	f.custom_minimum_size.y=52
	f.size_flags_horizontal=Control.SIZE_EXPAND_FILL
	return f

func _set_status(s:String)->void:
	status_label.text=s

func _headers(with_auth:bool=false)->PackedStringArray:
	var h:=PackedStringArray(["Content-Type: application/json","apikey: "+SUPABASE_KEY])
	if with_auth: h.append("Authorization: Bearer "+access_token)
	return h

func _send(path:String,body:Dictionary,headers:PackedStringArray)->void:
	if busy: return
	busy=true
	var err:=http.request(SUPABASE_URL+path,headers,HTTPClient.METHOD_POST,JSON.stringify(body))
	if err!=OK:
		busy=false
		_set_status("Không gửi được yêu cầu mạng. Mã lỗi: %s" % err)

func _signup()->void:
	var email:=email_input.text.strip_edges()
	var password:=pass_input.text
	var nickname:=nick_input.text.strip_edges()
	if not email.contains("@") or password.length()<6 or nickname.length()<3 or nickname.length()>20:
		_set_status("Kiểm tra email, mật khẩu từ 6 ký tự và tên nhân vật 3–20 ký tự.")
		return
	_set_status("Đang tạo tài khoản...")
	_send("/auth/v1/signup",{"email":email,"password":password,"data":{"nickname":nickname}},_headers())

func _login()->void:
	var email:=email_input.text.strip_edges()
	var password:=pass_input.text
	if not email.contains("@") or password.length()<6:
		_set_status("Nhập email hợp lệ và mật khẩu ít nhất 6 ký tự.")
		return
	_set_status("Đang đăng nhập...")
	_send("/auth/v1/token?grant_type=password",{"email":email,"password":password},_headers())

func _try_refresh_session()->void:
	if not FileAccess.file_exists(SESSION_PATH): return
	var f:=FileAccess.open(SESSION_PATH,FileAccess.READ)
	if not f:return
	var d=JSON.parse_string(f.get_as_text())
	f.close()
	if typeof(d)!=TYPE_DICTIONARY:return
	refresh_token=str(d.get("refresh_token",""))
	if refresh_token.is_empty():return
	_set_status("Đang khôi phục phiên đăng nhập...")
	_send("/auth/v1/token?grant_type=refresh_token",{"refresh_token":refresh_token},_headers())

func _on_request_completed(result:int,response_code:int,_headers_in:PackedStringArray,body:PackedByteArray)->void:
	busy=false
	var parsed=JSON.parse_string(body.get_string_from_utf8())
	if result!=HTTPRequest.RESULT_SUCCESS:
		_set_status("Lỗi mạng. Hãy kiểm tra Wi-Fi và thử lại.")
		return
	if response_code<200 or response_code>=300:
		var msg="Máy chủ trả lỗi HTTP %d" % response_code
		if typeof(parsed)==TYPE_DICTIONARY:
			msg=str(parsed.get("msg",parsed.get("message",parsed.get("error_description",parsed.get("error",msg)))))
		_set_status(msg)
		return
	if typeof(parsed)!=TYPE_DICTIONARY:
		_set_status("Phản hồi máy chủ không đúng định dạng.")
		return
	if parsed.has("access_token"):
		access_token=str(parsed.get("access_token",""))
		refresh_token=str(parsed.get("refresh_token",""))
		var user:Dictionary=parsed.get("user",{})
		user_id=str(user.get("id",""))
		_save_session()
		_load_profile()
	elif parsed.has("id") and parsed.has("email"):
		_set_status("Tạo tài khoản thành công. Nếu máy chủ yêu cầu xác minh email, hãy mở hộp thư rồi xác minh trước khi đăng nhập.")
	else:
		_set_status("Máy chủ đã phản hồi. Hãy đăng nhập để tiếp tục.")

func _save_session()->void:
	var f:=FileAccess.open(SESSION_PATH,FileAccess.WRITE)
	if f:
		f.store_string(JSON.stringify({"refresh_token":refresh_token,"user_id":user_id}))
		f.close()

func _load_profile()->void:
	if access_token.is_empty() or user_id.is_empty():
		_enter_game()
		return
	var url:=SUPABASE_URL+"/rest/v1/player_profiles?select=nickname,level,experience,gold&user_id=eq."+user_id
	var req:=HTTPRequest.new()
	req.name="ProfileRequest"
	req.timeout=20
	add_child(req)
	req.request_completed.connect(func(_r:int,code:int,_h:PackedStringArray,b:PackedByteArray):
		var data=JSON.parse_string(b.get_string_from_utf8())
		if code==200 and data is Array and data.size()>0:
			var profile:Dictionary=data[0]
			_set_status("Xin chào %s • Cấp %s • %s vàng" % [profile.get("nickname","Người chơi"),profile.get("level",1),profile.get("gold",0)])
			GameSession.nickname = str(profile.get("nickname", "Người chơi"))
		else:
			_set_status("Đăng nhập thành công. Chưa đọc được hồ sơ nhân vật.")
		_enter_game()
		req.queue_free()
	)
	var h:=PackedStringArray(["apikey: "+SUPABASE_KEY,"Authorization: Bearer "+access_token])
	var err:=req.request(url,h,HTTPClient.METHOD_GET)
	if err!=OK:
		req.queue_free()
		_enter_game()

func _enter_game()->void:
	GameSession.access_token = access_token
	GameSession.refresh_token = refresh_token
	GameSession.user_id = user_id
	if not nick_input.text.strip_edges().is_empty():
		GameSession.nickname = nick_input.text.strip_edges()
	get_tree().change_scene_to_file("res://Game.tscn")
