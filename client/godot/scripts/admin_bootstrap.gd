## Headless bootstrap used by the just admin recipes.
## It prints only the client identity, never the bearer token.
extends Node

const TIMEOUT_SECONDS := 20.0
var _client: ContinuumModuleClient
var _started := false
var _elapsed := 0.0

func _ready() -> void:
	_client = ContinuumModuleClient.new()
	add_child(_client)
	_client.connected.connect(_on_connected)
	_client.connection_error.connect(_on_error)
	_connect.call_deferred()

func _process(delta: float) -> void:
	_elapsed += delta
	if _elapsed > TIMEOUT_SECONDS:
		_fail("timed out obtaining an authenticated client identity")
		return
	if not _started:
		_started = true

func _connect() -> void:
	var host := _option("--stdb-host", "http://127.0.0.1:3001")
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
	get_tree().quit(0)

func _on_error(code: int, reason: String) -> void:
	_fail("client connection failed (%d): %s" % [code, reason])

func _fail(message: String) -> void:
	printerr("admin bootstrap: %s" % message)
	get_tree().quit(1)

func _option(name: String, fallback: String) -> String:
	for argument: String in OS.get_cmdline_user_args():
		if argument.begins_with(name + "="):
			return argument.substr(name.length() + 1)
	return fallback
