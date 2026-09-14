## Non-blocking source-checkout provisioning for the future launch menu.
##
## This adapter owns no SpacetimeDB connection or client identity. It only starts
## the repository helper and reports when the requested database is published.
class_name ContinuumLocalServerRunner extends RefCounted

signal progress(message: String)
signal ready(host: String, database: String)
signal failed(message: String)

const DEFAULT_HOST := "http://127.0.0.1:3000"
const DEFAULT_DATABASE := "continuum"
const PROCESS_GROUP_LAUNCHER := "/usr/bin/setsid"
const CLEANUP_GRACE_SECONDS := 1.0
const STATUS_GRACE_SECONDS := 0.25

@export var host := DEFAULT_HOST
@export var database := DEFAULT_DATABASE

# These overrides are intentionally useful to headless tests. Production uses the
# repository helper resolved from the source checkout.
@export var helper_command := ""
@export var helper_arguments: PackedStringArray = []
@export var status_file := ""

var _process_id := -1
var _cancel_requested := false
var _cleanup_deadline := 0


func is_running() -> bool:
	return _process_id >= 0


## Starts exactly one provisioning process. Repeated clicks are harmless.
func start() -> bool:
	if is_running():
		progress.emit("Local server setup is already running or cleaning up.")
		return false

	if not OS.has_feature("editor"):
		_fail("Local server setup is only supported from a source checkout; exported builds are unsupported.")
		return false

	var command := helper_command
	var arguments := helper_arguments
	if command.is_empty():
		command = ProjectSettings.globalize_path("res://../../scripts/internal/start-local-server")
		arguments = PackedStringArray(["--database", database])
	if status_file.is_empty():
		status_file = "user://continuum_local_server_%s.status" % Time.get_ticks_usec()
	var status_path := ProjectSettings.globalize_path(status_file)
	DirAccess.remove_absolute(status_path)
	arguments.append_array(["--status-file", status_path])
	if not FileAccess.file_exists(command):
		_fail("Local server setup helper is missing: %s" % command)
		return false

	_cancel_requested = false
	_cleanup_deadline = 0
	progress.emit("Starting local SpacetimeDB infrastructure...")
	var launch_arguments := PackedStringArray([command])
	launch_arguments.append_array(arguments)
	_process_id = OS.create_process(PROCESS_GROUP_LAUNCHER, launch_arguments, false)
	if _process_id < 0:
		_fail("Could not start local server setup. Check that Docker, Compose, and the helper are installed.")
		return false
	progress.emit("Publishing the local database '%s'..." % database)
	_watch_process()
	return true


## Cancels setup without stopping an already-running persistent server.
func cancel() -> void:
	if not is_running():
		progress.emit("No local server setup is running.")
		return
	_cancel_requested = true
	progress.emit("Cancelling local server setup...")
	_kill_process_group("TERM")
	_cleanup_deadline = Time.get_ticks_msec() + int(CLEANUP_GRACE_SECONDS * 1000.0)


func _watch_process() -> void:
	var status_path := ProjectSettings.globalize_path(status_file)
	var leader_reaped := false
	var unexpected_exit := false
	var status_deadline := 0
	while is_running() and _group_exists(_process_id):
		if not leader_reaped:
			var exit_code := OS.get_process_exit_code(_process_id)
			if exit_code != -1:
				leader_reaped = true
				status_deadline = Time.get_ticks_msec() + int(STATUS_GRACE_SECONDS * 1000.0)
		if leader_reaped and not FileAccess.file_exists(status_path) and not _cancel_requested \
				and Time.get_ticks_msec() >= status_deadline:
			unexpected_exit = true
			_cancel_requested = true
			_cleanup_deadline = Time.get_ticks_msec() + int(CLEANUP_GRACE_SECONDS * 1000.0)
			_kill_process_group("TERM")
		if _cancel_requested and Time.get_ticks_msec() >= _cleanup_deadline:
			_kill_process_group("KILL")
			_cleanup_deadline = Time.get_ticks_msec() + int(CLEANUP_GRACE_SECONDS * 1000.0)
			progress.emit("Waiting for local server setup processes to exit...")
		await Engine.get_main_loop().process_frame
	if not is_running():
		return

	_process_id = -1
	if _cancel_requested:
		_cancel_requested = false
		_cleanup_deadline = 0
		DirAccess.remove_absolute(status_path)
		if unexpected_exit:
			_fail("Local server setup ended without a status report. Check Docker and the setup output.")
			return
		progress.emit("Local server setup cancelled.")
		return
	if not FileAccess.file_exists(status_path):
		_fail("Local server setup ended without a status report. Check Docker and the setup output.")
		return
	var status_text := FileAccess.get_file_as_string(status_path).strip_edges()
	DirAccess.remove_absolute(status_path)
	if not status_text.is_valid_int() or status_text != str(int(status_text)):
		_fail("Local server setup wrote an invalid status report.")
		return
	var exit_code := int(status_text)
	if exit_code == 0:
		progress.emit("Local server is ready.")
		ready.emit(host, database)
		return
	_fail("Local server setup failed (exit code %d). Check Docker and the setup output." % exit_code)


func _fail(message: String) -> void:
	_process_id = -1
	_cancel_requested = false
	_cleanup_deadline = 0
	failed.emit(message)


func _group_exists(process_id: int) -> bool:
	var output: Array = []
	return OS.execute("kill", ["-0", "--", "-%d" % process_id], output, true) == 0


func _kill_process_group(signal_name: String) -> void:
	if not is_running():
		return
	var output: Array = []
	OS.execute("kill", ["-%s" % signal_name, "--", "-%d" % _process_id], output, true)


## RefCounted has no automatic tree callback. Owners embedding this adapter should
## call dispose() from their _exit_tree() so a launch-menu teardown cleans up too.
func dispose() -> void:
	cancel()


func _exit_tree() -> void:
	dispose()
