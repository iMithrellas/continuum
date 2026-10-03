## Renders replicated terrain and actors. Selection and planning signals do not
## mutate server state; the controller owns reducer dispatch.
class_name ColonyMap
extends Control

## Sparse terrain selects coordinates without a durable row (tile_id = -1).
signal tile_selected(tile_id: int)
signal rectangle_selected(rect: Rect2i)
signal build_rectangle_requested(rect: Rect2i)
signal excavation_requested(rect: Rect2i, bottom_z: int, height: int)
signal facility_requested(cell: Vector3i)
signal cut_changed(layer: int)
signal cell_selected(cell: Vector3i)
signal selection_invalidated
signal camera_changed
## Main owns the exclusive planning system; this view owns only the gesture.
signal tool_cancelled
var planning_preview: Callable

var terrain_model := LayeredTerrainModel.new()
## Physical subscription/model ownership is external in compact mode.
var streamed_terrain := false
var _stream_camera_focus: Variant = null
var terrain_view := LayeredTerrainView.new()
var layered := false
var excavation_height := 6
var facility_width := 1
var facility_depth := 1
var facility_height := 6
var selected_base := 0
var _drag_layer := 0
var _visual_feet: Dictionary[int, Vector3] = {}
var _visual_motion: Dictionary[int, Dictionary] = {}
var _frozen_selection: Dictionary = {}
var _source_db: Object
var _tiles: Array[ContinuumTile] = []
var _facilities: Array[ContinuumTile] = []
var _colonists: Array[ContinuumColonist] = []
var _stacks: Array[ContinuumItemStack] = []
var _tile_index: Dictionary = {}
var _visible_tile_cache: Array[ContinuumTile] = []
var _visible_tiles_dirty := true
var _tile_revision := 0
var _rectangle_tiles_key: Array = []
var _rectangle_tiles: Array[ContinuumTile] = []
var _static_entity_buckets: Dictionary = {}
var _camera_static_entities: Array = []
var _static_camera_region := Rect2i()
var _static_camera_dirty := true
var _static_entity_serial := 0
var _zoom := 1.0
var _pan := Vector2.ZERO
## Last laid-out world anchor, not reconstructed from an already-resized Control.
## Keep it through zero-size intermediate layouts; world/camera resets discard it.
var _resize_world_center: Variant = null
var _panning := false
var _pan_pointer := Vector2.ZERO

static var RESOURCE_COLORS: Dictionary[int, Color] = {
	ContinuumResourceKind.Options.food: ThemeTokens.color("ink"),
	ContinuumResourceKind.Options.wood: ThemeTokens.color("ink"),
	ContinuumResourceKind.Options.stone: ThemeTokens.color("ink"),
	ContinuumResourceKind.Options.meat: ThemeTokens.color("ink"),
}
const COLONIST_WALK_TEXTURE: Texture2D = preload("res://assets/world/colonist_walk.png")
const COLONIST_WALK_FRAME_COUNT := 4
const COLONIST_WALK_FRAME_MS := 140
const COLONIST_WALK_FRAME_SIZE := 32.0

const PRIORITY_NAMES := {1: "High", 2: "Normal", 3: "Low"}

var selected_tile_id: int = -1
var interaction_mode := &"select"
var build_kind := ContinuumTileKind.Options.farm
var _selection_rect := Rect2i()
var _dragging := false
var _drag_start := Vector2i.ZERO
var _drag_current := Vector2i.ZERO
var _drag_inside := false

var _visual_positions: Dictionary[int, Vector2] = {}
var _font: Font = null
## Grid extent, derived from the tiles the server actually sent.
var _grid := Vector2i(24, 24)
var _has_state: bool = false
var _generation := -1
var _regions: Array[Dictionary] = []
var _region_revision := -1
var _region_visibility_revision := -1
var _region_layered := false
var _visible_regions: Array[Dictionary] = []
var _region_buckets: Dictionary = {}
var _camera_regions: Array[Dictionary] = []
var _region_camera_rect := Rect2i()
var _region_camera_dirty := true
## Orders are indexed on replication, never scanned on moving-actor frames.
var _work_orders_by_tile: Dictionary = {}
var _work_labels_dirty := true
var _hover_cell: Variant = null
var _hover_point := Vector2.ZERO
var _selected_actor_centre: Variant = null
var _actor_plate_cache: Dictionary = {}
var _actor_name_cache: Dictionary = {}
var _destination_plate_cache: Dictionary = {}
var _preview_plate_cache: Dictionary = {}
var _terrain_status_cache: Dictionary = {}
var selected_colonist_id := -1
var _alert_pins: Array[Dictionary] = []
var _excavation_regions: Array[Dictionary] = []
var _excavation_revision := -1
var _walk_frame := 0
## Global drag tracking must never treat floating windows as map cells.
var input_blocked: Callable
var metrics := UiMetrics.new()


func _ready() -> void:
	metrics = UiMetrics.new()
	_font = ThemeTokens.font("body")
	texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	clip_contents = true
	set_process(true)
	set_process_input(true)
	mouse_default_cursor_shape = Control.CURSOR_CROSS
	focus_mode = Control.FOCUS_CLICK
	focus_exited.connect(cancel_gestures)
	mouse_exited.connect(_clear_hover)
	terrain_view.attach(self)
	terrain_view.presentation_changed.connect(queue_redraw)
	terrain_view.set_visible(false)
	resized.connect(_on_map_resized)


func _on_map_resized() -> void:
	var ready := has_world_snapshot()
	cancel_gestures()
	if ready and _fit_cell_size() > 0:
		if _stream_camera_focus != null:
			_zoom = ThemeTokens.number("tile") / _fit_cell_size()
			_center_camera_at(Vector2(_stream_camera_focus))
			_stream_camera_focus = null
		elif _resize_world_center != null:
			_center_camera_at(_resize_world_center)
	_layout_terrain()
	if layered and has_world_snapshot():
		terrain_view.update_entities(entity_descriptors())


func _layout_terrain() -> void:
	if has_world_snapshot() and _cell_size() > 0:
		_resize_world_center = screen_to_world(size * 0.5)
	if layered and not streamed_terrain:
		terrain_model.warm_region(visible_grid_rect())
	terrain_view.layout(_origin(), Vector2(_grid) * _cell_size())
	if _hover_cell != null:
		_hover_cell = _cell_at(_hover_point)
	queue_redraw()
	camera_changed.emit()


func _center_camera_at(world: Vector2) -> void:
	var cell := _cell_size()
	var centred := ((size - Vector2(_grid) * cell) * 0.5).floor()
	_pan = size * 0.5 - (world - Vector2(grid_bounds().position)) * cell - centred


## Streaming owner supplies an epoch-checked frame after exact cache updates.
## This installs visual data only; overview values never enter terrain_model.
func set_terrain_frame(frame: Dictionary) -> bool:
	if not layered or not has_world_snapshot() or not terrain_view.rebuild_frame(terrain_model, frame):
		return false
	terrain_view.set_visible(true)
	terrain_view.update_entities(entity_descriptors())
	queue_redraw()
	return true


func _fit_cell_size() -> float:
	return minf(size.x / maxi(1, _grid.x), size.y / maxi(1, _grid.y))


func screen_to_world(point: Vector2) -> Vector2:
	return (point - _origin()) / maxf(_cell_size(), 0.0001)


func world_to_screen(point: Vector2) -> Vector2:
	return _origin() + point * _cell_size()


func zoom_percent() -> float:
	return _cell_size() / ThemeTokens.number("tile") * 100.0


func zoom_at(factor: float, point: Vector2) -> void:
	if not has_world_snapshot() or factor <= 0 or _fit_cell_size() <= 0:
		return
	cancel_gestures()
	var world := screen_to_world(point)
	var minimum := minf(0.25, ThemeTokens.number("tile") / _fit_cell_size())
	_zoom = clampf(_zoom * factor, minimum, maxf(1.0, ThemeTokens.number("tile") * 4.0 / _fit_cell_size()))
	var centred := ((size - Vector2(_grid) * _cell_size()) * 0.5).floor()
	_pan = point - (world - Vector2(grid_bounds().position)) * _cell_size() - centred
	_layout_terrain()
	if layered:
		terrain_view.update_entities(entity_descriptors())


func fit_camera() -> void:
	if not has_world_snapshot():
		return
	cancel_gestures()
	_zoom = 1.0
	_pan = Vector2.ZERO
	_resize_world_center = null
	_layout_terrain()
	if layered:
		terrain_view.update_entities(entity_descriptors())


func reset_camera() -> void:
	fit_camera()
	if _fit_cell_size() > 0:
		zoom_at(ThemeTokens.number("tile") / _fit_cell_size(), size * 0.5)

func prepare_stream_camera(focus: Vector2i) -> void:
	_grid = Vector2i(terrain_model.width, terrain_model.height)
	layered = true
	_has_state = true
	_resize_world_center = null
	if _fit_cell_size() <= 0:
		_stream_camera_focus = focus
		return
	_stream_camera_focus = null
	_zoom = ThemeTokens.number("tile") / maxf(_fit_cell_size(), 0.0001)
	_center_camera_at(Vector2(focus))
	_layout_terrain()

func focus_detail_at(point: Vector2) -> void:
	var world := screen_to_world(point)
	cancel_gestures()
	_zoom = ThemeTokens.number("tile") / maxf(_fit_cell_size(), 0.0001)
	_center_camera_at(world)
	terrain_model.presentation_mode = &"detail"
	_layout_terrain()


func pan_by(offset: Vector2) -> void:
	if not has_world_snapshot():
		return
	_dragging = false
	_drag_inside = false
	_pan += offset
	_layout_terrain()
	if layered:
		terrain_view.update_entities(entity_descriptors())


func cancel_gestures() -> void:
	_dragging = false
	_drag_inside = false
	_panning = false
	queue_redraw()


func _clear_hover() -> void:
	_hover_cell = null
	queue_redraw()


func visible_grid_rect(padding := 0) -> Rect2i:
	if not has_world_snapshot():
		return Rect2i()
	var start := screen_to_world(Vector2.ZERO).floor()
	var end := screen_to_world(size).ceil()
	return Rect2i(Vector2i(start) - Vector2i.ONE * padding,
		Vector2i(end - start) + Vector2i.ONE * padding * 2).intersection(grid_bounds())


func grid_bounds() -> Rect2i:
	return terrain_model.bounds() if layered else Rect2i(Vector2i.ZERO, _grid)


func set_cut(layer: int) -> void:
	if not has_world_snapshot() or not terrain_model.set_cut(layer):
		return
	cancel_gestures()
	selected_tile_id = -1
	_selection_rect = Rect2i()
	_frozen_selection = {}
	if layered:
		if not streamed_terrain:
			terrain_model.warm_region(visible_grid_rect())
			terrain_view.rebuild(terrain_model)
		_invalidate_terrain_entities()
		terrain_view.update_entities(entity_descriptors())
	_sync_regions()
	_cache_excavations()
	cut_changed.emit(terrain_model.cut)
	queue_redraw()


func row_visible(row: Variant) -> bool:
	if not has_world_snapshot():
		return false
	if layered and row is ContinuumColonist:
		return terrain_model.position_visible(_feet(row), row.body_width, row.body_depth)
	return not layered or terrain_model.entity_visible(row)


func reset_world() -> void:
	_stream_camera_focus = null
	_resize_world_center = null
	_source_db = null
	terrain_model.reset()
	terrain_view.reset()
	_visual_feet.clear()
	_visual_motion.clear()
	_visual_positions.clear()
	_regions.clear()
	_visible_regions.clear()
	_region_buckets.clear()
	_camera_regions.clear()
	_region_camera_dirty = true
	_region_revision = -1
	_region_visibility_revision = -1
	_work_orders_by_tile.clear()
	_work_labels_dirty = true
	_clear_hover()
	_selected_actor_centre = null
	_actor_plate_cache.clear()
	_actor_name_cache.clear()
	_destination_plate_cache.clear()
	_preview_plate_cache.clear()
	_terrain_status_cache.clear()
	_alert_pins.clear()
	_excavation_regions.clear()
	_excavation_revision = -1
	selected_colonist_id = -1
	_tiles.clear()
	_facilities.clear()
	_colonists.clear()
	_stacks.clear()
	_tile_index.clear()
	_visible_tile_cache.clear()
	_visible_tiles_dirty = true
	_tile_revision += 1
	_rectangle_tiles_key.clear()
	_rectangle_tiles.clear()
	_static_entity_buckets.clear()
	_camera_static_entities.clear()
	_static_camera_dirty = true
	_zoom = 1.0
	_pan = Vector2.ZERO
	_generation = -1
	_has_state = false
	layered = false
	cancel_gestures()
	clear_selection()
	camera_changed.emit()
	queue_redraw()


func bind_world_source(source: Object) -> void:
	if _source_db != source:
		reset_world()
		_source_db = source


func has_world_snapshot() -> bool:
	bind_world_source(SpacetimeDB.Continuum.db)
	return _source_db != null and _has_state


func clear_selection() -> void:
	cancel_gestures()
	selected_tile_id = -1
	_selection_rect = Rect2i()
	_frozen_selection = {}
	selection_invalidated.emit()
	queue_redraw()


static func designation_rect(row: Variant) -> Rect2i:
	return Rect2i(Vector2i(row.x_0, row.y_0), Vector2i(row.x_1 - row.x_0 + 1, row.y_1 - row.y_0 + 1))


func visible_tiles() -> Array[ContinuumTile]:
	if not has_world_snapshot():
		return []
	if _visible_tiles_dirty:
		_visible_tile_cache.clear()
		for tile: ContinuumTile in _tiles:
			if row_visible(tile):
				_visible_tile_cache.append(tile)
		_visible_tiles_dirty = false
	return _visible_tile_cache


func facility_tiles() -> Array[ContinuumTile]:
	var rows: Array[ContinuumTile] = []
	if not has_world_snapshot():
		return rows
	for tile in _facilities:
		if row_visible(tile):
			rows.append(tile)
	return rows


func tiles_in_rect(rect: Rect2i) -> Array[ContinuumTile]:
	if not has_world_snapshot():
		return []
	var key: Array = [rect, _tile_revision, terrain_model.revision, layered]
	if key == _rectangle_tiles_key:
		return _rectangle_tiles
	_rectangle_tiles_key = key
	_rectangle_tiles.clear()
	var seen := {}
	var area := rect.intersection(grid_bounds())
	for y in range(area.position.y, area.end.y):
		for x in range(area.position.x, area.end.x):
			for tile: ContinuumTile in _tile_index.get(Vector2i(x, y), []):
				if not seen.has(tile.id) and rect.has_point(Vector2i(tile.x, tile.y)) and row_visible(tile):
					seen[tile.id] = true
					_rectangle_tiles.append(tile)
	return _rectangle_tiles


func tile_at(xy: Vector2i) -> ContinuumTile:
	if not has_world_snapshot():
		return null
	var empty: ContinuumTile
	for tile: ContinuumTile in _tile_index.get(xy, []):
		if row_visible(tile) and (not layered or tile.z == terrain_model.base_at(xy)):
			if tile.kind.value != ContinuumTileKind.Options.empty:
				return tile
			empty = tile
	return empty


static func tile_footprint(tile: ContinuumTile) -> Rect2i:
	return Rect2i(Vector2i(tile.x, tile.y), Vector2i(
		LayeredTerrainModel.field(tile, "width", 1), LayeredTerrainModel.field(tile, "depth", 1)))


static func table_rows(db: Object, name: String) -> Array:
	var table: Variant = LayeredTerrainModel.field(db, name)
	return table.iter() if table != null else []


func set_interaction_mode(mode: StringName) -> void:
	interaction_mode = mode
	cancel_gestures()
	queue_redraw()


func set_build_kind(kind: int) -> void:
	build_kind = kind
	queue_redraw()


func set_selected_rect(rect: Rect2i) -> void:
	if not has_world_snapshot():
		return
	_selection_rect = rect.intersection(grid_bounds())
	if not _selection_rect.has_area():
		clear_selection()
		return
	_frozen_selection = terrain_model.capture_selection(_selection_rect) if layered else {}
	queue_redraw()


func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_WINDOW_FOCUS_OUT:
		cancel_gestures()


func selected_rect() -> Rect2i:
	if not has_world_snapshot():
		return Rect2i()
	if _dragging:
		return MapUiModel.normalize_rect(_drag_start, _drag_current)
	if _selection_rect.size != Vector2i.ZERO:
		return _selection_rect
	if selected_tile_id < 0:
		return Rect2i()
	var db: ContinuumModuleDb = _source_db
	var tile: ContinuumTile = db.tile.id.find(selected_tile_id)
	return tile_footprint(tile) if tile != null else Rect2i()


static func compatible_work(kind: int) -> Array[int]:
	match kind:
		ContinuumTileKind.Options.farm:
			return [ContinuumWorkType.Options.farming]
		ContinuumTileKind.Options.mine:
			return [ContinuumWorkType.Options.mining]
		ContinuumTileKind.Options.forest:
			return [ContinuumWorkType.Options.logging, ContinuumWorkType.Options.hunting]
	return []


func _process(delta: float) -> void:
	if not has_world_snapshot():
		return
	var changed: bool = false
	var animation_frame := int(Time.get_ticks_msec() / float(COLONIST_WALK_FRAME_MS)) % COLONIST_WALK_FRAME_COUNT
	if animation_frame != _walk_frame:
		_walk_frame = animation_frame
		for colonist in _colonists:
			if colonist.move_progress > 0 and row_visible(colonist):
				changed = true
				break
	for colonist: ContinuumColonist in _colonists:
		if layered:
			var previous: Dictionary = _visual_motion.get(colonist.id, {})
			if previous.get("source") == Vector3(colonist.x, colonist.y, colonist.z) and previous.get("next") == Vector3(colonist.next_x, colonist.next_y, colonist.next_z) and previous.progress == colonist.move_progress:
				continue
			var sample := LayeredTerrainModel.sample_movement(colonist, _visual_motion.get(colonist.id, {}), delta * 8.0)
			changed = changed or _visual_feet.get(colonist.id) != sample.position
			_visual_motion[colonist.id] = sample
			_visual_feet[colonist.id] = sample.position
			continue
		var target := _colonist_render_position(colonist)
		if not _visual_positions.has(colonist.id):
			_visual_positions[colonist.id] = target
			changed = true
			continue
		var current: Vector2 = _visual_positions[colonist.id]
		if current.distance_to(target) > 0.001:
			_visual_positions[colonist.id] = current.lerp(target, clampf(delta * 8.0, 0.0, 1.0))
			changed = true
	if changed:
		if layered:
			terrain_view.update_entities(entity_descriptors())
		queue_redraw()


func _colonist_render_position(colonist: ContinuumColonist) -> Vector2:
	var position := Vector2(colonist.x, colonist.y)
	var progress := clampf(colonist.move_progress, 0.0, 1.0)
	if layered:
		var hop := LayeredTerrainModel.movement_position(colonist)
		return Vector2(hop.x, hop.y)
	if progress <= 0.0:
		return position
	if colonist.x != colonist.target_x:
		position.x += 1.0 if colonist.target_x > colonist.x else -1.0
	elif colonist.y != colonist.target_y:
		position.y += 1.0 if colonist.target_y > colonist.y else -1.0
	return Vector2(
		lerpf(float(colonist.x), position.x, progress),
		lerpf(float(colonist.y), position.y, progress))


## Called by [Main] after subscribed world rows change.
func refresh(changed_tables: Dictionary = {}) -> void:
	bind_world_source(SpacetimeDB.Continuum.db)
	if _source_db == null:
		return
	var full := changed_tables.is_empty() or not _has_state
	var config: ContinuumConfig = SpacetimeDB.Continuum.db.config.id.find(0)
	if config != null and config.generation != _generation:
		_generation = config.generation
		_visual_positions.clear()
		_regions.clear()
		_visible_regions.clear()
		_region_buckets.clear()
		_camera_regions.clear()
		_region_camera_dirty = true
		_region_revision = -1
		_region_visibility_revision = -1
		_alert_pins.clear()
		_excavation_regions.clear()
		_excavation_revision = -1
		selected_colonist_id = -1
		_visual_feet.clear()
		_visual_motion.clear()
		if not streamed_terrain:
			terrain_model.reset()
		clear_selection()
		cancel_gestures()
		if not streamed_terrain:
			_zoom = 1.0
			_pan = Vector2.ZERO
			_resize_world_center = null
		full = true
	if full or changed_tables.has("tile"):
		_cache_tiles()
	if full or changed_tables.has("work_order"):
		_work_orders_by_tile.clear()
		for order: ContinuumWorkOrder in table_rows(_source_db, "work_order"):
			if not _work_orders_by_tile.has(order.tile_id):
				_work_orders_by_tile[order.tile_id] = {}
			_work_orders_by_tile[order.tile_id][order.work.value] = order
		_work_labels_dirty = true
	if full or changed_tables.has("colonist"):
		_colonists = SpacetimeDB.Continuum.db.colonist.iter()
		_colonists.sort_custom(func(a: ContinuumColonist, b: ContinuumColonist) -> bool: return a.id < b.id)
		for id in _visual_feet.keys():
			if SpacetimeDB.Continuum.db.colonist.id.find(id) == null:
				_visual_feet.erase(id)
				_visual_motion.erase(id)
	if full or changed_tables.has("item_stack"):
		_stacks = SpacetimeDB.Continuum.db.item_stack.iter()
	_has_state = not _tiles.is_empty()
	if _has_state and not layered:
		var extent := Vector2i.ZERO
		for tile: ContinuumTile in _tiles:
			extent.x = maxi(extent.x, tile.x + tile.width)
			extent.y = maxi(extent.y, tile.y + tile.depth)
		_grid = extent
	var geometry_rows := table_rows(SpacetimeDB.Continuum.db, "world_geometry")
	layered = not geometry_rows.is_empty()
	if layered:
		var changed := false
		if not streamed_terrain and (full or changed_tables.has("world_geometry") or changed_tables.has("terrain_chunk") or changed_tables.has("terrain_material")):
			changed = terrain_model.sync(geometry_rows[0], table_rows(SpacetimeDB.Continuum.db, "terrain_chunk"),
				table_rows(SpacetimeDB.Continuum.db, "terrain_material"))
		_grid = Vector2i(terrain_model.width, terrain_model.height)
		_has_state = true
		_layout_terrain()
		if changed:
			if not streamed_terrain:
				terrain_view.rebuild(terrain_model)
			if not _frozen_selection.is_empty() and not terrain_model.selection_valid(_frozen_selection):
				clear_selection()
		if full or changed or changed_tables.has("tile") or changed_tables.has("item_stack"):
			_invalidate_terrain_entities()
	terrain_view.set_visible(layered)
	_sync_regions()
	_sync_work_labels()
	if full or changed_tables.has("excavation_designation") or _excavation_revision != terrain_model.revision:
		_cache_excavations()
	if layered:
		terrain_view.update_entities(entity_descriptors())
	_layout_terrain()
	queue_redraw()


func _cache_tiles() -> void:
	_tiles = SpacetimeDB.Continuum.db.tile.iter()
	_tile_revision += 1
	_facilities.clear()
	_tile_index.clear()
	_visible_tiles_dirty = true
	for tile in _tiles:
		if tile.kind.value != ContinuumTileKind.Options.empty:
			_facilities.append(tile)
		var area := tile_footprint(tile)
		for y in range(area.position.y, area.end.y):
			for x in range(area.position.x, area.end.x):
				var xy := Vector2i(x, y)
				if not _tile_index.has(xy):
					_tile_index[xy] = []
				_tile_index[xy].append(tile)


func _feet(colonist: ContinuumColonist) -> Vector3:
	# Dictionary.get's fallback is eagerly evaluated in GDScript.
	return _visual_feet[colonist.id] if _visual_feet.has(colonist.id) else LayeredTerrainModel.movement_position(colonist)


func _cell_size() -> float:
	return _fit_cell_size() * _zoom


func _origin() -> Vector2:
	var cell := _cell_size()
	var used := Vector2(cell * _grid.x, cell * _grid.y)
	return ((size - used) * 0.5).floor() + _pan - Vector2(grid_bounds().position) * cell


func _draw() -> void:
	var ready := has_world_snapshot()
	var cell := _cell_size()
	if cell <= 0.0:
		return
	var origin := _origin()

	if not ready:
		draw_rect(Rect2(Vector2.ZERO, size), ThemeTokens.color("bg-000"))
		draw_string(_font, origin + Vector2(0.0, size.y * 0.5), "Waiting for colony state…",
				HORIZONTAL_ALIGNMENT_CENTER, size.x, metrics.font(13), ThemeTokens.color("ink-muted"))
		return
	if not layered:
		draw_rect(Rect2(origin, Vector2(cell * _grid.x, cell * _grid.y)), ThemeTokens.color("map-ground-deep"))
	if layered and (terrain_view.is_overview() or terrain_view.is_frame_suspended()):
		_draw_terrain_status()
		return

	if layered:
		var selected: ContinuumTile = SpacetimeDB.Continuum.db.tile.id.find(selected_tile_id)
		if selected != null and row_visible(selected):
			var selection := tile_footprint(selected)
			MapPaint.selection(self, Rect2(origin + Vector2(selection.position) * cell, Vector2(selection.size) * cell).grow(-2 * metrics.scale), metrics.scale)
	for tile: ContinuumTile in ([] if layered else visible_tiles()):
		var footprint := Vector2(LayeredTerrainModel.field(tile, "width", 1), LayeredTerrainModel.field(tile, "depth", 1))
		var rect := Rect2(origin + Vector2(tile.x * cell, tile.y * cell), footprint * cell)
		if not rect.intersects(Rect2(Vector2.ZERO, size)):
			continue
		if tile.kind.value == ContinuumTileKind.Options.empty:
			draw_rect(rect, ThemeTokens.color("map-ground"))
		else:
			MapPaint.zone(self, rect, tile.kind.value, -origin / cell, cell)

		if not tile.enabled and tile.kind.value != ContinuumTileKind.Options.empty:
			var pad := cell * 0.28
			var a := rect.position + Vector2(pad, pad)
			var b := rect.position + Vector2(cell - pad, cell - pad)
			var width := maxf(1.0, cell * 0.07)
			draw_line(a, b, ThemeTokens.color("map-paper"), width + 2 * metrics.scale)
			draw_line(a, b, ThemeTokens.color("map-ink"), width)
			draw_line(Vector2(a.x, b.y), Vector2(b.x, a.y), ThemeTokens.color("map-paper"), width + 2 * metrics.scale)
			draw_line(Vector2(a.x, b.y), Vector2(b.x, a.y), ThemeTokens.color("map-ink"), width)

		if tile.id == selected_tile_id:
			MapPaint.selection(self, rect.grow(-2 * metrics.scale), metrics.scale)

	var visible := visible_grid_rect()
	if interaction_mode != &"select" and cell >= 24 * metrics.scale:
		for y in range(visible.position.y, visible.end.y):
			for x in range(visible.position.x, visible.end.x):
				if layered and terrain_model.depth_at(Vector2i(x, y)) != 0:
					continue
				var corner := origin + Vector2(x, y) * cell
				draw_line(corner, corner + Vector2(cell, 0), MapPaint.translucent("map-paper", 0.12), metrics.scale)
				draw_line(corner, corner + Vector2(0, cell), MapPaint.translucent("map-paper", 0.12), metrics.scale)

	if not layered:
		_draw_colonists(origin, cell)
		_draw_ground_items(origin, cell)
	_draw_zone_labels(origin, cell)
	_draw_excavations(origin, cell)
	_draw_actor_overlays(origin, cell)
	if _selected_actor_centre != null:
		_draw_actor_intent(_selected_actor_centre, cell)
	if _selection_rect.size != Vector2i.ZERO and not _dragging:
		var selection_rect := Rect2(origin + Vector2(_selection_rect.position) * cell,
			Vector2(_selection_rect.size) * cell)
		MapPaint.selection(self, selection_rect.grow(-2 * metrics.scale), metrics.scale)
	_draw_drag_preview(origin, cell)
	_draw_terrain_status()


func _draw_terrain_status() -> void:
	var status := terrain_view.presentation_status()
	if not status.is_empty():
		MapPaint.plate(self, Vector2(8, size.y - 38) * Vector2(metrics.scale, 1), status, "", metrics.scale, false, _terrain_status_cache, Rect2(Vector2.ZERO, size))


func _draw_drag_preview(origin: Vector2, cell: float) -> void:
	if not _dragging:
		_draw_hover_preview(origin, cell)
		return
	var rect := MapUiModel.normalize_rect(_drag_start, _drag_current)
	if interaction_mode == &"facility":
		rect = Rect2i(_drag_start, Vector2i(facility_width, facility_depth))
	var invalid: bool = interaction_mode == &"facility" and layered and (terrain_model.uniform_base(rect) != selected_base \
		or not terrain_model.placement_clear(rect, selected_base, facility_height))
	var preview := Rect2(origin + Vector2(rect.position) * cell, Vector2(rect.size) * cell)
	MapPaint.selection(self, preview, metrics.scale)
	var occupied := 0
	for tile: ContinuumTile in facility_tiles():
		if rect.intersects(tile_footprint(tile)) and tile.kind.value != ContinuumTileKind.Options.empty:
			occupied += 1
	var text := "%d×%d · %d cells" % [rect.size.x, rect.size.y, rect.size.x * rect.size.y]
	if interaction_mode == &"build" and planning_preview.is_valid():
		text = planning_preview.call(rect)
	elif interaction_mode == &"build":
		text += "  %.0f wood" % (rect.size.x * rect.size.y * 20.0)
		if occupied > 0:
			text += "  OCCUPIED"
		var colony: ContinuumColony = SpacetimeDB.Continuum.db.colony.id.find(0)
		if colony == null or colony.wood < rect.size.x * rect.size.y * 20.0:
			text += "  NOT ENOUGH WOOD"
		if layered and terrain_model.uniform_base(rect) == null:
			text += "  MIXED / UNKNOWN ELEVATIONS"
	elif interaction_mode == &"excavate":
		text += "  z=%d..%d (%.1fm)" % [selected_base, selected_base + excavation_height - 1, excavation_height * 0.5]
	elif interaction_mode == &"facility":
		text = "%dx%d facility at z=%d; clearance %.1fm" % [facility_width, facility_depth, selected_base, facility_height * 0.5]
	if invalid:
		text += " · Blocked"
	if rect.size == Vector2i.ONE:
		var tile := tile_at(_drag_start)
		var kind := build_kind if interaction_mode in [&"build", &"facility"] else (tile.kind.value if tile != null else ContinuumTileKind.Options.empty)
		var potential := _potential_yield(_drag_start, kind)
		if not potential.is_empty() and interaction_mode != &"excavate" and not (interaction_mode == &"build" and planning_preview.is_valid()):
			text = potential + " · " + text
	text = "Release to %s · " % ("select" if interaction_mode == &"select" else "request") + text
	MapPaint.plate(self, preview.position + Vector2(4, 4) * metrics.scale, "", text, metrics.scale, false, _preview_plate_cache, Rect2(Vector2.ZERO, size))


## Hover predicts only known geometry; the server still decides every request.
func _draw_hover_preview(origin: Vector2, cell: float) -> void:
	if _hover_cell == null or _panning or interaction_mode == &"select":
		return
	var rect := Rect2i(_hover_cell, Vector2i(facility_width, facility_depth) if interaction_mode == &"facility" else Vector2i.ONE)
	var preview := Rect2(origin + Vector2(rect.position) * cell, Vector2(rect.size) * cell)
	MapPaint.selection(self, preview, metrics.scale)
	MapPaint.plate(self, preview.position + Vector2(0, -28) * metrics.scale, "", action_hint(_hover_cell), metrics.scale, false, _preview_plate_cache, Rect2(Vector2.ZERO, size))


## A compact instruction with local geometry facts, never an approval verdict.
func action_hint(xy: Vector2i) -> String:
	if not has_world_snapshot():
		return ""
	var base: Variant = terrain_model.base_at(xy) if layered else 0
	if base == null:
		return "Unknown surface · change layer to inspect"
	match interaction_mode:
		&"facility":
			var rect := Rect2i(xy, Vector2i(facility_width, facility_depth))
			var hint := "%s %d×%d" % [ContinuumTileKind.parse_enum_name(build_kind).capitalize(), facility_width, facility_depth]
			if layered and terrain_model.uniform_base(rect) != base:
				return "Mixed / unknown elevations · %d×%d footprint" % [facility_width, facility_depth]
			if layered and not terrain_model.placement_clear(rect, base, facility_height):
				return "Terrain clearance blocked · z=%d" % base
			for y in range(rect.position.y, rect.end.y):
				for x in range(rect.position.x, rect.end.x):
					var tile := tile_at(Vector2i(x, y))
					if tile != null and tile.kind.value != ContinuumTileKind.Options.empty:
						return "Occupied footprint · %d×%d" % [facility_width, facility_depth]
			var potential := _potential_yield(xy, build_kind)
			if not potential.is_empty():
				hint += " · " + potential
			return hint + " · click to request"
		&"excavate":
			return "Excavate · drag area · z=%d..%d" % [base, base + excavation_height - 1]
		&"build":
			if planning_preview.is_valid(): return planning_preview.call(Rect2i(xy, Vector2i.ONE))
			var hint := ContinuumTileKind.parse_enum_name(build_kind).capitalize()
			var potential := _potential_yield(xy, build_kind)
			if not potential.is_empty():
				hint += " · " + potential
			return hint + " · drag area to request"
	return "Click to inspect · drag to select area"


## Operational Tile ecology wins. Otherwise inspect only the exact acknowledged
## compact column in detail; representatives/neighbours cannot supply potential.
func _ecology_fields(tile: ContinuumTile, xy: Variant = null) -> Dictionary:
	if layered and (terrain_model.presentation_mode != &"detail" or terrain_view.is_overview() or terrain_view.is_frame_suspended()):
		return {}
	if tile != null and _source_db != null:
		var terrain: ContinuumTerrain = _source_db.terrain.tile_id.find(tile.id)
		if terrain != null:
			return {"soil_fertility": terrain.soil_fertility, "moisture": terrain.moisture,
				"forest_density": terrain.forest_density}
	if not layered or not xy is Vector2i:
		return {}
	var data := terrain_model.frame_samples(Rect2i(xy, Vector2i.ONE), 1, 1)
	if data.mode != &"detail" or data.cut != terrain_model.cut or data.samples.size() != 1:
		return {}
	var sample: Dictionary = data.samples[0]
	if sample.xy != xy or sample.state != &"surface" or not sample.has_all(TerrainArt.ECOLOGY_FIELDS) or not TerrainArt.valid_ecology(sample):
		return {}
	return {"soil_fertility": sample.soil_fertility, "forest_density": sample.forest_density, "moisture": sample.moisture}


## Placement previews describe the anchor's potential, never a footprint average
## or current output. Logging and hunting share the same ecological multiplier.
func _potential_yield(xy: Vector2i, kind: int) -> String:
	if kind not in [ContinuumTileKind.Options.farm, ContinuumTileKind.Options.forest]:
		return ""
	if layered and (terrain_model.presentation_mode != &"detail" or terrain_view.is_overview() or terrain_view.is_frame_suspended()):
		return "potential unknown"
	var fields := _ecology_fields(tile_at(xy), xy)
	if fields.is_empty():
		return "potential unknown"
	var work := ContinuumWorkType.Options.farming if kind == ContinuumTileKind.Options.farm else ContinuumWorkType.Options.logging
	return "potential %.0f%%" % (100.0 * ProductionSuitability.multiplier(work, fields))


## Topology changes only with facilities. Cut/terrain changes recompute exposure,
## never connectivity from a camera crop; moving actors do neither.
func _sync_regions() -> void:
	if _region_revision != _tile_revision:
		var footprints: Array = []
		for tile: ContinuumTile in _facilities:
			footprints.append({"kind": tile.kind.value, "z": tile.z, "rect": tile_footprint(tile)})
		_regions = MapRegions.build(footprints)
		_region_revision = _tile_revision
		_region_visibility_revision = -1
	if _region_visibility_revision == terrain_model.revision and _region_layered == layered:
		return
	_region_visibility_revision = terrain_model.revision
	_region_layered = layered
	_visible_regions.clear()
	_region_buckets.clear()
	_region_camera_dirty = true
	_work_labels_dirty = true
	var exposed_by_z := {}
	for tile: ContinuumTile in _facilities:
		if not row_visible(tile):
			continue
		var group := Vector2i(tile.kind.value, tile.z)
		if not exposed_by_z.has(group):
			exposed_by_z[group] = {}
		var footprint := tile_footprint(tile)
		for y in range(footprint.position.y, footprint.end.y):
			for x in range(footprint.position.x, footprint.end.x):
				exposed_by_z[group][Vector2i(x, y)] = tile
	for region: Dictionary in _regions:
		var exposed: Dictionary = exposed_by_z.get(Vector2i(region.kind, region.z), {})
		if exposed.is_empty():
			continue
		var visible_edges: Array[PackedVector2Array] = []
		for edge: PackedVector2Array in region.edges:
			var direction := edge[1] - edge[0]
			var inside := (edge[0] + edge[1]) * 0.5 + Vector2(-direction.y, direction.x) * 0.25
			if exposed.has(Vector2i(inside.floor())):
				visible_edges.append(edge)
		if visible_edges.is_empty() and not exposed.has(region.anchor):
			continue
		var item := region.duplicate()
		item["visible_edges"] = visible_edges
		item["label_visible"] = exposed.has(region.anchor)
		item["plate_cache"] = {}
		var sites := {}
		for xy: Vector2i in region.cells:
			var tile: ContinuumTile = exposed.get(xy)
			if tile != null:
				sites[tile.id] = tile
		item["sites"] = sites
		item["work_label"] = ""
		item["cache_id"] = _visible_regions.size()
		_visible_regions.append(item)
		var bounds: Rect2i = region.bounds
		for y in range(floori(bounds.position.y / 16.0), ceili(bounds.end.y / 16.0)):
			for x in range(floori(bounds.position.x / 16.0), ceili(bounds.end.x / 16.0)):
				var bucket := Vector2i(x, y)
				if not _region_buckets.has(bucket):
					_region_buckets[bucket] = []
				_region_buckets[bucket].append(item)
	_sync_work_labels()


## Region connectivity stays stable when orders pause or change priority.
func _sync_work_labels() -> void:
	if not _work_labels_dirty:
		return
	_work_labels_dirty = false
	for region: Dictionary in _visible_regions:
		var states := {}
		for tile: ContinuumTile in region.sites.values():
			if not tile.enabled:
				states["OFF"] = true
				continue
			for work: int in compatible_work(tile.kind.value):
				var order: ContinuumWorkOrder = _work_orders_by_tile.get(tile.id, {}).get(work)
				var state := "NO ORDER"
				if order != null:
					state = str(PRIORITY_NAMES.get(order.priority, "Unknown")).to_upper() if order.enabled else "PAUSED"
				states[state] = true
		var labels := PackedStringArray()
		for state in ["OFF", "PAUSED", "NO ORDER", "HIGH", "NORMAL", "LOW", "UNKNOWN"]:
			if states.has(state):
				labels.append("ORDER " + state if state in ["HIGH", "NORMAL", "LOW", "UNKNOWN"] else state)
		region.work_label = " / ".join(labels)


func _draw_zone_labels(origin: Vector2, cell: float) -> void:
	var visible := visible_grid_rect()
	if _region_camera_dirty or visible != _region_camera_rect:
		_region_camera_rect = visible
		_region_camera_dirty = false
		_camera_regions.clear()
		var seen := {}
		for y in range(floori(visible.position.y / 16.0), ceili(visible.end.y / 16.0)):
			for x in range(floori(visible.position.x / 16.0), ceili(visible.end.x / 16.0)):
				for region: Dictionary in _region_buckets.get(Vector2i(x, y), []):
					if not seen.has(region.cache_id) and region.bounds.intersects(visible):
						seen[region.cache_id] = true
						_camera_regions.append(region)
	var viewport := Rect2(Vector2.ZERO, size)
	for region: Dictionary in _camera_regions:
		var bounds := Rect2(origin + Vector2(region.bounds.position) * cell, Vector2(region.bounds.size) * cell)
		if not bounds.intersects(viewport):
			continue
		var focused := _region_focused(region)
		var forest: bool = region.kind == ContinuumTileKind.Options.forest
		if focused or (not forest and cell >= 8 * metrics.scale):
			for edge: PackedVector2Array in region.visible_edges:
				draw_line(origin + edge[0] * cell, origin + edge[1] * cell, MapPaint.translucent("map-ink", 0.38), metrics.scale)
		if region.label_visible and region_label_visible(region, cell):
			var anchor := origin + Vector2(region.anchor) * cell + Vector2.ONE * 4 * metrics.scale
			var title := ContinuumTileKind.parse_enum_name(region.kind).to_upper()
			if not region.work_label.is_empty() and MapLabelLod.work(cell, metrics.scale, focused):
				title += " · " + region.work_label
			MapPaint.plate(self, anchor, title, str(region.count), metrics.scale, false, region.plate_cache, viewport if viewport.has_point(anchor) else Rect2())


func _region_focused(region: Dictionary) -> bool:
	if (_hover_cell != null and region.cells.has(_hover_cell)) or region.get("sites", {}).has(selected_tile_id):
		return true
	if _selection_rect.has_area() and _selection_rect.intersects(region.bounds):
		if _selection_rect.encloses(region.bounds): return true
		for xy: Vector2i in region.cells:
			if _selection_rect.has_point(xy): return true
	return false


func region_label_visible(region: Dictionary, cell: float) -> bool:
	var focused := _region_focused(region)
	if not MapLabelLod.region(cell, metrics.scale, focused):
		return false
	var minimum := 12 if region.kind == ContinuumTileKind.Options.forest else 3
	return focused or (region.count >= minimum and region.bounds.size.x * cell >= 58 * metrics.scale)


func _draw_ground_items(origin: Vector2, cell: float) -> void:
	for stack: ContinuumItemStack in SpacetimeDB.Continuum.db.item_stack.iter():
		if not row_visible(stack):
			continue
		if stack.amount <= 0.0:
			continue
		var column := 0.56 if stack.kind.value == ContinuumResourceKind.Options.meat else 0.04
		var rect := Rect2(origin + Vector2(stack.x + column, stack.y + 0.65) * cell,
				Vector2(cell * 0.40, cell * 0.33))
		MapPaint.crate(self, rect)


## One placement calculation feeds both legacy sprites and their selection rings.
## Authoritative occupancy determines stable offsets; interpolation determines
## the rendered position, and the supplied camera transforms both together.
func _legacy_colonist_descriptors(origin: Vector2, cell: float) -> Array[Dictionary]:
	var descriptors: Array[Dictionary] = []
	var colonists: Array[ContinuumColonist] = _colonists.duplicate()
	colonists.sort_custom(func(a: ContinuumColonist, b: ContinuumColonist) -> bool:
		return a.id < b.id)
	var occupants: Dictionary[Vector2i, Array] = {}
	for colonist: ContinuumColonist in colonists:
		if not row_visible(colonist):
			continue
		var tile := Vector2i(colonist.x, colonist.y)
		if not occupants.has(tile):
			occupants[tile] = []
		occupants[tile].append(colonist.id)

	for index in colonists.size():
		var colonist: ContinuumColonist = colonists[index]
		if not row_visible(colonist):
			continue
		var grid_pos: Vector2 = _visual_positions.get(colonist.id,
				Vector2(colonist.x, colonist.y))
		var centre := origin + (grid_pos + Vector2(0.5, 0.5)) * cell
		var sharing: Array = occupants[Vector2i(colonist.x, colonist.y)]
		if sharing.size() > 1:
			centre += Vector2.from_angle(TAU * sharing.find(colonist.id) / sharing.size()) * cell * 0.25
		var sprite_size := cell * (0.62 if sharing.size() > 1 else 0.82)
		var sprite_rect := Rect2(centre - Vector2.ONE * sprite_size * 0.5,
				Vector2.ONE * sprite_size)
		descriptors.append({"colonist": colonist, "rect": sprite_rect})
	return descriptors


func _draw_colonists(origin: Vector2, cell: float) -> void:
	for descriptor: Dictionary in _legacy_colonist_descriptors(origin, cell):
		_draw_legacy_colonist(descriptor, cell)


func _draw_legacy_colonist(descriptor: Dictionary, cell: float) -> void:
	var colonist: ContinuumColonist = descriptor.colonist
	var sprite_rect: Rect2 = descriptor.rect
	var walking := colonist.x != colonist.target_x \
			or colonist.y != colonist.target_y \
			or colonist.move_progress > 0.001
	var frame := _walk_frame if walking else 0
	var source_rect := Rect2(frame * COLONIST_WALK_FRAME_SIZE, 0.0,
			COLONIST_WALK_FRAME_SIZE, COLONIST_WALK_FRAME_SIZE)
	MapPaint.sprite(self, COLONIST_WALK_TEXTURE, sprite_rect, source_rect, metrics.scale)
	if colonist.carried_amount > 0.0:
		var cargo_rect := Rect2(sprite_rect.end - Vector2.ONE * cell * 0.25, Vector2.ONE * cell * 0.25)
		MapPaint.crate(self, cargo_rect)


func _get_tooltip(at_position: Vector2) -> String:
	if not has_world_snapshot() or _cell_size() <= 0.0:
		return ""
	if not Rect2(Vector2.ZERO, size).has_point(at_position):
		return ""
	var local := screen_to_world(at_position)
	var db: ContinuumModuleDb = _source_db
	var grid_pos := Vector2i(floori(local.x), floori(local.y))
	if not grid_bounds().has_point(grid_pos):
		return ""
	if layered and (terrain_model.presentation_mode != &"detail" or terrain_view.is_overview()):
		return "Terrain overview · zoom in to inspect"
	if layered and terrain_view.is_frame_suspended():
		return terrain_view.presentation_status()
	var lines := PackedStringArray()
	lines.append(action_hint(grid_pos))
	if layered:
		var surface: Variant = terrain_model.surface_at(grid_pos)
		if surface == null:
			lines.insert(0, "No known surface at (%d, %d), cut z=%d" % [grid_pos.x, grid_pos.y, terrain_model.cut])
			return "\n".join(lines)
		var material_id := terrain_model.material_at(surface)
		lines.append("%s material #%d at (%d, %d, %d) | depth %d (%.1fm) | base z=%d" % [
			LayeredTerrainModel.field(terrain_model.materials.get(material_id), "name", "unknown"), material_id,
			surface.x, surface.y, surface.z, terrain_model.depth_at(grid_pos), terrain_model.depth_at(grid_pos) * 0.5,
			terrain_model.base_at(grid_pos)])
	var tile := tile_at(grid_pos)
	var fields := _ecology_fields(tile, grid_pos)
	if tile != null:
		lines.append("%s (%d, %d) / %s" % [
			ContinuumTileKind.parse_enum_name(tile.kind.value).capitalize(), tile.x, tile.y,
			"enabled" if tile.enabled else "disabled"])
	if not fields.is_empty():
		lines.append("Soil: %s  fertility %.2f  moisture %.2f" % [
			_soil_name(fields.soil_fertility, fields.moisture), fields.soil_fertility, fields.moisture])
		lines.append("Cover potential: %s  density %.2f" % [
			_cover_name(fields.forest_density), fields.forest_density])
	if tile != null:
		for work: int in compatible_work(tile.kind.value):
			var description := "no order (no production)"
			for order: ContinuumWorkOrder in db.work_order.iter():
				if order.tile_id == tile.id and order.work.value == work:
					description = "#%d: %s / %s" % [order.id, "enabled" if order.enabled else "paused",
						PRIORITY_NAMES.get(order.priority, "Unknown")]
					break
			lines.append("%s order: %s" % [ContinuumWorkType.parse_enum_name(work).capitalize(), description])
		if not compatible_work(tile.kind.value).is_empty():
			lines.append("Priority ranks enabled orders; stock policy can still suspend production.\nOld goods remain haulable.")
	var potential_work: Array[int] = []
	if interaction_mode in [&"build", &"facility"]:
		potential_work = compatible_work(build_kind)
		if not potential_work.is_empty():
			lines.append("Placement anchor potential at (%d, %d):" % [grid_pos.x, grid_pos.y])
	elif tile != null:
		potential_work = compatible_work(tile.kind.value)
	if potential_work.is_empty() and (tile == null or tile.kind.value == ContinuumTileKind.Options.empty):
		potential_work = [ContinuumWorkType.Options.farming, ContinuumWorkType.Options.logging, ContinuumWorkType.Options.hunting]
	for work: int in potential_work:
		lines.append(ProductionSuitability.work_line(work, fields))
	if not potential_work.is_empty():
		lines.append(ProductionSuitability.description(potential_work[0], fields).replace(". ", ".\n").replace(", ", ",\n"))
	for region: Dictionary in _excavation_regions:
		if region.cells.has(grid_pos):
			lines.append(region.status)
	for stack: ContinuumItemStack in db.item_stack.iter():
		if row_visible(stack) and Vector2i(stack.x, stack.y) == grid_pos:
			lines.append("Ground: %.1f %s" % [stack.amount,
				ContinuumResourceKind.parse_enum_name(stack.kind.value)])
	for colonist: ContinuumColonist in db.colonist.iter():
		var feet := _feet(colonist)
		var tooltip_xy := Vector2i(floori(feet.x), floori(feet.y)) if layered else Vector2i(colonist.x, colonist.y)
		if row_visible(colonist) and tooltip_xy == grid_pos:
			lines.append("%s: %s / %s / %s" % [colonist.name,
				ContinuumWorkType.parse_enum_name(colonist.work.value),
				"produce + haul" if colonist.haul_role.value == ContinuumHaulRole.Options.both
						else ContinuumHaulRole.parse_enum_name(colonist.haul_role.value),
				ContinuumActivity.parse_enum_name(colonist.activity.value)])
			lines.append("Cargo: %.1f %s" % [colonist.carried_amount,
				ContinuumResourceKind.parse_enum_name(colonist.carried_kind.value)]
					if colonist.carried_amount > 0.0 else "Cargo: empty hands")
			lines.append(colonist_intent(colonist))
	return "\n".join(lines)


func _soil_name(fertility: float, moisture: float) -> String:
	if fertility > 0.68 and moisture > 0.52:
		return "chernozem"
	if fertility > 0.36:
		return "loamy ground"
	return "sandy ground"


func _cover_name(density: float) -> String:
	if density > 0.72:
		return "forest"
	if density > 0.45:
		return "woodland"
	return "grassland"


func _cell_at(position: Vector2, clamp_to_grid := false) -> Variant:
	if not has_world_snapshot():
		return null
	var cell := _cell_size()
	if cell <= 0.0 or not Rect2(Vector2.ZERO, size).has_point(position):
		return null
	var grid_rect := Rect2(world_to_screen(Vector2(grid_bounds().position)), Vector2(cell * _grid.x, cell * _grid.y))
	if not grid_rect.has_point(position):
		return null
	var local := screen_to_world(position)
	var grid_pos := Vector2i(floori(local.x), floori(local.y))
	if not grid_bounds().has_point(grid_pos):
		return null
	return grid_pos


func _input(event: InputEvent) -> void:
	if not has_world_snapshot():
		return
	if event is InputEventKey and event.pressed and not event.echo:
		if not layer_shortcuts_allowed():
			return
		if event.keycode in [KEY_PAGEUP, KEY_BRACKETRIGHT]:
			set_cut(terrain_model.cut + 1)
			get_viewport().set_input_as_handled()
			return
		if event.keycode in [KEY_PAGEDOWN, KEY_BRACKETLEFT]:
			set_cut(terrain_model.cut - 1)
			get_viewport().set_input_as_handled()
			return
	if event is InputEventMouse and input_blocked.is_valid() and input_blocked.call(event.position):
		cancel_gestures()
		_clear_hover()
		return
	if event is InputEventKey and event.pressed and event.keycode == KEY_ESCAPE:
		cancel_gestures()
		tool_cancelled.emit()
		return
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_RIGHT and event.pressed:
		cancel_gestures()
		tool_cancelled.emit()
		return
	if event is InputEventMouseMotion and _panning:
		var point: Vector2 = get_global_transform().affine_inverse() * event.position
		pan_by(point - _pan_pointer)
		_pan_pointer = point
		get_viewport().set_input_as_handled()
		return
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_MIDDLE and not event.pressed:
		_panning = false
		return
	if event is InputEventMouseMotion and _dragging:
		var motion := event as InputEventMouseMotion
		var point := get_global_transform().affine_inverse() * motion.position
		_drag_inside = _cell_at(point) != null
		if _drag_inside:
			_drag_current = _cell_at(point)
			queue_redraw()
		return
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT and not event.pressed and _dragging:
		var release := event as InputEventMouseButton
		var point := get_global_transform().affine_inverse() * release.position
		if _cell_at(point) == null or not _drag_inside:
			_dragging = false
			queue_redraw()
			return
		var finish: Vector2i = _cell_at(point)
		var rect := MapUiModel.normalize_rect(_drag_start, finish)
		_dragging = false
		if layered and terrain_model.cut != _drag_layer:
			return
		if interaction_mode == &"excavate":
			excavation_requested.emit(rect, selected_base, excavation_height)
		elif interaction_mode == &"facility":
			facility_requested.emit(Vector3i(_drag_start.x, _drag_start.y, selected_base))
		elif interaction_mode == &"build":
			build_rectangle_requested.emit(rect)
		else:
			if rect.size == Vector2i.ONE:
				var hit := tile_at(finish)
				if hit != null:
					rect = tile_footprint(hit)
			rectangle_selected.emit(rect)
		queue_redraw()
		return


func _gui_input(event: InputEvent) -> void:
	if not has_world_snapshot():
		return
	if event is InputEventMouse and input_blocked.is_valid() and input_blocked.call(get_global_transform() * event.position):
		cancel_gestures()
		_clear_hover()
		return
	if event is InputEventMouseMotion:
		_hover_point = event.position
		var hovered: Variant = _cell_at(event.position)
		if hovered != _hover_cell:
			_hover_cell = hovered
			queue_redraw()
	if event is InputEventMouseButton and event.pressed:
		if event.button_index in [MOUSE_BUTTON_WHEEL_UP, MOUSE_BUTTON_WHEEL_DOWN]:
			zoom_at(pow(1.2, event.factor if event.button_index == MOUSE_BUTTON_WHEEL_UP else -event.factor), event.position)
			accept_event()
			return
		if event.button_index == MOUSE_BUTTON_MIDDLE:
			cancel_gestures()
			_panning = true
			_pan_pointer = event.position
			grab_focus()
			accept_event()
			return
	if _panning:
		return
	if event is InputEventMouseButton and event.pressed \
			and event.button_index == MOUSE_BUTTON_LEFT:
		var point := (event as InputEventMouseButton).position
		if terrain_model.presentation_mode == &"overview":
			focus_detail_at(point)
			accept_event()
			return
		var grid_pos: Variant = _cell_at(point)
		if grid_pos == null:
			clear_selection()
			return
		grab_focus()
		var base: Variant = terrain_model.base_at(grid_pos) if layered else 0
		if base == null and interaction_mode != &"select":
			return
		selected_base = int(base) if base != null else terrain_model.cut
		_drag_layer = terrain_model.cut
		var source := _source_db
		var surface: Variant = terrain_model.surface_at(grid_pos) if layered else null
		cell_selected.emit(surface if surface != null else Vector3i(grid_pos.x, grid_pos.y, selected_base))
		if not has_world_snapshot() or _source_db != source:
			return
		_dragging = true
		_drag_inside = true
		_drag_start = grid_pos
		_drag_current = grid_pos
		accept_event()
		if interaction_mode != &"select":
			queue_redraw()
			return
		var tile: ContinuumTile = tile_at(grid_pos)
		selected_tile_id = tile.id if tile != null else -1
		set_selected_rect(tile_footprint(tile) if tile != null else Rect2i(grid_pos, Vector2i.ONE))
		tile_selected.emit(selected_tile_id)
		has_world_snapshot()
		queue_redraw()


func layer_shortcuts_allowed() -> bool:
	if not is_visible_in_tree() or not is_processing_input():
		return false
	var focus := get_viewport().gui_get_focus_owner()
	if focus is LineEdit or focus is TextEdit or focus is SpinBox:
		return false
	return focus == self


func actor_groups(rows: Array) -> Dictionary:
	var groups := {}
	if not has_world_snapshot():
		return groups
	var region := Rect2(visible_grid_rect(LayeredTerrainView.CAMERA_PADDING))
	for row in rows:
		var id := int(LayeredTerrainModel.field(row, "id", -1))
		var position: Vector3 = _visual_feet[id] if _visual_feet.has(id) else LayeredTerrainModel.movement_position(row)
		if not region.intersects(Rect2(Vector2(position.x, position.y), Vector2.ONE)):
			continue
		if not terrain_model.position_visible(position, int(LayeredTerrainModel.field(row, "body_width", 1)), int(LayeredTerrainModel.field(row, "body_depth", 1))):
			continue
		var key := Vector3i(floori(position.x), floori(position.y), floori(position.z))
		if not groups.has(key):
			groups[key] = []
		groups[key].append(id)
	return groups


func _invalidate_terrain_entities() -> void:
	_visible_tiles_dirty = true
	_static_entity_buckets.clear()
	_static_entity_serial = 0
	_static_camera_dirty = true
	for tile: ContinuumTile in _facilities:
		if not row_visible(tile):
			continue
		_index_entity({"type": "facility", "rect": Rect2(tile_footprint(tile)), "z": tile.z,
			"kind": tile.kind.value, "enabled": tile.enabled})
	for stack: ContinuumItemStack in _stacks:
		if row_visible(stack) and stack.amount > 0:
			_index_entity({"type": "stack", "z": stack.z,
				"rect": Rect2(Vector2(stack.x + 0.05, stack.y + 0.65), Vector2(0.4, 0.33))})


func _index_entity(entity: Dictionary) -> void:
	entity["cache_id"] = _static_entity_serial
	_static_entity_serial += 1
	var rect: Rect2 = entity.rect
	for y in range(floori(rect.position.y / 16), ceili(rect.end.y / 16)):
		for x in range(floori(rect.position.x / 16), ceili(rect.end.x / 16)):
			var key := Vector2i(x, y)
			if not _static_entity_buckets.has(key):
				_static_entity_buckets[key] = []
			_static_entity_buckets[key].append(entity)


func entity_descriptors() -> Array:
	if not has_world_snapshot() or terrain_view.is_overview() or terrain_view.is_frame_suspended():
		return []
	var region := visible_grid_rect(LayeredTerrainView.CAMERA_PADDING)
	if _static_camera_dirty or region != _static_camera_region:
		_static_camera_region = region
		_static_camera_dirty = false
		_camera_static_entities = []
		var seen := {}
		for y in range(floori(region.position.y / 16.0), ceili(region.end.y / 16.0)):
			for x in range(floori(region.position.x / 16.0), ceili(region.end.x / 16.0)):
				for entity: Dictionary in _static_entity_buckets.get(Vector2i(x, y), []):
					if entity.rect.intersects(Rect2(region)) and not seen.has(entity.cache_id):
						seen[entity.cache_id] = true
						_camera_static_entities.append(entity)
	var entities := _camera_static_entities.duplicate()
	var colonists := _colonists
	var groups := actor_groups(colonists)
	for index in colonists.size():
		var colonist := colonists[index]
		var feet := _feet(colonist)
		var key := Vector3i(floori(feet.x), floori(feet.y), floori(feet.z))
		if not groups.has(key) or colonist.id not in groups[key]:
			continue
		var sharing: Array = groups[key]
		var centre := Vector2(feet.x, feet.y) + Vector2.ONE * 0.5
		if sharing.size() > 1:
			centre += Vector2.from_angle(TAU * sharing.find(colonist.id) / sharing.size()) * 0.15
		var sprite_size := 0.62 if sharing.size() > 1 else 0.82
		var frame := _walk_frame if colonist.move_progress > 0 else 0
		entities.append({"type": "colonist", "z": floori(feet.z), "rect": Rect2(centre - Vector2.ONE * sprite_size * 0.5, Vector2.ONE * sprite_size),
			"texture": COLONIST_WALK_TEXTURE, "source": Rect2(frame * COLONIST_WALK_FRAME_SIZE, 0, COLONIST_WALK_FRAME_SIZE, COLONIST_WALK_FRAME_SIZE),
			"id": colonist.id, "outline": metrics.scale / maxf(_cell_size(), 0.0001), "cargo": colonist.carried_amount > 0})
	return entities


func _draw_excavations(origin: Vector2, cell: float) -> void:
	var visible := visible_grid_rect()
	for region: Dictionary in _excavation_regions:
		if not region.bounds.intersects(visible):
			continue
		for run: Rect2i in region.runs:
			if not run.intersects(visible):
				continue
			var area := run.intersection(visible)
			var rect := Rect2(origin + Vector2(area.position) * cell, Vector2(area.size) * cell)
			MapPaint.hatch(self, rect, -origin, 6 * cell / ThemeTokens.number("tile"), MapPaint.translucent("map-plan", 0.24 if region.enabled else 0.12), metrics.scale)
		for edge: PackedVector2Array in region.edges:
			MapPaint.plan_edge(self, origin + edge[0] * cell, origin + edge[1] * cell, metrics.scale)
		var anchor := origin + Vector2(region.anchor) * cell + Vector2.ONE * 4 * metrics.scale
		var viewport := Rect2(Vector2.ZERO, size)
		if MapLabelLod.work(cell, metrics.scale, _region_focused(region)):
			MapPaint.plate(self, anchor, region.status, "", metrics.scale, true, region.plate_cache, viewport if viewport.has_point(anchor) else Rect2())


func _cache_excavations() -> void:
	_excavation_revision = terrain_model.revision
	_excavation_regions.clear()
	if not layered:
		return
	for designation in table_rows(_source_db, "excavation_designation"):
		var bottom := int(LayeredTerrainModel.field(designation, "bottom_z", 0))
		var height := int(LayeredTerrainModel.field(designation, "height", 6))
		var area := designation_rect(designation).intersection(grid_bounds())
		var footprints: Array = []
		for y in range(area.position.y, area.end.y):
			for x in range(area.position.x, area.end.x):
				var surface: Variant = terrain_model.surface_at(Vector2i(x, y))
				if surface != null and surface.z >= bottom and surface.z < bottom + height:
					footprints.append({"kind": 0, "z": surface.z, "rect": Rect2i(x, y, 1, 1)})
		for region: Dictionary in MapRegions.build(footprints):
			region["enabled"] = designation.enabled
			region["status"] = "EXCAVATION #%d · %s · %d/%d done" % [designation.id,
				str(PRIORITY_NAMES.get(designation.priority, "Unknown")).to_upper() if designation.enabled else "PAUSED",
				designation.completed_cells, designation.total_cells]
			region["plate_cache"] = {}
			_excavation_regions.append(region)


func set_selected_colonist(id: int) -> void:
	selected_colonist_id = id
	queue_redraw()


## Pins are supplied by the actual alert presenter, never inferred from needs.
## Contract: {cell: Vector3i, level: "warn"|"critical"|"notice"}.
func set_alert_pins(pins: Array[Dictionary]) -> void:
	_alert_pins.clear()
	for pin in pins:
		if pin.get("cell") is Vector3i and pin.get("level", "") in ["warn", "critical", "notice"]:
			_alert_pins.append(pin.duplicate())
	queue_redraw()


func _draw_actor_overlays(origin: Vector2, cell: float) -> void:
	_selected_actor_centre = null
	if selected_colonist_id >= 0:
		if layered:
			for entity: Dictionary in entity_descriptors():
				if entity.type == "colonist" and entity.id == selected_colonist_id:
					_draw_actor_ring(origin + entity.rect.get_center() * cell, entity.rect.size.x * cell * 0.6)
					_selected_actor_centre = origin + entity.rect.get_center() * cell
		else:
			for descriptor: Dictionary in _legacy_colonist_descriptors(origin, cell):
				if descriptor.colonist.id == selected_colonist_id:
					_draw_actor_ring(descriptor.rect.get_center(), cell * 0.5)
					_selected_actor_centre = descriptor.rect.get_center()
	for pin: Dictionary in _alert_pins:
		var position: Vector3i = pin.cell
		if layered and not terrain_model.entity_visible({"x": position.x, "y": position.y, "z": position.z}):
			continue
		var rect := Rect2(origin + Vector2(position.x + 0.5, position.y + 0.5) * cell - Vector2.ONE * 10 * metrics.scale, Vector2.ONE * 20 * metrics.scale)
		if not rect.intersects(Rect2(Vector2.ZERO, size)):
			continue
		draw_rect(rect, ThemeTokens.color("map-paper"))
		draw_rect(rect, ThemeTokens.color("map-ink"), false, metrics.scale)
		draw_texture_rect(ThemeTokens.glyph(pin.level), rect.grow(-2 * metrics.scale), false)


func _draw_actor_ring(centre: Vector2, radius: float) -> void:
	draw_arc(centre, radius, 0, TAU, 48, ThemeTokens.color("map-ink"), 4 * metrics.scale, true)
	draw_arc(centre, radius, 0, TAU, 48, ThemeTokens.color("accent"), 2 * metrics.scale, true)


## Goal/target are replicated intent, not an inferred route or a progress promise.
func colonist_intent(colonist: ContinuumColonist) -> String:
	if colonist.goal == null or colonist.goal.value == ContinuumGoal.Options.nothing:
		return "No current goal"
	var goal := ContinuumGoal.parse_enum_name(colonist.goal.value).capitalize()
	return "%s · destination (%d, %d, %d)" % [goal, colonist.target_x, colonist.target_y, colonist.target_z]


## A target marker obeys the same full-body exposure contract as the actor.
func destination_visible(colonist: ContinuumColonist) -> bool:
	if not has_world_snapshot() or colonist.goal == null or colonist.goal.value == ContinuumGoal.Options.nothing:
		return false
	var xy := Vector2i(colonist.target_x, colonist.target_y)
	if not visible_grid_rect().has_point(xy):
		return false
	return not layered or terrain_model.position_visible(Vector3(xy.x, xy.y, colonist.target_z), colonist.body_width, colonist.body_depth)


func _draw_actor_intent(centre: Vector2, cell: float) -> void:
	if not Rect2(Vector2.ZERO, size).has_point(centre):
		return
	var colonist: ContinuumColonist = _source_db.colonist.id.find(selected_colonist_id)
	if colonist == null:
		return
	var text := colonist_intent(colonist)
	if colonist.goal != null and colonist.goal.value != ContinuumGoal.Options.nothing:
		var target := Vector3i(colonist.target_x, colonist.target_y, colonist.target_z)
		if target == Vector3i(colonist.x, colonist.y, colonist.z):
			text += " · at destination"
		elif destination_visible(colonist):
			var rect := Rect2(world_to_screen(Vector2(target.x, target.y)), Vector2.ONE * cell).grow(-2 * metrics.scale)
			MapPaint.destination(self, rect, metrics.scale)
			MapPaint.plate(self, rect.position - Vector2(0, 26) * metrics.scale, "DESTINATION", "", metrics.scale, false, _destination_plate_cache, Rect2(Vector2.ZERO, size))
		else:
			text += " · outside view"
	var activity := ContinuumActivity.parse_enum_name(colonist.activity.value).capitalize() if colonist.activity != null else ""
	var at := centre + Vector2(cell * 0.6, -cell * 0.6)
	at.y = minf(at.y, size.y - 56 * metrics.scale)
	var header := MapPaint.plate(self, at, colonist.name + " · " + activity, "", metrics.scale, false, _actor_name_cache, Rect2(Vector2.ZERO, size))
	MapPaint.plate(self, header.position + Vector2(0, header.size.y), "", text, metrics.scale, false, _actor_plate_cache, Rect2(Vector2.ZERO, size))
