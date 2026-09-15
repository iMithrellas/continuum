## Main-thread facade for the native manager. All process inspection, curl, and
## launch/stop calls run on one worker, so UI input never performs blocking IO.
class_name ContinuumNativeServerController
extends Node

signal state_changed(state: String, message: String)
signal server_ready(host: String, database: String)
signal autostart_changed(enabled: bool, error: String)

var manager: ContinuumNativeServerManager
var manager_factory: Callable
var _thread := Thread.new()
var _mutex := Mutex.new()
var _operations: Array[String] = []
var _running := true
var _cached_state := "unknown"
var _cached_message := "Native server status is being checked..."
var _last_status_ms := -1000
var _startup_epoch := 0
var _runtime_epoch := -1
var _started_by_request := false

func _ready() -> void:
	_thread.start(_worker)

func request_start() -> void:
	_queue("start")

func cancel_startup() -> void:
	_mutex.lock()
	_startup_epoch += 1
	_operations.erase("start")
	_mutex.unlock()
	_on_worker_progress("Startup cancelled; the current atomic preparation step may finish, but it will not start or join a server.")

func request_shutdown() -> void:
	_mutex.lock()
	_running = false
	_startup_epoch += 1
	_operations.clear()
	_mutex.unlock()

func finish_shutdown() -> bool:
	if _thread.is_alive():
		return false
	if _thread.is_started():
		_thread.wait_to_finish()
	return true

func _may_start(epoch: int) -> bool:
	_mutex.lock()
	var allowed := _running and epoch == _startup_epoch
	_mutex.unlock()
	return allowed

func request_stop(force := false) -> void:
	if not force:
		_mutex.lock()
		_startup_epoch += 1
		_operations.erase("start")
		_mutex.unlock()
	_queue("force_stop" if force else "stop")

func request_install() -> void:
	_queue("install")

func request_autostart(enabled: bool) -> void:
	_queue("autostart:%s" % str(enabled))

func request_autostart_status() -> void:
	_queue("autostart_status")

func request_status() -> void:
	_queue("status")

func cached_state() -> String:
	return _cached_state

func cached_message() -> String:
	return _cached_message

func _queue(operation: String) -> void:
	_mutex.lock()
	if not _operations.has(operation) and _operations.size() < 8:
		_operations.append(operation)
	_mutex.unlock()

func _worker() -> void:
	manager = manager_factory.call() if manager_factory.is_valid() else load("res://scripts/native_server_manager.gd").new()
	manager.status_changed.connect(_on_worker_state, CONNECT_DEFERRED)
	manager.progress.connect(_on_worker_progress, CONNECT_DEFERRED)
	manager.failed.connect(_on_worker_failure, CONNECT_DEFERRED)
	# Capture the emitting request's epoch on the worker, before deferring UI work.
	manager.ready.connect(_on_worker_ready)
	while _running:
		if _running and _started_by_request and _runtime_epoch >= 0 and not _may_start(_runtime_epoch) and manager.state() in ["starting", "online"] and manager.can_stop():
			manager.stop(false)
		_mutex.lock()
		var operation: String = "" if _operations.is_empty() else _operations.pop_front()
		var epoch := _startup_epoch
		_mutex.unlock()
		if not operation.is_empty():
			if operation == "install": manager.install_native()
			elif operation == "start":
				var current := manager.status()
				if current in ["stopping", "stop_timeout"] or (current == "starting" and _runtime_epoch != epoch):
					_mutex.lock()
					if _running and epoch == _startup_epoch and not _operations.has("start"):
						_operations.append("start")
					_mutex.unlock()
				elif current == "online" and _may_start(epoch):
					_runtime_epoch = epoch
					_started_by_request = false
					call_deferred("_emit_server_ready", manager.host, manager.database, epoch)
				elif current == "offline":
					_runtime_epoch = epoch
					_started_by_request = false
					var installed := manager.runtime_installed() or (_may_start(epoch) and manager.install_native())
					if installed and _may_start(epoch) and manager.prepare_module() and _may_start(epoch):
						_started_by_request = manager.start()
			elif operation == "stop" and manager.state() != "stopping": manager.stop(false)
			elif operation == "force_stop": manager.stop(true)
			elif operation.begins_with("autostart:"):
				var enabled := operation.ends_with("true")
				var result: Dictionary
				if enabled and not manager.runtime_installed() and not manager.install_native():
					result = {"ok": false, "error": "Install the native runtime before enabling autostart."}
				elif enabled and not manager.prepare_module():
					result = {"ok": false, "error": "Prepare the native module before enabling autostart."}
				else:
					result = manager.set_autostart(enabled)
				call_deferred("_emit_autostart", enabled, "" if result.get("ok", false) else str(result.get("error", "Autostart update failed.")))
			elif operation == "autostart_status":
				var result := manager.get_autostart()
				call_deferred("_emit_autostart", bool(result.get("enabled", false)), "" if result.get("ok", false) else str(result.get("error", "Autostart state is unavailable.")))
			elif operation == "status": manager.status()
		var now := Time.get_ticks_msec()
		if now - _last_status_ms >= 1000 and manager.state() not in ["starting", "stopping", "stop_timeout", "installing", "preparing"]:
			_last_status_ms = now
			manager.status()
		if manager.state() in ["starting", "stopping", "stop_timeout", "installing", "preparing"]:
			manager.tick()
		OS.delay_msec(50)

func _on_worker_state(value: String) -> void:
	_cached_state = value
	state_changed.emit(value, _cached_message)

func _on_worker_progress(value: String) -> void:
	_cached_message = value
	state_changed.emit(_cached_state, value)

func _on_worker_failure(value: String) -> void:
	_cached_message = value
	state_changed.emit(_cached_state, value)

func _on_worker_ready(value_host: String, value_database: String) -> void:
	call_deferred("_emit_server_ready", value_host, value_database, _runtime_epoch)

func _emit_server_ready(value_host: String, value_database: String, epoch: int) -> void:
	if _may_start(epoch):
		server_ready.emit(value_host, value_database)

func _emit_autostart(enabled: bool, error: String) -> void:
	autostart_changed.emit(enabled, error)

func _exit_tree() -> void:
	request_shutdown()
	if _thread.is_started(): _thread.wait_to_finish()
