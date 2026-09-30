## Repeatable backend-free CPU/render benchmark; never connects to a server.
## godot --headless --path client/godot res://tools/map_client_profile.tscn -- --edge=128
extends Node

const Fixture = preload("res://tools/terrain_fixture.gd")
var edge := 24

func measure(label: String, count: int, action: Callable) -> void:
	var samples: Array[float] = []
	for i in count:
		var start := Time.get_ticks_usec()
		action.call()
		samples.append((Time.get_ticks_usec() - start) / 1000.0)
	samples.sort()
	var total := 0.0
	for sample in samples:
		total += sample
	print("PROFILE %s n=%d mean_ms=%.3f p95_ms=%.3f max_ms=%.3f" % [label, count, total / count, samples[mini(count - 1, floori(count * 0.95))], samples.back()])

func database(include_empty_tiles := true) -> LocalDatabase:
	var local := Fixture.database(false)
	var geometry := ContinuumWorldGeometry.new()
	geometry.width = edge
	geometry.height = edge
	geometry.min_z = -16
	geometry.max_z = 15
	local._tables["world_geometry"][0] = geometry
	local._tables["config"][0] = ContinuumConfig.create(0, 0, 6, 1, ContinuumHaulPolicy.create(0), ContinuumMealPolicy.create(0))
	var colony := ContinuumColony.new()
	colony.wood = 10000
	local._tables["colony"][0] = colony
	for id in 3:
		var material := ContinuumTerrainMaterial.new()
		material.id = id
		material.name = ["air", "soil", "stone"][id]
		material.opaque = id != 0
		local._tables["terrain_material"][id] = material
	var chunk_id := 0
	for cy in ceili(edge / 16.0):
		for cx in ceili(edge / 16.0):
			for cz in [-1, 0]:
				var chunk := ContinuumTerrainChunk.new()
				chunk.id = chunk_id
				chunk_id += 1
				chunk.chunk_x = cx
				chunk.chunk_y = cy
				chunk.chunk_z = cz
				chunk.revision = 1
				chunk.materials.resize(4096)
				chunk.materials.fill(0)
				if cz == -1:
					for y in 16:
						for x in 16:
							var shaft := cx * 16 + x >= edge / 2 and cy * 16 + y >= edge / 2
							chunk.materials[x + 16 * (y + 16 * (7 if shaft else 15))] = 2 if shaft else 1
				local._tables["terrain_chunk"][chunk.id] = chunk
	if include_empty_tiles:
		for y in edge:
			for x in edge:
				var id := x + y * edge
				var z := -8 if x >= edge / 2 and y >= edge / 2 else 0
				local._tables["tile"][id] = ContinuumTile.create(id, x, y, ContinuumTileKind.create_empty(), true, z, 1, 1, 6)
	for id in 8:
		var actor := ContinuumColonist.new()
		actor.id = id
		actor.x = edge / 2 + id
		actor.y = edge / 2
		actor.z = -8
		actor.next_x = actor.x
		actor.next_y = actor.y
		actor.next_z = actor.z
		actor.target_x = actor.x
		actor.target_y = actor.y
		actor.target_z = actor.z
		actor.body_width = 1
		actor.body_depth = 1
		actor.carried_kind = ContinuumResourceKind.create_wood()
		actor.activity = ContinuumActivity.create(0)
		actor.work = ContinuumWorkType.create(0)
		actor.goal = ContinuumGoal.create(0)
		actor.haul_role = ContinuumHaulRole.create(0)
		local._tables["colonist"][id] = actor
	Fixture.index_rows(local)
	return local

func _ready() -> void:
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--edge="):
			edge = int(arg.trim_prefix("--edge="))
	var previous := SpacetimeDB.Continuum.db
	var local := database()
	var viewport := SubViewport.new()
	viewport.size = Vector2i(1280, 720)
	viewport.disable_3d = true
	viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	add_child(viewport)
	var map := ColonyMap.new()
	map.size = Vector2(viewport.size)
	viewport.add_child(map)
	map.set_process(false)
	print("PROFILE environment godot=%s display=%s edge=%d viewport=%s" % [Engine.get_version_info().string, DisplayServer.get_name(), edge, viewport.size])
	measure("initial_refresh", 1, map.refresh)
	measure("unchanged_refresh", 5, map.refresh)
	if map.has_method("_cache_tiles"):
		measure("ordinary_tick_refresh", 30, func() -> void: map.refresh({"colony": true, "config": true, "colonist": true}))
	measure("entity_descriptors", 6 if edge > 24 else 30, map.entity_descriptors)
	measure("visible_tiles", 6 if edge > 24 else 30, map.visible_tiles)
	measure("field_1000", 10, func() -> void:
		for i in 1000:
			LayeredTerrainModel.field(local._tables["colonist"][0], "next_z", 0))
	measure("idle_process", 180, func() -> void: map._process(1.0 / 60.0))
	var actor: ContinuumColonist = local._tables["colonist"][0]
	actor.next_x += 1
	measure("moving_process", 10 if edge > 24 else 180, func() -> void:
		actor.move_progress = fmod(actor.move_progress + 0.005, 1.0)
		map._process(1.0 / 60.0))
	var maximum := Vector2i.ZERO
	for pass_view in map.terrain_view.viewports:
		maximum.x = maxi(maximum.x, pass_view.size.x)
		maximum.y = maxi(maximum.y, pass_view.size.y)
	print("PROFILE max_entity_buffer=%s bands=%d terrain_textures=%d" % [maximum, map.terrain_view.viewports.size(), map.terrain_view.layers.filter(func(layer: TextureRect) -> bool: return layer.texture != null).size()])
	if DisplayServer.get_name() != "headless":
		var frame_times: Array[float] = []
		for frame in 180:
			var start := Time.get_ticks_usec()
			await RenderingServer.frame_post_draw
			frame_times.append((Time.get_ticks_usec() - start) / 1000.0)
		frame_times.sort()
		print("PROFILE idle_gpu_frame n=180 p50_ms=%.3f p95_ms=%.3f max_ms=%.3f" % [frame_times[90], frame_times[171], frame_times.back()])
	print("MAP_CLIENT_PROFILE_DONE")
	SpacetimeDB.Continuum.db = previous
	viewport.free()
	local.free()
	get_tree().quit()
