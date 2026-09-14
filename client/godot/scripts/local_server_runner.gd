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
const GROUP_HANDSHAKE_SECONDS := 1.0

@export var host := DEFAULT_HOST
@export var database := DEFAULT_DATABASE

# These overrides are intentionally useful to headless tests. Production uses the
# repository helper resolved from the source checkout.
@export var helper_command := ""
@export var helper_arguments: PackedStringArray = []
@export var status_file := ""
@export var test_skip_process_group_publication := false

var _process_id := -1
var _process_group_id := -1
var _wrapper_process_id := -1
var _cancel_requested := false
var _cleanup_deadline := 0
var _startup_deadline := 0


func is_running() -> bool:
	return _process_id >= 0


func process_group_id() -> int:
	return _process_group_id


func launcher_pid() -> int:
	return _process_id


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
	var group_path := status_path + ".pgid"
	var wrapper_path := status_path + ".pid"
	var wrapper_done_path := status_path + ".done"
	var cancel_path := status_path + ".cancel"
	var ack_path := status_path + ".ack"
	DirAccess.remove_absolute(status_path)
	DirAccess.remove_absolute(group_path)
	DirAccess.remove_absolute(wrapper_path)
	DirAccess.remove_absolute(wrapper_done_path)
	DirAccess.remove_absolute(cancel_path)
	DirAccess.remove_absolute(ack_path)
	arguments.append_array(["--status-file", status_path])
	if not FileAccess.file_exists(command):
		_fail("Local server setup helper is missing: %s" % command)
		return false

	_cancel_requested = false
	_cleanup_deadline = 0
	_process_group_id = -1
	_wrapper_process_id = -1
	_startup_deadline = Time.get_ticks_msec() + int(GROUP_HANDSHAKE_SECONDS * 1000.0)
	progress.emit("Starting local SpacetimeDB infrastructure...")
	# setsid may fork before exec, so its returned PID is not a reliable PGID. The
	# shell records its actual PID/PGID before execing the helper.
	var group_publication := "printf '%s\\n' \"$$\" > \"$2\""
	if test_skip_process_group_publication:
		group_publication = ":"
	var launch_arguments := PackedStringArray(["-f", "/bin/sh", "-c",
		"printf '%s\\n' \"$$\" > \"$1\"; if [ -e \"$3\" ]; then exit 130; fi; " +
		group_publication + "; " +
		"wait_ticks=0; while [ ! -e \"$4\" ] && [ ! -e \"$3\" ] && [ $wait_ticks -lt 100 ]; do " +
		"sleep 0.01; wait_ticks=$((wait_ticks + 1)); done; " +
		"if [ -e \"$3\" ] || [ ! -e \"$4\" ]; then exit 124; fi; " +
		"done_path=\"$5\"; shift 5; \"$@\" & helper_pid=$!; wait \"$helper_pid\"; helper_status=$?; " +
		"temporary=\"$done_path.$$\"; printf '%s\\n' \"$helper_status\" > \"$temporary\"; mv -f \"$temporary\" \"$done_path\"; exit \"$helper_status\"",
		"continuum-process-group", wrapper_path, group_path, cancel_path, ack_path, wrapper_done_path, command])
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
	var cancel_path := ProjectSettings.globalize_path(status_file) + ".cancel"
	var cancel_file := FileAccess.open(cancel_path, FileAccess.WRITE)
	cancel_file.store_string("cancelled\n")
	cancel_file.close()
	_kill_process_group("TERM")
	_cleanup_deadline = Time.get_ticks_msec() + int(CLEANUP_GRACE_SECONDS * 1000.0)


func _watch_process() -> void:
	var status_path := ProjectSettings.globalize_path(status_file)
	var group_path := status_path + ".pgid"
	var wrapper_path := status_path + ".pid"
	var wrapper_done_path := status_path + ".done"
	var cancel_path := status_path + ".cancel"
	var ack_path := status_path + ".ack"
	var helper_dead := false
	var group_dead := false
	var unexpected_exit := false
	var status_deadline := 0
	while is_running():
		_refresh_process_group_id(group_path)
		_refresh_wrapper_process_id(wrapper_path)
		_acknowledge_process_group(ack_path)
		if _process_group_id < 0:
			if _cancel_requested or Time.get_ticks_msec() >= _startup_deadline:
				if not _cancel_requested:
					unexpected_exit = true
					_cancel_requested = true
					var timeout_file := FileAccess.open(cancel_path, FileAccess.WRITE)
					timeout_file.store_string("timeout\n")
					timeout_file.close()
			if OS.get_process_exit_code(_process_id) != -1:
				break
			await Engine.get_main_loop().process_frame
			continue
		if not group_dead and not _group_exists(_process_group_id):
			group_dead = true
			if _cancel_requested:
				break
		if group_dead and _cancel_requested:
			break
		if not helper_dead and FileAccess.file_exists(wrapper_done_path):
			helper_dead = true
			status_deadline = Time.get_ticks_msec() + int(STATUS_GRACE_SECONDS * 1000.0)
		if helper_dead and FileAccess.file_exists(status_path):
			break
		if helper_dead and not FileAccess.file_exists(status_path) \
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
	_process_group_id = -1
	_wrapper_process_id = -1
	if _cancel_requested:
		_cancel_requested = false
		_cleanup_deadline = 0
		DirAccess.remove_absolute(status_path)
		DirAccess.remove_absolute(group_path)
		DirAccess.remove_absolute(wrapper_path)
		DirAccess.remove_absolute(wrapper_done_path)
		DirAccess.remove_absolute(cancel_path)
		DirAccess.remove_absolute(ack_path)
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
	DirAccess.remove_absolute(group_path)
	DirAccess.remove_absolute(wrapper_path)
	DirAccess.remove_absolute(wrapper_done_path)
	DirAccess.remove_absolute(cancel_path)
	DirAccess.remove_absolute(ack_path)
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
	if _process_group_id < 0:
		return
	var output: Array = []
	OS.execute("kill", ["-%s" % signal_name, "--", "-%d" % _process_group_id], output, true)


## RefCounted has no automatic lifecycle callback. The owning launch-menu node must
## call dispose() from its own _exit_tree() so teardown cleans up the process group.
func dispose() -> void:
	cancel()


func _refresh_process_group_id(group_path: String) -> void:
	if _process_group_id >= 0 or not FileAccess.file_exists(group_path):
		return
	var value := FileAccess.get_file_as_string(group_path).strip_edges()
	if value.is_valid_int() and value == str(int(value)) and int(value) > 0:
		_process_group_id = int(value)


func _refresh_wrapper_process_id(wrapper_path: String) -> void:
	if _wrapper_process_id >= 0 or not FileAccess.file_exists(wrapper_path):
		return
	var value := FileAccess.get_file_as_string(wrapper_path).strip_edges()
	if value.is_valid_int() and value == str(int(value)) and int(value) > 0:
		_wrapper_process_id = int(value)


func _acknowledge_process_group(ack_path: String) -> void:
	if _cancel_requested or _process_group_id < 0 or FileAccess.file_exists(ack_path):
		return
	if not _group_exists(_process_group_id):
		return
	var ack_file := FileAccess.open(ack_path, FileAccess.WRITE)
	ack_file.store_string("acknowledged\n")
	ack_file.close()
