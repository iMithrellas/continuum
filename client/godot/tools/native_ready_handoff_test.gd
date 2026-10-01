extends Node

var failures := 0

class ReadyOnly extends ContinuumNativeServerManager:
	var entered := Semaphore.new()
	var release := Semaphore.new()
	var rejoin_entered := Semaphore.new()
	var rejoin_release := Semaphore.new()
	var hold_rejoin := false
	var starts := 0
	var stops := 0
	func _init() -> void:
		host = "http://127.0.0.1:6"
		database = "first-native"
	func status() -> String:
		if _state == State.UNKNOWN: _set_state(State.OFFLINE)
		if hold_rejoin and _state == State.ONLINE:
			hold_rejoin = false
			rejoin_entered.post()
			rejoin_release.wait()
		return state()
	func runtime_installed() -> bool: return true
	func prepare_module() -> bool: return true
	func start() -> bool:
		starts += 1
		_set_state(State.STARTING)
		entered.post()
		release.wait()
		_set_state(State.ONLINE)
		ready.emit(host, database)
		return true
	func can_stop() -> bool: return false
	func stop(_force := false) -> bool:
		stops += 1
		return false
	func tick() -> void: pass

func _ready() -> void:
	call_deferred("_run")

func _run() -> void:
	var fixture := "/tmp/opencode/continuum-local-controls-state/native-ready-%d" % OS.get_process_id()
	DirAccess.make_dir_recursive_absolute(fixture)
	OS.set_environment("CONTINUUM_NATIVE_ROOT", fixture.path_join("native"))
	OS.set_environment("HOME", fixture)
	for mode in ["cancel", "cancel_restart", "manual", "return", "leave", "close", "controller_cancel", "current"]:
		await _case(mode)
	await _retirement_case(true)
	await _retirement_case(false)
	await _retirement_case(false, true)
	print("NATIVE_READY_HANDOFF_PASS" if failures == 0 else "NATIVE_READY_HANDOFF_FAIL")
	get_tree().quit(0 if failures == 0 else 1)

func _case(mode: String) -> void:
	var main := preload("res://scenes/main.tscn").instantiate()
	main.set_script(preload("res://tools/session_handoff_main_fixture.gd"))
	get_tree().root.add_child(main)
	main._native_controller.request_shutdown()
	_check(await _wait_for(main._native_controller.finish_shutdown), "initial private status worker shuts down")
	main._native_controller.queue_free()
	await get_tree().process_frame
	var fake := ReadyOnly.new()
	var controller := ContinuumNativeServerController.new()
	controller.manager_factory = func(): return fake
	controller.state_changed.connect(main._on_native_state, CONNECT_DEFERRED)
	controller.server_ready.connect(main._on_native_ready.bind(controller.get_instance_id()), CONNECT_DEFERRED)
	main._native_controller = controller
	main.add_child(controller)
	main._show_server_management()
	main._on_native_state("offline", "")
	var emissions: Array[Dictionary] = []
	controller.server_ready.connect(func(_host, database, epoch):
		emissions.append({"database": database, "epoch": epoch})
		if emissions.size() != 1: return
		match mode:
			"cancel": main._server_management._local_cancel.pressed.emit()
			"cancel_restart":
				main._server_management._local_cancel.pressed.emit()
				fake.hold_rejoin = true
				fake.database = "fresh-native"
				main._on_native_state("offline", "")
				main._server_management.request_local_start()
				_check(main._native_join_epoch != epoch and main._server_management._native_busy, "restart uses a distinct intent and is initially busy")
			"manual":
				main._server_management.set_native_busy(false)
				main._server_management._join_host.text = "http://127.0.0.1:2"
				main._server_management._join_database.text = "manual-selected"
				main._server_management._join_server()
			"return": main._server_management._back_button.pressed.emit()
			"leave": main.leave_session()
			"close":
				main.set_process(false)
				main._request_exit()
			"controller_cancel": controller.cancel_startup()
	)
	main._server_management.request_local_start()
	_check(await _wait_for(func(): return fake.entered.try_wait()), "real worker enters fake native launch")
	fake.release.post()
	_check(await _wait_for(func(): return not emissions.is_empty()), "native worker emits ready before the lifecycle action: " + mode)
	await _frames()
	if mode == "cancel_restart":
		_check(await _wait_for(func(): return fake.rejoin_entered.try_wait()), "new request reaches its held status check")
		_check(main.starts.is_empty() and not main._session_requested, "old completion cannot acquire a restarted intent (ABA)")
		print("NATIVE_ABA old_epoch=%d new_epoch=%d starts_before_fresh=%d" % [emissions[0].epoch, main._native_join_epoch, main.starts.size()])
		fake.rejoin_release.post()
		_check(await _wait_for(func(): return main.starts.size() == 1), "new epoch completion is allowed to join")
		_check(not main.starts.is_empty() and main.starts[0].database == "fresh-native", "only the restarted native target joins")
	elif mode == "manual":
		_check(main.starts.size() == 1 and main.starts[0].database == "manual-selected" and main._database == "manual-selected", "native completion cannot overwrite a newer manual target")
		_check(main._session_requested and main._server_management._join_button.disabled, "new manual target stays legitimately busy")
	elif mode == "current":
		_check(main.starts.size() == 1 and main.starts[0].database == "first-native" and main._session_requested, "current native intent joins successfully")
		controller._emit_server_ready(fake.host, fake.database, emissions[0].epoch)
		await _frames()
		_check(main.starts.size() == 1, "consumed native intent cannot join twice")
		var other := ContinuumNativeServerController.new()
		var other_epoch := other.request_start()
		main._native_join_epoch = other_epoch
		main._native_join_generation = main._session_generation
		main._on_native_ready(fake.host, "wrong-controller", other_epoch, other.get_instance_id())
		_check(main.starts.size() == 1 and main._database == "first-native", "wrong controller cannot claim an equal numeric ticket")
		main._invalidate_native_join()
		other.free()
	else:
		_check(main.starts.is_empty() and not main._session_requested, "deferred native ready cannot join after " + mode)
	print("NATIVE_READY mode=%s starts=%d requested=%s target=%s" % [mode, main.starts.size(), main._session_requested, main._database])
	main.leave_session()
	controller.request_shutdown()
	_check(await _wait_for(controller.finish_shutdown), "native ready worker finishes")
	main.queue_free()
	await get_tree().process_frame

func _retirement_case(replace: bool, retain_freed := false) -> void:
	var main := preload("res://scenes/main.tscn").instantiate()
	main.set_script(preload("res://tools/session_handoff_main_fixture.gd"))
	get_tree().root.add_child(main)
	main._native_controller.request_shutdown()
	_check(await _wait_for(main._native_controller.finish_shutdown), "private worker finishes before retirement fixture")
	main._native_controller.queue_free()
	await get_tree().process_frame
	var fake := ReadyOnly.new()
	var replacement_fake := ReadyOnly.new()
	replacement_fake._state = ContinuumNativeServerManager.State.ONLINE
	replacement_fake.database = "replacement-native"
	var controller := ContinuumNativeServerController.new()
	controller.manager_factory = func(): return fake
	var retired := [false]
	controller.server_ready.connect(func(_host, _database, _epoch):
		if not retain_freed: main._native_controller = null
		if replace:
			var replacement := ContinuumNativeServerController.new()
			replacement.manager_factory = func(): return replacement_fake
			replacement.server_ready.connect(main._on_native_ready.bind(replacement.get_instance_id()), CONNECT_DEFERRED)
			main._native_controller = replacement
			main.add_child(replacement)
		controller.request_shutdown()
		var deadline := Time.get_ticks_msec() + 3000
		while not controller.finish_shutdown() and Time.get_ticks_msec() < deadline:
			OS.delay_msec(1)
		_check(controller.finish_shutdown(), "retiring worker finishes without process actions")
		controller.free()
		retired[0] = true
	, CONNECT_DEFERRED)
	controller.server_ready.connect(main._on_native_ready.bind(controller.get_instance_id()), CONNECT_DEFERRED)
	main._native_controller = controller
	main.add_child(controller)
	main._show_server_management()
	main._on_native_state("offline", "")
	main._server_management.request_local_start()
	_check(await _wait_for(func(): return fake.entered.try_wait()), "retirement fixture's real worker enters fake launch")
	fake.release.post()
	_check(await _wait_for(func(): return retired[0]), "real ready emission retires its source before Main delivery")
	await _frames()
	_check(main.native_ready_deliveries == 1 and main.starts.is_empty() and not main._session_requested, "freed source safely enters the receiver guard without conversion failure or join")
	print("NATIVE_RETIRED replacement=%s retained=%s deliveries=%d starts=%d" % [replace, retain_freed, main.native_ready_deliveries, main.starts.size()])
	if replace:
		main._on_native_state("offline", "")
		main._server_management.request_local_start()
		_check(await _wait_for(func(): return main.starts.size() == 1), "replacement controller's current completion still joins")
		_check(main.native_ready_deliveries == 2 and not main.starts.is_empty() and main.starts[0].database == "replacement-native", "only the replacement source can select its native target")
		main._native_controller.request_shutdown()
		_check(await _wait_for(main._native_controller.finish_shutdown), "replacement worker finishes")
	_check(fake.starts == 1 and replacement_fake.starts == 0 and fake.stops == 0 and replacement_fake.stops == 0, "retirement and ticket renewal cause no extra runtime launch or stop")
	main.leave_session()
	main.queue_free()
	await get_tree().process_frame

func _frames() -> void:
	for _i in 6: await get_tree().process_frame

func _wait_for(condition: Callable) -> bool:
	var deadline := Time.get_ticks_msec() + 3000
	while Time.get_ticks_msec() < deadline:
		if condition.call(): return true
		await get_tree().create_timer(0.01).timeout
	return false

func _check(condition: bool, message: String) -> void:
	if not condition:
		failures += 1
		printerr("FAIL: " + message)
