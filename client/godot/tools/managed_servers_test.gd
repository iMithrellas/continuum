extends Node

var failures := 0
var fixture := ""


class DeleteAdapter:
	extends RefCounted
	var calls := 0
	var autostart_fails := false
	var deletion_fails := false

	func supports_native_hosting() -> bool:
		return true

	func set_autostart(
		_enabled,
		_supervisor,
		_runtime,
		_cli,
		_module,
		_host,
		_db,
		_data,
		_config,
		_lock,
		_log,
		_manifest,
		_sha,
		_nonce
	) -> Dictionary:
		return {"ok": not autostart_fails, "error": "fixture autostart failure"}

	func delete_server(_supervisor, _lock, _manifest, _instance) -> Dictionary:
		calls += 1
		return {"ok": not deletion_fails, "error": "fixture lock conflict"}


class FileUpdateAdapter:
	extends ContinuumNativeServerPlatformAdapter
	var autostart := true
	var install_fails := false

	func get_autostart(_supervisor: String, _data: String) -> Dictionary:
		return {"ok": true, "enabled": autostart}

	func set_autostart(
		enabled: bool,
		_supervisor: String,
		_runtime: String,
		_cli: String,
		_module: String,
		_host: String,
		_db: String,
		_data: String,
		_config: String,
		_lock: String,
		_log: String,
		_manifest: String,
		_sha: String,
		_nonce: String
	) -> Dictionary:
		autostart = enabled
		return {"ok": true}

	func install_module(
		helper: String,
		lock: String,
		manifest: String,
		instance: String,
		source: String,
		digest: String
	) -> Dictionary:
		if install_fails:
			return {"ok": false, "error": "fixture update lock conflict"}
		return super.install_module(helper, lock, manifest, instance, source, digest)


## Uses the real manager/helper files but records every process operation.
## No executable is run or OS process is inspected/signalled.
class ManifestLifecycleAdapter:
	extends FileUpdateAdapter
	var launches := 0
	var stops := 0
	var processes: Dictionary = {}

	func launch(
		helper: String,
		runtime: String,
		cli: String,
		module: String,
		host: String,
		database: String,
		data: String,
		_config: String,
		_lock: String,
		_log: String,
		manifest: String,
		digest: String,
		nonce: String
	) -> Dictionary:
		launches += 1
		var pid := 6100 + launches * 2
		var token := "supervisor-%d" % launches
		var child_token := "runtime-%d" % launches
		processes[pid] = {
			"token": token, "binary": helper, "sha": _file_sha256(helper), "parent": -1
		}
		processes[pid + 1] = {
			"token": child_token, "binary": runtime, "sha": _file_sha256(runtime), "parent": pid
		}
		var file := FileAccess.open(manifest, FileAccess.WRITE)
		file.store_string(
			JSON.stringify(
				{
					"phase": "running",
					"runtime": "2.10.0",
					"runtime_sha256": _file_sha256(runtime),
					"cli_sha256": _file_sha256(cli),
					"supervisor_sha256": _file_sha256(helper),
					"module_sha256": digest,
					"database": database,
					"pid": pid,
					"runtime_pid": pid + 1,
					"started_at": token,
					"runtime_started_at": child_token,
					"runtime_parent_pid": pid,
					"runtime_binary": runtime,
					"startup_nonce": nonce,
					"data_dir": data,
					"host": host
				}
			)
		)
		file.close()
		return {"ok": true, "pid": pid, "started_at": token}

	func health(_host: String) -> bool:
		return not processes.is_empty()

	func process_exists(pid: int) -> bool:
		return processes.has(pid)

	func is_process_identity(
		pid: int, token: String, binary: String, digest: String, parent := -1
	) -> bool:
		var process: Dictionary = processes.get(pid, {})
		return (
			not process.is_empty()
			and process.token == token
			and process.binary == binary
			and process.sha == digest
			and (parent <= 1 or process.parent == parent)
		)

	func terminate(
		pid: int, force: bool, token: String, binary: String, digest: String, parent := -1
	) -> bool:
		if force or not is_process_identity(pid, token, binary, digest, parent):
			return false
		stops += 1
		processes.erase(pid + 1)
		processes.erase(pid)
		return true

	func cleanup_stale(_helper: String, _lock: String, manifest: String, digest: String) -> bool:
		if not processes.is_empty():
			return false
		if FileAccess.file_exists(manifest):
			if _file_sha256(manifest) != digest:
				return false
			return DirAccess.remove_absolute(manifest) == OK
		return true


func _ready() -> void:
	call_deferred("_run")


func _run() -> void:
	fixture = "/tmp/opencode/managed-servers-%d" % OS.get_process_id()
	DirAccess.make_dir_recursive_absolute(fixture)
	OS.set_environment("HOME", fixture)
	OS.set_environment("CONTINUUM_NATIVE_ROOT", fixture.path_join("native"))
	_test_catalog()
	_test_deletion_guards()
	await _test_offline_file_deletion()
	await _test_offline_module_update()
	await _test_updated_server_stop()
	await _test_ui_lifecycle()
	print("MANAGED_SERVERS_PASS" if failures == 0 else "MANAGED_SERVERS_FAIL")
	get_tree().quit(0 if failures == 0 else 1)


func _test_catalog() -> void:
	var root := fixture.path_join("catalog")
	var catalog := ContinuumNativeServerCatalog.new()
	_check(catalog.load_from(root) == OK, "new catalog adopts the original server")
	var original := ContinuumNativeServerManager.new()
	_check(
		original.configure_instance("default", 3001), "original server configuration is accepted"
	)
	_check(
		original.data_dir == fixture.path_join("native/2.10.0/data"),
		"adoption preserves the original data path"
	)
	var created := catalog.create("Second colony")
	_check(created.ok and created.entry.port == 3002, "second server gets a unique port")
	var second := ContinuumNativeServerManager.new()
	_check(
		second.configure_instance(created.entry.id, int(created.entry.port)),
		"new profile is configurable"
	)
	_check(
		(
			second.data_dir != original.data_dir
			and second.config_dir != original.config_dir
			and second.lock_file != original.lock_file
			and second.manifest_file != original.manifest_file
		),
		"servers have isolated data, configuration, locks, and ownership"
	)
	_check(
		(
			second.executable == original.executable
			and second.module_artifact == original.module_artifact
		),
		"servers share only the pinned distribution"
	)
	_check(
		(
			not second.configure_instance("../../outside", 3002)
			and not second.configure_instance("default", 3002)
		),
		"path traversal and default-port reassignment are rejected"
	)
	_check(
		not catalog.create(" second COLONY ").ok and not catalog.create("\n").ok,
		"duplicate and blank names are rejected"
	)
	var reloaded := ContinuumNativeServerCatalog.new()
	_check(
		reloaded.load_from(root) == OK and reloaded.entries() == catalog.entries(),
		"server names and ports survive reload"
	)
	var third := catalog.create("Third colony")
	_check(third.ok and third.entry.port == 3003, "additional profiles get independent ports")
	var linux := ContinuumNativeServerPlatformAdapter.new()
	_check(
		linux._unit_name(original.data_dir) == "continuum-native.service",
		"legacy autostart service remains discoverable"
	)
	_check(
		linux._unit_name(second.data_dir) != linux._unit_name(original.data_dir),
		"new servers have isolated login services"
	)
	for host in ["http://127.0.0.1:3002", "127.0.0.1:65535"]:
		_check(not linux.local_listen_address(host).is_empty(), "alternate local port accepted")
	for host in [
		"http://example.com:3002",
		"http://0.0.0.0:3002",
		"https://127.0.0.1:3002",
		"http://127.0.0.1:03002",
		"http://127.0.0.1:65536"
	]:
		_check(linux.local_listen_address(host).is_empty(), "unsafe bind address rejected: " + host)
	for entry in catalog.entries():
		_check(catalog.remove(entry.id) == OK, "profile removal persists")
	_check(
		reloaded.load_from(root) == OK and reloaded.entries().is_empty(),
		"deleting every server does not resurrect the default"
	)
	var replacement := catalog.create("Second colony")
	_check(
		(
			replacement.ok
			and replacement.entry.id != created.entry.id
			and replacement.entry.port == 3001
		),
		"recreated names use fresh data identity and can reuse a freed port"
	)
	var corrupt := FileAccess.open(catalog.path, FileAccess.WRITE)
	corrupt.store_string('[{"id":"../../outside","name":"Bad","port":3001}]')
	corrupt.close()
	_check(
		reloaded.load_from(root) != OK and not reloaded.create("Ignored").ok,
		"corrupt catalogs fail closed without overwriting user data"
	)


func _test_deletion_guards() -> void:
	var manager := ContinuumNativeServerManager.new()
	var id := "server-" + "a".repeat(24)
	manager.configure_instance(id, 3100)
	var adapter := DeleteAdapter.new()
	manager.platform_adapter = adapter
	manager._state = manager.State.ONLINE
	# Give a live state an existing, invalid manifest: neither live nor ambiguous
	# ownership may ever reach the filesystem-deletion operation.
	DirAccess.make_dir_recursive_absolute(manager.manifest_file.get_base_dir())
	var manifest := FileAccess.open(manager.manifest_file, FileAccess.WRITE)
	manifest.store_string("{}")
	manifest.close()
	_check(
		not manager.delete_data().ok and adapter.calls == 0,
		"invalid ownership never reaches destructive IO"
	)
	DirAccess.remove_absolute(manager.manifest_file)
	manager._state = manager.State.STOPPING
	_check(
		not manager.delete_data().ok and adapter.calls == 0, "shutdown must finish before deletion"
	)
	manager._state = manager.State.OFFLINE
	var correct_data := manager.data_dir
	manager.data_dir = fixture.path_join("outside")
	_check(
		not manager.delete_data().ok and adapter.calls == 0,
		"changed data paths cannot authorize deletion"
	)
	manager.data_dir = correct_data
	adapter.autostart_fails = true
	_check(
		not manager.delete_data().ok and adapter.calls == 0,
		"autostart must be disabled before deleting data"
	)
	adapter.autostart_fails = false
	adapter.deletion_fails = true
	_check(
		not manager.delete_data().ok and adapter.calls == 1 and manager.state() == "offline",
		"lock or deletion failure remains retryable"
	)
	adapter.deletion_fails = false
	_check(
		manager.delete_data().ok and manager.state() == "deleted",
		"confirmed offline deletion completes"
	)
	_check(not manager.start(), "a deleted manager cannot restart its old colony")


## Exercise the real manager/controller/helper composition using files only.
## No runtime is installed, launched, inspected, or signalled.
func _test_offline_file_deletion() -> void:
	if OS.get_name() != "Linux":
		return
	var manager := ContinuumNativeServerManager.new()
	manager.configure_instance("server-" + "c".repeat(24), 3101)
	DirAccess.make_dir_recursive_absolute(manager.data_dir)
	DirAccess.make_dir_recursive_absolute(manager.config_dir)
	var colony := FileAccess.open(manager.data_dir.path_join("colony.save"), FileAccess.WRITE)
	colony.store_string("disposable colony")
	colony.close()
	var controller := ContinuumNativeServerController.new()
	controller.manager_factory = func(): return manager
	var result := ["pending"]
	controller.deletion_finished.connect(func(error: String): result[0] = error)
	get_tree().root.add_child(controller)
	_check(
		await _wait_for(func(): return controller.cached_state() == "offline"),
		"real file-only manager discovers an offline profile"
	)
	controller.request_delete()
	_check(
		await _wait_for(func(): return result[0] != "pending"),
		"real worker completes the offline deletion helper"
	)
	_check(
		(
			result[0].is_empty()
			and not DirAccess.dir_exists_absolute(manager.data_dir)
			and not DirAccess.dir_exists_absolute(manager.config_dir)
		),
		"real controller deletion removes only its disposable data/configuration"
	)
	_check(
		(
			FileAccess.file_exists(manager.lock_file)
			and FileAccess.file_exists(
				manager.data_dir.get_base_dir().path_join(".continuum-deleted")
			)
		),
		"real deletion retains a lock and anti-resurrection tombstone"
	)
	_check(not manager.start(), "the tombstoned profile cannot launch after deletion")
	controller.request_shutdown()
	_check(await _wait_for(controller.finish_shutdown), "file-only worker finishes")
	controller.queue_free()
	await get_tree().process_frame


func _test_offline_module_update() -> void:
	if OS.get_name() != "Linux":
		return
	var manager := ContinuumNativeServerManager.new()
	var id := "server-" + "d".repeat(24)
	manager.configure_instance(id, 3102)
	var adapter := FileUpdateAdapter.new()
	manager.platform_adapter = adapter
	DirAccess.make_dir_recursive_absolute(manager.data_dir)
	DirAccess.make_dir_recursive_absolute(manager.module_artifact.get_base_dir())
	_write(manager.module_artifact, "shared pinned module")
	_write(manager.data_dir.path_join("colony.save"), "persistent colony")
	_write(manager.data_dir.path_join(".continuum-module.sha256"), "a".repeat(64))
	manager.module_source_override = fixture.path_join("current-module.wasm")
	_write(manager.module_source_override, "current module")
	var shared := manager.module_artifact
	var old_helper := manager.supervisor
	var controller := ContinuumNativeServerController.new()
	controller.manager_factory = func(): return manager
	var result := ["pending"]
	var joins := [0]
	controller.module_update_finished.connect(func(error: String): result[0] = error)
	controller.server_ready.connect(func(_host, _database, _epoch): joins[0] += 1)
	get_tree().root.add_child(controller)
	_check(
		await _wait_for(func(): return controller.cached_state() == "offline"),
		"file-only module updater discovers stopped profile"
	)
	adapter.install_fails = true
	_check(controller.request_module_update(), "explicit module update queues once")
	_check(
		await _wait_for(func(): return result[0] != "pending"),
		"file-only module update reports lock failure"
	)
	_check(
		(
			not result[0].is_empty()
			and manager.module_artifact == shared
			and manager.supervisor == old_helper
			and adapter.autostart
		),
		"failed update retains old module/helper and login preference"
	)
	adapter.install_fails = false
	result[0] = "pending"
	controller.request_module_update()
	_check(
		await _wait_for(func(): return result[0] != "pending"),
		"file-only controller installs the current module after retry"
	)
	_check(
		(
			result[0].is_empty()
			and manager.module_artifact == manager._profile_module_path()
			and FileAccess.get_file_as_string(manager.module_artifact) == "current module"
		),
		"update uses a per-server artifact instead of its stale shared cache"
	)
	_check(
		(
			FileAccess.get_file_as_string(shared) == "shared pinned module"
			and (
				FileAccess.get_file_as_string(manager.data_dir.path_join("colony.save"))
				== "persistent colony"
			)
			and (
				FileAccess.get_file_as_string(
					manager.data_dir.path_join(".continuum-module.sha256")
				)
				== "a".repeat(64)
			)
		),
		"preparing an update preserves other modules, colony data, and the deployed pin"
	)
	_check(
		(
			adapter.autostart
			and manager.supervisor != old_helper
			and joins[0] == 0
			and manager.state() == "offline"
		),
		"update restores login startup with a new immutable helper but never launches or joins"
	)
	var reopened := ContinuumNativeServerManager.new()
	reopened.configure_instance(id, 3102)
	_check(
		(
			reopened.module_artifact == manager.module_artifact
			and reopened.supervisor == manager.supervisor
		),
		"reopening remembers the explicitly updated module and helper"
	)
	var fresh := ContinuumNativeServerManager.new()
	fresh.configure_instance("server-" + "e".repeat(24), 3103)
	fresh.platform_adapter = FileUpdateAdapter.new()
	fresh.module_source_override = fixture.path_join("fresh-module.wasm")
	_write(fresh.module_source_override, "current first-use module")
	_check(
		(
			fresh.prepare_module()
			and FileAccess.get_file_as_string(fresh.module_artifact) == "current first-use module"
			and FileAccess.get_file_as_string(shared) == "shared pinned module"
		),
		"first-use preparation does not provision a stale shared module or invalidate another server"
	)
	_write(
		fresh.data_dir.path_join(".continuum-module.sha256"),
		fresh._file_sha256(fresh.module_artifact)
	)
	_write(fresh.module_source_override, "a later module requiring an explicit update")
	_check(
		(
			fresh.prepare_module()
			and FileAccess.get_file_as_string(fresh.module_artifact) == "current first-use module"
		),
		"ordinary restarts retain the published per-profile module until explicit update"
	)
	_write(manager.manifest_file, "ambiguous ownership")
	_check(
		(
			not reopened.update_module().ok
			and FileAccess.get_file_as_string(manager.module_artifact) == "current module"
		),
		"ambiguous ownership refuses another module update"
	)
	DirAccess.remove_absolute(manager.manifest_file)
	controller.request_shutdown()
	_check(await _wait_for(controller.finish_shutdown), "file-only module worker finishes")
	controller.queue_free()
	await get_tree().process_frame


func _write(path: String, text: String) -> void:
	var file := FileAccess.open(path, FileAccess.WRITE)
	file.store_string(text)
	file.close()


func _test_updated_server_stop() -> void:
	if OS.get_name() != "Linux":
		return
	var manager := ContinuumNativeServerManager.new()
	manager.configure_instance("server-" + "f".repeat(24), 3104)
	var adapter := ManifestLifecycleAdapter.new()
	manager.platform_adapter = adapter
	manager.executable = fixture.path_join("recording-runtime")
	manager.cli_executable = fixture.path_join("recording-cli")
	_write(manager.executable, "never executed")
	_write(manager.cli_executable, "never executed")
	DirAccess.make_dir_recursive_absolute(manager.data_dir)
	_write(manager.module_artifact, "original shared module")
	_write(
		manager.data_dir.path_join(".continuum-module.sha256"),
		manager._file_sha256(manager.module_artifact)
	)
	_write(manager.data_dir.path_join("colony.save"), "persistent colony")
	manager.module_source_override = fixture.path_join("updated-lifecycle.wasm")
	_write(manager.module_source_override, "updated module")
	var controller := ContinuumNativeServerController.new()
	controller.manager_factory = func(): return manager
	var joined := [0]
	var update := ["pending"]
	controller.server_ready.connect(func(_host, _database, _epoch): joined[0] += 1)
	controller.module_update_finished.connect(func(error: String): update[0] = error)
	get_tree().root.add_child(controller)
	_check(
		await _wait_for(func(): return controller.cached_state() == "offline"),
		"manifest lifecycle starts offline"
	)
	controller.request_start()
	_check(
		await _wait_for(func(): return joined[0] == 1 and controller.cached_state() == "online"),
		"real manager joins its recorded initial runtime"
	)
	var old_helper := manager.supervisor
	controller.request_stop()
	_check(
		await _wait_for(func(): return controller.cached_state() == "offline"),
		"initial supervisor stops and releases its ownership snapshot"
	)
	controller.request_module_update()
	_check(
		await _wait_for(func(): return update[0] != "pending"),
		"real module helper prepares the stopped server update"
	)
	_check(
		update[0].is_empty() and manager.supervisor != old_helper,
		"updated module adopts its distinct immutable helper"
	)
	controller.request_start()
	_check(
		await _wait_for(func(): return joined[0] == 2 and controller.cached_state() == "online"),
		"updated manager joins its new supervisor identity"
	)
	controller.request_start()
	_check(
		await _wait_for(func(): return joined[0] == 3),
		"joining an already-running updated server retains its owner"
	)
	controller.request_stop()
	_check(
		await _wait_for(func(): return controller.cached_state() == "offline"),
		"the updated and rejoined server remains explicitly stoppable"
	)
	_check(
		(
			adapter.launches == 2
			and adapter.stops == 2
			and (
				FileAccess.get_file_as_string(manager.data_dir.path_join("colony.save"))
				== "persistent colony"
			)
		),
		"update/join/stop neither launches duplicates nor deletes the colony"
	)
	controller.request_shutdown()
	_check(
		await _wait_for(controller.finish_shutdown), "recording-process lifecycle worker finishes"
	)
	controller.queue_free()
	await get_tree().process_frame


func _test_ui_lifecycle() -> void:
	var main := preload("res://scenes/main.tscn").instantiate()
	main.set_script(preload("res://tools/managed_servers_main_fixture.gd"))
	get_tree().root.add_child(main)
	var browser: ContinuumServerManagement = main._server_management
	_check(
		await _wait_for(func(): return main._native_controller.cached_state() == "offline"),
		"initial server becomes manageable"
	)
	main._show_server_management()
	browser._local_start.pressed.emit()
	_check(await _wait_for(func(): return main.starts.size() == 1), "first server starts and joins")
	main.leave_session()
	main._show_server_management()
	browser._local_name.text = "Second colony"
	browser._local_create.pressed.emit()
	var second_id: String = main._native_server_id
	_check(
		second_id != "default" and main._native_catalog.entries().size() == 2,
		"Create adds and selects a durable second server"
	)
	_check(
		await _wait_for(func(): return main._native_controller.cached_state() == "offline"),
		"second server status is independent"
	)
	var first = main.managed["default"]
	var second = main.managed[second_id]
	browser._local_start.pressed.emit()
	_check(
		await _wait_for(func(): return main.starts.size() == 2), "second server starts and joins"
	)
	_check(
		(
			first.state() == "online"
			and second.state() == "online"
			and main._host == "http://127.0.0.1:3002"
		),
		"two servers run concurrently and join the selected port"
	)
	main._state_ready = true
	browser.set_busy(false)
	main._show_server_management()
	browser._managed_rows["default"].select.pressed.emit()
	_check(
		main._native_server_id == "default" and browser._local_start.text == "Join local server",
		"Manage selects an already-running server"
	)
	_check(browser._local_delete.disabled, "running servers cannot be deleted")
	browser.request_local_module_update()
	_check(
		(
			browser._local_update.disabled
			and first.updates == 0
			and main._native_update_dialog == null
		),
		"running servers cannot update their module"
	)
	var row: Label = browser._managed_rows["default"].address
	main._native_refresh()
	await get_tree().process_frame
	_check(
		browser._managed_rows["default"].address == row,
		"status refresh preserves row identity and focus"
	)
	browser._local_stop.pressed.emit()
	_check(
		await _wait_for(
			func():
				return (
					first.state() == "offline"
					and main._native_controller.cached_state() == "offline"
				)
		),
		"Stop affects the selected server"
	)
	_check(
		(
			first.stops == 1
			and second.stops == 0
			and second.state() == "online"
			and main._session_requested
		),
		"stopping another server leaves the current colony connected"
	)
	var original_settings: ClientSettings = main._settings.clone()
	var original_window_size := get_window().size
	get_window().size = Vector2i(360, 480)
	var large_text := original_settings.clone()
	large_text.font_size = 24
	main.apply_settings(large_text, false)
	browser.request_local_module_update()
	for _frame in 8:
		await get_tree().process_frame
	_check(
		(
			main._native_update_dialog.visible
			and main._native_update_dialog.dialog_text.contains("colony data is kept")
			and first.updates == 0
		),
		"module updates require a data-preserving confirmation"
	)
	_check(
		main._native_update_dialog.size.x <= 360 and main._native_update_dialog.position.x >= 0,
		"module confirmation fits a narrow window with large text"
	)
	main._native_update_dialog.hide()
	get_window().size = original_window_size
	main.apply_settings(original_settings, false)
	_check(first.updates == 0, "cancelled update confirmation leaves the module unchanged")
	browser.request_local_module_update()
	browser.request_server_selection(second_id)
	main._native_update_dialog.confirmed.emit()
	main._native_update_dialog.hide()
	_check(
		await _wait_for(func(): return first.updates == 1 and main._native_updating.is_empty()),
		"update confirmation preserves the captured stopped-server target"
	)
	_check(
		(
			second.updates == 0
			and second.state() == "online"
			and main._session_requested
			and first.starts == 1
		),
		"module preparation neither touches the other running server nor automatically starts this one"
	)
	browser.request_server_selection("default")
	first.update_error = "fixture update denied"
	browser.request_local_module_update()
	main._native_update_dialog.confirmed.emit()
	main._native_update_dialog.hide()
	_check(
		await _wait_for(func(): return browser._status.text == "fixture update denied"),
		"module update errors are visible and retryable"
	)
	_check(
		not browser._local_update.disabled and first.state() == "offline",
		"failed module update restores offline controls"
	)
	first.update_error = ""
	main._server_history.record_successful_subscription(
		first.host, "continuum", "default-world", "First"
	)
	var first_key := ContinuumConnectionHistory.canonical_key(first.host, "continuum")
	main._server_history.set_favorite(first_key, true)
	main._server_history.record_successful_subscription(
		"http://localhost:3001", "continuum", "default-world", "First alias"
	)
	main._server_history.record_successful_subscription(
		second.host, "continuum", "default-world", "Second"
	)
	main._settings.server_host = second.host
	main._settings.database = "continuum"
	browser.request_local_delete()
	_check(
		(
			main._native_delete_dialog.visible
			and main._native_delete_dialog.dialog_text.contains("Local server")
			and first.deletes == 0
		),
		"Delete requires a named permanent-data confirmation"
	)
	main._native_delete_dialog.hide()
	_check(first.deletes == 0, "cancelling the deletion dialog changes nothing")
	browser.request_local_delete()
	browser.request_server_selection(second_id)
	main._native_delete_dialog.confirmed.emit()
	main._native_delete_dialog.hide()
	_check(
		await _wait_for(func(): return main._native_catalog.entries().size() == 1),
		"confirmed deletion removes the captured server, not a newer selection"
	)
	_check(
		(
			first.deletes == 1
			and second.deletes == 0
			and second.state() == "online"
			and main._session_requested
		),
		"deletion leaves the other process and current session untouched"
	)
	_check(
		main._settings.server_host == second.host,
		"deleting another server preserves the last joined target"
	)
	_check(
		(
			main._server_history.entries().size() == 1
			and main._server_history.entries()[0].endpoint == second.host
		),
		"deleted server history is removed without deleting other saved connections"
	)
	_check(
		not FileAccess.get_file_as_string(main._server_history.favorites_path).contains(first_key),
		"deleted server favorites are removed"
	)
	browser._local_stop.pressed.emit()
	_check(
		await _wait_for(
			func():
				return (
					second.state() == "offline"
					and main._native_controller.cached_state() == "offline"
				)
		),
		"second server stops independently"
	)
	_check(
		not main._session_requested,
		"stopping the currently connected server ends only its client session"
	)
	main._show_server_management()
	second.deletion_error = "fixture deletion denied"
	browser.request_local_delete()
	main._native_delete_dialog.confirmed.emit()
	main._native_delete_dialog.hide()
	_check(
		await _wait_for(func(): return browser._status.text == "fixture deletion denied"),
		"deletion errors are visible and retryable"
	)
	_check(
		main._native_catalog.entries().size() == 1 and not browser._local_delete.disabled,
		"failed deletion keeps the managed entry"
	)
	second.deletion_error = ""
	browser.request_local_delete()
	main._native_delete_dialog.confirmed.emit()
	main._native_delete_dialog.hide()
	_check(
		await _wait_for(func(): return main._native_catalog.entries().is_empty()),
		"the last server can be deleted"
	)
	_check(
		(
			browser._local_start.disabled
			and not browser._local_create.disabled
			and browser._managed_rows.is_empty()
		),
		"empty list offers creation but no stale lifecycle controls"
	)
	_check(
		not main._menu._has_last_server(),
		"deleting the last joined server clears its stale Join last target"
	)
	await _dispose_main(main)
	var reopened := preload("res://scenes/main.tscn").instantiate()
	reopened.set_script(preload("res://tools/managed_servers_main_fixture.gd"))
	get_tree().root.add_child(reopened)
	_check(
		reopened._native_catalog.entries().is_empty() and reopened._native_controller == null,
		"empty managed list survives reopening the game UI"
	)
	await _dispose_main(reopened)


func _dispose_main(main: Node) -> void:
	var controllers: Array[ContinuumNativeServerController] = main._all_native_controllers()
	var ids: Array[int] = []
	for controller in controllers:
		ids.append(controller.get_instance_id())
		controller.request_shutdown()
	for id in ids:
		_check(
			await _wait_for(
				func():
					var controller = instance_from_id(id)
					return controller == null or controller.finish_shutdown()
			),
			"private worker finishes without host process actions"
		)
	main.queue_free()
	await get_tree().process_frame


func _wait_for(condition: Callable) -> bool:
	var deadline := Time.get_ticks_msec() + 5000
	while Time.get_ticks_msec() < deadline:
		if condition.call():
			await get_tree().process_frame
			return true
		await get_tree().create_timer(0.01).timeout
	return false


func _check(condition: bool, message: String) -> void:
	if not condition:
		failures += 1
		printerr("FAIL: " + message)
