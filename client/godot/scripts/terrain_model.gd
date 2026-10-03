## Authoritative voxel cache, independent of renderer and generated bindings.
class_name LayeredTerrainModel
extends RefCounted

const EDGE := 16
const MAX_SELECTION_CELLS := 4096
const MAX_CACHED_COLUMNS := 65536
const MAX_FRAME_SAMPLES := 65536
const METRES_PER_LAYER := 0.5
var width := 24
var height := 24
var min_x := 0
var min_y := 0
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
## Derived-cache growth is not a terrain/cut/provenance change. Legacy renderers
## use this separately; physical selections depend only on authoritative revision.
var exposure_revision := 0
## Source encoding is supplied by a backend adapter, never generated here.
var source_edge := 64
var source_chunks: Dictionary = {}
var _source_reader := Callable()
var _complete_sources: Dictionary = {}
var _resolved_columns: Dictionary = {}
var query_count := 0
var voxel_query_count := 0
var presentation_mode: StringName = &"detail"
var overview_frame_provider := Callable()

func reset() -> void:
	chunks.clear()
	surfaces.clear()
	_exposed_bottom.clear()
	_resolved_columns.clear()
	source_chunks.clear()
	_complete_sources.clear()
	_source_reader = Callable()
	presentation_mode = &"detail"
	overview_frame_provider = Callable()
	revision += 1
	exposure_revision += 1
	materials = {0: {"name": "air", "opaque": false}}
	_opaque_materials = {0: false}
	signature = ""
	cut = 0

func capture_selection(rect: Rect2i) -> Dictionary:
	if rect.get_area() <= 0 or rect.get_area() > MAX_SELECTION_CELLS or rect.intersection(bounds()) != rect:
		return {}
	var cells := {}
	var cell_materials := {}
	var ready := true
	for y in range(rect.position.y, rect.end.y):
		for x in range(rect.position.x, rect.end.x):
			var xy := Vector2i(x, y)
			var surface: Variant = surface_at(xy)
			if surface == null:
				ready = false
			cells[xy] = surface
			cell_materials[xy] = material_at(surface) if surface != null else -1
	return {"cells": cells, "base": uniform_base(rect), "cut": cut, "signature": signature,
		"materials": materials.duplicate(true), "cell_materials": cell_materials, "ready": ready, "revision": revision}

func selection_valid(selection: Dictionary) -> bool:
	if selection.is_empty():
		return false
	if selection.get("cut", cut) != cut or selection.get("materials", materials) != materials:
		return false
	if not selection.get("ready", true) and selection.get("revision", -1) != revision:
		return false
	for xy in selection.cells:
		if not bounds().has_point(xy) or surface_at(xy) != selection.cells[xy]:
			return false
		if selection.cells[xy] != null and selection.get("cell_materials", {}).get(xy, material_at(selection.cells[xy])) != material_at(selection.cells[xy]):
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
	min_x = int(field(geometry, "min_x", 0))
	min_y = int(field(geometry, "min_y", 0))
	min_z = int(field(geometry, "min_z", -16))
	max_z = int(field(geometry, "max_z", 15))
	cut = clampi(cut, min_z, max_z)
	var parts: Array[String] = [str(width), str(height), str(min_x), str(min_y), str(min_z), str(max_z)]
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
	warm_region(bounds())
	return true

func set_geometry(geometry: Variant) -> void:
	width = maxi(1, int(field(geometry, "width", 24)))
	height = maxi(1, int(field(geometry, "height", 24)))
	min_x = int(field(geometry, "min_x", 0))
	min_y = int(field(geometry, "min_y", 0))
	min_z = int(field(geometry, "min_z", -16))
	max_z = maxi(min_z, int(field(geometry, "max_z", 15)))
	cut = clampi(cut, min_z, max_z)
	rebuild()

func set_materials(rows: Array) -> void:
	materials = {0: {"name": "air", "opaque": false}}
	_opaque_materials = {0: false}
	for row in rows:
		var id := int(field(row, "id", 0))
		materials[id] = row
		_opaque_materials[id] = bool(field(row, "opaque", false))
	rebuild()

func set_cut(layer: int) -> bool:
	var next := clampi(layer, min_z, max_z)
	if next == cut:
		return false
	cut = next
	rebuild()
	return true

func bounds() -> Rect2i:
	return Rect2i(min_x, min_y, width, height)

func material_at(cell: Vector3i) -> int:
	voxel_query_count += 1
	if not bounds().has_point(Vector2i(cell.x, cell.y)) or cell.z < min_z or cell.z > max_z:
		return -1
	var chunk := Vector3i(floori(cell.x / float(EDGE)), floori(cell.y / float(EDGE)), floori(cell.z / float(EDGE)))
	var local := cell - chunk * EDGE
	if not source_chunks.is_empty() or _source_reader.is_valid():
		var source := Vector2i(floori(cell.x / float(source_edge)), floori(cell.y / float(source_edge)))
		if not _complete_sources.get(source, false) or not source_chunks.has(source):
			return -1
		if not chunks.has(chunk):
			return int(_source_reader.call(source_chunks[source].payload, cell)) if _source_reader.is_valid() else -1
	var values: Variant = chunks.get(chunk, [])
	var index := local.x + EDGE * (local.y + EDGE * local.z)
	return int(values[index]) if index < values.size() else -1

func opaque(cell: Vector3i) -> bool:
	var id := material_at(cell)
	return id >= 0 and bool(_opaque_materials.get(id, false))

func surface_at(xy: Vector2i) -> Variant:
	_resolve_column(xy)
	return surfaces.get(xy)

func rebuild() -> void:
	clear_exposure_cache()
	revision += 1

func clear_exposure_cache() -> void:
	surfaces.clear()
	_exposed_bottom.clear()
	_resolved_columns.clear()
	exposure_revision += 1

func _resolve_column(xy: Vector2i) -> void:
	if _resolved_columns.has(xy) or not bounds().has_point(xy):
		return
	if surfaces.has(xy) and _exposed_bottom.has(xy):
		_resolved_columns[xy] = true
		return
	if not _opaque_materials.has(material_at(Vector3i(xy.x, xy.y, cut))):
		query_count += 1
		return
	if _resolved_columns.size() >= MAX_CACHED_COLUMNS:
		clear_exposure_cache()
	query_count += 1
	var bottom := min_z
	var known := true
	for z in range(cut, min_z - 1, -1):
		var material := material_at(Vector3i(xy.x, xy.y, z))
		if not _opaque_materials.has(material):
			bottom = z + 1
			known = false
			break
		if _opaque_materials[material]:
			surfaces[xy] = Vector3i(xy.x, xy.y, z)
			bottom = z + 1
			break
	_exposed_bottom[xy] = bottom
	_resolved_columns[xy] = known
	exposure_revision += 1

func column_state(xy: Vector2i) -> StringName:
	_resolve_column(xy)
	if not _resolved_columns.get(xy, false):
		return &"pending"
	return &"surface" if surfaces.has(xy) else &"resolved_empty"

func coverage_ready(rect: Rect2i) -> bool:
	if rect.get_area() <= 0 or rect.get_area() > MAX_SELECTION_CELLS or rect.intersection(bounds()) != rect:
		return false
	if _source_reader.is_valid():
		for y in range(floori(rect.position.y / float(source_edge)), ceili(rect.end.y / float(source_edge))):
			for x in range(floori(rect.position.x / float(source_edge)), ceili(rect.end.x / float(source_edge))):
				var coordinate := Vector2i(x, y)
				if not source_chunks.has(coordinate) or not _complete_sources.get(coordinate, false):
					return false
		return true
	for z in range(floori(min_z / 16.0), floori(max_z / 16.0) + 1):
		for y in range(floori(rect.position.y / 16.0), ceili(rect.end.y / 16.0)):
			for x in range(floori(rect.position.x / 16.0), ceili(rect.end.x / 16.0)):
				if chunks.get(Vector3i(x, y, z), []).size() != 4096:
					return false
	return true

func configure_sources(edge: int, reader: Callable) -> void:
	assert(edge > 0)
	source_edge = edge
	_source_reader = reader
	source_chunks.clear()
	_complete_sources.clear()
	rebuild()

func apply_source_chunk(coordinate: Vector2i, payload: Variant, version: int) -> void:
	source_chunks[coordinate] = {"payload": payload, "revision": version}
	rebuild()

func set_chunk_complete(coordinate: Vector2i, complete: bool) -> void:
	_complete_sources[coordinate] = complete
	rebuild()

func apply_edit_chunk(coordinate: Vector3i, values: Variant) -> void:
	chunks[coordinate] = values
	rebuild()

func remove_edit_chunk(coordinate: Vector3i) -> void:
	chunks.erase(coordinate)
	rebuild()

func evict_source_chunk(coordinate: Vector2i) -> void:
	source_chunks.erase(coordinate)
	_complete_sources.erase(coordinate)
	var area := Rect2i(coordinate * source_edge, Vector2i.ONE * source_edge)
	for edit: Vector3i in chunks.keys():
		if area.intersects(Rect2i(Vector2i(edit.x, edit.y) * EDGE, Vector2i.ONE * EDGE)):
			chunks.erase(edit)
	rebuild()

## Renderer contract. Samples are exact physical rays; overview is a separate
## server-authored payload and must never enter this model's picking queries.
func frame_samples(rect: Rect2i, stride := 1, budget := MAX_FRAME_SAMPLES) -> Dictionary:
	if presentation_mode == &"overview" and overview_frame_provider.is_valid():
		return overview_frame_provider.call(rect, cut, budget)
	var area := rect.intersection(bounds())
	var step := maxi(1, stride)
	var limit := clampi(budget, 0, MAX_FRAME_SAMPLES)
	var samples: Array[Dictionary] = []
	for y in range(area.position.y, area.end.y, step):
		for x in range(area.position.x, area.end.x, step):
			if samples.size() >= limit:
				return {"rect": area, "stride": step, "cut": cut, "revision": revision, "mode": &"detail", "samples": samples, "truncated": true}
			var xy := Vector2i(x, y)
			var surface: Variant = surface_at(xy)
			var state: StringName = &"surface" if surface != null else (&"resolved_empty" if _resolved_columns.get(xy, false) else &"pending")
			var sample := {"xy": xy, "surface": surface, "state": state,
				"material": material_at(surface) if surface != null else -1}
			var source := Vector2i(floori(x / float(source_edge)), floori(y / float(source_edge)))
			if source_chunks.has(source) and _complete_sources.get(source, false):
				var index := posmod(x, source_edge) + source_edge * posmod(y, source_edge)
				for key in ["soil_fertility", "forest_density", "moisture"]:
					var values: Variant = field(source_chunks[source].payload, key, [])
					if values.size() == source_edge * source_edge:
						sample[key] = float(values[index]) / 255.0
			samples.append(sample)
	return {"rect": area, "stride": step, "cut": cut, "revision": revision, "mode": &"detail", "samples": samples, "truncated": false}

func visible_surfaces(rect: Rect2i, stride := 1, budget := MAX_FRAME_SAMPLES) -> Dictionary:
	return frame_samples(rect, stride, budget)

## Exact art API: keys are footprint origins, not overview representative points.
func render_frame(rect: Rect2i, budget := MAX_FRAME_SAMPLES) -> Dictionary:
	var data := frame_samples(rect, 1, budget)
	var stride: int = data.stride
	var start := Vector2i((Vector2(data.rect.position) / stride).floor()) * stride
	var finish := Vector2i((Vector2(data.rect.end) / stride).ceil()) * stride
	var samples := {}
	for sample: Dictionary in data.samples:
		var xy: Vector2i = sample.xy
		if data.mode == &"overview":
			xy -= Vector2i.ONE * (stride / 2)
		var surface: Variant = sample.surface
		samples[xy] = {"known": sample.state != &"pending", "surface_z": surface.z if surface != null else min_z - 1,
			"material": sample.material if surface != null else 0}
	return {"region": Rect2i(start, finish - start), "stride": stride, "cut": cut,
		"revision": data.revision, "mode": String(data.mode), "samples": samples}

## Legacy renderers enumerate exposed cells. Warm only replicated columns in a
## bounded crop. Exposure changes never advance the authoritative revision.
func warm_region(rect: Rect2i) -> void:
	var horizontal := {}
	var queried := 0
	for chunk: Vector3i in chunks:
		var coordinate := Vector2i(chunk.x, chunk.y)
		if horizontal.has(coordinate):
			continue
		horizontal[coordinate] = true
		var area := Rect2i(coordinate * EDGE, Vector2i.ONE * EDGE).intersection(rect).intersection(bounds())
		for y in range(area.position.y, area.end.y):
			for x in range(area.position.x, area.end.x):
				if queried >= MAX_FRAME_SAMPLES:
					return
				_resolve_column(Vector2i(x, y))
				queried += 1

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
	if w * d > MAX_SELECTION_CELLS:
		return false
	for yy in range(y, y + d):
		for xx in range(x, x + w):
			_resolve_column(Vector2i(xx, yy))
			if not bounds().has_point(Vector2i(xx, yy)):
				return false
			if base < int(_exposed_bottom.get(Vector2i(xx, yy), cut + 1)):
				return false
	return true

func position_visible(position: Vector3, body_width := 1, body_depth := 1) -> bool:
	if (body_width + 1) * (body_depth + 1) > MAX_SELECTION_CELLS:
		return false
	if position.z > cut or position.z < min_z or body_width < 1 or body_depth < 1:
		return false
	for y in range(floori(position.y), ceili(position.y + body_depth)):
		for x in range(floori(position.x), ceili(position.x + body_width)):
			_resolve_column(Vector2i(x, y))
			if not bounds().has_point(Vector2i(x, y)) or floori(position.z) < int(_exposed_bottom.get(Vector2i(x, y), cut + 1)):
				return false
	return true

func uniform_base(rect: Rect2i) -> Variant:
	if rect.get_area() <= 0 or rect.get_area() > MAX_SELECTION_CELLS:
		return null
	var base: Variant = base_at(rect.position)
	if base == null:
		return null
	for y in range(rect.position.y, rect.end.y):
		for x in range(rect.position.x, rect.end.x):
			if base_at(Vector2i(x, y)) != base:
				return null
	return base

func excavation_payload(rect: Rect2i, bottom: int, extent: int, priority := 2) -> Array:
	if rect.get_area() <= 0 or rect.get_area() > MAX_SELECTION_CELLS or rect.intersection(bounds()) != rect:
		return []
	if extent < 1 or bottom < min_z or bottom + extent - 1 > max_z:
		return []
	return [rect.position.x, rect.position.y, rect.end.x - 1, rect.end.y - 1, bottom, extent, priority]

func placement_clear(rect: Rect2i, base: int, clearance: int) -> bool:
	if rect.get_area() <= 0 or rect.get_area() > MAX_SELECTION_CELLS:
		return false
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
