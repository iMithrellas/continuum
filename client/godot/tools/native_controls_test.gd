extends Node

var failures := 0

class StatusOnly extends ContinuumNativeServerManager:
	func status() -> String:
		_set_state(State.OFFLINE)
		return state()
	func get_autostart() -> Dictionary:
		return {"ok": true, "enabled": false}

class RequestsOnly extends ContinuumNativeServerController:
	var starts := 0
	func _ready() -> void:
		pass
	func request_start() -> int:
		starts += 1
		return super.request_start()

func _ready() -> void:
	call_deferred("_run")

func _run() -> void:
	var fixture := "/tmp/opencode/native-controls-%d" % OS.get_process_id()
	_check(HTTPRequest.RESULT_CANT_CONNECT == 2, "SDK result 2 is HTTP connection failure, not a database authorization response")
	DirAccess.make_dir_recursive_absolute(fixture)
	OS.set_environment("CONTINUUM_NATIVE_ROOT", fixture.path_join("native"))
	OS.set_environment("HOME", fixture)
	var main := preload("res://scenes/main.tscn").instantiate()
	main.set_script(preload("res://tools/native_controls_main_fixture.gd"))
	get_tree().root.add_child(main)
	var browser: ContinuumServerManagement = main._server_management
	_check(await _wait_for(func(): return browser._native_note.text.begins_with("Native server: offline")), "cold menu receives completed native status")
	main._show_server_management()
	_check(not main._state_ready and not SpacetimeDB.Continuum.is_connected_db(), "cold menu does not need SDK readiness")
	_check(not browser._local_start.disabled and not browser._join_button.disabled, "completed offline check enables cold menu start and join")
	_check(not browser._native_note.text.contains("being checked"), "completed initial status clears checking message")

	main._session_requested = true
	main._direct_launch = true
	main._host = "http://127.0.0.1:3001"
	main._database = "continuum"
	main._on_connection_error(HTTPRequest.RESULT_CANT_CONNECT, "Failed to acquire authentication token")
	main._show_server_management()
	_check(main._reconnect_timer != null, "direct token failure retains background retry")
	_check(not browser._join_button.disabled and browser._join_host.editable and browser._join_database.editable, "background retries do not lock manual join or endpoint editing")
	_check(not browser._local_start.disabled and not browser._native_autostart.disabled, "background retries do not lock offline local actions")
	_check(browser._status.text.contains("authentication token"), "browser explains authentication failure")
	main.leave_session()
	main._on_native_state("conflict", "")
	_check(browser._local_start.disabled and browser._local_stop.disabled and browser._local_force.disabled, "conflicting ownership never grants lifecycle controls")
	_check(not browser._join_button.disabled and browser._native_note.text.contains("ownership"), "conflict explains ownership without disabling manual join")
	main._on_native_state("unhealthy", "")
	_check(browser._local_start.disabled and not browser._local_stop.disabled and browser._local_force.disabled, "owned unhealthy server permits only graceful stop")
	main._on_native_state("unknown", "")
	_check(browser._local_start.disabled and not browser._join_button.disabled, "unknown status does not authorize native start or block join")
	main._on_native_state("offline", "")
	main._session_requested = true
	main._direct_launch = false
	main._show_server_management()
	_check(browser._join_button.disabled and browser._local_start.disabled, "explicit manual connection remains legitimately busy")
	main._on_connection_error(2, "fixture token failure")
	_check(not browser._join_button.disabled and not browser._local_start.disabled, "manual token failure releases connection busy")
	main.leave_session()
	main._native_controller.request_shutdown()
	_check(await _wait_for(main._native_controller.finish_shutdown), "cold menu worker shuts down without launching or stopping")
	main._native_controller.queue_free()
	await get_tree().process_frame
	var requests := RequestsOnly.new()
	main._native_controller = requests
	main.add_child(requests)
	main._session_requested = true
	main._direct_launch = true
	main._on_connection_error(2, "fixture retry")
	var stale_timer: SceneTreeTimer = main._reconnect_timer
	main._native_start()
	_check(requests.starts == 1 and not main._session_requested and main._reconnect_timer == null, "explicit native setup supersedes the old automatic retry")
	main._retry_connection(stale_timer)
	_check(not SpacetimeDB.Continuum.is_connected_db() and main._reconnect_timer == null, "superseded retry callback cannot connect")
	_check(browser._join_button.disabled and browser._native_busy, "explicit native startup remains legitimately busy")
	main.cancel_local_setup()
	_check(not browser._join_button.disabled, "cancelled native setup restores manual join")
	main.queue_free()
	await get_tree().process_frame
	await _controller_status()
	print("NATIVE_CONTROLS_PASS" if failures == 0 else "NATIVE_CONTROLS_FAIL")
	get_tree().quit(0 if failures == 0 else 1)

func _controller_status() -> void:
	var controller := ContinuumNativeServerController.new()
	controller.manager_factory = func(): return StatusOnly.new()
	get_tree().root.add_child(controller)
	_check(await _wait_for(func(): return controller.cached_state() == "offline"), "worker reports initial status without world polling")
	_check(not controller.cached_message().contains("being checked"), "worker resolves initial checking message")
	controller._on_worker_failure("fixture actionable failure")
	controller._on_worker_state("offline")
	_check(controller.cached_message() == "fixture actionable failure", "resolved status preserves actionable failure details")
	controller.request_shutdown()
	_check(await _wait_for(controller.finish_shutdown), "status-only worker finishes")
	controller.queue_free()
	await get_tree().process_frame

func _wait_for(condition: Callable) -> bool:
	var deadline := Time.get_ticks_msec() + 3000
	while Time.get_ticks_msec() < deadline:
		if condition.call(): return true
		await get_tree().create_timer(0.01).timeout
	return false

func _check(condition: bool, message: String) -> void:
	if not condition:
		failures += 1
		printerr("FAIL: " + message)
