## Input and controller contract for the user-facing map UI.
##   godot --headless --path client/godot --scene res://tools/map_ui_test.tscn -- --stdb-host=http://127.0.0.1:3300 --stdb-db=continuum-map-ui
extends Node

const MainScene = preload("res://scenes/main.tscn")

var map: ColonyMap
var build_releases := 0
var selected_releases := 0
var reducer_calls: Array = []
var build_rects: Array[Rect2i] = []
var selected_rects: Array[Rect2i] = []
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
	_assert(build_rects[0] == Rect2i(1, 2, 6, 5), "reversed drag payload is exact")
	_assert(not map._dragging, "drag state clears after release")

	_drag(Vector2(70, 70), Vector2(70, 70))
	_assert(build_releases == 2, "one-cell build drag emits one request")
	_assert(build_rects[1] == Rect2i(3, 3, 1, 1), "single-cell payload is exact")

	# The drawn grid is 480x480; the remaining 90 pixels are the legend and must cancel.
	_press(Vector2(10, 10))
	_release(Vector2(10, 520))
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
	_assert(build_releases == 2 and not map._dragging, "right-click on side panel cancels")

	_press(Vector2(10, 10))
	map.notification(NOTIFICATION_WM_WINDOW_FOCUS_OUT)
	_release(Vector2(30, 30))
	_assert(build_releases == 2 and not map._dragging, "focus loss cancels stale drag")

	map.set_interaction_mode(&"select")
	_drag(Vector2(210, 210), Vector2(250, 250))
	_assert(selected_releases == 1, "select mode emits one rectangular selection")
	_assert(selected_rects[0] == Rect2i(10, 10, 3, 3), "selection payload is exact")


func _test_controller_surface() -> void:
	var main := MainScene.instantiate()
	get_tree().root.add_child.call_deferred(main)
	await get_tree().process_frame
	_assert(main._mode_buttons.size() == 2, "select and build mode buttons are reachable")
	main._set_permissions("operator", true, false)
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
	_test_sidebar_surface(main)
	if failed:
		return
	main._map_dirty = false
	main._on_table_changed("terrain")
	_assert(main._map_dirty, "terrain updates invalidate map rendering")
	_assert(main.can_send_map_intent(true, false), "ready client may send map intent")
	_assert(not main.can_send_map_intent(false, false) and not main.can_send_map_intent(true, true),
		"disconnected and pending clients are gated")
	await _refresh_real_tiles(main)


func _test_sidebar_surface(main: Control) -> void:
	_assert(main.sidebar.sections.size() == 7, "sidebar exposes seven extensible sections")
	_assert(main.sidebar.sections.has("overview") and main.sidebar.sections.has("administration"),
		"sidebar section keys are stable for extensions")
	main.sidebar._toggle_section("people")
	_assert(not main.sidebar.sections["people"].content.visible, "section collapse hides its content")
	main.sidebar._toggle_section("people")
	_assert(main.sidebar.sections["people"].content.visible, "section reopens from its header")
	main.sidebar.search.text = "forest"
	main.sidebar.search.text_changed.emit("forest")
	_assert(main.sidebar.sections["operations"].wrapper.visible, "search matches control aliases")
	main.sidebar.search.clear()
	main.sidebar.search.text_changed.emit("")
	_assert(main.sidebar.sections["people"].content.visible, "clear restores pre-search section state")
	main.sidebar.search.text = "no-such-control"
	main.sidebar.search.text_changed.emit("no-such-control")
	_assert(main.sidebar._no_matches.visible, "zero-result search is explicit")
	main.sidebar.search.clear()
	main.sidebar.search.text_changed.emit("")
	main.sidebar.toggle()
	_assert(main.sidebar.custom_minimum_size.x == main.sidebar.CLOSED_WIDTH,
		"sidebar collapses to a reachable narrow rail")
	main.sidebar.toggle()
	_assert(main.sidebar.custom_minimum_size.x == main.sidebar.OPEN_WIDTH, "sidebar reopens")
	main._set_permissions("viewer", false, false)
	_assert(not main.sidebar.sections["policies"].wrapper.visible and
			not main.sidebar.sections["administration"].wrapper.visible,
		"viewer cannot discover unauthorized policy or admin sections")
	_assert(not main._mode_buttons[&"build"].visible and not main._build_menu.visible,
		"viewer cannot see mutation controls")
	main.map_intent_override = _record_reducer_call
	var before := reducer_calls.size()
	main._dispatch_build_block(Rect2i(1, 1, 1, 1), ContinuumTileKind.create_farm())
	_assert(reducer_calls.size() == before, "programmatic build is guarded for viewers")
	main._set_permissions("operator", true, false)
	_assert(main.sidebar.sections["policies"].wrapper.visible and
			not main.sidebar.sections["administration"].wrapper.visible,
		"operator inherits policy access but not admin access")
	main._set_mode(&"build")
	main._set_permissions("viewer", false, false)
	_assert(main.map.interaction_mode == &"select", "permission loss cancels armed Build mode")
	main._set_permissions("admin", true, true)
	_assert(main.sidebar.sections["administration"].wrapper.visible and
		main._speed_buttons[0].visible, "admin can see administration controls")
	_assert(main._build_menu.disabled, "disconnected or pending state disables build picker")


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
	main.map_intent_override = _record_reducer_call
	main._dispatch_build_block(Rect2i(7, 4, 2, 3), ContinuumTileKind.create_farm())
	_assert(reducer_calls.size() == 1, "controller dispatches one reducer invocation")
	_assert(reducer_calls[0][0] == "build_tile_block" and reducer_calls[0][1].slice(0, 4) == [7, 4, 8, 6],
		"reducer receives normalized inclusive rectangle payload")
	main._dispatch_build_block(Rect2i(3, 3, 1, 1), ContinuumTileKind.create_mine())
	_assert(reducer_calls.size() == 2, "each completed release maps to one reducer invocation")


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
