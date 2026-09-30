## Renders replicated terrain and actors. Selection and planning signals do not
## mutate server state; the controller owns reducer dispatch.
class_name ColonyMap
extends Control

signal tile_selected(tile_id: int)
signal rectangle_selected(rect: Rect2i)
signal build_rectangle_requested(rect: Rect2i)
signal excavation_requested(rect: Rect2i, bottom_z: int, height: int)
signal facility_requested(cell: Vector3i)
signal cut_changed(layer: int)
signal cell_selected(cell: Vector3i)
signal selection_invalidated
signal camera_changed

var terrain_model := LayeredTerrainModel.new()
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
var _zoom := 1.0 # relative to fit; readout uses native 32px cells
var _pan := Vector2.ZERO
var _panning := false
var _pan_pointer := Vector2.ZERO

const TILE_COLORS: Dictionary[int, Color] = {
	ContinuumTileKind.Options.empty: Color("2a2e37"),
	ContinuumTileKind.Options.dining: Color("3f9b52"),
	ContinuumTileKind.Options.sleep: Color("4a5bb5"),
	ContinuumTileKind.Options.farm: Color("b1802c"),
	ContinuumTileKind.Options.recreation: Color("9350b8"),
	ContinuumTileKind.Options.forest: Color("275b48"),
	ContinuumTileKind.Options.mine: Color("555c72"),
	ContinuumTileKind.Options.storage: Color("66543c"),
}

const RESOURCE_COLORS: Dictionary[int, Color] = {
	ContinuumResourceKind.Options.food: Color("f5d76e"),
	ContinuumResourceKind.Options.wood: Color("dda575"),
	ContinuumResourceKind.Options.stone: Color("a9c6e8"),
	ContinuumResourceKind.Options.meat: Color("f38b9c"),
}

const COLONIST_COLORS: Array[Color] = [
	Color("ff7043"), Color("26c6da"), Color("ffee58"),
	Color("ec407a"), Color("8bc34a"), Color("b39ddb"),
	Color("80cbc4"), Color("ffcc80"),
]
const COLONIST_WALK_TEXTURE: Texture2D = preload("res://assets/colonist_worker_test_walk.png")
const COLONIST_WALK_FRAME_COUNT := 4
const COLONIST_WALK_FRAME_MS := 140
const COLONIST_WALK_FRAME_SIZE := 32.0

const DISABLED_COLOR := Color("50202a")
const GRID_LINE_COLOR := Color(1, 1, 1, 0.06)
const SELECTION_COLOR := Color("e6b887")
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
var _stored_amounts: Dictionary[int, float] = {}
var _stock_pulses: Dictionary[int, float] = {}
var _walk_frame := 0
## Global drag tracking must never treat floating windows as map cells.
var input_blocked: Callable
var metrics := UiMetrics.new()


func _ready() -> void:
	metrics = UiMetrics.new()
	_font = ThemeDB.fallback_font
	texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	clip_contents = true
	set_process(true)
	set_process_input(true)
	mouse_default_cursor_shape = Control.CURSOR_CROSS
	focus_mode = Control.FOCUS_CLICK
	focus_exited.connect(cancel_gestures)
	terrain_view.attach(self)
	terrain_view.set_visible(false)
	resized.connect(_on_map_resized)


func _on_map_resized() -> void:
	cancel_gestures()
	_layout_terrain()
	if layered and has_world_snapshot():
		terrain_view.update_entities(entity_descriptors())


func _layout_terrain() -> void:
	has_world_snapshot()
	terrain_view.layout(_origin(), Vector2(_grid) * _cell_size())
	queue_redraw()
	camera_changed.emit()


func _fit_cell_size() -> float:
	return minf(size.x / maxi(1, _grid.x), size.y / maxi(1, _grid.y))


func screen_to_world(point: Vector2) -> Vector2:
	return (point - _origin()) / maxf(_cell_size(), 0.0001)


func world_to_screen(point: Vector2) -> Vector2:
	return _origin() + point * _cell_size()


func zoom_percent() -> float:
	return _cell_size() / LayeredTerrainView.PIXELS * 100.0


func zoom_at(factor: float, point: Vector2) -> void:
	if not has_world_snapshot() or factor <= 0 or _fit_cell_size() <= 0:
		return
	cancel_gestures()
	var world := screen_to_world(point)
	var minimum := minf(0.25, LayeredTerrainView.PIXELS / _fit_cell_size())
	_zoom = clampf(_zoom * factor, minimum, maxf(1.0, 128.0 / _fit_cell_size()))
	var centred := ((size - Vector2(_grid) * _cell_size()) * 0.5).floor()
	_pan = point - world * _cell_size() - centred
	_layout_terrain()
	if layered:
		terrain_view.update_entities(entity_descriptors())


func fit_camera() -> void:
	if not has_world_snapshot():
		return
	cancel_gestures()
	_zoom = 1.0
	_pan = Vector2.ZERO
	_layout_terrain()
	if layered:
		terrain_view.update_entities(entity_descriptors())


func reset_camera() -> void:
	fit_camera()
	if _fit_cell_size() > 0:
		zoom_at(LayeredTerrainView.PIXELS / _fit_cell_size(), size * 0.5)


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


func visible_grid_rect(padding := 0) -> Rect2i:
	if not has_world_snapshot():
		return Rect2i()
	var start := screen_to_world(Vector2.ZERO).floor()
	var end := screen_to_world(size).ceil()
	return Rect2i(Vector2i(start) - Vector2i.ONE * padding,
		Vector2i(end - start) + Vector2i.ONE * padding * 2).intersection(Rect2i(Vector2i.ZERO, _grid))


func set_cut(layer: int) -> void:
	if not has_world_snapshot() or not terrain_model.set_cut(layer):
		return
	cancel_gestures()
	selected_tile_id = -1
	_selection_rect = Rect2i()
	_frozen_selection = {}
	if layered:
		terrain_view.rebuild(terrain_model)
		_invalidate_terrain_entities()
		terrain_view.update_entities(entity_descriptors())
	cut_changed.emit(terrain_model.cut)
	queue_redraw()


func row_visible(row: Variant) -> bool:
	if not has_world_snapshot():
		return false
	if layered and row is ContinuumColonist:
		return terrain_model.position_visible(_feet(row), row.body_width, row.body_depth)
	return not layered or terrain_model.entity_visible(row)


func reset_world() -> void:
	_source_db = null
	terrain_model.reset()
	terrain_view.reset()
	_visual_feet.clear()
	_visual_motion.clear()
	_visual_positions.clear()
	_stored_amounts.clear()
	_stock_pulses.clear()
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
	selected_tile_id = -1
	_selection_rect = Rect2i()
	_frozen_selection = {}
	selection_invalidated.emit()


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
	var area := rect.intersection(Rect2i(Vector2i.ZERO, _grid))
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
	_selection_rect = rect
	_frozen_selection = terrain_model.capture_selection(rect) if layered else {}
	queue_redraw()


func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_WINDOW_FOCUS_OUT:
		cancel_gestures()


func selected_rect() -> Rect2i:
	if not has_world_snapshot():
		return Rect2i()
	if _dragging:
		return MapUiModel.normalize_rect(_drag_start, _drag_current)
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
	for kind: int in _stock_pulses.keys():
		_stock_pulses[kind] = maxf(0.0, _stock_pulses[kind] - delta)
		changed = changed or not layered
		if _stock_pulses[kind] <= 0.0:
			_stock_pulses.erase(kind)
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


## Called by [Main] after subscribed world rows change. Stock flashes show only
## replicated increases, never predicted production or inferred delivery amounts.
func refresh(changed_tables: Dictionary = {}) -> void:
	bind_world_source(SpacetimeDB.Continuum.db)
	if _source_db == null:
		return
	var full := changed_tables.is_empty() or not _has_state
	var config: ContinuumConfig = SpacetimeDB.Continuum.db.config.id.find(0)
	if config != null and config.generation != _generation:
		_generation = config.generation
		_visual_positions.clear()
		_stored_amounts.clear()
		_stock_pulses.clear()
		_visual_feet.clear()
		_visual_motion.clear()
		terrain_model.reset()
		clear_selection()
		cancel_gestures()
		_zoom = 1.0
		_pan = Vector2.ZERO
		full = true
	var colony: ContinuumColony = SpacetimeDB.Continuum.db.colony.id.find(0)
	if colony != null:
		for kind: int in RESOURCE_COLORS:
			var amount: float = colony.get(ContinuumResourceKind.parse_enum_name(kind))
			if _stored_amounts.has(kind) and amount > _stored_amounts[kind] + 0.001:
				_stock_pulses[kind] = 1.2
			_stored_amounts[kind] = amount
	if full or changed_tables.has("tile"):
		_cache_tiles()
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
		if full or changed_tables.has("world_geometry") or changed_tables.has("terrain_chunk") or changed_tables.has("terrain_material"):
			changed = terrain_model.sync(geometry_rows[0], table_rows(SpacetimeDB.Continuum.db, "terrain_chunk"),
				table_rows(SpacetimeDB.Continuum.db, "terrain_material"))
		_grid = Vector2i(terrain_model.width, terrain_model.height)
		_has_state = true
		_layout_terrain()
		if changed:
			terrain_view.rebuild(terrain_model)
			if not _frozen_selection.is_empty() and not terrain_model.selection_valid(_frozen_selection):
				clear_selection()
		if full or changed or changed_tables.has("tile") or changed_tables.has("item_stack"):
			_invalidate_terrain_entities()
	terrain_view.set_visible(layered)
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
	return ((size - used) * 0.5).floor() + _pan


func _draw() -> void:
	var ready := has_world_snapshot()
	var cell := _cell_size()
	if cell <= 0.0:
		return
	var origin := _origin()

	if not layered:
		draw_rect(Rect2(origin, Vector2(cell * _grid.x, cell * _grid.y)), Color("1a1d23"))

	if not ready:
		draw_string(_font, origin + Vector2(0.0, size.y * 0.5), "waiting for colony state...",
				HORIZONTAL_ALIGNMENT_CENTER, size.x, metrics.font(14), Color(1, 1, 1, 0.5))
		return

	if layered:
		var selected: ContinuumTile = SpacetimeDB.Continuum.db.tile.id.find(selected_tile_id)
		if selected != null and row_visible(selected):
			var selection := tile_footprint(selected)
			draw_rect(Rect2(origin + Vector2(selection.position) * cell, Vector2(selection.size) * cell).grow(-1), SELECTION_COLOR, false, 2)
	for tile: ContinuumTile in ([] if layered else visible_tiles()):
		var footprint := Vector2(LayeredTerrainModel.field(tile, "width", 1), LayeredTerrainModel.field(tile, "depth", 1))
		var rect := Rect2(origin + Vector2(tile.x * cell, tile.y * cell), footprint * cell)
		if not rect.intersects(Rect2(Vector2.ZERO, size)):
			continue
		var colour: Color = TILE_COLORS.get(tile.kind.value, Color("2a2e37"))
		var terrain: Resource = SpacetimeDB.Continuum.db.terrain.tile_id.find(tile.id)
		if tile.kind.value == ContinuumTileKind.Options.empty:
			colour = _soil_colour(terrain)
		if not tile.enabled:
			colour = colour.lerp(DISABLED_COLOR, 0.75)
		draw_rect(rect.grow(-1.0), colour)

		if not tile.enabled and tile.kind.value != ContinuumTileKind.Options.empty:
			var pad := cell * 0.28
			var a := rect.position + Vector2(pad, pad)
			var b := rect.position + Vector2(cell - pad, cell - pad)
			var width := maxf(1.0, cell * 0.07)
			draw_line(a, b, Color("ff5c6c"), width)
			draw_line(Vector2(a.x, b.y), Vector2(b.x, a.y), Color("ff5c6c"), width)

		if tile.id == selected_tile_id:
			draw_rect(rect.grow(-1.0), SELECTION_COLOR, false, 2.0)
		if terrain != null and terrain.forest_density > 0.45:
			_draw_cover(rect, cell, terrain.forest_density)

	var visible := visible_grid_rect()
	for i in (range(visible.position.x, visible.end.x + 1) if cell >= 6 else []):
		var x: float = origin.x + i * cell
		draw_line(Vector2(x, maxf(0, origin.y)), Vector2(x, minf(size.y, origin.y + cell * _grid.y)), GRID_LINE_COLOR)
	for i in (range(visible.position.y, visible.end.y + 1) if cell >= 6 else []):
		var y: float = origin.y + i * cell
		draw_line(Vector2(maxf(0, origin.x), y), Vector2(minf(size.x, origin.x + cell * _grid.x), y), GRID_LINE_COLOR)

	if not layered:
		_draw_zone_labels(origin, cell)
		_draw_work_orders(origin, cell)
		_draw_delivery_routes(origin, cell)
		_draw_storage(origin, cell)
		_draw_colonists(origin, cell)
		_draw_ground_items(origin, cell)
	_draw_excavations(origin, cell)
	if _selection_rect.size != Vector2i.ZERO and not _dragging:
		var selection_rect := Rect2(origin + Vector2(_selection_rect.position) * cell,
			Vector2(_selection_rect.size) * cell)
		draw_rect(selection_rect.grow(-1.0), Color("64d8cb"), false, 2.0)
	_draw_drag_preview(origin, cell)


func _soil_colour(terrain: Resource) -> Color:
	if terrain == null:
		return Color("2a2e37")
	# Continuous interpolation keeps fertile, wet forest ground visibly distinct.
	var sandy := Color("b99862")
	var loamy := Color("78664f")
	var chernozem := Color("403f36")
	var fertility: float = clampf(terrain.soil_fertility, 0.0, 1.0)
	var moisture: float = clampf(terrain.moisture, 0.0, 1.0)
	var soil := sandy.lerp(loamy, fertility)
	soil = soil.lerp(chernozem, fertility * moisture)
	return soil


func _draw_cover(rect: Rect2, cell: float, density: float) -> void:
	var alpha := clampf((density - 0.45) * 0.9, 0.08, 0.5)
	var cover := Color("4d8b52", alpha)
	if density > 0.72:
		cover = Color("1d5138", alpha)
	var radius := maxf(1.0, cell * 0.12)
	draw_circle(rect.position + Vector2(cell * 0.28, cell * 0.3), radius, cover)
	draw_circle(rect.position + Vector2(cell * 0.68, cell * 0.64), radius * 0.8, cover)


func _draw_drag_preview(origin: Vector2, cell: float) -> void:
	if not _dragging:
		return
	var rect := MapUiModel.normalize_rect(_drag_start, _drag_current)
	if interaction_mode == &"facility":
		rect = Rect2i(_drag_start, Vector2i(facility_width, facility_depth))
	var colour := Color("d39a68") if interaction_mode == &"select" else Color("d8b06e")
	if interaction_mode == &"facility" and layered and (terrain_model.uniform_base(rect) != selected_base \
		or not terrain_model.placement_clear(rect, selected_base, facility_height)):
		colour = Color("ff5c6c")
	colour.a = 0.22
	draw_rect(Rect2(origin + Vector2(rect.position) * cell, Vector2(rect.size) * cell), colour)
	draw_rect(Rect2(origin + Vector2(rect.position) * cell, Vector2(rect.size) * cell), colour.lightened(0.3), false, 2.0)
	var occupied := 0
	for tile: ContinuumTile in facility_tiles():
		if rect.intersects(tile_footprint(tile)) and tile.kind.value != ContinuumTileKind.Options.empty:
			occupied += 1
	var text := "%dx%d  %d cells" % [rect.size.x, rect.size.y, rect.size.x * rect.size.y]
	if interaction_mode == &"build":
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
	draw_string(_font, origin + Vector2(rect.position.x * cell + 4.0, rect.position.y * cell - 5.0),
			text, HORIZONTAL_ALIGNMENT_LEFT, -1, metrics.font(clampf(cell * 0.34, 10, 15)), Color("f1f4f8"))


## One label per zone, at the zone's top-left tile, so the map reads without a legend.
func _draw_zone_labels(origin: Vector2, cell: float) -> void:
	var font_size := int(maxf(9.0, cell * 0.32))
	for kind: int in TILE_COLORS.keys():
		if kind in [ContinuumTileKind.Options.empty, ContinuumTileKind.Options.storage]:
			continue
		var zone: Array[ContinuumTile] = []
		for tile: ContinuumTile in visible_tiles():
			if tile.kind.value == kind:
				zone.append(tile)
		if zone.is_empty():
			continue
		var anchor := Vector2i(9999, 9999)
		for tile: ContinuumTile in zone:
			if tile.y < anchor.y or (tile.y == anchor.y and tile.x < anchor.x):
				anchor = Vector2i(tile.x, tile.y)
		draw_string(_font,
				origin + Vector2(anchor.x * cell + 3.0, anchor.y * cell + font_size + 2.0),
				ContinuumTileKind.parse_enum_name(kind).capitalize(), HORIZONTAL_ALIGNMENT_LEFT, -1,
				metrics.font(font_size), Color(1, 1, 1, 0.85))


func _draw_work_orders(origin: Vector2, cell: float) -> void:
	for order: ContinuumWorkOrder in SpacetimeDB.Continuum.db.work_order.iter():
		var tile: ContinuumTile = SpacetimeDB.Continuum.db.tile.id.find(order.tile_id)
		if tile == null or not row_visible(tile) or not tile.enabled or not order.enabled:
			continue
		var column := 0.5 if order.work.value == ContinuumWorkType.Options.hunting else 0.0
		var rect := Rect2(origin + Vector2(tile.x + column, tile.y) * cell,
			Vector2(cell * 0.5, maxf(10.0, cell * 0.3)))
		var text := "%s%d" % [ContinuumWorkType.parse_enum_name(order.work.value).left(1).to_upper(), order.priority]
		draw_rect(rect, Color("151920"))
		draw_string(_font, rect.position + Vector2(1, rect.size.y - 1), text,
				HORIZONTAL_ALIGNMENT_LEFT, rect.size.x, metrics.font(clampf(cell * 0.27, 8, 11)), Color("f5d76e"))


static func format_amount(amount: float) -> String:
	if amount >= 1000000.0:
		return "%.1fm" % (amount / 1000000.0)
	if amount >= 1000.0:
		return "%.1fk" % (amount / 1000.0)
	return "%.1f" % amount if amount < 10.0 else "%.0f" % amount


func _draw_ground_items(origin: Vector2, cell: float) -> void:
	for stack: ContinuumItemStack in SpacetimeDB.Continuum.db.item_stack.iter():
		if not row_visible(stack):
			continue
		if stack.amount <= 0.0:
			continue
		var column := 0.56 if stack.kind.value == ContinuumResourceKind.Options.meat else 0.04
		var rect := Rect2(origin + Vector2(stack.x + column, stack.y + 0.65) * cell,
				Vector2(cell * 0.40, cell * 0.33))
		var colour: Color = RESOURCE_COLORS[stack.kind.value]
		draw_rect(rect, Color("151920"))
		draw_rect(rect, colour, false, 2.0)
		var text := ContinuumResourceKind.parse_enum_name(stack.kind.value).left(1).to_upper()
		var font_size := metrics.font(clampf(cell * 0.30, 8, 12))
		draw_string(_font, rect.position + Vector2(metrics.px(1), rect.size.y * 0.5 + font_size * 0.35),
				text, HORIZONTAL_ALIGNMENT_CENTER, rect.size.x - metrics.px(2), font_size, colour)


func _draw_delivery_routes(origin: Vector2, cell: float) -> void:
	for colonist: ContinuumColonist in SpacetimeDB.Continuum.db.colonist.iter():
		if not row_visible(colonist):
			continue
		if colonist.carried_amount <= 0.0 or colonist.goal.value != ContinuumGoal.Options.haul:
			continue
		if colonist.activity.value not in [ContinuumActivity.Options.travelling, ContinuumActivity.Options.hauling]:
			continue
		if layered and not terrain_model.entity_visible({"x": colonist.target_x, "y": colonist.target_y,
			"z": LayeredTerrainModel.field(colonist, "target_z", 0)}):
			continue
		var start: Vector2 = origin + (_visual_positions.get(colonist.id,
				Vector2(colonist.x, colonist.y)) + Vector2(0.5, 0.5)) * cell
		var end := origin + Vector2(colonist.target_x + 0.5, colonist.target_y + 0.5) * cell
		var colour: Color = RESOURCE_COLORS[colonist.carried_kind.value]
		colour.a = 0.55
		# A destination guide, not a predicted simulation path.
		draw_dashed_line(start, end, colour, 1.5, 5.0)
		if start.distance_to(end) > cell:
			var direction := (end - start).normalized()
			var wing := direction.orthogonal() * 4.0
			draw_line(end, end - direction * 9.0 + wing, colour, 2.0)
			draw_line(end, end - direction * 9.0 - wing, colour, 2.0)


func _draw_storage(origin: Vector2, cell: float) -> void:
	var colony: ContinuumColony = SpacetimeDB.Continuum.db.colony.id.find(0)
	if colony == null:
		return
	var anchor := Vector2i(9999, 9999)
	var storage_open := false
	for tile: ContinuumTile in visible_tiles():
		if tile.kind.value == ContinuumTileKind.Options.storage:
			storage_open = storage_open or tile.enabled
			if tile.y < anchor.y or (tile.y == anchor.y and tile.x < anchor.x):
				anchor = Vector2i(tile.x, tile.y)
	if anchor.x == 9999:
		return
	var font_size := clampi(int(cell * 0.36), 10, 13)
	var line_height := float(font_size + 5)
	var rect := Rect2(origin + Vector2(anchor) * cell + Vector2(3, 3),
			Vector2(cell * 4.0 - 6.0, line_height * 5.0 + 6.0))
	draw_rect(rect, Color("171d26"))
	draw_rect(rect, Color("a38a60") if storage_open else DISABLED_COLOR, false, 1.0)
	var at := rect.position + Vector2(5, line_height)
	draw_string(_font, at, "STORED / SHARED" if storage_open else "STORED / CLOSED",
			HORIZONTAL_ALIGNMENT_LEFT, rect.size.x - metrics.px(10), metrics.font(font_size - 1), Color("ddd4c0"))
	for kind: int in RESOURCE_COLORS:
		at.y += line_height
		var colour: Color = RESOURCE_COLORS[kind]
		var key := ContinuumResourceKind.parse_enum_name(kind)
		if _stock_pulses.has(kind):
			var glow := colour
			glow.a = _stock_pulses[kind] / 1.2 * 0.3
			draw_rect(Rect2(Vector2(rect.position.x + 2, at.y - font_size - 2),
					Vector2(rect.size.x - 4, line_height)), glow)
		draw_string(_font, at, "%s %s" % [key.capitalize(), format_amount(colony.get(key))],
				HORIZONTAL_ALIGNMENT_LEFT, rect.size.x - metrics.px(10), metrics.font(font_size), colour)


func _draw_colonists(origin: Vector2, cell: float) -> void:
	var colonists: Array[ContinuumColonist] = SpacetimeDB.Continuum.db.colonist.iter()
	colonists.sort_custom(func(a: ContinuumColonist, b: ContinuumColonist) -> bool:
		return a.id < b.id)
	var occupants: Dictionary[Vector2i, Array] = {}
	for colonist: ContinuumColonist in colonists:
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
		var colour: Color = COLONIST_COLORS[index % COLONIST_COLORS.size()]
		var sprite_size := cell * (0.62 if sharing.size() > 1 else 0.82)
		var radius := sprite_size * 0.36

		draw_circle(centre, radius + 2.0, Color(0, 0, 0, 0.55))
		draw_circle(centre, radius, colour)
		var walking := colonist.x != colonist.target_x \
				or colonist.y != colonist.target_y \
				or colonist.move_progress > 0.001
		var frame := _walk_frame if walking else 0
		var sprite_rect := Rect2(centre - Vector2.ONE * sprite_size * 0.5,
				Vector2.ONE * sprite_size)
		var source_rect := Rect2(frame * COLONIST_WALK_FRAME_SIZE, 0.0,
				COLONIST_WALK_FRAME_SIZE, COLONIST_WALK_FRAME_SIZE)
		draw_texture_rect_region(COLONIST_WALK_TEXTURE, sprite_rect, source_rect)

		if colonist.carried_amount > 0.0:
			var cargo_colour: Color = RESOURCE_COLORS[colonist.carried_kind.value]
			var cargo_rect := Rect2(centre + Vector2(radius * 0.6, -radius - cell * 0.2),
					Vector2(cell * 0.95, maxf(13.0, cell * 0.4)))
			draw_line(centre, cargo_rect.get_center(), cargo_colour, 2.0)
			draw_rect(cargo_rect, Color("151920"))
			draw_rect(cargo_rect, cargo_colour, false, 2.0)
			var cargo_text := "%s %s" % [
				ContinuumResourceKind.parse_enum_name(colonist.carried_kind.value).left(1).to_upper(),
				format_amount(colonist.carried_amount),
			]
			draw_string(_font, cargo_rect.position + Vector2(1, cargo_rect.size.y * 0.5 + metrics.px(3)), cargo_text,
					HORIZONTAL_ALIGNMENT_CENTER, cargo_rect.size.x - metrics.px(2), metrics.font(clampf(cell * 0.3, 8, 12)), cargo_colour)

		var small := int(maxf(8.0, cell * 0.26))
		var caption := "%s: %s" % [colonist.name,
			ContinuumActivity.parse_enum_name(colonist.activity.value).capitalize()]
		var caption_at := centre + Vector2(-cell * 1.1, radius + small + 1.0)
		draw_string_outline(_font, caption_at, caption, HORIZONTAL_ALIGNMENT_CENTER,
				cell * 2.2, metrics.font(small), metrics.px(3), Color("151920"))
		draw_string(_font, caption_at, caption, HORIZONTAL_ALIGNMENT_CENTER,
				cell * 2.2, metrics.font(small), Color("f1f4f8"))


func _get_tooltip(at_position: Vector2) -> String:
	if not has_world_snapshot() or _cell_size() <= 0.0:
		return ""
	if not Rect2(Vector2.ZERO, size).has_point(at_position):
		return ""
	var local := screen_to_world(at_position)
	var db: ContinuumModuleDb = _source_db
	var grid_pos := Vector2i(floori(local.x), floori(local.y))
	var lines := PackedStringArray()
	if layered:
		var surface: Variant = terrain_model.surface_at(grid_pos)
		if surface == null:
			return "No known surface at (%d, %d), cut z=%d" % [grid_pos.x, grid_pos.y, terrain_model.cut]
		var material_id := terrain_model.material_at(surface)
		lines.append("%s material #%d at (%d, %d, %d) | depth %d (%.1fm) | base z=%d" % [
			LayeredTerrainModel.field(terrain_model.materials.get(material_id), "name", "unknown"), material_id,
			surface.x, surface.y, surface.z, terrain_model.depth_at(grid_pos), terrain_model.depth_at(grid_pos) * 0.5,
			terrain_model.base_at(grid_pos)])
	var tile := tile_at(grid_pos)
	if tile != null:
		lines.append("%s (%d, %d) / %s" % [
			ContinuumTileKind.parse_enum_name(tile.kind.value).capitalize(), tile.x, tile.y,
			"enabled" if tile.enabled else "disabled"])
		var terrain: Resource = db.terrain.tile_id.find(tile.id)
		if terrain != null:
			lines.append("Soil: %s  fertility %.2f  moisture %.2f" % [
				_soil_name(terrain.soil_fertility, terrain.moisture), terrain.soil_fertility, terrain.moisture])
			lines.append("Cover: %s  density %.2f (decorative)" % [
				_cover_name(terrain.forest_density), terrain.forest_density])
		for work: int in compatible_work(tile.kind.value):
			var description := "no order (no production)"
			for order: ContinuumWorkOrder in db.work_order.iter():
				if order.tile_id == tile.id and order.work.value == work:
					description = "#%d: %s / %s" % [order.id, "enabled" if order.enabled else "paused",
						PRIORITY_NAMES.get(order.priority, "Unknown")]
					break
			lines.append("%s order: %s" % [ContinuumWorkType.parse_enum_name(work).capitalize(), description])
		if not compatible_work(tile.kind.value).is_empty():
			lines.append("Priority ranks sites within the profession. Old goods remain haulable.")
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
	var grid_rect := Rect2(_origin(), Vector2(cell * _grid.x, cell * _grid.y))
	if not grid_rect.has_point(position):
		return null
	var local := screen_to_world(position)
	var grid_pos := Vector2i(floori(local.x), floori(local.y))
	if grid_pos.x < 0 or grid_pos.y < 0 or grid_pos.x >= _grid.x or grid_pos.y >= _grid.y:
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
		return
	if event is InputEventKey and event.pressed and event.keycode == KEY_ESCAPE:
		cancel_gestures()
		return
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_RIGHT and event.pressed:
		cancel_gestures()
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
		return
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
		var grid_pos: Variant = _cell_at(point)
		if grid_pos == null:
			return
		grab_focus()
		var base: Variant = terrain_model.base_at(grid_pos) if layered else 0
		if base == null:
			return
		selected_base = int(base)
		_drag_layer = terrain_model.cut
		var source := _source_db
		cell_selected.emit(terrain_model.surface_at(grid_pos) if layered else Vector3i(grid_pos.x, grid_pos.y, 0))
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
		selected_tile_id = -1
		if tile != null:
			selected_tile_id = tile.id
			tile_selected.emit(tile.id)
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
		var colour: Color = TILE_COLORS.get(tile.kind.value, Color("737d8b"))
		if not tile.enabled:
			colour = colour.lerp(DISABLED_COLOR, 0.75)
		_index_entity({"type": "facility", "rect": Rect2(tile_footprint(tile)), "z": tile.z,
			"colour": colour, "enabled": tile.enabled, "label": ContinuumTileKind.parse_enum_name(tile.kind.value).capitalize()})
	for stack: ContinuumItemStack in _stacks:
		if row_visible(stack) and stack.amount > 0:
			_index_entity({"type": "stack", "z": stack.z, "colour": RESOURCE_COLORS[stack.kind.value],
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
	if not has_world_snapshot():
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
			"colour": COLONIST_COLORS[index % COLONIST_COLORS.size()], "cargo": colonist.carried_amount > 0,
			"cargo_colour": RESOURCE_COLORS.get(colonist.carried_kind.value, Color.WHITE)})
	return entities


func _draw_excavations(origin: Vector2, cell: float) -> void:
	if not layered:
		return
	for designation in table_rows(SpacetimeDB.Continuum.db, "excavation_designation"):
		var bottom := int(LayeredTerrainModel.field(designation, "bottom_z", 0))
		var height := int(LayeredTerrainModel.field(designation, "height", 6))
		var area := designation_rect(designation).intersection(visible_grid_rect())
		for y in range(area.position.y, area.end.y):
			for x in range(area.position.x, area.end.x):
				var surface: Variant = terrain_model.surface_at(Vector2i(x, y))
				if surface == null or surface.z < bottom or surface.z >= bottom + height:
					continue
				var rect := Rect2(origin + Vector2(x, y) * cell, Vector2.ONE * cell)
				var colour := Color("ffc35a") if designation.enabled else Color("b57878")
				draw_rect(rect.grow(-2), colour, false, 2)
				draw_line(rect.position + Vector2.ONE * 4, rect.end - Vector2.ONE * 4, colour, 1)
