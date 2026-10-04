## 256 real adapter acknowledgements must schedule one authored-frame render.
extends Node
const Wire = preload("res://tools/large_map_wire_test.gd")
var failures := 0


func check(value: bool, message: String) -> void:
	if not value:
		failures += 1
		push_error(message)


func _ready() -> void:
	call_deferred("run")


func run() -> void:
	var local := preload("res://tools/terrain_fixture.gd").database()
	local._tables["terrain_chunk"].clear()
	local._tables["world_geometry"][0].width = 2048
	local._tables["world_geometry"][0].height = 2048
	var db := Wire.ExtendedDb.new(local)
	db.world_generation.values = [
		{
			"generation_id": 9,
			"storage_version": 1,
			"width": 2048,
			"height": 2048,
			"min_z": -16,
			"max_z": 15,
			"starter_x": 1012,
			"starter_y": 1012,
			"phase": 5,
			"ready": true,
			"error": ""
		}
	]
	var client := Wire.Client.new()
	client.db = db
	var previous := SpacetimeDB.Continuum.db
	SpacetimeDB.Continuum.db = db
	var map := ColonyMap.new()
	map.size = Vector2(1280, 720)
	add_child(map)
	map.set_process(false)
	var session := LargeWorldSession.new()
	session.attach(map)
	session.overview.target_samples = 65536
	session.start(client, 1)
	map.refresh()
	map.fit_camera()
	map.terrain_model.presentation_mode = &"overview"
	session.overview.request_frame(Rect2i(0, 0, 2048, 2048), 0.25, 0)
	var heights := PackedInt32Array()
	heights.resize(256)
	heights.fill(-1)
	var materials := PackedInt32Array()
	materials.resize(256)
	materials.fill(1)
	var ecology := PackedByteArray()
	ecology.resize(256)
	for y in 16:
		for x in 16:
			db.terrain_overview_chunk.values.append(
				{
					"generation_id": 9,
					"revision": 0,
					"lod": 3,
					"cut_z": 0,
					"chunk_x": x,
					"chunk_y": y,
					"surface_z": heights,
					"material": materials,
					"soil_fertility": ecology,
					"forest_density": ecology,
					"moisture": ecology
				}
			)
	var baseline := session.rendered_frames
	var physical := Vector2i(map.terrain_model.query_count, map.terrain_model.voxel_query_count)
	var start := Time.get_ticks_usec()
	var index := 0
	while index < client.handles.size():
		client.handles[index].applied.emit()
		index += 1
	var elapsed := Time.get_ticks_usec() - start
	check(
		index == 256 and session.overview.rows.size() == 256,
		"all 256 overview acknowledgements installed bounded rows"
	)
	check(
		session.rendered_frames == baseline,
		"burst does not synchronously rebuild any 65536-sample frames"
	)
	await get_tree().process_frame
	check(
		session.rendered_frames == baseline + 1 and map.terrain_view.pending_samples == 0,
		"one deferred frame consumes the full burst without pending samples"
	)
	check(
		Vector2i(map.terrain_model.query_count, map.terrain_model.voxel_query_count) == physical,
		"overview burst never samples physical world"
	)
	var snapshots := session.overview.snapshot_count
	session._camera_dirty = false
	session.mark_changed("terrain_overview_chunk", db.terrain_overview_chunk.iter()[0])
	session.tick(0.0)
	check(
		session.overview.snapshot_count == snapshots + 1,
		"one row event reconciles one resident coordinate, not all 256"
	)
	print(
		(
			"OVERVIEW_BURST_%s acks=%d frames=%d synchronous_usec=%d"
			% [
				"PASS" if failures == 0 else "FAIL",
				index,
				session.rendered_frames - baseline,
				elapsed
			]
		)
	)
	await get_tree().process_frame
	var removed: Variant = db.terrain_overview_chunk.iter()[0]
	db.terrain_overview_chunk.values.remove_at(0)
	session.overview._stream._entries[Vector2i(15, 15)].applied = false
	session._overview_render_rows = 240
	var before_loss := session.rendered_frames
	session.mark_changed("terrain_overview_chunk", removed)
	session.tick(0.0)
	await get_tree().process_frame
	check(
		session.rendered_frames == before_loss + 1 and map.terrain_view.pending_samples > 0,
		"lost overview coverage renders pending immediately even during a partial growth batch"
	)
	print(
		(
			"OVERVIEW_INVALIDATION_%s frames=%d pending=%d"
			% [
				"PASS" if failures == 0 else "FAIL",
				session.rendered_frames - before_loss,
				map.terrain_view.pending_samples
			]
		)
	)
	session.stop()
	for handle in client.handles:
		handle.end.emit()
		handle.free()
	session.dispose()
	map.free()
	local.free()
	await get_tree().process_frame
	SpacetimeDB.Continuum.db = previous
	get_tree().quit(0 if failures == 0 else 1)
