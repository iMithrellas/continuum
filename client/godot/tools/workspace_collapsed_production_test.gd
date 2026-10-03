## Actual production-main controls exercise tall-panel collapse without a backend.
## Header anchors are independent of remembered body dimensions until restoration.
extends "res://tools/ui_composition_fixture.gd"

func _check_functional_contracts() -> void:
	var deck: WorkspaceDeck = main.workspace
	deck.switch_workspace("welfare")
	deck.model.show_panel_headers = true
	for key: String in deck.windows:
		deck.state(key).open = key == "people"
	deck.state("people").pinned = false
	deck.state("people").minimized = false
	deck._apply_layout()
	await _settle()
	check(not deck.compact, "production collapsed test requires a floating budget")
	var window: WorkspaceWindow = deck.windows.people
	var map_actions := [0]
	main.map.build_rectangle_requested.connect(func(_rect: Rect2i) -> void: map_actions[0] += 1)
	main.map.rectangle_selected.connect(func(_rect: Rect2i) -> void: map_actions[0] += 1)
	deck.state("people").rect = WorkspaceLayout.defaults().welfare.panels.people.rect.duplicate()
	deck._apply_layout()
	await _settle()
	var dimensions: Array = deck.state("people").rect.slice(2)
	await _collapse_action(window)
	var before := window.position
	await _drag_header(window, before + Vector2(0, 120), true)
	check(window.position.distance_to(before + Vector2(0, 120)) < 1, "default welfare roster drags down 120px independently of expanded height")
	check(deck.state("people").rect.slice(2) == dimensions, "default roster movement preserves expanded dimensions")
	for full_area: bool in [false, true]:
		deck.state("people").minimized = false
		deck.state("people").rect = [0.2, 0.2, 0.3, 0.4]
		deck._apply_layout()
		await _settle()
		await _resize(window.resize_handles.top_left if full_area else window.resize_handles.top, Vector2(-3000, -3000) if full_area else Vector2(0, -3000))
		await _resize(window.grip if full_area else window.resize_handles.bottom, Vector2(3000, 3000) if full_area else Vector2(0, 3000))
		var expanded := Rect2(window.position, window.size)
		check(expanded.size.y == deck.area.size.y and expanded.position.y == 0, "actual production handles create full-height body")
		if full_area:
			check(expanded == Rect2(Vector2.ZERO, deck.area.size), "actual production corner handles create full-area body")
		dimensions = deck.state("people").rect.slice(2)
		await _collapse_action(window)
		await _drag_header(window, window.position + Vector2(0, 120), true)
		check(window.position.y == 120 and window.size.y == window.chrome_height(), "full-height/full-area collapsed header moves down 120px")
		await _drag_header(window, Vector2(window.position.x, deck.area.size.y - window.size.y - 5), false)
		check(window.position.y + window.size.y == deck.area.size.y, "full-height header snaps to lower viewport edge")
		var collapsed := Rect2(window.position, window.size)
		var saved_rect: Array = deck.state("people").rect.duplicate()
		check(saved_rect.slice(2) == dimensions, "lower-edge movement never persists header height as body height")
		var reload := WorkspaceLayout.new()
		check(reload.load_from(deck._save_path), "production release saves layout")
		check(_same_rect(reload.workspaces.welfare.panels.people.rect, saved_rect) and reload.workspaces.welfare.panels.people.minimized, "disk persists collapsed anchor independently of expanded size")
		deck.model.load_from(deck._save_path)
		# JSON serialization may round the final decimal digits. Subsequent
		# in-memory no-op/rollback checks compare the canonical loaded values exactly.
		saved_rect = deck.state("people").rect.duplicate()
		dimensions = saved_rect.slice(2)
		deck._apply_layout()
		await _settle()
		check(Rect2(window.position, window.size) == collapsed, "full-height collapsed anchor survives disk reload")
		deck.switch_workspace("build")
		deck.switch_workspace("welfare")
		await _settle()
		check(Rect2(window.position, window.size) == collapsed, "full-height collapsed anchor survives workspace round-trip")
		var old_size := get_window().size
		get_window().size = old_size + Vector2i(120, 120)
		await _settle()
		var anchor := Vector2(saved_rect[0], saved_rect[1]) * deck.area.size
		var expected := WorkspaceLayout.clamp_rect(Rect2(anchor, Vector2(window.size.x, window.chrome_height())), deck.area.size, deck.metrics, Vector2(280, window.chrome_height()))
		check(window.position.distance_to(expected.position.round()) < 1 and deck.state("people").rect == saved_rect, "viewport change uses saved collapsed anchor without overwriting dimensions")
		get_window().size = old_size
		await _settle()
		check(Rect2(window.position, window.size) == collapsed and deck.state("people").rect == saved_rect, "viewport round-trip recovers lower-edge collapsed anchor")
		for cancellation: String in ["escape", "right", "focus"]:
			var pointer := window.titlebar.global_position + Vector2(40, 12)
			await _send(_button(MOUSE_BUTTON_LEFT, true, pointer))
			var destination := pointer - Vector2(0, 120)
			await _send(_motion(destination, true))
			check(window.position.y == collapsed.position.y - 120, "full-height header actually moves before cancellation")
			if cancellation == "escape":
				var escape := InputEventKey.new()
				escape.keycode = KEY_ESCAPE
				escape.pressed = true
				await _send(escape)
			elif cancellation == "right":
				await _send(_button(MOUSE_BUTTON_RIGHT, true, destination))
				await _send(_button(MOUSE_BUTTON_RIGHT, false, destination))
			else:
				window.notification(NOTIFICATION_WM_WINDOW_FOCUS_OUT)
				await _settle()
			await _send(_button(MOUSE_BUTTON_LEFT, false, destination))
			check(Rect2(window.position, window.size) == collapsed and deck.state("people").rect == saved_rect and window._gesture.is_empty() and deck._drag_origins.is_empty(), "full-height %s rollback restores lower-edge anchor and dimensions" % cancellation)
			reload.load_from(deck._save_path)
			check(_same_rect(reload.workspaces.welfare.panels.people.rect, saved_rect), "full-height cancellation persists original collapsed anchor")
		await _drag_header(window, Vector2(window.position.x, 3000), true)
		check(Rect2(window.position, window.size) == collapsed, "collapsed bottom overshoot clamps to visible header bounds")
		await _collapse_action(window)
		check(not window.collapsed and window.position == expanded.position and window.size == expanded.size, "only restoration clamps full-height body back onscreen without shrinking")
		check(deck.state("people").rect.slice(2) == dimensions, "restoration preserves exact remembered body dimensions")
		await _collapse_action(window)
		check(window.position == expanded.position, "next collapse starts at the clamped restored position")
	check(main.forbidden_connections == 0 and map_actions[0] == 0, "production gestures neither connect nor dispatch map actions")
	if failures.is_empty():
		print("WORKSPACE_COLLAPSED_PRODUCTION_PASS screen=%s scale=%s welfare actual-resize full-height full-area bottom-snap anchor reload workspace viewport rollback restore-clamp" % [_screen, _scale])


## Allow only JSON's final-decimal rounding, far below a logical pixel.
func _same_rect(first: Array, second: Array) -> bool:
	for axis in 4:
		if absf(first[axis] - second[axis]) > 0.000000000001:
			return false
	return true


func _collapse_action(window: WorkspaceWindow) -> void:
	var button: Button = window.titlebar.get_child(-2)
	var pointer := button.get_global_rect().get_center()
	await _send(_button(MOUSE_BUTTON_LEFT, true, pointer))
	await _send(_button(MOUSE_BUTTON_LEFT, false, pointer))


func _resize(handle: Control, delta: Vector2) -> void:
	var pointer := handle.get_global_rect().get_center()
	await _send(_button(MOUSE_BUTTON_LEFT, true, pointer))
	await _send(_motion(pointer + delta, true))
	await _send(_button(MOUSE_BUTTON_LEFT, false, pointer + delta))


func _drag_header(window: WorkspaceWindow, target: Vector2, unsnapped: bool) -> void:
	var pointer := window.titlebar.global_position + Vector2(40, 12)
	var destination := pointer + target - window.position
	await _send(_button(MOUSE_BUTTON_LEFT, true, pointer))
	check(window._gesture == "move", "production header arms actual move")
	await _send(_motion(destination, unsnapped))
	await _send(_button(MOUSE_BUTTON_LEFT, false, destination))


func _button(index: MouseButton, pressed: bool, pointer: Vector2) -> InputEventMouseButton:
	var event := InputEventMouseButton.new()
	event.button_index = index
	event.pressed = pressed
	event.position = pointer
	return event


func _motion(pointer: Vector2, unsnapped: bool) -> InputEventMouseMotion:
	var event := InputEventMouseMotion.new()
	event.position = pointer
	event.alt_pressed = unsnapped
	return event


## Input singleton consumes physical pixels; production GUI uses logical pixels.
func _send(event: InputEvent) -> void:
	if event is InputEventMouse:
		event.position = get_viewport().get_final_transform() * event.position
		event.global_position = event.position
	Input.parse_input_event(event)
	await _settle()


func _settle() -> void:
	for _frame in 4:
		await get_tree().process_frame
