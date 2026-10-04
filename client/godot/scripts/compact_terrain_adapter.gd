## Decodes persisted storage-version-1 columns; does not generate terrain.
class_name CompactTerrainAdapter
extends RefCounted

const SOURCE_EDGE := 32
const OVERVIEW_EDGE := 16
const LODS := [3, 5, 7, 9]
var source_revisions: Dictionary = {}
var edit_revisions: Dictionary = {}


static func valid_source(row: Variant, generation: int) -> bool:
	if (
		not integer_field(row, "generation_id", 0, 9223372036854775807)
		or LayeredTerrainModel.field(row, "generation_id") != generation
	):
		return false
	if not integer_field(row, "revision", 0, 4294967295) or not coordinates_valid(row):
		return false
	for key in ["base_z", "soil_depth", "soil_fertility", "forest_density", "moisture"]:
		if not integer_array(
			LayeredTerrainModel.field(row, key),
			1024,
			-32768 if key == "base_z" else 0,
			32767 if key == "base_z" else 255
		):
			return false
	return true


static func integer_field(row: Variant, key: String, minimum: int, maximum: int) -> bool:
	var value: Variant = LayeredTerrainModel.field(row, key)
	return value is int and value >= minimum and value <= maximum


static func coordinates_valid(row: Variant) -> bool:
	return (
		integer_field(row, "chunk_x", -2147483648, 2147483647)
		and integer_field(row, "chunk_y", -2147483648, 2147483647)
	)


static func integer_array(values: Variant, count: int, minimum: int, maximum: int) -> bool:
	if not (
		values is Array
		or values is PackedByteArray
		or values is PackedInt32Array
		or values is PackedInt64Array
	):
		return false
	if values.size() != count:
		return false
	for value: Variant in values:
		if not value is int or value < minimum or value > maximum:
			return false
	return true


static func read_material(row: Variant, cell: Vector3i) -> int:
	var index := posmod(cell.x, SOURCE_EDGE) + SOURCE_EDGE * posmod(cell.y, SOURCE_EDGE)
	var bases: Variant = LayeredTerrainModel.field(row, "base_z", [])
	var soils: Variant = LayeredTerrainModel.field(row, "soil_depth", [])
	if bases.size() != 1024 or soils.size() != 1024:
		return -1
	var base := int(bases[index])
	return 0 if cell.z >= base else (1 if cell.z >= base - int(soils[index]) else 2)


static func detail_queries(coordinate: Vector2i, edge: int, generation: int) -> PackedStringArray:
	assert(edge == SOURCE_EDGE)
	return PackedStringArray(
		[
			(
				"SELECT * FROM terrain_column_chunk WHERE chunk_x = %d AND chunk_y = %d AND generation_id = %d"
				% [coordinate.x, coordinate.y, generation]
			),
			(
				"SELECT * FROM terrain_chunk WHERE chunk_x >= %d AND chunk_x < %d AND chunk_y >= %d AND chunk_y < %d"
				% [coordinate.x * 2, coordinate.x * 2 + 2, coordinate.y * 2, coordinate.y * 2 + 2]
			)
		]
	)


func snapshot(
	model: LayeredTerrainModel, coordinate: Vector2i, client: Variant, generation: int
) -> bool:
	var found: Variant = null
	for row in ColonyMap.table_rows(client.db, "terrain_column_chunk"):
		if not coordinates_valid(row):
			return false
		if (
			LayeredTerrainModel.field(row, "chunk_x") == coordinate.x
			and LayeredTerrainModel.field(row, "chunk_y") == coordinate.y
		):
			if found != null:
				return false
			found = row
	if found == null or not valid_source(found, generation):
		return false
	if not Rect2i(coordinate * SOURCE_EDGE, Vector2i.ONE * SOURCE_EDGE).intersects(model.bounds()):
		return false
	for id in [0, 1, 2]:
		if (
			not model.materials.has(id)
			or not LayeredTerrainModel.field(model.materials[id], "opaque") is bool
			or LayeredTerrainModel.field(model.materials[id], "opaque") != (id != 0)
		):
			return false
	for index in 1024:
		var point := coordinate * SOURCE_EDGE + Vector2i(index % SOURCE_EDGE, index / SOURCE_EDGE)
		if model.bounds().has_point(point):
			continue
		if LayeredTerrainModel.field(found, "base_z")[index] != model.min_z:
			return false
		for key in ["soil_depth", "soil_fertility", "forest_density", "moisture"]:
			if LayeredTerrainModel.field(found, key)[index] != 0:
				return false
	var version: int = LayeredTerrainModel.field(found, "revision")
	if version < source_revisions.get(coordinate, -1):
		return false
	var present := {}
	for row in ColonyMap.table_rows(client.db, "terrain_chunk"):
		if not coordinates_valid(row) or not integer_field(row, "chunk_z", -2147483648, 2147483647):
			return false
		var xyz := Vector3i(
			LayeredTerrainModel.field(row, "chunk_x", 0),
			LayeredTerrainModel.field(row, "chunk_y", 0),
			LayeredTerrainModel.field(row, "chunk_z", 0)
		)
		if Vector2i(floori(xyz.x / 2.0), floori(xyz.y / 2.0)) != coordinate:
			continue
		var values: Variant = LayeredTerrainModel.field(row, "materials", [])
		if (
			not integer_field(row, "revision", 0, 4294967295)
			or not integer_array(values, 4096, 0, 65535)
		):
			return false
		if xyz.z * 16 > model.max_z or xyz.z * 16 + 15 < model.min_z or present.has(xyz):
			return false
		for material: int in values:
			if (
				not model.materials.has(material)
				or not LayeredTerrainModel.field(model.materials[material], "opaque") is bool
			):
				return false
		var edit_version: int = LayeredTerrainModel.field(row, "revision")
		if edit_version < edit_revisions.get(xyz, -1):
			return false
		present[xyz] = {"values": values, "revision": edit_version}
	if source_revisions.get(coordinate, -1) != version or not model.source_chunks.has(coordinate):
		var stored := {}
		for key in [
			"chunk_x",
			"chunk_y",
			"generation_id",
			"revision",
			"base_z",
			"soil_depth",
			"soil_fertility",
			"forest_density",
			"moisture"
		]:
			var value: Variant = LayeredTerrainModel.field(found, key)
			stored[key] = (
				value.duplicate()
				if (
					value is Array
					or value is PackedByteArray
					or value is PackedInt32Array
					or value is PackedInt64Array
				)
				else value
			)
		model.apply_source_chunk(coordinate, stored, version)
		source_revisions[coordinate] = version
	for xyz: Vector3i in present:
		var edit_version: int = present[xyz].revision
		if edit_revisions.get(xyz, -1) != edit_version or not model.chunks.has(xyz):
			model.apply_edit_chunk(xyz, present[xyz].values.duplicate())
			edit_revisions[xyz] = edit_version
	for xyz: Vector3i in model.chunks.keys():
		if (
			Vector2i(floori(xyz.x / 2.0), floori(xyz.y / 2.0)) == coordinate
			and not present.has(xyz)
		):
			model.remove_edit_chunk(xyz)
			edit_revisions.erase(xyz)
	return true


func evict(coordinate: Vector2i) -> void:
	source_revisions.erase(coordinate)
	for xyz: Vector3i in edit_revisions.keys():
		if Vector2i(floori(xyz.x / 2.0), floori(xyz.y / 2.0)) == coordinate:
			edit_revisions.erase(xyz)
