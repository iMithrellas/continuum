## Production happy-path gate: menu -> Servers -> Start local -> joined session.
## The native controller and SDK are intentionally real; no callbacks or reducers are faked.
extends Node

const MainScene = preload("res://scenes/main.tscn")
const TIMEOUT_SECONDS := 300

var main: Control
var failed := false

func _ready() -> void:
	if OS.get_environment("CONTINUUM_NATIVE_TEST_SANDBOX") != "private-pid-namespace" or not FileAccess.file_exists("/.dockerenv"):
		_fail("run the native E2E through its private-container recipe")
		return
	call_deferred("_run")

func _run() -> void:
	_assert(MainScene != null, "main scene resource loads")
	main = MainScene.instantiate()
	_assert(main != null and main.get_script() != null, "main scene has a production root script")
	_assert(main.get_node_or_null("Map") != null and main.get_node_or_null("Workspace") != null,
		"main scene has non-null production subviews")
	_assert(main.get_node("Map").get_script() != null and main.get_node("Workspace").get_script() != null,
		"production subviews have scripts")
	add_child(main)
	await get_tree().process_frame
	if _option("--phase", "start") == "reopen":
		await _reopen_and_join_last()
	else:
		await _start_and_join()
	if failed:
		return
	print("MENU_HOST_JOIN_E2E_PASS phase=%s" % _option("--phase", "start"))
	get_tree().quit(0)

func _start_and_join() -> void:
	var native_root := OS.get_environment("CONTINUUM_NATIVE_ROOT")
	_assert(not native_root.is_empty() and not FileAccess.file_exists(native_root.path_join("spacetimedb/2.10.0/spacetimedb-standalone")),
		"production first-use flow starts without an installed native runtime")
	_assert(main._menu.visible, "main menu is visible on offline launch")
	_assert(not main._session_requested, "offline launch has no session request")
	_assert(main._menu._last_button.disabled, "join-last is disabled before a successful join")
	print("PHASE menu-visible offline session_requested=false")
	main._show_server_management()
	await _wait_until(func() -> bool:
		return main._native_controller.cached_state() == "offline" and not main._server_management._local_start.disabled)
	if failed: return
	_assert(main._server_management.visible and not main._menu.visible, "Servers opens the production browser")
	_assert(not main._server_management._join_button.disabled and not main._server_management._local_start.disabled,
		"browser join and start-local controls are enabled offline")
	var local_signal_count := [0]
	main._server_management.local_start_requested.connect(func() -> void: local_signal_count[0] += 1)
	var started_at := Time.get_ticks_msec()
	await _click_button(main._server_management._local_start)
	_assert(local_signal_count[0] == 1, "start-local button emitted its production signal")
	print("PHASE start-local clicked t_ms=%d" % (Time.get_ticks_msec() - started_at))
	await _wait_until_native_any(["installing", "preparing", "starting", "online"])
	_assert(main._native_controller.cached_state() in ["installing", "preparing", "starting", "online"],
		"native start enters a visible production lifecycle state")
	await _wait_until(func() -> bool:
		return main._state_ready and main._role_name == "Viewer" and \
			SpacetimeDB.Continuum.db.tile.iter().size() == 576 and \
			SpacetimeDB.Continuum.db.colonist.iter().size() == 8)
	if failed:
		return
	var client: ContinuumModuleClient = SpacetimeDB.Continuum
	var tiles: Array[ContinuumTile] = client.db.tile.iter()
	var colonists: Array[ContinuumColonist] = client.db.colonist.iter()
	_assert(tiles.size() == 576 and colonists.size() == 8,
		"joined production subscription contains the fixed production fixture")
	_assert(main.visible and main._menu.visible == false, "session is visible and menu is hidden")
	_assert(main._role_name == "Viewer" and not main._can_operate and not main._is_admin,
		"normal profile joins with readonly viewer permissions")
	print("PHASE server-ready-and-joined host=%s db=%s tiles=%d colonists=%d role=%s" %
		[main._host, main._database, tiles.size(), colonists.size(), main._role_name])
	main.configure_diagnostics(true, true, false)
	await _wait_until(func() -> bool: return main._session_diagnostics.snapshot(Time.get_ticks_usec()).successful >= 3)
	if failed: return
	var network: Dictionary = main._session_diagnostics.snapshot(Time.get_ticks_usec())
	_assert(network.rtt_ms != null and network.rtt_ms > 0.0, "production diagnostics receives active-session RTT")
	_assert(network.packet_loss == null, "packet loss remains honestly unavailable")
	print("PHASE active-session-ping latest_ms=%.3f" % network.rtt_ms)
	var settings_path := _option("--settings-file", "")
	_assert(not settings_path.is_empty() and FileAccess.file_exists(settings_path),
		"isolated settings file exists after ready")
	var settings := ClientSettings.new()
	_assert(settings.load_from(settings_path) == "loaded" and settings.server_host == main._host and
		settings.database == main._database, "last server is persisted only after subscription ready")
	var history_path := settings_path + ".history.json"
	var history: Variant = JSON.parse_string(FileAccess.get_file_as_string(history_path)) if FileAccess.file_exists(history_path) else null
	var history_key := ContinuumConnectionHistory.canonical_key(main._host, main._database)
	_assert(history is Dictionary and history.has(history_key),
		"successful endpoint history is written in isolated user data")
	print("PHASE persistence-ready settings=%s history=%s" % [settings_path, history_path])
	main.leave_session()
	await get_tree().process_frame
	_assert(main._menu.visible and not main._session_requested and not main._menu._last_button.disabled,
		"return to menu keeps join-last enabled after success")
	print("PHASE returned-to-menu join-last-enabled=true")
	main._show_server_management()
	await get_tree().process_frame
	await _click_button(main._server_management._local_stop)
	await _wait_until_native("offline")
	if failed: return
	await _click_button(main._server_management._local_start)
	await _wait_until_native("online")
	await _wait_until(func() -> bool: return main._state_ready)
	_assert(main._state_ready, "native restart rejoins the last server")
	main.leave_session()
	main.queue_free()

func _reopen_and_join_last() -> void:
	_assert(main._menu.visible and not main._session_requested,
		"fresh process reopens offline without ghost autoconnect")
	_assert(not main._menu._last_button.disabled, "persisted successful server enables join-last")
	print("PHASE reopened offline session_requested=false join-last-enabled=true")
	await _click_button(main._menu._last_button)
	print("PHASE join-last clicked")
	await _wait_until(func() -> bool:
		return main._state_ready and main._role_name == "Viewer" and \
			SpacetimeDB.Continuum.db.tile.iter().size() == 576 and \
			SpacetimeDB.Continuum.db.colonist.iter().size() == 8)
	if failed:
		return
	var client: ContinuumModuleClient = SpacetimeDB.Continuum
	_assert(client.db.tile.iter().size() == 576 and client.db.colonist.iter().size() == 8,
		"join-last reconnect applies the fixed production fixture")
	_assert(main._menu.visible == false and main._role_name == "Viewer" and not main._can_operate,
		"join-last reconnect reaches readonly session UI")
	print("PHASE join-last-reconnected host=%s db=%s tiles=%d colonists=%d role=%s" %
		[main._host, main._database, client.db.tile.iter().size(), client.db.colonist.iter().size(), main._role_name])
	main.leave_session()
	await get_tree().process_frame
	main.queue_free()

func _wait_until(condition: Callable) -> void:
	var deadline := Time.get_ticks_msec() + TIMEOUT_SECONDS * 1000
	while Time.get_ticks_msec() < deadline:
		if condition.call():
			return
		await get_tree().process_frame
	_fail("timed out waiting for production session readiness")

func _wait_until_native(expected: String) -> void:
	var deadline := Time.get_ticks_msec() + TIMEOUT_SECONDS * 1000
	while Time.get_ticks_msec() < deadline:
		if main._native_controller.cached_state() == expected: return
		await get_tree().process_frame
	_fail("timed out waiting for native server state " + expected)

func _wait_until_native_any(expected: Array[String]) -> void:
	var deadline := Time.get_ticks_msec() + TIMEOUT_SECONDS * 1000
	while Time.get_ticks_msec() < deadline:
		if expected.has(main._native_controller.cached_state()): return
		await get_tree().process_frame
	_fail("native start never entered an expected lifecycle state")

func _click_button(button: Button) -> void:
	_assert(button.visible and not button.disabled, "%s is visible and enabled" % button.text)
	await get_tree().process_frame
	var rect := button.get_global_rect()
	_assert(rect.size.x > 0.0 and rect.size.y > 0.0, "%s has production layout geometry" % button.text)
	button.grab_focus()
	var down := InputEventKey.new()
	down.keycode = KEY_ENTER
	down.pressed = true
	Input.parse_input_event(down)
	await get_tree().process_frame
	var up := InputEventKey.new()
	up.keycode = KEY_ENTER
	up.pressed = false
	Input.parse_input_event(up)
	await get_tree().process_frame

func _option(name: String, fallback: String) -> String:
	for argument: String in OS.get_cmdline_user_args():
		if argument.begins_with(name + "="):
			return argument.substr(name.length() + 1)
	return fallback

func _assert(condition: bool, message: String) -> void:
	if not condition:
		_fail(message)

func _fail(message: String) -> void:
	if failed:
		return
	failed = true
	printerr("MENU_HOST_JOIN_E2E_FAIL: " + message)
	get_tree().quit(1)
