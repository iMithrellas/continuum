## Locked schema adapter/lifecycle tests before combined binding regeneration.
extends Node

class Rows extends RefCounted:
	var values: Array = []
	func iter() -> Array:
		return values

class ExtendedDb extends ContinuumModuleDb:
	var world_generation := Rows.new()
	var terrain_column_chunk := Rows.new()
	var terrain_overview_chunk := Rows.new()

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
	check(bootstrap == PackedStringArray(["SELECT * FROM config", "SELECT * FROM world_generation"]), "compact bootstrap never subscribes whole terrain")
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
	main._subscription.applied.emit()
	check(main.visible and not main._menu.visible and main._world_overlay.is_visible_in_tree(), "bootstrap presents generation overlay on real controller route")
	check(main._world_overlay._phase.text == "Building overview" and main._world_overlay._progress.value == 25.0,
		"controller shows truthful phase/progress even without colonists")
	check(not main._state_ready and not main.map.is_processing_input() and not main._can_resume_colony(), "bootstrap/auth status does not grant editing or game navigation/resume")
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
	for handle in owner.get_children():
		if handle is SpacetimeDBSubscription and not handle.active:
			handle.applied.emit()
	check(main._state_ready and not main._world_overlay.visible and main.map.is_processing_input(), "real controller reaches gameplay immediately after ready world and nearby snapshot")
	main._on_subscription_applied(main._subscription, main._session_generation)
	check(main._world_overlay._phase.text == "Loading nearby terrain", "already-ready reconnect skips artificial generation phase/delay")
	main._large_world.tick(0.1)
	for handle in owner.get_children():
		if handle is SpacetimeDBSubscription and not handle.active:
			handle.applied.emit()
	check(main._state_ready and not main._world_overlay.visible, "ready-on-connect finishes with snapshot acknowledgement, no timer")
	status.phase = 6
	status.ready = false
	status.error = "Fixture generation failure"
	main._on_table_changed("world_generation")
	main._large_world.tick(0.1)
	check(main._world_overlay._phase.text == status.error and not main._state_ready, "server generation failure remains visible and non-playable")
	main._world_overlay._cancel.pressed.emit()
	check(owner.disconnects > 0 and not main._session_requested and main._menu.visible and not main._world_overlay.visible, "overlay cancel disconnects current client and returns to menu")
	main._has_configured_client = false
	status.phase = 1
	status.error = ""
	main._menu._last_button.pressed.emit()
	main._subscription.applied.emit()
	owner.disconnected.emit()
	check(not main._state_ready and main._menu.visible and not main._world_overlay.visible, "actual disconnect during generation exits loading and restores menu")
	main.free()
	local.free()
	SpacetimeDB.Continuum = old_client
	owner.queue_free()
	await get_tree().process_frame
