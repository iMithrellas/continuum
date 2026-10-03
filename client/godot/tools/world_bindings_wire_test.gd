## Isolated real SDK smoke test, never Main or the shared configured endpoint.
extends SceneTree

var client: ContinuumModuleClient
var stage := 0
var deadline := 0

func _initialize() -> void:
	call_deferred("run")

func run() -> void:
	var host := ""
	var database := ""
	for argument in OS.get_cmdline_user_args():
		if argument.begins_with("--stdb-host="):
			host = argument.trim_prefix("--stdb-host=")
		if argument.begins_with("--stdb-db="):
			database = argument.trim_prefix("--stdb-db=")
	assert(not host.is_empty() and not database.is_empty(), "explicit owned runtime required")
	client = ContinuumModuleClient.new()
	client.save_token = false
	client.one_time_token = true
	root.add_child(client)
	client.connected.connect(on_connected)
	client.connection_error.connect(func(_code: int, _reason: String) -> void:
		push_error("private SDK connection failed")
		quit(1))
	deadline = Time.get_ticks_msec() + 30000
	var options := SpacetimeDBConnectionOptions.new()
	options.debug_mode = false
	options.threading = false
	options.save_token = false
	options.one_time_token = true
	client.connect_db(host, database, options)

func on_connected(_identity: PackedByteArray, _token: String) -> void:
	var bootstrap := client.subscribe(PackedStringArray([
		"SELECT * FROM world_generation", "SELECT * FROM world_geometry",
		"SELECT * FROM world_seed", "SELECT * FROM config", "SELECT * FROM colony",
		"SELECT * FROM my_role"]))
	bootstrap.applied.connect(func() -> void: stage = 1)

func _process(_delta: float) -> bool:
	if deadline == 0:
		return false
	if Time.get_ticks_msec() > deadline:
		push_error("private typed SDK wire gate timed out at stage %d" % stage)
		if client != null:
			client.disconnect_db()
		quit(1)
	if stage == 1:
		var state := client.db.world_generation.id.find(0)
		if state == null or not state.ready:
			return false
		assert(state.width == 2048 and state.height == 2048 and state.phase.value == 5)
		assert(state.starter_x == 1012 and state.starter_y == 1012)
		assert(state.completed_chunks == 4096 and state.total_chunks == 4096)
		assert(client.db.my_role.iter().size() == 1)
		assert(client.db.my_role.iter()[0] is ContinuumMembership)
		stage = 2
		var bounded := client.subscribe(PackedStringArray([
			"SELECT * FROM terrain_column_chunk WHERE chunk_x = 32 AND chunk_y = 32",
			"SELECT * FROM terrain_overview_chunk WHERE lod = 3 AND cut_z = -1 AND chunk_x = 8 AND chunk_y = 8",
			"SELECT * FROM terrain_chunk WHERE chunk_x = 64 AND chunk_y = 63 AND chunk_z = 0"]))
		bounded.applied.connect(func() -> void: stage = 3)
	if stage == 3:
		assert(client.db.terrain_column_chunk.iter().size() == 1)
		var source := client.db.terrain_column_chunk.id.find((32 << 32) | 32)
		assert(source != null and source.base_z.size() == 1024 and source.moisture.size() == 1024)
		assert(source.generation_id == client.db.world_generation.id.find(0).generation_id)
		assert(source.base_z[0] == 0 and source.moisture[0] >= 192)
		assert(client.db.terrain_overview_chunk.iter().size() == 1)
		var overview := client.db.terrain_overview_chunk.iter()[0]
		assert(overview.lod == 3 and overview.cut_z == -1)
		assert(overview.surface_z.size() == 256 and overview.material.size() == 256)
		assert(overview.soil_fertility.size() == 256)
		client.disconnect_db()
		print("WORLD_BINDINGS_WIRE_PASS: actual SDK bootstrap/Ready/Membership and bounded production source/overview subscriptions")
		quit(0)
	return false
