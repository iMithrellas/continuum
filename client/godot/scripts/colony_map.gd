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
	ContinuumTileKind.Options.food: Color("3f9b52"),
	ContinuumTileKind.Options.sleep: Color("4a5bb5"),
	ContinuumTileKind.Options.work: Color("b1802c"),
	ContinuumTileKind.Options.recreation: Color("9350b8"),
}

const COLONIST_COLORS: Array[Color] = [
	Color("ff7043"), Color("26c6da"), Color("ffee58"),
	Color("ec407a"), Color("8bc34a"),
]

const DISABLED_COLOR := Color("50202a")
const GRID_LINE_COLOR := Color(1, 1, 1, 0.06)
const SELECTION_COLOR := Color("ffffff")

var selected_tile_id: int = -1

## Rendered colonist positions, eased towards the authoritative tile positions so
## movement reads as movement instead of teleporting.
var _visual_positions: Dictionary[int, Vector2] = {}
var _font: Font = null
## Grid extent, derived from the tiles the server actually sent.
var _grid := Vector2i(16, 16)
var _has_state: bool = false


func _ready() -> void:
	_font = ThemeDB.fallback_font
	set_process(true)


func _process(delta: float) -> void:
	if not _has_state:
		return
	var changed: bool = false
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


## Called by [Main] when the subscription delivered new tile or colonist rows.
func refresh() -> void:
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
	_draw_colonists(origin, cell)


## One label per zone, at the zone's top-left tile, so the map reads without a legend.
func _draw_zone_labels(origin: Vector2, cell: float) -> void:
	var font_size := int(maxf(9.0, cell * 0.32))
	for kind: int in TILE_COLORS.keys():
		if kind == ContinuumTileKind.Options.empty:
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


func _draw_colonists(origin: Vector2, cell: float) -> void:
	var colonists: Array[ContinuumColonist] = SpacetimeDB.Continuum.db.colonist.iter()
	colonists.sort_custom(func(a: ContinuumColonist, b: ContinuumColonist) -> bool:
		return a.id < b.id)

	for index in colonists.size():
		var colonist: ContinuumColonist = colonists[index]
		var grid_pos: Vector2 = _visual_positions.get(colonist.id,
				Vector2(colonist.x, colonist.y))
		var centre := origin + (grid_pos + Vector2(0.5, 0.5)) * cell
		var colour: Color = COLONIST_COLORS[index % COLONIST_COLORS.size()]
		var radius := cell * 0.32

		draw_circle(centre, radius + 2.0, Color(0, 0, 0, 0.55))
		draw_circle(centre, radius, colour)

		var font_size := int(maxf(9.0, cell * 0.42))
		draw_string(_font, centre + Vector2(-font_size * 0.32, font_size * 0.36),
				colonist.name.substr(0, 1), HORIZONTAL_ALIGNMENT_LEFT, -1, font_size,
				Color("14161a"))

		var small := int(maxf(8.0, cell * 0.26))
		draw_string(_font, centre + Vector2(-cell * 0.9, radius + small + 1.0),
				"%s: %s" % [colonist.name,
					ContinuumActivity.parse_enum_name(colonist.activity.value).capitalize()],
				HORIZONTAL_ALIGNMENT_CENTER, cell * 1.8, small, Color(1, 1, 1, 0.8))


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
