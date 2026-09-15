extends Node

const Client = preload("res://spacetime_bindings/schema/module_continuum_client.gd")
const Session = preload("res://scripts/session_diagnostics.gd")
const PingTransport = preload("res://scripts/session_ping_transport.gd")

const TARGET_REPLIES := 12
const TEST_TIMEOUT_SEC := 45.0

var client: ContinuumModuleClient
var sampler: SessionDiagnostics
var transport: SessionPingTransport
var elapsed := 0.0
var failed := false
var finished := false
var disconnect_seen := false
var role_verified := false
var shutdown_requested := false
var final_replies := 0
var final_latest_ms := 0.0
var final_smoothed_ms := 0.0
var shutdown_deadline_usec := 0


func _ready() -> void:
	client = Client.new()
	client.connection_error.connect(_on_connection_error)
	client.connected.connect(_on_connected)
	client.disconnected.connect(_on_disconnected)
	add_child(client)
	sampler = Session.new()
	transport = PingTransport.new(client, sampler)
	# Exercise the configured lower bound without creating a per-frame probe.
	sampler.configure_probe(sampler.sender, 3_000_000, 10_000_000, 1)
	var options := SpacetimeDBConnectionOptions.new()
	options.compression = SpacetimeDBConnection.CompressionPreference.NONE
	options.debug_mode = false
	options.threading = false
	client.token_save_path = _cli_option("--token-path", "user://session_ping.token")
	client.connect_db(_cli_option("--stdb-host", "http://127.0.0.1:3303"),
			_cli_option("--stdb-db", "session_ping"), options)


func _process(delta: float) -> void:
	if finished:
		return
	if shutdown_requested:
		if disconnect_seen:
			_assert(client._pending_reducer_call.size() == 0, "SDK pending reducer map is empty after disconnect")
			_assert(role_verified, "Viewer role was verified")
			finished = true
			print("SESSION_PING_E2E replies=%d latest_ms=%.3f smoothed_ms=%.3f" % [
				final_replies, final_latest_ms, final_smoothed_ms])
			print("SESSION_PING_E2E_FAIL" if failed else "SESSION_PING_E2E_PASS")
			get_tree().quit(0 if not failed else 1)
		elif Time.get_ticks_usec() >= shutdown_deadline_usec:
			_fail("disconnect did not complete within five seconds")
			finished = true
			print("SESSION_PING_E2E_FAIL")
			get_tree().quit(1)
		return
	elapsed += delta
	var now_usec := Time.get_ticks_usec()
	sampler.advance(now_usec)
	if failed:
		_finish(false)
		return
	if elapsed > TEST_TIMEOUT_SEC:
		_fail("timed out waiting for %d authenticated echo replies" % TARGET_REPLIES)
		_finish(false)
		return
	var snapshot := sampler.snapshot(now_usec)
	if snapshot.successful >= TARGET_REPLIES:
		_assert(client._pending_reducer_call.size() == 0, "SDK pending reducer map is empty after response")
		_assert(snapshot.rtt_ms > 0.0, "latest RTT is positive")
		_assert(snapshot.rtt_smoothed_ms > 0.0, "smoothed RTT is positive")
		_assert(snapshot.timed_out == 0 and snapshot.rejected == 0, "real echo replies are not failures")
		_assert(client.get_local_identity().size() > 0, "connected identity is nonempty")
		_assert(_token_file_is_nonempty(), "authenticated token file is nonempty")
		_assert(role_verified, "authenticated client is a Viewer")
		_finish(not failed)
		return
	# Completion is checked before this launch so the response just observed cannot
	# be hidden by the next one-second probe.
	sampler.pump(now_usec)
	_assert(client._pending_reducer_call.size() <= 1, "SDK pending reducer map is bounded to one")


func _on_connection_error(code: int, reason: String) -> void:
	_fail("connection error %d: %s" % [code, reason])


func _on_connected(_identity: PackedByteArray, _token: String) -> void:
	var role_subscription := client.subscribe(PackedStringArray(["SELECT * FROM my_role"]))
	role_subscription.applied.connect(_on_role_subscription_applied)


func _on_disconnected() -> void:
	disconnect_seen = true


func _on_role_subscription_applied() -> void:
	# The public sender-filtered view has no row for a Viewer (role NONE).
	role_verified = client.db.my_role.iter().is_empty()


func _assert(condition: bool, message: String) -> void:
	if not condition:
		_fail(message)


func _fail(message: String) -> void:
	if not failed:
		failed = true
		push_error(message)


func _finish(passed: bool) -> void:
	if shutdown_requested:
		return
	var final_snapshot := sampler.snapshot(Time.get_ticks_usec())
	final_replies = final_snapshot.successful
	final_latest_ms = float(final_snapshot.rtt_ms) if final_snapshot.rtt_ms != null else 0.0
	final_smoothed_ms = float(final_snapshot.rtt_smoothed_ms) if final_snapshot.rtt_smoothed_ms != null else 0.0
	transport.dispose()
	_assert(client._pending_reducer_call.size() == 0, "SDK pending reducer map is empty after dispose")
	shutdown_requested = true
	shutdown_deadline_usec = Time.get_ticks_usec() + 5_000_000
	if client.is_connected_db():
		client.disconnect_db()
	else:
		disconnect_seen = true
	if not passed:
		finished = true
		print("SESSION_PING_E2E_FAIL")
		get_tree().quit(1)


func _token_file_is_nonempty() -> bool:
	var path := client.token_save_path
	if not FileAccess.file_exists(path):
		return false
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return false
	var token := file.get_as_text().strip_edges()
	file.close()
	return not token.is_empty()


func _cli_option(option: String, fallback: String) -> String:
	for argument: String in OS.get_cmdline_user_args():
		if argument.begins_with(option + "="):
			return argument.substr(option.length() + 1)
	return fallback
