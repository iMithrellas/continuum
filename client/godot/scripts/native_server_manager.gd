## One manager owns one independent native server and one module database.
## Profiles have isolated ports/data; logical worlds still share their server.
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

enum State {
	UNKNOWN,
	CHECKING,
	OFFLINE,
	STARTING,
	ONLINE,
	UNHEALTHY,
	STOPPING,
	STOP_TIMEOUT,
	UNSUPPORTED,
	CONFLICT,
	INSTALLING,
	PREPARING,
	DELETING,
	DELETED
}

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
var instance_id := "default"
var _root := ""
var _instance_dir := ""

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
	_root = root.simplify_path()
	_instance_dir = _root.path_join(RUNTIME_VERSION)
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
		executable = platform_adapter.runtime_path(
			root.path_join("spacetimedb/%s" % RUNTIME_VERSION)
		)
		cli_executable = platform_adapter.cli_path(
			root.path_join("spacetimedb/%s" % RUNTIME_VERSION)
		)
		supervisor = root.path_join("helpers/windows-supervisor.ps1")
		platform_adapter.configure(
			supervisor, executable, cli_executable, data_dir, config_dir, manifest_file, lock_file
		)
	_adopt_updated_module()


static func native_root() -> String:
	var configured_root := OS.get_environment("CONTINUUM_NATIVE_ROOT")
	if not configured_root.is_empty():
		return configured_root
	if OS.get_name() == "Windows":
		return OS.get_environment("LOCALAPPDATA").path_join("Continuum/native")
	return (
		(
			OS.get_environment("XDG_DATA_HOME")
			if not OS.get_environment("XDG_DATA_HOME").is_empty()
			else OS.get_environment("HOME").path_join(".local/share")
		)
		. path_join("Continuum/native")
	)


func _native_root() -> String:
	return native_root()


static func valid_instance_id(value: String) -> bool:
	if value == "default":
		return true
	return (
		value.begins_with("server-")
		and value.length() == 31
		and value.trim_prefix("server-").is_valid_hex_number()
		and value == value.to_lower()
	)


func configure_instance(id: String, port: int) -> bool:
	if (
		_state != State.UNKNOWN
		or not valid_instance_id(id)
		or port < 1024
		or port > 65535
		or (id == "default" and port != 3001)
	):
		return false
	instance_id = id
	host = "http://127.0.0.1:%d" % port
	_instance_dir = _root.path_join(RUNTIME_VERSION if id == "default" else "servers/" + id)
	data_dir = _instance_dir.path_join("data")
	config_dir = _instance_dir.path_join("config")
	log_file = _instance_dir.path_join("server.log")
	manifest_file = _instance_dir.path_join("server.json")
	lock_file = data_dir + ".lock"
	module_artifact = _root.path_join("modules/%s/continuum_module.wasm" % RUNTIME_VERSION)
	if id != "default":
		supervisor = _control_assets_dir().path_join(
			(
				"windows-supervisor.ps1"
				if OS.get_name() == "Windows"
				else "native-server-supervisor.sh"
			)
		)
	_adopt_updated_module()
	if OS.get_name() == "Windows":
		platform_adapter.configure(
			supervisor, executable, cli_executable, data_dir, config_dir, manifest_file, lock_file
		)
	return true


## New profiles use a separate helper path so an old running server's executable
## identity is never changed while adding a server to an existing installation.
func prepare_control_helper() -> bool:
	if module_artifact == _profile_module_path():
		return not _stage_control_helper(_update_assets_dir()).is_empty()
	return instance_id == "default" or not _stage_control_helper().is_empty()


func _control_assets_dir() -> String:
	return _root.path_join("bootstrap/%s/multi-server-v1" % RUNTIME_VERSION)


func _profile_module_path() -> String:
	return _instance_dir.path_join("continuum_module.wasm")


func _update_assets_dir() -> String:
	return _root.path_join("bootstrap/%s/module-updates-v1" % RUNTIME_VERSION)


func _adopt_updated_module() -> void:
	if not _has_instance_paths() or not FileAccess.file_exists(_profile_module_path()):
		return
	module_artifact = _profile_module_path()
	supervisor = _update_assets_dir().path_join(
		"windows-supervisor.ps1" if OS.get_name() == "Windows" else "native-server-supervisor.sh"
	)
	if OS.get_name() == "Windows":
		platform_adapter.configure(
			supervisor, executable, cli_executable, data_dir, config_dir, manifest_file, lock_file
		)


func _stage_control_helper(directory := "") -> String:
	if directory.is_empty():
		directory = _control_assets_dir()
	var filename := (
		"windows-supervisor.ps1" if OS.get_name() == "Windows" else "native-server-supervisor.sh"
	)
	var files := [filename]
	if OS.get_name() == "Windows":
		files.append("WindowsNativeProcessControl.cs")
	if DirAccess.make_dir_recursive_absolute(directory) != OK:
		return ""
	for asset: String in files:
		var destination := directory.path_join(asset)
		if FileAccess.file_exists(destination):
			continue
		var source := "res://native/" + asset
		if OS.has_feature("editor"):
			var checkout_source := ProjectSettings.globalize_path(
				"res://../../scripts/native-hosting/" + asset
			)
			if FileAccess.file_exists(checkout_source):
				source = checkout_source
		var temporary := destination + ".tmp.%d-%d" % [OS.get_process_id(), get_instance_id()]
		if (
			DirAccess.copy_absolute(source, temporary, 493 if asset.ends_with(".sh") else -1) != OK
			or DirAccess.rename_absolute(temporary, destination) != OK
		):
			DirAccess.remove_absolute(temporary)
			return ""
	return directory.path_join(filename)


func _module_source() -> String:
	if not module_source_override.is_empty():
		return module_source_override
	var configured := OS.get_environment("CONTINUUM_NATIVE_MODULE")
	if not configured.is_empty():
		return configured
	var packaged := "res://native/continuum_module.wasm"
	if FileAccess.file_exists(packaged):
		return packaged
	return ""


func state() -> String:
	return _state_name(_state)


func runtime_installed() -> bool:
	return (
		FileAccess.file_exists(executable)
		and FileAccess.file_exists(cli_executable)
		and FileAccess.file_exists(supervisor)
	)


## Reads durable ownership and health. Safe to call after the UI process restarts.
func status() -> String:
	if (
		_state
		in [State.STARTING, State.STOPPING, State.STOP_TIMEOUT, State.DELETING, State.DELETED]
	):
		return state()
	if FileAccess.file_exists(_instance_dir.path_join(".continuum-deleted")):
		_set_state(State.DELETED)
		return state()
	var manifest := _read_manifest()
	if manifest.is_empty():
		if not FileAccess.file_exists(manifest_file):
			_adopt_updated_module()
		_set_state(State.CONFLICT if FileAccess.file_exists(manifest_file) else State.OFFLINE)
		return state()
	if not _identity_matches(manifest):
		_set_state(State.CONFLICT)
		return state()
	var manifest_pid := int(manifest.get("pid", -1))
	var runtime_pid := int(manifest.get("runtime_pid", -1))
	var supervisor_owned: bool = platform_adapter.is_process_identity(
		manifest_pid,
		str(manifest.get("started_at", "")),
		supervisor,
		str(manifest.get("supervisor_sha256", ""))
	)
	var runtime_owned: bool = platform_adapter.is_process_identity(
		runtime_pid,
		str(manifest.get("runtime_started_at", "")),
		executable,
		str(manifest.get("runtime_sha256", "")),
		manifest_pid if supervisor_owned else -1
	)
	if not supervisor_owned and platform_adapter.process_exists(manifest_pid):
		_set_state(State.CONFLICT)
		return state()
	if supervisor_owned and not runtime_owned:
		_set_state(State.CONFLICT)
		return state()
	if supervisor_owned or runtime_owned:
		if (
			not supervisor_owned
			and platform_adapter.has_method("supports_runtime_adoption")
			and not platform_adapter.supports_runtime_adoption()
		):
			_set_state(State.CONFLICT)
			return state()
		_adopted_runtime = not supervisor_owned
		_pid = runtime_pid if _adopted_runtime else manifest_pid
		_started_at = (
			str(manifest.get("runtime_started_at", ""))
			if _adopted_runtime
			else str(manifest.get("started_at", ""))
		)
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
		_set_state(
			(
				State.STARTING
				if ["provisioning", "starting"].has(str(manifest.get("phase", "")))
				else State.UNHEALTHY
			)
		)
		return state()
	if (
		platform_adapter.process_exists(manifest_pid)
		or platform_adapter.process_exists(runtime_pid)
	):
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
	if current != "offline":
		return false
	_set_state(State.STARTING)
	if not _ensure_dirs():
		_fail("Cannot create native server data or log paths.")
		return false
	progress.emit("Starting the locked native supervisor (provisioning is first-use only)...")
	return _launch_server()


## Destruction is explicit, offline-only, and performed under the same OS lock as
## launch. Keep the lock inode/tombstone so stale clients cannot resurrect data.
func delete_data() -> Dictionary:
	if not _has_instance_paths():
		return {
			"ok": false, "error": "Refusing to delete data outside this managed server's directory."
		}
	if status() not in ["offline", "deleted"] or FileAccess.file_exists(manifest_file):
		return {
			"ok": false,
			"error": "Stop this server and resolve any ownership conflict before deleting it."
		}
	var autostart := set_autostart(false)
	if not autostart.get("ok", false):
		return autostart
	var helper := _stage_control_helper(
		_update_assets_dir() if module_artifact == _profile_module_path() else ""
	)
	if helper.is_empty() or not _ensure_dirs():
		return {"ok": false, "error": "Could not prepare the safe server deletion helper."}
	_set_state(State.DELETING)
	var result: Dictionary = platform_adapter.delete_server(
		helper, lock_file, manifest_file, _instance_dir
	)
	_set_state(State.DELETED if result.get("ok", false) else State.OFFLINE)
	return result


func _has_instance_paths() -> bool:
	var expected := _root.path_join(
		RUNTIME_VERSION if instance_id == "default" else "servers/" + instance_id
	)
	return (
		valid_instance_id(instance_id)
		and _root.is_absolute_path()
		and _instance_dir == expected
		and data_dir == expected.path_join("data")
		and config_dir == expected.path_join("config")
		and manifest_file == expected.path_join("server.json")
		and log_file == expected.path_join("server.log")
		and lock_file == data_dir + ".lock"
	)


## Explicit stopped-server update. Never replaces the shared artifact or the
## deployed digest pin. The locked supervisor publishes with delete-data=never
## on the next start, and records the new pin only after successful publication.
func update_module() -> Dictionary:
	if not _supported() or not _has_instance_paths():
		return {
			"ok": false,
			"error":
			"Cannot update this managed server's module on this platform or outside its directory."
		}
	if status() != "offline" or FileAccess.file_exists(manifest_file):
		return {
			"ok": false,
			"error":
			"Stop this server and resolve any ownership conflict before updating its module."
		}
	_set_state(State.PREPARING)
	progress.emit(
		"Preparing the current module for this server; existing colony data will be preserved..."
	)
	var source := _current_module_source(true)
	var helper := _stage_control_helper(_update_assets_dir())
	if source.is_empty() or helper.is_empty() or not _ensure_dirs():
		_set_state(State.OFFLINE)
		return {
			"ok": false,
			"error":
			"Could not prepare the current module or its update helper. Check the build and directory permissions, then retry."
		}
	var candidate := _update_assets_dir().path_join(
		"module-candidate-%d-%d.wasm" % [OS.get_process_id(), get_instance_id()]
	)
	if not _copy_module(source, candidate):
		return {
			"ok": false,
			"error": "Could not stage the module update; the existing module was not changed."
		}
	var registration := get_autostart()
	var result := set_autostart(false) if registration.get("ok", false) else registration
	if result.get("ok", false):
		result = platform_adapter.install_module(
			helper, lock_file, manifest_file, _instance_dir, candidate, _file_sha256(candidate)
		)
		if result.get("ok", false):
			_adopt_updated_module()
		if registration.get("enabled", false):
			var restored := set_autostart(true)
			if not restored.get("ok", false):
				var outcome := (
					"Module prepared, but "
					if result.get("ok", false)
					else str(result.get("error", "Module update failed.")) + " Also, "
				)
				result = {
					"ok": false,
					"error":
					(
						outcome
						+ "login startup could not be restored. Check Start at login before relying on it. "
						+ str(restored.get("error", ""))
					)
				}
	DirAccess.remove_absolute(candidate)
	_set_state(State.OFFLINE)
	return result


## First use snapshots the current module for this profile, never a stale shared
## cache. Published profiles retain their pin until an explicit update request.
func prepare_module() -> bool:
	if (
		_has_instance_paths()
		and not FileAccess.file_exists(data_dir.path_join(".continuum-module.sha256"))
	):
		var result := update_module()
		if not result.get("ok", false):
			_fail(str(result.get("error", "Could not prepare this server's module.")))
		return bool(result.get("ok", false))
	_set_state(State.PREPARING)
	progress.emit("Preparing the pinned native module...")
	if FileAccess.file_exists(module_artifact):
		_set_state(State.OFFLINE)
		return true
	var source := _current_module_source()
	return not source.is_empty() and _stage_module(source)


func _current_module_source(refresh := false) -> String:
	var source := _module_source()
	var cargo_manifest := ProjectSettings.globalize_path(
		"res://../../backend/spacetimedb/Cargo.toml"
	)
	if (
		refresh
		and OS.has_feature("editor")
		and FileAccess.file_exists(cargo_manifest)
		and module_source_override.is_empty()
		and OS.get_environment("CONTINUUM_NATIVE_MODULE").is_empty()
	):
		source = ""  # An old export asset is not the current source checkout.
	if not source.is_empty() and FileAccess.file_exists(source):
		return source
	if not OS.has_feature("editor"):
		_fail(
			"This exported build has no packaged native module; use a source checkout or install a packaged build."
		)
		return ""
	if not FileAccess.file_exists(cargo_manifest):
		_fail(
			"Native module is missing. Install the packaged module or use a source checkout with Cargo."
		)
		return ""
	progress.emit("Building the current native module from the source checkout...")
	var output: Array = []
	var code: int
	if OS.get_name() == "Windows":
		code = platform_adapter.build_module(cargo_manifest, output)
	else:
		code = OS.execute(
			"/usr/bin/timeout",
			[
				"300",
				"cargo",
				"build",
				"--manifest-path",
				cargo_manifest,
				"--release",
				"--target",
				"wasm32-unknown-unknown"
			],
			output,
			true
		)
	if code != 0:
		_fail(
			"Could not build the native module. Install Cargo and the wasm32-unknown-unknown target."
		)
		return ""
	var built_module := (
		ProjectSettings
		. globalize_path(
			"res://../../backend/spacetimedb/target/wasm32-unknown-unknown/release/continuum_module.wasm"
		)
	)
	if not FileAccess.file_exists(built_module):
		_fail("Cargo completed without producing continuum_module.wasm.")
		return ""
	return built_module


func _stage_module(source: String) -> bool:
	if not _copy_module(source, module_artifact):
		return false
	_set_state(State.OFFLINE)
	return true


func _copy_module(source: String, destination: String) -> bool:
	if DirAccess.make_dir_recursive_absolute(destination.get_base_dir()) != OK:
		_fail("Could not create the native module destination; fix the destination and retry.")
		return false
	var temporary := destination + ".tmp"
	var error := DirAccess.copy_absolute(source, temporary)
	if error == OK and _file_sha256(source) == _file_sha256(temporary):
		error = DirAccess.rename_absolute(temporary, destination)
	else:
		error = ERR_FILE_CORRUPT if error == OK else error
	if error != OK:
		DirAccess.remove_absolute(temporary)
		_fail(
			(
				"Could not install the native module at %s (error %d); fix the destination and retry."
				% [destination, error]
			)
		)
		return false
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
		script = ProjectSettings.globalize_path(
			"res://../../scripts/native-hosting/install-spacetimedb." + extension
		)
	if not FileAccess.file_exists(script):
		_fail("The native runtime installer is missing from this build.")
		return false
	var output: Array = []
	var code: int
	if OS.get_name() == "Windows":
		code = platform_adapter.install_runtime(
			script, executable.get_base_dir(), supervisor.get_base_dir(), output
		)
	else:
		code = OS.execute(
			"/usr/bin/timeout",
			["330", "/bin/bash", script, executable.get_base_dir()],
			output,
			true
		)
	if code != 0:
		_fail("Native runtime installation failed. Check network access and the pinned checksum.")
		return false
	if not runtime_installed():
		_fail(
			"Native runtime installation completed without the pinned runtime and CLI; fix the installation and retry."
		)
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
		if (
			DirAccess.copy_absolute("res://native/" + filename, destination.path_join(filename))
			!= OK
		):
			return ""
	return destination.path_join("install-spacetimedb." + extension)


func _launch_server() -> bool:
	_startup_nonce = "%s-%s" % [Time.get_ticks_usec(), randi()]
	var launched: Dictionary = platform_adapter.launch(
		supervisor,
		executable,
		cli_executable,
		module_artifact,
		host,
		database,
		data_dir,
		config_dir,
		lock_file,
		log_file,
		manifest_file,
		_file_sha256(module_artifact),
		_startup_nonce
	)
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
		_fail(
			"Native ownership does not match this server's configuration. Refresh its status before stopping it."
		)
		return false
	if force and (_shutdown_manifest.is_empty() or not _same_owner(manifest, _shutdown_manifest)):
		_fail("Native server ownership changed during shutdown.")
		return false
	var supervisor_pid := int(manifest.pid)
	var runtime_pid := int(manifest.runtime_pid)
	var supervisor_alive: bool = platform_adapter.is_process_identity(
		supervisor_pid, str(manifest.started_at), supervisor, str(manifest.supervisor_sha256)
	)
	var runtime_alive: bool = platform_adapter.is_process_identity(
		runtime_pid,
		str(manifest.runtime_started_at),
		executable,
		str(manifest.runtime_sha256),
		supervisor_pid if supervisor_alive else -1
	)
	if (
		(platform_adapter.process_exists(supervisor_pid) and not supervisor_alive)
		or (platform_adapter.process_exists(runtime_pid) and not runtime_alive)
	):
		_fail("Native server process identity could not be verified.")
		return false
	if force:
		# The runtime inherits flock, so stopping only the supervisor cannot release it.
		if (
			runtime_alive
			and not platform_adapter.terminate(
				runtime_pid,
				true,
				str(manifest.runtime_started_at),
				executable,
				str(manifest.runtime_sha256),
				supervisor_pid if supervisor_alive else -1
			)
			and platform_adapter.process_exists(runtime_pid)
		):
			_fail("Native runtime force termination could not be requested.")
			return false
		if (
			supervisor_alive
			and not platform_adapter.terminate(
				supervisor_pid,
				true,
				str(manifest.started_at),
				supervisor,
				str(manifest.supervisor_sha256)
			)
			and platform_adapter.process_exists(supervisor_pid)
		):
			_fail("Native supervisor force termination could not be requested.")
			return false
	else:
		# A stop targets the freshly verified manifest, not cached PID/hash fields
		# left by an earlier runtime or module helper. Force still requires the
		# exact shutdown snapshot captured by the initial graceful request.
		if not supervisor_alive and not runtime_alive:
			_fail("The owned native server processes have already exited. Refresh its status.")
			return false
		if (
			not supervisor_alive
			and platform_adapter.has_method("supports_runtime_adoption")
			and not platform_adapter.supports_runtime_adoption()
		):
			_fail("The native supervisor has exited; waiting for its runtime to close.")
			return false
		_adopted_runtime = not supervisor_alive
		_pid = runtime_pid if _adopted_runtime else supervisor_pid
		_started_at = (
			str(manifest.runtime_started_at) if _adopted_runtime else str(manifest.started_at)
		)
		_runtime_pid = runtime_pid
		_runtime_started_at = str(manifest.runtime_started_at)
		_shutdown_manifest = manifest.duplicate(true)
		if not platform_adapter.terminate(
			_pid, false, _started_at, _active_binary(), _active_binary_hash()
		):
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
	if (
		_state == State.STARTING
		and int(manifest.get("pid", -1)) == _pid
		and str(manifest.get("startup_nonce", "")) == _startup_nonce
		and _started_at == _launch_started_at
		and not str(manifest.get("started_at", "")).is_empty()
	):
		_started_at = str(manifest.get("started_at", ""))
		_runtime_pid = int(manifest.get("runtime_pid", -1))
		_runtime_started_at = str(manifest.get("runtime_started_at", ""))
	if (
		_state == State.STARTING
		and not _adopted_runtime
		and not _launch_started_at.is_empty()
		and _started_at != _launch_started_at
		and int(manifest.get("pid", -1)) == _pid
	):
		_set_state(State.CONFLICT)
		_fail("Native server supervisor identity changed during startup.")
		return
	var supervisor_owned: bool = platform_adapter.is_process_identity(
		int(manifest.get("pid", -1)),
		str(manifest.get("started_at", "")),
		supervisor,
		str(manifest.get("supervisor_sha256", ""))
	)
	var runtime_owned: bool = platform_adapter.is_process_identity(
		int(manifest.get("runtime_pid", -1)),
		str(manifest.get("runtime_started_at", "")),
		executable,
		str(manifest.get("runtime_sha256", "")),
		int(manifest.get("pid", -1)) if supervisor_owned else -1
	)
	if _state == State.STARTING and not supervisor_owned:
		if runtime_owned and phase == "running":
			if (
				platform_adapter.has_method("supports_runtime_adoption")
				and not platform_adapter.supports_runtime_adoption()
			):
				_set_state(State.CONFLICT)
				_fail("Native supervisor exited; waiting for its owned runtime to close.")
				return
			_adopted_runtime = true
			_pid = int(manifest.get("runtime_pid", -1))
			_started_at = str(manifest.get("runtime_started_at", ""))
			if _healthy():
				_set_state(State.ONLINE)
				ready.emit(host, database)
		elif (
			not platform_adapter.process_exists(int(manifest.get("pid", -1)))
			and not platform_adapter.process_exists(int(manifest.get("runtime_pid", -1)))
		):
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
	elif (
		_state == State.STARTING
		and phase == "starting"
		and Time.get_ticks_msec() >= _start_deadline
	):
		_set_state(State.UNHEALTHY)
		_fail("Native server is owned but did not become healthy before the startup deadline.")
	elif (
		_state == State.STARTING
		and phase == "provisioning"
		and Time.get_ticks_msec() >= _start_deadline
	):
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
	if (
		(
			supervisor_alive
			and not platform_adapter.is_process_identity(
				supervisor_pid,
				str(_shutdown_manifest.started_at),
				supervisor,
				str(_shutdown_manifest.supervisor_sha256)
			)
		)
		or (
			runtime_alive
			and not platform_adapter.is_process_identity(
				runtime_pid,
				str(_shutdown_manifest.runtime_started_at),
				executable,
				str(_shutdown_manifest.runtime_sha256),
				supervisor_pid if supervisor_alive else -1
			)
		)
	):
		_set_state(State.CONFLICT)
		_fail("Native server identity changed during shutdown.")
	elif not supervisor_alive and not runtime_alive:
		if _clear_runtime_manifest(_shutdown_manifest):
			_shutdown_manifest.clear()
			_set_state(State.OFFLINE)
		else:
			var current := _read_manifest()
			if (
				(not current.is_empty() and not _same_owner(current, _shutdown_manifest))
				or Time.get_ticks_msec() >= _stop_deadline
			):
				_set_state(State.CONFLICT)
				_fail("Native server ownership could not be released safely.")
	elif Time.get_ticks_msec() >= _stop_deadline:
		_set_state(State.STOP_TIMEOUT)


func set_autostart(enabled: bool) -> Dictionary:
	if not _supported():
		return {"ok": false, "error": _unsupported_reason()}
	if enabled and not _ensure_dirs():
		return {
			"ok": false,
			"error": "Could not prepare native server data directories for login startup."
		}
	return platform_adapter.set_autostart(
		enabled,
		supervisor,
		executable,
		cli_executable,
		module_artifact,
		host,
		database,
		data_dir,
		config_dir,
		lock_file,
		log_file,
		manifest_file,
		_file_sha256(module_artifact),
		"autostart"
	)


func get_autostart() -> Dictionary:
	if not _supported():
		return {"ok": false, "enabled": false, "error": _unsupported_reason()}
	return platform_adapter.get_autostart(supervisor, data_dir)


func can_stop() -> bool:
	var manifest := _read_manifest()
	if not _identity_matches(manifest):
		return false
	var supervisor_pid := int(manifest.pid)
	var supervisor_owned: bool = platform_adapter.is_process_identity(
		supervisor_pid, str(manifest.started_at), supervisor, str(manifest.supervisor_sha256)
	)
	var runtime_pid := int(manifest.runtime_pid)
	var runtime_owned: bool = platform_adapter.is_process_identity(
		runtime_pid,
		str(manifest.runtime_started_at),
		executable,
		str(manifest.runtime_sha256),
		supervisor_pid if supervisor_owned else -1
	)
	if (
		(platform_adapter.process_exists(supervisor_pid) and not supervisor_owned)
		or (platform_adapter.process_exists(runtime_pid) and not runtime_owned)
	):
		return false
	if supervisor_owned:
		return runtime_owned
	return (
		runtime_owned
		and (
			not platform_adapter.has_method("supports_runtime_adoption")
			or platform_adapter.supports_runtime_adoption()
		)
	)


func _supported() -> bool:
	if platform_adapter != null and platform_adapter.has_method("supports_native_hosting"):
		return platform_adapter.supports_native_hosting()
	return (
		OS.get_name() == "Linux"
		and ["x86_64", "AMD64"].has(OS.get_processor_name())
		and _linux_distribution_supported()
	)


func _unsupported_reason() -> String:
	return "Managed native hosting requires Linux x86_64 or Windows x86_64 and the pinned runtime. Dedicated servers can use Docker or a manual service."


func _healthy() -> bool:
	_last_health_check = Time.get_ticks_msec()
	return platform_adapter.health(host)


func _health_due() -> bool:
	return (
		_last_health_check < 0 or Time.get_ticks_msec() - _last_health_check >= HEALTH_INTERVAL_MS
	)


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
	for field in [
		"runtime",
		"runtime_sha256",
		"cli_sha256",
		"supervisor_sha256",
		"module_sha256",
		"database",
		"pid",
		"runtime_pid",
		"started_at",
		"runtime_started_at",
		"runtime_parent_pid",
		"runtime_binary",
		"startup_nonce",
		"data_dir",
		"host"
	]:
		if not manifest.has(field):
			return false
	return (
		str(manifest.get("runtime", "")) == RUNTIME_VERSION
		and str(manifest.get("runtime_sha256", "")) == _file_sha256(executable)
		and str(manifest.get("cli_sha256", "")) == _file_sha256(cli_executable)
		and str(manifest.get("supervisor_sha256", "")) == _file_sha256(supervisor)
		and str(manifest.get("module_sha256", "")) == _file_sha256(module_artifact)
		and str(manifest.get("database", "")) == database
		and str(manifest.get("runtime_binary", "")) == executable
		and _data_path_matches(str(manifest.get("data_dir", "")))
		and str(manifest.get("host", "")) == host
		and int(manifest.get("pid", -1)) > 1
		and int(manifest.get("runtime_pid", -1)) > 1
		and int(manifest.get("runtime_parent_pid", -1)) == int(manifest.get("pid", -1))
		and not str(manifest.get("startup_nonce", "")).is_empty()
	)


func _data_path_matches(actual: String) -> bool:
	if platform_adapter.has_method("same_data_path"):
		return platform_adapter.same_data_path(actual, data_dir)
	return actual == data_dir


func _ensure_dirs() -> bool:
	return (
		(
			DirAccess.make_dir_recursive_absolute(data_dir) == OK
			or DirAccess.dir_exists_absolute(data_dir)
		)
		and DirAccess.make_dir_recursive_absolute(config_dir) == OK
	)


func _read_manifest() -> Dictionary:
	if not FileAccess.file_exists(manifest_file):
		return {}
	var parser := JSON.new()
	if parser.parse(FileAccess.get_file_as_string(manifest_file)) != OK:
		return {}
	var parsed = parser.data
	return parsed if parsed is Dictionary else {}


func _same_owner(left: Dictionary, right: Dictionary) -> bool:
	for field in [
		"pid", "started_at", "runtime_pid", "runtime_started_at", "startup_nonce", "data_dir"
	]:
		if not left.has(field) or left[field] != right.get(field):
			return false
	return true


func _clear_runtime_manifest(expected_owner: Dictionary = {}) -> bool:
	var exists := FileAccess.file_exists(manifest_file)
	var contents := FileAccess.get_file_as_string(manifest_file) if exists else ""
	var parsed = JSON.parse_string(contents) if not contents.is_empty() else null
	if exists and not parsed is Dictionary:
		return false
	var manifest: Dictionary = parsed if parsed is Dictionary else expected_owner
	if (
		not _identity_matches(manifest)
		or (
			not _startup_nonce.is_empty()
			and str(manifest.get("startup_nonce", "")) != _startup_nonce
		)
	):
		return false
	if not expected_owner.is_empty() and not _same_owner(manifest, expected_owner):
		return false
	if (
		platform_adapter.process_exists(int(manifest.get("pid", -1)))
		or platform_adapter.process_exists(int(manifest.get("runtime_pid", -1)))
	):
		return false
	if not platform_adapter.cleanup_stale(
		supervisor,
		lock_file,
		manifest_file,
		contents.sha256_text() if not contents.is_empty() else "0".repeat(64)
	):
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
	if (
		snapshot_hash.is_empty()
		or not platform_adapter.cleanup_stale(supervisor, lock_file, manifest_file, snapshot_hash)
	):
		_set_state(State.CONFLICT)
		return false
	return true


func _manifest_sha256() -> String:
	return _file_sha256(manifest_file)


func _active_binary() -> String:
	return executable if _adopted_runtime else supervisor


func _active_binary_hash() -> String:
	return (
		str(_read_manifest().get("runtime_sha256", ""))
		if _adopted_runtime
		else str(
			_shutdown_manifest.get(
				"supervisor_sha256", _read_manifest().get("supervisor_sha256", "")
			)
		)
	)


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
	return (
		OS.get_name() == "Linux"
		and ["x86_64", "amd64"].has(str(output[0]).strip_edges().to_lower())
	)


func _fail(message: String) -> void:
	if _state in [State.INSTALLING, State.PREPARING]:
		_set_state(State.OFFLINE)
	failed.emit(message)


func _set_state(value: int) -> void:
	if _state != value:
		_state = value
		status_changed.emit(_state_name(value))


func _state_name(value: int) -> String:
	return [
		"unknown",
		"checking",
		"offline",
		"starting",
		"online",
		"unhealthy",
		"stopping",
		"stop_timeout",
		"unsupported",
		"conflict",
		"installing",
		"preparing",
		"deleting",
		"deleted"
	][value]


func _default_adapter() -> RefCounted:
	var windows_adapter := "res://scripts/native_server_windows_adapter.gd"
	if OS.get_name() == "Windows" and FileAccess.file_exists(windows_adapter):
		return load(windows_adapter).new()
	return load("res://scripts/native_server_platform_adapter.gd").new()
