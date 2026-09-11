## Draws the abstract colony grid and the colonist markers.
##
## Purely a view: it reads typed rows out of the generated `SpacetimeDB.Continuum`
## bindings and never mutates anything. Clicking a tile only emits
## [signal tile_selected]; it is [Main] that turns that into a reducer call.
class_name ColonyMap
extends Control

signal tile_selected(tile_id: int)

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

const DISABLED_COLOR := Color("50202a")
const GRID_LINE_COLOR := Color(1, 1, 1, 0.06)
const SELECTION_COLOR := Color("ffffff")
const LEGEND_HEIGHT := 72.0

var selected_tile_id: int = -1

## Rendered colonist positions, eased towards the authoritative tile positions so
## movement reads as movement instead of teleporting.
var _visual_positions: Dictionary[int, Vector2] = {}
var _font: Font = null
## Grid extent, derived from the tiles the server actually sent.
var _grid := Vector2i(24, 24)
var _has_state: bool = false
var _generation := -1
var _stored_amounts: Dictionary[int, float] = {}
var _stock_pulses: Dictionary[int, float] = {}


func _ready() -> void:
	_font = ThemeDB.fallback_font
	set_process(true)


func _process(delta: float) -> void:
	if not _has_state:
		return
	var changed: bool = false
	for kind: int in _stock_pulses.keys():
		_stock_pulses[kind] = maxf(0.0, _stock_pulses[kind] - delta)
		changed = true
		if _stock_pulses[kind] <= 0.0:
			_stock_pulses.erase(kind)
	for colonist: ContinuumColonist in SpacetimeDB.Continuum.db.colonist.iter():
		var target := Vector2(colonist.x, colonist.y)
		if not _visual_positions.has(colonist.id):
			_visual_positions[colonist.id] = target
			changed = true
			continue
		var current: Vector2 = _visual_positions[colonist.id]
		if current.distance_to(target) > 0.001:
			# Snap when far behind (a big time-scale jump), ease when close.
			if current.distance_to(target) > 3.0:
				_visual_positions[colonist.id] = target
			else:
				_visual_positions[colonist.id] = current.lerp(target, clampf(delta * 8.0, 0.0, 1.0))
			changed = true
	if changed:
		queue_redraw()


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
	return minf(size.x / float(_grid.x), maxf(0.0, size.y - LEGEND_HEIGHT) / float(_grid.y))


func _origin() -> Vector2:
	var cell := _cell_size()
	var used := Vector2(cell * _grid.x, cell * _grid.y)
	return ((size - Vector2(0, LEGEND_HEIGHT) - used) * 0.5).floor()


func _draw() -> void:
	var cell := _cell_size()
	if cell <= 0.0:
		return
	var origin := _origin()

	draw_rect(Rect2(origin, Vector2(cell * _grid.x, cell * _grid.y)), Color("1a1d23"))

	if not _has_state:
		draw_string(_font, origin + Vector2(0.0, size.y * 0.5), "waiting for colony state...",
				HORIZONTAL_ALIGNMENT_CENTER, size.x, 14, Color(1, 1, 1, 0.5))
		return

	for tile: ContinuumTile in SpacetimeDB.Continuum.db.tile.iter():
		var rect := Rect2(origin + Vector2(tile.x * cell, tile.y * cell), Vector2(cell, cell))
		var colour: Color = TILE_COLORS.get(tile.kind.value, Color("2a2e37"))
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

	for i in range(_grid.x + 1):
		var x := origin.x + i * cell
		draw_line(Vector2(x, origin.y), Vector2(x, origin.y + cell * _grid.y), GRID_LINE_COLOR)
	for i in range(_grid.y + 1):
		var y := origin.y + i * cell
		draw_line(Vector2(origin.x, y), Vector2(origin.x + cell * _grid.x, y), GRID_LINE_COLOR)

	_draw_zone_labels(origin, cell)
	_draw_delivery_routes(origin, cell)
	_draw_storage(origin, cell)
	_draw_colonists(origin, cell)
	_draw_ground_items(origin, cell)
	_draw_legend()


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
				font_size, Color(1, 1, 1, 0.85))


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
		var font_size := clampi(int(cell * 0.30), 8, 12)
		draw_string(_font, rect.position + Vector2(1, rect.size.y * 0.5 + font_size * 0.35),
				text, HORIZONTAL_ALIGNMENT_CENTER, rect.size.x - 2, font_size, colour)


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
			HORIZONTAL_ALIGNMENT_LEFT, rect.size.x - 10, font_size - 1, Color("ddd4c0"))
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
				HORIZONTAL_ALIGNMENT_LEFT, rect.size.x - 10, font_size, colour)


func _draw_legend() -> void:
	var y := size.y - LEGEND_HEIGHT + 19.0
	var index := 0
	for kind: int in RESOURCE_COLORS:
		var x := 12.0 + index * (size.x - 24.0) / 4.0
		var colour: Color = RESOURCE_COLORS[kind]
		draw_rect(Rect2(Vector2(x, y - 10), Vector2(9, 9)), colour)
		draw_string(_font, Vector2(x + 14, y),
				ContinuumResourceKind.parse_enum_name(kind).capitalize(),
				HORIZONTAL_ALIGNMENT_LEFT, -1, 12, colour)
		index += 1
	draw_string(_font, Vector2(12, y + 21), "Box = ground pile   Attached box = cargo   Dashed arrow = delivery destination",
			HORIZONTAL_ALIGNMENT_LEFT, size.x - 24, 11, Color("ccd3df"))
	draw_string(_font, Vector2(12, y + 39), "Shared storage: no limit. Stock flashes on increases. Hover or select a pile's tile for amounts.",
			HORIZONTAL_ALIGNMENT_LEFT, size.x - 24, 11, Color("9aa4b2"))


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
		var radius := cell * (0.23 if sharing.size() > 1 else 0.32)

		draw_circle(centre, radius + 2.0, Color(0, 0, 0, 0.55))
		draw_circle(centre, radius, colour)

		var font_size := int(maxf(9.0, cell * 0.42))
		draw_string(_font, centre + Vector2(-font_size * 0.32, font_size * 0.36),
				colonist.name.substr(0, 1), HORIZONTAL_ALIGNMENT_LEFT, -1, font_size,
				Color("14161a"))

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
			draw_string(_font, cargo_rect.position + Vector2(1, cargo_rect.size.y * 0.5 + 3), cargo_text,
					HORIZONTAL_ALIGNMENT_CENTER, cargo_rect.size.x - 2, clampi(int(cell * 0.3), 8, 12), cargo_colour)

		var small := int(maxf(8.0, cell * 0.26))
		var caption := "%s: %s" % [colonist.name,
			ContinuumActivity.parse_enum_name(colonist.activity.value).capitalize()]
		var caption_at := centre + Vector2(-cell * 1.1, radius + small + 1.0)
		draw_string_outline(_font, caption_at, caption, HORIZONTAL_ALIGNMENT_CENTER,
				cell * 2.2, small, 3, Color("151920"))
		draw_string(_font, caption_at, caption, HORIZONTAL_ALIGNMENT_CENTER,
				cell * 2.2, small, Color("f1f4f8"))


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


func _gui_input(event: InputEvent) -> void:
	if not _has_state:
		return
	if event is InputEventMouseButton and event.pressed \
			and event.button_index == MOUSE_BUTTON_LEFT:
		var cell := _cell_size()
		if cell <= 0.0:
			return
		var local: Vector2 = ((event as InputEventMouseButton).position - _origin()) / cell
		var gx := int(floor(local.x))
		var gy := int(floor(local.y))
		if gx < 0 or gy < 0 or gx >= _grid.x or gy >= _grid.y:
			return
		var tile: ContinuumTile = null
		for candidate: ContinuumTile in SpacetimeDB.Continuum.db.tile.iter():
			if candidate.x == gx and candidate.y == gy:
				tile = candidate
				break
		if tile != null:
			selected_tile_id = tile.id
			tile_selected.emit(tile.id)
			queue_redraw()
