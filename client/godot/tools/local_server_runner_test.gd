extends SceneTree

const RUNNER_SCRIPT := "res://scripts/local_server_runner.gd"
var failures := 0


func _initialize() -> void:
	await _test_success()
	await _test_failure()
	await _test_repeated_start_and_cancel()
	if failures == 0:
		print("LOCAL_SERVER_RUNNER_PASS")
		quit(0)
	else:
		print("LOCAL_SERVER_RUNNER_FAIL (%d failures)" % failures)
		quit(1)


func _test_success() -> void:
	var runner: ContinuumLocalServerRunner = load(RUNNER_SCRIPT).new()
	runner.helper_command = "/bin/sh"
	runner.status_file = "/tmp/continuum-runner-success.status"
	runner.helper_arguments = PackedStringArray(["-c", "sleep 0.05; printf '0\\n' > '%s'" % ProjectSettings.globalize_path(runner.status_file)])
	var completed := [false]
	runner.ready.connect(func(_host: String, database: String) -> void:
		completed[0] = database == "continuum")
	_assert(runner.start(), "successful setup starts")
	await _wait_until(func() -> bool: return not runner.is_running())
	_assert(completed[0], "successful setup emits ready")


func _test_failure() -> void:
	var runner: ContinuumLocalServerRunner = load(RUNNER_SCRIPT).new()
	runner.helper_command = "/bin/sh"
	runner.status_file = "/tmp/continuum-runner-failure.status"
	runner.helper_arguments = PackedStringArray(["-c", "printf '7\\n' > '%s'; exit 7" % ProjectSettings.globalize_path(runner.status_file)])
	var message := [""]
	runner.failed.connect(func(value: String) -> void:
		message[0] = value)
	_assert(runner.start(), "failing setup starts")
	await _wait_until(func() -> bool: return not runner.is_running())
	_assert(message[0].contains("exit code 7"), "failure reports helper exit code")


func _test_repeated_start_and_cancel() -> void:
	var runner: ContinuumLocalServerRunner = load(RUNNER_SCRIPT).new()
	runner.helper_command = "/bin/sh"
	runner.status_file = "/tmp/continuum-runner-cancel.status"
	var status_path := ProjectSettings.globalize_path(runner.status_file)
	runner.helper_arguments = PackedStringArray(["-c", "trap \"printf '143\\n' > '%s'; exit 143\" TERM; sleep 5" % status_path])
	_assert(runner.start(), "cancellable setup starts")
	_assert(not runner.start(), "repeated start does not spawn another process")
	runner.cancel()
	await _wait_until(func() -> bool: return not runner.is_running())
	_assert(not runner.start() or runner.is_running(), "runner remains usable after cancellation")
	if runner.is_running():
		runner.cancel()
	await _wait_until(func() -> bool: return not runner.is_running())


func _wait_until(condition: Callable) -> void:
	var deadline := Time.get_ticks_msec() + 3000
	while not condition.call() and Time.get_ticks_msec() < deadline:
		await process_frame
	_assert(condition.call(), "async operation completes")


func _assert(condition: bool, description: String) -> void:
	if not condition:
		failures += 1
		printerr("FAIL: %s" % description)
