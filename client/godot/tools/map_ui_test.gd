## Input and controller contract for the user-facing map UI.
##   godot --headless --path client/godot --script res://tools/map_ui_test.gd
extends Node

const MainScene = preload("res://scenes/main.tscn")

var map: ColonyMap
var build_releases := 0
var selected_releases := 0


func _ready() -> void:
	_assert(MapUiModel.normalize_rect(Vector2i(7, 4), Vector2i(2, 1)) == Rect2i(2, 1, 6, 4),
		"reverse drag is normalized inclusively")
	_assert(MapUiModel.normalize_rect(Vector2i(3, 3), Vector2i(3, 3)) == Rect2i(3, 3, 1, 1),
		"single cell remains one cell")
	_assert(MapUiModel.cells(Rect2i(0, 0, 5, 2)) == 10, "rectangle cost uses area")
	_assert(MapUiModel.clamp_cell(Vector2i(-4, 30), Vector2i(24, 24)) == Vector2i(0, 23),
		"helper clamping remains deterministic")
	await _test_map_input()
	await _test_controller_surface()
	print("MAP_UI_PASS")
	get_tree().quit(0)


func _test_map_input() -> void:
	map = ColonyMap.new()
	map.size = Vector2(480, 570)
	map._has_state = true
	map._grid = Vector2i(24, 24)
	get_tree().root.add_child.call_deferred(map)
	await get_tree().process_frame
	map.build_rectangle_requested.connect(func(_rect: Rect2i) -> void: build_releases += 1)
	map.rectangle_selected.connect(func(_rect: Rect2i) -> void: selected_releases += 1)

	map.set_interaction_mode(&"build")
	_drag(Vector2(130, 130), Vector2(30, 50))
	_assert(build_releases == 1, "one reversed build drag emits one atomic request")
	_assert(not map._dragging, "drag state clears after release")

	_drag(Vector2(70, 70), Vector2(70, 70))
	_assert(build_releases == 2, "one-cell build drag emits one request")

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

	map.set_interaction_mode(&"select")
	_drag(Vector2(210, 210), Vector2(250, 250))
	_assert(selected_releases == 1, "select mode emits one rectangular selection")


func _test_controller_surface() -> void:
	var main := MainScene.instantiate()
	get_tree().root.add_child.call_deferred(main)
	await get_tree().process_frame
	_assert(main._mode_buttons.size() == 2, "select and build mode buttons are reachable")
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
	_assert(not main._tile_button.visible and not main._build_box.visible,
		"single-tile mutators are replaced, not primary")
	main._map_dirty = false
	main._on_table_changed("terrain")
	_assert(main._map_dirty, "terrain updates invalidate map rendering")
	_assert(main.can_send_map_intent(true, false), "ready client may send map intent")
	_assert(not main.can_send_map_intent(false, false) and not main.can_send_map_intent(true, true),
		"disconnected and pending clients are gated")


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
		printerr("MAP_UI_FAIL: %s" % message)
		get_tree().quit(1)
