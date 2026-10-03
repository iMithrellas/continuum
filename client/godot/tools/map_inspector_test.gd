## Actual Main + typed replication fixtures; never connects or mutates a server.
extends Node

const Fixture = preload("res://tools/terrain_fixture.gd")
const Profile = preload("res://tools/map_client_profile.gd")
class OriginGeometry extends ContinuumWorldGeometry:
	var min_x := -16
	var min_y := -16

var failures := 0
var assertions := 0

func check(value: bool, message: String) -> void:
	assertions += 1
	if not value:
		failures += 1
		push_error(message)

func mouse(map: ColonyMap, xy: Vector2i, pressed: bool) -> InputEventMouseButton:
	var event := InputEventMouseButton.new()
	event.button_index = MOUSE_BUTTON_LEFT
	event.pressed = pressed
	event.position = map.world_to_screen(Vector2(xy) + Vector2.ONE * 0.5)
	if not pressed:
		event.position = map.get_global_transform() * event.position
	return event

func pick(main: Control, xy: Vector2i) -> void:
	var map: ColonyMap = main.map
	map.pan_by(map.size * 0.5 - map.world_to_screen(Vector2(xy) + Vector2.ONE * 0.5))
	map._gui_input(mouse(map, xy, true))
	map._input(mouse(map, xy, false))
	main._refresh_controls()

func _ready() -> void:
	call_deferred("run")

func run() -> void:
	var previous := SpacetimeDB.Continuum.db
	var profile := Profile.new()
	profile.edge = 128
	var local := profile.database(false)
	var alias := ContinuumTile.create(127 + 127 * 128, 1, 1, ContinuumTileKind.create_farm(), true, 0, 1, 1, 6)
	var farm := ContinuumTile.create(907531, 96, 90, ContinuumTileKind.create_farm(), true, -8, 2, 3, 6)
	var empty := ContinuumTile.create(778899, 35, 36, ContinuumTileKind.create_empty(), true, 0, 1, 1, 6)
	for tile in [alias, farm, empty]:
		local._tables["tile"][tile.id] = tile
	var ecology := ContinuumTerrain.new()
	ecology.tile_id = empty.id
	ecology.soil_fertility = 0.73
	ecology.moisture = 0.42
	ecology.forest_density = 0.19
	local._tables["terrain"][empty.id] = ecology
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
	var requests: Array = []
	main.map_intent_override = func(name: String, payload: Array) -> void: requests.append([name, payload])
	var map: ColonyMap = main.map
	for xy in [Vector2i(24, 25), Vector2i(33, 34), Vector2i(127, 127)]:
		pick(main, xy)
		check(main._selected_tile_id == -1 and map.selected_tile_id == -1, "sparse inspection never aliases historical tile IDs at %s" % xy)
		check(map.selected_rect() == Rect2i(xy, Vector2i.ONE) and main._selected_rect == map.selected_rect(), "coordinate selection/highlight persists after release at %s" % xy)
		check(main._tile_info.text.contains("Selected terrain at (%d, %d)" % [xy.x, xy.y]) and main._tile_info.text.contains("material #") and not main._tile_info.text.contains("Click a tile"), "actual Inspector shows sparse replicated terrain at %s" % xy)
		check(main._tile_info.text.contains("No replicated facility/tile row") and main._tile_info.text.contains("Ecology: no replicated"), "missing durable row is explicit, not invented empty tile or ecology")
		check(main._block_controls["enabled_true"].disabled and main._block_controls["enabled_false"].disabled
			and main._block_controls["enabled_true"].tooltip_text == "No facilities in selection"
			and main._block_controls["enabled_false"].tooltip_text == "No facilities in selection", "operator cannot toggle facilities on sparse terrain without facility rows")
		check(not main._mode_buttons[&"build"].disabled and not main._mode_buttons[&"excavate"].disabled, "zero facilities does not disable operator building or excavation")
	check(main._tile_info.text.contains("stone material #2 at (127, 127, -9)") and main._tile_info.text.contains("base z=-8"), "far corner uses replicated elevation and material")
	pick(main, Vector2i(35, 36))
	check(main._selected_tile_id == empty.id and main._tile_info.text.contains("Fertility: 73%") and main._tile_info.text.contains("Moisture: 42%"), "actual durable empty row retains its real replicated ecology")
	check(main._block_controls["enabled_true"].disabled and main._block_controls["enabled_false"].disabled
		and main._block_controls["enabled_false"].tooltip_text == "No facilities in selection", "placeholder Empty tile row is not a facility to enable or disable")
	check(not main._mode_buttons[&"build"].disabled and not main._mode_buttons[&"excavate"].disabled, "placeholder Empty row retains operator terrain-edit modes")
	main._set_permissions("viewer", false, false)
	main._refresh_controls()
	check(main._block_controls["enabled_true"].disabled and main._block_controls["enabled_false"].disabled
		and main._mode_buttons[&"build"].disabled and main._mode_buttons[&"excavate"].disabled
		and main._tile_info.text.contains("Fertility: 73%"), "viewer retains read-only terrain inspection without facility or terrain-edit controls")
	main._set_permissions("operator", true, false)
	pick(main, Vector2i(97, 91))
	check(main._selected_tile_id == farm.id and map.selected_tile_id == farm.id and map.selected_rect() == Rect2i(96, 90, 2, 3), "whole facility retains durable identity and footprint")
	check(not main._block_controls["enabled_true"].disabled and not main._block_controls["enabled_false"].disabled
		and main._block_controls["enabled_true"].tooltip_text.is_empty() and main._block_controls["enabled_false"].tooltip_text.is_empty(), "real facility restores toggles and clears the no-facility tooltip")
	main._block_controls["enabled_false"].pressed.emit()
	check(requests == [["set_tile_block_enabled_at", [96, 90, 97, 92, -8, false]]] and farm.enabled, "facility action dispatches authoritative coordinates without optimistic mutation")
	main._on_rectangle_selected(Rect2i(128, 128, 1, 1))
	check(main._selected_tile_id == -1 and map.selected_tile_id == -1 and not main._selected_rect.has_area(), "out-of-bounds rectangle after a facility does not revive the previous durable ID")
	var geometry := OriginGeometry.new()
	geometry.width = 160
	geometry.height = 160
	geometry.min_z = -16
	geometry.max_z = 15
	local._tables["world_geometry"][0] = geometry
	for cz in [-1, 0]:
		var chunk := ContinuumTerrainChunk.new()
		chunk.id = 1000 + cz
		chunk.chunk_x = -1
		chunk.chunk_y = -1
		chunk.chunk_z = cz
		chunk.materials.resize(4096)
		chunk.materials.fill(0)
		chunk.revision = 1
		if cz == -1:
			chunk.materials[15 + 16 * (15 + 16 * 13)] = 2
		local._tables["terrain_chunk"][chunk.id] = chunk
	map.refresh({"world_geometry": true, "terrain_chunk": true})
	map.fit_camera()
	check(map.grid_bounds() == Rect2i(-16, -16, 160, 160), "expanded origin comes from geometry, not sparse Tile extents")
	var anchor := map.world_to_screen(Vector2(-0.5, -0.5))
	var world := map.screen_to_world(anchor)
	map.zoom_at(1.5, anchor)
	check(map.screen_to_world(anchor).is_equal_approx(world), "zoom retains the fractional world point with a negative geometry origin")
	pick(main, Vector2i(-1, -1))
	check(map.selected_rect() == Rect2i(-1, -1, 1, 1) and main._tile_info.text.contains("stone material #2 at (-1, -1, -3)") and main._tile_info.text.contains("base z=-2"), "actual Main/map handles negative chunk local coordinates and elevation")
	check(map.terrain_view._region.has_point(Vector2i(-1, -1)) and map.terrain_model.material_at(Vector3i(-1, -1, -3)) == 2, "negative origin is rendered and inspected from the same replicated chunk")
	var unknown_chunk: ContinuumTerrainChunk = local._tables["terrain_chunk"][1000]
	unknown_chunk.materials[14 + 16 * (15 + 16 * 0)] = 999
	unknown_chunk.revision += 1
	map.refresh({"terrain_chunk": true})
	for xy in [Vector2i(140, 140), Vector2i(-2, -1), Vector2i(-3, -1)]:
		pick(main, xy)
		check(main._tile_info.text.contains("No known surface") and main._selected_tile_id == -1 and map.selected_rect() == Rect2i(xy, Vector2i.ONE), "unknown chunk or unsupported ray remains inspectable without inventing a floor")
		check(main._block_controls["enabled_false"].disabled and requests.size() == 1, "unknown/unsupported selections cannot dispatch facility controls")
		check(main._cell_label.text.begins_with("No known surface"), "voxel label does not invent material or base on unknown/unsupported rays")
	geometry.min_x = 0
	geometry.min_y = 0
	map.refresh({"world_geometry": true})
	main._refresh_controls()
	check(not main._selected_rect.has_area() and map.selected_rect() == Rect2i(), "geometry moving an unknown selection out of bounds invalidates it even when both old/new surfaces are null")
	pick(main, Vector2i(127, 127))
	map.clear_selection()
	main._refresh_controls()
	check(main._tile_info.text.begins_with("Click a tile") and map.selected_rect() == Rect2i() and main._cell_label.text == "Select a visible surface", "clear removes Inspector and voxel selection")
	main._on_rectangle_selected(Rect2i(-17, -17, 1, 1))
	main._refresh_controls()
	check(main._selected_tile_id == -1 and not main._selected_rect.has_area() and main._tile_info.text.begins_with("Click a tile"), "out-of-bounds selection cannot resurrect a tile or terrain")
	var settings_path: String = main.fixture_settings_path
	var workspace_path: String = main.fixture_workspace_path
	main.free()
	profile.free()
	local.free()
	SpacetimeDB.Continuum.db = previous
	DirAccess.remove_absolute(ProjectSettings.globalize_path(settings_path))
	DirAccess.remove_absolute(ProjectSettings.globalize_path(workspace_path))
	print("MAP_INSPECTOR_TEST_%s assertions=%d failures=%d" % ["PASS" if failures == 0 else "FAIL", assertions, failures])
	get_tree().quit(0 if failures == 0 else 1)
