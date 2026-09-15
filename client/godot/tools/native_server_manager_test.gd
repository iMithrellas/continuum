extends SceneTree

var failures := 0

func _initialize() -> void:
	await _first_use_is_locked_and_pinned()
	await _rediscovery_does_not_start_second_process()
	_test_force_requires_timeout()
	_test_force_waits_for_both_processes()
	_test_shutdown_refuses_replacement_manifest()
	_test_process_snapshot_reads_non_child()
	_test_systemd_path_validation()
	_test_windows_autostart_command_is_quoted()
	_test_unsupported_platform_message()
	_test_invalid_pid_never_reaches_termination()
	_test_live_mismatch_keeps_manifest()
	_test_conflict_never_clears_or_relaunches()
	_test_owned_unhealthy_is_stoppable_not_startable()
	_test_provisioning_has_long_budget()
	_test_manifest_validation_and_stale_cleanup()
	_test_manager_autostart_public_path()
	_test_status_poll_preserves_shutdown_state()
	_test_prepare_copy_failures_are_retryable()
	if not OS.get_environment("NATIVE_MANAGER_REAL").is_empty():
		if FileAccess.file_exists("/.dockerenv") and OS.get_environment("CONTINUUM_NATIVE_TEST_SANDBOX") == "private-pid-namespace":
			await _real_godot_manager_flow()
		else:
			_assert(false, "real signal tests require the private container harness")
	if failures == 0:
		print("NATIVE_SERVER_MANAGER_PASS")
		quit(0)
	else:
		print("NATIVE_SERVER_MANAGER_FAIL (%d failures)" % failures)
		quit(1)

func _manager(adapter: RefCounted, suffix: String):
	var manager = load("res://scripts/native_server_manager.gd").new()
	manager.platform_adapter = adapter
	manager.data_dir = "/tmp/continuum-native-%s/data" % suffix
	manager.manifest_file = "/tmp/continuum-native-%s/server.json" % suffix
	manager.lock_file = manager.data_dir + ".lock"
	manager.module_artifact = "/tmp/continuum-native-%s/module.wasm" % suffix
	manager.executable = "fake-spacetime"
	manager.supervisor = "fake-supervisor"
	DirAccess.remove_absolute(manager.lock_file)
	DirAccess.remove_absolute(manager.manifest_file)
	DirAccess.make_dir_recursive_absolute(manager.module_artifact.get_base_dir())
	var artifact := FileAccess.open(manager.module_artifact, FileAccess.WRITE)
	artifact.store_string("pinned module")
	return manager

func _first_use_is_locked_and_pinned() -> void:
	var adapter := FakeNativeAdapter.new()
	var manager = _manager(adapter, "first")
	_assert(manager.start(), "first use starts the locked supervisor")
	_assert(adapter.provision_calls == 0, "manager does not provision outside the supervisor lock")
	_assert(adapter.launch_calls == 1, "locked supervisor is the single launch entrypoint")
	manager.tick()
	_assert(manager.state() == "online", "health transitions to online")
	manager.stop(false)
	_assert(adapter.force_calls == 0, "graceful stop never force terminates")
	DirAccess.remove_absolute(manager.lock_file)
	DirAccess.remove_absolute(manager.manifest_file)

func _rediscovery_does_not_start_second_process() -> void:
	var adapter := FakeNativeAdapter.new()
	var first = _manager(adapter, "rediscover")
	_assert(first.start(), "rediscovery fixture starts")
	first.tick()
	first.tick()
	var second = _manager_without_cleanup(adapter, "rediscover")
	_assert(second.status() == "online", "new manager rediscovers healthy owned server")
	_assert(not second.start(), "rediscovery does not launch duplicate server")
	_assert(adapter.launch_calls == 1, "one physical server serves all logical worlds")
	first.stop(true)
	DirAccess.remove_absolute(first.lock_file)
	DirAccess.remove_absolute(first.manifest_file)

func _manager_without_cleanup(adapter: RefCounted, suffix: String):
	var manager = load("res://scripts/native_server_manager.gd").new()
	manager.platform_adapter = adapter
	manager.data_dir = "/tmp/continuum-native-%s/data" % suffix
	manager.manifest_file = "/tmp/continuum-native-%s/server.json" % suffix
	manager.lock_file = manager.data_dir + ".lock"
	manager.module_artifact = "/tmp/continuum-native-%s/module.wasm" % suffix
	manager.executable = "fake-spacetime"
	manager.supervisor = "fake-supervisor"
	return manager

func _real_manager(suffix: String, cleanup := true):
	var manager = load("res://scripts/native_server_manager.gd").new()
	manager.platform_adapter = load("res://scripts/native_server_platform_adapter.gd").new()
	manager.executable = OS.get_environment("NATIVE_MANAGER_RUNTIME")
	manager.cli_executable = OS.get_environment("NATIVE_MANAGER_CLI")
	manager.supervisor = OS.get_environment("NATIVE_MANAGER_SUPERVISOR")
	manager.module_artifact = OS.get_environment("NATIVE_MANAGER_MODULE")
	manager.data_dir = "/fixture/godot-manager-%s/data" % suffix
	manager.config_dir = "/fixture/godot-manager-%s/config" % suffix
	manager.log_file = "/fixture/godot-manager-%s/server.log" % suffix
	manager.manifest_file = "/fixture/godot-manager-%s/server.json" % suffix
	manager.lock_file = manager.data_dir + ".lock"
	if cleanup:
		DirAccess.remove_absolute(manager.manifest_file)
	return manager

func _read_real_manifest(manager) -> Dictionary:
	if not FileAccess.file_exists(manager.manifest_file):
		return {}
	var parsed = JSON.parse_string(FileAccess.get_file_as_string(manager.manifest_file))
	return parsed if parsed is Dictionary else {}

func _real_godot_manager_flow() -> void:
	print("REAL_GODOT_PHASE=setup")
	var manager = _real_manager("owned")
	print("REAL_GODOT_SUPPORT=%s PROCESSOR=%s RUNTIME_EXISTS=%s CLI_EXISTS=%s SUPERVISOR_EXISTS=%s MODULE_EXISTS=%s" % [manager.platform_adapter.supports_native_hosting(), OS.get_processor_name(), FileAccess.file_exists(manager.executable), FileAccess.file_exists(manager.cli_executable), FileAccess.file_exists(manager.supervisor), FileAccess.file_exists(manager.module_artifact)])
	var real_failure := [""]
	manager.failed.connect(func(message: String) -> void: real_failure[0] = message)
	var started_at := Time.get_ticks_msec()
	_assert(manager.start(), "real manager launches the native supervisor")
	print("REAL_GODOT_START_RESULT state=%s error=%s" % [manager.state(), real_failure[0]])
	print("REAL_GODOT_OWNER pid=%d started_at=%s" % [manager._pid, manager._started_at])
	print("REAL_GODOT_PHASE=launch_requested")
	var saw_provisioning := false
	var became_online := false
	for _i in range(1800):
		manager.tick()
		var manifest := _read_real_manifest(manager)
		if str(manifest.get("phase", "")) == "provisioning":
			saw_provisioning = true
			if manager.state() == "online":
				_assert(false, "real manager never reports online during provisioning")
		if manager.state() == "online":
			became_online = true
			break
		await process_frame
	_assert(saw_provisioning, "real manager observes provisioning before publication")
	_assert(became_online, "real manager reaches online through tick loop")
	if not became_online:
		print("REAL_GODOT_TIMEOUT state=%s manifest=%s" % [manager.state(), JSON.stringify(_read_real_manifest(manager))])
		return
	var online_manifest := _read_real_manifest(manager)
	_assert(str(online_manifest.get("phase", "")) == "running", "online requires published running phase")
	_assert(int(online_manifest.get("pid", -1)) == manager._pid, "manager owns the supervisor PID")
	_assert(int(online_manifest.get("runtime_pid", -1)) != manager._pid, "manager metadata distinguishes runtime child PID")
	print("REAL_GODOT_START_TICK_ONLINE=pass ELAPSED_MS=%d" % (Time.get_ticks_msec() - started_at))
	var sibling_data := "/fixture/godot-sibling/data"
	var sibling_config := "/fixture/godot-sibling/config"
	DirAccess.make_dir_recursive_absolute(sibling_data)
	DirAccess.make_dir_recursive_absolute(sibling_config)
	var sibling_pid := OS.create_process(manager.executable, ["start", "--listen-addr", "127.0.0.1:3002", "--data-dir", sibling_data, "--jwt-key-dir", sibling_config], false)
	if sibling_pid <= 1:
		_assert(false, "sibling runtime has a valid owned PID")
		return
	var sibling_started_at := ""
	for _i in range(50):
		sibling_started_at = manager.platform_adapter._process_start_token(sibling_pid)
		if not sibling_started_at.is_empty():
			break
		await process_frame
	var tampered_manifest := online_manifest.duplicate()
	tampered_manifest["runtime_pid"] = sibling_pid
	tampered_manifest["runtime_started_at"] = sibling_started_at
	_write_manifest(manager.manifest_file, tampered_manifest)
	var tampered = _real_manager("owned", false)
	_assert(tampered.status() == "conflict", "same-binary runtime with the wrong parent role is rejected")
	_write_manifest(manager.manifest_file, online_manifest)
	if not _real_signal(manager, sibling_pid, sibling_started_at, manager.executable, "INT"):
		return
	print("REAL_GODOT_RUNTIME_PARENT_ROLE_GUARD=pass")

	if not _real_signal(manager, manager._pid, manager._started_at, manager.supervisor, "KILL"):
		return
	for _i in range(100):
		if not manager.platform_adapter.process_exists(manager._pid):
			break
		await create_timer(0.05).timeout
	var rediscovered = _real_manager("owned", false)
	_assert(rediscovered.status() == "online", "fresh manager adopts the healthy runtime after supervisor death")
	_assert(rediscovered._adopted_runtime, "fresh manager records runtime adoption")
	_assert(not rediscovered.start(), "fresh manager does not launch a duplicate server")
	print("REAL_GODOT_SUPERVISOR_KILL_RUNTIME_ADOPTION=pass")

	var unhealthy = _real_manager("owned", false)
	unhealthy.platform_adapter = FalseHealthAdapter.new(unhealthy.platform_adapter)
	_assert(unhealthy.status() == "unhealthy", "owned server with failed health is unhealthy")
	_assert(not unhealthy.start(), "owned unhealthy server cannot start another process")
	_assert(unhealthy.can_stop(), "owned unhealthy server remains stoppable")
	print("REAL_GODOT_UNHEALTHY_STOP_GUARD=pass")

	if failures > 0:
		return
	_assert(rediscovered.stop(false), "adopted manager requests graceful SIGINT stop")
	for _i in range(120):
		rediscovered.tick()
		if rediscovered.state() == "offline":
			break
		await process_frame
	_assert(rediscovered.status() == "offline", "real manager reaches offline after graceful stop")
	_assert(not FileAccess.file_exists(rediscovered.manifest_file), "stopped manager clears owned metadata")
	_assert(rediscovered.start(), "lock is released after graceful stop")
	for _i in range(1800):
		rediscovered.tick()
		if rediscovered.state() == "online":
			break
		await process_frame
	_assert(rediscovered.state() == "online", "manager restarts after releasing the lock")
	if failures > 0:
		return
	_assert(not rediscovered.stop(true), "force stop is rejected before a real timeout")
	var stopping_manifest := _read_real_manifest(rediscovered)
	if not _real_signal(rediscovered, rediscovered._pid, rediscovered._started_at, rediscovered.supervisor, "STOP"):
		return
	_assert(rediscovered.stop(false), "stalled supervisor accepts graceful stop request")
	var stop_deadline := Time.get_ticks_msec() + 8000
	while Time.get_ticks_msec() < stop_deadline:
		rediscovered.tick()
		if rediscovered.state() == "stop_timeout":
			break
		await create_timer(0.05).timeout
	_assert(rediscovered.state() == "stop_timeout", "stalled supervisor reaches stop timeout")
	_assert(rediscovered.platform_adapter.process_exists(rediscovered._runtime_pid), "runtime remains alive while supervisor is stopped")
	_assert(rediscovered.platform_adapter.health(rediscovered.host), "runtime remains healthy while supervisor is stopped")
	if failures > 0:
		return
	_assert(rediscovered.stop(true), "force stop is accepted only after timeout")
	var force_deadline := Time.get_ticks_msec() + 6000
	while Time.get_ticks_msec() < force_deadline:
		rediscovered.tick()
		if rediscovered.state() == "offline":
			break
		await create_timer(0.02).timeout
	_assert(rediscovered.state() == "offline", "forced stop ends supervisor and runtime")
	_assert(not rediscovered.platform_adapter.process_exists(int(stopping_manifest.pid)), "forced supervisor is actually gone")
	_assert(not rediscovered.platform_adapter.process_exists(int(stopping_manifest.runtime_pid)), "forced runtime is actually gone")
	_assert(not FileAccess.file_exists(rediscovered.manifest_file), "forced stop clears metadata after both owners die")
	if failures > 0:
		return
	_assert(rediscovered.start(), "forced stop releases the runtime lock")
	for _i in range(1800):
		rediscovered.tick()
		if rediscovered.state() == "online":
			break
		await process_frame
	_assert(rediscovered.state() == "online", "server restarts after forced stop")
	_assert(FileAccess.file_exists(rediscovered.data_dir + "/.continuum-module.sha256"), "forced stop preserves persisted module state")
	_assert(rediscovered.stop(false), "restarted manager stops gracefully")
	for _i in range(120):
		rediscovered.tick()
		if rediscovered.state() == "offline":
			break
		await process_frame
	_assert(rediscovered.state() == "offline", "restarted graceful stop completes before stale metadata test")
	print("REAL_GODOT_STOP_TIMEOUT_FORCE_RESTART_LOCK=pass")
	var stale_manifest := online_manifest.duplicate()
	stale_manifest["pid"] = 999991
	stale_manifest["runtime_pid"] = 999992
	stale_manifest["started_at"] = "999991"
	stale_manifest["runtime_started_at"] = "999992"
	stale_manifest["runtime_parent_pid"] = 999991
	_write_manifest(rediscovered.manifest_file, stale_manifest)
	var stale_manager = _real_manager("owned", false)
	_assert(stale_manager.status() == "offline", "fresh manager identifies all-dead owner metadata as stale")
	_assert(not FileAccess.file_exists(stale_manager.manifest_file), "fresh manager removes only the verified stale manifest")
	print("REAL_GODOT_STALE_OWNER_CLEANUP=pass")

	var invalid = _real_manager("invalid")
	invalid.executable += ".missing"
	var invalid_started := Time.get_ticks_msec()
	_assert(not invalid.start(), "invalid runtime fails before creating a supervisor")
	_assert(invalid.state() == "offline", "invalid runtime leaves manager offline")
	_assert(Time.get_ticks_msec() - invalid_started < 5000, "invalid runtime failure is bounded")
	print("REAL_GODOT_STARTUP_FAILURE_BOUNDED=pass")

func _real_signal(manager, pid: int, token: String, binary: String, signal_name: String) -> bool:
	var safe: bool = failures == 0 and FileAccess.file_exists("/.dockerenv") \
		and OS.get_environment("CONTINUUM_NATIVE_TEST_SANDBOX") == "private-pid-namespace" \
		and pid > 1 and ["INT", "KILL", "STOP"].has(signal_name) \
		and manager.platform_adapter.is_process_identity(pid, token, binary, manager._file_sha256(binary))
	if not safe:
		_assert(false, "real signal requires a verified owned process in the private container")
		return false
	var output: Array = []
	var exit_code := OS.execute("/bin/kill", ["-s", signal_name, "--", str(pid)], output, true)
	var sent := exit_code == 0
	if not sent:
		printerr("Container signal failed: exit=%d output=%s" % [exit_code, str(output)])
	_assert(sent, "verified container process accepts " + signal_name)
	return sent

class FalseHealthAdapter extends RefCounted:
	var inner: RefCounted

	func _init(value: RefCounted) -> void:
		inner = value

	func supports_native_hosting() -> bool:
		return inner.supports_native_hosting()

	func health(_host: String) -> bool:
		return false

	func launch(supervisor: String, runtime: String, cli: String, module: String, host: String, database: String, data_path: String, config_path: String, lock_path: String, log_path: String, manifest_path: String, module_sha256: String, startup_nonce: String) -> Dictionary:
		return inner.launch(supervisor, runtime, cli, module, host, database, data_path, config_path, lock_path, log_path, manifest_path, module_sha256, startup_nonce)

	func is_process_identity(pid: int, started_at: String, expected_binary: String, expected_sha256: String, expected_parent_pid := -1) -> bool:
		return inner.is_process_identity(pid, started_at, expected_binary, expected_sha256, expected_parent_pid)

	func process_exists(pid: int) -> bool:
		return inner.process_exists(pid)

	func cleanup_stale(supervisor: String, lock_path: String, manifest_path: String, manifest_sha256: String) -> bool:
		return inner.cleanup_stale(supervisor, lock_path, manifest_path, manifest_sha256)

	func terminate(pid: int, force: bool, started_at: String, expected_binary: String, expected_sha256: String, expected_parent_pid := -1) -> bool:
		return inner.terminate(pid, force, started_at, expected_binary, expected_sha256, expected_parent_pid)

func _test_unsupported_platform_message() -> void:
	var manager = load("res://scripts/native_server_manager.gd").new()
	var message := [""]
	manager.failed.connect(func(value: String) -> void: message[0] = value)
	# The assertion is platform-independent: the public message names the fallback.
	_assert(manager._unsupported_reason().contains("Docker"), "unsupported platforms have actionable fallback")

func _test_windows_autostart_command_is_quoted() -> void:
	var adapter = load("res://scripts/native_server_platform_adapter.gd").new()
	var command: String = adapter.windows_task_command("C:/Program Files/Continuum/spacetime.exe", "http://127.0.0.1:3001", "C:/Users/test user/data")
	_assert(command.begins_with('"C:/Program Files/Continuum/spacetime.exe"'), "Windows task quotes executable paths")
	_assert(command.contains('"C:/Users/test user/data"'), "Windows task quotes data paths")

func _test_invalid_pid_never_reaches_termination() -> void:
	var adapter := FakeNativeAdapter.new()
	var manager = _manager(adapter, "invalid-pid")
	manager._state = manager.State.STOP_TIMEOUT
	for invalid_pid in [-1, 0, 1]:
		manager._pid = invalid_pid
		_assert(not manager.stop(true), "invalid pid %d cannot be force-stopped" % invalid_pid)
	_assert(adapter.terminate_calls == 0, "invalid manager PIDs make no OS termination call")

func _test_force_requires_timeout() -> void:
	var adapter := FakeNativeAdapter.new()
	var manager = _manager(adapter, "force")
	manager.start()
	manager.tick()
	manager.tick()
	_assert(not manager.stop(true), "force stop is rejected before timeout")
	adapter.graceful_hangs = true
	manager.stop(false)
	manager._stop_deadline = 0
	manager.tick()
	_assert(manager.state() == "stop_timeout", "graceful timeout is visible before force")
	_assert(manager.stop(true), "force stop is accepted after timeout")
	_assert(FileAccess.file_exists(manager.manifest_file), "force request does not clear live metadata")
	adapter.healthy = false
	manager.tick()
	_assert(not FileAccess.file_exists(manager.manifest_file), "metadata clears only after process death")

func _test_force_waits_for_both_processes() -> void:
	var adapter := FakeNativeAdapter.new()
	adapter.graceful_hangs = true
	adapter.auto_exit_on_force = false
	var manager = _manager(adapter, "two-process-stop")
	_assert(manager.start(), "two-process fixture starts")
	manager.tick()
	_assert(manager.stop(), "graceful stop requested before escalation")
	manager._stop_deadline = 0
	manager.tick()
	_assert(manager.stop(true), "force requests both owned process exits")
	_assert(adapter.forced_pids == [4243, 4242], "force targets runtime before supervisor, independently")
	_assert(manager._stop_deadline > Time.get_ticks_msec(), "forced exit gets its own bounded wait")
	adapter.supervisor_alive = false
	manager.tick()
	_assert(manager.state() == "stopping", "dead supervisor does not imply stopped runtime")
	_assert(FileAccess.file_exists(manager.manifest_file), "live runtime retains ownership metadata")
	adapter.runtime_alive = false
	adapter.cleanup_allowed = false
	manager.tick()
	_assert(manager.state() == "stopping", "transient lock release is retried while the shutdown deadline remains")
	manager._stop_deadline = 0
	manager.tick()
	_assert(manager.state() == "conflict", "failed lock cleanup is not reported as offline")
	_assert(FileAccess.file_exists(manager.manifest_file), "failed cleanup preserves manifest")
	adapter.cleanup_allowed = true
	manager._state = manager.State.STOPPING
	manager.tick()
	_assert(manager.state() == "offline", "offline requires both exits and confirmed cleanup")
	_assert(not FileAccess.file_exists(manager.manifest_file), "confirmed lock cleanup removes only the old manifest")

func _test_shutdown_refuses_replacement_manifest() -> void:
	var adapter := FakeNativeAdapter.new()
	adapter.graceful_hangs = true
	var manager = _manager(adapter, "replacement-stop")
	manager.start()
	manager.tick()
	manager.stop()
	manager._stop_deadline = 0
	manager.tick()
	var replacement: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(manager.manifest_file))
	replacement["startup_nonce"] = "another-owner"
	_write_manifest(manager.manifest_file, replacement)
	_assert(not manager.stop(true), "force refuses a replacement owner")
	_assert(adapter.force_calls == 0, "replacement owner receives no force signal")
	adapter.process_alive = false
	manager.tick()
	_assert(manager.state() == "conflict", "replacement manifest is not reported as our stopped server")
	_assert(FileAccess.file_exists(manager.manifest_file), "replacement manifest is preserved")
	DirAccess.remove_absolute(manager.manifest_file)

func _test_process_snapshot_reads_non_child() -> void:
	if OS.get_name() != "Linux":
		return
	var adapter = load("res://scripts/native_server_platform_adapter.gd").new()
	var self_pid := OS.get_process_id()
	_assert(adapter.process_exists(self_pid), "Linux liveness works without a child-process handle")
	_assert(not adapter._process_start_token(self_pid).is_empty(), "procfs zero-length stat exposes a start token")
	var parent: int = adapter._process_parent_pid(self_pid)
	_assert(parent > 1 and adapter.process_exists(parent), "parent liveness is read without waitpid")
	for invalid_pid in [-1, 0, 1]:
		_assert(not adapter.process_exists(invalid_pid), "invalid PID is never considered a managed process")

func _test_live_mismatch_keeps_manifest() -> void:
	var adapter := FakeNativeAdapter.new()
	var manager = _manager(adapter, "mismatch")
	manager.start()
	manager.tick()
	manager._started_at = "wrong-start-token"
	manager._state = manager.State.STARTING
	manager._start_deadline = 0
	manager.tick()
	_assert(manager.state() == "conflict", "live identity mismatch becomes conflict")
	_assert(FileAccess.file_exists(manager.manifest_file), "live identity mismatch keeps manifest")
	adapter.healthy = false
	DirAccess.remove_absolute(manager.manifest_file)

func _test_conflict_never_clears_or_relaunches() -> void:
	var adapter := FakeNativeAdapter.new()
	var first = _manager(adapter, "conflict")
	first.start()
	first.tick()
	adapter.owned = false
	var second = _manager_without_cleanup(adapter, "conflict")
	_assert(second.status() == "conflict", "different manager identity becomes conflict")
	_assert(not second.start(), "conflict cannot start a second supervisor")
	_assert(adapter.launch_calls == 1, "conflict does not relaunch")
	_assert(FileAccess.file_exists(second.manifest_file), "conflict retains the other manager manifest")
	adapter.healthy = false
	DirAccess.remove_absolute(second.manifest_file)

func _test_owned_unhealthy_is_stoppable_not_startable() -> void:
	var adapter := FakeNativeAdapter.new()
	var manager = _manager(adapter, "unhealthy")
	manager.start()
	manager.tick()
	adapter.healthy = false
	adapter.owned = true
	adapter.phase = "running"
	var manifest: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(manager.manifest_file))
	manifest["phase"] = "running"
	var manifest_file := FileAccess.open(manager.manifest_file, FileAccess.WRITE)
	manifest_file.store_string(JSON.stringify(manifest))
	manifest_file.close()
	manager._state = manager.State.UNKNOWN
	_assert(manager.status() == "unhealthy", "owned health failure is visible as unhealthy")
	_assert(not manager.start(), "owned unhealthy server cannot be started again")
	_assert(manager.can_stop(), "owned unhealthy server remains stoppable")
	DirAccess.remove_absolute(manager.manifest_file)

func _test_provisioning_has_long_budget() -> void:
	var adapter := FakeNativeAdapter.new()
	adapter.phase = "provisioning"
	var manager = _manager(adapter, "provisioning")
	manager.start()
	manager._startup_phase = "provisioning"
	manager._start_deadline = Time.get_ticks_msec() + 1000
	manager.tick()
	_assert(manager.state() == "starting", "slow provisioning remains starting within its budget")
	_assert(adapter.launch_calls == 1, "slow provisioning remains one owned supervisor")
	DirAccess.remove_absolute(manager.manifest_file)

func _test_manifest_validation_and_stale_cleanup() -> void:
	var adapter := FakeNativeAdapter.new()
	var manager = _manager(adapter, "manifest-validation")
	_assert(manager.start(), "manifest validation fixture starts")
	manager.tick()
	var valid_manifest: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(manager.manifest_file))
	var missing_manifest := valid_manifest.duplicate()
	missing_manifest.erase("runtime_started_at")
	_write_manifest(manager.manifest_file, missing_manifest)
	_assert(manager.status() == "conflict", "mandatory runtime identity metadata is fail-closed")
	_assert(FileAccess.file_exists(manager.manifest_file), "incomplete metadata is not deleted")
	_write_manifest(manager.manifest_file, valid_manifest)
	var mismatch_manifest := valid_manifest.duplicate()
	mismatch_manifest["started_at"] = "wrong-start-token"
	_write_manifest(manager.manifest_file, mismatch_manifest)
	_assert(manager.status() == "conflict", "PID start identity mismatch is fail-closed")
	_write_manifest(manager.manifest_file, valid_manifest)
	adapter.process_alive = false
	_assert(manager.status() == "offline", "dead owner metadata becomes stale")
	_assert(not FileAccess.file_exists(manager.manifest_file), "stale dead-owner metadata is cleaned")
	DirAccess.remove_absolute(manager.lock_file)

func _write_manifest(path: String, value: Dictionary) -> void:
	var file := FileAccess.open(path, FileAccess.WRITE)
	file.store_string(JSON.stringify(value))
	file.close()

func _test_manager_autostart_public_path() -> void:
	var adapter := FakeNativeAdapter.new()
	var manager = _manager(adapter, "autostart")
	_assert(manager.set_autostart(true).ok, "manager autostart uses the platform adapter public path")
	_assert(adapter.autostart_calls == 1, "manager autostart does not register a host process directly")
	DirAccess.remove_absolute(manager.lock_file)

func _test_status_poll_preserves_shutdown_state() -> void:
	var adapter := FakeNativeAdapter.new()
	var manager = _manager(adapter, "status-shutdown")
	manager.start()
	manager.tick()
	_assert(manager.stop(false), "status-poll fixture accepts graceful stop")
	_assert(manager.status() == "stopping", "status polling does not overwrite STOPPING")
	manager._stop_deadline = 0
	manager.tick()
	_assert(manager.status() == "stop_timeout", "status polling preserves STOP_TIMEOUT")
	_assert(manager._active_binary_hash() == "unavailable", "graceful stop retains the stored supervisor hash")
	DirAccess.remove_absolute(manager.manifest_file)

func _test_prepare_copy_failures_are_retryable() -> void:
	_prepare_copy_failure("packaged", "packaged module")
	_prepare_copy_failure("source-built", "source-built module")

func _prepare_copy_failure(label: String, source_text: String) -> void:
	var adapter := FakeNativeAdapter.new()
	var manager = _manager(adapter, "prepare-%s" % label)
	DirAccess.remove_absolute(manager.module_artifact)
	var source := "/tmp/continuum-native-prepare-%s-source.wasm" % label
	var source_file := FileAccess.open(source, FileAccess.WRITE)
	source_file.store_string(source_text)
	source_file.close()
	manager.module_source_override = source
	var blocked_parent := "/tmp/continuum-native-prepare-%s-blocked" % label
	var blocked := FileAccess.open(blocked_parent, FileAccess.WRITE)
	blocked.store_string("not a directory")
	blocked.close()
	manager.module_artifact = blocked_parent + "/module.wasm"
	var progress_messages: Array[String] = []
	manager.progress.connect(func(message: String) -> void: progress_messages.append(message))
	_assert(not manager.prepare_module(), "%s artifact copy failure is reported" % label)
	_assert(manager.state() == "offline", "%s copy failure is retryable offline" % label)
	_assert(not progress_messages.is_empty() and progress_messages[0].contains("Preparing"),
		"%s copy failure reports preparation progress" % label)
	DirAccess.remove_absolute(blocked_parent)
	manager.module_artifact = "/tmp/continuum-native-prepare-%s-retry/module.wasm" % label
	_assert(manager.prepare_module(), "%s preparation can be retried" % label)
	_assert(manager.state() != "preparing", "%s retry does not remain preparing" % label)
	DirAccess.remove_absolute(source)
	DirAccess.remove_absolute(manager.module_artifact)

func _test_systemd_path_validation() -> void:
	var adapter = load("res://scripts/native_server_platform_adapter.gd").new()
	var unit: String = adapter.linux_unit_contents("/tmp/super visor", "/tmp/runtime", "/tmp/cli", "/tmp/module.wasm", "127.0.0.1:3001", "continuum", "/tmp/data with spaces", "/tmp/config", "/tmp/lock", "/tmp/log", "/tmp/server.json", "abc123", "fake-nonce")
	_assert(unit.contains('"/tmp/super visor" start "/tmp/runtime"'), "systemd uses the shared supervisor")
	_assert(unit.contains('"/tmp/data with spaces"'), "systemd quotes space-containing paths")
	_assert(adapter.linux_unit_contents("/tmp/supervisor", "/tmp/runtime", "/tmp/cli", "/tmp/module", "http://127.0.0.1:3001", "continuum", "/tmp/data", "/tmp/config", "/tmp/lock", "/tmp/log", "/tmp/server", "abc123", "fake-nonce").contains("127.0.0.1:3001"), "autostart normalizes the manager host URL")
	_assert(adapter.linux_unit_contents("/tmp/bad%path", "/tmp/runtime", "/tmp/cli", "/tmp/module", "127.0.0.1:3001", "continuum", "/tmp/data", "/tmp/config", "/tmp/lock", "/tmp/log", "/tmp/server", "abc123", "fake-nonce") == "", "systemd rejects percent injection")

func _assert(condition: bool, description: String) -> void:
	if not condition:
		failures += 1
		printerr("FAIL: %s" % description)

class FakeNativeAdapter extends RefCounted:
	var provision_calls := 0
	var launch_calls := 0
	var force_calls := 0
	var healthy := false
	var graceful_hangs := false
	var terminate_calls := 0
	var autostart_calls := 0
	var owned := true
	var phase := "running"
	var process_alive := true
	var supervisor_alive := true
	var runtime_alive := true
	var auto_exit_on_force := true
	var cleanup_allowed := true
	var forced_pids: Array[int] = []

	func supports_native_hosting() -> bool:
		return true

	func provision(_provisioner: String, _cli: String, _artifact: String, _host: String, _database: String, _config: String, _log: String) -> Dictionary:
		provision_calls += 1
		return {"ok": true, "pid": -1}

	func launch(_supervisor: String, _runtime: String, _cli: String, _module: String, _host: String, _database: String, _data: String, _config: String, _lock: String, _log: String, manifest: String, module_sha256: String, startup_nonce: String) -> Dictionary:
		launch_calls += 1
		healthy = phase != "provisioning"
		var file := FileAccess.open(manifest, FileAccess.WRITE)
		file.store_string(JSON.stringify({"phase":phase, "runtime":"2.10.0", "runtime_sha256":"unavailable", "cli_sha256":"unavailable", "supervisor_sha256":"unavailable", "module_sha256":module_sha256, "database":"continuum", "pid":4242, "runtime_pid":4243, "started_at":"fake-start", "runtime_started_at":"fake-runtime-start", "runtime_parent_pid":4242, "runtime_binary":"fake-spacetime", "startup_nonce":startup_nonce, "data_dir":_data, "host":"http://127.0.0.1:3001"}))
		file.close()
		return {"ok": true, "pid": 4242, "started_at": "fake-start"}

	func health(_host: String) -> bool:
		return healthy

	func is_process_identity(pid: int, started: String, binary: String, _hash: String, parent_pid := -1) -> bool:
		return process_exists(pid) and owned and ((pid == 4243 and binary == "fake-spacetime" and started == "fake-runtime-start" and (parent_pid <= 1 or parent_pid == 4242)) or (pid == 4242 and binary == "fake-supervisor" and started == "fake-start"))

	func process_exists(pid: int) -> bool:
		return process_alive and ((pid == 4242 and supervisor_alive) or (pid == 4243 and runtime_alive))

	func cleanup_stale(_supervisor: String, _lock_path: String, manifest: String, _manifest_sha256: String) -> bool:
		if not cleanup_allowed:
			return false
		DirAccess.remove_absolute(manifest)
		return true

	func terminate(pid: int, force: bool, _started: String, _binary: String, _hash: String, _parent_pid := -1) -> bool:
		terminate_calls += 1
		if force:
			force_calls += 1
			forced_pids.append(pid)
			if auto_exit_on_force:
				if pid == 4242:
					supervisor_alive = false
				if pid == 4243:
					runtime_alive = false
					healthy = false
		return true

	func set_autostart(_enabled: bool, _supervisor: String, _runtime: String, _cli: String, _module: String, _host: String, _database: String, _data: String, _config: String, _lock: String, _log: String, _manifest: String, _module_sha256: String, _startup_nonce: String) -> Dictionary:
		autostart_calls += 1
		return {"ok": true}
