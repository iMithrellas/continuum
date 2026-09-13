## Backend-free regression coverage for the personal workspace manager.
extends Node

const WorkspaceLayout = preload("res://scripts/workspace_layout.gd")
const WorkspaceDeck = preload("res://scripts/workspace_deck.gd")

var failed := false
var path := "user://workspace_test_%d.json" % Time.get_ticks_usec()
var viewport_builds := 0
var viewport_selections := 0

func _ready() -> void:
	var model := WorkspaceLayout.new()
	_assert(model.workspaces.keys().size() == 4, "defaults provide daily, build, welfare, and diagnostics")
	_assert(WorkspaceLayout.MIN_SIZE == Vector2(280, 180), "workspace minimum size is public")
	_assert(WorkspaceLayout.clamp_rect(Rect2(-50, -20, 20, 20), Vector2(640, 480)).size == WorkspaceLayout.MIN_SIZE, "rectangles clamp to minimum size")
	_assert(WorkspaceLayout.to_pixels([0.5, 0.5, 0.5, 0.5], Vector2(800, 600)).position == Vector2(400, 300), "normalized geometry converts to pixels")
	var id := model.create_workspace("  Field notes  ", ["people", "alerts"], false)
	_assert(not id.is_empty() and model.active == id and model.workspaces[id].name == "Field notes", "custom workspace creates and trims its name")
	model.workspaces[id].name = "Renamed notes"
	model.workspaces[id].panels.people.rect = [0.1, 0.2, 0.4, 0.5]
	model.workspaces[id].panels.people.open = true
	model.workspaces[id].panels.people.minimized = true
	model.workspaces[id].panels.people.pinned = true
	model.workspaces[id].panels.people.z = 17
	_assert(model.remove_workspace("daily") == false and model.workspaces.has("daily"), "built-in workspaces cannot be deleted")
	_assert(model.save_to(path) == OK, "layout persists to the isolated test path")
	var restored := WorkspaceLayout.new()
	_assert(restored.load_from(path) and restored.workspaces.size() == 5 and restored.active == id, "saved layouts restore active custom workspace")
	_assert(restored.workspaces[id].name == "Renamed notes" and restored.workspaces[id].panels.people.rect == [0.1, 0.2, 0.4, 0.5] and
			restored.workspaces[id].panels.people.minimized and restored.workspaces[id].panels.people.pinned and
			restored.workspaces[id].panels.people.z == 17, "saved custom geometry and flags round-trip")
	var other_id := restored.create_workspace("Other", ["overview"], false)
	var other_rect: Array = restored.workspaces[other_id].panels.overview.rect.duplicate()
	restored.active = id
	restored.reset_active()
	_assert(restored.workspaces[id].panels.people.rect == WorkspaceLayout.defaults().daily.panels.people.rect and
			not restored.workspaces[id].panels.people.pinned and not restored.workspaces[id].panels.people.minimized,
		"resetting one custom layout uses daily geometry and clears its flags")
	_assert(restored.workspaces[other_id].panels.overview.rect == other_rect, "resetting one layout does not alter another")
	_assert(restored.remove_workspace(id) and restored.active == "daily", "custom workspace can be deleted")
	var malformed := path + ".bad"
	var bad_file := FileAccess.open(malformed, FileAccess.WRITE)
	bad_file.store_string(JSON.stringify({"version": 1, "active": "missing", "workspaces": {
		"bad": {"name": "Bad", "panels": {"people": {"rect": ["nan", 0, 1, 1], "open": true}}}}}))
	bad_file.close()
	var recovered := WorkspaceLayout.new()
	_assert(recovered.load_from(malformed), "nested corruption file has a valid outer envelope")
	_assert(recovered.workspaces.size() == 5 and recovered.active == "daily",
		"corrupted preferences retain defaults and a safe active workspace")
	_assert(recovered.workspaces["bad"].panels.people.rect == WorkspaceLayout.defaults().daily.panels.people.rect,
		"corrupted nested panel data is discarded")
	DirAccess.remove_absolute(ProjectSettings.globalize_path(malformed))
	await _test_geometry(model)
	if failed:
		return
	await _test_manager()
	if failed:
		return
	DirAccess.remove_absolute(ProjectSettings.globalize_path(path))
	print("WORKSPACE_PASS")
	get_tree().quit(0)

func _test_geometry(_model: WorkspaceLayout) -> void:
	var area := Vector2(1000, 700)
	var first := Rect2(100, 100, 300, 220)
	var neighbor := Rect2(408, 100, 300, 220)
	var snapped := WorkspaceLayout.snap_rect(Rect2(394, 100, 300, 220), area, [first, neighbor])
	_assert(is_equal_approx(snapped.position.x, 400.0), "neighboring edge alignment snaps")
	var viewport := WorkspaceLayout.to_pixels([0.1, 0.1, 0.4, 0.5], area)
	_assert(viewport.size.x >= WorkspaceLayout.MIN_SIZE.x and viewport.end.x <= area.x, "desktop viewport clamps preset geometry")
	var normalized := WorkspaceLayout.to_normalized(viewport, area)
	_assert(is_equal_approx(normalized[0], 0.1) and is_equal_approx(normalized[1], 0.1) and
			is_equal_approx(normalized[2], 0.4) and is_equal_approx(normalized[3], 0.5),
		"desktop geometry round-trips without viewport scaling")
	var resized := WorkspaceLayout.snap_rect(Rect2(100, 100, 296, 220), area, [Rect2(408, 100, 300, 220)], true)
	_assert(resized.size.x == 300 and resized.position.x == 100, "resize snaps trailing edge to neighbor gutter")
	var viewport_snap := WorkspaceLayout.snap_rect(Rect2(712, 484, 280, 210), area, [])
	_assert(viewport_snap.end == area, "move snaps both edges to viewport")
	var viewport_resize := WorkspaceLayout.snap_rect(Rect2(500, 300, 494, 394), area, [], true)
	_assert(viewport_resize.position == Vector2(500, 300) and viewport_resize.end == area,
		"resize snaps both trailing edges to viewport")

func _test_manager() -> void:
	var map := ColonyMap.new()
	map.name = "Map"
	map._has_state = true
	map._grid = Vector2i(24, 24)
	map.build_rectangle_requested.connect(func(_rect: Rect2i) -> void:
		viewport_builds += 1)
	map.rectangle_selected.connect(func(_rect: Rect2i) -> void:
		viewport_selections += 1)
	var deck := WorkspaceDeck.new()
	deck.name = "Workspace"
	get_tree().root.add_child.call_deferred(map)
	get_tree().root.add_child.call_deferred(deck)
	await get_tree().process_frame
	deck.size = Vector2(1200, 800)
	var manager_path := "user://workspace_manager_test_%d.json" % Time.get_ticks_usec()
	deck.setup(map, manager_path)
	for key: String in WorkspaceLayout.PANEL_NAMES:
		deck.add_panel(key)
	deck.finish_setup()
	await get_tree().process_frame
	map.input_blocked = deck.blocks_map_input
	_assert(deck.windows.size() == 8 and deck.authorized.size() == 8, "manager creates all actual game panels")
	var active := deck.model.active
	deck.toggle_panel("people")
	_assert(deck.state("people").minimized, "panel minimizes to the dock")
	deck.toggle_panel("people")
	_assert(not deck.state("people").minimized and deck.windows["people"].visible, "panel restores from the dock")
	deck.state("people").pinned = true
	deck._apply_layout()
	_assert(deck.windows["people"].pinned and not deck.windows["people"].grip.visible, "pin state disables geometry grip")
	deck.state("alerts").open = false
	deck._apply_layout()
	_assert(not deck.windows["alerts"].visible, "closed panel is removed from the workspace")
	deck.toggle_panel("alerts")
	_assert(deck.state("alerts").open and deck.windows["alerts"].visible, "closed panel reopens from the dock")
	deck.switch_workspace("build")
	_assert(deck.model.active == "build", "workspace switching is public")
	deck.state("operations").open = true
	deck.state("operations").rect = [0.2, 0.2, 0.4, 0.4]
	deck.switch_workspace(active)
	_assert(deck.model.active == active and deck.state("people").pinned, "switching restores the prior layout state")
	var desktop_rect: Array = deck.state("people").rect.duplicate()
	deck.size = Vector2(390, 844)
	await get_tree().process_frame
	await get_tree().process_frame
	_assert(deck.compact and deck.state("people").rect == desktop_rect, "compact mode adapts without overwriting desktop geometry")
	_assert(deck.area.size.x == 390 and deck.windows[deck._compact_panel].size == deck.area.size,
		"phone viewport shows one full-width panel inside the available deck")
	deck.set_panel_authorized("operations", false)
	_assert(not deck.authorized["operations"] and not deck.windows["operations"].visible, "unauthorized workspace windows are hidden")
	_assert(deck.blocks_map_input(deck.windows["people"].global_position + Vector2(20, 20)), "window content blocks map input")
	deck.size = Vector2(1200, 800)
	await get_tree().process_frame
	await get_tree().process_frame
	_assert(not deck.compact and deck.state("people").rect == desktop_rect,
		"returning to desktop preserves preferred geometry")
	await _test_viewport_input(deck, map)
	deck.toggle_map_only()
	var map_point := deck.area.get_global_rect().position + Vector2(500, 300)
	_assert(not deck.blocks_map_input(map_point), "map-only mode passes map input")
	deck.toggle_map_only()
	_assert(deck.blocks_map_input(Vector2(-1, -1)), "outside workspace blocks unsafe input")
	var copied_rect: Array = deck.state("people").rect.duplicate()
	deck.edit_workspace(true)
	deck._name_input.text = "Survey"
	for key: String in deck._checks:
		deck._checks[key].button_pressed = key in ["people", "trends"]
	deck._confirm_workspace()
	deck._dialog.hide()
	_assert(deck.model.workspaces[deck.model.active].name == "Survey" and deck.state("people").rect == copied_rect,
		"workspace creator copies the selected arrangement")
	_assert(deck.state("trends").open and not deck.state("alerts").open,
		"creator applies the chosen panel set")
	deck.edit_workspace(false)
	deck._name_input.text = "Survey notes"
	deck._confirm_workspace()
	deck._dialog.hide()
	_assert(deck.model.workspaces[deck.model.active].name == "Survey notes", "chooser renames a custom workspace")
	var reloaded := WorkspaceLayout.new()
	_assert(reloaded.load_from(manager_path) and reloaded.active == deck.model.active and
		reloaded.workspaces[reloaded.active].name == "Survey notes", "UI edits auto-save the active workspace")
	DirAccess.remove_absolute(ProjectSettings.globalize_path(manager_path))
	deck.queue_free()

func _test_viewport_input(deck: WorkspaceDeck, map: ColonyMap) -> void:
	for key: String in deck.windows:
		deck.state(key).open = key == "people"
	deck.state("people").pinned = false
	deck.state("people").minimized = false
	deck.state("people").rect = [0.35, 0.3, 0.3, 0.45]
	deck._apply_layout()
	await get_tree().process_frame
	var window: WorkspaceWindow = deck.windows["people"]
	var title: Vector2 = window.titlebar.global_position + Vector2(50, 15)
	var start_position := window.position
	var viewport := get_viewport()
	viewport.push_input(_mouse_button(MOUSE_BUTTON_LEFT, true, title))
	_assert(window._gesture == "move" and not map._dragging, "title press arms a real window move, not map painting")
	viewport.push_input(_mouse_motion(title + Vector2(40, 20)))
	viewport.push_input(_mouse_button(MOUSE_BUTTON_LEFT, false, title + Vector2(40, 20)))
	_assert(window.position.distance_to(start_position + Vector2(40, 20)) < 1,
		"viewport drag changes the actual window position")
	_assert(viewport_builds == 0 and viewport_selections == 0 and window._gesture.is_empty(),
		"viewport-routed title drag does not paint the map")
	await get_tree().process_frame
	var grip := window.grip.get_global_rect().get_center()
	var start_size := window.size
	viewport.push_input(_mouse_button(MOUSE_BUTTON_LEFT, true, grip))
	_assert(window._gesture == "resize", "resize grip arms a real geometry change")
	viewport.push_input(_mouse_motion(grip + Vector2(30, 20)))
	viewport.push_input(_mouse_button(MOUSE_BUTTON_LEFT, false, grip + Vector2(30, 20)))
	_assert(window.size.distance_to(start_size + Vector2(30, 20)) < 1, "viewport resize changes the actual window extent")
	_assert(viewport_builds == 0 and viewport_selections == 0 and window._gesture.is_empty(),
		"viewport-routed resize grip does not paint the map")
	var map_point := map.global_position + map._origin() + Vector2(2, 2) * map._cell_size()
	title = window.titlebar.global_position + Vector2(50, 15)
	map.set_interaction_mode(&"build")
	viewport.push_input(_mouse_button(MOUSE_BUTTON_LEFT, true, map_point))
	_assert(map._dragging, "uncovered map still accepts build gestures")
	viewport.push_input(_mouse_motion(title))
	viewport.push_input(_mouse_button(MOUSE_BUTTON_LEFT, false, title))
	_assert(viewport_builds == 0 and viewport_selections == 0 and not map._dragging,
		"map release over a workspace window cancels without dispatch")
	viewport.push_input(_mouse_button(MOUSE_BUTTON_LEFT, true, map_point))
	viewport.push_input(_mouse_motion(map_point + Vector2(10, 10)))
	viewport.push_input(_mouse_button(MOUSE_BUTTON_LEFT, false, map_point + Vector2(10, 10)))
	_assert(viewport_builds == 1, "uncovered map release emits exactly one build intent")
	viewport.push_input(_mouse_button(MOUSE_BUTTON_LEFT, true, title))
	viewport.push_input(_mouse_motion(title + Vector2(30, 20)))
	var escape := InputEventKey.new()
	escape.keycode = KEY_ESCAPE
	escape.pressed = true
	viewport.push_input(escape)
	_assert(window._gesture.is_empty() and window.position.distance_to(start_position + Vector2(40, 20)) < 1,
		"Escape cancels and rolls back an active window gesture")
	deck.state("people").pinned = true
	deck._apply_layout()
	viewport.push_input(_mouse_button(MOUSE_BUTTON_LEFT, true, title))
	_assert(window._gesture.is_empty(), "pinned headers cannot arm a drag")
	viewport.push_input(_mouse_button(MOUSE_BUTTON_LEFT, false, title))

func _mouse_button(button: MouseButton, pressed: bool, position: Vector2) -> InputEventMouseButton:
	var event := InputEventMouseButton.new()
	event.button_index = button
	event.pressed = pressed
	event.position = position
	event.global_position = position
	return event

func _mouse_motion(position: Vector2) -> InputEventMouseMotion:
	var event := InputEventMouseMotion.new()
	event.position = position
	event.global_position = position
	return event

func _assert(condition: bool, message: String) -> void:
	if not condition:
		_fail(message)

func _fail(message: String) -> void:
	if failed:
		return
	failed = true
	printerr("WORKSPACE_FAIL: %s" % message)
	get_tree().quit(1)
