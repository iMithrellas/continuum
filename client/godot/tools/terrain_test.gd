## Backend-free model, renderer, input, and final reducer-payload regression tests.
## godot --headless --path client/godot --scene res://tools/terrain_test.tscn
extends Node

var failures := 0
var assertions := 0
var model := LayeredTerrainModel.new()
var requests: Array = []
var digs: Array = []

func check(condition: bool, description: String) -> void:
	assertions += 1
	if not condition:
		failures += 1
		push_error(description)

func _ready() -> void:
	call_deferred("run")

func fixture() -> void:
	var lower := PackedInt32Array()
	lower.resize(4096)
	var upper := PackedInt32Array()
	upper.resize(4096)
	for y in 2:
		lower[0 + 16 * (y + 16 * 15)] = 1 # z=-1, exposed floor
		lower[1 + 16 * (y + 16 * 8)] = 2 # z=-8, deep hole
		lower[2 + 16 * (y + 16 * 12)] = 2 # z=-4, buried floor
		upper[2 + 16 * y] = 2 # z=0, intermediate rock occludes -4
	model.sync({"width": 4, "height": 2, "min_z": -16, "max_z": 15}, [
		{"chunk_x": 0, "chunk_y": 0, "chunk_z": -1, "materials": lower, "revision": 1},
		{"chunk_x": 0, "chunk_y": 0, "chunk_z": 0, "materials": upper, "revision": 1}], [
		{"id": 0, "name": "air", "opaque": false},
		{"id": 1, "name": "soil", "opaque": true},
		{"id": 2, "name": "stone", "opaque": true}])

func run() -> void:
	var previous_db := SpacetimeDB.Continuum.db
	var query_db := preload("res://tools/terrain_fixture.gd").database(false)
	var query_source := SpacetimeDB.Continuum.db
	fixture()
	check(model.surface_at(Vector2i(0, 0)) == Vector3i(0, 0, -1), "ray crosses air to actual negative-z floor")
	check(model.surface_at(Vector2i(1, 0)) == Vector3i(1, 0, -8), "ray can reveal a floor many layers below cut")
	check(model.material_at(Vector3i(1, 0, -8)) == 2, "negative chunk floor division and x+16*(y+16*z) addressing")
	check(model.material_at(Vector3i(0, 0, -16)) == 0, "negative chunk boundary remains correct")
	check(model.material_at(Vector3i(0, 0, -17)) == -1, "outside bounds is unknown, not invented solid")
	check(model.surface_at(Vector2i(2, 0)) == Vector3i(2, 0, 0), "intermediate solid floor occludes lower floor")
	check(model.base_at(Vector2i(0, 0)) == 0, "exposed floor placement base is surface+1")
	check(model.base_at(Vector2i(2, 0)) == 0, "cut rock excavation base is surface, not surface+1")
	check(model.depth_at(Vector2i(1, 0)) == 8, "depth comes from true surface z")
	check(model.surface_at(Vector2i(3, 0)) == null, "air column does not invent a floor")
	check(model.uniform_base(Rect2i(0, 0, 2, 1)) == null, "mixed elevation placement rejected")
	check(model.uniform_base(Rect2i(0, 0, 1, 2)) == 0, "uniform footprint accepts one actual elevation")
	check(model.placement_clear(Rect2i(0, 0, 1, 2), 0, 10), "full tall facility clearance checked against real air and support")
	check(not model.placement_clear(Rect2i(2, 0, 1, 1), 0, 6), "cut rock is excavatable, not buildable air")
	check(not model.placement_clear(Rect2i(3, 0, 1, 1), 0, 6), "unsupported air column cannot host a facility")
	check(LayeredTerrainModel.movement_position({"x": 0, "y": 0, "z": -7, "target_x": 9, "target_y": 9,
		"next_x": 0, "next_y": 1, "next_z": -6, "move_progress": 0.5}) == Vector3(0, 0, -6),
		"movement lifts before advancing toward actual next xyz, not ultimate target")
	check(model.entity_visible({"x": 0, "y": 0, "z": 0, "clearance_height": 12}), "tall actor crossing cut draws whole sprite")
	check(not model.entity_visible({"x": 0, "y": 0, "z": 1}), "feet above cut stay hidden")
	check(not model.entity_visible({"x": 2, "y": 0, "z": -3}), "solid intermediate floor hides entity")
	check(model.entity_visible({"x": 1, "y": 0, "z": -7}), "deep exposed actor remains visible")
	check(model.entity_visible({"x": 0, "y": 0, "z": 0, "width": 1, "depth": 2, "clearance_height": 9}), "complete exposed multicell facility visible")
	check(not model.entity_visible({"x": 1, "y": 0, "z": -7, "width": 2, "depth": 1}), "one occluded footprint cell hides whole facility")
	check(model.excavation_payload(Rect2i(1, 0, 2, 2), -7, 6) == [1, 0, 2, 1, -7, 6, 2], "default 3m designation exact payload")
	check(model.excavation_payload(Rect2i(0, 0, 1, 1), -11, 1) == [0, 0, 0, 0, -11, 1, 2], "arbitrary half-metre bottom and single-layer height")
	check(model.excavation_payload(Rect2i(0, 0, 1, 1), 14, 3).is_empty(), "designation upper bounds checked")
	check(model.excavation_payload(Rect2i(0, 0, 1, 1), 0, 0).is_empty(), "zero designation height rejected")
	var map := ColonyMap.new()
	map.bind_world_source(query_source)
	map.size = Vector2(400, 200)
	get_tree().root.add_child(map)
	map.terrain_model = model
	map.layered = true
	map._has_state = true
	map._grid = Vector2i(4, 2)
	map.terrain_view.rebuild(model)
	map.excavation_requested.connect(func(rect: Rect2i, bottom: int, height: int) -> void: digs.append([rect, bottom, height]))
	map.set_interaction_mode(&"excavate")
	press(map, Vector2(150, 50))
	check(map.selected_base == -7, "hit testing freezes deep actual floor base, not cut z")
	release(map, Vector2(150, 50))
	check(digs.size() == 1 and digs[0][1] == -7 and digs[0][2] == 6, "paint emits exact selected base and default height")
	press(map, Vector2(150, 50))
	var up := InputEventKey.new()
	up.pressed = true
	up.keycode = KEY_PAGEUP
	map._input(up)
	check(model.cut == 1 and model.cut * model.METRES_PER_LAYER == 0.5, "PgUp moves exactly one 0.5m layer")
	check(not map._dragging, "cut change cancels frozen-layer drag")
	release(map, Vector2(150, 50))
	check(digs.size() == 1, "release after cut change cannot designate")
	up.keycode = KEY_BRACKETLEFT
	map._input(up)
	check(model.cut == 0, "left bracket moves exactly one layer down")
	map.set_cut(-1)
	check(model.surface_at(Vector2i(2, 0)) == Vector3i(2, 0, -4), "cut hides rock above and reveals true lower floor")
	map.set_cut(0)
	var near_effect: ShaderMaterial = map.terrain_view.layers[0].material
	var deep_effect: ShaderMaterial = map.terrain_view.layers[8].material
	check(deep_effect.get_shader_parameter("radius") > near_effect.get_shader_parameter("radius"), "depth bands increase actual blur kernel radius")
	check(deep_effect.get_shader_parameter("darkness") < near_effect.get_shader_parameter("darkness"), "depth bands darken progressively")
	check(map.terrain_view.layers[8].texture != null, "blur samples actual cached offscreen texture")
	check(map.terrain_view.layers[8].show_behind_parent, "designation and selection overlays remain above blurred terrain")
	var controller = load("res://scripts/main.gd").new()
	controller.map = map
	controller._can_operate = true
	controller._state_ready = true
	controller._intent_feedback = Label.new()
	controller._build_menu = OptionButton.new()
	controller._build_menu.add_item("Dining", ContinuumTileKind.Options.dining)
	controller.map_intent_override = func(name: String, payload: Array) -> void: requests.append([name, payload])
	controller._dispatch_build_block(Rect2i(0, 0, 1, 2), ContinuumTileKind.create_dining())
	check(requests.back()[0] == "build_tile_block_at" and requests.back()[1][4] == 0, "build calls layer-aware reducer at actual base")
	controller._selected_rect = Rect2i(1, 0, 1, 1)
	controller._selected_surface = model.capture_selection(controller._selected_rect)
	controller._set_block_enabled(false)
	check(requests.back() == ["set_tile_block_enabled_at", [1, 0, 1, 0, -7, false]], "enable payload resolves actual deep floor")
	controller._set_block_work(ContinuumWorkType.Options.mining, 1, true)
	check(requests.back()[0] == "set_block_work_order_at" and requests.back()[1][4] == -7, "work order payload resolves actual deep floor")
	controller._on_excavation_requested(Rect2i(1, 0, 1, 1), -7, 6)
	check(requests.back() == ["designate_excavation", [1, 0, 1, 0, -7, 6, 2]], "excavation controller preserves arbitrary chosen elevation")
	map.facility_depth = 2
	map.facility_height = 10
	controller._on_facility_requested(Vector3i(0, 0, 0))
	check(requests.back()[0] == "place_facility" and requests.back()[1].slice(4) == [1, 2, 10], "facility payload carries full configurable footprint and tall clearance")
	var before := requests.size()
	map.facility_width = 2
	controller._on_facility_requested(Vector3i(0, 0, 0))
	check(requests.size() == before, "mixed-elevation facility never silently dispatches hidden geometry")
	controller._can_operate = false
	controller._on_excavation_requested(Rect2i(1, 0, 1, 1), -7, 6)
	check(requests.size() == before, "excavation respects operator permissions")
	controller._can_operate = true
	controller._state_ready = false
	controller._dispatch_vertical("cancel_excavation", [7], "Cancel")
	check(requests.size() == before, "vertical intents respect subscription readiness")
	controller._state_ready = true
	controller._selected_surface = model.capture_selection(Rect2i(1, 0, 1, 1))
	controller._selected_rect = Rect2i(1, 0, 1, 1)
	var lower: PackedInt32Array = model.chunks[Vector3i(0, 0, -1)].duplicate()
	lower[1 + 16 * 16 * 8] = 0
	lower[1 + 16 * 16 * 7] = 2
	var changed_rows: Array = []
	for coordinate: Vector3i in model.chunks:
		changed_rows.append({"chunk_x": coordinate.x, "chunk_y": coordinate.y, "chunk_z": coordinate.z,
			"materials": lower if coordinate.z == -1 else model.chunks[coordinate], "revision": 2})
	model.sync({"width": 4, "height": 2, "min_z": -16, "max_z": 15}, changed_rows, model.materials.values())
	controller._set_block_enabled(true)
	check(requests.size() == before and controller._selected_rect.size == Vector2i.ZERO,
		"excavated pending selection invalidates instead of retargeting new lower floor")
	fixture()
	check(not model.position_visible(Vector3(1.6, 0, -7)), "moving feet over intact intermediate rock hide the whole actor")
	check(model.position_visible(Vector3(0.6, 0, 0)), "rendered horizontal hop over exposed columns is visible")
	check(not model.position_visible(Vector3(1.6, 0, -6.5)), "actual fractional xyz hop uses touched columns and feet layer")
	var old_motion := LayeredTerrainModel.sample_movement({"x": 1, "y": 0, "z": -7}, {}, 1.0)
	check(LayeredTerrainModel.sample_movement({"x": 0, "y": 0, "z": 0}, old_motion, 0.1).position == Vector3(0, 0, 0),
		"high-speed correction snaps to actual hop rather than inventing a wall-crossing path")
	var groups := map.actor_groups([
		{"id": 1, "x": 0, "y": 0, "z": 0}, {"id": 2, "x": 0, "y": 0, "z": 1},
		{"id": 3, "x": 1, "y": 0, "z": -7}, {"id": 4, "x": 1, "y": 0, "z": 0}])
	check(groups[Vector3i(0, 0, 0)] == [1], "hidden above-cut actors never shrink or offset visible occupants")
	check(groups[Vector3i(1, 0, -7)] == [3] and groups[Vector3i(1, 0, 0)] == [4], "occupant groups separate exposed feet elevations")
	var input := LineEdit.new()
	get_tree().root.add_child(input)
	input.grab_focus()
	up.keycode = KEY_BRACKETRIGHT
	map._input(up)
	check(model.cut == 0, "bracket typing in a focused server/GUI LineEdit never changes cut")
	input.free()
	var spinner := SpinBox.new()
	get_tree().root.add_child(spinner)
	spinner.get_line_edit().grab_focus()
	up.keycode = KEY_PAGEUP
	map._input(up)
	check(model.cut == 0, "SpinBox editing owns PgUp instead of map navigation")
	spinner.free()
	map.grab_focus()
	map.visible = false
	map._input(up)
	check(model.cut == 0, "hidden map never consumes navigation shortcuts")
	map.visible = true
	var wire_row := ContinuumExcavationDesignation.new()
	wire_row.x_0 = 1
	wire_row.y_0 = 2
	wire_row.x_1 = 3
	wire_row.y_1 = 4
	check(ColonyMap.designation_rect(wire_row) == Rect2i(1, 2, 3, 3), "real generated designation uses canonical x_0/y_0/x_1/y_1 properties")
	var source_a := RefCounted.new()
	var source_b := RefCounted.new()
	map.bind_world_source(source_a)
	fixture()
	check(model.surface_at(Vector2i.ZERO).z == -1, "first database snapshot has its own surface")
	map.bind_world_source(source_b)
	check(model.surfaces.is_empty() and map._visual_feet.is_empty(), "database replacement explicitly clears geometry and actors")
	var other_lower := PackedInt32Array()
	other_lower.resize(4096)
	other_lower[16 * 16 * 14] = 2
	var other_upper := PackedInt32Array()
	other_upper.resize(4096)
	model.sync({"width": 4, "height": 2, "min_z": -16, "max_z": 15}, [
		{"chunk_x": 0, "chunk_y": 0, "chunk_z": -1, "materials": other_lower, "revision": 1},
		{"chunk_x": 0, "chunk_y": 0, "chunk_z": 0, "materials": other_upper, "revision": 1}],
		[{"id": 0, "name": "air", "opaque": false}, {"id": 1, "name": "soil", "opaque": true}, {"id": 2, "name": "stone", "opaque": true}])
	check(model.surface_at(Vector2i.ZERO) == Vector3i(0, 0, -2), "equal dimensions/generation/chunk revisions in a different DB never reuse old hits")
	var unknown := LayeredTerrainModel.new()
	unknown.sync({"width": 1, "height": 1, "min_z": -16, "max_z": 15}, [], [])
	check(unknown.material_at(Vector3i(0, 0, -1)) == -1 and unknown.surface_at(Vector2i.ZERO) == null,
		"missing chunks never create imaginary stone surfaces")
	check(not unknown.entity_visible({"x": 0, "y": 0, "z": 0}), "missing chunks fail closed for actor exposure")
	var transparent := PackedInt32Array()
	transparent.resize(4096)
	transparent[16 * 16 * 15] = 3
	unknown.sync({"width": 1, "height": 1, "min_z": -16, "max_z": 15}, [
		{"chunk_x": 0, "chunk_y": 0, "chunk_z": -1, "materials": transparent, "revision": 1},
		{"chunk_x": 0, "chunk_y": 0, "chunk_z": 0, "materials": other_upper, "revision": 1}],
		[{"id": 3, "name": "glass", "opaque": false}])
	check(unknown.placement_clear(Rect2i(0, 0, 1, 1), 0, 1), "transparent non-air material provides physical support")
	check(not unknown.placement_clear(Rect2i(0, 0, 1, 1), -1, 1), "transparent solid occupies space even without opacity")
	var first_db := preload("res://tools/terrain_fixture.gd").database()
	first_db._tables["config"][0] = ContinuumConfig.create(0, 0, 0, 7, ContinuumHaulPolicy.create(0), ContinuumMealPolicy.create(0))
	preload("res://tools/terrain_fixture.gd").index_rows(first_db)
	map.refresh()
	check(map._generation == 7 and map.terrain_model.surface_at(Vector2i.ZERO).z == -1, "first real generated DB snapshot installs generation/revision 7/1")
	map.set_selected_rect(Rect2i(0, 0, 1, 1))
	map._visual_feet[77] = Vector3(1, 1, 0)
	var second_db := preload("res://tools/terrain_fixture.gd").database()
	second_db._tables["config"][0] = ContinuumConfig.create(0, 0, 0, 7, ContinuumHaulPolicy.create(0), ContinuumMealPolicy.create(0))
	preload("res://tools/terrain_fixture.gd").index_rows(second_db)
	var replacement: ContinuumTerrainChunk = second_db._tables["terrain_chunk"][1]
	replacement.materials[16 * 16 * 15] = 0
	replacement.materials[16 * 16 * 14] = 2
	map.refresh()
	check(map._generation == 7 and map.terrain_model.surface_at(Vector2i.ZERO).z == -2,
		"actual DB replacement with identical generation/revisions refreshes authoritative surface hit xyz")
	check(not map._visual_feet.has(77) and map._selection_rect.size == Vector2i.ZERO,
		"actual DB replacement clears stale eased actors and frozen selections")
	SpacetimeDB.Continuum.db = query_source
	first_db.free()
	second_db.free()
	test_step_motion()
	test_unresolved_rays()
	check(not model.set_cut(0), "unchanged cut avoids cache invalidation")
	model.set_cut(1000)
	check(model.cut == 15, "upper cut clamped to inclusive world bounds")
	model.set_cut(-1000)
	check(model.cut == -16, "lower cut clamped to inclusive world bounds")
	controller._intent_feedback.free()
	controller._build_menu.free()
	controller.free()
	map.free()
	SpacetimeDB.Continuum.db = previous_db
	query_db.free()
	print("TERRAIN_TEST_%s: %d assertions" % ["PASS" if failures == 0 else "FAIL", assertions])
	get_tree().quit(0 if failures == 0 else 1)

func test_step_motion() -> void:
	var terrain := LayeredTerrainModel.new()
	var lower := PackedInt32Array()
	lower.resize(4096)
	lower[16 * 16 * 15] = 1
	var upper := PackedInt32Array()
	upper.resize(4096)
	upper[1] = 2 # destination's real support at (1,0,0)
	terrain.set_cut(2)
	terrain.sync({"width": 2, "height": 1, "min_z": -16, "max_z": 15}, [
		{"chunk_x": 0, "chunk_y": 0, "chunk_z": -1, "materials": lower, "revision": 1},
		{"chunk_x": 0, "chunk_y": 0, "chunk_z": 0, "materials": upper, "revision": 1}],
		[{"id": 1, "name": "soil", "opaque": true}, {"id": 2, "name": "stone", "opaque": true}])
	check(terrain.placement_clear(Rect2i(0, 0, 1, 1), 0, 4) and terrain.placement_clear(Rect2i(1, 0, 1, 1), 1, 4),
		"supported half-metre step has four-cell physical clearance at both endpoints")
	for ascending in [true, false]:
		var source := Vector3(0, 0, 0) if ascending else Vector3(1, 0, 1)
		var next := Vector3(1, 0, 1) if ascending else Vector3(0, 0, 0)
		for progress in [0.0, 0.1, 0.25, 0.49, 0.5, 0.51, 0.75, 0.9, 1.0]:
			var position := LayeredTerrainModel.step_position(source, next, progress)
			check(terrain.position_visible(position), "whole actor remains visible on %s step at p=%s" % ["up" if ascending else "down", progress])
			var clear := true
			for x in range(floori(position.x), ceili(position.x + 1)):
				for z in range(floori(position.z), ceili(position.z + 4)):
					clear = clear and terrain.material_at(Vector3i(x, 0, z)) == 0
			check(clear, "entire four-cell swept body clears destination support on %s step at p=%s" % ["up" if ascending else "down", progress])
		var row := {"x": source.x, "y": source.y, "z": source.z, "next_x": next.x, "next_y": next.y, "next_z": next.z, "move_progress": 0.1}
		var previous := LayeredTerrainModel.sample_movement(row, {}, 1.0)
		row.move_progress = 0.9
		var smoothed := LayeredTerrainModel.sample_movement(row, previous, 0.5)
		check(smoothed.progress == 0.5 and terrain.position_visible(smoothed.position), "scalar smoothing crosses the %s step corner without diagonal floor collision" % ["up" if ascending else "down"])
		row.move_progress = 0.1
		check(LayeredTerrainModel.sample_movement(row, smoothed, 0.5).progress == 0.1, "backwards packet correction snaps to its own legal step path")
	var correction := LayeredTerrainModel.sample_movement({"x": 1, "y": 0, "z": 0}, {}, 0.1)
	check(not terrain.position_visible(correction.position), "invalid high-speed corrected feet behind the support block stay hidden")

func test_unresolved_rays() -> void:
	var terrain := LayeredTerrainModel.new()
	terrain.set_cut(2)
	var geometry := {"width": 1, "height": 1, "min_z": -16, "max_z": 15}
	var definitions := [{"id": 1, "name": "soil", "opaque": true}]
	var lower := PackedInt32Array()
	lower.resize(4096)
	lower[16 * 16 * 15] = 1
	var lower_row := {"chunk_x": 0, "chunk_y": 0, "chunk_z": -1, "materials": lower, "revision": 1}
	terrain.sync(geometry, [lower_row], definitions)
	check(terrain.surface_at(Vector2i.ZERO) == null and terrain.base_at(Vector2i.ZERO) == null,
		"known lower floor is neither visible nor selectable through missing upper chunk")
	var map := ColonyMap.new()
	map.bind_world_source(SpacetimeDB.Continuum.db)
	map.size = Vector2(100, 100)
	get_tree().root.add_child(map)
	map.terrain_model = terrain
	map.layered = true
	map._has_state = true
	map._grid = Vector2i.ONE
	var hits: Array = []
	map.cell_selected.connect(func(cell: Vector3i) -> void: hits.append(cell))
	press(map, Vector2(50, 50))
	check(hits.is_empty() and not map._dragging, "unresolved surface cannot emit a hit or begin map paint")
	map.free()
	check(not terrain.placement_clear(Rect2i(0, 0, 1, 1), 0, 4), "missing required clearance never invents air for placement")
	var upper := PackedInt32Array()
	upper.resize(4096)
	var upper_row := {"chunk_x": 0, "chunk_y": 0, "chunk_z": 0, "materials": upper, "revision": 1}
	check(terrain.sync(geometry, [lower_row, upper_row], definitions), "arrival of missing chunk invalidates unresolved-ray cache even at equal revision")
	check(terrain.surface_at(Vector2i.ZERO) == Vector3i(0, 0, -1) and terrain.base_at(Vector2i.ZERO) == 0,
		"subscription completion recovers the true lower surface and base")
	var incomplete_row := {"chunk_x": 0, "chunk_y": 0, "chunk_z": 0, "materials": [0], "revision": 1}
	terrain.sync(geometry, [lower_row, incomplete_row], definitions)
	check(terrain.base_at(Vector2i.ZERO) == null, "truncated chunk cells are unknown, not transparent defaults")
	check(terrain.sync(geometry, [lower_row, upper_row], definitions) and terrain.base_at(Vector2i.ZERO) == 0,
		"completion of a partial chunk array invalidates cache without inventing a revision change")
	upper[16 * 16] = 9 # unidentified material at z=1
	upper_row.materials = upper
	upper_row.revision = 2
	terrain.sync(geometry, [lower_row, upper_row], definitions)
	check(terrain.surface_at(Vector2i.ZERO) == null and terrain.base_at(Vector2i.ZERO) == null,
		"unknown material metadata terminates surface ray rather than assuming transparency")
	check(not terrain.placement_clear(Rect2i(0, 0, 1, 1), 2, 4), "unknown material cannot be assumed physical support")
	definitions.append({"id": 9, "name": "glass", "opaque": false})
	check(terrain.sync(geometry, [lower_row, upper_row], definitions), "material metadata arrival invalidates unresolved-ray cache")
	check(terrain.surface_at(Vector2i.ZERO) == Vector3i(0, 0, -1), "known transparent metadata resolves ray to real opaque floor")
	check(terrain.placement_clear(Rect2i(0, 0, 1, 1), 2, 4), "known transparent solid supports placement above it")
	check(not terrain.placement_clear(Rect2i(0, 0, 1, 1), 0, 4), "known transparent material remains occupied, not clearance air")
	terrain.sync(geometry, [upper_row], definitions)
	check(not terrain.placement_clear(Rect2i(0, 0, 1, 1), 0, 1), "missing required support fails closed despite known clearance")

func press(map: ColonyMap, point: Vector2) -> void:
	var event := InputEventMouseButton.new()
	event.button_index = MOUSE_BUTTON_LEFT
	event.pressed = true
	event.position = point
	map._gui_input(event)

func release(map: ColonyMap, point: Vector2) -> void:
	var event := InputEventMouseButton.new()
	event.button_index = MOUSE_BUTTON_LEFT
	event.position = point
	map._input(event)
