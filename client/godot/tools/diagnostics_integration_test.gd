extends Node

const MainScene = preload("res://tools/diagnostics_fixture_main.tscn")

var failed := false


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	var settings_path := "user://diagnostics_integration_%d.cfg" % Time.get_ticks_usec()
	var settings := ClientSettings.new()
	settings.font_size = 19
	settings.server_host = "http://example.test"
	settings.database = "diagnostics-db"
	settings.diagnostics_enabled = true
	settings.diagnostics_graph_enabled = false
	_assert(settings.save_to(settings_path) == OK, "diagnostics settings save")
	var loaded := ClientSettings.new()
	_assert(loaded.load_from(settings_path) == "loaded", "diagnostics settings reload")
	_assert(loaded.diagnostics_enabled and not loaded.diagnostics_graph_enabled and
			loaded.server_host == settings.server_host and loaded.database == settings.database and
			loaded.font_size == settings.font_size, "diagnostics and last server settings persist together")

	var main := MainScene.instantiate()
	main.diagnostics_settings_path = settings_path
	get_tree().root.add_child(main)
	await get_tree().process_frame
	_assert(main._server_management._metrics.base_font_size == 19 and
		main._server_management._join_button.get_theme_font_size("font_size") == 19,
		"production browser uses the saved font before any settings changes")
	_assert(main._server_management._join_host.text == settings.server_host and
		main._server_management._join_database.text == settings.database, "server form loads the saved endpoint")
	main.set_size(Vector2(360, 480))
	for _frame in 8: await get_tree().process_frame
	var servers_button := _button_named(main._menu, "Servers")
	_assert(servers_button != null and servers_button.get_global_rect().size.x > 0.0 and
			servers_button.get_global_rect().size.y > 0.0, "production menu Servers button has usable geometry")
	servers_button.pressed.emit()
	for _frame in 8: await get_tree().process_frame
	_assert(main._server_management.visible and main._server_management.get_global_rect().size == Vector2(360, 480),
		"Servers opens a full-viewport production browser")
	var return_button := _button_named(main._server_management, "Return")
	_assert(return_button != null and return_button.get_global_rect().size.x > 0.0 and
			return_button.get_global_rect().size.y > 0.0, "production browser Return button is reachable")
	_assert(main._server_management.get_global_rect().encloses(return_button.get_global_rect()), "Return is inside the small viewport")
	_assert(main.workspace.process_mode == Node.PROCESS_MODE_DISABLED and main.map.process_mode == Node.PROCESS_MODE_DISABLED,
		"menus disable background map and workspace input")
	var map_only: bool = main.workspace.map_only
	var shortcut := InputEventKey.new()
	shortcut.keycode = KEY_BACKSLASH
	shortcut.ctrl_pressed = true
	shortcut.pressed = true
	Input.parse_input_event(shortcut)
	await get_tree().process_frame
	_assert(main.workspace.map_only == map_only, "workspace shortcut does not leak through Servers")
	main._server_management._join_host.text = "http://127.0.0.1:1"
	main._server_management._join_database.text = "browser-test"
	main._server_management._join_button.pressed.emit()
	_assert(main._session_requested and main._server_management.visible and not main._menu.visible,
		"browser join connects without navigating away from its progress")
	main._fail_manual_session("Browser connection failed")
	_assert(main._server_management.visible and main._server_management._status.text == "Browser connection failed" and
		not main._server_management._join_button.disabled, "browser join failure remains visible and retryable in Servers")
	_assert(main._server_management._join_host.text == "http://127.0.0.1:1", "failed join preserves the entered host")
	main._on_native_state("offline", "Test native status")
	_assert(main._server_management._status.text == "Browser connection failed", "native status polling cannot overwrite join errors")
	return_button.pressed.emit()
	await get_tree().process_frame
	_assert(main._menu.visible and not main._server_management.visible, "browser Return restores the menu")
	_assert(not main._server_probes.visible, "Return stops HTTP polling")
	_assert(main._menu.settings == main._settings, "main menu keeps the shared settings object")
	_assert(main._diagnostics_overlay.visible and not main._diagnostics_overlay.show_graph,
		"enabled diagnostics show without enabling the subordinate graph")
	_assert(main._diagnostics_overlay.mouse_filter == Control.MOUSE_FILTER_IGNORE,
		"diagnostics overlay never consumes game input")
	main._diagnostics_stats.reset()
	main._diagnostics_stats.observe_tick(1_000_000)
	main._diagnostics_stats.observe_tick(1_016_000)
	_assert(main._diagnostics_stats.refresh(1_016_000, true).count == 1,
		"active diagnostics collect monotonic frame samples")
	main._notification(NOTIFICATION_APPLICATION_FOCUS_OUT)
	_assert(main._diagnostics_stats.refresh(1_016_000, true).count == 0,
		"focus loss resets frame samples")
	main._notification(NOTIFICATION_APPLICATION_FOCUS_IN)
	main._session_diagnostics.set_connected(true)
	main._session_diagnostics.pump(2_000_000)
	main._session_diagnostics.set_connected(false)
	_assert(main._session_diagnostics.snapshot(2_000_000).successful == 0,
		"disconnect resets session diagnostics")
	main.apply_font_size(10, false)
	_assert(main._menu.settings == main._settings and main._settings.diagnostics_enabled and
			main._settings.server_host == settings.server_host and
			main._settings.database == settings.database and main._metrics.base_font_size == 10,
		"font changes preserve all settings fields and menu ownership")
	_assert(main._settings.remember_server("http://joined.test", "joined-db", settings_path) == OK,
		"successful server save updates shared settings")
	main._menu._refresh_last_button()
	_assert(main._menu.settings.server_host == "http://joined.test" and
			main._menu.settings.database == "joined-db" and not main._menu._last_button.disabled,
		"menu sees the last server saved through the shared settings object")
	main.apply_font_size(22, false)
	_assert(main._server_management._join_host.text == "http://127.0.0.1:1" and
		main._server_management._join_button.get_theme_font_size("font_size") == 22, "browser font rebuild preserves the draft endpoint")
	_assert(main._menu.settings.diagnostics_enabled and main._menu.settings.font_size == 22 and
			main._menu.settings.server_host == "http://joined.test" and
			main._menu.settings.database == "joined-db",
		"later font changes do not toggle diagnostics or lose last server")
	main.configure_diagnostics(false, true, false)
	_assert(not main._diagnostics_overlay.visible and not main._diagnostics_overlay.processing_enabled,
		"disabled diagnostics stop overlay processing")
	main._diagnostics_stats.reset()
	main._process_diagnostics()
	_assert(main._diagnostics_stats.refresh(Time.get_ticks_usec(), true).count == 0,
		"disabled diagnostics collect no samples")
	main._menu.visible = false
	_assert(main.workspace.process_mode == Node.PROCESS_MODE_INHERIT and main.map.process_mode == Node.PROCESS_MODE_INHERIT,
		"closing menus restores gameplay input")
	main.queue_free()
	DirAccess.remove_absolute(ProjectSettings.globalize_path(settings_path))
	if failed:
		get_tree().quit(1)
		return
	print("DIAGNOSTICS_INTEGRATION_PASS")
	get_tree().quit(0)


func _assert(condition: bool, message: String) -> void:
	if not condition:
		failed = true
		push_error(message)

func _button_named(root: Node, text: String) -> Button:
	if root is Button and (root as Button).text == text:
		return root
	for child in root.get_children():
		var result := _button_named(child, text)
		if result != null:
			return result
	return null
