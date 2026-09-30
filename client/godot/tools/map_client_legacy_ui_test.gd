## Run the existing map UI/controller contract against generated in-memory rows.
## Supplies rows and sender-scoped fixture roles; no connection or reducer calls.
extends "res://tools/map_ui_test.gd"

var local_fixture: LocalDatabase
var previous_db: ContinuumModuleDb

func _ready() -> void:
	previous_db = SpacetimeDB.Continuum.db
	var fixture := preload("res://tools/map_client_profile.gd").new()
	fixture.edge = 24
	local_fixture = fixture.database()
	fixture.free()
	local_fixture._tables["tile"][8 + 24 * 8] = ContinuumTile.create(8 + 24 * 8, 8, 8, ContinuumTileKind.create_farm(), true, 0, 1, 1, 6)
	preload("res://tools/terrain_fixture.gd").index_rows(local_fixture)
	await super._ready()

func _set_role(main: Control, role: String, can_operate: bool, admin: bool) -> void:
	if main.fixture_access == null:
		main._create_access(SpacetimeDB.Continuum)
		main.fixture_access.changed.connect(main._set_permissions)
	main.fixture_access.set_role(role, can_operate, admin)

func _refresh_real_tiles(main: Control) -> void:
	main._state_ready = true
	await super._refresh_real_tiles(main)
	# Reproduce teardown with a real cached map and an explicit cursor position,
	# rather than relying on the headless driver's inherited hover coordinates.
	map.refresh()
	var point := map.world_to_screen(Vector2(8.5, 8.5))
	Input.parse_input_event(_motion(map.get_global_transform() * point))
	_assert(map._get_tooltip(point).contains("Farm (8, 8)"), "teardown starts over a known cached facility")
	map._gui_input(_button(MOUSE_BUTTON_LEFT, true, point))
	var releases := selected_releases
	main.free()
	SpacetimeDB.Continuum.db = previous_db
	_assert(map._get_tooltip(point).is_empty(), "hover after provider teardown returns no stale tooltip")
	map._input(_motion(map.get_global_transform() * point))
	map._input(_button(MOUSE_BUTTON_LEFT, false, map.get_global_transform() * point))
	_assert(selected_releases == releases and not map._dragging, "release after provider teardown cannot dispatch a stale selection")
	_assert(not map._has_state and map._tiles.is_empty() and map.entity_descriptors().is_empty(), "teardown invalidates cache provenance before an ordinary refresh")
	local_fixture.free()
