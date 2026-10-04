extends Node
const Wire = preload("res://tools/large_map_wire_test.gd")
var failures := 0
var assertions := 0


func check(value: bool, message: String) -> void:
	assertions += 1
	if not value:
		failures += 1
		push_error(message)


func _ready() -> void:
	call_deferred("run")


func run() -> void:
	var fixture := Wire.new()
	var a: Dictionary = fixture.source(Vector2i.ZERO)
	var b: Dictionary = fixture.source(Vector2i(1, 0))
	fixture.free()
	for key in ["soil_fertility", "forest_density", "moisture"]:
		a[key] = a[key].duplicate()
		a[key].fill(255 if key == "soil_fertility" else (128 if key == "forest_density" else 64))
	var model := LayeredTerrainModel.new()
	model.set_geometry({"width": 2048, "height": 2048, "min_z": -16, "max_z": 15})
	model.set_materials(
		[{"id": 0, "opaque": false}, {"id": 1, "opaque": true}, {"id": 2, "opaque": true}]
	)
	model.configure_sources(32, CompactTerrainAdapter.read_material)
	model.apply_source_chunk(Vector2i.ZERO, a, 1)
	model.set_chunk_complete(Vector2i.ZERO, true)
	var xy := Vector2i(8, 8)
	var picked := model.capture_selection(Rect2i(xy, Vector2i.ONE))
	var queries := model.query_count
	model.apply_source_chunk(Vector2i(1, 0), b, 1)
	model.set_chunk_complete(Vector2i(1, 0), true)
	check(
		(
			model.surface_at(xy) == Vector3i(8, 8, -1)
			and model.query_count == queries
			and model.selection_valid(picked)
		),
		"unrelated source acknowledgement preserves cached ray and ready selection"
	)
	var revision := model.revision
	var exposure := model.exposure_revision
	model.set_chunk_complete(Vector2i.ZERO, true)
	model.apply_source_chunk(Vector2i.ZERO, a, 1)
	check(
		model.revision == revision and model.exposure_revision == exposure,
		"no-op completeness/source does not invalidate resident exposure"
	)
	var sample: Dictionary = model.render_frame(Rect2i(xy, Vector2i.ONE)).samples[xy]
	check(
		(
			sample.soil_fertility == 1.0
			and is_equal_approx(sample.forest_density, 128.0 / 255.0)
			and is_equal_approx(sample.moisture, 64.0 / 255.0)
		),
		"exact authored frame preserves optional normalized source ecology"
	)
	var other := Vector2i(40, 8)
	model.surface_at(other)
	queries = model.query_count
	var air := PackedByteArray()
	air.resize(4096)
	model.apply_edit_chunk(Vector3i(0, 0, -1), air)
	check(
		model.surface_at(other) == Vector3i(40, 8, -1) and model.query_count == queries,
		"edit invalidates only its horizontal 16-cell footprint"
	)
	sample = model.render_frame(Rect2i(xy, Vector2i.ONE)).samples[xy]
	check(
		(
			sample.known
			and sample.material == 0
			and not sample.has("soil_fertility")
			and not sample.has("moisture")
		),
		"resolved-empty frame does not invent ecology"
	)
	revision = model.revision
	model.apply_edit_chunk(Vector3i(0, 0, -1), air.duplicate())
	check(model.revision == revision, "identical edit bytes do not invalidate exposure")
	model.remove_edit_chunk(Vector3i(0, 0, -1))
	check(model.surface_at(xy) == Vector3i(8, 8, -1), "edit removal resolves real baseline")
	model.set_chunk_complete(Vector2i.ZERO, false)
	sample = model.render_frame(Rect2i(xy, Vector2i.ONE)).samples[xy]
	check(
		not sample.known and not sample.has("soil_fertility"),
		"pending coverage has no ecological metadata"
	)
	queries = model.query_count
	model.evict_source_chunk(Vector2i.ZERO)
	check(
		model.surface_at(other) == Vector3i(40, 8, -1) and model.query_count == queries,
		"source eviction preserves unrelated cached ray"
	)
	var cache := TerrainOverviewCache.new()
	var client := Wire.Client.new()
	cache.attach(client, model, 1, 9)
	cache.request_frame(model.bounds(), 0.25, 0)
	var frame := cache.frame_samples(model.bounds(), 0, 65536)
	check(
		cache.lod == 5 and frame.samples.size() == 4096 and cache._stream._wanted.size() == 16,
		"ordinary 2048 Fit chooses existing authored LOD5, not hard-cap 256-row LOD3"
	)
	var stream := TerrainStream.new()
	stream.attach(
		client,
		model,
		1,
		9,
		CompactTerrainAdapter.detail_queries,
		func(_model: Variant, _coordinate: Variant, _client: Variant, _generation: Variant) -> bool:
			return true
	)
	stream.request_frame(Rect2i(0, 0, 300, 32), 4.0, 0)
	check(
		stream.mode == &"overview" and stream.resident_count() == 0,
		"ultrawide short area chooses overview despite fitting the sample/residency ceilings"
	)
	stream.request_frame(Rect2i(0, 0, 32, 300), 4.0, 0)
	check(stream.mode == &"overview", "tall short area respects renderer axis limit symmetrically")
	stream.request_frame(Rect2i(0, 0, 256, 256), 4.0, 0)
	check(
		stream.mode == &"detail" and stream.outstanding_count() <= 4,
		"256-axis/65536-sample boundary remains exact detail"
	)
	client.online = false
	stream.dispose()
	cache.dispose()
	for handle in client.handles:
		handle.free()
	print(
		"TERRAIN_LOCAL_CACHE_%s assertions=%d" % ["PASS" if failures == 0 else "FAIL", assertions]
	)
	get_tree().quit(0 if failures == 0 else 1)
