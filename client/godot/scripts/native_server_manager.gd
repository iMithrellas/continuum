## Shared contract for the managed native SpacetimeDB instance.
##
## One manager owns one physical server and one module database. Logical worlds
## must be represented inside that database; this class intentionally has no
## world argument and never starts a per-world process.
class_name ContinuumNativeServerManager extends RefCounted

signal status_changed(status: String)
signal progress(message: String)
signal ready(host: String, database: String)
signal failed(message: String)

const RUNTIME_VERSION := "2.10.0"
const DEFAULT_DATABASE := "continuum"
const DEFAULT_HOST := "http://127.0.0.1:3001"
const STOP_TIMEOUT_MS := 5000
const START_TIMEOUT_MS := 15000
const PROVISION_TIMEOUT_MS := 120000
const HEALTH_INTERVAL_MS := 1000

enum State { UNKNOWN, CHECKING, OFFLINE, STARTING, ONLINE, UNHEALTHY, STOPPING, STOP_TIMEOUT, UNSUPPORTED, CONFLICT, INSTALLING, PREPARING }

var host := DEFAULT_HOST
var database := DEFAULT_DATABASE
var executable := ""
var cli_executable := ""
var supervisor := ""
var provisioner := ""
var module_artifact := ""
var module_source_override := ""
var config_dir := ""
var data_dir := ""
var log_file := ""
var manifest_file := ""
var lock_file := ""
var platform_adapter: RefCounted

var _pid := -1
var _started_at := ""
var _launch_started_at := ""
var _runtime_pid := -1
var _runtime_started_at := ""
var _adopted_runtime := false
var _state := State.UNKNOWN
var _stop_deadline := 0
var _start_deadline := 0
var _startup_nonce := ""
var _startup_phase := ""
var _shutdown_manifest: Dictionary = {}
var _last_health_check := -1

func _init() -> void:
	platform_adapter = _default_adapter()
	var root := _native_root()
	executable = root.path_join("spacetimedb/%s/spacetimedb-standalone" % RUNTIME_VERSION)
	cli_executable = root.path_join("spacetimedb/%s/spacetimedb-cli" % RUNTIME_VERSION)
	supervisor = root.path_join("spacetimedb/%s/native-server-supervisor.sh" % RUNTIME_VERSION)
	provisioner = root.path_join("spacetimedb/%s/native-server-provisioner.sh" % RUNTIME_VERSION)
	data_dir = root.path_join("%s/data" % RUNTIME_VERSION)
	config_dir = root.path_join("%s/config" % RUNTIME_VERSION)
	log_file = root.path_join("%s/server.log" % RUNTIME_VERSION)
	manifest_file = root.path_join("%s/server.json" % RUNTIME_VERSION)
	lock_file = data_dir + ".lock"
	module_artifact = _native_root().path_join("modules/%s/continuum_module.wasm" % RUNTIME_VERSION)
	if OS.get_name() == "Windows":
		executable = platform_adapter.runtime_path(root.path_join("spacetimedb/%s" % RUNTIME_VERSION))
		cli_executable = platform_adapter.cli_path(root.path_join("spacetimedb/%s" % RUNTIME_VERSION))
		supervisor = root.path_join("helpers/windows-supervisor.ps1")
		platform_adapter.configure(supervisor, executable, cli_executable, data_dir, config_dir, manifest_file, lock_file)

func _native_root() -> String:
	var configured_root := OS.get_environment("CONTINUUM_NATIVE_ROOT")
	if not configured_root.is_empty():
		return configured_root
	if OS.get_name() == "Windows":
		return OS.get_environment("LOCALAPPDATA").path_join("Continuum/native")
	return (OS.get_environment("XDG_DATA_HOME") if not OS.get_environment("XDG_DATA_HOME").is_empty() else OS.get_environment("HOME").path_join(".local/share")).path_join("Continuum/native")

func _module_source() -> String:
	if not module_source_override.is_empty(): return module_source_override
	var configured := OS.get_environment("CONTINUUM_NATIVE_MODULE")
	if not configured.is_empty(): return configured
	var packaged := "res://native/continuum_module.wasm"
	if FileAccess.file_exists(packaged): return packaged
	return "" # A checkout builds current sources once; stale Cargo output is not a packaged module.

func state() -> String:
	return _state_name(_state)

func runtime_installed() -> bool:
	return FileAccess.file_exists(executable) and FileAccess.file_exists(cli_executable) and FileAccess.file_exists(supervisor)

## Reads durable ownership and health. Safe to call after the UI process restarts.
func status() -> String:
	if _state in [State.STARTING, State.STOPPING, State.STOP_TIMEOUT]:
		return state()
	var manifest := _read_manifest()
	if manifest.is_empty():
		_set_state(State.OFFLINE)
		return state()
	if not _identity_matches(manifest):
		_set_state(State.CONFLICT)
		return state()
	var manifest_pid := int(manifest.get("pid", -1))
	var runtime_pid := int(manifest.get("runtime_pid", -1))
	var supervisor_owned: bool = platform_adapter.is_process_identity(manifest_pid, str(manifest.get("started_at", "")), supervisor, str(manifest.get("supervisor_sha256", "")))
	var runtime_owned: bool = platform_adapter.is_process_identity(runtime_pid, str(manifest.get("runtime_started_at", "")), executable, str(manifest.get("runtime_sha256", "")), manifest_pid if supervisor_owned else -1)
	if not supervisor_owned and platform_adapter.process_exists(manifest_pid):
		_set_state(State.CONFLICT)
		return state()
	if supervisor_owned and not runtime_owned:
		_set_state(State.CONFLICT)
		return state()
	if supervisor_owned or runtime_owned:
		if not supervisor_owned and platform_adapter.has_method("supports_runtime_adoption") and not platform_adapter.supports_runtime_adoption():
			_set_state(State.CONFLICT)
			return state()
		_adopted_runtime = not supervisor_owned
		_pid = runtime_pid if _adopted_runtime else manifest_pid
		_started_at = str(manifest.get("runtime_started_at", "")) if _adopted_runtime else str(manifest.get("started_at", ""))
		_runtime_pid = runtime_pid
		_runtime_started_at = str(manifest.get("runtime_started_at", ""))
		if str(manifest.get("phase", "")) in ["stopping", "stop_timeout"]:
			_shutdown_manifest = manifest.duplicate(true)
			_stop_deadline = Time.get_ticks_msec() + STOP_TIMEOUT_MS
			_set_state(State.STOP_TIMEOUT if manifest.phase == "stop_timeout" else State.STOPPING)
			return state()
		if str(manifest.get("phase", "")) == "running" and _healthy():
			_set_state(State.ONLINE)
			_mark_manifest_running(manifest)
			return state()
		_set_state(State.STARTING if ["provisioning", "starting"].has(str(manifest.get("phase", ""))) else State.UNHEALTHY)
		return state()
	if platform_adapter.process_exists(manifest_pid) or platform_adapter.process_exists(runtime_pid):
		_set_state(State.CONFLICT)
		return state()
	if not _clear_stale_manifest(manifest):
		return state()
	_set_state(State.OFFLINE)
	return state()

## Starts one shared native server. Provisioning is a separate child process and
## is only requested when this database has not recorded the pinned module.
func start() -> bool:
	if not _supported():
		_fail(_unsupported_reason())
		_set_state(State.UNSUPPORTED)
		return false
	var current := "offline" if _state in [State.INSTALLING, State.PREPARING] else status()
	if ["online", "starting", "unhealthy", "stopping", "stop_timeout", "conflict"].has(current):
		return false
	_set_state(State.STARTING)
	if not _ensure_dirs():
		_fail("Cannot create native server data or log paths.")
		return false
	progress.emit("Starting the locked native supervisor (provisioning is first-use only)...")
	return _launch_server()

## Builds the checkout module once when no packaged artifact was supplied. Runtime
## installation is explicit and is chained by the controller before this step.
func prepare_module() -> bool:
	_set_state(State.PREPARING)
	progress.emit("Preparing the pinned native module...")
	if FileAccess.file_exists(module_artifact):
		_set_state(State.OFFLINE)
		return true
	var source := _module_source()
	if not source.is_empty() and FileAccess.file_exists(source):
		return _stage_module(source)
	if not OS.has_feature("editor"):
		_fail("This exported build has no packaged native module; use a source checkout or install a packaged build.")
		return false
	var cargo_manifest := ProjectSettings.globalize_path("res://../../backend/spacetimedb/Cargo.toml")
	if not FileAccess.file_exists(cargo_manifest):
		_fail("Native module is missing. Install the packaged module or use a source checkout with Cargo.")
		return false
	progress.emit("Building the native module once from the source checkout...")
	var output: Array = []
	var code: int
	if OS.get_name() == "Windows":
		code = platform_adapter.build_module(cargo_manifest, output)
	else:
		code = OS.execute("/usr/bin/timeout", ["300", "cargo", "build", "--manifest-path", cargo_manifest, "--release", "--target", "wasm32-unknown-unknown"], output, true)
	if code != 0:
		_fail("Could not build the native module. Install Cargo and the wasm32-unknown-unknown target.")
		return false
	var built_module := ProjectSettings.globalize_path("res://../../backend/spacetimedb/target/wasm32-unknown-unknown/release/continuum_module.wasm")
	if not FileAccess.file_exists(built_module):
		_fail("Cargo completed without producing continuum_module.wasm.")
		return false
	return _stage_module(built_module)

func _stage_module(source: String) -> bool:
	if DirAccess.make_dir_recursive_absolute(module_artifact.get_base_dir()) != OK:
		_fail("Could not create the native module destination; fix the destination and retry.")
		return false
	var temporary := module_artifact + ".tmp"
	var error := DirAccess.copy_absolute(source, temporary)
	if error == OK and _file_sha256(source) == _file_sha256(temporary):
		error = DirAccess.rename_absolute(temporary, module_artifact)
	else:
		error = ERR_FILE_CORRUPT if error == OK else error
	if error != OK:
		DirAccess.remove_absolute(temporary)
		_fail("Could not install the native module at %s (error %d); fix the destination and retry." % [module_artifact, error])
		return false
	_set_state(State.OFFLINE)
	return true

func install_native() -> bool:
	if not _supported():
		_fail(_unsupported_reason())
		return false
	_set_state(State.INSTALLING)
	progress.emit("Installing pinned SpacetimeDB %s..." % RUNTIME_VERSION)
	var extension := "ps1" if OS.get_name() == "Windows" else "sh"
	var script := ""
	if FileAccess.file_exists("res://native/install-spacetimedb." + extension):
		script = _stage_installer_assets(extension)
	elif OS.has_feature("editor"):
		script = ProjectSettings.globalize_path("res://../../scripts/native-hosting/install-spacetimedb." + extension)
	if not FileAccess.file_exists(script):
		_fail("The native runtime installer is missing from this build.")
		return false
	var output: Array = []
	var code: int
	if OS.get_name() == "Windows":
		code = platform_adapter.install_runtime(script, executable.get_base_dir(), supervisor.get_base_dir(), output)
	else:
		code = OS.execute("/usr/bin/timeout", ["330", "/bin/bash", script, executable.get_base_dir()], output, true)
	if code != 0:
		_fail("Native runtime installation failed. Check network access and the pinned checksum.")
		return false
	if not runtime_installed():
		_fail("Native runtime installation completed without the pinned runtime and CLI; fix the installation and retry.")
		return false
	_set_state(State.OFFLINE)
	return true

func _stage_installer_assets(extension: String) -> String:
	var destination := _native_root().path_join("bootstrap/" + RUNTIME_VERSION)
	if DirAccess.make_dir_recursive_absolute(destination) != OK:
		return ""
	var files := ["install-spacetimedb." + extension]
	if extension == "ps1":
		files.append_array(["windows-supervisor.ps1", "WindowsNativeProcessControl.cs"])
	else:
		files.append_array(["native-server-supervisor.sh", "native-server-provisioner.sh"])
	for filename: String in files:
		if DirAccess.copy_absolute("res://native/" + filename, destination.path_join(filename)) != OK:
			return ""
	return destination.path_join("install-spacetimedb." + extension)

func _launch_server() -> bool:
	_startup_nonce = "%s-%s" % [Time.get_ticks_usec(), randi()]
	var launched: Dictionary = platform_adapter.launch(supervisor, executable, cli_executable, module_artifact,
		host, database, data_dir, config_dir, lock_file, log_file, manifest_file, _file_sha256(module_artifact), _startup_nonce)
	if not launched.ok:
		_fail(str(launched.get("error", "Native server could not be started.")))
		_set_state(State.OFFLINE)
		return false
	_pid = int(launched.pid)
	_started_at = str(launched.started_at)
	_launch_started_at = _started_at
	_adopted_runtime = false
	_start_deadline = Time.get_ticks_msec() + PROVISION_TIMEOUT_MS
	progress.emit("Waiting for the native server health check...")
	return true

## Graceful stop only. Once the timeout state is reported, the caller must ask
## explicitly before calling stop(true).
func stop(force := false) -> bool:
	if force and _state != State.STOP_TIMEOUT:
		_fail("Force termination requires an explicit timeout state.")
		return false
	if _pid <= 1:
		status()
	var manifest := _read_manifest()
	if not _identity_matches(manifest):
		return false
	if force and (_shutdown_manifest.is_empty() or not _same_owner(manifest, _shutdown_manifest)):
		_fail("Native server ownership changed during shutdown.")
		return false
	var supervisor_pid := int(manifest.pid)
	var runtime_pid := int(manifest.runtime_pid)
	var supervisor_alive: bool = platform_adapter.is_process_identity(supervisor_pid, str(manifest.started_at), supervisor, str(manifest.supervisor_sha256))
	var runtime_alive: bool = platform_adapter.is_process_identity(runtime_pid, str(manifest.runtime_started_at), executable, str(manifest.runtime_sha256), supervisor_pid if supervisor_alive else -1)
	if (platform_adapter.process_exists(supervisor_pid) and not supervisor_alive) \
			or (platform_adapter.process_exists(runtime_pid) and not runtime_alive):
		_fail("Native server process identity could not be verified.")
		return false
	if force:
		# The runtime inherits the flock. Killing only its supervisor is not a
		# stopped server; request both exits and wait for both identities below.
		if runtime_alive and not platform_adapter.terminate(runtime_pid, true, str(manifest.runtime_started_at), executable, str(manifest.runtime_sha256), supervisor_pid if supervisor_alive else -1) \
				and platform_adapter.process_exists(runtime_pid):
			_fail("Native runtime force termination could not be requested.")
			return false
		if supervisor_alive and not platform_adapter.terminate(supervisor_pid, true, str(manifest.started_at), supervisor, str(manifest.supervisor_sha256)) \
				and platform_adapter.process_exists(supervisor_pid):
			_fail("Native supervisor force termination could not be requested.")
			return false
	else:
		# Freeze the validated owner before requesting shutdown. The supervisor hash
		# must remain available even when this manager owns the supervisor directly.
		_shutdown_manifest = manifest.duplicate(true)
		if _pid <= 1 or _started_at.is_empty() \
				or not platform_adapter.terminate(_pid, false, _started_at, _active_binary(), _active_binary_hash()):
			_fail("Native server rejected graceful shutdown.")
			return false
	_stop_deadline = Time.get_ticks_msec() + STOP_TIMEOUT_MS
	_set_state(State.STOPPING)
	return true

## Called by the integration node while starting/stopping. It never escalates.
func tick() -> void:
	if _state in [State.STOPPING, State.STOP_TIMEOUT]:
		_tick_shutdown()
		return
	var manifest := _read_manifest()
	var phase := str(manifest.get("phase", ""))
	if phase != _startup_phase:
		_startup_phase = phase
		if phase == "provisioning":
			_start_deadline = Time.get_ticks_msec() + PROVISION_TIMEOUT_MS
		elif phase == "starting":
			_start_deadline = Time.get_ticks_msec() + START_TIMEOUT_MS
	if _state == State.STARTING and (manifest.is_empty() or not manifest.has("pid")):
		if not platform_adapter.process_exists(_pid):
			_set_state(State.OFFLINE)
			_fail("Native server exited before publishing its ownership manifest.")
		elif Time.get_ticks_msec() >= _start_deadline:
			_set_state(State.CONFLICT)
			_fail("Native server startup timed out without verified ownership metadata.")
		return
	if _state == State.STARTING and phase in ["stopping", "stop_timeout"]:
		if not _identity_matches(manifest):
			_set_state(State.CONFLICT)
			return
		_shutdown_manifest = manifest.duplicate(true)
		_stop_deadline = Time.get_ticks_msec() + STOP_TIMEOUT_MS
		_set_state(State.STOP_TIMEOUT if phase == "stop_timeout" else State.STOPPING)
		_fail("Native server setup stopped before completion; shutdown is in progress.")
		return
	if _state == State.STARTING and int(manifest.get("pid", -1)) == _pid \
			and str(manifest.get("startup_nonce", "")) == _startup_nonce \
			and _started_at == _launch_started_at \
			and not str(manifest.get("started_at", "")).is_empty():
		_started_at = str(manifest.get("started_at", ""))
		_runtime_pid = int(manifest.get("runtime_pid", -1))
		_runtime_started_at = str(manifest.get("runtime_started_at", ""))
	if _state == State.STARTING and not _adopted_runtime and not _launch_started_at.is_empty() \
			and _started_at != _launch_started_at and int(manifest.get("pid", -1)) == _pid:
		_set_state(State.CONFLICT)
		_fail("Native server supervisor identity changed during startup.")
		return
	var supervisor_owned: bool = platform_adapter.is_process_identity(int(manifest.get("pid", -1)), str(manifest.get("started_at", "")), supervisor, str(manifest.get("supervisor_sha256", "")))
	var runtime_owned: bool = platform_adapter.is_process_identity(int(manifest.get("runtime_pid", -1)), str(manifest.get("runtime_started_at", "")), executable, str(manifest.get("runtime_sha256", "")), int(manifest.get("pid", -1)) if supervisor_owned else -1)
	if _state == State.STARTING and not supervisor_owned:
		if runtime_owned and phase == "running":
			if platform_adapter.has_method("supports_runtime_adoption") and not platform_adapter.supports_runtime_adoption():
				_set_state(State.CONFLICT)
				_fail("Native supervisor exited; waiting for its owned runtime to close.")
				return
			_adopted_runtime = true
			_pid = int(manifest.get("runtime_pid", -1))
			_started_at = str(manifest.get("runtime_started_at", ""))
			if _healthy():
				_set_state(State.ONLINE)
				ready.emit(host, database)
		elif not platform_adapter.process_exists(int(manifest.get("pid", -1))) and not platform_adapter.process_exists(int(manifest.get("runtime_pid", -1))):
			_clear_runtime_manifest()
			_set_state(State.OFFLINE)
			_fail("Native server exited before its health check completed.")
		elif Time.get_ticks_msec() >= _start_deadline:
			_set_state(State.CONFLICT)
			_fail("Native server identity could not be validated before startup timed out.")
	elif _state == State.STARTING and phase == "running" and _health_due() and _healthy():
		_set_state(State.ONLINE)
		_mark_manifest_running(manifest)
		ready.emit(host, database)
	elif _state == State.STARTING and phase == "starting" and Time.get_ticks_msec() >= _start_deadline:
		_set_state(State.UNHEALTHY)
		_fail("Native server is owned but did not become healthy before the startup deadline.")
	elif _state == State.STARTING and phase == "provisioning" and Time.get_ticks_msec() >= _start_deadline:
		_set_state(State.UNHEALTHY)
		_fail("Native module provisioning exceeded its bounded startup budget.")

func _tick_shutdown() -> void:
	if _shutdown_manifest.is_empty():
		_set_state(State.CONFLICT)
		return
	var supervisor_pid := int(_shutdown_manifest.pid)
	var runtime_pid := int(_shutdown_manifest.runtime_pid)
	var supervisor_alive: bool = platform_adapter.process_exists(supervisor_pid)
	var runtime_alive: bool = platform_adapter.process_exists(runtime_pid)
	if (supervisor_alive and not platform_adapter.is_process_identity(supervisor_pid, str(_shutdown_manifest.started_at), supervisor, str(_shutdown_manifest.supervisor_sha256))) \
			or (runtime_alive and not platform_adapter.is_process_identity(runtime_pid, str(_shutdown_manifest.runtime_started_at), executable, str(_shutdown_manifest.runtime_sha256), supervisor_pid if supervisor_alive else -1)):
		_set_state(State.CONFLICT)
		_fail("Native server identity changed during shutdown.")
	elif not supervisor_alive and not runtime_alive:
		if _clear_runtime_manifest(_shutdown_manifest):
			_shutdown_manifest.clear()
			_set_state(State.OFFLINE)
		else:
			var current := _read_manifest()
			if (not current.is_empty() and not _same_owner(current, _shutdown_manifest)) or Time.get_ticks_msec() >= _stop_deadline:
				_set_state(State.CONFLICT)
				_fail("Native server ownership could not be released safely.")
	elif Time.get_ticks_msec() >= _stop_deadline:
		_set_state(State.STOP_TIMEOUT)

func set_autostart(enabled: bool) -> Dictionary:
	if not _supported():
		return {"ok": false, "error": _unsupported_reason()}
	if enabled and not _ensure_dirs():
		return {"ok": false, "error": "Could not prepare native server data directories for login startup."}
	return platform_adapter.set_autostart(enabled, supervisor, executable, cli_executable, module_artifact,
		host, database, data_dir, config_dir, lock_file, log_file, manifest_file, _file_sha256(module_artifact), "autostart")

func get_autostart() -> Dictionary:
	if not _supported():
		return {"ok": false, "enabled": false, "error": _unsupported_reason()}
	return platform_adapter.get_autostart(supervisor, data_dir)

func can_stop() -> bool:
	if _pid <= 1 or _started_at.is_empty():
		status()
	return _pid > 1 and not _started_at.is_empty() and platform_adapter.is_process_identity(_pid, _started_at, _active_binary(), _active_binary_hash(), -1)

func _supported() -> bool:
	if platform_adapter != null and platform_adapter.has_method("supports_native_hosting"):
		return platform_adapter.supports_native_hosting()
	return OS.get_name() == "Linux" and ["x86_64", "AMD64"].has(OS.get_processor_name()) and _linux_distribution_supported()

func _unsupported_reason() -> String:
	return "Managed native hosting requires Linux x86_64 or Windows x86_64 and the pinned runtime. Dedicated servers can use Docker or a manual service."

func _healthy() -> bool:
	_last_health_check = Time.get_ticks_msec()
	return platform_adapter.health(host)

func _health_due() -> bool:
	return _last_health_check < 0 or Time.get_ticks_msec() - _last_health_check >= HEALTH_INTERVAL_MS

func _module_identity() -> String:
	return _file_sha256(module_artifact)

func _file_sha256(path: String) -> String:
	if path.is_empty() or not FileAccess.file_exists(path):
		return "unavailable"
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return "unavailable"
	var hashing := HashingContext.new()
	hashing.start(HashingContext.HASH_SHA256)
	hashing.update(file.get_buffer(file.get_length()))
	return hashing.finish().hex_encode()

func _identity_matches(manifest: Dictionary) -> bool:
	for field in ["runtime", "runtime_sha256", "cli_sha256", "supervisor_sha256", "module_sha256", "database", "pid", "runtime_pid", "started_at", "runtime_started_at", "runtime_parent_pid", "runtime_binary", "startup_nonce", "data_dir", "host"]:
		if not manifest.has(field):
			return false
	return str(manifest.get("runtime", "")) == RUNTIME_VERSION and str(manifest.get("runtime_sha256", "")) == _file_sha256(executable) \
		and str(manifest.get("cli_sha256", "")) == _file_sha256(cli_executable) and str(manifest.get("supervisor_sha256", "")) == _file_sha256(supervisor) \
		and str(manifest.get("module_sha256", "")) == _file_sha256(module_artifact) \
		and str(manifest.get("database", "")) == database and str(manifest.get("runtime_binary", "")) == executable \
		and _data_path_matches(str(manifest.get("data_dir", ""))) and str(manifest.get("host", "")) == host \
		and int(manifest.get("pid", -1)) > 1 and int(manifest.get("runtime_pid", -1)) > 1 \
		and int(manifest.get("runtime_parent_pid", -1)) == int(manifest.get("pid", -1)) \
		and not str(manifest.get("startup_nonce", "")).is_empty()

func _data_path_matches(actual: String) -> bool:
	if platform_adapter.has_method("same_data_path"):
		return platform_adapter.same_data_path(actual, data_dir)
	return actual == data_dir

func _ensure_dirs() -> bool:
	return (DirAccess.make_dir_recursive_absolute(data_dir) == OK or DirAccess.dir_exists_absolute(data_dir)) \
		and DirAccess.make_dir_recursive_absolute(config_dir) == OK

func _read_manifest() -> Dictionary:
	if not FileAccess.file_exists(manifest_file):
		return {}
	var parsed = JSON.parse_string(FileAccess.get_file_as_string(manifest_file))
	return parsed if parsed is Dictionary else {}

func _same_owner(left: Dictionary, right: Dictionary) -> bool:
	for field in ["pid", "started_at", "runtime_pid", "runtime_started_at", "startup_nonce", "data_dir"]:
		if not left.has(field) or left[field] != right.get(field):
			return false
	return true

func _clear_runtime_manifest(expected_owner: Dictionary = {}) -> bool:
	# Hash the same snapshot whose owner we validated. The helper compares this
	# digest after acquiring the flock, so a replacement manifest is never erased.
	var exists := FileAccess.file_exists(manifest_file)
	var contents := FileAccess.get_file_as_string(manifest_file) if exists else ""
	var parsed = JSON.parse_string(contents) if not contents.is_empty() else null
	if exists and not parsed is Dictionary:
		return false
	var manifest: Dictionary = parsed if parsed is Dictionary else expected_owner
	if not _identity_matches(manifest) or (not _startup_nonce.is_empty() and str(manifest.get("startup_nonce", "")) != _startup_nonce):
		return false
	if not expected_owner.is_empty() and not _same_owner(manifest, expected_owner):
		return false
	if platform_adapter.process_exists(int(manifest.get("pid", -1))) or platform_adapter.process_exists(int(manifest.get("runtime_pid", -1))):
		return false
	if not platform_adapter.cleanup_stale(supervisor, lock_file, manifest_file, contents.sha256_text() if not contents.is_empty() else "0".repeat(64)):
		return false
	_pid = -1
	_started_at = ""
	_launch_started_at = ""
	_runtime_pid = -1
	_runtime_started_at = ""
	_adopted_runtime = false
	_startup_nonce = ""
	return true

func _clear_stale_manifest(manifest: Dictionary) -> bool:
	if not _identity_matches(manifest):
		_set_state(State.CONFLICT)
		return false
	var snapshot_hash := _manifest_sha256()
	if snapshot_hash.is_empty() or not platform_adapter.cleanup_stale(supervisor, lock_file, manifest_file, snapshot_hash):
		_set_state(State.CONFLICT)
		return false
	return true

func _manifest_sha256() -> String:
	return _file_sha256(manifest_file)

func _active_binary() -> String:
	return executable if _adopted_runtime else supervisor

func _active_binary_hash() -> String:
	return str(_read_manifest().get("runtime_sha256", "")) if _adopted_runtime else str(_shutdown_manifest.get("supervisor_sha256", _read_manifest().get("supervisor_sha256", "")))

func _mark_manifest_running(manifest: Dictionary) -> void:
	if str(manifest.get("phase", "")) == "running":
		return
	if not manifest.has("pid") or int(manifest.get("pid", -1)) != _pid:
		return
	manifest["phase"] = "running"
	var temporary := manifest_file + ".tmp.%s" % str(_pid)
	var file := FileAccess.open(temporary, FileAccess.WRITE)
	if file == null:
		return
	file.store_string(JSON.stringify(manifest))
	file.close()
	DirAccess.rename_absolute(temporary, manifest_file)

func _linux_distribution_supported() -> bool:
	var output: Array = []
	if OS.execute("uname", ["-m"], output, true) != 0 or output.is_empty():
		return false
	return OS.get_name() == "Linux" and ["x86_64", "amd64"].has(str(output[0]).strip_edges().to_lower())

func _fail(message: String) -> void:
	if _state in [State.INSTALLING, State.PREPARING]:
		_set_state(State.OFFLINE)
	failed.emit(message)

func _set_state(value: int) -> void:
	if _state != value:
		_state = value
		status_changed.emit(_state_name(value))

func _state_name(value: int) -> String:
	return ["unknown", "checking", "offline", "starting", "online", "unhealthy", "stopping", "stop_timeout", "unsupported", "conflict", "installing", "preparing"][value]

func _default_adapter() -> RefCounted:
	var windows_adapter := "res://scripts/native_server_windows_adapter.gd"
	if OS.get_name() == "Windows" and FileAccess.file_exists(windows_adapter):
		return load(windows_adapter).new()
	return load("res://scripts/native_server_platform_adapter.gd").new()
