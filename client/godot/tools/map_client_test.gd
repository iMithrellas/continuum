## Backend-free camera, input, HUD, sparse cells, and 128/256 render budgets.
extends Node

const Fixture = preload("res://tools/terrain_fixture.gd")
const Profile = preload("res://tools/map_client_profile.gd")
var failures := 0
var assertions := 0
var requests: Array = []

func check(value: bool, message: String) -> void:
	assertions += 1
	if not value:
		failures += 1
		push_error(message)

func button(index: MouseButton, pressed: bool, point: Vector2) -> InputEventMouseButton:
	var event := InputEventMouseButton.new()
	event.button_index = index
	event.pressed = pressed
	event.position = point
	return event

func global_button(map: ColonyMap, index: MouseButton, pressed: bool, point: Vector2) -> InputEventMouseButton:
	return button(index, pressed, map.get_global_transform() * point)

func counts(map: ColonyMap) -> Vector3i:
	return Vector3i(map.terrain_view.terrain_build_count, map.terrain_view.mask_build_count, map.terrain_view.entity_update_count)

func rendered_facilities(map: ColonyMap) -> Array:
	var entities: Array = []
	for canvas in map.terrain_view.canvases:
		for entity: Dictionary in canvas.entities:
			if entity.type == "facility":
				entities.append(entity)
	return entities

func _ready() -> void:
	call_deferred("run")

func run() -> void:
	var previous := SpacetimeDB.Continuum.db
	var local := Fixture.database()
	var map := ColonyMap.new()
	map.position = Vector2(41, 27) # global events must not be confused with local ones
	map.size = Vector2(512, 256)
	add_child(map)
	map.refresh()
	map.set_process(false)
	map.excavation_requested.connect(func(rect: Rect2i, z: int, height: int) -> void: requests.append([rect, z, height]))
	map.facility_requested.connect(func(cell: Vector3i) -> void: requests.append(cell))
	map.set_interaction_mode(&"excavate")
	var anchor := Vector2(153.25, 113.75)
	for factor in [1.2, 1.2, 1.0 / 1.2, 0.7, 3.0]:
		var world := map.screen_to_world(anchor)
		map.zoom_at(factor, anchor)
		check(map.screen_to_world(anchor).is_equal_approx(world), "zoom preserves the exact fractional world point under the cursor")
		check(map.world_to_screen(world).is_equal_approx(anchor), "camera inverse round-trips at every zoom")
	map.fit_camera()
	check(map._zoom == 1.0 and map._pan == Vector2.ZERO, "Fit restores the original fit camera")
	map.reset_camera()
	check(is_equal_approx(map.zoom_percent(), 100.0) and is_equal_approx(map._cell_size(), ThemeTokens.number("tile")), "1:1 resets to the 16 logical pixel display cell without changing physical coordinates")
	map.fit_camera()
	map.zoom_at(2.0, map.size * 0.5)
	# 400% display zoom is now 64px; explicitly pan the test cell outside.
	map.pan_by(Vector2(-60.25, -45.5))
	var point := map.world_to_screen(Vector2(3.5, 1.5))
	check(map._cell_at(point) == Vector2i(3, 1), "zoomed and panned picking uses exact actual coordinates")
	check(map._cell_at(map.world_to_screen(Vector2(0.5, 0.5))) == null, "offscreen cells cannot be picked through the map's clip rectangle")
	map._gui_input(button(MOUSE_BUTTON_LEFT, true, point))
	map._input(global_button(map, MOUSE_BUTTON_LEFT, false, point))
	check(requests.size() == 1 and requests.back() == [Rect2i(3, 1, 1, 1), -8, 6], "zoom/pan preserve exact xyz excavation payload, not cut or screen coordinates")
	map._gui_input(button(MOUSE_BUTTON_LEFT, true, point))
	map._gui_input(button(MOUSE_BUTTON_WHEEL_UP, true, point))
	map._input(global_button(map, MOUSE_BUTTON_LEFT, false, point))
	check(not map._dragging and requests.size() == 1, "wheel zoom cancels an edit drag without dispatch")
	point = map.world_to_screen(Vector2(3.5, 1.5))
	map._gui_input(button(MOUSE_BUTTON_LEFT, true, point))
	map._gui_input(button(MOUSE_BUTTON_MIDDLE, true, point))
	map._gui_input(button(MOUSE_BUTTON_LEFT, true, point))
	check(map._panning and not map._dragging, "middle pan cancels paint and suppresses concurrent left press")
	var before := map._origin()
	var motion := InputEventMouseMotion.new()
	motion.position = map.get_global_transform() * (point + Vector2(10.5, 12.25))
	map._input(motion)
	check(map._origin().is_equal_approx(before + Vector2(10.5, 12.25)), "global motion pans in local camera pixels, including fractional offsets")
	map._input(global_button(map, MOUSE_BUTTON_LEFT, false, point))
	map._input(global_button(map, MOUSE_BUTTON_MIDDLE, false, point))
	check(not map._panning and requests.size() == 1, "pan release never dispatches an edit")
	map._gui_input(button(MOUSE_BUTTON_MIDDLE, true, point))
	map.notification(NOTIFICATION_WM_WINDOW_FOCUS_OUT)
	check(not map._panning and not map._dragging, "application focus loss cancels both gestures")
	map.input_blocked = func(_global: Vector2) -> bool: return true
	var zoom := map._zoom
	map._gui_input(button(MOUSE_BUTTON_WHEEL_UP, true, point))
	map._gui_input(button(MOUSE_BUTTON_MIDDLE, true, point))
	check(map._zoom == zoom and not map._panning, "floating panels/modal UI block camera wheel and middle gestures")
	map.input_blocked = Callable()
	map._gui_input(button(MOUSE_BUTTON_MIDDLE, true, point))
	map.input_blocked = func(_global: Vector2) -> bool: return true
	map._input(motion)
	check(not map._panning and not map._dragging, "moving onto a floating panel cancels an active camera gesture")
	map.input_blocked = Callable()
	map._gui_input(button(MOUSE_BUTTON_MIDDLE, true, point))
	var escape := InputEventKey.new()
	escape.keycode = KEY_ESCAPE
	escape.pressed = true
	map._input(escape)
	check(not map._panning, "Escape cancels middle pan as well as paint")
	map._gui_input(button(MOUSE_BUTTON_MIDDLE, true, point))
	map._input(global_button(map, MOUSE_BUTTON_RIGHT, true, point))
	check(not map._panning, "right-click cancels middle pan as well as paint")
	var input := LineEdit.new()
	add_child(input)
	map._gui_input(button(MOUSE_BUTTON_MIDDLE, true, point))
	input.grab_focus()
	check(not map._panning, "another control taking keyboard focus cancels an active middle gesture")
	map._gui_input(button(MOUSE_BUTTON_LEFT, true, point))
	input.grab_focus()
	map._input(global_button(map, MOUSE_BUTTON_LEFT, false, point))
	check(not map._dragging and requests.size() == 1, "another control taking keyboard focus cancels paint without dispatch")
	input.free()
	map.fit_camera()
	map.set_interaction_mode(&"facility")
	map.zoom_at(1.5, map.size * 0.5)
	point = map.world_to_screen(Vector2(3.5, 1.5))
	map._gui_input(button(MOUSE_BUTTON_LEFT, true, point))
	map._input(global_button(map, MOUSE_BUTTON_LEFT, false, point))
	check(requests.size() == 2 and requests.back() == Vector3i(3, 1, -8), "facility interaction freezes actual exposed feet xyz at arbitrary zoom")
	check(map.tile_at(Vector2i(4, 0)).id == 1, "spatial picking indexes the complete two-cell facility footprint")
	map.fit_camera()
	map._process(1.0 / 60)
	var stable := counts(map)
	var terrain_ids: Array = []
	for layer in map.terrain_view.layers:
		terrain_ids.append(layer.texture.get_instance_id() if layer.texture != null else 0)
	for i in 360:
		map._walk_frame = -1 # force frame-clock changes even when the actor is idle
		map._process(1.0 / 60)
	check(counts(map) == stable, "idle actors/animation clock never rebuild terrain, masks, or entity passes")
	for i in 10:
		map.refresh({"colony": true, "config": true})
	check(counts(map) == stable, "ordinary colony/config ticks do not reallocate or redraw cached render passes")
	for i in map.terrain_view.layers.size():
		var texture: Texture2D = map.terrain_view.layers[i].texture
		check((texture.get_instance_id() if texture != null else 0) == terrain_ids[i], "idle texture resource identity stays stable")
	for pass_view in map.terrain_view.viewports:
		check(pass_view.render_target_update_mode != SubViewport.UPDATE_ALWAYS, "entity pass is on-demand, never UPDATE_ALWAYS")
	var actor: ContinuumColonist = local._tables["colonist"][1]
	actor.next_x = 2
	actor.move_progress = 0.5
	map._process(0.125)
	check(map.terrain_view.terrain_build_count == stable.x and map.terrain_view.mask_build_count == stable.y, "moving entities reuse terrain textures and unchanged exposure masks")
	actor.next_x = actor.x
	actor.move_progress = 0
	map._process(1.0)
	check(LayeredTerrainModel.field(actor, "next_z", 77) == actor.next_z and LayeredTerrainModel.field(actor, "missing", 77) == 77, "validated object lookup keeps existing fields and missing-property fallbacks")
	map.free()
	await test_hud(local)
	local.free()
	test_provider_transitions()
	test_resize_camera()
	await test_sparse_cells()
	for edge in [128, 256]:
		test_large_map(edge)
	SpacetimeDB.Continuum.db = previous
	print("MAP_CLIENT_TEST_%s: %d assertions" % ["PASS" if failures == 0 else "FAIL", assertions])
	get_tree().quit(0 if failures == 0 else 1)

func test_hud(local: LocalDatabase) -> void:
	var main := preload("res://scenes/main.tscn").instantiate()
	main.set_script(preload("res://tools/terrain_ui_fixture_main.gd"))
	add_child(main)
	main.set_anchors_and_offsets_preset(Control.PRESET_TOP_LEFT)
	main.size = Vector2(1440, 860)
	await get_tree().process_frame
	await get_tree().process_frame
	main._state_ready = true
	main._menu.visible = false
	main.map.refresh()
	main._set_permissions("viewer", false, false)
	check(not main.workspace.authorized.operations and main._map_toolbar.is_visible_in_tree(), "Viewer has an always-visible map toolbar outside unauthorized Operations")
	check(main._map_toolbar.get_parent() == main.workspace.area and main._map_toolbar.get_index() < main.workspace.windows.people.get_index(), "toolbar overlays the full map below floating panels")
	check(not main._map_layer_buttons[1].disabled, "Viewer can navigate layers")
	main._map_layer_buttons[1].pressed.emit()
	check(main.map.terrain_model.cut == 1 and main._map_layer_label.text.contains("z=1") and main._map_layer_label.text.contains("0.5m"), "layer HUD immediately synchronizes z and half-metre elevation")
	main.map.zoom_at(1.2, main.map.size * 0.5)
	check(main._map_zoom_label.text == "%d%%" % roundi(main.map.zoom_percent()), "zoom HUD immediately synchronizes with cursor-anchored zoom")
	main._map_zoom_buttons.fit.pressed.emit()
	check(main.map._zoom == 1.0 and main.map._pan == Vector2.ZERO, "actual Fit button resets the camera")
	main._map_zoom_buttons.reset.pressed.emit()
	check(is_equal_approx(main.map.zoom_percent(), 100), "actual 1:1 button restores native scale (actual %.2f%%)" % main.map.zoom_percent())
	main.map.set_cut(main.map.terrain_model.min_z)
	check(main._map_layer_buttons[-1].disabled and not main._map_layer_buttons[1].disabled, "HUD disables only the lower bound at minimum z")
	main.map._panning = true
	main.map._dragging = true
	main._menu.visible = true
	check(not main.map._panning and not main.map._dragging, "opening the actual opaque menu cancels both gestures before input is suspended")
	main._menu.visible = false
	check(not main.map._panning and not main.map._dragging, "closing the menu cannot resume a stale camera or edit gesture")
	for font in range(10, 25):
		main.apply_font_size(font, false)
		main.size = Vector2(360, 640)
		await get_tree().process_frame
		await get_tree().process_frame
		check(main._map_toolbar.size.x <= 360.1 and main._map_toolbar.get_combined_minimum_size().x <= 360.1, "HUD fits 360px width without font shrinking at font %d: %s" % [font, main._map_toolbar.get_combined_minimum_size()])
		check(main._map_layer_label.get_theme_font_size("font_size") == main._metrics.font(12), "HUD uses current UiMetrics at font %d" % font)
		for row in main._map_toolbar.get_child(0).get_children():
			for control in row.get_children():
				check(main._map_toolbar.get_global_rect().encloses(control.get_global_rect()), "every HUD control is unclipped/reachable at font %d" % font)
	main._refresh_colonists()
	var card: PanelContainer = main._colonist_cards[1]
	var card_id := card.get_instance_id()
	local._tables["colonist"][1].name = "Updated worker"
	main._refresh_colonists()
	check(main._colonist_cards[1].get_instance_id() == card_id and card.model.name == "Updated worker", "People roster rows update authoritative fields without destroying/rebuilding their nodes")
	main._refresh()
	var alert_child: int = main._alert_box.get_child(0).get_instance_id()
	var excavation_children: Array = main._excavation_list.get_children()
	main._on_table_changed("config")
	main._refresh()
	check(main._alert_box.get_child(0).get_instance_id() == alert_child, "config ticks do not rebuild unrelated alert UI")
	check(main._excavation_list.get_children() == excavation_children, "unchanged designation controls do not recreate nodes on ordinary ticks")
	main.map.set_cut(0)
	main._set_permissions("operator", true, false)
	main._on_rectangle_selected(Rect2i(3, 0, 2, 1))
	var source := SpacetimeDB.Continuum.db
	var nil_calls: Array = []
	main.map_intent_override = func(name: String, payload: Array) -> void: nil_calls.append([name, payload])
	SpacetimeDB.Continuum.db = null
	main._set_block_enabled(false)
	check(nil_calls.is_empty() and main._selected_rect == Rect2i() and not main.map._has_state, "actual Main block controls reject a stale selection immediately on nil provider")
	main._refresh_controls()
	main._state_ready = true # deliberately exercise the previously-ready history path
	main._sample_history()
	main._refresh()
	await get_tree().process_frame
	await get_tree().process_frame
	check(not main._state_ready and main._build_menu.disabled and main._full_ui_refresh, "actual Main nil-provider refresh/history/control paths remain safe and require a fresh UI snapshot")
	SpacetimeDB.Continuum.db = source
	main._state_ready = true
	main.map.refresh({"config": true})
	main._refresh()
	check(main.map.tile_at(Vector2i(3, 0)) == local._tables["tile"][1] and main._colonist_cards[1].model.name == "Updated worker", "actual Main refresh recovers map and cached People fields after provider restoration")
	var settings_path: String = main.fixture_settings_path
	var workspace_path: String = main.fixture_workspace_path
	main.free()
	DirAccess.remove_absolute(ProjectSettings.globalize_path(settings_path))
	DirAccess.remove_absolute(ProjectSettings.globalize_path(workspace_path))

func test_provider_transitions() -> void:
	var previous := SpacetimeDB.Continuum.db
	var first := Fixture.database()
	var first_source := SpacetimeDB.Continuum.db
	var second := Fixture.database()
	var second_source := SpacetimeDB.Continuum.db
	# Same dimensions, generation, ids, and revisions, but different actual rows.
	second._tables["tile"][1] = ContinuumTile.create(1, 6, 0, ContinuumTileKind.create_dining(), true, -8, 1, 1, 6)
	var chunk: ContinuumTerrainChunk = second._tables["terrain_chunk"][1]
	chunk.materials[3 + 16 * 16 * 7] = 0
	chunk.materials[3 + 16 * 16 * 6] = 2
	Fixture.index_rows(second)
	var map := ColonyMap.new()
	map.position = Vector2(41, 27)
	map.size = Vector2(512, 256)
	add_child(map)
	map.set_process(false) # no ordinary refresh/process can hide a query-time bug
	var events: Array = []
	map.tile_selected.connect(func(id: int) -> void: events.append(id))
	map.cell_selected.connect(func(cell: Vector3i) -> void: events.append(cell))
	map.rectangle_selected.connect(func(rect: Rect2i) -> void: events.append(rect))
	map.build_rectangle_requested.connect(func(rect: Rect2i) -> void: events.append(rect))
	map.excavation_requested.connect(func(rect: Rect2i, z: int, height: int) -> void: events.append([rect, z, height]))
	map.facility_requested.connect(func(cell: Vector3i) -> void: events.append(cell))
	for detached in [true, false]:
		for probe in ["tooltip", "tile", "visible", "facilities", "rectangle", "selection", "entities",
			"visibility", "groups", "cell", "region", "snapshot", "input", "gui", "process", "layout", "resize", "cut", "zoom", "fit", "pan", "select"]:
			SpacetimeDB.Continuum.db = first_source
			map.refresh()
			map.fit_camera()
			map.zoom_at(1.1, map.size * 0.5)
			map.pan_by(Vector2(8, 8))
			map.visible_tiles()
			map.facility_tiles()
			map.tiles_in_rect(Rect2i(3, 0, 2, 1))
			map.set_selected_rect(Rect2i(3, 0, 2, 1))
			map._visual_feet[777] = Vector3(3, 0, -8)
			var point := map.world_to_screen(Vector2(3.5, 0.5))
			map._gui_input(button(MOUSE_BUTTON_LEFT, true, point))
			check(map._dragging and map.tile_at(Vector2i(3, 0)) == first._tables["tile"][1] and not map.entity_descriptors().is_empty(), "provider probe %s starts with actual cached terrain, tile, selection, and sprites" % probe)
			events.clear()
			SpacetimeDB.Continuum.db = null if detached else second_source
			var context := "%s on %s" % [probe, "nil" if detached else "replacement"]
			match probe:
				"tooltip": check(map._get_tooltip(point).is_empty(), "no old tooltip " + context)
				"tile": check(map.tile_at(Vector2i(3, 0)) == null, "no old tile " + context)
				"visible": check(map.visible_tiles().is_empty(), "no old visible rows " + context)
				"facilities": check(map.facility_tiles().is_empty(), "no old facilities " + context)
				"rectangle": check(map.tiles_in_rect(Rect2i(3, 0, 2, 1)).is_empty(), "no old rectangle rows " + context)
				"selection": check(map.selected_rect() == Rect2i(), "no old selected footprint " + context)
				"entities": check(map.entity_descriptors().is_empty(), "no old sprites " + context)
				"visibility": check(not map.row_visible(first._tables["tile"][1]), "no old row exposure " + context)
				"groups": check(map.actor_groups(first._tables["colonist"].values()).is_empty(), "no old actor groups " + context)
				"cell": check(map._cell_at(point) == null, "no old physical cell picking " + context)
				"region": check(map.visible_grid_rect() == Rect2i(), "no old visible physical bounds " + context)
				"snapshot": check(not map.has_world_snapshot(), "no old snapshot provenance " + context)
				"input": map._input(global_button(map, MOUSE_BUTTON_LEFT, false, point))
				"gui": map._gui_input(button(MOUSE_BUTTON_LEFT, true, point))
				"process": map._process(1.0 / 60)
				"layout": map._layout_terrain()
				"resize": map.size += Vector2(1, 1)
				"cut": map.set_cut(1)
				"zoom": map.zoom_at(1.2, point)
				"fit": map.fit_camera()
				"pan": map.pan_by(Vector2(7, 3))
				"select": map.set_selected_rect(Rect2i(3, 0, 2, 1))
			check(not map._has_state and not map.layered and map._source_db == SpacetimeDB.Continuum.db, "cache provenance invalidates before refresh " + context)
			check(map._tiles.is_empty() and map._tile_index.is_empty() and map._colonists.is_empty() and map._stacks.is_empty() and map.terrain_model.surfaces.is_empty(), "all old row and terrain caches clear " + context)
			check(map._frozen_selection.is_empty() and map.selected_tile_id == -1 and not map._dragging and not map._panning and map._visual_feet.is_empty(), "selection, gestures, and eased actor poses clear " + context)
			var cleared := true
			for depth in map.terrain_view.layers.size():
				cleared = cleared and map.terrain_view.layers[depth].texture == null and map.terrain_view.entity_layers[depth].texture == null and map.terrain_view.canvases[depth].entities.is_empty() and map.terrain_view.viewports[depth].render_target_update_mode == SubViewport.UPDATE_DISABLED
			check(cleared and events.is_empty(), "old render passes stop without dispatching a stale input " + context)
			check(map._get_tooltip(point).is_empty() and map.tile_at(Vector2i(3, 0)) == null and map.entity_descriptors().is_empty() and map.selected_rect() == Rect2i(), "all later queries remain fail-closed until a real snapshot " + context)
			SpacetimeDB.Continuum.db = first_source
			map.refresh({"colonist": true})
			check(map.tile_at(Vector2i(3, 0)) == first._tables["tile"][1] and map.terrain_model.base_at(Vector2i(3, 0)) == -8, "a selective refresh after source transition still installs a full fresh snapshot " + context)
	SpacetimeDB.Continuum.db = second_source
	check(map._get_tooltip(map.world_to_screen(Vector2(3.5, 0.5))).is_empty(), "replacement tooltip cannot mix old cached ids with new provider tables")
	map.refresh({"colonist": true})
	check(map.tile_at(Vector2i(3, 0)) == null and map.tile_at(Vector2i(6, 0)) == second._tables["tile"][1], "same-id replacement installs new durable coordinates, never the old footprint")
	check(map.terrain_model.base_at(Vector2i(3, 0)) == -9 and not map._visual_feet.has(777), "same-revision replacement installs its own terrain and discards old eased poses")
	map.set_interaction_mode(&"excavate")
	map.cell_selected.connect(func(_cell: Vector3i) -> void: SpacetimeDB.Continuum.db = null, CONNECT_ONE_SHOT)
	map._gui_input(button(MOUSE_BUTTON_LEFT, true, map.world_to_screen(Vector2(6.5, 0.5))))
	check(not map._has_state and not map._dragging and map._source_db == null, "a synchronous selection callback detaching the provider cannot restart an old-world paint gesture")
	map.free()
	SpacetimeDB.Continuum.db = previous
	first.free()
	second.free()

func test_resize_camera() -> void:
	var previous := SpacetimeDB.Continuum.db
	SpacetimeDB.Continuum.db = null
	var map := ColonyMap.new()
	add_child(map)
	map.size = Vector2(256, 256)
	map.size = Vector2(1024, 256)
	check(not map._has_state and map.terrain_view.canvases.is_empty(), "resize before any world snapshot safely lays out an empty map")
	var fixture := Profile.new()
	fixture.edge = 128
	var local := fixture.database(false)
	local._tables["tile"][500001] = ContinuumTile.create(500001, 78, 64, ContinuumTileKind.create_dining(), true, -8, 1, 1, 6)
	Fixture.index_rows(local)
	map.size = Vector2(256, 256)
	map.refresh()
	map.reset_camera()
	map.set_process(false) # resize must update immediately, not via idle process/tick
	check(rendered_facilities(map).is_empty() and map._cell_at(map.world_to_screen(Vector2(78.5, 64.5))) == null, "narrow native camera culls and clips the far facility")
	var tile_revision := map._tile_revision
	var terrain_revision := map.terrain_model.revision
	var serial := map._static_entity_serial
	var selections: Array[int] = []
	var rectangles: Array[Rect2i] = []
	var edits: Array = []
	var camera_events: Array = []
	map.tile_selected.connect(func(id: int) -> void: selections.append(id))
	map.rectangle_selected.connect(func(rect: Rect2i) -> void: rectangles.append(rect))
	map.excavation_requested.connect(func(rect: Rect2i, z: int, height: int) -> void: edits.append([rect, z, height]))
	map.camera_changed.connect(func() -> void: camera_events.append(map.size))
	for dimensions: Vector2 in [Vector2(1024, 256), Vector2(256, 256), Vector2(1024, 256), Vector2(256, 1024), Vector2(1024, 256)]:
		var event_count := camera_events.size()
		map.size = dimensions
		check(camera_events.size() == event_count + 1, "resize completes one camera layout without recursive resize/layout signals")
		var facilities := rendered_facilities(map)
		var visible := dimensions.x == 1024
		check(facilities.size() == (1 if visible else 0), "resize immediately adds/removes camera-culled render descriptors at %s" % dimensions)
		var point := map.world_to_screen(Vector2(78.5, 64.5))
		check((map._cell_at(point) == Vector2i(78, 64)) if visible else (map._cell_at(point) == null), "resized render frustum and clipped physical picking agree at %s" % dimensions)
		if visible:
			check(facilities.size() == 1 and facilities[0].rect == Rect2(78, 64, 1, 1) and map.tile_at(Vector2i(78, 64)).id == 500001, "resize preserves the whole facility and durable xyz picking")
		var selected_count := selections.size()
		var rectangle_count := rectangles.size()
		map._gui_input(button(MOUSE_BUTTON_LEFT, true, point))
		map._input(global_button(map, MOUSE_BUTTON_LEFT, false, point))
		check(selections.size() == selected_count + (1 if visible else 0) and rectangles.size() == rectangle_count + (1 if visible else 0), "resized GUI press/global release dispatch only for visible facility cells")
		if visible:
			check(selections.back() == 500001 and rectangles.back() == Rect2i(78, 64, 1, 1), "resized GUI selection retains durable facility id and physical footprint")
		var pixels := Vector2i.ZERO
		for depth in map.terrain_view.layers.size():
			var texture: Texture2D = map.terrain_view.layers[depth].texture
			if texture != null:
				check(texture.get_width() <= 2048 and texture.get_height() <= 2048, "resized terrain texture edges stay bounded")
				pixels.x += texture.get_width() * texture.get_height()
			var pass_view: SubViewport = map.terrain_view.viewports[depth]
			check(pass_view.size.x <= 2048 and pass_view.size.y <= 2048, "resized entity pass edges stay bounded")
			if map.terrain_view.entity_layers[depth].texture != null:
				pixels.y += pass_view.size.x * pass_view.size.y
		check(pixels.x <= LayeredTerrainView.MAX_PASS_PIXELS and pixels.y <= LayeredTerrainView.MAX_PASS_PIXELS, "resize preserves independent aggregate render budgets")
		check(map._tile_revision == tile_revision and map.terrain_model.revision == terrain_revision and map._static_entity_serial == serial, "resize never resnapshots/reindexes the world or rebuilds model exposure")
	var stable := counts(map)
	for frame in 60:
		map._process(1.0 / 60)
	check(counts(map) == stable and rendered_facilities(map).size() == 1 and camera_events.size() == 5, "idle processing after resize retains correct descriptors without polling/rebuilds/layout")
	map.set_interaction_mode(&"excavate")
	var point := map.world_to_screen(Vector2(78.5, 64.5))
	map._gui_input(button(MOUSE_BUTTON_LEFT, true, point))
	check(map._dragging, "resize cancellation regression starts with an armed edit gesture")
	map.size = Vector2(256, 256)
	map._input(global_button(map, MOUSE_BUTTON_LEFT, false, point))
	check(not map._dragging and rendered_facilities(map).is_empty() and edits.is_empty(), "resize safely cancels a paint gesture without dispatch and removes out-of-view entities")
	print("MAP_CLIENT_TEST resize_camera_events=5 idle_rebuilds=0 sparse_facility_id=500001")
	map.free()
	SpacetimeDB.Continuum.db = previous
	local.free()
	fixture.free()

func test_sparse_cells() -> void:
	var fixture := Profile.new()
	fixture.edge = 128
	var local := fixture.database(false) # physical cells do not need empty Tile rows
	var facility := ContinuumTile.create(907531, 96, 90, ContinuumTileKind.create_farm(), true, -8, 2, 3, 6)
	local._tables["tile"][facility.id] = facility
	Fixture.index_rows(local)
	var main := preload("res://scenes/main.tscn").instantiate()
	main.set_script(preload("res://tools/terrain_ui_fixture_main.gd"))
	add_child(main)
	main.set_anchors_and_offsets_preset(Control.PRESET_TOP_LEFT)
	main.size = Vector2(1440, 860)
	await get_tree().process_frame
	await get_tree().process_frame
	main.set_process(false)
	main._state_ready = true
	main._menu.visible = false
	main.workspace.toggle_map_only()
	main.map.refresh()
	main.map.set_process(false)
	main._set_permissions("operator", true, false)
	var calls: Array = []
	main.map_intent_override = func(name: String, payload: Array) -> void: calls.append([name, payload])
	var map: ColonyMap = main.map
	map.reset_camera()
	map.pan_by(map.size * 0.5 - map.world_to_screen(Vector2(97.5, 91.5)))
	check(map._tiles.size() == 1 and map._grid == Vector2i(128, 128), "one sparse operational row cannot shrink authoritative physical bounds")
	var point := map.world_to_screen(Vector2(97.5, 91.5))
	map._gui_input(button(MOUSE_BUTTON_LEFT, true, point))
	map._input(global_button(map, MOUSE_BUTTON_LEFT, false, point))
	check(map.selected_tile_id == 907531 and main._selected_tile_id == 907531, "far facility picking preserves the durable id, never a list index or x+y*width")
	check(main._selected_rect == Rect2i(96, 90, 2, 3) and map.tile_at(Vector2i(97, 92)) == facility, "selecting any footprint cell selects the complete sparse facility")
	check(main._tile_info.text.contains("#907531 at (96, 90)") and main._tile_info.text.contains("z=-8 footprint 2x3"), "actual Inspector resolves sparse facility id and authoritative xyz/footprint")
	check(not main._block_controls[ContinuumWorkType.Options.farming].set.disabled, "actual work controls find a compatible sparse facility outside the starter area")
	main._block_controls["enabled_false"].pressed.emit()
	check(calls.size() == 1 and calls.back() == ["set_tile_block_enabled_at", [96, 90, 97, 92, -8, false]], "actual block button dispatches durable facility coordinates and floor z")
	main._block_controls[ContinuumWorkType.Options.farming].set.pressed.emit()
	check(calls.size() == 2 and calls.back()[0] == "set_block_work_order_at" and calls.back()[1].slice(0, 5) == [96, 90, 97, 92, -8], "actual sparse work button dispatches the whole footprint, not row indices")
	check(facility.enabled, "fixture intents do not optimistically mutate authoritative facility rows")
	check(map.tile_at(Vector2i(103, 96)) == null and map.terrain_model.base_at(Vector2i(103, 96)) == -8, "known empty physical terrain is buildable without an empty Tile row")
	main._set_mode(&"build")
	point = map.world_to_screen(Vector2(105.5, 97.5))
	map._gui_input(button(MOUSE_BUTTON_LEFT, true, point))
	map._input(global_button(map, MOUSE_BUTTON_LEFT, false, map.world_to_screen(Vector2(103.5, 96.5))))
	check(calls.size() == 3 and calls.back()[0] == "build_tile_block_at" and calls.back()[1].slice(0, 5) == [103, 96, 105, 97, -8], "actual Main build path accepts sparse physical cells with exact reverse-drag xyz outside 24x24")
	main._set_mode(&"facility")
	map.facility_width = 3
	map.facility_depth = 2
	map.facility_height = 6
	point = map.world_to_screen(Vector2(108.5, 94.5))
	map._gui_input(button(MOUSE_BUTTON_LEFT, true, point))
	map._input(global_button(map, MOUSE_BUTTON_LEFT, false, point))
	check(calls.size() == 4 and calls.back()[0] == "place_facility" and calls.back()[1].slice(0, 3) == [108, 94, -8] and calls.back()[1].slice(4) == [3, 2, 6], "actual Main facility path accepts supported sparse cells and whole dimensions")
	main._set_mode(&"excavate")
	point = map.world_to_screen(Vector2(111.5, 96.5))
	map._gui_input(button(MOUSE_BUTTON_LEFT, true, point))
	map._input(global_button(map, MOUSE_BUTTON_LEFT, false, point))
	check(calls.size() == 5 and calls.back() == ["designate_excavation", [111, 96, 111, 96, -8, 6, 2]], "actual Main excavation path preserves far sparse coordinates and actual base")
	var geometry: ContinuumWorldGeometry = local._tables["world_geometry"][0]
	geometry.width = 256
	geometry.height = 256
	map.refresh({"world_geometry": true})
	map.pan_by(map.size * 0.5 - map.world_to_screen(Vector2(201.5, 201.5)))
	point = map.world_to_screen(Vector2(201.5, 201.5))
	check(map._grid == Vector2i(256, 256) and map._cell_at(point) == Vector2i(201, 201), "grow-only geometry updates install 256 bounds independently of sparse rows")
	map._gui_input(button(MOUSE_BUTTON_LEFT, true, point))
	map._input(global_button(map, MOUSE_BUTTON_LEFT, false, point))
	check(not map._dragging and calls.size() == 5 and map.terrain_model.base_at(Vector2i(201, 201)) == null, "expanded but unreplicated terrain stays unknown and never sends a phantom edit")
	check(map._get_tooltip(point).begins_with("No known surface"), "unknown expanded terrain remains visibly distinct from known empty physical cells")
	map.set_selected_rect(Rect2i(96, 90, 2, 3))
	map._visual_feet[777] = Vector3(96, 90, -8)
	map._gui_input(button(MOUSE_BUTTON_MIDDLE, true, point))
	var replacement := fixture.database(false)
	replacement._tables["world_geometry"][0].width = 256
	replacement._tables["world_geometry"][0].height = 256
	for chunk: ContinuumTerrainChunk in replacement._tables["terrain_chunk"].values():
		if chunk.chunk_x == 6 and chunk.chunk_y == 5 and chunk.chunk_z == -1:
			chunk.materials[16 * (10 + 16 * 7)] = 0
			chunk.materials[16 * (10 + 16 * 6)] = 2 # deliberately keep revision=1
	map.refresh({"colonist": true})
	check(map.terrain_model.base_at(Vector2i(96, 90)) == -9 and map._tiles.is_empty(), "same-generation/revision/size replacement cannot reuse old sparse rows or surface caches")
	check(map._zoom == 1.0 and map._pan == Vector2.ZERO and not map._panning and not map._dragging, "world replacement resets camera and safely cancels active gestures")
	check(map._frozen_selection.is_empty() and not map._visual_feet.has(777) and map.tile_at(Vector2i(97, 92)) == null, "world replacement clears frozen selections, actors, and durable facility picking indexes")
	var settings_path: String = main.fixture_settings_path
	var workspace_path: String = main.fixture_workspace_path
	main.free()
	fixture.free()
	local.free()
	replacement.free()
	DirAccess.remove_absolute(ProjectSettings.globalize_path(settings_path))
	DirAccess.remove_absolute(ProjectSettings.globalize_path(workspace_path))

func test_large_map(edge: int) -> void:
	var fixture := Profile.new()
	fixture.edge = edge
	var local := fixture.database()
	fixture.free()
	var map := ColonyMap.new()
	map.size = Vector2(3816, 2060)
	add_child(map)
	map.refresh()
	map.set_process(false)
	check(map._grid == Vector2i(edge, edge), "camera uses authoritative %dx%d geometry rather than legacy tile dimensions" % [edge, edge])
	check(map._cell_at(map.world_to_screen(Vector2(edge - 0.5, edge - 0.5))) == Vector2i(edge - 1, edge - 1), "far map corner picks exact coordinates at fit")
	map._process(1.0 / 60)
	var stable := counts(map)
	for i in 180:
		map._process(1.0 / 60)
		map.refresh({"colonist": true})
	check(counts(map) == stable, "large-map idle/colonist ticks do not rebuild terrain, masks, or entity buffers")
	for factor in [1.0, 2.0, 4.0, 0.25]:
		map.zoom_at(factor, map.size * 0.5)
		map.pan_by(Vector2(0.5, -0.75))
		var terrain_pixels := 0
		var entity_pixels := 0
		for layer in map.terrain_view.layers:
			if layer.texture != null:
				check(layer.texture.get_width() <= 2048 and layer.texture.get_height() <= 2048, "terrain texture edges stay bounded at large-map zoom")
				terrain_pixels += layer.texture.get_width() * layer.texture.get_height()
		for pass_view in map.terrain_view.viewports:
			check(pass_view.size.x <= 2048 and pass_view.size.y <= 2048, "entity buffers are bounded camera/actor crops, never giant world passes")
			entity_pixels += pass_view.size.x * pass_view.size.y
		check(terrain_pixels <= LayeredTerrainView.MAX_PASS_PIXELS and entity_pixels <= LayeredTerrainView.MAX_PASS_PIXELS + 128, "aggregate depth buffers fit the pixel budget")
		for entity: Dictionary in map.entity_descriptors():
			check(entity.rect.intersects(Rect2(map.visible_grid_rect(2))), "off-camera descriptors are culled before rendering")
	var terrain_id := map.terrain_view.layers[1].texture.get_instance_id()
	var builds := map.terrain_view.terrain_build_count
	map.pan_by(Vector2(0.001, 0.001))
	check(map.terrain_view.terrain_build_count == builds and map.terrain_view.layers[1].texture.get_instance_id() == terrain_id, "subcell pan with unchanged crop keeps cached texture identities")
	# All 32 surface depths at once must obey an aggregate budget, not merely
	# keep each individual texture below a driver limit.
	for chunk: ContinuumTerrainChunk in local._tables["terrain_chunk"].values():
		chunk.materials.fill(0)
		chunk.revision += 1
		for y in 16:
			for x in 16:
				var z := 15 - (chunk.chunk_x * 16 + x) % 32
				if floori(z / 16.0) == chunk.chunk_z:
					chunk.materials[x + 16 * (y + 16 * (z - chunk.chunk_z * 16))] = 2
	map.fit_camera()
	map.refresh({"terrain_chunk": true})
	map.set_cut(15)
	var pixels := 0
	var bands := 0
	for layer in map.terrain_view.layers:
		if layer.texture != null:
			bands += 1
			pixels += layer.texture.get_width() * layer.texture.get_height()
	check(bands == 32 and pixels <= LayeredTerrainView.MAX_PASS_PIXELS, "all 32 simultaneous terrain bands share a 32MiB texture budget")
	print("MAP_CLIENT_TEST edge=%d 32_depth_bands pixels=%d limit=%d" % [edge, pixels, LayeredTerrainView.MAX_PASS_PIXELS])
	var actor: ContinuumColonist = local._tables["colonist"][0]
	actor.x = 4
	actor.y = edge / 2
	actor.z = 12
	actor.next_x = actor.x
	actor.next_y = actor.y
	actor.next_z = actor.z
	actor.move_progress = 0
	map.refresh({"colonist": true})
	map._process(1.0)
	check(map.terrain_view.canvases[3].pixels == 32, "sparse whole actors retain native detail despite the many-depth terrain budget")
	var many_entities: Array = []
	for z in range(-15, 16):
		many_entities.append({"type": "stack", "z": z, "colour": Color.WHITE,
			"rect": Rect2(Vector2(16 - z, edge / 2), Vector2.ONE)})
	map.terrain_view.update_entities(many_entities)
	var entity_pixels := 0
	var active_bands := 0
	for depth in map.terrain_view.viewports.size():
		var pass_view: SubViewport = map.terrain_view.viewports[depth]
		if map.terrain_view.entity_layers[depth].texture != null:
			active_bands += 1
			entity_pixels += pass_view.size.x * pass_view.size.y
		check(pass_view.size.x <= 2048 and pass_view.size.y <= 2048, "many-depth entity buffers remain edge-bounded at %dx%d" % [edge, edge])
	check(active_bands == 31 and entity_pixels <= LayeredTerrainView.MAX_PASS_PIXELS, "31 exposed entity bands share their own aggregate texture budget")
	print("MAP_CLIENT_TEST edge=%d entity_bands=%d pixels=%d limit=%d" % [edge, active_bands, entity_pixels, LayeredTerrainView.MAX_PASS_PIXELS])
	map.free()
	local.free()
