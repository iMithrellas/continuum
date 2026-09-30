## Authoritative voxel cache, independent of renderer and generated bindings.
class_name LayeredTerrainModel
extends RefCounted

const EDGE := 16
const METRES_PER_LAYER := 0.5
var width := 24
var height := 24
var min_z := -16
var max_z := 15
var cut := 0
var chunks: Dictionary = {}
var materials: Dictionary = {0: {"name": "air", "opaque": false}}
var _opaque_materials: Dictionary = {0: false}
var surfaces: Dictionary = {}
var signature := ""
## Lowest exposed feet layer, including rays with no supporting floor.
## A solid or unknown voxel terminates exposure; neither is inferred as air.
var _exposed_bottom: Dictionary = {}
var revision := 0

func reset() -> void:
	chunks.clear()
	surfaces.clear()
	_exposed_bottom.clear()
	revision += 1
	materials = {0: {"name": "air", "opaque": false}}
	_opaque_materials = {0: false}
	signature = ""
	cut = 0

func capture_selection(rect: Rect2i) -> Dictionary:
	var cells := {}
	for y in range(rect.position.y, rect.end.y):
		for x in range(rect.position.x, rect.end.x):
			var xy := Vector2i(x, y)
			cells[xy] = surface_at(xy)
	return {"cells": cells, "base": uniform_base(rect)}

func selection_valid(selection: Dictionary) -> bool:
	if selection.is_empty():
		return false
	for xy in selection.cells:
		if surface_at(xy) != selection.cells[xy]:
			return false
	return true

static func step_position(source: Vector3, next: Vector3, progress: float) -> Vector3:
	var p := clampf(progress, 0.0, 1.0)
	if next.z == source.z:
		return source.lerp(next, p)
	var corner := Vector3(source.x, source.y, next.z) if next.z > source.z else Vector3(next.x, next.y, source.z)
	return source.lerp(corner, p * 2.0) if p < 0.5 else corner.lerp(next, (p - 0.5) * 2.0)

static func sample_movement(row: Variant, previous: Dictionary, weight: float) -> Dictionary:
	var source := Vector3(field(row, "x", 0), field(row, "y", 0), field(row, "z", 0))
	var next := Vector3(field(row, "next_x", source.x), field(row, "next_y", source.y), field(row, "next_z", source.z))
	var authoritative := clampf(float(field(row, "move_progress", 0.0)), 0.0, 1.0)
	var progress := authoritative
	if previous.get("source") == source and previous.get("next") == next and authoritative >= float(previous.get("authoritative", authoritative)):
		progress = lerpf(float(previous.progress), authoritative, clampf(weight, 0.0, 1.0))
		if absf(progress - authoritative) < 0.0001:
			progress = authoritative
	return {"source": source, "next": next, "progress": progress, "authoritative": authoritative,
		"position": step_position(source, next, progress)}

static func field(row: Variant, key: String, fallback: Variant = null) -> Variant:
	if row is Dictionary:
		return row.get(key, fallback)
	if row is Object and key in row:
		return row.get(key)
	return fallback

static func movement_position(row: Variant) -> Vector3:
	var feet := Vector3(field(row, "x", 0), field(row, "y", 0), field(row, "z", 0))
	var next := Vector3(field(row, "next_x", feet.x), field(row, "next_y", feet.y), field(row, "next_z", feet.z))
	return step_position(feet, next, float(field(row, "move_progress", 0.0)))

func sync(geometry: Variant, chunk_rows: Array, material_rows: Array) -> bool:
	width = int(field(geometry, "width", 24))
	height = int(field(geometry, "height", 24))
	min_z = int(field(geometry, "min_z", -16))
	max_z = int(field(geometry, "max_z", 15))
	cut = clampi(cut, min_z, max_z)
	var parts: Array[String] = [str(width), str(height), str(min_z), str(max_z)]
	chunks.clear()
	for row in chunk_rows:
		var coordinate := Vector3i(field(row, "chunk_x", 0), field(row, "chunk_y", 0), field(row, "chunk_z", 0))
		chunks[coordinate] = field(row, "materials", [])
		parts.append("%s:%s:%s" % [coordinate, field(row, "revision", 0), chunks[coordinate].size()])
	materials = {0: {"name": "air", "opaque": false}}
	_opaque_materials = {0: false}
	for row in material_rows:
		var id := int(field(row, "id", 0))
		materials[id] = row
		_opaque_materials[id] = bool(field(row, "opaque", false))
		parts.append("material:%s:%s:%s" % [field(row, "id", 0), field(row, "name", ""), field(row, "opaque", false)])
	parts.sort()
	var next := "|".join(parts)
	if signature == next:
		return false
	signature = next
	rebuild()
	return true

func set_cut(layer: int) -> bool:
	var next := clampi(layer, min_z, max_z)
	if next == cut:
		return false
	cut = next
	rebuild()
	return true

func material_at(cell: Vector3i) -> int:
	if cell.x < 0 or cell.y < 0 or cell.x >= width or cell.y >= height or cell.z < min_z or cell.z > max_z:
		return -1
	var chunk := Vector3i(floori(cell.x / float(EDGE)), floori(cell.y / float(EDGE)), floori(cell.z / float(EDGE)))
	var local := cell - chunk * EDGE
	var values: Variant = chunks.get(chunk, [])
	var index := local.x + EDGE * (local.y + EDGE * local.z)
	return int(values[index]) if index < values.size() else -1

func opaque(cell: Vector3i) -> bool:
	var id := material_at(cell)
	return id >= 0 and bool(_opaque_materials.get(id, false))

func surface_at(xy: Vector2i) -> Variant:
	return surfaces.get(xy)

func rebuild() -> void:
	surfaces.clear()
	_exposed_bottom.clear()
	revision += 1
	for y in height:
		for x in width:
			var xy := Vector2i(x, y)
			var column_chunk := Vector3i(x / EDGE, y / EDGE, 0)
			var column_index := x % EDGE + EDGE * (y % EDGE)
			var chunk_z := 2147483647
			var values: Variant = []
			var bottom := min_z
			for z in range(cut, min_z - 1, -1):
				var cz := floori(z / float(EDGE))
				if cz != chunk_z:
					chunk_z = cz
					column_chunk.z = cz
					values = chunks.get(column_chunk, [])
				var index := column_index + EDGE * EDGE * (z - cz * EDGE)
				var material := int(values[index]) if index < values.size() else -1
				if not _opaque_materials.has(material):
					bottom = z + 1
					break # unresolved ray: no inferred floor, base, or hit target
				if _opaque_materials[material]:
					surfaces[xy] = Vector3i(x, y, z)
					bottom = z + 1
					break
			_exposed_bottom[xy] = bottom

func base_at(xy: Vector2i) -> Variant:
	var surface: Variant = surface_at(xy)
	if surface == null:
		return null
	return surface.z + 1 if surface.z < cut else surface.z

func depth_at(xy: Vector2i) -> int:
	var surface: Variant = surface_at(xy)
	return cut - surface.z if surface != null else -1

## Whole actors remain visible when their feet are exposed, even if heads
## cross the cut. Unknown chunks are not invented walls or selectable floors.
func entity_visible(row: Variant) -> bool:
	var base := int(field(row, "z", 0))
	if base > cut or base < min_z:
		return false
	var x := int(field(row, "x", 0))
	var y := int(field(row, "y", 0))
	var w := maxi(1, int(field(row, "width", field(row, "body_width", 1))))
	var d := maxi(1, int(field(row, "depth", field(row, "body_depth", 1))))
	for yy in range(y, y + d):
		for xx in range(x, x + w):
			if xx < 0 or yy < 0 or xx >= width or yy >= height:
				return false
			if base < int(_exposed_bottom.get(Vector2i(xx, yy), cut + 1)):
				return false
	return true

func position_visible(position: Vector3, body_width := 1, body_depth := 1) -> bool:
	if position.z > cut or position.z < min_z or body_width < 1 or body_depth < 1:
		return false
	for y in range(floori(position.y), ceili(position.y + body_depth)):
		for x in range(floori(position.x), ceili(position.x + body_width)):
			if x < 0 or y < 0 or x >= width or y >= height or floori(position.z) < int(_exposed_bottom.get(Vector2i(x, y), cut + 1)):
				return false
	return true

func uniform_base(rect: Rect2i) -> Variant:
	var base: Variant = base_at(rect.position)
	if base == null:
		return null
	for y in range(rect.position.y, rect.end.y):
		for x in range(rect.position.x, rect.end.x):
			if base_at(Vector2i(x, y)) != base:
				return null
	return base

func excavation_payload(rect: Rect2i, bottom: int, extent: int, priority := 2) -> Array:
	if extent < 1 or bottom < min_z or bottom + extent - 1 > max_z:
		return []
	return [rect.position.x, rect.position.y, rect.end.x - 1, rect.end.y - 1, bottom, extent, priority]

func placement_clear(rect: Rect2i, base: int, clearance: int) -> bool:
	if clearance < 1 or base < min_z or base + clearance - 1 > max_z:
		return false
	for y in range(rect.position.y, rect.end.y):
		for x in range(rect.position.x, rect.end.x):
			var support := material_at(Vector3i(x, y, base - 1))
			if support <= 0 or not materials.has(support):
				return false
			for z in range(base, base + clearance):
				var cell := Vector3i(x, y, z)
				if material_at(cell) != 0:
					return false
	return true
