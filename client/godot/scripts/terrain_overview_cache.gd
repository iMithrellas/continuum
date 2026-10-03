## Representative server samples: intentionally no material_at/base_at API.
class_name TerrainOverviewCache
extends RefCounted

signal changed
signal failed(message: String)
var rows: Dictionary = {}
var lod := 3
var cut := 0
var revision := 0
var generation := 0
var _client: Variant
var _epoch := 0
var _coverage := LayeredTerrainModel.new()
var _stream := TerrainStream.new()
var _physical: LayeredTerrainModel
var _row_revisions: Dictionary = {}

func attach(client: Variant, model: LayeredTerrainModel, epoch: int, world_generation: int) -> void:
	stop()
	_client = client
	_epoch = epoch
	generation = world_generation
	_physical = model
	_row_revisions.clear()
	_coverage.set_geometry({"width": model.width, "height": model.height, "min_x": model.min_x, "min_y": model.min_y, "min_z": model.min_z, "max_z": model.max_z})
	_stream.manage_physical = false
	_stream.max_resident = 256
	_stream.eviction_adapter = _evict
	if not _stream.changed.is_connected(_changed):
		_stream.changed.connect(_changed)
	if not _stream.failed.is_connected(_failed):
		_stream.failed.connect(_failed)
	_stream.attach(client, _coverage, epoch, generation, _queries, _snapshot)

func _changed() -> void:
	changed.emit()

func _evict(coordinate: Vector2i) -> void:
	rows.erase(coordinate)
	_row_revisions.erase(coordinate)
	revision += 1

func _failed(message: String) -> void:
	failed.emit(message)

func request_frame(rect: Rect2i, pixels_per_cell: float, layer: int) -> void:
	var next_lod := 9
	for candidate: int in CompactTerrainAdapter.LODS:
		var stride := 1 << candidate
		var estimated := ceili(rect.size.x / float(stride)) * ceili(rect.size.y / float(stride))
		var edge := 16 * stride
		var tiles := (ceili(rect.end.x / float(edge)) - floori(rect.position.x / float(edge))) * (ceili(rect.end.y / float(edge)) - floori(rect.position.y / float(edge)))
		if stride * pixels_per_cell >= 2.0 and estimated <= 65536 and tiles <= 256:
			next_lod = candidate
			break
	if next_lod != lod or layer != cut or _stream.client == null:
		_stream.stop()
		rows.clear()
		_row_revisions.clear()
		lod = next_lod
		cut = layer
		revision += 1
		_stream.attach(_client, _coverage, _epoch, generation, _queries, _snapshot)
	_coverage.source_edge = 16 * (1 << lod)
	_stream.request_frame(rect, 32.0, cut)

func _queries(coordinate: Vector2i, _edge: int, version: int) -> PackedStringArray:
	return PackedStringArray(["SELECT * FROM terrain_overview_chunk WHERE lod = %d AND cut_z = %d AND chunk_x = %d AND chunk_y = %d AND generation_id = %d" % [lod, cut, coordinate.x, coordinate.y, version]])

func _snapshot(_model: LayeredTerrainModel, coordinate: Vector2i, client: Variant, version: int) -> bool:
	var found: Variant = null
	for row in ColonyMap.table_rows(client.db, "terrain_overview_chunk"):
		if LayeredTerrainModel.field(row, "generation_id") != version or LayeredTerrainModel.field(row, "lod") != lod or LayeredTerrainModel.field(row, "cut_z") != cut:
			continue
		if LayeredTerrainModel.field(row, "chunk_x") != coordinate.x or LayeredTerrainModel.field(row, "chunk_y") != coordinate.y:
			continue
		if found != null:
			return false
		found = row
	if found == null or not _valid_row(found, coordinate, version):
		return false
	var next_revision: int = LayeredTerrainModel.field(found, "revision")
	if next_revision < _row_revisions.get(coordinate, -1):
		return false
	if not rows.has(coordinate) or next_revision != _row_revisions.get(coordinate, -1):
		var stored := {}
		for key in ["generation_id", "revision", "lod", "cut_z", "chunk_x", "chunk_y", "surface_z", "material", "soil_fertility", "forest_density", "moisture"]:
			var value: Variant = LayeredTerrainModel.field(found, key)
			stored[key] = value.duplicate() if value is Array else value
		rows[coordinate] = stored
		_row_revisions[coordinate] = next_revision
		revision += 1
	return true

func _valid_row(row: Variant, coordinate: Vector2i, version: int) -> bool:
	if not CompactTerrainAdapter.coordinates_valid(row) or not CompactTerrainAdapter.integer_field(row, "revision", 0, 4294967295):
		return false
	if not CompactTerrainAdapter.integer_field(row, "generation_id", 0, 9223372036854775807) or LayeredTerrainModel.field(row, "generation_id") != version:
		return false
	if not CompactTerrainAdapter.integer_field(row, "lod", 0, 255) or LayeredTerrainModel.field(row, "lod") != lod:
		return false
	if not CompactTerrainAdapter.integer_field(row, "cut_z", _coverage.min_z, _coverage.max_z) or LayeredTerrainModel.field(row, "cut_z") != cut:
		return false
	var stride := 1 << lod
	if not Rect2i(coordinate * 16 * stride, Vector2i.ONE * 16 * stride).intersects(_coverage.bounds()):
		return false
	for key in ["surface_z", "material", "soil_fertility", "forest_density", "moisture"]:
		var minimum := -32768 if key == "surface_z" else 0
		var maximum := 32767 if key == "surface_z" else (65535 if key == "material" else 255)
		if not CompactTerrainAdapter.integer_array(LayeredTerrainModel.field(row, key), 256, minimum, maximum):
			return false
	var heights: Variant = LayeredTerrainModel.field(row, "surface_z")
	var materials: Variant = LayeredTerrainModel.field(row, "material")
	for index in 256:
		var material: int = materials[index]
		var z: int = heights[index]
		var point := (coordinate * 16 + Vector2i(index % 16, index / 16)) * stride + Vector2i.ONE * (stride / 2)
		if not _physical.materials.has(material) or not LayeredTerrainModel.field(_physical.materials[material], "opaque") is bool:
			return false
		if material == 0:
			if z != _coverage.min_z - 1 or LayeredTerrainModel.field(_physical.materials[material], "opaque"):
				return false
		elif not _coverage.bounds().has_point(point) or z < _coverage.min_z or z > cut or not LayeredTerrainModel.field(_physical.materials[material], "opaque"):
			return false
	return true

func refresh() -> void:
	var invalidated := false
	for coordinate: Vector2i in _stream.active_coordinates():
		if not _snapshot(_coverage, coordinate, _client, generation) and rows.has(coordinate):
			rows.erase(coordinate)
			revision += 1
			invalidated = true
	if invalidated:
		changed.emit()

func frame_samples(rect: Rect2i, layer: int, budget: int) -> Dictionary:
	var stride := 1 << lod
	var samples: Array[Dictionary] = []
	var area := rect.intersection(_coverage.bounds())
	var limit := clampi(budget, 0, 65536)
	if layer == cut:
		for sy in range(floori(area.position.y / float(stride)), ceili(area.end.y / float(stride))):
			for sx in range(floori(area.position.x / float(stride)), ceili(area.end.x / float(stride))):
				if samples.size() >= limit:
					return _frame(area, stride, samples, true)
				var coordinate := Vector2i(floori(sx / 16.0), floori(sy / 16.0))
				var xy := Vector2i(sx, sy) * stride + Vector2i.ONE * (stride / 2)
				var sample := {"xy": xy, "surface": null, "material": -1, "state": &"pending"}
				if rows.has(coordinate):
					var row: Variant = rows[coordinate]
					var index := posmod(sx, 16) + 16 * posmod(sy, 16)
					var z := int(LayeredTerrainModel.field(row, "surface_z")[index])
					var material := int(LayeredTerrainModel.field(row, "material")[index])
					sample.material = material
					sample.state = &"surface" if material > 0 else &"resolved_empty"
					sample.surface = Vector3i(xy.x, xy.y, z) if material > 0 else null
					for key in ["soil_fertility", "forest_density", "moisture"]:
						sample[key] = float(LayeredTerrainModel.field(row, key)[index]) / 255.0
				samples.append(sample)
	return _frame(area, stride, samples, false)

func _frame(area: Rect2i, stride: int, samples: Array, truncated: bool) -> Dictionary:
	return {"rect": area, "stride": stride, "cut": cut, "revision": revision, "mode": &"overview", "samples": samples, "truncated": truncated}

func tick(delta: float) -> void:
	_stream.tick(delta)

func stop() -> void:
	_stream.stop()
	rows.clear()
