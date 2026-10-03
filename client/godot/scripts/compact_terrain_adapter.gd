## Decodes persisted storage-version-1 columns; does not generate terrain.
class_name CompactTerrainAdapter
extends RefCounted

const SOURCE_EDGE := 32
const OVERVIEW_EDGE := 16
const LODS := [3, 5, 7, 9]
var source_revisions: Dictionary = {}
var edit_revisions: Dictionary = {}

static func valid_source(row: Variant, generation: int) -> bool:
	if int(LayeredTerrainModel.field(row, "generation_id", -1)) != generation:
		return false
	for key in ["base_z", "soil_depth", "soil_fertility", "forest_density", "moisture"]:
		var values: Variant = LayeredTerrainModel.field(row, key, [])
		if values.size() != 1024:
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
	return PackedStringArray([
		"SELECT * FROM terrain_column_chunk WHERE chunk_x = %d AND chunk_y = %d AND generation_id = %d" % [coordinate.x, coordinate.y, generation],
		"SELECT * FROM terrain_chunk WHERE chunk_x >= %d AND chunk_x < %d AND chunk_y >= %d AND chunk_y < %d" % [coordinate.x * 2, coordinate.x * 2 + 2, coordinate.y * 2, coordinate.y * 2 + 2]])

func snapshot(model: LayeredTerrainModel, coordinate: Vector2i, client: Variant, generation: int) -> bool:
	var found: Variant = null
	for row in ColonyMap.table_rows(client.db, "terrain_column_chunk"):
		if int(LayeredTerrainModel.field(row, "chunk_x")) == coordinate.x and int(LayeredTerrainModel.field(row, "chunk_y")) == coordinate.y:
			found = row
			break
	if found == null or not valid_source(found, generation):
		return false
	var version := int(LayeredTerrainModel.field(found, "revision", 0))
	if source_revisions.get(coordinate, -1) != version or not model.source_chunks.has(coordinate):
		model.apply_source_chunk(coordinate, found, version)
		source_revisions[coordinate] = version
	var present := {}
	for row in ColonyMap.table_rows(client.db, "terrain_chunk"):
		var xyz := Vector3i(LayeredTerrainModel.field(row, "chunk_x", 0), LayeredTerrainModel.field(row, "chunk_y", 0), LayeredTerrainModel.field(row, "chunk_z", 0))
		if Vector2i(floori(xyz.x / 2.0), floori(xyz.y / 2.0)) != coordinate:
			continue
		var values: Variant = LayeredTerrainModel.field(row, "materials", [])
		if values.size() != 4096:
			return false
		present[xyz] = true
		var edit_version := int(LayeredTerrainModel.field(row, "revision", 0))
		if edit_revisions.get(xyz, -1) != edit_version or not model.chunks.has(xyz):
			model.apply_edit_chunk(xyz, values)
			edit_revisions[xyz] = edit_version
	for xyz: Vector3i in model.chunks.keys():
		if Vector2i(floori(xyz.x / 2.0), floori(xyz.y / 2.0)) == coordinate and not present.has(xyz):
			model.remove_edit_chunk(xyz)
			edit_revisions.erase(xyz)
	return true

func evict(coordinate: Vector2i) -> void:
	source_revisions.erase(coordinate)
	for xyz: Vector3i in edit_revisions.keys():
		if Vector2i(floori(xyz.x / 2.0), floori(xyz.y / 2.0)) == coordinate:
			edit_revisions.erase(xyz)
