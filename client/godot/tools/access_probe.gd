## Isolated authorization probe. Prints the sender-scoped role only.
extends SceneTree

const TIMEOUT := 25.0
var client: ContinuumModuleClient
var access: ContinuumAccess
var elapsed := 0.0
var connected := false
var _started := false

func _initialize() -> void:
	client = ContinuumModuleClient.new()
	root.add_child(client)
	access = ContinuumAccess.new(client)
	access.changed.connect(_on_access_changed)
	client.connected.connect(func(identity: PackedByteArray, _token: String) -> void:
		connected = true
		print("CLIENT_IDENTITY=%s" % identity.hex_encode()))
	client.connection_error.connect(func(code: int, reason: String) -> void: _fail("connection error %d: %s" % [code, reason]))

func _process(delta: float) -> bool:
	elapsed += delta
	if elapsed > TIMEOUT:
		_fail("role discovery timed out")
		return true
	if not connected and not _started:
		_started = true
		_connect()
	return false

func _connect() -> void:
	var host := _option("--stdb-host", "http://127.0.0.1:3000")
	var database := _option("--stdb-db", "continuum")
	var profile := _option("--profile", ContinuumClientProfile.NORMAL)
	var options := SpacetimeDBConnectionOptions.new()
	options.debug_mode = false
	options.one_time_token = false
	options.save_token = true
	client.token_save_path = ContinuumClientProfile.token_path(profile, host, database)
	client.connect_db(host, database, options)

func _on_access_changed(role_name: String, can_operate: bool, is_admin: bool) -> void:
	print("ACCESS_ROLE=%s OPERATE=%s ADMIN=%s" % [role_name, can_operate, is_admin])
	quit(0)

func _fail(message: String) -> void:
	printerr("access probe: %s" % message)
	quit(1)

func _option(name: String, fallback: String) -> String:
	for argument: String in OS.get_cmdline_user_args():
		if argument.begins_with(name + "="):
			return argument.substr(name.length() + 1)
	return fallback
