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
	model.show_panel_headers = false
	_assert(model.remove_workspace("daily") == false and model.workspaces.has("daily"), "built-in workspaces cannot be deleted")
	_assert(model.save_to(path) == OK, "layout persists to the isolated test path")
	var restored := WorkspaceLayout.new()
	_assert(restored.load_from(path) and restored.workspaces.size() == 5 and restored.active == id, "saved layouts restore active custom workspace")
	_assert(restored.workspaces[id].name == "Renamed notes" and restored.workspaces[id].panels.people.rect == [0.1, 0.2, 0.4, 0.5] and
			restored.workspaces[id].panels.people.minimized and restored.workspaces[id].panels.people.pinned and
			restored.workspaces[id].panels.people.z == 17, "saved custom geometry and flags round-trip")
	_assert(not restored.show_panel_headers, "header visibility persists independently of panel geometry")
	_assert(not restored.workspaces[id].panels.people.has("dock"), "v3 persists no docking state")
	var legacy_data: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(path))
	legacy_data.version = 1
	for entry: Dictionary in legacy_data.workspaces.values():
		entry.panels.erase("admin")
		entry.panels.erase("developer")
		for saved: Dictionary in entry.panels.values():
			saved.erase("dock")
	var legacy_file := FileAccess.open(path, FileAccess.WRITE)
	legacy_file.store_string(JSON.stringify(legacy_data))
	legacy_file.close()
	var migrated := WorkspaceLayout.new()
	_assert(migrated.load_from(path) and migrated.workspaces[id].panels.size() == 10,
		"version-one layouts migrate optional admin and developer panel keys")
	var migrated_people: Dictionary = migrated.workspaces[id].panels.people.duplicate(true)
	_assert(migrated_people == restored.workspaces[id].panels.people and
		not migrated.show_panel_headers and migrated.active == id,
		"migration preserves old geometry, open/minimized/pinned/layer, headers and workspace")
	_assert(not migrated.workspaces[id].panels.people.has("dock"), "v1 overlays retain their remembered geometry without docking state")
	legacy_data.version = 2
	for entry: Dictionary in legacy_data.workspaces.values():
		for saved: Dictionary in entry.panels.values():
			saved.dock = "left" if saved.rect[0] < 0.5 else "right"
	legacy_file = FileAccess.open(path, FileAccess.WRITE)
	legacy_file.store_string(JSON.stringify(legacy_data))
	legacy_file.close()
	_assert(migrated.load_from(path) and migrated.workspaces[id].panels.people == restored.workspaces[id].panels.people,
		"v2 dock keys migrate to remembered floating rectangles without changing any panel intent")
	_assert(migrated.save_to(path) == OK and JSON.parse_string(FileAccess.get_file_as_string(path)).version == 3 and
		not FileAccess.get_file_as_string(path).contains('"dock"'), "migration saves v3 without obsolete dock keys")
	_assert(migrated.workspaces[id].panels.admin.open and migrated.workspaces[id].panels.developer.open,
		"new panels default open without changing old panel preferences")
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
	_assert(recovered.show_panel_headers, "old layout files default to visible headers")
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
	var neighbor := Rect2(416, 100, 300, 220)
	var snapped := WorkspaceLayout.snap_rect(Rect2(394, 100, 300, 220), area, [first, neighbor])
	_assert(is_equal_approx(snapped.position.x, 400.0), "neighboring edge alignment snaps")
	var viewport := WorkspaceLayout.to_pixels([0.1, 0.1, 0.4, 0.5], area)
	_assert(viewport.size.x >= WorkspaceLayout.MIN_SIZE.x and viewport.end.x <= area.x, "desktop viewport clamps preset geometry")
	var normalized := WorkspaceLayout.to_normalized(viewport, area)
	_assert(is_equal_approx(normalized[0], 0.1) and is_equal_approx(normalized[1], 0.1) and
			is_equal_approx(normalized[2], 0.4) and is_equal_approx(normalized[3], 0.5),
		"desktop geometry round-trips without viewport scaling")
	var resized := WorkspaceLayout.snap_rect(Rect2(100, 100, 296, 220), area, [Rect2(416, 100, 300, 220)], true)
	_assert(resized.size.x == 300 and resized.position.x == 100, "resize snaps trailing edge to neighbor gutter")
	var viewport_snap := WorkspaceLayout.snap_rect(Rect2(712, 484, 280, 210), area, [])
	_assert(viewport_snap.end == area, "move snaps both edges to viewport")
	var viewport_resize := WorkspaceLayout.snap_rect(Rect2(500, 300, 494, 394), area, [], true)
	_assert(viewport_resize.position == Vector2(500, 300) and viewport_resize.end == area,
		"resize snaps both trailing edges to viewport")
	var leading := WorkspaceLayout.snap_rect(Rect2(12, 12, 488, 388), area, [], true, UiMetrics.new(), Vector2i(-1, -1))
	_assert(leading.position == Vector2.ZERO and leading.end == Vector2(500, 400),
		"top-left resizing snaps moving edges without moving the opposite corner")
	var left_only := WorkspaceLayout.snap_rect(Rect2(12, 12, 488, 388), area, [], true, UiMetrics.new(), Vector2i(-1, 0))
	_assert(left_only.position == Vector2(0, 12) and left_only.end == Vector2(500, 400),
		"single-edge resizing never snaps the untouched axis")
	var minimum := WorkspaceLayout.clamp_resize_rect(Rect2(600, 500, -100, -100), area, Vector2i(-1, -1))
	_assert(minimum.size == WorkspaceLayout.MIN_SIZE and minimum.end == Vector2(500, 400),
		"crossing top-left edges clamps to minimum size with the opposite corner fixed")
	var maximum := WorkspaceLayout.clamp_resize_rect(Rect2(-900, -900, 1400, 1300), area, Vector2i(-1, -1))
	_assert(maximum.position == Vector2.ZERO and maximum.end == Vector2(500, 400),
		"top-left resize cannot escape the workspace")

func _test_manager() -> void:
	# Headless defaults to a tiny native Window; dialogs need a real host budget.
	get_tree().root.size = Vector2i(1440, 900)
	var previous_db := SpacetimeDB.Continuum.db
	var local := preload("res://tools/terrain_fixture.gd").database(false)
	var map := ColonyMap.new()
	map.bind_world_source(SpacetimeDB.Continuum.db)
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
	deck.apply_metrics(UiMetrics.new(24))
	_assert(deck.metrics.base_font_size == 13 and deck.windows["people"].metrics.base_font_size == 13,
		"whole-UI scaling never doubles logical workspace measurements")
	_assert(deck._dialog.min_size.x == 300, "workspace dialog retains logical minimum")
	_assert(deck._rows[0].custom_minimum_size.y == 40, "telemetry header is the 40px token")
	await get_tree().process_frame
	var scaled: WorkspaceWindow = deck.windows.people
	for child: Node in scaled.titlebar.get_children():
		if child is Button:
			_assert(scaled.get_global_rect().encloses(child.get_global_rect()), "scaled action buttons stay inside their panel")
			for handle: Control in scaled.resize_handles.values():
				_assert(not child.get_global_rect().intersects(handle.get_global_rect()), "scaled action buttons do not overlap resize hit areas")
	deck.apply_metrics(UiMetrics.new(13))
	_assert(is_equal_approx(deck._rows[0].custom_minimum_size.y, 40), "header row returns without compounding")
	map.input_blocked = deck.blocks_map_input
	_assert(deck.windows.size() == 10 and deck.authorized.size() == 10, "manager creates all actual game panels")
	_assert(deck.windows.keys() == ["overview", "people", "inspector", "operations", "policies", "alerts", "activity", "trends", "admin", "developer"], "F1-F8 keep existing order with Admin F9 and Developer F10")
	for index in 10:
		var panel_key: String = deck.windows.keys()[index]
		deck.state(panel_key).open = true
		deck.state(panel_key).minimized = false
		var key_event := InputEventKey.new()
		key_event.pressed = true
		key_event.keycode = KEY_F1 + index
		deck._unhandled_key_input(key_event)
		_assert(deck.state(panel_key).minimized, "F%d toggles its stable panel" % (index + 1))
		deck.state(panel_key).minimized = false
	deck.set_panel_authorized("admin", false)
	var denied_event := InputEventKey.new()
	denied_event.pressed = true
	denied_event.keycode = KEY_F9
	deck._unhandled_key_input(denied_event)
	_assert(not deck.state("admin").minimized, "F9 cannot change a denied admin panel")
	deck.set_panel_authorized("admin", true)
	var developer_window: WorkspaceWindow = deck.windows.developer
	deck.windows.erase("developer")
	denied_event.keycode = KEY_F10
	deck._unhandled_key_input(denied_event)
	_assert(not deck.state("developer").minimized, "fast F10 lookup is safe before every window exists")
	deck.windows.developer = developer_window
	deck.model.workspaces.daily = WorkspaceLayout.defaults().daily
	deck._apply_layout()
	_assert(not deck.compact and map.get_global_rect() == deck.area.get_global_rect(), "panels overlay the full map with no reserved space")
	_assert(not deck.has_method("set_panel_dock") and not deck.windows.people.has_signal("dock_requested"), "docking APIs and controls are removed entirely")
	deck.windows.people.set_live_count(8)
	_assert(deck.windows.people.live_count.text == "8", "integration can set a live mono panel-header count")
	deck.set_workspace_alert_summary("daily", "warn", 2)
	_assert(deck._alert_summaries.daily.count == 2, "workspace alert summaries are transient integration inputs")
	deck.set_panel_authorized("admin", false)
	_assert(deck._alert_summaries.is_empty(), "access revocation clears potentially stale restricted counts")
	deck.set_panel_authorized("admin", true)
	var framed: WorkspaceWindow = deck.windows.people
	for child: Node in framed.titlebar.get_children():
		if child is Button:
			_assert(child.text.is_empty() and child.icon != null and not child.tooltip_text.is_empty(),
				"window actions use actual icons with descriptive tooltips")
	_assert(framed.resize_handles.size() == 8, "every edge and corner has a resize hit area")
	await _test_headers(deck, manager_path)
	var active := deck.model.active
	deck.toggle_panel("people")
	_assert(deck.state("people").minimized, "panel minimizes to its header")
	_assert(deck.windows.people.visible and deck.windows.people.size.y == 32 and not deck.windows.people.scroll.visible, "collapse retains a real 32px header")
	deck.toggle_panel("people")
	_assert(not deck.state("people").minimized and deck.windows["people"].visible, "panel restores from navigation")
	deck.state("people").pinned = true
	deck._apply_layout()
	_assert(deck.windows["people"].pinned and not deck.windows["people"].grip.visible, "pin state disables geometry grip")
	deck.state("alerts").open = false
	deck._apply_layout()
	_assert(not deck.windows["alerts"].visible, "closed panel is removed from the workspace")
	deck.toggle_panel("alerts")
	_assert(deck.state("alerts").open and deck.windows["alerts"].visible, "closed panel reopens from navigation")
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
	for scale_percent: int in [100, 125, 150]:
		deck.size = Vector2(1440, 900) / (float(scale_percent) / 100.0)
		await get_tree().process_frame
		await get_tree().process_frame
		_assert(not deck.compact and map.get_global_rect() == deck.area.get_global_rect(), "1440px full-map overlay policy at %d percent" % scale_percent)
	deck.size = Vector2(1200, 800)
	await get_tree().process_frame
	await get_tree().process_frame
	await _test_viewport_input(deck, map)
	await _test_resize_edges(deck)
	await _test_direct_panel_interactions(deck)
	await _test_floating_overlap(deck)
	await _test_retained_body_focus_resize(deck)
	await _test_navigation_focus(deck)
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
	map.queue_free()
	SpacetimeDB.Continuum.db = previous_db
	local.free()

func _test_headers(deck: WorkspaceDeck, manager_path: String) -> void:
	var window: WorkspaceWindow = deck.windows.people
	var original := Rect2(window.position, window.size)
	deck._layout_action(2)
	_assert(not deck.model.show_panel_headers and not window.titlebar.visible and window.drag_strip.visible and window.divider.visible,
		"hidden headers preserve visible drag and restore affordances")
	_assert(is_equal_approx(window.scroll.offset_top, deck.metrics.px(36)) and Rect2(window.position, window.size) == original,
		"hidden headers retain a 24px drag strip without changing window geometry")
	var reloaded := WorkspaceLayout.new()
	_assert(reloaded.load_from(manager_path) and not reloaded.show_panel_headers,
		"UI header toggle auto-saves the preference")
	deck.switch_workspace("build")
	_assert(not deck.windows.operations.titlebar.visible, "header preference also applies after switching workspaces")
	deck.apply_metrics(UiMetrics.new(24))
	_assert(not deck.windows.operations.titlebar.visible and is_equal_approx(deck.windows.operations.scroll.offset_top, deck.metrics.px(36)),
		"font scaling preserves hidden headers and their compact inset")
	deck.apply_metrics(UiMetrics.new(13))
	var shortcut := InputEventKey.new()
	shortcut.keycode = KEY_H
	shortcut.ctrl_pressed = true
	shortcut.shift_pressed = true
	shortcut.pressed = true
	deck._unhandled_key_input(shortcut)
	_assert(deck.model.show_panel_headers and deck.windows.operations.titlebar.visible,
		"Ctrl+Shift+H restores headers without needing the hidden controls")
	_assert(deck._menu.get_popup().is_item_checked(deck._menu.get_popup().get_item_index(2)),
		"Layout checkmark stays in sync with the keyboard toggle")
	deck.switch_workspace("daily")
	await get_tree().process_frame

func _test_resize_edges(deck: WorkspaceDeck) -> void:
	deck.state("people").pinned = false
	deck.state("people").rect = [0.35, 0.3, 0.3, 0.45]
	deck._apply_layout()
	await get_tree().process_frame
	var window: WorkspaceWindow = deck.windows.people
	var viewport := get_viewport()
	var original := Rect2(window.position, window.size)
	var builds_before := viewport_builds
	var selections_before := viewport_selections
	for key: String in WorkspaceWindow.RESIZE_DIRECTIONS:
		window.position = original.position
		window.size = original.size
		await get_tree().process_frame
		var handle: Control = window.resize_handles[key]
		var pointer := handle.get_global_rect().get_center()
		var edges: Vector2i = WorkspaceWindow.RESIZE_DIRECTIONS[key]
		var delta := Vector2(edges) * Vector2(28, 22)
		viewport.push_input(_mouse_button(MOUSE_BUTTON_LEFT, true, pointer))
		_assert(window._gesture == "resize" and window._resize_edges == edges, "real %s handle arms the correct edges" % key)
		var motion := _mouse_motion(pointer + delta)
		motion.alt_pressed = true
		viewport.push_input(motion)
		viewport.push_input(_mouse_button(MOUSE_BUTTON_LEFT, false, pointer + delta))
		var expected := original
		for axis in 2:
			if edges[axis] < 0:
				expected.position[axis] += delta[axis]
				expected.size[axis] -= delta[axis]
			elif edges[axis] > 0:
				expected.size[axis] += delta[axis]
		_assert(window.position.distance_to(expected.position) < 1 and window.size.distance_to(expected.size) < 1,
			"real %s resize preserves the stationary edges" % key)
		_assert(window._gesture.is_empty(), "releasing %s finishes its resize" % key)
		for overshoot: float in [-3000.0, 3000.0]:
			window.position = original.position
			window.size = original.size
			await get_tree().process_frame
			pointer = handle.get_global_rect().get_center()
			viewport.push_input(_mouse_button(MOUSE_BUTTON_LEFT, true, pointer))
			motion = _mouse_motion(pointer + Vector2(edges) * overshoot)
			motion.alt_pressed = true
			viewport.push_input(motion)
			viewport.push_input(_mouse_button(MOUSE_BUTTON_LEFT, false, motion.position))
			var actual := Rect2(window.position, window.size)
			_assert(Rect2(Vector2.ZERO, deck.area.size).encloses(actual), "real %s overshoot remains inside the workspace" % key)
			for axis in 2:
				if edges[axis] != 0:
					var stationary := actual.end[axis] if edges[axis] < 0 else actual.position[axis]
					var expected_stationary := original.end[axis] if edges[axis] < 0 else original.position[axis]
					_assert(is_equal_approx(stationary, expected_stationary), "real %s overshoot preserves the opposite edge" % key)
					if overshoot < 0:
						_assert(is_equal_approx(actual.size[axis], WorkspaceLayout.minimum_size(deck.metrics)[axis]), "real %s crossing clamps to minimum" % key)
				else:
					_assert(is_equal_approx(actual.position[axis], original.position[axis]) and is_equal_approx(actual.size[axis], original.size[axis]), "real %s overshoot leaves the untouched axis unchanged" % key)
	window.position = original.position
	window.size = original.size
	await get_tree().process_frame
	var cancel_point: Vector2 = window.resize_handles.top_left.get_global_rect().get_center()
	viewport.push_input(_mouse_button(MOUSE_BUTTON_LEFT, true, cancel_point))
	viewport.push_input(_mouse_motion(cancel_point - Vector2(30, 30)))
	window._notification(NOTIFICATION_WM_WINDOW_FOCUS_OUT)
	_assert(window._gesture.is_empty() and Rect2(window.position, window.size) == original, "focus loss cancels resizing and restores starting geometry")
	_assert(WorkspaceLayout.to_pixels(deck.state("people").rect, deck.area.size, deck.metrics).position.distance_to(original.position) < 1, "cancelled geometry persists coherently")
	_assert(viewport_builds == builds_before and viewport_selections == selections_before, "no edge or corner drag paints the map")
	deck.toggle_panel_headers()
	await get_tree().process_frame
	var point := window.scroll.get_global_rect().get_center()
	var position_before := window.position
	var press := _mouse_button(MOUSE_BUTTON_LEFT, true, point)
	press.alt_pressed = true
	viewport.push_input(press)
	_assert(window._gesture == "move", "Alt-drag moves headerless panels through their contents")
	var motion := _mouse_motion(point + Vector2(20, 16))
	motion.alt_pressed = true
	viewport.push_input(motion)
	viewport.push_input(_mouse_button(MOUSE_BUTTON_LEFT, false, point + Vector2(20, 16)))
	_assert(window.position.distance_to(position_before + Vector2(20, 16)) < 1, "headerless movement changes the panel, not the map")
	for key: String in ["left", "top_left"]:
		var handle: Control = window.resize_handles[key]
		await get_tree().process_frame
		var pointer := handle.get_global_rect().get_center()
		var resize_press := _mouse_button(MOUSE_BUTTON_LEFT, true, pointer)
		resize_press.alt_pressed = true
		viewport.push_input(resize_press)
		_assert(window._gesture == "resize", "Alt with hidden headers retains the %s resize handle instead of moving" % key)
		var escape := InputEventKey.new()
		escape.keycode = KEY_ESCAPE
		escape.pressed = true
		viewport.push_input(escape)
	deck.state("people").pinned = true
	deck._apply_layout()
	for handle: Control in window.resize_handles.values():
		_assert(not handle.visible, "pinning disables every edge and corner")
	_assert(window.pin_button.icon == UiIcons.texture("pin-off"), "pinned panels use the token-colored active pin icon")
	press = _mouse_button(MOUSE_BUTTON_LEFT, true, window.scroll.get_global_rect().get_center())
	press.alt_pressed = true
	viewport.push_input(press)
	_assert(window._gesture.is_empty(), "Alt cannot move a pinned headerless panel")
	viewport.push_input(_mouse_button(MOUSE_BUTTON_LEFT, false, press.position))
	deck.state("people").pinned = false
	deck._apply_layout()
	deck.toggle_panel_headers()

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

## Goes through the actual Input singleton, native Window scale and GUI dispatch,
## rather than invoking a title callback or assigning a gesture directly.
func _test_direct_panel_interactions(deck: WorkspaceDeck) -> void:
	var host := get_tree().root
	var old_size := host.size
	var old_scale := host.content_scale_factor
	var old_deck_size := deck.size
	var old_panels: Dictionary = deck.model.workspaces[deck.model.active].panels.duplicate(true)
	var builds := viewport_builds
	var selections := viewport_selections
	var window: WorkspaceWindow = deck.windows.people
	for scale: float in [1.0, 1.25, 1.5]:
		host.size = Vector2i(1920, 1080)
		host.content_scale_factor = scale
		await _settle_layout()
		deck.size = host.get_visible_rect().size
		for key: String in deck.windows:
			deck.state(key).open = key == "people"
		deck.state("people").pinned = false
		deck.state("people").minimized = false
		deck.state("people").rect = [0.2, 0.2, 0.3, 0.45]
		deck._apply_layout()
		await _settle_layout()
		_assert(not deck.compact, "native Window interaction budget remains desktop at %s" % scale)
		var saved := deck.state("people").duplicate(true)
		var start := Rect2(window.global_position - deck.area.global_position, window.size)
		var pointer := window.titlebar.global_position + Vector2(40, 12)
		await _parse(_mouse_button(MOUSE_BUTTON_LEFT, true, pointer))
		await _parse(_mouse_motion(pointer + Vector2(3, 2)))
		_assert(window.position.distance_to(start.position + Vector2(3, 2)) <= 16, "title press/jitter moves only this floating panel at %s" % scale)
		var motion := _mouse_motion(pointer + Vector2(60, 0))
		motion.alt_pressed = true
		await _parse(motion)
		_assert(window.get_parent() == deck.area and window._gesture == "move", "title drag moves a floating panel at %s" % scale)
		_assert(window.position.distance_to(start.position + Vector2(60, 0)) < 1 and window.size.distance_to(start.size) < 1,
			"movement preserves actual footprint and pointer offset at %s: %s -> %s" % [scale, start, Rect2(window.position, window.size)])
		var escape := InputEventKey.new()
		escape.keycode = KEY_ESCAPE
		escape.pressed = true
		await _parse(escape)
		_assert(deck.state("people").rect == saved.rect and window._gesture.is_empty(), "Escape restores remembered floating geometry at %s" % scale)
		await _parse(_mouse_button(MOUSE_BUTTON_LEFT, false, motion.position))
		pointer = window.grip.get_global_rect().get_center()
		start = Rect2(window.global_position - deck.area.global_position, window.size)
		await _parse(_mouse_button(MOUSE_BUTTON_LEFT, true, pointer))
		motion = _mouse_motion(pointer + Vector2(40, -30))
		motion.alt_pressed = true
		await _parse(motion)
		await _parse(_mouse_button(MOUSE_BUTTON_LEFT, false, motion.position))
		_assert(window.size.distance_to(start.size + Vector2(40, -30)) < 1 and window.position.distance_to(start.position) < 1,
			"visible corner resizes stationary opposite edges at %s" % scale)
		_assert(window._gesture.is_empty() and deck._drag_origins.is_empty(), "release completes exactly one gesture at %s" % scale)
		var restored := WorkspaceLayout.new()
		_assert(restored.load_from(deck._save_path) and
			WorkspaceLayout.to_pixels(restored.workspaces[restored.active].panels.people.rect, deck.area.size).size.distance_to(window.size) < 0.01,
			"float resize persists at %s" % scale)
		deck.toggle_panel_headers()
		await _settle_layout()
		pointer = window.drag_strip.global_position + Vector2(40, 12)
		var before := window.position
		await _parse(_mouse_button(MOUSE_BUTTON_LEFT, true, pointer))
		motion = _mouse_motion(pointer + Vector2(40, 20))
		motion.alt_pressed = true
		await _parse(motion)
		await _parse(_mouse_button(MOUSE_BUTTON_LEFT, false, motion.position))
		_assert(window.position.distance_to(before + Vector2(40, 20)) < 1 and not deck.model.show_panel_headers, "visible hidden-header strip moves without changing header intent at %s" % scale)
		var restore_button: Button = window.drag_strip.get_child(1)
		pointer = restore_button.get_global_rect().get_center()
		await _parse(_mouse_button(MOUSE_BUTTON_LEFT, true, pointer))
		await _parse(_mouse_button(MOUSE_BUTTON_LEFT, false, pointer))
		_assert(deck.model.show_panel_headers and window.titlebar.visible, "visible Headers button restores controls at %s" % scale)
		deck.state("people").pinned = true
		deck._apply_layout()
		await _settle_layout()
		pointer = window.titlebar.global_position + Vector2(40, 12)
		before = window.position
		await _parse(_mouse_button(MOUSE_BUTTON_LEFT, true, pointer))
		await _parse(_mouse_motion(pointer + Vector2(40, 20)))
		await _parse(_mouse_button(MOUSE_BUTTON_LEFT, false, pointer + Vector2(40, 20)))
		_assert(window.position == before and window._gesture.is_empty() and "geometry only" in window.pin_button.tooltip_text, "pin locks geometry with explicit tooltip at %s" % scale)
		deck.state("people").pinned = false
		deck._apply_layout()
		await _settle_layout()
		pointer = window.titlebar.global_position + Vector2(40, 12)
		saved = deck.state("people").duplicate(true)
		await _parse(_mouse_button(MOUSE_BUTTON_LEFT, true, pointer))
		await _parse(_mouse_motion(pointer + Vector2(40, 20)))
		deck.set_panel_authorized("people", false)
		_assert(not window.visible and window._gesture.is_empty() and deck.state("people").rect == saved.rect, "permission loss rolls back movement without changing intent at %s" % scale)
		await _parse(_mouse_button(MOUSE_BUTTON_LEFT, false, pointer + Vector2(40, 20)))
		deck.set_panel_authorized("people", true)
		await _settle_layout()
		pointer = window.titlebar.global_position + Vector2(40, 12)
		await _parse(_mouse_button(MOUSE_BUTTON_LEFT, true, pointer))
		await _parse(_mouse_motion(pointer + Vector2(40, 0)))
		deck.toggle_map_only()
		_assert(window._gesture.is_empty() and not window.visible and deck.state("people").rect == saved.rect and deck._map.get_global_rect() == deck.area.get_global_rect(), "Map mode cancels movement and restores saved intent at %s" % scale)
		await _parse(_mouse_button(MOUSE_BUTTON_LEFT, false, pointer + Vector2(40, 0)))
		deck.toggle_map_only()
		deck.size = Vector2(600, 600)
		deck._apply_layout()
		await _settle_layout()
		pointer = window.titlebar.global_position + Vector2(40, 12)
		await _parse(_mouse_button(MOUSE_BUTTON_LEFT, true, pointer))
		await _parse(_mouse_motion(pointer + Vector2(40, 20)))
		await _parse(_mouse_button(MOUSE_BUTTON_LEFT, false, pointer + Vector2(40, 20)))
		_assert(deck.compact and window._gesture.is_empty() and deck.state("people").rect == saved.rect and deck._map.get_global_rect() == deck.area.get_global_rect(), "compact panels keep desktop geometry and never shrink the map at %s" % scale)
		deck.size = host.get_visible_rect().size
		deck._apply_layout()
		await _settle_layout()
		_assert(viewport_builds == builds and viewport_selections == selections, "Input.parse_input_event title/strip/corner gestures never dispatch map actions at %s" % scale)
		var map := deck._map as ColonyMap
		var map_point := Vector2.ZERO
		var found := false
		for y in map._grid.y:
			for x in map._grid.x:
				var candidate := map.global_position + map._origin() + (Vector2(x, y) + Vector2.ONE * 0.5) * map._cell_size()
				if not deck.blocks_map_input(candidate):
					map_point = candidate
					found = true
					break
			if found:
				break
		_assert(found, "full map retains uncovered pickable cells at %s" % scale)
		map.set_interaction_mode(&"build")
		await _parse(_mouse_button(MOUSE_BUTTON_LEFT, true, map_point))
		_assert(map._dragging, "native scaled pointer maps correctly into an uncovered build cell at %s" % scale)
		await _parse(_mouse_button(MOUSE_BUTTON_LEFT, false, map_point))
		_assert(viewport_builds == builds + 1 and not map._dragging, "uncovered map emits exactly one build intent at %s" % scale)
		builds = viewport_builds
	deck.model.workspaces[deck.model.active].panels = old_panels
	host.content_scale_factor = old_scale
	host.size = old_size
	deck.size = old_deck_size
	deck._apply_layout()
	await _settle_layout()
	print("WORKSPACE_DIRECT_INTERACTION_PASS Input.parse_input_event native-window-100-125-150 footprint offset corner-resize hidden-strip restore pin escape permission compact full-map map-exclusion")

func _parse(event: InputEvent) -> void:
	event = event.duplicate()
	# Input singleton accepts native-window pixels, unlike Viewport.push_input.
	if event is InputEventMouse:
		event.position = get_viewport().get_final_transform() * event.position
		event.global_position = event.position
	Input.parse_input_event(event)
	await get_tree().process_frame
	await get_tree().process_frame

## Many overlapping floating frames retain z-order and usable scroll bodies.
func _test_floating_overlap(deck: WorkspaceDeck) -> void:
	var original_panels: Dictionary = deck.model.workspaces[deck.model.active].panels.duplicate(true)
	var original_authorized := deck.authorized.duplicate()
	var original_size := deck.size
	var original_compact_panel := deck._compact_panel
	var host := get_tree().root
	var original_host_size := host.size
	var original_scale := host.content_scale_factor
	var probes := {}
	var activated := [0]
	for key: String in deck.windows:
		deck.authorized[key] = true
		deck.state(key).open = true
		deck.state(key).minimized = false
		deck.state(key).rect = [0.2, 0.2, 0.3, 0.45]
		var fixture := VBoxContainer.new()
		var spacer := Control.new()
		spacer.custom_minimum_size.y = WorkspaceLayout.MIN_SIZE.y * 2
		fixture.add_child(spacer)
		var action := Button.new()
		action.text = "Reach %s action" % key
		action.custom_minimum_size.y = ThemeTokens.number("control-md")
		action.pressed.connect(func() -> void: activated[0] += 1)
		fixture.add_child(action)
		deck.windows[key].content.add_child(fixture)
		probes[key] = {"fixture": fixture, "action": action}
	for scale: float in [1.0, 1.25, 1.5]:
		host.size = Vector2i(1440, 900)
		host.content_scale_factor = scale
		await _settle_layout()
		deck.size = host.get_visible_rect().size
		deck._apply_layout()
		await _settle_layout()
		_assert(not deck.compact and deck._map.get_global_rect() == deck.area.get_global_rect(), "ten overlapping panels never shrink map at %s" % scale)
		for key: String in deck.windows:
			deck.focus_panel(key)
			var window: WorkspaceWindow = deck.windows[key]
			_assert(deck.area.get_child(-1) == window and window.size.x >= 280 and window.size.y >= 180, "focused %s is raised with usable minimum geometry" % key)
			_assert(deck.blocks_map_input(window.get_global_rect().get_center()), "floating %s excludes map input" % key)
			var action: Button = probes[key].action
			action.grab_focus()
			await _settle_layout()
			_assert(_unclipped_control_rect(action).encloses(action.get_global_rect()), "keyboard follow-focus reveals %s final body action at %s: action %s visible %s scroll %s offset %s" % [key, scale, action.get_global_rect(), _unclipped_control_rect(action), window.scroll.get_global_rect(), window.scroll.scroll_vertical])
			var before: int = activated[0]
			var pointer := action.get_global_rect().get_center()
			await _parse(_mouse_button(MOUSE_BUTTON_LEFT, true, pointer))
			await _parse(_mouse_button(MOUSE_BUTTON_LEFT, false, pointer))
			_assert(activated[0] == before + 1, "real pointer activates topmost %s body exactly once" % key)
			_assert(deck.state(key).rect == [0.2, 0.2, 0.3, 0.45], "overlap and focus do not rewrite %s geometry" % key)
	for key: String in probes:
		deck.windows[key].content.remove_child(probes[key].fixture)
		probes[key].fixture.queue_free()
	deck.model.workspaces[deck.model.active].panels = original_panels
	deck.authorized = original_authorized
	deck._compact_panel = original_compact_panel
	host.content_scale_factor = original_scale
	host.size = original_host_size
	deck.size = original_size
	deck._apply_layout()
	await _settle_layout()
	print("WORKSPACE_FLOATING_OVERLAP_PASS ten-panels z-order full-map native-window-100-125-150 scroll-body pointer-actions")

func _test_retained_body_focus_resize(deck: WorkspaceDeck) -> void:
	var host := get_tree().root
	var old_host_size := host.size
	var old_scale := host.content_scale_factor
	var old_size := deck.size
	var old_panels: Dictionary = deck.model.workspaces[deck.model.active].panels.duplicate(true)
	var window: WorkspaceWindow = deck.windows.people
	for key: String in deck.windows:
		deck.state(key).open = key == "people"
	deck.state("people").minimized = false
	deck.state("people").pinned = true
	deck.state("people").rect = [0.1, 0.1, 0.32, 0.6]
	var fixture := VBoxContainer.new()
	var spacer := Control.new()
	spacer.custom_minimum_size.y = 900
	fixture.add_child(spacer)
	var action := Button.new()
	action.text = "Final body action"
	fixture.add_child(action)
	window.content.add_child(fixture)
	var activated := [0]
	action.pressed.connect(func() -> void: activated[0] += 1)
	for budget: Dictionary in [
		{"size": Vector2i(1440, 900), "scale": 1.0},
		{"size": Vector2i(1440, 900), "scale": 1.25},
		{"size": Vector2i(1440, 900), "scale": 1.5},
		{"size": Vector2i(1280, 840), "scale": 1.5},
	]:
		host.size = budget.size
		host.content_scale_factor = budget.scale
		await _settle_layout()
		deck.size = host.get_visible_rect().size
		deck._apply_layout()
		await _settle_layout()
		if budget.scale == 1.0:
			action.grab_focus()
			await _settle_layout()
		_assert(get_viewport().gui_get_focus_owner() == action, "body resize retains the exact focused node at %s/%s" % [budget.size, budget.scale])
		_assert(_unclipped_control_rect(action).encloses(action.get_global_rect()), "retained final body action is fully revealed after %s/%s" % [budget.size, budget.scale])
		var before: int = activated[0]
		var key := InputEventKey.new()
		key.keycode = KEY_SPACE
		key.pressed = true
		await _parse(key)
		key.pressed = false
		await _parse(key)
		_assert(activated[0] == before + 1, "retained body action remains keyboard reachable after resize")
		var point := action.get_global_rect().get_center()
		await _parse(_mouse_button(MOUSE_BUTTON_LEFT, true, point))
		await _parse(_mouse_button(MOUSE_BUTTON_LEFT, false, point))
		_assert(activated[0] == before + 2 and get_viewport().gui_get_focus_owner() == action, "revealed body action remains pointer reachable without focus replacement")
		var scroll_before := window.scroll.scroll_vertical
		deck._apply_layout()
		await _settle_layout()
		_assert(window.scroll.scroll_vertical == scroll_before, "already visible retained focus does not reset scroll on repeated layout")
	window.content.remove_child(fixture)
	fixture.queue_free()
	deck.model.workspaces[deck.model.active].panels = old_panels
	host.size = old_host_size
	host.content_scale_factor = old_scale
	deck.size = old_size
	deck._apply_layout()
	await _settle_layout()
	print("WORKSPACE_RETAINED_BODY_FOCUS_PASS same-node scale-100-125-150 viewport-resize clipping keyboard pointer pinned no-scroll-reset")

func _test_navigation_focus(deck: WorkspaceDeck) -> void:
	var viewport := get_viewport()
	deck._rebuild_navigation()
	var tab: Button = deck._tab_buttons.daily
	tab.grab_focus()
	deck.set_workspace_alert_summary("daily", "warn", 3)
	await _settle_layout()
	_assert(viewport.gui_get_focus_owner() == tab and deck._tab_buttons.daily == tab,
		"changed alert count retains the same actual focused tab node")
	deck.set_workspace_alert_summary("daily", "warn", 3)
	await _settle_layout()
	_assert(viewport.gui_get_focus_owner() == tab, "unchanged alert summary is a focus-preserving no-op")
	deck.set_workspace_alert_summary("daily", "critical", 4)
	deck.set_workspace_alert_summary("daily", "warn", 0)
	await _settle_layout()
	_assert(viewport.gui_get_focus_owner() == tab and not deck._tab_alert_nodes.daily.count.visible,
		"severity and count removal update glyph/count in place without discarding focus")
	deck.switch_workspace("build")
	await _settle_layout()
	_assert(viewport.gui_get_focus_owner() == deck._tab_buttons.daily and deck.model.active == "build",
		"workspace selection preserves valid navigation identity across structural rebuild")
	var new_button: Button
	for button: Button in deck.find_children("*", "Button", true, false):
		if button.text == "+ New":
			new_button = button
	new_button.grab_focus()
	deck.set_workspace_alert_summary("build", "warn", 2)
	deck.set_panel_authorized("admin", false)
	await _settle_layout()
	_assert(viewport.gui_get_focus_owner() == new_button, "alert updates and revocation never steal New-button focus")
	deck.edit_workspace(false)
	await _settle_layout()
	deck._name_input.grab_focus()
	deck.set_workspace_alert_summary("build", "critical", 5)
	deck.set_panel_authorized("developer", false)
	await _settle_layout()
	_assert(deck._dialog.gui_get_focus_owner() == deck._name_input,
		"alert updates and role changes preserve chooser text focus")
	deck._dialog.hide()
	deck.switch_workspace("daily")
	deck.set_panel_authorized("admin", true)
	deck.set_panel_authorized("developer", true)
	deck.state("admin").open = true
	deck._changed()
	await _settle_layout()
	deck._panel_buttons.admin.grab_focus()
	deck.set_panel_authorized("admin", false)
	await _settle_layout()
	_assert(viewport.gui_get_focus_owner() == null and not deck._panel_buttons.has("admin"),
		"revoked panel-navigation identity is cleared rather than restored")
	deck.set_panel_authorized("admin", true)
	deck.windows.admin.pin_button.grab_focus()
	deck.set_panel_authorized("admin", false)
	await _settle_layout()
	_assert(viewport.gui_get_focus_owner() == null and not deck.windows.admin.visible,
		"revocation clears focus within the denied live panel")
	deck.set_panel_authorized("admin", true)
	deck.state("admin").open = false
	deck._changed()
	await _settle_layout()
	print("WORKSPACE_NAVIGATION_FOCUS_PASS changed unchanged removed selection new chooser revocation")

func _settle_layout() -> void:
	for _frame in 4:
		await get_tree().process_frame

func _unclipped_control_rect(control: Control) -> Rect2:
	var visible := control.get_global_rect().intersection(control.get_viewport().get_visible_rect())
	var parent := control.get_parent()
	while parent != null:
		if parent is Control and parent.clip_contents:
			visible = visible.intersection(parent.get_global_rect())
		parent = parent.get_parent()
	return visible

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
