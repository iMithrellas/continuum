## Input and controller contract for the user-facing map UI.
## Live: scripts/internal/test-map-ui supplies queried starter XY and owns its server.
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
var assertions := 0


func _ready() -> void:
	if _has_user_arg("--map-ui-intentional-failure"):
		_fail("intentional failure validation")
		return
	_assert(
		MapUiModel.normalize_rect(Vector2i(7, 4), Vector2i(2, 1)) == Rect2i(2, 1, 6, 4),
		"reverse drag is normalized inclusively"
	)
	_assert(
		MapUiModel.normalize_rect(Vector2i(3, 3), Vector2i(3, 3)) == Rect2i(3, 3, 1, 1),
		"single cell remains one cell"
	)
	_assert(MapUiModel.cells(Rect2i(0, 0, 5, 2)) == 10, "rectangle cost uses area")
	_assert(
		MapUiModel.clamp_cell(Vector2i(-4, 30), Vector2i(24, 24)) == Vector2i(0, 23),
		"helper clamping remains deterministic"
	)
	await _test_map_input()
	if failed:
		return
	await _test_controller_surface()
	if failed:
		return
	print("MAP_UI_PASS ", assertions, " assertions")
	get_tree().quit(0)


func _has_user_arg(value: String) -> bool:
	return value in OS.get_cmdline_user_args()


func _test_map_input() -> void:
	var previous_db := SpacetimeDB.Continuum.db
	var local: LocalDatabase
	if previous_db == null:
		var fixture := preload("res://tools/map_client_profile.gd").new()
		local = fixture.database()
		fixture.free()
	await _test_flat_map_input()
	SpacetimeDB.Continuum.db = previous_db
	map.bind_world_source(previous_db)
	if local != null:
		local.free()


func _test_flat_map_input() -> void:
	map = ColonyMap.new()
	map.bind_world_source(SpacetimeDB.Continuum.db)
	map.size = Vector2(480, 570)
	map._has_state = true
	map._grid = Vector2i(24, 24)
	get_tree().root.add_child.call_deferred(map)
	await get_tree().process_frame
	map.build_rectangle_requested.connect(
		func(rect: Rect2i) -> void:
			build_releases += 1
			build_rects.append(rect)
	)
	map.rectangle_selected.connect(
		func(rect: Rect2i) -> void:
			selected_releases += 1
			selected_rects.append(rect)
	)
	map.set_interaction_mode(&"build")
	_drag(Vector2(130, 130), Vector2(30, 50))
	_assert(build_releases == 1, "one reversed build drag emits one atomic request")
	if failed:
		return
	_assert(build_rects[0] == Rect2i(1, 0, 6, 5), "reversed drag payload is exact")
	_assert(not map._dragging, "drag state clears after release")

	_drag(Vector2(70, 70), Vector2(70, 70))
	_assert(build_releases == 2, "one-cell build drag emits one request")
	if failed:
		return
	_assert(build_rects[1] == Rect2i(3, 1, 1, 1), "single-cell payload is exact")
	_release(Vector2(70, 70))
	_assert(build_releases == 2, "repeated release cannot submit another build")

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
	if failed:
		return
	_assert(selected_rects[0] == Rect2i(10, 8, 3, 3), "selection payload is exact")


func _test_controller_surface() -> void:
	get_tree().root.size = Vector2i(1440, 900)
	var main := TestMainScene.instantiate()
	get_tree().root.add_child.call_deferred(main)
	await main.ready
	# Exercise the ordinary-player authorization catalog even under developer CLI.
	main._profile = "normal"
	main._set_permissions("Unknown", false, false)
	isolated_path = main.fixture_workspace_path
	main.apply_font_size(10, false)
	_assert(
		(
			main._metrics.base_font_size == 13
			and main._settings.ui_scale_percent == 100
			and main.get_window().content_scale_factor == 1.0
			and main._haul_button.get_theme_font_size("font_size") == 13
			and main._construction_panel.activate.get_theme_font_size("font_size") == 13
		),
		"legacy lower font bound migrates to 100% without shrinking canonical typography"
	)
	await _test_header_geometry(main)
	var clock_baseline: float = _label_baseline(main._clock) - main._clock_group.global_position.y
	var maximum_scale := ClientSettings.legacy_ui_scale(ClientSettings.MAX_FONT_SIZE)
	main.apply_font_size(ClientSettings.MAX_FONT_SIZE, false)
	_assert(
		(
			main._metrics.base_font_size == 13
			and main._settings.ui_scale_percent == maximum_scale
			and main.get_window().content_scale_factor == float(maximum_scale) / 100.0
			and main._feed.custom_minimum_size.y == 70
			and main._history_chart.custom_minimum_size.y == 108
			and main.workspace.windows.status.size.y == 30
			and main._haul_button.get_theme_font_size("font_size") == 13
			and (
				main._connection_label.get_theme_font_size("font_size")
				== ThemeTokens.font_size("small")
			)
		),
		"legacy maximum font bound scales the entire viewport once while logical metrics remain fixed"
	)
	await _test_header_geometry(main)
	_assert(
		is_equal_approx(
			_label_baseline(main._clock) - main._clock_group.global_position.y, clock_baseline
		),
		"clock baseline inside the status micro remains stable at %d percent" % maximum_scale
	)
	main.apply_font_size(13, false)
	_assert(
		(
			main._haul_button.get_theme_font_size("font_size") == 13
			and main.get_window().content_scale_factor == 1.0
		),
		"runtime reference size restores exactly"
	)
	main.apply_font_size(10, false)
	_assert(
		(
			main._metrics.base_font_size == 13
			and main._feed.custom_minimum_size.y == 70
			and main._haul_button.get_theme_font_size("font_size") == 13
			and main.get_window().content_scale_factor == 1.0
		),
		"runtime scaling returns to 100% without compounding or shrinking typography"
	)
	main.apply_font_size(13, false)
	_assert(
		(
			main._construction_panel != null
			and main._zones_panel != null
			and main._mode_buttons.has(&"excavate")
		),
		"separate planning panels and terrain work are reachable"
	)
	_set_role(main, "operator", true, false)
	_assert(
		(
			main._zones_panel.choices.size() == 7
			and main._zones_panel.choices.has(ContinuumTileKind.Options.forest)
		),
		"all seven non-empty usage types are reachable only in Zones"
	)
	main._set_mode(&"build")
	_assert(main.map.interaction_mode == &"build", "build button changes map mode")
	main._set_mode(&"select")
	_assert(main.map.interaction_mode == &"select", "select button changes map mode")
	_assert(main._block_box.visible and main._block_info != null, "block control panel is visible")
	_assert(main._block_controls.size() == 6, "enable/disable and four work controls are reachable")
	_assert(
		main._tile_action_box.visible and main._tile_info != null,
		"one-cell inspection detail remains visible"
	)
	_assert(
		main._block_controls[ContinuumWorkType.Options.farming].row.visible,
		"block work controls are not hidden by legacy refresh"
	)
	await _test_workspace_surface(main)
	if failed:
		return
	main._map_dirty = false
	main._on_table_changed("terrain")
	_assert(main._map_dirty, "terrain updates invalidate map rendering")
	_assert(main.can_send_map_intent(true, false), "ready client may send map intent")
	_assert(
		not main.can_send_map_intent(false, false) and not main.can_send_map_intent(true, true),
		"disconnected and pending clients are gated"
	)
	await _refresh_real_tiles(main)
	DirAccess.remove_absolute(ProjectSettings.globalize_path(isolated_path))


func _test_header_geometry(main: Control) -> void:
	for frame in 8:
		await get_tree().process_frame
	var status: Rect2 = main.workspace.windows.status.get_global_rect()
	var clock: Rect2 = main._clock_group.get_global_rect()
	_assert(
		(
			not main.workspace.header.visible
			and main.workspace.area.position == Vector2.ZERO
			and main.workspace.area.size == main.size.floor()
			and main.map.get_global_rect() == main.workspace.area.get_global_rect()
		),
		(
			"Atlas map owns the full logical viewport without a global header: area=%s main=%s map=%s"
			% [
				main.workspace.area.get_global_rect(),
				main.get_global_rect(),
				main.map.get_global_rect()
			]
		)
	)
	_assert(
		(
			status.size.y == 30
			and status.encloses(clock)
			and (
				absf(status.get_center().x - main.workspace.area.get_global_rect().get_center().x)
				<= 1
			)
		),
		"30px status micro is centered on the viewport independently of other panels"
	)
	for label: Label in [main._clock, main._population]:
		if not label.is_visible_in_tree():
			continue
		_assert(
			(
				clock.encloses(label.get_global_rect())
				and label.get_combined_minimum_size().x <= label.size.x
			),
			"clock and crew text fit their content-sized micro without clipping"
		)
	_assert(
		(
			not main._clock.text.contains("\n")
			and not main._population.text.contains("\n")
			and (
				not main._population.is_visible_in_tree()
				or absf(_label_baseline(main._clock) - _label_baseline(main._population)) <= 1
			)
		),
		"clock and crew occupy one micro line"
	)
	var resource_state: Dictionary = main.workspace.state("resources")
	var was_open: bool = resource_state.open
	var was_minimized: bool = resource_state.minimized
	resource_state.open = true
	resource_state.minimized = false
	main.workspace.focus_panel("resources")
	main.workspace._apply_layout()
	for frame in 8:
		await get_tree().process_frame
	var resources: Rect2 = main.workspace.windows.resources.get_global_rect()
	_assert(main.workspace.windows.resources.visible, "independent Resources panel opens")
	_assert(
		main.workspace.area.get_global_rect().encloses(resources), "Resources stays within viewport"
	)
	var previous_card := Rect2()
	var previous_baseline := 0.0
	for card: ResourceReadout in main._resource_labels.values():
		var bounds := card.get_global_rect()
		_assert(
			(
				main._resource_group.get_global_rect().encloses(bounds)
				and card.get_parent() == main._resource_group
				and bounds.position.x >= resources.position.x
				and bounds.end.x <= resources.end.x
				and main.workspace.windows.resources.scroll.clip_contents
			),
			"resource readouts fit independent panel width; vertical overflow is scroll-clipped"
		)
		for label: Label in card.find_children("*", "Label", true, false):
			_assert(
				(
					bounds.encloses(label.get_global_rect())
					and label.get_combined_minimum_size().x <= label.size.x
				),
				"resource names, values and secondary text fit their card"
			)
		var value: Label = card.find_child("ResourceValue", true, false)
		_assert(
			value != null, "resource value has a semantic label rather than a child-index contract"
		)
		var baseline := _label_baseline(value)
		if previous_card.has_area():
			_assert(not previous_card.intersects(bounds), "adjacent resource cards never overlap")
			if previous_card.position.y == bounds.position.y:
				_assert(
					absf(baseline - previous_baseline) <= 1,
					"resource values share a stable row baseline"
				)
		previous_card = bounds
		previous_baseline = baseline
	resource_state.open = was_open
	resource_state.minimized = was_minimized
	main.workspace._apply_layout()


func _label_baseline(label: Label) -> float:
	var font := label.get_theme_font("font")
	var font_size := label.get_theme_font_size("font_size")
	return (
		label.global_position.y
		+ (label.size.y - font.get_height(font_size)) * 0.5
		+ font.get_ascent(font_size)
	)


func _test_workspace_surface(main: Control) -> void:
	_assert(
		main._sections.size() == 15 and main.workspace.windows.size() == 15,
		"Atlas catalog exposes fifteen extensible panels"
	)
	var authorized_count := 0
	for allowed: bool in main.workspace.authorized.values():
		authorized_count += int(allowed)
	_assert(authorized_count == 13, "normal Operator has thirteen authorized Atlas panels")
	_assert(
		main.workspace.model.workspaces.size() == 4 and main.workspace.model.active == "daily",
		"workspace manager starts on the daily built-in layout"
	)
	_assert(
		not main._orders_help.text.contains("\n") and not main._orders_help.tooltip_text.is_empty(),
		"compact order help retains hover details"
	)
	main._set_feedback(main._intent_feedback, "Failed", "Full reducer error detail")
	_assert(
		(
			main._intent_feedback.text == "Failed"
			and main._intent_feedback.tooltip_text == "Full reducer error detail"
		),
		"error status stays concise while retaining details"
	)
	_set_role(main, "viewer", false, false)
	_assert(
		not main.workspace.authorized["policies"] and not main.workspace.authorized["operations"],
		"viewer workspace authorization fails closed"
	)
	_assert(
		(
			not main.workspace.authorized["construction"]
			and not main._mode_buttons[&"excavate"].visible
			and not main._block_box.visible
		),
		"viewer cannot see mutation controls"
	)
	main.map_intent_override = _record_reducer_call
	var before := reducer_calls.size()
	main._on_build_rectangle_requested(Rect2i(1, 1, 1, 1))
	_assert(reducer_calls.size() == before, "programmatic build is guarded for viewers")
	_set_role(main, "operator", true, false)
	_assert(
		main.workspace.authorized["policies"] and main.workspace.authorized["operations"],
		"operator inherits policy and operations workspace access"
	)
	for mode: StringName in [&"build", &"excavate", &"facility"]:
		main._set_mode(mode)
		_set_role(main, "viewer", false, false)
		_assert(
			main.map.interaction_mode == &"select" and not main.map._dragging,
			"permission loss cancels armed %s mode and paint" % mode
		)
		_set_role(main, "operator", true, false)
	var ack_probe := Button.new()
	ack_probe.text = "Ack"
	main._alert_box.add_child(ack_probe)
	_assert(ack_probe.is_inside_tree(), "operator alert rows are present before downgrade")
	_set_role(main, "viewer", false, false)
	await get_tree().process_frame
	_assert(
		not is_instance_valid(ack_probe), "permission downgrade immediately rebuilds alert rows"
	)
	_set_role(main, "operator", true, false)
	_set_role(main, "maintenance", true, false)
	_assert(
		not main._can_operate and main._role_name == "Unknown", "unknown role input fails closed"
	)
	_set_role(main, "admin", true, false)
	_assert(not main._can_operate and not main._is_admin, "inconsistent admin flags fail closed")
	_set_role(main, "admin", true, true)
	_assert(
		(
			main.workspace.authorized["policies"]
			and main.workspace.authorized["operations"]
			and main.workspace.authorized["admin"]
		),
		"verified admin can see the admin panel"
	)
	_assert(
		(
			main._speed_label.get_parent() == main._sections["admin"]
			and main._speed_strip.get_parent() == main._sections["admin"]
		),
		"speed controls belong to admin content, not telemetry"
	)
	_assert(not main.workspace.authorized["developer"], "normal profile has no developer utilities")
	_assert(
		main._construction_panel.activate.disabled and main._zones_panel.activate.disabled,
		"disconnected or pending state disables planning"
	)
	var desktop_size := main.size
	main.size = Vector2(390, 844)
	await get_tree().process_frame
	await get_tree().process_frame
	_assert(
		main.workspace.compact and main.workspace.area.size.x == 390,
		"production UI fits a phone viewport without a fixed-width sidebar"
	)
	await _test_header_geometry(main)
	await _test_planning_header_geometry(main)
	main.size = desktop_size
	await get_tree().process_frame
	await get_tree().process_frame
	for window: WorkspaceWindow in main.workspace.windows.values():
		window.size = WorkspaceLayout.MIN_SIZE
	await get_tree().process_frame
	await get_tree().process_frame
	for window: WorkspaceWindow in main.workspace.windows.values():
		_assert(
			window.content.get_combined_minimum_size().x <= window.scroll.size.x,
			"panel contents fit minimum width: %s" % window.name
		)
	main.workspace._apply_layout()


## Atlas tool feedback does not reserve map rows; Escape still works from Cancel.
func _test_planning_header_geometry(main: Control) -> void:
	var quiet_bounds: Rect2 = main.map.get_global_rect()
	var row: HBoxContainer = main._intent_feedback.get_parent()
	_assert(not row.visible, "Inspect mode has no empty or cancelled-tool status row")
	main._set_mode(&"excavate")
	for frame in 8:
		await get_tree().process_frame
	_assert(
		(
			row.visible
			and not main.workspace.header.visible
			and main.map.get_global_rect() == quiet_bounds
		),
		"armed tool keeps feedback populated without shrinking the Atlas map"
	)
	await _test_header_geometry(main)
	var menu_was_visible: bool = main._menu.visible
	main._menu.hide()
	main.workspace.state("construction").open = true
	main.workspace.focus_panel("construction")
	main.workspace._apply_layout()
	main._construction_panel.activate.grab_focus()
	var escape := InputEventKey.new()
	escape.keycode = KEY_ESCAPE
	escape.pressed = true
	Input.parse_input_event(escape)
	for frame in 3:
		await get_tree().process_frame
	_assert(
		main._planning_system == &"",
		"native Escape from the focused planning action disarms the map tool"
	)
	escape = escape.duplicate()
	escape.pressed = false
	Input.parse_input_event(escape)
	main._menu.visible = menu_was_visible
	main._set_feedback(
		main._intent_feedback, "Failed", "Outcome detail remains available in the planning panels."
	)
	for frame in 8:
		await get_tree().process_frame
	_assert(
		(
			not row.visible
			and main.map.interaction_mode == &"select"
			and main.map.get_global_rect() == quiet_bounds
		),
		"cancel and subsequent idle outcome feedback preserve the full map viewport"
	)
	_assert(
		(
			main._construction_panel.feedback.visible
			and "Outcome detail" in main._construction_panel.feedback.text
		),
		"hiding idle header status preserves visible outcome details in the planning panel"
	)


func _refresh_real_tiles(main: Control) -> void:
	var client: ContinuumModuleClient = SpacetimeDB.Continuum
	var deadline := Time.get_ticks_msec() + 10000
	while (
		(not main._state_ready or client.db == null or client.db.tile.iter().is_empty())
		and Time.get_ticks_msec() < deadline
	):
		await get_tree().process_frame
	_assert(
		main._state_ready and client.db != null and not client.db.tile.iter().is_empty(),
		"private fixture subscription completes with tiles within 10 seconds"
	)
	if failed:
		return
	var occupied: ContinuumTile = null
	var empty: ContinuumTile = null
	main.map.refresh()
	_assert(main.map.layered, "real subscription contains matching authoritative terrain bindings")
	for tile: ContinuumTile in main.map.visible_tiles():
		if tile.kind.value == ContinuumTileKind.Options.empty and empty == null:
			empty = tile
		if tile.kind.value != ContinuumTileKind.Options.empty and occupied == null:
			occupied = tile
	_assert(occupied != null and empty != null, "fixture has occupied and empty tiles")
	main._on_rectangle_selected(ColonyMap.tile_footprint(occupied))
	main._selected_tile_id = occupied.id
	main._refresh_controls()
	_assert(
		main._block_box.visible and main._tile_info.text.contains("Selected:"),
		"occupied refresh keeps block primary and inspection detail"
	)
	var compatible := ColonyMap.compatible_work(occupied.kind.value)
	if not compatible.is_empty():
		_assert(
			not main._block_controls[compatible[0]].set.disabled,
			"occupied refresh enables compatible block work control"
		)
	main._on_rectangle_selected(ColonyMap.tile_footprint(empty))
	main._selected_tile_id = empty.id
	main._refresh_controls()
	_assert(
		main._block_box.visible and main._tile_info.text.contains("Selected:"),
		"empty refresh keeps block primary and inspection detail"
	)
	if not compatible.is_empty():
		_assert(
			main._block_controls[compatible[0]].set.disabled,
			"empty refresh disables incompatible block work control"
		)
	var area := Rect2i(empty.x, empty.y, 1, 1)
	main._activate_planning(&"zones")
	main._choose_zone(ContinuumTileKind.Options.farm)
	main._on_build_rectangle_requested(area)
	_assert(reducer_calls.size() == 1, "controller dispatches one reducer invocation")
	_assert(
		(
			reducer_calls[0][0] == "designate_zone_at"
			and reducer_calls[0][1].slice(0, 4) == [empty.x, empty.y, empty.x, empty.y]
			and reducer_calls[0][1][4] == main.map.terrain_model.uniform_base(area)
		),
		"reducer receives normalized inclusive rectangle and actual visible floor z"
	)
	main._on_build_rectangle_requested(area)
	_assert(reducer_calls.size() == 2, "each completed block maps to one reducer invocation")


func _set_role(main: Control, role: String, can_operate: bool, is_admin: bool) -> void:
	if main.fixture_access == null:
		main._create_access(SpacetimeDB.Continuum)
		main.fixture_access.changed.connect(main._set_permissions)
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
	assertions += 1
	if not condition:
		_fail(message)


func _fail(message: String) -> void:
	if failed:
		return
	failed = true
	printerr("MAP_UI_FAIL: %s" % message)
	get_tree().quit(1)
