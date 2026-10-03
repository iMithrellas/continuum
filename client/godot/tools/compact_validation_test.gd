## Strict normalized boundaries and atomic authored-snapshot reconciliation.
extends Node
const Wire = preload("res://tools/large_map_wire_test.gd")
var assertions := 0
var failures := 0

func check(value: bool, message: String) -> void:
	assertions += 1
	if not value:
		failures += 1
		push_error(message)

func _ready() -> void:
	call_deferred("run")

func run() -> void:
	var fixture := Wire.new()
	var source: Dictionary = fixture.source(Vector2i.ZERO, 2)
	fixture.free()
	check(CompactTerrainAdapter.valid_source(source, 9), "valid stored source")
	for key in ["generation_id", "revision", "chunk_x", "chunk_y"]:
		var bad := source.duplicate(true)
		bad.erase(key)
		check(not CompactTerrainAdapter.valid_source(bad, 9), "required " + key)
		bad = source.duplicate(true)
		bad[key] = 0.5
		check(not CompactTerrainAdapter.valid_source(bad, 9), "exact integer " + key)
	for key in ["base_z", "soil_depth", "soil_fertility", "forest_density", "moisture"]:
		for invalid in [-32769 if key == "base_z" else -1, 32768 if key == "base_z" else 256, 0.5]:
			var bad := source.duplicate(true)
			bad[key] = Array(bad[key])
			bad[key][0] = invalid
			check(not CompactTerrainAdapter.valid_source(bad, 9), "reject out-of-range/type " + key)
	var local := preload("res://tools/terrain_fixture.gd").database(false)
	var db := Wire.NormalizedDb.new(local)
	var client := Wire.Client.new()
	client.db = db
	var model := LayeredTerrainModel.new()
	model.configure_sources(32, CompactTerrainAdapter.read_material)
	model.set_geometry({"width": 2048, "height": 2048, "min_z": -16, "max_z": 15})
	model.set_materials([{"id": 0, "opaque": false}, {"id": 1, "opaque": true}, {"id": 2, "opaque": true}])
	var adapter := CompactTerrainAdapter.new()
	db.terrain_column_chunk.values = [source]
	check(adapter.snapshot(model, Vector2i.ZERO, client, 9), "install source revision two")
	model.set_chunk_complete(Vector2i.ZERO, true)
	var source_authority := model.revision
	var source_exposure := model.exposure_revision
	var installed_source: Dictionary = model.source_chunks.duplicate(true)
	var installed_revisions := adapter.source_revisions.duplicate()
	for key in ["generation_id", "revision", "chunk_x", "chunk_y"]:
		var outside: int = -1 if key == "generation_id" else (4294967296 if key == "revision" else 2147483648)
		for value: Variant in [true, "0", null, 0.5, outside]:
			var bad := source.duplicate(true)
			bad[key] = value
			db.terrain_column_chunk.values = [bad]
			check(not adapter.snapshot(model, Vector2i.ZERO, client, 9)
				and model.revision == source_authority and model.exposure_revision == source_exposure
				and model.source_chunks == installed_source and adapter.source_revisions == installed_revisions
				and model._complete_sources.get(Vector2i.ZERO, false), "source boundary rejects metadata atomically " + key)
	db.terrain_column_chunk.values = [{"chunk_x": 1, "chunk_y": 0}, source]
	check(adapter.snapshot(model, Vector2i.ZERO, client, 9), "source selector skips unrelated payload validation")
	db.terrain_column_chunk.values = [source]
	var edit := ContinuumTerrainChunk.new()
	edit.id = 1
	edit.chunk_z = -1
	edit.revision = 3
	edit.materials.resize(4096)
	edit.materials.fill(0)
	local._tables["terrain_chunk"][1] = edit
	check(adapter.snapshot(model, Vector2i.ZERO, client, 9) and model.column_state(Vector2i.ZERO) == &"resolved_empty", "acknowledged complete air overrides baseline")
	edit.materials[0] = 999
	check(model.material_at(Vector3i(0, 0, -16)) == 0 and not adapter.snapshot(model, Vector2i.ZERO, client, 9),
		"mutable typed row cannot change installed edit bytes before snapshot validation")
	edit.materials[0] = 0
	var authority := model.revision
	var changed := source.duplicate(true)
	changed.revision = 4
	changed.base_z.fill(4)
	db.terrain_column_chunk.values = [changed]
	var old_edit := edit.duplicate(true)
	old_edit.revision = 2
	old_edit.materials.fill(2)
	local._tables["terrain_chunk"][1] = old_edit
	check(not adapter.snapshot(model, Vector2i.ZERO, client, 9) and model.revision == authority and model.source_chunks[Vector2i.ZERO].revision == 2,
		"stale edit rejects entire snapshot including newer source atomically")
	local._tables["terrain_chunk"][1] = edit
	var old_source := source.duplicate(true)
	old_source.revision = 1
	db.terrain_column_chunk.values = [old_source]
	check(not adapter.snapshot(model, Vector2i.ZERO, client, 9) and model.revision == authority, "older source cannot roll back resident data")
	db.terrain_column_chunk.values = [source]
	var invalid_edit := edit.duplicate(true)
	invalid_edit.revision = 4
	invalid_edit.materials[0] = 999
	local._tables["terrain_chunk"][1] = invalid_edit
	check(not adapter.snapshot(model, Vector2i.ZERO, client, 9) and model.revision == authority, "unknown material rejects entire edit snapshot")
	local._tables["terrain_chunk"].clear()
	check(adapter.snapshot(model, Vector2i.ZERO, client, 9) and model.surface_at(Vector2i.ZERO) == Vector3i(0, 0, -1), "acknowledged absent edit restores baseline")
	source.base_z[0] = 6
	source.soil_depth[0] = 255
	check(model.material_at(Vector3i.ZERO) == 0 and model.material_at(Vector3i(0, 0, -4)) == 2,
		"packed source arrays are detached from mutable normalized rows")
	source.base_z[0] = 0
	source.soil_depth[0] = 3
	var cache := TerrainOverviewCache.new()
	cache.attach(client, model, 1, 9)
	var overview := {"generation_id": 9, "revision": 2, "lod": 3, "cut_z": 0, "chunk_x": 0, "chunk_y": 0}
	for key in ["surface_z", "material", "soil_fertility", "forest_density", "moisture"]:
		var values := PackedInt32Array()
		values.resize(256)
		values.fill(-1 if key == "surface_z" else (1 if key == "material" else 0))
		overview[key] = values
	db.terrain_overview_chunk.values = [overview]
	check(cache._snapshot(model, Vector2i.ZERO, client, 9), "valid overview revision two")
	var overview_authority := cache.revision
	var installed_overview: Dictionary = cache.rows.duplicate(true)
	var overview_revisions := cache._row_revisions.duplicate()
	for key in ["generation_id", "revision", "lod", "cut_z", "chunk_x", "chunk_y"]:
		var outside: int = -1 if key == "generation_id" else (4294967296 if key == "revision" else (256 if key == "lod" else (16 if key == "cut_z" else 2147483648)))
		for value: Variant in [true, "0", null, 0.5, outside]:
			var bad := overview.duplicate(true)
			bad[key] = value
			db.terrain_overview_chunk.values = [bad]
			check(not cache._snapshot(model, Vector2i.ZERO, client, 9) and cache.revision == overview_authority
				and cache.rows == installed_overview and cache._row_revisions == overview_revisions,
				"overview boundary rejects metadata atomically " + key)
	db.terrain_overview_chunk.values = [{"generation_id": 9, "lod": 3, "cut_z": 0, "chunk_x": 1, "chunk_y": 0}, overview]
	check(cache._snapshot(model, Vector2i.ZERO, client, 9), "overview selector skips unrelated payload validation")
	overview.surface_z[0] = 0
	check(cache.rows[Vector2i.ZERO].surface_z[0] == -1, "packed overview arrays cannot mutate installed representatives")
	overview.surface_z[0] = -1
	for key in ["generation_id", "revision", "lod", "cut_z", "chunk_x", "chunk_y"]:
		var bad := overview.duplicate(true)
		bad[key] = float(bad[key])
		db.terrain_overview_chunk.values = [bad]
		check(not cache._snapshot(model, Vector2i.ZERO, client, 9), "overview exact metadata " + key)
	var old_overview := overview.duplicate(true)
	old_overview.revision = 1
	db.terrain_overview_chunk.values = [old_overview]
	check(not cache._snapshot(model, Vector2i.ZERO, client, 9) and cache.rows[Vector2i.ZERO].revision == 2, "overview rollback rejected")
	for variant in 4:
		var bad := overview.duplicate(true)
		bad.revision = 3
		match variant:
			0: bad.surface_z[0] = 1
			1: bad.material[0] = 999
			2: bad.material[0] = 0
			3: bad.moisture[0] = 256
		db.terrain_overview_chunk.values = [bad]
		check(not cache._snapshot(model, Vector2i.ZERO, client, 9), "overview rejects cut/registry/sentinel/ecology variant %d" % variant)
	db.terrain_overview_chunk.values = [overview]
	cache.request_frame(Rect2i(0, 0, 128, 128), 1.0, 0)
	client.handles[-1].applied.emit()
	var changes := [0]
	cache.changed.connect(func() -> void: changes[0] += 1)
	db.terrain_overview_chunk.values.clear()
	cache.refresh()
	check(not cache.rows.has(Vector2i.ZERO) and cache.frame_samples(Rect2i(0, 0, 8, 8), 0, 1).samples[0].state == &"pending" and changes[0] == 1,
		"deleted acknowledged overview invalidates visual row and emits dirty signal")
	db.terrain_overview_chunk.values = [overview]
	cache.refresh()
	check(cache.rows.has(Vector2i.ZERO), "valid current overview can restore invalidated row")
	for key in ["generation_id", "revision", "lod", "cut_z", "chunk_x", "chunk_y"]:
		for value: Variant in [true, "0", null, 0.5, 9223372036854775807]:
			var bad := overview.duplicate(true)
			bad[key] = value
			db.terrain_overview_chunk.values = [bad]
			cache.refresh()
			check(not cache.rows.has(Vector2i.ZERO)
				and cache.frame_samples(Rect2i(0, 0, 8, 8), 0, 1).samples[0].state == &"pending"
				and cache._row_revisions[Vector2i.ZERO] == 2, "bad metadata refresh revokes overview coverage " + key)
			db.terrain_overview_chunk.values = [overview]
			cache.refresh()
			check(cache.rows.has(Vector2i.ZERO), "valid metadata restores overview after rejected refresh")
	var malformed := overview.duplicate(true)
	malformed.material.resize(255)
	db.terrain_overview_chunk.values = [malformed]
	cache.refresh()
	check(not cache.rows.has(Vector2i.ZERO), "malformed refreshed overview cannot retain old drawable data")
	db.terrain_overview_chunk.values = [old_overview]
	cache.refresh()
	check(not cache.rows.has(Vector2i.ZERO), "invalidated row retains revision high-water until subscription eviction")
	cache.stop()
	for handle in client.handles:
		handle.free()
	model.set_geometry({"width": 20, "height": 20, "min_z": -16, "max_z": 15})
	db.terrain_column_chunk.values = [source]
	check(not adapter.snapshot(model, Vector2i.ZERO, client, 9), "source rejects noncanonical out-of-bounds padding")
	var padded := source.duplicate(true)
	padded.revision = 4
	for index in 1024:
		if index % 32 >= 20 or index / 32 >= 20:
			padded.base_z[index] = -16
			for key in ["soil_depth", "soil_fertility", "forest_density", "moisture"]:
				padded[key][index] = 0
	db.terrain_column_chunk.values = [padded]
	check(adapter.snapshot(model, Vector2i.ZERO, client, 9), "source accepts min_z/zero canonical rectangular padding")
	local.free()
	print("COMPACT_VALIDATION_%s assertions=%d" % ["PASS" if failures == 0 else "FAIL", assertions])
	get_tree().quit(0 if failures == 0 else 1)
