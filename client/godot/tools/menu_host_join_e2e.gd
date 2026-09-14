## Production happy-path gate: menu -> Start local server -> joined session.
## The runner and SDK are intentionally real; no callbacks or reducers are faked.
extends Node

const MainScene = preload("res://scenes/main.tscn")
const TIMEOUT_SECONDS := 300

var main: Control
var failed := false

func _ready() -> void:
	call_deferred("_run")

func _run() -> void:
	main = MainScene.instantiate()
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
	_assert(main._menu.visible, "main menu is visible on offline launch")
	_assert(not main._session_requested, "offline launch has no session request")
	_assert(not main._menu._join_button.disabled and not main._menu._local_button.disabled,
		"join and start-local controls are enabled offline")
	_assert(main._menu._last_button.disabled, "join-last is disabled before a successful join")
	var local_signal_count := [0]
	main._menu.local_server_requested.connect(func() -> void: local_signal_count[0] += 1)
	var started_at := Time.get_ticks_msec()
	print("PHASE menu-visible offline session_requested=false")
	# This is the same Button signal used by the shipped UI, not a private callback.
	main._menu._local_button.pressed.emit()
	_assert(local_signal_count[0] == 1, "start-local button emitted its production signal")
	print("PHASE start-local clicked t_ms=%d" % (Time.get_ticks_msec() - started_at))
	await _wait_until(func() -> bool:
		return main._state_ready and main._role_name == "Viewer" and \
			not SpacetimeDB.Continuum.db.tile.iter().is_empty() and \
			not SpacetimeDB.Continuum.db.colonist.iter().is_empty())
	if failed:
		return
	var client: ContinuumModuleClient = SpacetimeDB.Continuum
	var tiles: Array[ContinuumTile] = client.db.tile.iter()
	var colonists: Array[ContinuumColonist] = client.db.colonist.iter()
	_assert(not tiles.is_empty() and not colonists.is_empty(),
		"joined production subscription contains tiles and colonists")
	_assert(main.visible and main._menu.visible == false, "session is visible and menu is hidden")
	_assert(main._role_name == "Viewer" and not main._can_operate and not main._is_admin,
		"normal profile joins with readonly viewer permissions")
	print("PHASE server-ready-and-joined host=%s db=%s tiles=%d colonists=%d role=%s" %
		[main._host, main._database, tiles.size(), colonists.size(), main._role_name])
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
	main.queue_free()

func _reopen_and_join_last() -> void:
	_assert(main._menu.visible and not main._session_requested,
		"fresh process reopens offline without ghost autoconnect")
	_assert(not main._menu._last_button.disabled, "persisted successful server enables join-last")
	print("PHASE reopened offline session_requested=false join-last-enabled=true")
	main._menu._last_button.pressed.emit()
	print("PHASE join-last clicked")
	await _wait_until(func() -> bool: return main._state_ready)
	if failed:
		return
	var client: ContinuumModuleClient = SpacetimeDB.Continuum
	_assert(not client.db.tile.iter().is_empty() and not client.db.colonist.iter().is_empty(),
		"join-last reconnect applies production tables")
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
	if main._menu._runner != null and main._menu._runner.is_running():
		# Avoid cancellation/forced process control on a hung real runner. Leak only
		# this test reference so the runner can finish independently of the harness.
		printerr("MENU_HOST_JOIN_E2E_FAIL: timed out while runner was active; leaving it untouched")
		main._menu._runner = null
	else:
		_fail("timed out waiting for production session readiness")

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
