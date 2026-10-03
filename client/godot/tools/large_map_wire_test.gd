## Typed schema adapter/lifecycle tests with generated production bindings.
extends Node

class Rows extends RefCounted:
	var values: Array = []
	func iter() -> Array:
		return values

class NormalizedDb extends RefCounted:
	var world_generation := Rows.new()
	var terrain_column_chunk := Rows.new()
	var terrain_overview_chunk := Rows.new()
	var base: ContinuumModuleDb
	func _init(local: LocalDatabase) -> void:
		base = ContinuumModuleDb.new(local)
	func _get(key: StringName) -> Variant:
		return base.get(key) if key in base else null

static func typed_row(row: Variant, schema: GDScript) -> Variant:
	if row is Resource:
		return row
	var result: Variant = schema.new()
	if result is ContinuumWorldGeneration:
		result.storage_version = 1
		result.generator_version = 1
	for key: String in row:
		if key == "phase":
			result.phase = ContinuumGenerationPhase.create(int(row[key]))
		elif key in ["base_z", "surface_z", "material"]:
			var values: Array[int] = []
			values.assign(Array(row[key]))
			result.set(key, values)
		else:
			result.set(key, row[key])
	return result

class GenerationRows extends ContinuumWorldGenerationTable:
	var values: Array = []
	func iter() -> Array[ContinuumWorldGeneration]:
		var result: Array[ContinuumWorldGeneration] = []
		for row in values:
			result.append(load("res://tools/large_map_wire_test.gd").typed_row(row, ContinuumWorldGeneration))
		return result
class SourceRows extends ContinuumTerrainColumnChunkTable:
	var values: Array = []
	func iter() -> Array[ContinuumTerrainColumnChunk]:
		var result: Array[ContinuumTerrainColumnChunk] = []
		for row in values:
			result.append(load("res://tools/large_map_wire_test.gd").typed_row(row, ContinuumTerrainColumnChunk))
		return result
class OverviewRows extends ContinuumTerrainOverviewChunkTable:
	var values: Array = []
	func iter() -> Array[ContinuumTerrainOverviewChunk]:
		var result: Array[ContinuumTerrainOverviewChunk] = []
		for row in values:
			result.append(load("res://tools/large_map_wire_test.gd").typed_row(row, ContinuumTerrainOverviewChunk))
		return result
class ExtendedDb extends ContinuumModuleDb:
	func _init(local: LocalDatabase) -> void:
		super(local)
		world_generation = GenerationRows.new()
		terrain_column_chunk = SourceRows.new()
		terrain_overview_chunk = OverviewRows.new()


class Handle extends Node:
	signal applied
	signal end
	var error := OK
	var unsubscribes := 0
	var active := false
	func unsubscribe() -> int:
		unsubscribes += 1
		return OK

class Client extends RefCounted:
	var db: Variant
	var handles: Array = []
	var queries: Array = []
	var online := true
	func is_connected_db() -> bool:
		return online
	func subscribe(sql: PackedStringArray) -> Handle:
		queries.append(sql)
		var handle := Handle.new()
		(Engine.get_main_loop() as SceneTree).root.add_child(handle)
		handles.append(handle)
		return handle
	func discard_subscription(_handle: Variant) -> void:
		pass

class ControllerClient extends "res://tools/main_menu_controller_fixture.gd".ClientFixture:
	func unsubscribe(_query_id: int, _flags: UnsubscribeMessage.UnsubscribeFlags = UnsubscribeMessage.UnsubscribeFlags.Default) -> Error:
		return OK

var assertions := 0
var failures := 0

func check(value: bool, message: String) -> void:
	assertions += 1
	if not value:
		failures += 1
		push_error(message)

func source(coordinate: Vector2i, version := 1) -> Dictionary:
	var base := PackedInt32Array()
	base.resize(1024)
	base.fill(0)
	var depth := PackedByteArray()
	depth.resize(1024)
	depth.fill(3)
	return {"chunk_x": coordinate.x, "chunk_y": coordinate.y, "generation_id": 9, "revision": version,
		"base_z": base, "soil_depth": depth, "soil_fertility": depth, "forest_density": depth, "moisture": depth}

func _ready() -> void:
	call_deferred("run")

func run() -> void:
	var old_db := SpacetimeDB.Continuum.db
	var local := preload("res://tools/terrain_fixture.gd").database()
	var db := ExtendedDb.new(local)
	SpacetimeDB.Continuum.db = db
	var geometry: ContinuumWorldGeometry = local._tables["world_geometry"][0]
	geometry.width = 2048
	geometry.height = 2048
	var status := {"generation_id": 9, "width": 2048, "height": 2048, "min_z": -16, "max_z": 15,
		"starter_x": 1012, "starter_y": 1012, "phase": 1, "completed_units": 16, "total_units": 4096, "ready": false, "error": ""}
	db.world_generation.values = [status]
	var owner := Client.new()
	owner.db = db
	var bootstrap := LargeWorldSession.bootstrap_queries(db, PackedStringArray(["SELECT * FROM config", "SELECT * FROM terrain_chunk", "SELECT * FROM terrain"]))
	check(bootstrap == PackedStringArray(["SELECT * FROM config", "SELECT * FROM terrain", "SELECT * FROM world_generation"]), "compact bootstrap retains operational ecology, never subscribes whole physical terrain")
	var model := LayeredTerrainModel.new()
	model.set_geometry(geometry)
	model.set_materials([{"id": 1, "opaque": true}, {"id": 2, "opaque": true}])
	model.configure_sources(32, CompactTerrainAdapter.read_material)
	var row := source(Vector2i(32, 32))
	check(CompactTerrainAdapter.valid_source(row, 9) and not CompactTerrainAdapter.valid_source(row, 10), "source generation and exact1024 shape validated")
	model.apply_source_chunk(Vector2i(32, 32), row, 1)
	check(model.material_at(Vector3i(1024, 1024, -1)) == -1, "stored column pending before matching snapshot acknowledgement")
	model.set_chunk_complete(Vector2i(32, 32), true)
	check(model.material_at(Vector3i(1024, 1024, 0)) == 0 and model.material_at(Vector3i(1024, 1024, -3)) == 1 and model.material_at(Vector3i(1024, 1024, -4)) == 2, "locked soil/stone intervals decoded exactly")
	var malformed := row.duplicate()
	malformed.base_z = PackedInt32Array([0])
	check(not CompactTerrainAdapter.valid_source(malformed, 9), "malformed source fails closed")

	var map := ColonyMap.new()
	map.size = Vector2(400, 320)
	get_tree().root.add_child(map)
	var session := LargeWorldSession.new()
	session.attach(map)
	check(session.start(owner, 7), "new bindings route through generation lifecycle")
	session.tick(0.1)
	check(owner.handles.is_empty() and session.loading.phase == "Generating terrain" and not session.loading.playable, "partial generation displays server phase without exploration generation/subscriptions")
	check(map.screen_to_world(map.size * 0.5).is_equal_approx(Vector2(1024, 1024)) and is_equal_approx(map._cell_size(), ThemeTokens.number("tile")), "initial camera centers starter+12 at native scale")
	status.ready = true
	status.phase = 5
	status.completed_units = 4096
	session.mark_changed("world_generation")
	session.tick(0.1)
	check(owner.handles.size() > 0 and owner.handles.size() <= 4 and not session.loading.playable, "ready world still waits for bounded physical snapshots")
	for y in range(30, 34):
		for x in range(30, 34):
			db.terrain_column_chunk.values.append(source(Vector2i(x, y)))
	var index := 0
	while index < owner.handles.size() and index < 64:
		owner.handles[index].applied.emit()
		index += 1
	check(session.loading.playable and owner.handles.size() <= 64, "starter viewport becomes playable only after exact matching snapshots")
	var idle_builds := Vector2i(map.terrain_view.terrain_build_count, map.terrain_view.mask_build_count)
	for tick in 8:
		session.tick(0.1)
	check(idle_builds == Vector2i(map.terrain_view.terrain_build_count, map.terrain_view.mask_build_count), "integrated compact idle ticks rebuild neither terrain nor masks")
	check(map.terrain_model.surface_at(Vector2i(1024, 1024)) == Vector3i(1024, 1024, -1), "acknowledged production adapter installs real surface")
	var selection := map.terrain_model.capture_selection(Rect2i(1024, 1024, 1, 1))
	session.detail.pin_selection(Rect2i(1024, 1024, 1, 1))
	session.detail.request_frame(Rect2i(0, 0, 2048, 2048), 0.25, 0)
	check(session.detail.complete(Vector2i(32, 32)) and map.terrain_model.selection_valid(selection), "bounded selection pins preserve exact physical snapshot across overview transition")
	session.stop()
	db.world_generation.values.clear()
	local._tables["colony"][0] = ContinuumColony.new()
	geometry.width = 24
	geometry.height = 24
	check(session.start(owner, 8) and session.loading.phase == "Loading nearby terrain", "initialized legacy world with new bindings skips generation spinner")
	owner.handles[-1].active = true
	owner.handles[-1].applied.emit()
	check(session.loading.playable and not session.compact, "legacy becomes ready after actual dense snapshot")
	session.stop()
	local._tables["colony"].clear()
	check(session.start(owner, 9) and not session.loading.error.is_empty() and not session.loading.playable, "missing status cannot authorize an uninitialized world")
	session.stop()
	geometry.width = 2048
	geometry.height = 2048

	var cache := TerrainOverviewCache.new()
	cache.attach(owner, model, 7, 9)
	cache.request_frame(Rect2i(0, 0, 2048, 2048), 0.25, 0)
	var frame := cache.frame_samples(Rect2i(0, 0, 2048, 2048), 0, 100)
	check(frame.mode == &"overview" and frame.stride == 8 and frame.samples.size() == 100 and frame.truncated and frame.samples[0].state == &"pending", "overview frame bounded and missing rows explicitly pending")
	var z := PackedInt32Array()
	z.resize(256)
	z.fill(-1)
	var material := PackedInt32Array()
	material.resize(256)
	material.fill(1)
	var ecology := PackedByteArray()
	ecology.resize(256)
	ecology.fill(255)
	db.terrain_overview_chunk.values = [{"generation_id": 9, "revision": 1, "lod": 3, "cut_z": 0, "chunk_x": 0, "chunk_y": 0,
		"surface_z": z, "material": material, "soil_fertility": ecology, "forest_density": ecology, "moisture": ecology}]
	check(cache._snapshot(model, Vector2i.ZERO, owner, 9), "locked overview array shape accepted")
	frame = cache.frame_samples(Rect2i(0, 0, 8, 8), 0, 100)
	check(frame.samples[0].surface == Vector3i(4, 4, -1) and frame.samples[0].soil_fertility == 1.0, "overview uses server representative point and stored normalized ecology")
	check(model.material_at(Vector3i(4, 4, -1)) == -1, "overview never installs approximate physical terrain")
	model.presentation_mode = &"overview"
	model.overview_frame_provider = cache.frame_samples
	var before_queries := model.query_count
	var visual := model.render_frame(Rect2i(0, 0, 128, 128))
	check(visual.samples.has(Vector2i.ZERO) and visual.samples[Vector2i.ZERO].surface_z == -1 and visual.stride == 8,
		"art frame translates server representative point to footprint origin")
	check(model.query_count == before_queries, "overview frame conversion makes zero physical queries")
	map.terrain_model = model
	map.streamed_terrain = true
	map.prepare_stream_camera(Vector2i(64, 64))
	check(map.set_terrain_frame(visual), "actual art renderer accepts bounded production overview frame")
	var picked := [0]
	map.cell_selected.connect(func(_cell: Vector3i) -> void: picked[0] += 1)
	var click := InputEventMouseButton.new()
	click.button_index = MOUSE_BUTTON_LEFT
	click.pressed = true
	click.position = map.size * 0.5
	map._gui_input(click)
	check(picked[0] == 0 and not map.selected_rect().has_area() and model.presentation_mode == &"detail", "overview click focuses detail without selecting representative terrain")
	cache.stop()
	cache.request_frame(Rect2i(0, 0, 2048, 2048), 0.25, 0)
	check(cache._stream.client == owner, "overview subscriptions resume after returning from detail")
	cache.stop()
	await controller_route()
	for handle in owner.handles:
		handle.free()
	owner.handles.clear()
	map.free()
	SpacetimeDB.Continuum.db = old_db
	local.free()
	print("LARGE_MAP_WIRE_%s: %d assertions" % ["PASS" if failures == 0 else "FAIL", assertions])
	get_tree().quit(0 if failures == 0 else 1)

func controller_route() -> void:
	var old_client := SpacetimeDB.Continuum
	var fixture = preload("res://tools/main_menu_controller_fixture.gd")
	var owner := ControllerClient.new()
	SpacetimeDB.add_child(owner)
	owner.set_process(false)
	SpacetimeDB.Continuum = owner
	var local := preload("res://tools/terrain_fixture.gd").database()
	var db := ExtendedDb.new(local)
	owner.db = db
	local._tables["world_geometry"][0].width = 24
	local._tables["world_geometry"][0].height = 24
	local._tables["config"][0] = ContinuumConfig.create(0, 0, 6, 1, ContinuumHaulPolicy.create(0), ContinuumMealPolicy.create(0))
	var colony := ContinuumColony.new()
	colony.wood = 500.0
	local._tables["colony"][0] = colony
	var farm := ContinuumTile.create(907531, 12, 12, ContinuumTileKind.create_farm(), true, 0, 1, 1, 4)
	var unknown := ContinuumTile.create(907532, 13, 12, ContinuumTileKind.create_forest(), true, 0, 1, 1, 4)
	local._tables["tile"][farm.id] = farm
	local._tables["tile"][unknown.id] = unknown
	var ecology := ContinuumTerrain.create(farm.id, 0.8, 0.2, 0.5)
	local._tables["terrain"][farm.id] = ecology
	local._tables["terrain_chunk"].clear()
	for cy in 2:
		for cx in 2:
			for cz in [-1, 0]:
				var chunk := ContinuumTerrainChunk.new()
				chunk.id = 100 + cx + 2 * cy + 4 * (cz + 1)
				chunk.chunk_x = cx
				chunk.chunk_y = cy
				chunk.chunk_z = cz
				chunk.revision = 1
				chunk.materials.resize(4096)
				chunk.materials.fill(1 if cz == -1 else 0)
				local._tables["terrain_chunk"][chunk.id] = chunk
	preload("res://tools/terrain_fixture.gd").index_rows(local)
	var status := {"generation_id": 12, "width": 24, "height": 24, "min_z": -16, "max_z": 15,
		"starter_x": 0, "starter_y": 0, "phase": 2, "completed_units": 25, "total_units": 100, "ready": false, "error": ""}
	db.world_generation.values = [status]
	local._tables["colonist"].clear()
	var main = preload("res://scenes/main.tscn").instantiate()
	main.set_script(fixture)
	get_tree().root.add_child(main)
	main.set_anchors_and_offsets_preset(Control.PRESET_TOP_LEFT)
	main.size = Vector2(960, 640)
	main.set_process(false)
	await get_tree().process_frame
	main._settings.server_host = "http://generation-fixture.test"
	main._settings.database = "colony"
	main._menu.show_menu()
	main._menu._last_button.pressed.emit()
	check(main._subscription != null and not main._state_ready, "actual menu join reaches bootstrap but not gameplay")
	check(main._subscription.queries.has("SELECT * FROM terrain") and not main._subscription.queries.has("SELECT * FROM terrain_chunk"),
		"actual compact Main bootstrap retains typed Tile ecology without broad physical replication")
	main._subscription.applied.emit()
	check(main.visible and not main._menu.visible and main._world_overlay.is_visible_in_tree(), "bootstrap presents generation overlay on real controller route")
	check(main._world_overlay._phase.text == "Building overview" and main._world_overlay._progress.value == 25.0,
		"controller shows truthful phase/progress even without colonists")
	check(not main._state_ready and not main.map.is_processing_input() and not main._can_resume_colony(), "bootstrap/auth status does not grant editing or game navigation/resume")
	var intents: Array = []
	main.map_intent_override = func(name: String, payload: Array) -> void: intents.append([name, payload])
	main._set_permissions("Operator", true, false)
	main._planning_system = &"zones"
	main._zone_kind = ContinuumTileKind.Options.farm
	main._on_build_rectangle_requested(Rect2i(12, 12, 1, 1))
	main._dispatch_vertical("designate_zone_at", [12, 12, 12, 12, 0, ContinuumTileKind.create_farm()], "Fixture zone")
	check(intents.is_empty() and not main._planning_allowed(), "combined planning handlers cannot bypass generation gate with Operator authority")
	status.phase = 3
	status.completed_units = 1
	status.total_units = 2
	main._on_table_changed("world_generation")
	main._large_world.tick(0.1)
	check(main._world_overlay._phase.text == "Validating world" and main._world_overlay._progress.value == 50.0, "real controller updates phase-local counters while world remains unready")
	var stored := source(Vector2i.ZERO)
	stored.generation_id = 12
	db.terrain_column_chunk.values = [stored]
	status.ready = true
	status.phase = 5
	main._on_table_changed("world_generation")
	main._large_world.tick(0.1)
	main._on_build_rectangle_requested(Rect2i(12, 12, 1, 1))
	check(intents.is_empty() and not main._state_ready, "server Ready without physical snapshot ack does not permit planning")
	for handle in owner.get_children():
		if handle is SpacetimeDBSubscription and not handle.active:
			handle.applied.emit()
	check(main._state_ready and not main._world_overlay.visible and main.map.is_processing_input(), "real controller reaches gameplay immediately after ready world and nearby snapshot")
	main.map.refresh()
	check_ecology(main, farm, "compact")
	main.map.terrain_model.set_chunk_complete(Vector2i.ZERO, false)
	main._on_build_rectangle_requested(Rect2i(12, 12, 1, 1))
	main._dispatch_vertical("designate_zone_at", [12, 12, 12, 12, 0, ContinuumTileKind.create_farm()], "Fixture pending zone")
	main._dispatch_vertical("construct_room", [12, 12, 12, 12, 0, 4], "Fixture pending room")
	check(intents.is_empty(), "combined typed zone handler rejects pending exact coverage even in playable session")
	main.map.terrain_model.set_chunk_complete(Vector2i.ZERO, true)
	main.map.terrain_model.presentation_mode = &"overview"
	main._on_build_rectangle_requested(Rect2i(12, 12, 1, 1))
	main._dispatch_vertical("designate_zone_at", [12, 12, 12, 12, 0, ContinuumTileKind.create_farm()], "Fixture overview zone")
	check(intents.is_empty(), "merged overview and attached planning gates block mutations despite retained exact selection")
	main.map.terrain_model.presentation_mode = &"detail"
	main._on_subscription_applied(main._subscription, main._session_generation)
	check(main._world_overlay._phase.text == "Loading nearby terrain", "already-ready reconnect skips artificial generation phase/delay")
	main._large_world.tick(0.1)
	for handle in owner.get_children():
		if handle is SpacetimeDBSubscription and not handle.active:
			handle.applied.emit()
	check(main._state_ready and not main._world_overlay.visible, "ready-on-connect finishes with snapshot acknowledgement, no timer")
	db.world_generation.values.clear()
	main._on_subscription_applied(main._subscription, main._session_generation)
	var legacy: SpacetimeDBSubscription = main._large_world._legacy_handle
	check(legacy.queries == PackedStringArray(["SELECT * FROM terrain_chunk"]), "initialized legacy mode adds physical terrain only; ecology remains in bootstrap")
	legacy.applied.emit()
	check(main._state_ready and not main._large_world.compact, "actual Main with new bindings enters initialized legacy ready mode")
	check_ecology(main, farm, "legacy with new bindings")
	db.world_generation.values = [status]
	main._on_subscription_applied(main._subscription, main._session_generation)
	legacy.end.emit()
	check(main._large_world.loading.error.is_empty(), "late released legacy subscription end cannot fail the compact session")
	main._large_world.tick(0.1)
	for handle in owner.get_children():
		if handle is SpacetimeDBSubscription and not handle.active:
			handle.applied.emit()
	status.phase = 6
	status.ready = false
	status.error = "Fixture generation failure"
	main._on_table_changed("world_generation")
	main._large_world.tick(0.1)
	check(main._world_overlay._phase.text == status.error and not main._state_ready, "server generation failure remains visible and non-playable")
	main._dispatch_vertical("designate_zone_at", [12, 12, 12, 12, 0, ContinuumTileKind.create_farm()], "Fixture failed zone")
	check(intents.is_empty() and not main._planning_allowed(), "combined attached planning gate rejects errored world")
	main._world_overlay._cancel.pressed.emit()
	check(owner.disconnects > 0 and not main._session_requested and main._menu.visible and not main._world_overlay.visible, "overlay cancel disconnects current client and returns to menu")
	main._has_configured_client = false
	status.phase = 1
	status.error = ""
	main._menu._last_button.pressed.emit()
	main._subscription.applied.emit()
	owner.disconnected.emit()
	check(not main._state_ready and main._menu.visible and not main._world_overlay.visible, "actual disconnect during generation exits loading and restores menu")
	main._has_configured_client = false
	main._menu._last_button.pressed.emit()
	var expired: SpacetimeDBSubscription = main._subscription
	main._on_bootstrap_timeout(expired, main._session_generation)
	status.ready = true
	status.phase = 5
	expired.applied.emit()
	main._on_table_changed("world_generation")
	main._large_world.tick(0.1)
	check(not main._state_ready and not main._large_world.loading.playable and not main.map.is_processing_input(),
		"actual Menu late bootstrap ack/Ready cannot revive terminal timeout")
	main._on_bootstrap_ended(expired, main._session_generation)
	main._on_subscription_applied(expired, main._session_generation)
	check(not main._state_ready and not main.map.is_processing_input(), "ended bootstrap remains terminal for its subscription")
	main.free()
	local.free()
	SpacetimeDB.Continuum = old_client
	owner.queue_free()
	await get_tree().process_frame

func check_ecology(main: Control, farm: ContinuumTile, context: String) -> void:
	main.map.set_interaction_mode(&"select")
	main.map.set_selected_rect(Rect2i(farm.x, farm.y, 1, 1))
	main._on_tile_selected(farm.id)
	main._refresh_controls()
	check(main._tile_info.text.contains("Fertility: 80%") and main._tile_info.text.contains("Moisture: 50%")
		and main._tile_info.text.contains("(20%)"), context + " Inspector retains authoritative typed Tile ecology")
	check(main._block_info.tooltip_text.contains("fertility 0.80, moisture 0.50")
		and main._block_info.tooltip_text.contains("density 0.20"), context + " selected production block retains authoritative ecology averages")
	check(main.map._potential_yield(Vector2i(farm.x, farm.y), ContinuumTileKind.Options.farm) == "potential 90%",
		context + " productive zone potential uses typed operational ecology, not source-column bytes/defaults")
	check(main.map._potential_yield(Vector2i(13, 12), ContinuumTileKind.Options.forest) == "potential unknown",
		context + " missing operational ecology remains unknown despite physical terrain/source ecology")
