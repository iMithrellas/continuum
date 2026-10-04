## Generated-row presentation regressions; no network or reducers.
extends Node

var failed := false


## Observe the two independent rendering consumers, not the shared placement
## helper: the sprite rectangle handed to painting and the ring handed to arcs.
class LegacySelectionProbe:
	extends ColonyMap
	var sprite_centres := {}
	var ring_centres: Array[Vector2] = []
	var hidden_ids: Array[int] = []

	func _draw_legacy_colonist(descriptor: Dictionary, _cell: float) -> void:
		sprite_centres[descriptor.colonist.id] = descriptor.rect.get_center()

	func _draw_actor_ring(centre: Vector2, _radius: float) -> void:
		ring_centres.append(centre)

	func row_visible(row: Variant) -> bool:
		return super.row_visible(row) and not (row is ContinuumColonist and row.id in hidden_ids)


func check(value: bool, message: String) -> void:
	if not value:
		failed = true
		push_error(message)


func _ready() -> void:
	var previous := SpacetimeDB.Continuum.db
	var fixture = preload("res://tools/terrain_fixture.gd")
	var local: LocalDatabase = fixture.database()
	local._tables["tile"][3] = ContinuumTile.create(
		3, 5, 0, ContinuumTileKind.create_dining(), true, -8, 1, 1, 6
	)
	local._tables["tile"][4] = ContinuumTile.create(
		4, 6, 0, ContinuumTileKind.create_storage(), true, -8, 2, 1, 6
	)
	fixture.index_rows(local)
	var map := ColonyMap.new()
	map.size = Vector2(512, 256)
	add_child(map)
	map.refresh()
	map.set_process(false)
	check(
		map._regions.size() == 3 and map._visible_regions.size() == 2,
		"buried disconnected facility has topology but no visible outline or plate"
	)
	var dining: Dictionary = {}
	var storage: Dictionary = {}
	for region: Dictionary in map._visible_regions:
		if region.kind == ContinuumTileKind.Options.dining:
			dining = region
		if region.kind == ContinuumTileKind.Options.storage:
			storage = region
	check(
		dining.get("count") == 3 and dining.get("anchor") == Vector2i(3, 0),
		"touching durable facilities share one plate with physical occupied count"
	)
	check(
		storage.get("count") == 2 and storage.get("label_visible", false),
		"storage has a region plate rather than a global resource legend"
	)
	check(
		map.tile_at(Vector2i(4, 0)).id == 1 and map.tile_at(Vector2i(5, 0)).id == 3,
		"visual connectivity does not merge durable picking identities"
	)
	var topology := map._regions
	map.pan_by(Vector2(-64, 0))
	map.reset_camera()
	check(map._regions == topology, "pan and display zoom do not recompute or split topology")
	check(
		map._cell_size() == 16 and map.terrain_model.METRES_PER_LAYER == 0.5,
		"100% display cell changes pixels only, never physical half-metre layers"
	)
	map.set_cut(-9)
	check(
		map._regions == topology and map._visible_regions.is_empty(),
		"cut hides above-cut facilities without losing global region identity"
	)
	map.set_cut(0)
	check(
		map._visible_regions.size() == 2,
		"returning cut restores exactly the two exposed region plates"
	)
	map.set_alert_pins(
		[
			{"cell": Vector3i(3, 0, -8), "level": "warn"},
			{"cell": Vector2i(3, 0), "level": "critical"},
			{"cell": Vector3i.ZERO, "level": "invented"}
		]
	)
	check(
		map._alert_pins.size() == 1,
		"only actual xyz locations with supported severity enter the pin presenter"
	)
	map.set_selected_colonist(2)
	map.reset_world()
	check(
		(
			map._regions.is_empty()
			and map._visible_regions.is_empty()
			and map._alert_pins.is_empty()
			and map._excavation_regions.is_empty()
			and map.selected_colonist_id == -1
		),
		"provider reset clears every presentation cache and intent overlay"
	)
	map.free()
	SpacetimeDB.Continuum.db = previous
	local.free()
	test_legacy_selection()
	print("UI_MAP_%s" % ["FAIL" if failed else "PASS"])
	get_tree().quit(1 if failed else 0)


func check_selected_render_centre(map: LegacySelectionProbe, id: int, expected: Vector2) -> void:
	map.sprite_centres.clear()
	map.ring_centres.clear()
	map.set_selected_colonist(id)
	map._draw_colonists(map._origin(), map._cell_size())
	map._draw_actor_overlays(map._origin(), map._cell_size())
	check(
		map.sprite_centres.has(id) and map.sprite_centres[id].is_equal_approx(expected),
		"legacy sprite %d retains its expected camera/interpolated/occupancy position" % id
	)
	check(
		(
			map.ring_centres.size() == 1
			and map.ring_centres[0].is_equal_approx(map.sprite_centres.get(id, Vector2.INF))
		),
		(
			"only the selected legacy actor %d gets a ring at its corresponding rendered sprite centre"
			% id
		)
	)


func test_legacy_selection() -> void:
	var previous := SpacetimeDB.Continuum.db
	var fixture = preload("res://tools/terrain_fixture.gd")
	var local: LocalDatabase = fixture.database()
	local._tables["world_geometry"].clear()
	local._tables["tile"].clear()
	local._tables["tile"][0] = ContinuumTile.create(
		0, 0, 0, ContinuumTileKind.create_empty(), true, 0, 8, 4, 1
	)
	for id in [1, 2, 3]:
		var actor: ContinuumColonist = local._tables["colonist"][id]
		actor.x = 5 if id == 3 else 2
		actor.y = 2 if id == 3 else 1
		actor.target_x = actor.x
		actor.target_y = actor.y
		actor.move_progress = 0
	fixture.index_rows(local)
	var map := LegacySelectionProbe.new()
	map.size = Vector2(512, 256)
	map.position = Vector2(41, 27)
	add_child(map)
	map.refresh()
	map.set_process(false)
	check(not map.layered, "selection regression exercises the actual legacy path")
	map._colonists.reverse()
	check_selected_render_centre(map, 1, Vector2(176, 96))
	check_selected_render_centre(map, 2, Vector2(144, 96))
	check_selected_render_centre(map, 3, Vector2(352, 160))
	var moving: ContinuumColonist = local._tables["colonist"][1]
	moving.target_x = 3
	moving.move_progress = 0.75
	map._visual_positions[1] = Vector2(2, 1)
	map._process(0.0625)
	check(
		map._visual_positions[1].is_equal_approx(Vector2(2.375, 1)),
		"real legacy easing advances the rendered position halfway toward the authoritative hop"
	)
	map.zoom_at(0.5, Vector2(220, 110))
	map.pan_by(Vector2(13.25, -7.5))
	check_selected_render_centre(map, 1, map.world_to_screen(Vector2(3.125, 1.5)))
	check_selected_render_centre(map, 2, map.world_to_screen(Vector2(2.25, 1.5)))
	check_selected_render_centre(map, 3, map.world_to_screen(Vector2(5.5, 2.5)))
	map.hidden_ids = [2]
	check_selected_render_centre(map, 1, map.world_to_screen(Vector2(2.875, 1.5)))
	map.sprite_centres.clear()
	map.ring_centres.clear()
	map.set_selected_colonist(2)
	map._draw_colonists(map._origin(), map._cell_size())
	map._draw_actor_overlays(map._origin(), map._cell_size())
	check(
		not map.sprite_centres.has(2) and map.ring_centres.is_empty(),
		"invisible legacy actors receive neither a sprite nor a selection ring"
	)
	map.free()
	SpacetimeDB.Continuum.db = previous
	local.free()
	print("UI_LEGACY_SELECTION_PASS" if not failed else "UI_LEGACY_SELECTION_FAIL")
