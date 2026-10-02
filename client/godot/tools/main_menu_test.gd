extends Node

const MenuScene = preload("res://scenes/main_menu.tscn")

var failed := false

func _ready() -> void:
	var settings := ClientSettings.new()
	var path := "user://main_menu_test_%d.cfg" % Time.get_ticks_usec()
	settings.save_to(path)
	var restored := ClientSettings.new()
	restored.load_from(path)
	_assert(restored.server_host.is_empty() and restored.database.is_empty(), "last server is absent by default")
	_assert(restored.font_size == ClientSettings.DEFAULT_FONT_SIZE, "default font size is stable")
	_assert(UiMetrics.new(ClientSettings.MIN_FONT_SIZE).base_font_size == ClientSettings.MIN_FONT_SIZE, "font minimum clamps")
	_assert(UiMetrics.new(ClientSettings.MAX_FONT_SIZE).base_font_size == ClientSettings.MAX_FONT_SIZE, "font maximum clamps")
	restored.remember_server("http://example.test", "continuum", path)
	var persisted := ClientSettings.new()
	persisted.load_from(path)
	_assert(persisted.server_host == "http://example.test" and persisted.database == "continuum", "successful endpoint persists")
	DirAccess.remove_absolute(ProjectSettings.globalize_path(path))

	var menu: ContinuumMainMenu = MenuScene.instantiate()
	add_child(menu)
	menu.setup(null, ClientSettings.new(), UiMetrics.new())
	var buttons := menu.find_children("*", "Button", true, false)
	var expected_buttons := ["Join last server", "Servers", "Settings", "Exit", "Reduce motion", "Show diagnostics", "Show frame/RTT graph", "100%"]
	_assert(buttons.size() == expected_buttons.size(), "menu contains only navigation, join-last, and display/diagnostics controls")
	for button: Button in buttons:
		_assert(expected_buttons.has(button.text), "no direct join, local lifecycle, or autostart control: " + button.text)
	for line: LineEdit in menu.find_children("*", "LineEdit", true, false):
		_assert(menu._ui_scale.is_ancestor_of(line), "only the UI-scale popup may contain an internal search input: " + str(line.get_path()))
	var server_menu_opened := [0]
	menu.server_management_requested.connect(func() -> void: server_menu_opened[0] += 1)
	_button(menu, "Servers").pressed.emit()
	_assert(server_menu_opened[0] == 1, "Servers entry emits standalone browser navigation")
	var exit_requests := [0]
	menu.exit_requested.connect(func() -> void: exit_requests[0] += 1)
	_button(menu, "Exit").pressed.emit()
	_assert(exit_requests[0] == 1, "Exit remains available")
	var joins: Array[Dictionary] = []
	menu.join_requested.connect(func(host: String, database: String) -> void:
		joins.append({"host": host, "database": database})
		_assert(menu._last_button.disabled, "join-last is busy before dispatch")
		_assert(menu._status.text == "Connecting to %s / %s ..." % [host, database], "join status includes the stored endpoint"))
	_assert(menu._last_button.disabled, "join last is disabled without a successful endpoint")
	menu._join_last()
	menu.set_busy(false)
	_assert(joins.is_empty() and menu._last_button.disabled, "clearing busy does not enable an absent last endpoint")
	_assert(menu._ui_scale.item_count == 3 and menu._ui_scale.get_item_id(2) == 150,
		"settings expose only 100/125/150 percent UI scales")
	_button(menu, "Settings").pressed.emit()
	_assert(menu._settings_panel.visible, "settings are reachable from the menu")
	_assert(not menu._diagnostics_toggle.button_pressed and menu._graph_toggle.disabled, "diagnostics graph is subordinate by default")
	var settings_changes := [0]
	menu.settings_changed.connect(func(_settings: ClientSettings) -> void: settings_changes[0] += 1)
	menu._diagnostics_toggle.button_pressed = true
	_assert(menu.settings.diagnostics_enabled and not menu._graph_toggle.disabled, "diagnostics toggle enables graph control")
	menu._graph_toggle.button_pressed = true
	_assert(menu.settings.diagnostics_graph_enabled, "graph toggle persists independently")
	menu._diagnostics_toggle.button_pressed = false
	_assert(not menu.settings.diagnostics_enabled and not menu.settings.diagnostics_graph_enabled and menu._graph_toggle.disabled, "disabling diagnostics clears subordinate graph")
	menu._ui_scale.item_selected.emit(2)
	_assert(menu.settings.ui_scale_percent == 150 and menu.settings.font_size == 13, "scale control keeps base token fonts normalized")
	menu._reduced_motion.button_pressed = true
	_assert(menu.settings.reduced_motion and settings_changes[0] >= 5, "motion and scale controls emit settings updates")
	menu.apply_metrics(UiMetrics.new(24))
	_assert(menu.theme.default_font_size == 13 and menu.metrics.scale == 1, "legacy metrics cannot double-scale the new menu")
	menu._toggle_settings()

	for endpoint: Array in [["localhost:3000", "continuum"], ["http://localhost", "bad name"]]:
		menu.settings.server_host = endpoint[0]
		menu.settings.database = endpoint[1]
		menu.show_menu()
		menu._last_button.pressed.emit()
		_assert(joins.is_empty() and not menu._last_button.disabled, "invalid stored endpoints do not dispatch or stay busy")
		_assert(menu._error.text == ContinuumServerManagement.validate_endpoint(endpoint[0], endpoint[1]), "join-last uses shared browser validation")
	menu.settings.server_host = "  https://[2001:db8::1]:443  "
	menu.settings.database = "  continuum-home  "
	menu.visible = false
	menu.show_menu()
	_assert(menu.visible and not menu._last_button.disabled, "show_menu refreshes the remembered endpoint")
	_assert(menu._last_button.tooltip_text.contains("continuum-home"), "join-last tooltip identifies the endpoint")
	menu._last_button.pressed.emit()
	_assert(joins == [{"host": "https://[2001:db8::1]:443", "database": "continuum-home"}], "join-last emits the trimmed stored endpoint without line edits")
	_assert(menu._error.text.is_empty(), "valid join clears prior validation errors")
	menu._join_last()
	_assert(joins.size() == 1, "busy join-last cannot dispatch twice")
	for text: String in ["Servers", "Settings", "Exit"]:
		_assert(not _button(menu, text).disabled, "busy leaves " + text + " available")
	_assert(not menu._ui_scale.disabled and not menu._diagnostics_toggle.disabled, "busy leaves display and diagnostics settings available")
	menu.join_failed("Connection failed")
	_assert(not menu._last_button.disabled and menu._status.text == "Warning · Connection failed", "failed joins release busy and show the failure")
	_assert(menu._status.get_theme_color("font_color") == ThemeTokens.color("warn") and menu._status_glyph.texture != null, "failed join uses warning glyph and token")
	menu._last_button.pressed.emit()
	_assert(joins.size() == 2, "failed join can be retried")
	menu.show_menu()
	_assert(not menu._last_button.disabled, "returning to the menu releases busy")
	menu.queue_free()
	await _test_layout()

	if failed:
		get_tree().quit(1)
		return
	print("MAIN_MENU_PASS")
	get_tree().quit(0)

func _test_layout() -> void:
	for font_size: int in [100, 125, 150]:
		var menu: ContinuumMainMenu = MenuScene.instantiate()
		add_child(menu)
		menu.set_anchors_and_offsets_preset(Control.PRESET_TOP_LEFT)
		var logical_size := Vector2(360, 480) / (float(font_size) / 100.0)
		menu.size = logical_size
		var settings := ClientSettings.new()
		settings.ui_scale_percent = font_size
		menu.setup(null, settings, settings.ui_metrics())
		menu._toggle_settings()
		menu.set_status("Connecting to http://" + "longhostname".repeat(8) + " / continuum-home ...")
		menu._error.text = "A long connection failure remains readable without widening the launch menu."
		for _frame in 4:
			await get_tree().process_frame
		var scroll: ScrollContainer = menu.find_child("MenuScroll", true, false)
		_assert(scroll != null and scroll.follow_focus, "small menu provides keyboard-following scrolling")
		_assert(menu.get_global_rect().encloses(scroll.get_global_rect()), "scroll viewport fits 360x480 at font %d" % font_size)
		for control: Control in menu.find_children("*", "Control", true, false):
			if not control.is_visible_in_tree():
				continue
			var rect := control.get_global_rect()
			_assert(rect.position.x >= -0.5 and rect.end.x <= logical_size.x + 0.5, "scale %d control fits horizontally: %s" % [font_size, control.name])
		_assert(menu._status.get_line_count() > 1 and menu._error.get_line_count() > 1, "status and errors wrap in narrow menus")
		_assert(not scroll.get_h_scroll_bar().visible, "narrow menu never needs horizontal scrolling")
		scroll.ensure_control_visible(menu._graph_toggle)
		await get_tree().process_frame
		_assert(scroll.scroll_vertical > 0 and scroll.get_global_rect().encloses(menu._graph_toggle.get_global_rect()), "scrolling reaches the final settings control at font %d" % font_size)
		menu.queue_free()
		await get_tree().process_frame

func _button(menu: ContinuumMainMenu, text: String) -> Button:
	for button: Button in menu.find_children("*", "Button", true, false):
		if button.text == text:
			return button
	return null

func _assert(condition: bool, message: String) -> void:
	if not condition:
		failed = true
		printerr("FAIL: " + message)
