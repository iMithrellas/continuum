extends "res://tools/session_handoff_main_fixture.gd"


## No real runtime, installation, process inspection, or host signals.
class ManagedServer:
	extends ContinuumNativeServerManager
	var starts := 0
	var stops := 0
	var deletes := 0
	var updates := 0
	var autostart := false
	var deletion_error := ""
	var update_error := ""

	func status() -> String:
		if _state == State.UNKNOWN:
			_set_state(State.OFFLINE)
		return state()

	func prepare_control_helper() -> bool:
		return true

	func runtime_installed() -> bool:
		return true

	func prepare_module() -> bool:
		return true

	func start() -> bool:
		starts += 1
		_set_state(State.ONLINE)
		ready.emit(host, database)
		return true

	func can_stop() -> bool:
		return _state == State.ONLINE

	func stop(_force := false) -> bool:
		stops += 1
		_set_state(State.OFFLINE)
		return true

	func tick() -> void:
		pass

	func get_autostart() -> Dictionary:
		return {"ok": true, "enabled": autostart}

	func set_autostart(enabled: bool) -> Dictionary:
		autostart = enabled
		return {"ok": true}

	func delete_data() -> Dictionary:
		deletes += 1
		if not deletion_error.is_empty():
			return {"ok": false, "error": deletion_error}
		autostart = false
		_set_state(State.DELETED)
		return {"ok": true}

	func update_module() -> Dictionary:
		updates += 1
		return {"ok": update_error.is_empty(), "error": update_error}


var managed: Dictionary = {}


func _cli_option(option: String, fallback: String) -> String:
	var fixture := OS.get_environment("CONTINUUM_NATIVE_ROOT").get_base_dir()
	if option == "--settings-file":
		return fixture.path_join("settings.cfg")
	if option == "--workspace-file":
		return fixture.path_join("workspace.json")
	return fallback


func _make_native_controller(entry: Dictionary) -> ContinuumNativeServerController:
	var manager := ManagedServer.new()
	manager.configure_instance(str(entry.id), int(entry.port))
	managed[entry.id] = manager
	var controller := ContinuumNativeServerController.new()
	controller.manager_factory = func(): return manager
	return controller
