extends SceneTree

var failures := 0


class Preparation:
	extends ContinuumNativeServerManager
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


class DelayedRuntime:
	extends Preparation
	var allow_stop := false
	var stops := 0

	func _init() -> void:
		installed = true

	func start() -> bool:
		starts += 1
		_set_state(State.STARTING if starts == 1 else State.ONLINE)
		if starts > 1:
			ready.emit(host, database)
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


class ReusableRuntime:
	extends Preparation
	var stops := 0

	func _init() -> void:
		installed = true

	func can_stop() -> bool:
		return _state == State.ONLINE

	func stop(_force := false) -> bool:
		stops += 1
		_set_state(State.OFFLINE)
		return true


class StaleStopPreflight:
	extends ReusableRuntime

	func status() -> String:
		status_changed.emit(state())
		return state()

	func can_stop() -> bool:
		return false


func _initialize() -> void:
	await _cancel_then_retry()
	await _responsive_shutdown()
	await _retry_waits_for_cancelled_runtime()
	await _fresh_ticket_reuses_runtime()
	await _cancel_rejoin_preserves_existing_runtime()
	await _shared_preparation_preserves_independent_stop()
	await _explicit_stop_is_not_silently_dropped()
	print("NATIVE_CONTROLLER_PASS" if failures == 0 else "NATIVE_CONTROLLER_FAIL")
	quit(0 if failures == 0 else 1)


func _wait_for(condition: Callable) -> bool:
	var deadline := Time.get_ticks_msec() + 3000
	while Time.get_ticks_msec() < deadline:
		if condition.call():
			return true
		await create_timer(0.01).timeout
	return false


func _cancel_then_retry() -> void:
	var fake := Preparation.new()
	var controller := ContinuumNativeServerController.new()
	controller.manager_factory = func(): return fake
	var joined := [0]
	controller.server_ready.connect(func(_host, _database, _epoch): joined[0] += 1)
	root.add_child(controller)
	controller.request_start()
	var entered := await _wait_for(func(): return fake.entered.try_wait())
	_check(entered, "preparation enters its asynchronous step")
	controller.cancel_startup()
	fake.release.post()
	await create_timer(0.15).timeout
	_check(
		fake.prepares == 0 and fake.starts == 0 and joined[0] == 0,
		"cancelled preparation cannot start or autojoin"
	)
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
	_check(
		await _wait_for(func(): return fake.entered.try_wait()),
		"shutdown fixture enters preparation"
	)
	var before := Time.get_ticks_msec()
	controller.request_shutdown()
	_check(
		Time.get_ticks_msec() - before < 100,
		"exit request never joins a busy worker on the UI thread"
	)
	_check(
		not controller.finish_shutdown(),
		"busy preparation reports pending shutdown without blocking"
	)
	await create_timer(0.03).timeout
	fake.release.post()
	_check(
		await _wait_for(controller.finish_shutdown),
		"shutdown completes at the atomic-step boundary"
	)
	_check(
		fake.prepares == 0 and fake.starts == 0,
		"exit cannot start a server after the client leaves"
	)
	controller.queue_free()
	await process_frame


func _retry_waits_for_cancelled_runtime() -> void:
	var fake := DelayedRuntime.new()
	var controller := ContinuumNativeServerController.new()
	controller.manager_factory = func(): return fake
	var joined := [0]
	controller.server_ready.connect(func(_host, _database, _epoch): joined[0] += 1)
	root.add_child(controller)
	controller.request_start()
	_check(await _wait_for(func(): return fake.starts == 1), "first runtime begins startup")
	fake.ready.emit(fake.host, fake.database)
	controller.cancel_startup()
	controller.request_start()
	_check(await _wait_for(func(): return fake.stops == 1), "cancel stops the runtime it created")
	await create_timer(0.15).timeout
	_check(
		fake.starts == 1 and joined[0] == 0, "retry waits for shutdown and stale ready cannot join"
	)
	fake.allow_stop = true
	_check(
		await _wait_for(func(): return fake.starts == 2 and joined[0] == 1),
		"queued retry starts and joins after cleanup"
	)
	controller._emit_server_ready(fake.host, fake.database, 0)
	_check(joined[0] == 1, "old completion cannot acquire the new retry epoch")
	controller.request_shutdown()
	_check(await _wait_for(controller.finish_shutdown), "retry fixture shuts down")
	controller.queue_free()
	await process_frame


func _fresh_ticket_reuses_runtime() -> void:
	var fake := ReusableRuntime.new()
	var controller := ContinuumNativeServerController.new()
	controller.manager_factory = func(): return fake
	var joined: Array[int] = []
	controller.server_ready.connect(func(_host, _database, epoch): joined.append(epoch))
	root.add_child(controller)
	var first := controller.request_start()
	_check(await _wait_for(func(): return joined.size() == 1), "first owned runtime becomes ready")
	var second := controller.request_start()
	_check(
		(
			first != second
			and controller.is_startup_current(second)
			and not controller.is_startup_current(first)
		),
		"fresh requests have unique completion tickets"
	)
	_check(
		await _wait_for(func(): return joined.size() == 2),
		"fresh ticket can join the existing runtime"
	)
	_check(
		fake.stops == 0 and fake.starts == 1,
		"ticket renewal alone never stops or relaunches an owned runtime"
	)
	_check(
		joined.size() == 2 and joined[0] == first and joined[1] == second,
		"ready signals preserve each request's exact ticket"
	)
	controller.request_shutdown()
	_check(controller.request_start() == -1, "closed controller rejects new startup tickets")
	_check(await _wait_for(controller.finish_shutdown), "reusable runtime fixture shuts down")
	controller.queue_free()
	await process_frame


func _cancel_rejoin_preserves_existing_runtime() -> void:
	var fake := ReusableRuntime.new()
	var controller := ContinuumNativeServerController.new()
	controller.manager_factory = func(): return fake
	var joined := [0]
	controller.server_ready.connect(func(_host, _database, _epoch): joined[0] += 1)
	root.add_child(controller)
	controller.request_start()
	_check(
		await _wait_for(func(): return joined[0] == 1),
		"rejoin cancellation fixture has a running server"
	)
	controller.request_start()
	controller.cancel_startup()
	await create_timer(0.15).timeout
	_check(
		fake.stops == 0 and fake.starts == 1 and fake.state() == "online",
		"cancelling a new join ticket never stops an older running server"
	)
	_check(joined[0] == 1, "cancelled rejoin cannot acquire the session")
	controller.request_shutdown()
	_check(await _wait_for(controller.finish_shutdown), "cancelled rejoin worker finishes")
	controller.queue_free()
	await process_frame


func _shared_preparation_preserves_independent_stop() -> void:
	var installing := Preparation.new()
	var installed := Preparation.new()
	installed.installed = true
	var running := ReusableRuntime.new()
	running._state = ContinuumNativeServerManager.State.ONLINE
	var first := ContinuumNativeServerController.new()
	var second := ContinuumNativeServerController.new()
	var third := ContinuumNativeServerController.new()
	first.manager_factory = func(): return installing
	second.manager_factory = func(): return installed
	third.manager_factory = func(): return running
	for controller in [first, second, third]:
		root.add_child(controller)
	first.request_start()
	_check(
		await _wait_for(func(): return installing.entered.try_wait()),
		"shared preparation fixture enters installation"
	)
	second.request_start()
	await create_timer(0.1).timeout
	_check(
		installed.prepares == 0 and installed.starts == 0,
		"another profile cannot race the shared runtime/module preparation"
	)
	third.request_stop()
	_check(
		await _wait_for(func(): return running.stops == 1),
		"a running server remains independently stoppable during another profile's installation"
	)
	second.cancel_startup()
	installing.release.post()
	_check(
		await _wait_for(func(): return installing.starts == 1),
		"first profile completes preparation"
	)
	await create_timer(0.1).timeout
	_check(
		installed.prepares == 0 and installed.starts == 0,
		"cancelled waiting profile never starts after acquiring the preparation lock"
	)
	for controller in [first, second, third]:
		controller.request_shutdown()
	for controller in [first, second, third]:
		_check(await _wait_for(controller.finish_shutdown), "multi-profile worker finishes")
		controller.queue_free()
	await process_frame


func _explicit_stop_is_not_silently_dropped() -> void:
	var manager := StaleStopPreflight.new()
	manager._state = ContinuumNativeServerManager.State.ONLINE
	var controller := ContinuumNativeServerController.new()
	controller.manager_factory = func(): return manager
	root.add_child(controller)
	_check(
		await _wait_for(func(): return controller.cached_state() == "online"),
		"stop preflight fixture becomes manageable"
	)
	controller.request_stop()
	_check(
		await _wait_for(func(): return manager.stops == 1),
		"explicit stop reaches the authoritative manager despite a stale can_stop preflight"
	)
	manager._set_state(ContinuumNativeServerManager.State.CONFLICT)
	_check(
		await _wait_for(func(): return controller.cached_state() == "conflict"),
		"ownership conflict becomes visible"
	)
	controller.request_stop()
	_check(
		await _wait_for(
			func(): return controller.cached_message().contains("no process was signalled")
		),
		"a refused stop reports actionable feedback instead of silently disappearing"
	)
	_check(manager.stops == 1, "a conflicting owner is never stopped")
	controller.request_shutdown()
	_check(await _wait_for(controller.finish_shutdown), "explicit-stop worker finishes")
	controller.queue_free()
	await process_frame


func _check(condition: bool, message: String) -> void:
	if not condition:
		failures += 1
		printerr(message)
