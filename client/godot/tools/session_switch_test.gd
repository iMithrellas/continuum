extends Node

var failed := false

func _ready() -> void:
	var admin_path := ContinuumClientProfile.token_path(ContinuumClientProfile.ADMIN,
		"http://127.0.0.1:1", "continuum")
	var normal_path := ContinuumClientProfile.token_path(ContinuumClientProfile.NORMAL,
		"http://127.0.0.1:1", "continuum")
	var admin_file := FileAccess.open(admin_path, FileAccess.WRITE)
	admin_file.store_string("admin-token-cache")
	admin_file.close()
	DirAccess.remove_absolute(ProjectSettings.globalize_path(normal_path))

	var main := preload("res://scenes/main.tscn").instantiate()
	get_tree().root.add_child.call_deferred(main)
	await get_tree().process_frame
	main.configure_connection("http://127.0.0.1:1", "continuum", ContinuumClientProfile.ADMIN)
	await get_tree().process_frame
	SpacetimeDB.Continuum.set("_token", "admin-token-cache")
	main.configure_connection("http://127.0.0.1:1", "continuum", ContinuumClientProfile.NORMAL)
	await get_tree().process_frame
	await get_tree().process_frame
	_assert(SpacetimeDB.Continuum.token_save_path == normal_path,
		"admin to normal switch selects the normal identity file")
	_assert(SpacetimeDB.Continuum.get_token().is_empty(),
		"fresh production client does not carry the cached admin token")
	_assert(FileAccess.get_file_as_string(admin_path) == "admin-token-cache",
		"switching profiles preserves the admin identity file")

	main.configure_connection("http://127.0.0.1:2", "other_db", ContinuumClientProfile.NORMAL)
	await get_tree().process_frame
	await get_tree().process_frame
	_assert(SpacetimeDB.Continuum.token_save_path == ContinuumClientProfile.token_path(
		ContinuumClientProfile.NORMAL, "http://127.0.0.1:2", "other_db"),
		"endpoint switch selects a fresh endpoint identity file")
	_assert(SpacetimeDB.Continuum.get_token().is_empty(),
		"endpoint switch does not retain the previous cached token")
	main.leave_session()
	var failures := [0]
	var ready_count := [0]
	main.session_failed.connect(func(_message: String) -> void: failures[0] += 1)
	main.session_ready.connect(func() -> void: ready_count[0] += 1)
	main._session_requested = true
	main._direct_launch = false
	var old_generation: int = main._session_generation
	var old_subscription := SpacetimeDBSubscription.new()
	main._subscription = old_subscription
	main._on_connection_error(1006, "abnormal close")
	main._on_disconnected()
	main._on_connected(PackedByteArray(), "late-token")
	main._on_subscription_applied(old_subscription, old_generation)
	_assert(failures[0] == 1, "connection error and disconnected emit one terminal failure (%d)" % failures[0])
	_assert(ready_count[0] == 0 and not main._session_requested,
		"late connected and subscription callbacks cannot restore a failed session")
	DirAccess.remove_absolute(ProjectSettings.globalize_path(admin_path))
	main.queue_free()
	if failed:
		get_tree().quit(1)
		return
	print("SESSION_SWITCH_PASS")
	get_tree().quit(0)

func _assert(condition: bool, message: String) -> void:
	if not condition:
		failed = true
		printerr("FAIL: " + message)
