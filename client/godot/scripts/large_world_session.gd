## Narrow Main integration: bootstrap readiness, camera streaming, and loading UI.
class_name LargeWorldSession
extends RefCounted

signal ready
signal failed(message: String)
var loading := WorldLoadingState.new()
var detail := TerrainStream.new()
var overview := TerrainOverviewCache.new()
var adapter := CompactTerrainAdapter.new()
var map: ColonyMap
var client: Variant
var epoch := 0
var generation := -1
var compact := false
var _active := false
var _announced := false
var _dirty := false
var _camera_dirty := false
var _bootstrap_seconds := 0.0
var _legacy_handle: Variant
var _starter := Vector2i.ZERO
var _pinned_rect := Rect2i()
var _render_revision := -1
var _render_mode: StringName = &""
var _material_dirty := false
var _local_failure := ""
const PHASES := ["Preparing world", "Generating terrain", "Building overview", "Validating world", "Founding colony", "Ready", "Generation failed"]

func attach(value_map: ColonyMap) -> void:
	map = value_map
	map.camera_changed.connect(func() -> void: _camera_dirty = true)
	map.cut_changed.connect(func(_cut: int) -> void: _camera_dirty = true)
	detail.changed.connect(_detail_changed)
	detail.failed.connect(_fail)
	overview.changed.connect(_render_changed)
	overview.failed.connect(_fail)

static func supports_generation(db: Variant) -> bool:
	return LayeredTerrainModel.field(db, "world_generation") != null

static func bootstrap_queries(db: Variant, legacy_queries: PackedStringArray) -> PackedStringArray:
	if not supports_generation(db):
		return legacy_queries
	var queries := PackedStringArray()
	for query in legacy_queries:
		if query not in ["SELECT * FROM terrain_chunk", "SELECT * FROM terrain"]:
			queries.append(query)
	queries.append("SELECT * FROM world_generation")
	return queries

## Returns true when this helper owns readiness; old bindings keep legacy Main.
func start(owner: Variant, session_epoch: int) -> bool:
	stop()
	if not supports_generation(owner.db):
		return false
	client = owner
	epoch = session_epoch
	_active = true
	var rows := ColonyMap.table_rows(owner.db, "world_generation")
	if rows.is_empty():
		var geometry := ColonyMap.table_rows(owner.db, "world_geometry")
		var colony := ColonyMap.table_rows(owner.db, "colony")
		if geometry.is_empty() or colony.is_empty():
			loading.begin(owner, epoch, 0)
			_fail("World is uninitialized and generation state is unavailable.")
			return true
		generation = 0
		map.reset_world()
		map.bind_world_source(owner.db)
		loading.begin(owner, epoch, generation)
		loading.bootstrap_applied(owner, epoch, generation, false)
		_legacy_handle = owner.subscribe(PackedStringArray(["SELECT * FROM terrain_chunk", "SELECT * FROM terrain"]))
		if _legacy_handle.error != OK:
			_fail("Legacy terrain subscription failed.")
			return true
		_legacy_handle.applied.connect(_legacy_applied.bind(owner, epoch))
		_legacy_handle.end.connect(_legacy_ended.bind(owner, epoch))
		return true
	_install_world(rows[0])
	return true

func _install_world(row: Variant) -> void:
	_local_failure = ""
	detail.stop()
	overview.stop()
	adapter = CompactTerrainAdapter.new()
	generation = int(LayeredTerrainModel.field(row, "generation_id", -1))
	compact = true
	_announced = false
	loading.begin(client, epoch, generation)
	loading.bootstrap_applied(client, epoch, generation, true)
	if int(LayeredTerrainModel.field(row, "storage_version", 1)) != 1:
		_active = false
		_fail("Unsupported terrain storage version; update this client.")
		return
	_starter = Vector2i(LayeredTerrainModel.field(row, "starter_x", 0), LayeredTerrainModel.field(row, "starter_y", 0))
	map.reset_world()
	map.bind_world_source(client.db)
	map.streamed_terrain = true
	map.terrain_model.configure_sources(32, CompactTerrainAdapter.read_material)
	map.terrain_model.set_geometry(row)
	map.terrain_model.set_materials(ColonyMap.table_rows(client.db, "terrain_material"))
	map.terrain_model.overview_frame_provider = overview.frame_samples
	map.prepare_stream_camera(_starter + Vector2i(12, 12))
	detail.eviction_adapter = adapter.evict
	detail.attach(client, map.terrain_model, epoch, generation, CompactTerrainAdapter.detail_queries, adapter.snapshot)
	overview.attach(client, map.terrain_model, epoch, generation)
	_dirty = true
	_camera_dirty = true
	_update_generation(row)

func _legacy_applied(owner: Variant, session_epoch: int) -> void:
	if client != owner or epoch != session_epoch or not _active:
		return
	map.refresh()
	loading.terrain_applied(client, epoch, generation, true)
	_announce()

func _legacy_ended(owner: Variant, session_epoch: int) -> void:
	if client == owner and epoch == session_epoch and _active:
		_fail("Legacy terrain subscription ended unexpectedly.")

func mark_changed(_table: String) -> void:
	_dirty = true
	if _table == "terrain_material":
		_material_dirty = true

func tick(delta: float) -> void:
	if not _active or client == null:
		return
	detail.tick(delta)
	overview.tick(delta)
	if _legacy_handle != null and not _announced:
		_bootstrap_seconds += delta
		if _bootstrap_seconds > 15.0:
			_fail("Legacy terrain acknowledgement timed out.")
			_bootstrap_seconds = -INF
	if not compact:
		return
	if _dirty:
		_dirty = false
		if _material_dirty:
			_material_dirty = false
			map.terrain_model.set_materials(ColonyMap.table_rows(client.db, "terrain_material"))
		var rows := ColonyMap.table_rows(client.db, "world_generation")
		if rows.is_empty():
			_fail("Generation state disappeared; reconnect required.")
			return
		if int(LayeredTerrainModel.field(rows[0], "generation_id", -1)) != generation:
			_install_world(rows[0])
		else:
			_update_generation(rows[0])
		for coordinate: Vector2i in detail.active_coordinates():
			if not adapter.snapshot(map.terrain_model, coordinate, client, generation):
				map.terrain_model.set_chunk_complete(coordinate, false)
				_fail("Authoritative terrain coverage became unavailable.")
		overview.refresh()
		_render_changed()
	if map.selected_rect() != _pinned_rect:
		_pinned_rect = map.selected_rect()
		detail.pin_selection(_pinned_rect)
		_camera_dirty = true
	if _camera_dirty and loading.error.is_empty() and loading._world_ready and map.size.x > 0 and map.size.y > 0:
		_camera_dirty = false
		var rect := map.visible_grid_rect(2)
		detail.request_frame(rect, map._cell_size(), map.terrain_model.cut)
		map.terrain_model.presentation_mode = detail.mode
		if detail.mode == &"overview":
			overview.request_frame(rect, map._cell_size(), map.terrain_model.cut)
		else:
			overview.stop()
		_render_changed()
		_detail_changed()

func _update_generation(row: Variant) -> void:
	if not _local_failure.is_empty():
		return
	var was_ready := loading._world_ready
	var phase_value: Variant = LayeredTerrainModel.field(row, "phase", 0)
	var ordinal := int(LayeredTerrainModel.field(phase_value, "value", phase_value))
	var message := str(LayeredTerrainModel.field(row, "error", ""))
	if ordinal == 6 and message.is_empty():
		message = "World generation failed."
	loading.server_progress(client, epoch, generation, PHASES[clampi(ordinal, 0, 6)],
		int(LayeredTerrainModel.field(row, "completed_units", 0)), int(LayeredTerrainModel.field(row, "total_units", 0)),
		bool(LayeredTerrainModel.field(row, "ready", false)), message)
	if not was_ready and loading._world_ready:
		var geometry := ColonyMap.table_rows(client.db, "world_geometry")
		if geometry.is_empty():
			_fail("Ready world has no authoritative geometry bounds.")
			return
		map.terrain_model.set_geometry(geometry[0])
		map.terrain_model.set_materials(ColonyMap.table_rows(client.db, "terrain_material"))
		map.prepare_stream_camera(_starter + Vector2i(12, 12))
		_camera_dirty = true

func _detail_changed() -> void:
	if not compact or client == null:
		return
	var anchor := Vector2i(floori((_starter.x + 12) / 32.0), floori((_starter.y + 12) / 32.0))
	if not _announced:
		var nearby_ready := true
		var area := map.visible_grid_rect().intersection(map.grid_bounds())
		var start := Vector2i(floori(area.position.x / 32.0), floori(area.position.y / 32.0))
		var finish := Vector2i(ceili(area.end.x / 32.0), ceili(area.end.y / 32.0))
		if (finish.x - start.x) * (finish.y - start.y) > detail.max_resident:
			nearby_ready = false
		else:
			for y in range(start.y, finish.y):
				for x in range(start.x, finish.x):
					if not detail.complete(Vector2i(x, y)):
						nearby_ready = false
		loading.terrain_applied(client, epoch, generation, nearby_ready and detail.complete(anchor) and map.terrain_model.source_chunks.has(anchor))
	_announce()
	_render_changed()

func _announce() -> void:
	if loading.playable and not _announced:
		_announced = true
		ready.emit()

func _render_changed() -> void:
	if map == null or not compact:
		return
	if not map._frozen_selection.is_empty() and not map.terrain_model.selection_valid(map._frozen_selection):
		map.clear_selection()
	map.queue_redraw()
	if map.size.x > 0 and map.size.y > 0:
		var frame := map.terrain_model.render_frame(map.visible_grid_rect(1))
		if frame.region.has_area() and not map.set_terrain_frame(frame):
			_fail("Terrain frame exceeded the renderer's bounded frame contract.")
	if _render_revision != map.terrain_model.revision or _render_mode != map.terrain_model.presentation_mode:
		_render_revision = map.terrain_model.revision
		_render_mode = map.terrain_model.presentation_mode
		if _render_mode == &"detail":
			map._invalidate_terrain_entities()
			map.terrain_view.update_entities(map.entity_descriptors())

func _fail(message: String) -> void:
	_local_failure = message
	loading.fail(message)
	failed.emit(message)

func stop() -> void:
	_active = false
	detail.stop()
	overview.stop()
	if _legacy_handle != null and client != null and is_instance_valid(_legacy_handle):
		if client.is_connected_db():
			if _legacy_handle.active:
				_legacy_handle.unsubscribe()
			else:
				var handle: Variant = _legacy_handle
				handle.applied.connect(func() -> void: handle.unsubscribe(), CONNECT_ONE_SHOT)
		else:
			client.discard_subscription(_legacy_handle)
	_legacy_handle = null
	client = null
	loading.client = null
	loading.playable = false
	loading.changed.emit()
	_announced = false
	_bootstrap_seconds = 0.0
	compact = false
	_local_failure = ""
	_render_revision = -1
	_render_mode = &""
	_pinned_rect = Rect2i()
	if map != null:
		map.streamed_terrain = false
		map.terrain_model.presentation_mode = &"detail"
		map.terrain_model.overview_frame_provider = Callable()
