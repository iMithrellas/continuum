extends SceneTree

var failures := 0

class Preparation extends ContinuumNativeServerManager:
	var entered := Semaphore.new()
	var release := Semaphore.new()
	var installed := false
	var prepares := 0
	var starts := 0
	func status() -> String:
		return state() if _state != State.UNKNOWN else "offline"
	func runtime_installed() -> bool:
		return installed
	func install_native() -> bool:
		_set_state(State.INSTALLING)
		entered.post()
		release.wait()
		installed = true
		_set_state(State.OFFLINE)
		return true
	func prepare_module() -> bool:
		prepares += 1
		return true
	func start() -> bool:
		starts += 1
		_set_state(State.ONLINE)
		ready.emit(host, database)
		return true
	func tick() -> void:
		pass
	func can_stop() -> bool:
		return false

class DelayedRuntime extends Preparation:
	var allow_stop := false
	var stops := 0
	func _init() -> void:
		installed = true
	func start() -> bool:
		starts += 1
		_set_state(State.STARTING if starts == 1 else State.ONLINE)
		if starts > 1: ready.emit(host, database)
		return true
	func can_stop() -> bool:
		return _state in [State.STARTING, State.ONLINE]
	func stop(_force := false) -> bool:
		stops += 1
		_set_state(State.STOPPING)
		return true
	func tick() -> void:
		if _state == State.STOPPING and allow_stop:
			_set_state(State.OFFLINE)

func _initialize() -> void:
	await _cancel_then_retry()
	await _responsive_shutdown()
	await _retry_waits_for_cancelled_runtime()
	print("NATIVE_CONTROLLER_PASS" if failures == 0 else "NATIVE_CONTROLLER_FAIL")
	quit(0 if failures == 0 else 1)

func _wait_for(condition: Callable) -> bool:
	var deadline := Time.get_ticks_msec() + 3000
	while Time.get_ticks_msec() < deadline:
		if condition.call(): return true
		await create_timer(0.01).timeout
	return false

func _cancel_then_retry() -> void:
	var fake := Preparation.new()
	var controller := ContinuumNativeServerController.new()
	controller.manager_factory = func(): return fake
	var joined := [0]
	controller.server_ready.connect(func(_host, _database): joined[0] += 1)
	root.add_child(controller)
	controller.request_start()
	var entered := await _wait_for(func(): return fake.entered.try_wait())
	_check(entered, "preparation enters its asynchronous step")
	controller.cancel_startup()
	fake.release.post()
	await create_timer(0.15).timeout
	_check(fake.prepares == 0 and fake.starts == 0 and joined[0] == 0, "cancelled preparation cannot start or autojoin")
	controller.request_start()
	var retried := await _wait_for(func(): return joined[0] == 1)
	_check(retried and fake.starts == 1, "fresh request can retry after cancellation")
	controller.request_shutdown()
	_check(await _wait_for(controller.finish_shutdown), "idle worker shuts down")
	controller.queue_free()
	await process_frame

func _responsive_shutdown() -> void:
	var fake := Preparation.new()
	var controller := ContinuumNativeServerController.new()
	controller.manager_factory = func(): return fake
	root.add_child(controller)
	controller.request_start()
	_check(await _wait_for(func(): return fake.entered.try_wait()), "shutdown fixture enters preparation")
	var before := Time.get_ticks_msec()
	controller.request_shutdown()
	_check(Time.get_ticks_msec() - before < 100, "exit request never joins a busy worker on the UI thread")
	_check(not controller.finish_shutdown(), "busy preparation reports pending shutdown without blocking")
	await create_timer(0.03).timeout
	fake.release.post()
	_check(await _wait_for(controller.finish_shutdown), "shutdown completes at the atomic-step boundary")
	_check(fake.prepares == 0 and fake.starts == 0, "exit cannot start a server after the client leaves")
	controller.queue_free()
	await process_frame

func _retry_waits_for_cancelled_runtime() -> void:
	var fake := DelayedRuntime.new()
	var controller := ContinuumNativeServerController.new()
	controller.manager_factory = func(): return fake
	var joined := [0]
	controller.server_ready.connect(func(_host, _database): joined[0] += 1)
	root.add_child(controller)
	controller.request_start()
	_check(await _wait_for(func(): return fake.starts == 1), "first runtime begins startup")
	# Queue an old completion, then invalidate it before the main-thread delivery.
	fake.ready.emit(fake.host, fake.database)
	controller.cancel_startup()
	controller.request_start()
	_check(await _wait_for(func(): return fake.stops == 1), "cancel stops the runtime it created")
	await create_timer(0.15).timeout
	_check(fake.starts == 1 and joined[0] == 0, "retry waits for shutdown and stale ready cannot join")
	fake.allow_stop = true
	_check(await _wait_for(func(): return fake.starts == 2 and joined[0] == 1), "queued retry starts and joins after cleanup")
	controller._emit_server_ready(fake.host, fake.database, 0)
	_check(joined[0] == 1, "old completion cannot acquire the new retry epoch")
	controller.request_shutdown()
	_check(await _wait_for(controller.finish_shutdown), "retry fixture shuts down")
	controller.queue_free()
	await process_frame

func _check(condition: bool, message: String) -> void:
	if not condition:
		failures += 1
		printerr(message)
