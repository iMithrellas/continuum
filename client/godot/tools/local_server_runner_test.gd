extends SceneTree

const RUNNER_SCRIPT := "res://scripts/local_server_runner.gd"
var failures := 0


func _initialize() -> void:
	await _test_success()
	await _test_unexpected_exit()
	await _test_invalid_status()
	await _test_cancel_cleans_descendants_and_blocks_restart()
	await _test_missing_group_handshake()
	await _test_cancel_before_group_handshake()
	if failures == 0:
		print("LOCAL_SERVER_RUNNER_PASS")
		quit(0)
	else:
		print("LOCAL_SERVER_RUNNER_FAIL (%d failures)" % failures)
		quit(1)


func _runner(status_name: String) -> ContinuumLocalServerRunner:
	var runner: ContinuumLocalServerRunner = load(RUNNER_SCRIPT).new()
	runner.helper_command = "/bin/sh"
	runner.status_file = "/tmp/continuum-runner-%s.status" % status_name
	return runner


func _test_success() -> void:
	var runner := _runner("success")
	var completed := [false]
	runner.helper_arguments = PackedStringArray(["-c", _write_status_command(runner, "0") + "; sleep 0.5"])
	runner.ready.connect(func(_host: String, database: String) -> void:
		completed[0] = database == "continuum")
	_assert(runner.start(), "successful setup starts")
	await _wait_until(func() -> bool: return runner.process_group_id() > 0)
	_assert(runner.process_group_id() != runner.launcher_pid(),
			"actual process group id is tracked separately from launcher pid")
	await _wait_until(func() -> bool: return not runner.is_running())
	_assert(completed[0], "successful setup emits ready")


func _test_unexpected_exit() -> void:
	var runner := _runner("unexpected")
	var message := [""]
	var child_file := "/tmp/continuum-runner-unexpected-child.pid"
	DirAccess.remove_absolute(child_file)
	runner.helper_arguments = PackedStringArray(["-c",
		"sleep 30 & child=$!; printf '%%s\\n' $child > '%s'; exit 23" % child_file])
	runner.failed.connect(func(value: String) -> void: message[0] = value)
	_assert(runner.start(), "unexpected exit setup starts")
	await _wait_until(func() -> bool: return runner.process_group_id() > 0)
	var unexpected_group_id := runner.process_group_id()
	await _wait_until(func() -> bool: return FileAccess.file_exists(child_file))
	await _wait_until(func() -> bool: return not runner.is_running())
	_assert(message[0].contains("without a status"), "unexpected exit fails instead of hanging")
	var child_pid := int(FileAccess.get_file_as_string(child_file).strip_edges())
	_assert(child_pid > 0, "unexpected-exit descendant PID is numeric")
	await _wait_until(func() -> bool: return not _live_process(child_pid))
	_assert(not _live_group(unexpected_group_id), "unexpected-exit group has no live descendants")


func _test_invalid_status() -> void:
	var runner := _runner("invalid")
	var message := [""]
	runner.helper_arguments = PackedStringArray(["-c", _write_status_command(runner, "")])
	runner.failed.connect(func(value: String) -> void: message[0] = value)
	_assert(runner.start(), "invalid status setup starts")
	await _wait_until(func() -> bool: return not runner.is_running())
	_assert(message[0].contains("invalid status"), "empty status is rejected")


func _test_cancel_cleans_descendants_and_blocks_restart() -> void:
	var runner := _runner("cancel")
	var child_file := "/tmp/continuum-runner-child.pid"
	DirAccess.remove_absolute(child_file)
	runner.helper_arguments = PackedStringArray(["-c",
		"sleep 30 & child=$!; printf '%%s\\n' $child > '%s'; wait $child" % child_file])
	_assert(runner.start(), "cancellable setup starts")
	await _wait_until(func() -> bool: return runner.process_group_id() > 0)
	var cancel_group_id := runner.process_group_id()
	await _wait_until(func() -> bool: return FileAccess.file_exists(child_file))
	var child_pid := int(FileAccess.get_file_as_string(child_file).strip_edges())
	_assert(child_pid > 0, "descendant PID file contains a numeric PID")
	runner.cancel()
	_assert(not runner.start(), "restart is blocked while process group cleans up")
	await _wait_until(func() -> bool: return not runner.is_running())
	await _wait_until(func() -> bool: return not _live_process(child_pid))
	_assert(not _live_process(child_pid), "cancellation terminates descendant process")
	_assert(not _live_group(cancel_group_id), "cancellation leaves no live group descendants")
	_assert(runner.start(), "restart works after process group cleanup")
	runner.cancel()
	await _wait_until(func() -> bool: return not runner.is_running())


func _test_missing_group_handshake() -> void:
	var runner := _runner("missing-group")
	var message := [""]
	var child_file := "/tmp/continuum-runner-missing-child.pid"
	DirAccess.remove_absolute(child_file)
	runner.test_skip_process_group_publication = true
	runner.helper_arguments = PackedStringArray(["-c",
		"sleep 30 & child=$!; printf '%%s\\n' $child > '%s'; wait $child" % child_file])
	runner.failed.connect(func(value: String) -> void: message[0] = value)
	_assert(runner.start(), "missing-PGID setup starts")
	await _wait_until(func() -> bool: return FileAccess.file_exists(child_file))
	await _wait_until(func() -> bool: return not runner.is_running())
	_assert(message[0] != "", "missing PGID fails within the handshake timeout")
	var child_pid := int(FileAccess.get_file_as_string(child_file).strip_edges())
	_assert(child_pid > 0, "missing-PGID descendant PID is numeric")
	await _wait_until(func() -> bool: return not _live_process(child_pid))


func _test_cancel_before_group_handshake() -> void:
	var runner := _runner("early-cancel")
	var child_file := "/tmp/continuum-runner-early-child.pid"
	DirAccess.remove_absolute(child_file)
	runner.test_skip_process_group_publication = true
	runner.helper_arguments = PackedStringArray(["-c",
		"sleep 30 & child=$!; printf '%%s\\n' $child > '%s'; wait $child" % child_file])
	_assert(runner.start(), "early-cancellable setup starts")
	runner.cancel()
	_assert(not runner.start(), "early cancellation blocks immediate restart")
	await _wait_until(func() -> bool: return not runner.is_running())
	if FileAccess.file_exists(child_file):
		var child_pid := int(FileAccess.get_file_as_string(child_file).strip_edges())
		_assert(child_pid > 0, "early-cancel descendant PID is numeric")
		await _wait_until(func() -> bool: return not _live_process(child_pid))


func _write_status_command(runner: ContinuumLocalServerRunner, value: String) -> String:
	var path := ProjectSettings.globalize_path(runner.status_file)
	return "printf '%s\\n' > '%s'" % [value, path]


func _live_process(process_id: int) -> bool:
	var output: Array = []
	var command := "ps -o stat= -p %d | grep -qv '^Z'" % process_id
	return OS.execute("sh", ["-c", command], output, true) == 0


func _live_group(group_id: int) -> bool:
	var output: Array = []
	var command := "ps -eo pgid= | grep -Eq '^ *%d *$'" % group_id
	return OS.execute("sh", ["-c", command], output, true) == 0


func _wait_until(condition: Callable) -> void:
	var deadline := Time.get_ticks_msec() + 5000
	while not condition.call() and Time.get_ticks_msec() < deadline:
		await process_frame
	_assert(condition.call(), "async operation completes")


func _assert(condition: bool, description: String) -> void:
	if not condition:
		failures += 1
		printerr("FAIL: %s" % description)
