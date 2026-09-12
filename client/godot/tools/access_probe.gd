## Isolated authorization probe. Prints the sender-scoped role only.
extends SceneTree

const TIMEOUT := 25.0
var client: ContinuumModuleClient
var access: ContinuumAccess
var elapsed := 0.0
var connected := false
var _started := false
var expected_role := ""
var expected_sequence: PackedStringArray
var sequence_index := 0
var hold := false
var disconnect_after := ""
var signal_file := ""
var resume_file := ""
var waiting_reconnect := false
var allow_unknown := false
var disconnected := false

func _initialize() -> void:
	client = ContinuumModuleClient.new()
	root.add_child(client)
	access = ContinuumAccess.new(client)
	access.changed.connect(_on_access_changed)
	client.connected.connect(func(identity: PackedByteArray, _token: String) -> void:
		connected = true
		print("CLIENT_IDENTITY=%s" % identity.hex_encode()))
	client.connection_error.connect(func(code: int, reason: String) -> void: _fail("connection error %d: %s" % [code, reason]))
	client.disconnected.connect(_on_disconnected)
	expected_role = _option("--expected", "")
	hold = _option("--hold", "false") == "true"
	var sequence := _option("--sequence", "")
	if not sequence.is_empty():
		expected_sequence = sequence.split(",")
	disconnect_after = _option("--disconnect-after", "")
	signal_file = _option("--signal-file", "")
	resume_file = _option("--resume-file", "")

func _process(delta: float) -> bool:
	elapsed += delta
	if elapsed > TIMEOUT:
		_fail("role discovery timed out")
		return true
	if waiting_reconnect and FileAccess.file_exists(resume_file):
		DirAccess.remove_absolute(resume_file)
		waiting_reconnect = false
		client.reconnect_db()
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
	if role_name == ContinuumAccess.ROLE_UNKNOWN:
		if allow_unknown:
			return
		_fail("authorization became Unknown")
		return
	var expected := expected_role
	if not expected_sequence.is_empty():
		if sequence_index >= expected_sequence.size():
			_fail("unexpected extra role %s" % role_name)
			return
		expected = expected_sequence[sequence_index]
	if expected.is_empty() or role_name != expected:
		_fail("unexpected role %s (expected %s)" % [role_name, expected])
		return
	print("ACCESS_ROLE=%s OPERATE=%s ADMIN=%s" % [role_name, can_operate, is_admin])
	sequence_index += 1
	if role_name == disconnect_after:
		allow_unknown = true
		waiting_reconnect = true
		client.disconnect_db()
		return
	if not hold or (not expected_sequence.is_empty() and sequence_index == expected_sequence.size()):
		print("ACCESS_PASS")
		quit(0)

func _fail(message: String) -> void:
	printerr("access probe: %s" % message)
	quit(1)

func _on_disconnected() -> void:
	if disconnected:
		return
	disconnected = true
	var signal_handle := FileAccess.open(signal_file, FileAccess.WRITE)
	if signal_handle:
		signal_handle.store_string("disconnected")
		signal_handle.close()

func _option(name: String, fallback: String) -> String:
	for argument: String in OS.get_cmdline_user_args():
		if argument.begins_with(name + "="):
			return argument.substr(name.length() + 1)
	return fallback
