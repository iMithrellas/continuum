## Draws the abstract colony grid and the sprite-backed colonist markers.
##
## Purely a view: it reads typed rows out of the generated `SpacetimeDB.Continuum`
## bindings and never mutates anything. Clicking a tile only emits
## [signal tile_selected]; it is [Main] that turns that into a reducer call.
class_name ColonyMap
extends Control

signal tile_selected(tile_id: int)
signal rectangle_selected(rect: Rect2i)
signal build_rectangle_requested(rect: Rect2i)

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

## Rendered colonist positions, eased towards the authoritative tile/progress
## positions so movement reads as movement instead of teleporting.
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
	set_process(true)
	set_process_input(true)
	mouse_default_cursor_shape = Control.CURSOR_CROSS


func set_interaction_mode(mode: StringName) -> void:
	interaction_mode = mode
	_dragging = false
	queue_redraw()


func set_build_kind(kind: int) -> void:
	build_kind = kind
	queue_redraw()


func set_selected_rect(rect: Rect2i) -> void:
	_selection_rect = rect
	queue_redraw()


func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_WINDOW_FOCUS_OUT:
		_dragging = false
		_drag_inside = false
		queue_redraw()


func selected_rect() -> Rect2i:
	if _dragging:
		return MapUiModel.normalize_rect(_drag_start, _drag_current)
	if selected_tile_id < 0:
		return Rect2i()
	var tile: ContinuumTile = SpacetimeDB.Continuum.db.tile.id.find(selected_tile_id)
	return Rect2i(Vector2i(tile.x, tile.y), Vector2i.ONE) if tile != null else Rect2i()


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
	if not _has_state or SpacetimeDB.Continuum.db == null:
		return
	var changed: bool = false
	var animation_frame := int(Time.get_ticks_msec() / float(COLONIST_WALK_FRAME_MS)) % COLONIST_WALK_FRAME_COUNT
	if animation_frame != _walk_frame:
		_walk_frame = animation_frame
		changed = true
	for kind: int in _stock_pulses.keys():
		_stock_pulses[kind] = maxf(0.0, _stock_pulses[kind] - delta)
		changed = true
		if _stock_pulses[kind] <= 0.0:
			_stock_pulses.erase(kind)
	for colonist: ContinuumColonist in SpacetimeDB.Continuum.db.colonist.iter():
		var target := _colonist_render_position(colonist)
		if not _visual_positions.has(colonist.id):
			_visual_positions[colonist.id] = target
			changed = true
			continue
		var current: Vector2 = _visual_positions[colonist.id]
		if current.distance_to(target) > 0.001:
			# High simulation speeds can advance several tiles per server tick;
			# always ease the correction instead of visually teleporting.
			_visual_positions[colonist.id] = current.lerp(target, clampf(delta * 8.0, 0.0, 1.0))
			changed = true
	if changed:
		queue_redraw()


func _colonist_render_position(colonist: ContinuumColonist) -> Vector2:
	var position := Vector2(colonist.x, colonist.y)
	var progress := clampf(colonist.move_progress, 0.0, 1.0)
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
func refresh() -> void:
	var config: ContinuumConfig = SpacetimeDB.Continuum.db.config.id.find(0)
	if config != null and config.generation != _generation:
		_generation = config.generation
		_visual_positions.clear()
		_stored_amounts.clear()
		_stock_pulses.clear()
	var colony: ContinuumColony = SpacetimeDB.Continuum.db.colony.id.find(0)
	if colony != null:
		for kind: int in RESOURCE_COLORS:
			var amount: float = colony.get(ContinuumResourceKind.parse_enum_name(kind))
			if _stored_amounts.has(kind) and amount > _stored_amounts[kind] + 0.001:
				_stock_pulses[kind] = 1.2
			_stored_amounts[kind] = amount
	var tiles: Array[ContinuumTile] = SpacetimeDB.Continuum.db.tile.iter()
	_has_state = not tiles.is_empty()
	if _has_state:
		var extent := Vector2i.ZERO
		for tile: ContinuumTile in tiles:
			extent.x = maxi(extent.x, tile.x + 1)
			extent.y = maxi(extent.y, tile.y + 1)
		_grid = extent
	queue_redraw()


func _cell_size() -> float:
	return minf(size.x / float(_grid.x), size.y / float(_grid.y))


func _origin() -> Vector2:
	var cell := _cell_size()
	var used := Vector2(cell * _grid.x, cell * _grid.y)
	return ((size - used) * 0.5).floor()


func _draw() -> void:
	var cell := _cell_size()
	if cell <= 0.0:
		return
	var origin := _origin()

	draw_rect(Rect2(origin, Vector2(cell * _grid.x, cell * _grid.y)), Color("1a1d23"))

	if not _has_state or SpacetimeDB.Continuum.db == null:
		draw_string(_font, origin + Vector2(0.0, size.y * 0.5), "waiting for colony state...",
				HORIZONTAL_ALIGNMENT_CENTER, size.x, metrics.font(14), Color(1, 1, 1, 0.5))
		return

	for tile: ContinuumTile in SpacetimeDB.Continuum.db.tile.iter():
		var rect := Rect2(origin + Vector2(tile.x * cell, tile.y * cell), Vector2(cell, cell))
		var colour: Color = TILE_COLORS.get(tile.kind.value, Color("2a2e37"))
		var terrain: Resource = SpacetimeDB.Continuum.db.terrain.tile_id.find(tile.id)
		if tile.kind.value == ContinuumTileKind.Options.empty:
			colour = _soil_colour(terrain)
		if not tile.enabled:
			colour = colour.lerp(DISABLED_COLOR, 0.75)
		draw_rect(rect.grow(-1.0), colour)

		if not tile.enabled and tile.kind.value != ContinuumTileKind.Options.empty:
			# A clear "this is switched off" marker, not just a dimmer colour.
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

	for i in range(_grid.x + 1):
		var x := origin.x + i * cell
		draw_line(Vector2(x, origin.y), Vector2(x, origin.y + cell * _grid.y), GRID_LINE_COLOR)
	for i in range(_grid.y + 1):
		var y := origin.y + i * cell
		draw_line(Vector2(origin.x, y), Vector2(origin.x + cell * _grid.x, y), GRID_LINE_COLOR)

	_draw_zone_labels(origin, cell)
	_draw_work_orders(origin, cell)
	_draw_delivery_routes(origin, cell)
	_draw_storage(origin, cell)
	_draw_colonists(origin, cell)
	_draw_ground_items(origin, cell)
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
	var colour := Color("d39a68") if interaction_mode == &"select" else Color("d8b06e")
	colour.a = 0.22
	draw_rect(Rect2(origin + Vector2(rect.position) * cell, Vector2(rect.size) * cell), colour)
	draw_rect(Rect2(origin + Vector2(rect.position) * cell, Vector2(rect.size) * cell), colour.lightened(0.3), false, 2.0)
	var occupied := 0
	for tile: ContinuumTile in SpacetimeDB.Continuum.db.tile.iter():
		if rect.has_point(Vector2i(tile.x, tile.y)) and tile.kind.value != ContinuumTileKind.Options.empty:
			occupied += 1
	var text := "%dx%d  %d cells" % [rect.size.x, rect.size.y, rect.size.x * rect.size.y]
	if interaction_mode == &"build":
		text += "  %.0f wood" % (rect.size.x * rect.size.y * 20.0)
		if occupied > 0:
			text += "  OCCUPIED"
		var colony: ContinuumColony = SpacetimeDB.Continuum.db.colony.id.find(0)
		if colony == null or colony.wood < rect.size.x * rect.size.y * 20.0:
			text += "  NOT ENOUGH WOOD"
	draw_string(_font, origin + Vector2(rect.position.x * cell + 4.0, rect.position.y * cell - 5.0),
			text, HORIZONTAL_ALIGNMENT_LEFT, -1, metrics.font(clampf(cell * 0.34, 10, 15)), Color("f1f4f8"))


## One label per zone, at the zone's top-left tile, so the map reads without a legend.
func _draw_zone_labels(origin: Vector2, cell: float) -> void:
	var font_size := int(maxf(9.0, cell * 0.32))
	for kind: int in TILE_COLORS.keys():
		if kind in [ContinuumTileKind.Options.empty, ContinuumTileKind.Options.storage]:
			continue
		var zone: Array[ContinuumTile] = []
		for tile: ContinuumTile in SpacetimeDB.Continuum.db.tile.iter():
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
		if tile == null or not tile.enabled or not order.enabled:
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
		if stack.amount <= 0.0:
			continue
		# Ground crates stay at the tile's feet, visible even under a working colonist.
		# Forest tiles can have both wood (left) and meat (right).
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
		if colonist.carried_amount <= 0.0 or colonist.goal.value != ContinuumGoal.Options.haul:
			continue
		if colonist.activity.value not in [ContinuumActivity.Options.travelling, ContinuumActivity.Options.hauling]:
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
	for tile: ContinuumTile in SpacetimeDB.Continuum.db.tile.iter():
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
	if not _has_state or _cell_size() <= 0.0:
		return ""
	var local := (at_position - _origin()) / _cell_size()
	var grid_pos := Vector2i(floori(local.x), floori(local.y))
	var lines := PackedStringArray()
	for tile: ContinuumTile in SpacetimeDB.Continuum.db.tile.iter():
		if Vector2i(tile.x, tile.y) == grid_pos:
			lines.append("%s (%d, %d) / %s" % [
				ContinuumTileKind.parse_enum_name(tile.kind.value).capitalize(), tile.x, tile.y,
				"enabled" if tile.enabled else "disabled"])
			var terrain: Resource = SpacetimeDB.Continuum.db.terrain.tile_id.find(tile.id)
			if terrain != null:
				lines.append("Soil: %s  fertility %.2f  moisture %.2f" % [
					_soil_name(terrain.soil_fertility, terrain.moisture), terrain.soil_fertility, terrain.moisture])
				lines.append("Cover: %s  density %.2f (decorative)" % [
					_cover_name(terrain.forest_density), terrain.forest_density])
			for work: int in compatible_work(tile.kind.value):
				var description := "no order (no production)"
				for order: ContinuumWorkOrder in SpacetimeDB.Continuum.db.work_order.iter():
					if order.tile_id == tile.id and order.work.value == work:
						description = "#%d: %s / %s" % [order.id, "enabled" if order.enabled else "paused",
							PRIORITY_NAMES.get(order.priority, "Unknown")]
						break
				lines.append("%s order: %s" % [ContinuumWorkType.parse_enum_name(work).capitalize(), description])
			if not compatible_work(tile.kind.value).is_empty():
				lines.append("Priority ranks sites within the profession. Old goods remain haulable.")
			break
	for stack: ContinuumItemStack in SpacetimeDB.Continuum.db.item_stack.iter():
		if Vector2i(stack.x, stack.y) == grid_pos:
			lines.append("Ground: %.1f %s" % [stack.amount,
				ContinuumResourceKind.parse_enum_name(stack.kind.value)])
	for colonist: ContinuumColonist in SpacetimeDB.Continuum.db.colonist.iter():
		if Vector2i(colonist.x, colonist.y) == grid_pos:
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
	var cell := _cell_size()
	if cell <= 0.0:
		return null
	var grid_rect := Rect2(_origin(), Vector2(cell * _grid.x, cell * _grid.y))
	if not grid_rect.has_point(position):
		return null
	var local := (position - _origin()) / cell
	var grid_pos := Vector2i(floori(local.x), floori(local.y))
	if grid_pos.x < 0 or grid_pos.y < 0 or grid_pos.x >= _grid.x or grid_pos.y >= _grid.y:
		return null
	return grid_pos


func _input(event: InputEvent) -> void:
	if not _has_state:
		return
	if event is InputEventMouse and input_blocked.is_valid() and input_blocked.call(event.position):
		_dragging = false
		_drag_inside = false
		queue_redraw()
		return
	if event is InputEventKey and event.pressed and event.keycode == KEY_ESCAPE:
		_dragging = false
		queue_redraw()
		return
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_RIGHT and event.pressed:
		# Right-click is a global cancel while painting, including the side panel.
		_dragging = false
		_drag_inside = false
		queue_redraw()
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
		if interaction_mode == &"build":
			build_rectangle_requested.emit(rect)
		else:
			rectangle_selected.emit(rect)
		queue_redraw()
		return


func _gui_input(event: InputEvent) -> void:
	if not _has_state:
		return
	if event is InputEventMouseButton and event.pressed \
			and event.button_index == MOUSE_BUTTON_LEFT:
		var point := (event as InputEventMouseButton).position
		var grid_pos: Variant = _cell_at(point)
		if grid_pos == null:
			return
		_dragging = true
		_drag_inside = true
		_drag_start = grid_pos
		_drag_current = grid_pos
		accept_event()
		if interaction_mode != &"select":
			queue_redraw()
			return
		var tile: ContinuumTile = null
		if SpacetimeDB.Continuum.db != null:
			for candidate: ContinuumTile in SpacetimeDB.Continuum.db.tile.iter():
				if candidate.x == grid_pos.x and candidate.y == grid_pos.y:
					tile = candidate
					break
		if tile != null:
			selected_tile_id = tile.id
			tile_selected.emit(tile.id)
			queue_redraw()
