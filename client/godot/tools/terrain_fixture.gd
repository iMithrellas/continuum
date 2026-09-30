## In-memory generated rows only. Never connects or calls server reducers.
extends RefCounted

static func database(populate := true) -> LocalDatabase:
	var client := SpacetimeDB.Continuum
	var schema := SpacetimeDBSchema.new("Continuum", "res://spacetime_bindings/schema", false)
	var local := LocalDatabase.new(schema, client)
	client._init_db(local)
	if not populate:
		return local
	var geometry := ContinuumWorldGeometry.new()
	geometry.width = 8
	geometry.height = 4
	geometry.min_z = -16
	geometry.max_z = 15
	local._tables["world_geometry"][0] = geometry
	for id in 3:
		var material := ContinuumTerrainMaterial.new()
		material.id = id
		material.name = ["air", "soil", "stone"][id]
		material.opaque = id != 0
		local._tables["terrain_material"][id] = material
	for chunk_z in [-1, 0]:
		var chunk := ContinuumTerrainChunk.new()
		chunk.id = chunk_z + 2
		chunk.chunk_z = chunk_z
		chunk.materials.resize(4096)
		chunk.materials.fill(0)
		chunk.revision = 1
		if chunk_z == -1:
			for y in 4:
				for x in 8:
					var z := 15 if x < 3 else 7
					chunk.materials[x + 16 * (y + 16 * z)] = 1 if x < 3 else 2
		local._tables["terrain_chunk"][chunk.id] = chunk
	var facility := ContinuumTile.create(1, 3, 0, ContinuumTileKind.create_dining(), true, -8, 2, 1, 12)
	local._tables["tile"][1] = facility
	local._tables["tile"][2] = ContinuumTile.create(2, 1, 0, ContinuumTileKind.create_dining(), true, -8, 1, 1, 4)
	for id in [1, 2, 3]:
		var actor := ContinuumColonist.new()
		actor.id = id
		actor.name = "Worker %d" % id
		actor.x = 5 if id == 2 else 1
		actor.y = 2
		actor.z = 0 if id == 1 else -8
		actor.next_x = actor.x
		actor.next_y = actor.y
		actor.next_z = actor.z
		actor.target_x = actor.x
		actor.target_y = actor.y
		actor.target_z = actor.z
		actor.body_width = 1
		actor.body_depth = 1
		actor.clearance_height = 12
		actor.max_step_height = 1
		actor.activity = ContinuumActivity.create(0)
		actor.work = ContinuumWorkType.create(0)
		actor.haul_role = ContinuumHaulRole.create(0)
		actor.goal = ContinuumGoal.create(0)
		actor.carried_kind = ContinuumResourceKind.create_wood()
		local._tables["colonist"][id] = actor
	var stack := ContinuumItemStack.new()
	stack.id = 1
	stack.x = 6
	stack.y = 2
	stack.z = -8
	stack.kind = ContinuumResourceKind.create_wood()
	stack.amount = 20
	local._tables["item_stack"][1] = stack
	var designation := ContinuumExcavationDesignation.new()
	designation.id = 1
	designation.x_0 = 7
	designation.x_1 = 7
	designation.y_0 = 3
	designation.y_1 = 3
	designation.bottom_z = -9
	designation.height = 6
	designation.enabled = true
	designation.total_cells = 1
	local._tables["excavation_designation"][1] = designation
	index_rows(local)
	return local

static func index_rows(local: LocalDatabase) -> void:
	# Populate generated unique-index caches through their registered listeners,
	# matching subscription application without invoking any server transport.
	for table in local._tables:
		for row in local._tables[table].values():
			for listener: Callable in local._insert_listeners_by_table.get(table, []):
				listener.call(row)
