class_name ContinuumNativeServerPlatformAdapter extends RefCounted

## Common surface reserved for the Windows worker; Linux exposes it now so both
## workers consume the same latest manifest contract.
func runtime_path(version: String) -> Dictionary:
	var root := (OS.get_environment("XDG_DATA_HOME") if not OS.get_environment("XDG_DATA_HOME").is_empty() else OS.get_environment("HOME").path_join(".local/share")).path_join("Continuum/native/spacetimedb/%s" % version)
	return {"runtime": root.path_join("spacetimedb-standalone"), "cli": root.path_join("spacetimedb-cli"), "supervisor": root.path_join("native-server-supervisor.sh")}

func manifest_fields() -> PackedStringArray:
	return PackedStringArray(["phase", "runtime", "runtime_sha256", "cli_sha256", "supervisor_sha256", "module_sha256", "database", "pid", "runtime_pid", "started_at", "runtime_started_at", "runtime_parent_pid", "runtime_binary", "startup_nonce", "data_dir", "host"])

func supports_native_hosting() -> bool:
	return OS.get_name() == "Linux" and _linux_x86_64()

func _linux_x86_64() -> bool:
	var output: Array = []
	if OS.execute("uname", ["-m"], output, true) != 0 or output.is_empty():
		return false
	return ["x86_64", "amd64"].has(str(output[0]).strip_edges().to_lower())

func launch(supervisor: String, runtime: String, cli: String, module: String, host: String, database: String, data_path: String, config_path: String, lock_path: String, log_path: String, manifest_path: String, module_sha256: String, startup_nonce: String) -> Dictionary:
	if supervisor.is_empty() or runtime.is_empty() or cli.is_empty() or not FileAccess.file_exists(supervisor) \
		or not FileAccess.file_exists(runtime) or not FileAccess.file_exists(cli):
		return {"ok": false, "error": "The pinned SpacetimeDB runtime is not installed for this platform."}
	if host != "http://127.0.0.1:3001" or database.is_empty() or module_sha256 == "unavailable":
		return {"ok": false, "error": "Native hosting requires the fixed localhost endpoint and a pinned module."}
	var pid := OS.create_process(supervisor, ["start", runtime, cli, module, host.trim_prefix("http://"), database, data_path, config_path, lock_path, log_path, manifest_path, module_sha256, startup_nonce], false)
	if pid <= 1:
		return {"ok": false, "error": "Could not launch SpacetimeDB; check the installed v2.10.0 distribution."}
	var started_at := ""
	for _i in range(50):
		started_at = _process_start_token(pid)
		if not started_at.is_empty():
			break
		OS.delay_msec(10)
	return {"ok": true, "pid": pid, "started_at": started_at}

func health(_host: String) -> bool:
	var output: Array = []
	return OS.execute("curl", ["--silent", "--fail", "--max-time", "1", _host + "/v1/ping"], output, true) == 0

func is_process_identity(pid: int, started_at: String, expected_binary: String, expected_sha256: String, expected_parent_pid := -1) -> bool:
	if pid <= 1 or started_at.is_empty() or expected_binary.is_empty() or not process_exists(pid):
		return false
	if _process_start_token(pid) != started_at or not _process_command_contains(pid, expected_binary):
		return false
	if expected_parent_pid > 1 and _process_parent_pid(pid) != expected_parent_pid:
		return false
	return expected_sha256.is_empty() or _file_sha256(expected_binary) == expected_sha256

func process_exists(pid: int) -> bool:
	if pid <= 1:
		return false
	var snapshot := _process_snapshot(pid)
	if snapshot.is_empty():
		# Unreadable identity is not proof of death. Adoption may involve a
		# process that this Godot instance did not spawn, so do not use waitpid.
		return DirAccess.dir_exists_absolute("/proc/%d" % pid)
	return not ["Z", "X", "x"].has(snapshot.state)

func terminate(pid: int, force: bool, started_at: String, expected_binary: String, expected_sha256: String, expected_parent_pid := -1) -> bool:
	if OS.get_name() != "Linux" or not is_process_identity(pid, started_at, expected_binary, expected_sha256, expected_parent_pid):
		return false
	# Use the executable, not /bin/sh's kill builtin (dash parses '--' differently).
	return OS.execute("/bin/kill", ["-s", "KILL" if force else "INT", "--", str(pid)], [], true) == 0

func cleanup_stale(supervisor: String, lock_path: String, manifest_path: String, manifest_sha256: String) -> bool:
	return OS.execute(supervisor, ["cleanup", lock_path, manifest_path, manifest_sha256], [], true) == 0

func set_autostart(enabled: bool, supervisor: String, runtime: String, cli: String, module: String, host: String, database: String, data_path: String, config_path: String, lock_path: String, log_path: String, manifest_path: String, module_sha256: String, _startup_nonce: String) -> Dictionary:
	if OS.get_name() == "Linux":
		var unit_dir := OS.get_environment("HOME").path_join(".config/systemd/user")
		var unit_path := unit_dir.path_join("continuum-native.service")
		if FileAccess.file_exists(unit_path) and not FileAccess.get_file_as_string(unit_path).begins_with("# Managed by Continuum\n"):
			return {"ok": false, "error": "A manually configured continuum-native.service already exists; it was not changed."}
		if not enabled:
			if not FileAccess.file_exists(unit_path):
				return {"ok": true}
			if OS.execute("systemctl", ["--user", "disable", "continuum-native.service"], [], true) != 0:
				return {"ok": false, "error": "Could not disable native server autostart."}
			if DirAccess.remove_absolute(unit_path) != OK:
				return {"ok": false, "error": "Could not remove the disabled native server unit."}
			OS.execute("systemctl", ["--user", "daemon-reload"], [], true)
			return {"ok": true}
		var contents := linux_unit_contents(supervisor, runtime, cli, module, host, database, data_path, config_path, lock_path, log_path, manifest_path, module_sha256, "autostart")
		if contents.is_empty():
			return {"ok": false, "error": "Autostart paths contain unsupported newline or systemd-percent characters."}
		DirAccess.make_dir_recursive_absolute(unit_dir)
		var unit := FileAccess.open(unit_path, FileAccess.WRITE)
		if unit == null:
			return {"ok": false, "error": "Could not write the per-user systemd service."}
		unit.store_string(contents)
		unit.close()
		if OS.execute("systemctl", ["--user", "daemon-reload"], [], true) != 0:
			return {"ok": false, "error": "The user systemd service manager is unavailable."}
		var result := OS.execute("systemctl", ["--user", "enable", "continuum-native.service"], [], true)
		var observed := get_autostart(supervisor, data_path)
		return {"ok": result == 0 and observed.get("ok", false) and observed.get("enabled", false), "error": "Could not register and verify the per-user systemd service."}
	return {"ok": false, "error": "Managed native hosting is unsupported on Windows until its native supervisor and control path are validated."}

func get_autostart(_supervisor: String, _data_path: String) -> Dictionary:
	var unit_path := OS.get_environment("HOME").path_join(".config/systemd/user/continuum-native.service")
	if not FileAccess.file_exists(unit_path):
		return {"ok": true, "enabled": false}
	if not FileAccess.get_file_as_string(unit_path).begins_with("# Managed by Continuum\n"):
		return {"ok": false, "enabled": false, "error": "Native server autostart is managed outside this application."}
	var output: Array = []
	var code := OS.execute("systemctl", ["--user", "is-enabled", "continuum-native.service"], output, true)
	var value := str(output[0]).strip_edges() if not output.is_empty() else ""
	return {"ok": code == 0 or value == "disabled", "enabled": code == 0 and value == "enabled", "error": "Could not inspect native server autostart."}

func linux_unit_contents(supervisor: String, runtime: String, cli: String, module: String, host: String, database: String, data_path: String, config_path: String, lock_path: String, log_path: String, manifest_path: String, module_sha256: String, startup_nonce: String) -> String:
	var normalized_host := host.trim_prefix("http://")
	if normalized_host != "127.0.0.1:3001" or database.is_empty() or module_sha256 == "unavailable":
		return ""
	var values := [supervisor, runtime, cli, module, data_path, config_path, lock_path, log_path, manifest_path, database, module_sha256, startup_nonce]
	for value in values:
		if value.contains("\n") or value.contains("\r") or value.contains("%") or value.contains('"') or value.contains("\\"):
			return ""
	if not database.is_valid_identifier() or not module_sha256.is_valid_hex_number():
		return ""
	var command := [_systemd_quote(supervisor), "start", _systemd_quote(runtime), _systemd_quote(cli), _systemd_quote(module), normalized_host, _systemd_quote(database), _systemd_quote(data_path), _systemd_quote(config_path), _systemd_quote(lock_path), _systemd_quote(log_path), _systemd_quote(manifest_path), _systemd_quote(module_sha256), _systemd_quote(startup_nonce)]
	return "# Managed by Continuum\n[Unit]\nDescription=Continuum native SpacetimeDB\n\n[Service]\nExecStart=%s\nRestart=on-failure\nRestartSec=5\nKillSignal=SIGINT\nTimeoutStopSec=15\n\n[Install]\nWantedBy=default.target\n" % " ".join(command)

func _systemd_quote(value: String) -> String:
	return '"%s"' % value.replace("\\", "\\\\").replace('"', '\\"')

func windows_task_command(command: String, host: String, data_path: String) -> String:
	return '"%s" start --listen-addr %s --data-dir "%s" --jwt-key-dir "%s"' % [command, host.trim_prefix("http://"), data_path, data_path]

func _process_start_token(pid: int) -> String:
	return str(_process_snapshot(pid).get("started_at", ""))

func _process_snapshot(pid: int) -> Dictionary:
	if pid <= 1 or OS.get_name() != "Linux":
		return {}
	var file := FileAccess.open("/proc/%d/stat" % pid, FileAccess.READ)
	if file == null:
		return {}
	# procfs reports length zero; read the line instead of get_length() bytes.
	# comm can contain spaces and parentheses, so fields begin after its last ')'.
	var line := file.get_line()
	var end_comm := line.rfind(") ")
	if end_comm < 0:
		return {}
	var fields := line.substr(end_comm + 2).split(" ", false)
	if fields.size() < 20 or not fields[1].is_valid_int() or not fields[19].is_valid_int():
		return {}
	return {"state": fields[0], "parent_pid": fields[1].to_int(), "started_at": fields[19]}

func _process_command_contains(pid: int, needle: String) -> bool:
	if pid <= 1 or needle.is_empty():
		return false
	var output: Array = []
	return OS.execute("ps", ["-o", "args=", "-p", str(pid)], output, true) == 0 \
		and not output.is_empty() and str(output[0]).contains(needle)

func _process_parent_pid(pid: int) -> int:
	return int(_process_snapshot(pid).get("parent_pid", -1))

func _file_sha256(path: String) -> String:
	if not FileAccess.file_exists(path):
		return ""
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return ""
	var hashing := HashingContext.new()
	hashing.start(HashingContext.HASH_SHA256)
	hashing.update(file.get_buffer(file.get_length()))
	return hashing.finish().hex_encode()
