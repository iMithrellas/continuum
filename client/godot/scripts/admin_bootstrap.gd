## Headless bootstrap used by scripts/run-admin-client.
## It prints only the client identity, never the bearer token.
extends SceneTree

const TIMEOUT_SECONDS := 20.0
var _client: ContinuumModuleClient
var _started := false
var _elapsed := 0.0

func _initialize() -> void:
	_client = ContinuumModuleClient.new()
	root.add_child(_client)
	_client.connected.connect(_on_connected)
	_client.connection_error.connect(_on_error)

func _process(delta: float) -> bool:
	_elapsed += delta
	if _elapsed > TIMEOUT_SECONDS:
		_fail("timed out obtaining an authenticated client identity")
		return true
	if not _started:
		_started = true
		_connect()
	return false

func _connect() -> void:
	var host := _option("--stdb-host", "http://127.0.0.1:3000")
	var database := _option("--stdb-db", "continuum")
	var profile := _option("--profile", ContinuumClientProfile.ADMIN)
	var options := SpacetimeDBConnectionOptions.new()
	options.debug_mode = false
	options.one_time_token = false
	options.save_token = true
	_client.token_save_path = ContinuumClientProfile.token_path(profile, host, database)
	_client.connect_db(host, database, options)

func _on_connected(identity: PackedByteArray, _token: String) -> void:
	print("CLIENT_IDENTITY=%s" % identity.hex_encode())
	print("CLIENT_PROFILE_READY")
	quit(0)

func _on_error(code: int, reason: String) -> void:
	_fail("client connection failed (%d): %s" % [code, reason])

func _fail(message: String) -> void:
	printerr("admin bootstrap: %s" % message)
	quit(1)

func _option(name: String, fallback: String) -> String:
	for argument: String in OS.get_cmdline_user_args():
		if argument.begins_with(name + "="):
			return argument.substr(name.length() + 1)
	return fallback
