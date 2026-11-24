extends Node
var access_token: String = ""
var refresh_token: String = ""
var user_id: String = ""
var nickname: String = "Người chơi"
var is_authenticated: bool:
	get:
		return not access_token.is_empty() and not user_id.is_empty()
