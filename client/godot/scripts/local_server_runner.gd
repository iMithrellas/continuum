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

@export var host := DEFAULT_HOST
@export var database := DEFAULT_DATABASE

# These overrides are intentionally useful to headless tests. Production uses the
# repository helper resolved from the source checkout.
@export var helper_command := ""
@export var helper_arguments: PackedStringArray = []
@export var status_file := ""

var _process_id := -1
var _cancel_requested := false


func is_running() -> bool:
	return _process_id >= 0


## Starts exactly one provisioning process. Repeated clicks are harmless.
func start() -> bool:
	if is_running():
		progress.emit("Local server setup is already running.")
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
	progress.emit("Starting local SpacetimeDB infrastructure...")
	_process_id = OS.create_process(command, arguments, false)
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
	OS.kill(_process_id)
	_process_id = -1
	_cancel_requested = false
	progress.emit("Local server setup cancelled.")


func _watch_process() -> void:
	var status_path := ProjectSettings.globalize_path(status_file)
	while is_running() and not FileAccess.file_exists(status_path):
		await Engine.get_main_loop().process_frame
	if not is_running():
		return

	_process_id = -1
	if not FileAccess.file_exists(status_path):
		_fail("Local server setup ended without a status report. Check Docker and the setup output.")
		return
	var status_text := FileAccess.get_file_as_string(status_path).strip_edges()
	DirAccess.remove_absolute(status_path)
	var exit_code := int(status_text)
	if exit_code == 0:
		progress.emit("Local server is ready.")
		ready.emit(host, database)
		return
	_fail("Local server setup failed (exit code %d). Check Docker and the setup output." % exit_code)


func _fail(message: String) -> void:
	_process_id = -1
	_cancel_requested = false
	failed.emit(message)
