## Input and controller contract for the user-facing map UI.
##   godot --headless --path client/godot --scene res://tools/map_ui_test.tscn -- --stdb-host=http://127.0.0.1:3300 --stdb-db=continuum-map-ui
extends Node

const TestMainScene = preload("res://tools/ui_fixture_main.tscn")

var map: ColonyMap
var build_releases := 0
var selected_releases := 0
var build_rects: Array[Rect2i] = []
var selected_rects: Array[Rect2i] = []
var reducer_calls: Array = []
var isolated_path := ""
var failed := false


func _ready() -> void:
	if _has_user_arg("--map-ui-intentional-failure"):
		_fail("intentional failure validation")
		return
	_assert(MapUiModel.normalize_rect(Vector2i(7, 4), Vector2i(2, 1)) == Rect2i(2, 1, 6, 4),
		"reverse drag is normalized inclusively")
	_assert(MapUiModel.normalize_rect(Vector2i(3, 3), Vector2i(3, 3)) == Rect2i(3, 3, 1, 1),
		"single cell remains one cell")
	_assert(MapUiModel.cells(Rect2i(0, 0, 5, 2)) == 10, "rectangle cost uses area")
	_assert(MapUiModel.clamp_cell(Vector2i(-4, 30), Vector2i(24, 24)) == Vector2i(0, 23),
		"helper clamping remains deterministic")
	await _test_map_input()
	if failed:
		return
	await _test_controller_surface()
	if failed:
		return
	print("MAP_UI_PASS")
	get_tree().quit(0)


func _has_user_arg(value: String) -> bool:
	return value in OS.get_cmdline_user_args()


func _test_map_input() -> void:
	map = ColonyMap.new()
	map.size = Vector2(480, 570)
	map._has_state = true
	map._grid = Vector2i(24, 24)
	get_tree().root.add_child.call_deferred(map)
	await get_tree().process_frame
	map.build_rectangle_requested.connect(func(rect: Rect2i) -> void:
		build_releases += 1
		build_rects.append(rect))
	map.rectangle_selected.connect(func(rect: Rect2i) -> void:
		selected_releases += 1
		selected_rects.append(rect))
	map.set_interaction_mode(&"build")
	_drag(Vector2(130, 130), Vector2(30, 50))
	_assert(build_releases == 1, "one reversed build drag emits one atomic request")
	_assert(build_rects[0] == Rect2i(1, 0, 6, 5), "reversed drag payload is exact")
	_assert(not map._dragging, "drag state clears after release")

	_drag(Vector2(70, 70), Vector2(70, 70))
	_assert(build_releases == 2, "one-cell build drag emits one request")
	_assert(build_rects[1] == Rect2i(3, 1, 1, 1), "single-cell payload is exact")
	_release(Vector2(70, 70))
	_assert(build_releases == 2, "repeated release cannot submit another build")

	# The map now uses the full viewport; a release outside the viewport cancels.
	_press(Vector2(10, 10))
	_release(Vector2(10, 580))
	_assert(build_releases == 2, "release in legend cancels instead of building edge cells")

	_press(Vector2(10, 10))
	map._input(_key(KEY_ESCAPE))
	_release(Vector2(30, 30))
	_assert(build_releases == 2 and not map._dragging, "Escape cancels without a release request")

	_press(Vector2(10, 10))
	map._input(_button(MOUSE_BUTTON_RIGHT, true, Vector2(10, 10)))
	_release(Vector2(30, 30))
	_assert(build_releases == 2 and not map._dragging, "right-click cancels")

	_press(Vector2(10, 10))
	map._input(_button(MOUSE_BUTTON_RIGHT, true, Vector2(700, 700)))
	_release(Vector2(30, 30))
	_assert(build_releases == 2 and not map._dragging, "right-click on workspace cancels")

	_press(Vector2(10, 10))
	map.notification(NOTIFICATION_WM_WINDOW_FOCUS_OUT)
	_release(Vector2(30, 30))
	_assert(build_releases == 2 and not map._dragging, "focus loss cancels stale drag")
	map.set_interaction_mode(&"select")
	_drag(Vector2(210, 210), Vector2(250, 250))
	_assert(selected_releases == 1, "select mode emits one rectangular selection")
	_assert(selected_rects[0] == Rect2i(10, 8, 3, 3), "selection payload is exact")


func _test_controller_surface() -> void:
	var main := TestMainScene.instantiate()
	get_tree().root.add_child.call_deferred(main)
	await get_tree().process_frame
	isolated_path = main.fixture_workspace_path
	main.apply_font_size(10, false)
	_assert(main._metrics.base_font_size == 10, "runtime font can shrink to the lower bound")
	main.apply_font_size(24, false)
	_assert(main._metrics.base_font_size == 24 and main._feed.custom_minimum_size.y > 120 and
			main._history_chart.custom_minimum_size.y > 300 and main._clock.custom_minimum_size.x > 250 and
			main.workspace.telemetry.get_parent().custom_minimum_size.y > 60,
		"runtime max scale updates feed, chart, clock, and telemetry minima")
	main.apply_font_size(10, false)
	_assert(main._metrics.base_font_size == 10 and main._feed.custom_minimum_size.y < 70,
		"runtime scaling returns to small metrics without compounding")
	main.apply_font_size(13, false)
	_assert(main._mode_buttons.size() == 2, "select and build mode buttons are reachable")
	_set_role(main, "operator", true, false)
	_assert(main._build_menu.item_count == 7, "all seven non-empty build types are reachable")
	main._build_menu.select(1)
	main._build_menu.item_selected.emit(1)
	_assert(main.map.build_kind == ContinuumTileKind.Options.forest, "type picker arms forestry")
	main._set_mode(&"build")
	_assert(main.map.interaction_mode == &"build", "build button changes map mode")
	main._set_mode(&"select")
	_assert(main.map.interaction_mode == &"select", "select button changes map mode")
	_assert(main._block_box.visible and main._block_info != null, "block control panel is visible")
	_assert(main._block_controls.size() == 6, "enable/disable and four work controls are reachable")
	_assert(main._tile_action_box.visible and main._tile_info != null, "one-cell inspection detail remains visible")
	_assert(main._block_controls[ContinuumWorkType.Options.farming].row.visible,
		"block work controls are not hidden by legacy refresh")
	await _test_workspace_surface(main)
	if failed:
		return
	main._map_dirty = false
	main._on_table_changed("terrain")
	_assert(main._map_dirty, "terrain updates invalidate map rendering")
	_assert(main.can_send_map_intent(true, false), "ready client may send map intent")
	_assert(not main.can_send_map_intent(false, false) and not main.can_send_map_intent(true, true),
		"disconnected and pending clients are gated")
	await _refresh_real_tiles(main)
	DirAccess.remove_absolute(ProjectSettings.globalize_path(isolated_path))


func _test_workspace_surface(main: Control) -> void:
	_assert(main._sections.size() == 8 and main.workspace.windows.size() == 8,
		"workspace manager exposes eight extensible panels")
	_assert(main.workspace.model.workspaces.size() == 4 and main.workspace.model.active == "daily",
		"workspace manager starts on the daily built-in layout")
	_assert(not main._build_help.text.contains("\n") and not main._orders_help.text.contains("\n"),
		"help surfaces use compact labels rather than text blocks")
	_assert(not main._build_help.tooltip_text.is_empty() and not main._orders_help.tooltip_text.is_empty(),
		"compact help labels retain hover details")
	main._set_feedback(main._intent_feedback, "Failed", "Full reducer error detail")
	_assert(main._intent_feedback.text == "Failed" and
			main._intent_feedback.tooltip_text == "Full reducer error detail",
		"error status stays concise while retaining details")
	_set_role(main, "viewer", false, false)
	_assert(not main.workspace.authorized["policies"] and not main.workspace.authorized["operations"],
		"viewer workspace authorization fails closed")
	_assert(not main._mode_buttons[&"build"].visible and
			not main._build_menu.visible and not main._block_box.visible,
		"viewer cannot see mutation controls")
	main.map_intent_override = _record_reducer_call
	var before := reducer_calls.size()
	main._dispatch_build_block(Rect2i(1, 1, 1, 1), ContinuumTileKind.create_farm())
	_assert(reducer_calls.size() == before, "programmatic build is guarded for viewers")
	_set_role(main, "operator", true, false)
	_assert(main.workspace.authorized["policies"] and main.workspace.authorized["operations"],
		"operator inherits policy and operations workspace access")
	main._set_mode(&"build")
	_set_role(main, "viewer", false, false)
	_assert(main.map.interaction_mode == &"select", "permission loss cancels armed Build mode")
	_set_role(main, "operator", true, false)
	var ack_probe := Button.new()
	ack_probe.text = "Ack"
	main._alert_box.add_child(ack_probe)
	_assert(ack_probe.is_inside_tree(), "operator alert rows are present before downgrade")
	_set_role(main, "viewer", false, false)
	await get_tree().process_frame
	_assert(not is_instance_valid(ack_probe), "permission downgrade immediately rebuilds alert rows")
	_set_role(main, "operator", true, false)
	_set_role(main, "maintenance", true, false)
	_assert(not main._can_operate and main._role_name == "Unknown",
		"unknown role input fails closed")
	_set_role(main, "admin", true, false)
	_assert(not main._can_operate and not main._is_admin,
		"inconsistent admin flags fail closed")
	_set_role(main, "admin", true, true)
	_assert(main.workspace.authorized["policies"] and main.workspace.authorized["operations"] and
			main._speed_strip.visible, "admin can see workspace panels and header speed controls")
	_assert(main._build_menu.disabled, "disconnected or pending state disables build picker")
	var desktop_size := main.size
	main.size = Vector2(390, 844)
	await get_tree().process_frame
	await get_tree().process_frame
	_assert(main.workspace.compact and main.workspace.area.size.x == 390,
		"production UI fits a phone viewport without a fixed-width sidebar")
	_assert(main.workspace.area.position.y < 140,
		"telemetry text cannot inflate the header through narrow wrapping")
	main.size = desktop_size
	await get_tree().process_frame
	await get_tree().process_frame
	for window: WorkspaceWindow in main.workspace.windows.values():
		window.size = WorkspaceLayout.MIN_SIZE
	await get_tree().process_frame
	await get_tree().process_frame
	for window: WorkspaceWindow in main.workspace.windows.values():
		_assert(window.content.get_combined_minimum_size().x <= window.scroll.size.x,
			"panel contents fit minimum width: %s" % window.name)
	main.workspace._apply_layout()


func _refresh_real_tiles(main: Control) -> void:
	var client: ContinuumModuleClient = SpacetimeDB.Continuum
	var frames := 0
	while (client.db == null or client.db.tile.iter().is_empty()) and frames < 120:
		await get_tree().process_frame
		frames += 1
	_assert(client.db != null and not client.db.tile.iter().is_empty(),
		"private subscribed fixture provides tiles for refresh tests")
	if failed:
		return
	var occupied: ContinuumTile = null
	var empty: ContinuumTile = null
	for tile: ContinuumTile in client.db.tile.iter():
		if tile.kind.value == ContinuumTileKind.Options.empty and empty == null:
			empty = tile
		if tile.kind.value != ContinuumTileKind.Options.empty and occupied == null:
			occupied = tile
	_assert(occupied != null and empty != null, "fixture has occupied and empty tiles")
	main._selected_rect = Rect2i(Vector2i(occupied.x, occupied.y), Vector2i.ONE)
	main._selected_tile_id = occupied.id
	main._refresh_controls()
	_assert(main._block_box.visible and main._tile_info.text.contains("Selected:"),
		"occupied refresh keeps block primary and inspection detail")
	var compatible := ColonyMap.compatible_work(occupied.kind.value)
	if not compatible.is_empty():
		_assert(not main._block_controls[compatible[0]].set.disabled,
			"occupied refresh enables compatible block work control")
	main._selected_rect = Rect2i(Vector2i(empty.x, empty.y), Vector2i.ONE)
	main._selected_tile_id = empty.id
	main._refresh_controls()
	_assert(main._block_box.visible and main._tile_info.text.contains("Selected:"),
		"empty refresh keeps block primary and inspection detail")
	if not compatible.is_empty():
		_assert(main._block_controls[compatible[0]].set.disabled,
			"empty refresh disables incompatible block work control")
	main._dispatch_build_block(Rect2i(7, 4, 2, 3), ContinuumTileKind.create_farm())
	_assert(reducer_calls.size() == 1, "controller dispatches one reducer invocation")
	_assert(reducer_calls[0][0] == "build_tile_block" and
			reducer_calls[0][1].slice(0, 4) == [7, 4, 8, 6],
		"reducer receives normalized inclusive rectangle payload")
	main._dispatch_build_block(Rect2i(3, 3, 1, 1), ContinuumTileKind.create_mine())
	_assert(reducer_calls.size() == 2, "each completed block maps to one reducer invocation")


func _set_role(main: Control, role: String, can_operate: bool, is_admin: bool) -> void:
	main.fixture_access.set_role(role, can_operate, is_admin)


func _record_reducer_call(name: String, args: Array) -> void:
	reducer_calls.append([name, args])


func _drag(start: Vector2, finish: Vector2) -> void:
	_press(start)
	map._input(_motion(finish))
	_release(finish)


func _press(position: Vector2) -> void:
	map._gui_input(_button(MOUSE_BUTTON_LEFT, true, position))


func _release(position: Vector2) -> void:
	map._input(_button(MOUSE_BUTTON_LEFT, false, position))


func _button(button: MouseButton, pressed: bool, position: Vector2) -> InputEventMouseButton:
	var event := InputEventMouseButton.new()
	event.button_index = button
	event.pressed = pressed
	event.position = position
	return event


func _motion(position: Vector2) -> InputEventMouseMotion:
	var event := InputEventMouseMotion.new()
	event.position = position
	return event


func _key(keycode: Key) -> InputEventKey:
	var event := InputEventKey.new()
	event.keycode = keycode
	event.pressed = true
	return event


func _assert(condition: bool, message: String) -> void:
	if not condition:
		_fail(message)


func _fail(message: String) -> void:
	if failed:
		return
	failed = true
	printerr("MAP_UI_FAIL: %s" % message)
	get_tree().quit(1)
