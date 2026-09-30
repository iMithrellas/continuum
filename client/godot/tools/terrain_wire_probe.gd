## Read-only wire/deserializer check. No reducers, access enrollment, or settings.
## godot --headless --path client/godot --scene res://tools/terrain_wire_probe.tscn -- --terrain-host=http://127.0.0.1:3307 --terrain-db=continuum-vertical-migration
extends Node
var client: ContinuumModuleClient
var subscription: SpacetimeDBSubscription
var finished := false

func _ready() -> void:
	client = ContinuumModuleClient.new()
	client.handle_window_close = false
	client.token_save_path = "user://terrain_wire_probe_unused.token"
	add_child(client)
	client.connected.connect(_connected)
	client.connection_error.connect(func(code: int, reason: String) -> void: finish(false, "connection error %d: %s" % [code, reason]))
	var host := ""
	var database := ""
	for argument in OS.get_cmdline_user_args():
		if argument.begins_with("--terrain-host="):
			host = argument.trim_prefix("--terrain-host=")
		if argument.begins_with("--terrain-db="):
			database = argument.trim_prefix("--terrain-db=")
	if host.is_empty() or database.is_empty():
		finish(false, "explicit --terrain-host and --terrain-db are required")
		return
	var options := SpacetimeDBConnectionOptions.new()
	options.compression = SpacetimeDBConnection.CompressionPreference.NONE
	options.save_token = false
	options.one_time_token = true
	client.connect_db(host, database, options)
	get_tree().create_timer(15).timeout.connect(func() -> void: finish(false, "subscription timeout"))

func _connected(_identity: Variant, _token: Variant) -> void:
	subscription = client.subscribe(PackedStringArray([
		"SELECT * FROM world_geometry", "SELECT * FROM terrain_chunk", "SELECT * FROM terrain_material",
		"SELECT * FROM excavation_designation", "SELECT * FROM tile", "SELECT * FROM colonist", "SELECT * FROM item_stack"]))
	if subscription.error != OK:
		finish(false, "subscribe error %d" % subscription.error)
		return
	subscription.applied.connect(_applied)

func _applied() -> void:
	var geometry: ContinuumWorldGeometry = client.db.world_geometry.id.find(0)
	if geometry == null or client.db.terrain_chunk.iter().is_empty():
		finish(false, "missing generated terrain rows")
		return
	for chunk: ContinuumTerrainChunk in client.db.terrain_chunk.iter():
		if chunk.materials.size() != 4096:
			finish(false, "wrong voxel chunk payload length")
			return
	for designation: ContinuumExcavationDesignation in client.db.excavation_designation.iter():
		if ColonyMap.designation_rect(designation).size.x < 1:
			finish(false, "invalid canonical designation rectangle")
			return
	var model := LayeredTerrainModel.new()
	model.sync(geometry, client.db.terrain_chunk.iter(), client.db.terrain_material.iter())
	finish(true, "%dx%d z=%d..%d chunks=%d surfaces=%d colonists=%d designations=%d" % [geometry.width, geometry.height,
		geometry.min_z, geometry.max_z, client.db.terrain_chunk.iter().size(), model.surfaces.size(),
		client.db.colonist.iter().size(), client.db.excavation_designation.iter().size()])

func finish(passed: bool, message: String) -> void:
	if finished:
		return
	finished = true
	print("TERRAIN_WIRE_%s %s" % ["PASS" if passed else "FAIL", message])
	if client != null and client.is_connected_db():
		client.disconnect_db()
	get_tree().quit(0 if passed else 1)
