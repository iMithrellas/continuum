extends Node

var failures := 0

func _ready() -> void:
	call_deferred("_run")

func _run() -> void:
	var root := OS.get_environment("CONTINUUM_NATIVE_ROOT")
	var fixture := (root if not root.is_empty() else "/tmp/opencode").path_join("handoff-%d" % OS.get_process_id())
	DirAccess.make_dir_recursive_absolute(fixture)
	OS.set_environment("CONTINUUM_NATIVE_ROOT", fixture.path_join("native"))
	OS.set_environment("HOME", fixture)
	var main := preload("res://scenes/main.tscn").instantiate()
	main.set_script(preload("res://tools/session_handoff_main_fixture.gd"))
	get_tree().root.add_child(main)
	main.configure_connection("http://127.0.0.1:1", "old-db", ContinuumClientProfile.NORMAL, true)
	main._show_server_management()
	var old_client: ContinuumModuleClient = SpacetimeDB.Continuum
	var old_generation: int = main._session_generation
	var old_access := ContinuumAccess.new(old_client)
	old_access.stop() # Never subscribe or send an auth request in this fixture.
	main._bind_access(old_access, old_client, old_generation)
	old_access.call_deferred("emit_signal", "changed", "Admin", true, true)
	# Also queue already-captured callbacks: disconnecting a signal alone cannot
	# withdraw a callback that was delivered to the deferred queue earlier.
	main._client_bindings[0].callback.call_deferred(PackedByteArray(), "old-token")
	main._client_bindings[1].callback.call_deferred()
	main._client_bindings[2].callback.call_deferred(2, "old queued callback failure")
	main._client_bindings[3].callback.call_deferred("my_role", null)
	main._client_bindings[4].callback.call_deferred("my_role", null, null)
	main._client_bindings[5].callback.call_deferred("my_role", null)
	var old_subscription := SpacetimeDBSubscription.new()
	main._subscription = old_subscription
	main._on_subscription_applied.call_deferred(old_subscription, old_generation)
	var old_intent := SpacetimeDBReducerCall.new()
	main._track_intent(old_intent, "old intent")
	var old_report := SpacetimeDBReducerCall.new()
	main._report(old_report, "old report")
	var old_response := ReducerResultMessage.new()
	old_response.reducer_result = ReducerOutcomeEnum.create_internal_error("old acknowledgement")
	old_intent.call_deferred("emit_signal", "response", old_response)
	old_report.call_deferred("emit_signal", "response", old_response)
	main._on_haul_policy_response.call_deferred(old_response, 7, old_generation)
	main._on_meal_policy_response.call_deferred(old_response, 7, old_generation)
	main._set_permissions("Admin", true, true)
	var failed := [0]
	main.session_failed.connect(func(_message): failed[0] += 1)
	old_client.call_deferred("emit_signal", "connection_error", 2, "old pending token failure")
	old_client.call_deferred("emit_signal", "disconnected")
	old_client.call_deferred("emit_signal", "connected", PackedByteArray(), "old-token")
	old_client.call_deferred("emit_signal", "row_inserted", "my_role", null)
	old_client.call_deferred("emit_signal", "row_updated", "my_role", null, null)
	old_client.call_deferred("emit_signal", "row_deleted", "my_role", null)
	var browser: ContinuumServerManagement = main._server_management
	browser._join_host.text = "http://127.0.0.1:2"
	browser._join_database.text = "new-db"
	browser._join_server()
	var selected_generation: int = main._session_generation
	browser._join_server()
	_check(main._session_generation == selected_generation, "busy browser blocks a duplicate manual join")
	main._replace_client_and_connect(old_generation)
	_check(SpacetimeDB.Continuum == old_client, "stale replacement cannot remove the selected epoch's transport")
	_check(main._intent_request == null and main._haul_request == null and main._meal_request == null and not main._can_operate and not main._is_admin, "selection immediately revokes old permissions and pending reducer handles")
	# Request IDs can be reused by a fresh client. Old acknowledgements must not
	# clear a new request even if its request ID collides with the old one.
	var current_intent := SpacetimeDBReducerCall.new()
	main._track_intent(current_intent, "current intent")
	var current_haul := SpacetimeDBReducerCall.new()
	current_haul.request_id = 7
	main._haul_request = current_haul
	main._haul_request_seconds = 10.0
	var current_meal := SpacetimeDBReducerCall.new()
	current_meal.request_id = 7
	main._meal_request = current_meal
	main._meal_request_seconds = 10.0
	print("HANDOFF_BEFORE requested=%s direct=%s busy=%s" % [main._session_requested, main._direct_launch, browser._join_button.disabled])
	_check(main._session_requested and not main._direct_launch and browser._join_button.disabled, "manual join is legitimately busy before deferred delivery")
	await get_tree().process_frame
	await get_tree().process_frame
	print("HANDOFF_AFTER requested=%s failures=%d target=%s starts=%d connected=%d rows=%d" % [main._session_requested, failed[0], main._database, main.starts.size(), main.connected_events, main.row_events])
	_check(main._session_requested and failed[0] == 0 and main._database == "new-db", "old queued failure cannot fail the new manual join")
	_check(main.starts.size() == 2 and main.starts[1].database == "new-db", "new endpoint reaches connection start exactly once")
	_check(main.connected_events == 0 and main.row_events == 0 and not main._state_ready, "old queued success and rows cannot restore readiness or role state")
	_check(main._intent_request == current_intent and main._haul_request == current_haul and main._meal_request == current_meal, "old queued reducer acknowledgements cannot clear new handles")
	_check(not main._connection_label.text.contains("old acknowledgement") and not main._can_operate, "old report and role callbacks cannot change new session feedback or authority")
	SpacetimeDB.Continuum.connected.emit(PackedByteArray(), "current-token")
	SpacetimeDB.Continuum.row_inserted.emit("my_role", null)
	_check(main.connected_events == 1 and main.row_events == 1, "current client success and row events remain delivered")
	var current_access := ContinuumAccess.new(SpacetimeDB.Continuum)
	current_access.stop()
	main._bind_access(current_access, SpacetimeDB.Continuum, main._session_generation)
	current_access.changed.emit("Admin", true, true)
	_check(main._can_operate and main._is_admin, "current client role callbacks remain authoritative")
	var current_response := ReducerResultMessage.new()
	current_response.reducer_result = ReducerOutcomeEnum.create_ok_empty()
	current_intent.response.emit(current_response)
	main._on_haul_policy_response(current_response, 7, main._session_generation)
	main._on_meal_policy_response(current_response, 7, main._session_generation)
	_check(main._intent_request == null and main._haul_request == null and main._meal_request == null, "current reducer acknowledgements remain delivered")
	var current_subscription := SpacetimeDBSubscription.new()
	main._subscription = current_subscription
	main._on_subscription_applied(current_subscription, main._session_generation)
	_check(main._state_ready, "current subscription can grant readiness")
	var start_count: int = main.starts.size()
	main._closing = true
	main._state_ready = false
	SpacetimeDB.Continuum.connected.emit(PackedByteArray(), "closing-token")
	main._on_subscription_applied(current_subscription, main._session_generation)
	main.configure_connection("http://127.0.0.1:3", "closing-db")
	main._on_native_ready("http://127.0.0.1:3", "closing-db", main._native_join_epoch, main._native_controller.get_instance_id())
	main._replace_client_and_connect(main._session_generation)
	_check(main.starts.size() == start_count and main._database == "new-db" and main.connected_events == 1 and not main._state_ready, "closure cannot select another target, deliver success or restore readiness")
	main._closing = false
	SpacetimeDB.Continuum.connection_error.emit(2, "current fixture failure")
	_check(not main._session_requested and failed[0] == 1 and not main._can_operate and not main._is_admin, "current client failure remains terminal and revokes permissions for a manual join")
	main.leave_session()
	main._native_controller.request_shutdown()
	var deadline := Time.get_ticks_msec() + 3000
	while not main._native_controller.finish_shutdown() and Time.get_ticks_msec() < deadline:
		await get_tree().create_timer(0.01).timeout
	main.queue_free()
	await get_tree().process_frame
	print("SESSION_HANDOFF_PASS" if failures == 0 else "SESSION_HANDOFF_FAIL")
	get_tree().quit(0 if failures == 0 else 1)

func _check(condition: bool, message: String) -> void:
	if not condition:
		failures += 1
		printerr("FAIL: " + message)
