## Actual Main, typed local world, isolated renderer; never connects a server.
extends "res://tools/ui_composition_fixture.gd"

var capture_panel := "construction"
var fixture_rooms: Array = []
var fixture_thermal: Array = []
var panel_width := 0
var header_state := ""

func _ready() -> void:
	for argument in OS.get_cmdline_user_args():
		if argument.begins_with("--screen="):
			var parts := argument.trim_prefix("--screen=").split("x")
			_screen = Vector2i(int(parts[0]), int(parts[1]))
		if argument.begins_with("--scale="): _scale = int(argument.trim_prefix("--scale="))
		if argument.begins_with("--capture="): _capture = argument.trim_prefix("--capture=")
		if argument.begins_with("--panel="): capture_panel = argument.trim_prefix("--panel=")
		if argument.begins_with("--panel-width="): panel_width = int(argument.trim_prefix("--panel-width="))
		if argument.begins_with("--header-state="): header_state = argument.trim_prefix("--header-state=")
	get_window().size = _screen
	_previous_db = SpacetimeDB.Continuum.db
	seed_world()
	main = MainScene.instantiate()
	get_tree().root.add_child.call_deferred(main)
	await get_tree().process_frame
	main._session_requested = true
	main._state_ready = true
	main._menu.hide()
	main._server_management.hide()
	main._set_permissions("Operator", true, false)
	var settings: ClientSettings = main._settings.clone()
	settings.ui_scale_percent = _scale
	main.apply_settings(settings, false)
	main.map.refresh()
	main.map.reset_camera()
	main.workspace.switch_workspace("build")
	main.workspace.focus_panel(capture_panel)
	main.workspace._apply_layout()
	main._selected_rect = Rect2i(125, 123, 1, 1)
	main.map.set_selected_rect(main._selected_rect)
	main._selected_surface = main.map.terrain_model.capture_selection(main._selected_rect)
	main._refresh()
	for frame in 12: await get_tree().process_frame
	if panel_width > 0:
		for key in ["construction", "operations"]:
			main.workspace.state(key).rect[2] = panel_width / main.workspace.area.size.x
		main.workspace._apply_layout()
	if main.has_method("_activate_planning"):
		main._activate_planning(&"construction" if capture_panel == "construction" else &"zones")
		if main.workspace.compact:
			check(main.workspace.state(capture_panel).minimized, "compact Draw action reveals map by minimizing its panel")
			main.workspace.state(capture_panel).minimized = false
		main.workspace.focus_panel(capture_panel)
		main.workspace._apply_layout()
	for frame in 4: await RenderingServer.frame_post_draw
	if header_state == "cancelled":
		main._set_permissions("Viewer", false, false)
		main._set_permissions("Operator", true, false)
	elif header_state == "escape":
		main._intent_feedback.get_parent().get_child(1).grab_focus()
		var escape := InputEventKey.new()
		escape.keycode = KEY_ESCAPE
		escape.pressed = true
		escape.window_id = get_window().get_window_id()
		Input.parse_input_event(escape)
	elif header_state == "menu":
		main.workspace._menu.show_popup()
		for frame in 4: await RenderingServer.frame_post_draw
		var popup: PopupMenu = main.workspace._menu.get_popup()
		check(popup.visible, "native Panels dropdown opens above armed planning UI")
		var escape := InputEventKey.new()
		escape.keycode = KEY_ESCAPE
		escape.pressed = true
		escape.window_id = popup.get_window_id()
		Input.parse_input_event(escape)
	for frame in 8: await RenderingServer.frame_post_draw
	if header_state in ["cancelled", "escape"]:
		check(main._planning_system == &"" and not main._intent_feedback.get_parent().visible, "cancelled tool restores idle header in the native window")
		if main.size.x <= 390:
			check(main.workspace.header.size.y <= 202, "native narrow idle header retains the original 202px budget")
	elif header_state == "menu":
		check(not main.workspace._menu.get_popup().visible and main._planning_system != &"", "native Escape closes Panels without cancelling its underlying map tool")
	for key in ["construction", "operations"]:
		var window: WorkspaceWindow = main.workspace.windows[key]
		if window.is_visible_in_tree():
			check(main.workspace.area.get_global_rect().encloses(window.get_global_rect()), "planning window stays inside viewport")
			check(window.scroll.get_h_scroll_bar().max_value <= window.scroll.size.x + 1, "planning panel fits minimum width without horizontal scrolling")
	check(main._construction_panel.activate.focus_mode == Control.FOCUS_ALL and main._zones_panel.remove.focus_mode == Control.FOCUS_ALL, "planning actions remain keyboard focusable")
	var image := get_viewport().get_texture().get_image()
	image.save_png(_capture)
	print("PLANNING_CAPTURE ", _capture, " ", image.get_size())
	main._state_ready = false
	main._return_key = ""
	main.free()
	SpacetimeDB.Continuum.db = _previous_db
	local.free()
	get_tree().quit(0 if failures.is_empty() else 1)

func seed_world() -> void:
	var builder := preload("res://tools/map_client_profile.gd").new()
	builder.edge = 256
	local = builder.database(false)
	builder.free()
	var colony: ContinuumColony = local._tables.colony[0]
	colony.food = 360
	colony.wood = 680
	colony.stone = 90
	colony.population = 8
	colony.avg_mood = 72
	colony.avg_productivity = 86
	for id in local._tables.colonist:
		var actor: ContinuumColonist = local._tables.colonist[id]
		actor.name = ["Bram", "Enid", "Finn", "Mara", "Otis", "Rin", "Sora", "Alex"][id]
		actor.x = 121 + id
		actor.y = 120
		actor.z = 0
		actor.next_x = actor.x
		actor.next_y = actor.y
		actor.next_z = 0
	var next_id := 900001
	for y in range(122, 125):
		for x in range(124, 129):
			local._tables.tile[next_id] = ContinuumTile.create(next_id, x, y, ContinuumTileKind.create_storage(), true, 0, 1, 1, 4)
			next_id += 1
	for y in range(128, 134):
		for x in range(117, 120):
			local._tables.tile[next_id] = ContinuumTile.create(next_id, x, y, ContinuumTileKind.create_farm(), true, 0, 1, 1, 4)
			next_id += 1
	fixture_rooms = [ContinuumBuilding.create(71, ContinuumBuildingKind.create_insulated_room(), 123, 121, 0, 7, 5, 4, 175.0)]
	fixture_thermal = [ContinuumBuildingThermalProperty.create(71, 2.0)]
	local._tables.building[71] = fixture_rooms[0]
	local._tables.building_thermal_property[71] = fixture_thermal[0]
	TerrainFixture.index_rows(local)
