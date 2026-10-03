## Reproducible, physically varied generated-row landscape for renderer evidence.
## Heights/materials live in real voxel rows; rendering never synthesizes geometry.
extends RefCounted

static func height_at(x: int, y: int, edge: int) -> int:
	var p := Vector2(x - edge / 2, y - edge / 2)
	if absf(p.x) < 15 and absf(p.y) < 12:
		return -1
	var ridge := sin(p.x * 0.072) * 3.0 + cos(p.y * 0.081) * 2.0 + sin((p.x + p.y) * 0.043) * 2.0
	return clampi(-4 + floori(ridge), -11, -1)

static func material_at(x: int, y: int, edge: int) -> int:
	var p := Vector2(x - edge / 2, y - edge / 2)
	var seam := sin(p.y * 0.16) * 4.0 + 10.0
	return 2 if p.x > seam or sin(p.x * 0.044 + 1.3) + cos(p.y * 0.056) < -0.8 else 1

static func database(edge := 128) -> LocalDatabase:
	var fixture = preload("res://tools/terrain_fixture.gd")
	var local: LocalDatabase = fixture.database(false)
	var geometry := ContinuumWorldGeometry.new()
	geometry.width = edge
	geometry.height = edge
	geometry.min_z = -16
	geometry.max_z = 15
	local._tables["world_geometry"][0] = geometry
	for id in 3:
		var material := ContinuumTerrainMaterial.new()
		material.id = id
		material.name = ["air", "soil", "stone"][id]
		material.opaque = id != 0
		local._tables["terrain_material"][id] = material
	for cy in ceili(edge / 16.0):
		for cx in ceili(edge / 16.0):
			for cz in [-1, 0]:
				var chunk := ContinuumTerrainChunk.new()
				chunk.id = local._tables["terrain_chunk"].size()
				chunk.chunk_x = cx
				chunk.chunk_y = cy
				chunk.chunk_z = cz
				chunk.revision = 1
				chunk.materials.resize(4096)
				chunk.materials.fill(0)
				if cz == -1:
					for y in 16:
						for x in 16:
							var wx := cx * 16 + x
							var wy := cy * 16 + y
							var height := height_at(wx, wy, edge)
							for z in range(-16, height + 1):
								chunk.materials[x + 16 * (y + 16 * (z + 16))] = material_at(wx, wy, edge) if z >= height - 1 else 2
				local._tables["terrain_chunk"][chunk.id] = chunk
	var c := Vector2i.ONE * (edge / 2)
	var sites := [[Vector2i(-9, -5), Vector2i(5, 4), ContinuumTileKind.Options.farm],
		[Vector2i(-9, 1), Vector2i(4, 3), ContinuumTileKind.Options.farm],
		[Vector2i(-2, -4), Vector2i(3, 2), ContinuumTileKind.Options.dining],
		[Vector2i(-2, 1), Vector2i(3, 2), ContinuumTileKind.Options.sleep],
		[Vector2i(3, 1), Vector2i(3, 3), ContinuumTileKind.Options.storage],
		[Vector2i(3, -5), Vector2i(3, 2), ContinuumTileKind.Options.recreation],
		[Vector2i(10, -4), Vector2i(3, 3), ContinuumTileKind.Options.mine]]
	for site in sites:
		for yy in site[1].y:
			for xx in site[1].x:
				var p: Vector2i = c + site[0] + Vector2i(xx, yy)
				var id: int = local._tables["tile"].size()
				local._tables["tile"][id] = ContinuumTile.create(id, p.x, p.y, ContinuumTileKind.create(site[2]), true, height_at(p.x, p.y, edge) + 1, 1, 1, 6)
	for y in range(c.y - 25, c.y + 25):
		for x in range(c.x - 34, c.x + 22):
			if (x * 43 + y * 71) % 11 > 3 or (abs(x - c.x) < 15 and abs(y - c.y) < 12) or material_at(x, y, edge) == 2:
				continue
			var id: int = local._tables["tile"].size()
			local._tables["tile"][id] = ContinuumTile.create(id, x, y, ContinuumTileKind.create_forest(), true, height_at(x, y, edge) + 1, 1, 1, 6)
	for id in 12:
		var actor := ContinuumColonist.new()
		actor.id = id
		actor.name = ["Ada", "Ivo", "Mara", "Sol"][id % 4]
		actor.x = c.x - 8 + id
		actor.y = c.y - 1 + id % 3
		actor.z = 0
		actor.next_x = actor.x
		actor.next_y = actor.y
		actor.next_z = actor.z
		actor.target_x = actor.x
		actor.target_y = actor.y
		actor.target_z = actor.z
		actor.body_width = 1
		actor.body_depth = 1
		actor.activity = ContinuumActivity.create(0)
		actor.work = ContinuumWorkType.create(0)
		actor.goal = ContinuumGoal.create(0)
		actor.haul_role = ContinuumHaulRole.create(0)
		actor.carried_kind = ContinuumResourceKind.create_wood()
		actor.carried_amount = 2.0 if id % 3 == 0 else 0.0
		local._tables["colonist"][id] = actor
	fixture.index_rows(local)
	return local

## Staged sparse-cache contract for renderer-only 2048 evidence. This expands a
## loaded 128² generated-row patch into 2048² logical bounds and translates ALL
## rows/cache coordinates together. It does not invoke the old dense model's
## whole-bounds rebuild; production streaming/cache population is owned elsewhere.
static func expand_sparse_snapshot(map: ColonyMap, local: LocalDatabase, logical_edge: int) -> void:
	var model := map.terrain_model
	var offset := Vector2i.ONE * ((logical_edge - model.width) / 2)
	assert(offset.x % 16 == 0)
	var delta := Vector3i(offset.x, offset.y, 0)
	local._tables["world_geometry"][0].width = logical_edge
	local._tables["world_geometry"][0].height = logical_edge
	for table in ["tile", "colonist", "item_stack"]:
		for row in local._tables[table].values():
			row.x += offset.x
			row.y += offset.y
			if row is ContinuumColonist:
				row.next_x += offset.x
				row.next_y += offset.y
				row.target_x += offset.x
				row.target_y += offset.y
	for row in local._tables["terrain_chunk"].values():
		row.chunk_x += offset.x / 16
		row.chunk_y += offset.y / 16
	var chunks := {}
	for key: Vector3i in model.chunks: chunks[key + delta / 16] = model.chunks[key]
	var surfaces := {}
	for xy: Vector2i in model.surfaces: surfaces[xy + offset] = model.surfaces[xy] + delta
	var exposed := {}
	for xy: Vector2i in model._exposed_bottom: exposed[xy + offset] = model._exposed_bottom[xy]
	model.chunks = chunks
	model.surfaces = surfaces
	model._exposed_bottom = exposed
	model.width = logical_edge
	model.height = logical_edge
	model.revision += 1
	map._visual_feet.clear()
	map._visual_motion.clear()
	map.refresh({"tile": true, "colonist": true, "item_stack": true})

## Fixture equivalent of persisted overview rows. Representative values are read
## from the loaded authoritative voxel cache, never generated by the renderer.
## Samples whose source is outside that cache remain explicitly pending.
static func overview_frame(model: LayeredTerrainModel, lod := 3) -> Dictionary:
	var stride := 1 << lod
	var samples := {}
	var bounds := model.bounds()
	for y in range(bounds.position.y, bounds.end.y, stride):
		for x in range(bounds.position.x, bounds.end.x, stride):
			var representative := Vector2i(x + stride / 2, y + stride / 2)
			var surface: Variant = model.surface_at(representative)
			if surface != null:
				samples[Vector2i(x, y)] = {"known": true, "surface_z": surface.z, "material": model.material_at(surface)}
	return {"region": bounds, "stride": stride, "cut": model.cut, "revision": model.revision + lod,
		"mode": "overview", "samples": samples}

static func detail_frame(model: LayeredTerrainModel, region: Rect2i) -> Dictionary:
	var samples := {}
	var halo := region.grow(1)
	for xy: Vector2i in model.surfaces:
		if not halo.has_point(xy): continue
		var surface: Vector3i = model.surfaces[xy]
		samples[xy] = {"known": true, "surface_z": surface.z, "material": model.material_at(surface)}
	return {"region": region, "stride": 1, "cut": model.cut, "revision": model.revision,
		"mode": "detail", "samples": samples}

static func install_camera_frame(map: ColonyMap) -> bool:
	var region := map.visible_grid_rect(2)
	if region.get_area() > 65536 or map._cell_size() < 2.0:
		return map.set_terrain_frame(overview_frame(map.terrain_model))
	return map.set_terrain_frame(detail_frame(map.terrain_model, region))
