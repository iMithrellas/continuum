## Read-only launcher preflight. Never starts, adopts, cleans up, or publishes.
## Only public metadata is returned; publisher credentials are never opened.
extends SceneTree

func _initialize() -> void:
	var host := _option("--stdb-host", ContinuumNativeServerManager.DEFAULT_HOST)
	var database := _option("--stdb-db", ContinuumNativeServerManager.DEFAULT_DATABASE)
	var validation := ContinuumServerManagement.validate_endpoint(host, database)
	if not validation.is_empty():
		_fail(validation)
		return
	if host != ContinuumNativeServerManager.DEFAULT_HOST:
		print("TARGET_VALID")
		quit(0)
		return
	var manager := ContinuumNativeServerManager.new()
	manager.host = host
	manager.database = database
	# OS.execute in the supported Godot Linux runtime uses shell-marshaled
	# arguments. Reject unsafe spelling before any derived path reaches it,
	# including roots computed from HOME or XDG_DATA_HOME. Do not sanitize.
	var root := manager._native_root()
	if not _safe_native_path(root):
		_fail("Native root must be an absolute path using only letters, digits, spaces, dots, underscores, dashes and slashes, without dot traversal.")
		return
	var uid_output: Array = []
	if OS.get_name() != "Linux" or OS.execute("id", ["-u"], uid_output, true) != 0 or uid_output.is_empty():
		_fail("Native admin launcher requires Linux.")
		return
	var uid := str(uid_output[0]).strip_edges()
	# Check ownership and write permissions before trusting metadata or an
	# executable. Include all directories beneath the managed native root.
	for path: String in [manager.manifest_file, manager.executable, manager.cli_executable, manager.supervisor, manager.module_artifact, manager.config_dir, manager.data_dir]:
		var current := path
		while true:
			if not _owned_path(current, uid):
				_fail("Start local server in Servers first (native ownership or permissions could not be verified).")
				return
			if current == root:
				break
			current = current.get_base_dir()
			if current.length() < root.length():
				_fail("Native path is outside its managed root.")
				return
	var manifest := manager._read_manifest()
	if not manager._identity_matches(manifest) or str(manifest.get("phase", "")) != "running":
		_fail("Start local server in Servers first (native manifest does not match this host, database, or pinned files).")
		return
	var adapter := manager.platform_adapter
	var pid := int(manifest.pid)
	var runtime_pid := int(manifest.runtime_pid)
	# The manager permits a surviving owned runtime after a dead supervisor.
	# Apply those exact process identity checks without status()'s stale cleanup.
	var supervisor_owned: bool = adapter.is_process_identity(pid, str(manifest.started_at), manager.supervisor, str(manifest.supervisor_sha256))
	var runtime_owned: bool = adapter.is_process_identity(runtime_pid, str(manifest.runtime_started_at), manager.executable, str(manifest.runtime_sha256), pid if supervisor_owned else -1)
	if (not supervisor_owned and adapter.process_exists(pid)) or not runtime_owned \
		or not _owned_path("/proc/%d" % runtime_pid, uid) \
		or (supervisor_owned and not _owned_path("/proc/%d" % pid, uid)):
		_fail("Start local server in Servers first (native process identity could not be verified).")
		return
	if not adapter.health(host):
		_fail("Start local server in Servers first (native server is not online).")
		return
	print("NATIVE_CLI=%s" % manager.cli_executable)
	print("NATIVE_CONFIG=%s" % manager.config_dir)
	quit(0)

func _owned_path(path: String, uid: String) -> bool:
	# Defense in depth: every path argument is checked at the subprocess
	# boundary, not just the root. Symlink targets are followed by stat itself,
	# never resolved to a new string and interpolated into another shell call.
	if not _safe_native_path(path):
		return false
	# stat -L checks the actual target rather than trusting a symlink's owner.
	var output: Array = []
	if OS.execute("stat", ["-L", "-c", "%u %a", "--", path], output, false) != 0 or output.is_empty():
		return false
	var fields := str(output[0]).strip_edges().split(" ", false)
	if fields.size() != 2 or fields[0] != uid:
		return false
	var permissions := fields[1]
	if permissions.length() < 3:
		return false
	return (int(permissions.substr(permissions.length() - 2, 1)) & 2) == 0 \
		and (int(permissions.right(1)) & 2) == 0

func _safe_native_path(path: String) -> bool:
	var pattern := RegEx.new()
	pattern.compile("^/[A-Za-z0-9_./ -]*$")
	var matched := pattern.search(path)
	if not path.is_absolute_path() or matched == null or matched.get_string() != path:
		return false
	for component: String in path.split("/"):
		if component == "." or component == "..":
			return false
	return true

func _option(key: String, fallback: String) -> String:
	for argument: String in OS.get_cmdline_user_args():
		if argument.begins_with(key + "="):
			return argument.substr(key.length() + 1)
	return fallback

func _fail(message: String) -> void:
	printerr("admin launcher: %s" % message)
	quit(1)
