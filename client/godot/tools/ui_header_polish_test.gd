extends "res://tools/ui_composition_fixture.gd"

func _check_functional_contracts() -> void:
	main._set_permissions("viewer", false, false)
	main.workspace.switch_workspace("diagnostics")
	main._session_observations = SessionObservations.new()
	local._tables.config[0].game_seconds = 30600.0
	main._refresh_status()
	main.configure_diagnostics(true, false, false)
	main.set_process(false)
	main._diagnostics_focus_paused = true
	main._diagnostics_overlay.set_snapshots({"ready": true, "mean_fps": 112.0, "p95_frame_ms": 8.9}, {"rtt_ms": 7.9})
	for frame in 12: await get_tree().process_frame
	check(main.forbidden_connections == 0, "private fixture never connects")
	if "--before" in OS.get_cmdline_user_args(): return
	_check_geometry()
	if main.size.x >= 1280:
		main.configure_diagnostics(true, true, false)
		await _settle()
		check(main._diagnostics_overlay.graph_lane_rects().size() == 2, "wide diagnostics retain both optional sparkline lanes inside the utility surface")
		main.configure_diagnostics(true, false, false)
		await _settle()
	await _check_keyboard_and_map()
	await _check_budget_edges()
	main._diagnostics_overlay.set_snapshots({"ready": true, "mean_fps": 112.0, "p95_frame_ms": 8.9}, {"rtt_ms": 7.9})
	main._session_menu.release_focus()
	await _settle()
	print("UI_HEADER_POLISH_PASS failures=%d" % failures.size())

func _settle() -> void:
	for frame in 12: await get_tree().process_frame

func _check_geometry() -> void:
	var deck: WorkspaceDeck = main.workspace
	var header := deck.header.get_global_rect()
	var utilities := deck._utilities.get_global_rect()
	var panels := deck._menu.get_global_rect()
	var menu: Rect2 = main._session_menu.get_global_rect()
	check(is_equal_approx(header.position.y, 0) and is_equal_approx(header.size.x, main.size.x), "header spans the actual logical viewport")
	check(utilities.position.y >= 8 and header.end.x - utilities.end.x >= 12, "utility group has real top/right insets")
	check(panels.end.x + 8 <= menu.position.x and absf(panels.get_center().y - menu.get_center().y) < 1, "Panels and Menu are adjacent vertically aligned utilities with an 8px gutter")
	check(is_equal_approx(panels.size.y, 32) and is_equal_approx(menu.size.y, 32), "utility controls have equal 32px hit heights")
	check(deck._menu.get_parent() == main._session_menu.get_parent() and panels.end.y + 8 <= deck._tabs.global_position.y, "Panels is above the view tabs, inside the deliberate utility cluster")
	var surfaces: Array[Control] = [main._clock_group, main._session_group]
	surfaces.append_array(main._resource_labels.values())
	for surface in surfaces:
		var rect := surface.get_global_rect()
		check(header.encloses(rect) and rect.position.x >= 12, "every status group is wholly visible with an outer inset: " + surface.name)
		check(rect.size.y >= 44, "two-line status surface has a comfortable minimum height")
		var style: StyleBoxFlat = surface.get_theme_stylebox("panel")
		check(style.bg_color != deck.header.get_theme_stylebox("panel").bg_color and style.border_width_left == 1, "status groups are visibly distinct surfaces with subtle boundaries")
		_check_labels(surface, rect)
	_check_labels(deck.utility_row, utilities)
	_check_labels(deck._tabs, header)
	var status := deck._rows[0].get_global_rect()
	check(status.position.x >= 12, "status group has a real left inset")
	check(status.end.x <= utilities.position.x - 12 if utilities.position.y == status.position.y else header.encloses(status), "status and utility groups have a real gutter, including stacked mode")
	var food: ResourceReadout = main._resource_labels[0]
	var food_rect := food.get_global_rect()
	var last: Rect2
	for kind in 4:
		var card: ResourceReadout = main._resource_labels[kind]
		var rect := card.get_global_rect()
		if kind > 0 and rect.position.y == last.position.y:
			check(rect.position.x - last.end.x >= 4, "resource surfaces have non-overlapping horizontal gutters")
		last = rect
	if food_rect.position.y == main._clock_group.global_position.y and food._config.get("show_rate", false):
		var clock_baseline := _baseline(main._clock)
		for card: ResourceReadout in main._resource_labels.values():
			var stock: Label = card.get_child(0).get_child(0).get_child(1)
			check(absf(_baseline(stock) - clock_baseline) <= 2, "time and resource values share a primary text baseline")
			var rate: Label = card.get_child(0).get_child(1)
			check(rate.global_position.y > stock.global_position.y and rate.get_theme_color("font_color") != stock.get_theme_color("font_color"), "warmup is a separate secondary line, never a competing value")
	for window: WorkspaceWindow in deck.windows.values():
		if not window.is_visible_in_tree(): continue
		var frame := window.get_global_rect()
		var body := window.scroll.get_global_rect()
		check(body.position.x - frame.position.x >= 12 and frame.end.x - body.end.x >= 12, "floating content has balanced horizontal insets")
		check(body.position.y - window.header_ground.get_global_rect().end.y == 16, "floating body has 16px breathing room below its titlebar")
		check(window.titlebar.offset_left == 12 and window.titlebar.size.y == 24, "floating title and controls share a padded 24px row clear of resize edges")
		check(window.content.get_theme_constant("separation") == 12, "floating body sections have a consistent vertical rhythm")
	check(main.map.get_global_rect() == deck.area.get_global_rect() and deck.area.global_position.y == header.end.y, "map starts exactly below the measured header and fills all remaining space")

func _check_labels(node: Node, bounds: Rect2) -> void:
	if node is Control and not node.is_visible_in_tree(): return
	if node is Label:
		check(bounds.encloses(node.get_global_rect()), "label stays inside its surface: " + node.text)
		check(node.get_combined_minimum_size().x <= node.size.x + 0.1, "label is not horizontally clipped: " + node.text)
	for child in node.get_children(): _check_labels(child, bounds)

func _baseline(label: Label) -> float:
	var font := label.get_theme_font("font")
	var font_size := label.get_theme_font_size("font_size")
	return label.global_position.y + (label.size.y - font.get_height(font_size)) * 0.5 + font.get_ascent(font_size)

func _check_keyboard_and_map() -> void:
	var panels: MenuButton = main.workspace._menu
	var popup := panels.get_popup()
	var workspace_id: String = main.workspace.model.active
	for opening in ["pointer", "Ctrl+P"]:
		if opening == "pointer":
			var point := panels.get_global_rect().get_center()
			await _native_pointer(_pointer_button(true, point))
			await _native_pointer(_pointer_button(false, point))
		else:
			await _native_key(KEY_P, true)
		await _settle()
		check(popup.visible, opening + " opens the actual Panels chooser through native input dispatch")
		check(main._map_input_blocked(main.map.get_global_rect().get_center()), "open Panels chooser excludes map input")
		await _native_key(KEY_ESCAPE)
		await _settle()
		check(not popup.visible, "native Escape closes the " + opening + " Panels popup")
		check(get_viewport().gui_get_focus_owner() == panels, "Escape retains keyboard focus on the Panels button after " + opening)
		check(main.workspace.model.active == workspace_id and not main._menu.visible, "popup Escape does not switch views or open the session menu")
	main.workspace.toggle_map_only()
	await _settle()
	var map_rect: Rect2 = main.map.get_global_rect()
	check(main._map_input_blocked(Vector2(main.size.x / 2, map_rect.position.y - 1)), "entire padded header excludes map input up to its bottom edge")
	check(not main._map_input_blocked(map_rect.end - Vector2(12, 12)), "uncovered map below header remains interactive")
	var world := Vector2(8.5, 8.5)
	var global_point: Vector2 = main.map.get_global_transform() * main.map.world_to_screen(world)
	check(main.map.screen_to_world(main.map.get_global_transform().affine_inverse() * global_point).distance_to(world) < 0.001, "map picking round-trips after the taller header at actual UI scale")
	main.workspace.toggle_map_only()
	await _settle()

func _native_key(key: Key, ctrl := false) -> void:
	var popup: PopupMenu = main.workspace._menu.get_popup()
	var target: Window = popup if popup.visible and not popup.is_embedded() else get_window()
	for pressed in [true, false]:
		var event := InputEventKey.new()
		event.window_id = target.get_window_id()
		event.keycode = key
		event.ctrl_pressed = ctrl
		event.pressed = pressed
		Input.parse_input_event(event)
		await get_tree().process_frame

func _check_budget_edges() -> void:
	var colony: ContinuumColony = local._tables.colony[0]
	var config: ContinuumConfig = local._tables.config[0]
	var originals := [colony.food, colony.wood, colony.stone, colony.meat]
	var names := ["food", "wood", "stone", "meat"]
	var saved_clock := config.game_seconds
	for value: float in [1.0, 1e12, 150.0]:
		config.generation += 1
		main._session_observations = SessionObservations.new()
		for minute in range(61):
			config.game_seconds = minute * 60.0
			for resource in names: colony.set(resource, lerpf(100.0 if value < 100 else value - 100, value, minute / 60.0))
			main._observe_session_state()
		main._refresh_status()
		await _settle()
		var viewport: Rect2 = main.workspace._rows[0].get_global_rect()
		for card: ResourceReadout in main._resource_labels.values():
			check(viewport.encloses(card.get_global_rect()), "all stocks and forecasts fit under changing live budgets")
			_check_labels(card, viewport)
		var food: ResourceReadout = main._resource_labels[0]
		var retained := food.get_child(0)
		main._session_menu.grab_focus()
		main._refresh_status()
		await _settle()
		check(food.get_child(0) == retained and get_viewport().gui_get_focus_owner() == main._session_menu, "unchanged ticks preserve visible stock nodes and keyboard focus")
		check(main.map.size.y > 50, "adversarial status reflow still leaves a usable map/body viewport")
	main._connection_label.text = "Connection problem"
	main._identity_label.text = "Read-only"
	main._queue_status_balance()
	await _settle()
	_check_labels(main._clock_group, main.workspace.header.get_global_rect())
	_check_labels(main._session_group, main.workspace.header.get_global_rect())
	for index in 4: colony.set(names[index], originals[index])
	config.game_seconds = saved_clock
	main._session_observations = SessionObservations.new()
	main._refresh_status()
	await _settle()
