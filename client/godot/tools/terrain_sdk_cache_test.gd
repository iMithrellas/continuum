## Real SDK cache + production stream/adapter; only transport is captured.
extends Node
const Wire = preload("res://tools/large_map_wire_test.gd")


class Transport:
	extends SpacetimeDBConnection
	var packets: Array[PackedByteArray] = []

	func send_bytes(bytes: PackedByteArray) -> Error:
		packets.append(bytes)
		return OK

	func _process(_delta: float) -> void:
		pass


class Client:
	extends ContinuumModuleClient
	var next_id := 0
	var online := true

	func is_connected_db() -> bool:
		return online

	func subscribe(sql: PackedStringArray) -> SpacetimeDBSubscription:
		next_id += 1
		var handle := SpacetimeDBSubscription.create(self, next_id, sql)
		add_child(handle)
		_pending_subscriptions[next_id] = handle
		return handle


var failures := 0
var assertions := 0


func check(value: bool, message: String) -> void:
	assertions += 1
	if not value:
		failures += 1
		push_error(message)


func _ready() -> void:
	call_deferred("run")


func apply(client: Client, id: int, edit: Resource = null) -> void:
	var ack := SubscribeAppliedMessage.new()
	ack.query_id.id = id
	if edit != null:
		var table := TableUpdateData.new()
		table.table_name = "terrain_chunk"
		table.inserts.append(edit)
		ack.tables.append(table)
	client._handle_parsed_message(ack)


func release(client: Client, id: int, edit: Resource = null) -> void:
	var ack := UnsubscribeAppliedMessage.new()
	ack.query_id.id = id
	if edit != null:
		var table := TableUpdateData.new()
		table.table_name = "terrain_chunk"
		table.deletes.append(edit)
		ack.tables.append(table)
	client._handle_parsed_message(ack)


func run() -> void:
	var spacetime := get_tree().root.get_node("SpacetimeDB")
	var previous: Variant = spacetime.Continuum
	var client := Client.new()
	spacetime.add_child(client)
	client.set_process(false)
	spacetime.Continuum = client
	var local := preload("res://tools/terrain_fixture.gd").database(false)
	var db := Wire.ExtendedDb.new(local)
	client.db = db
	client._local_db = local
	client._serializer = BSATNSerializer.new(SpacetimeDBSchema.new("Continuum"))
	var transport := Transport.new(SpacetimeDBConnectionOptions.new(), "terrain-cache-fixture")
	client._connection = transport
	client.add_child(transport)
	var fixture := Wire.new()
	db.terrain_column_chunk.values = [fixture.source(Vector2i.ZERO), fixture.source(Vector2i(1, 0))]
	fixture.free()
	var model := LayeredTerrainModel.new()
	model.configure_sources(32, CompactTerrainAdapter.read_material)
	model.set_geometry({"width": 2048, "height": 2048, "min_z": -16, "max_z": 15})
	model.set_materials(
		[{"id": 0, "opaque": false}, {"id": 1, "opaque": true}, {"id": 2, "opaque": true}]
	)
	var adapter := CompactTerrainAdapter.new()
	var stream := TerrainStream.new()
	stream.max_resident = 1
	stream.eviction_adapter = adapter.evict
	stream.attach(client, model, 7, 9, CompactTerrainAdapter.detail_queries, adapter.snapshot)
	stream.request_frame(Rect2i(0, 0, 1, 1), 16, 0)
	var edit := ContinuumTerrainChunk.new()
	edit.id = 1
	edit.chunk_z = -1
	edit.revision = 1
	edit.materials.resize(4096)
	apply(client, 1, edit)
	check(
		model.column_state(Vector2i.ZERO) == &"resolved_empty",
		"real SDK installs complete all-air edit"
	)
	stream.request_frame(Rect2i(32, 0, 1, 1), 16, 0)
	check(
		(
			transport.packets.size() == 1
			and transport.packets[0][-1] == UnsubscribeMessage.UnsubscribeFlags.SendDroppedRows
		),
		"production eviction serializes authoritative dropped-rows flag"
	)
	check(
		local._tables["terrain_chunk"].has(1) and client.current_subscriptions.has(1),
		"cache/handle remain owned until server ack"
	)
	release(client, 1, edit)
	check(
		not local._tables["terrain_chunk"].has(1), "real SDK removes server-reported dropped edit"
	)
	apply(client, 2)
	stream.request_frame(Rect2i(0, 0, 1, 1), 16, 0)
	release(client, 2)
	apply(client, 3)
	check(
		model.surface_at(Vector2i.ZERO) == Vector3i(0, 0, -1),
		"returning after deleted edit restores exact stored floor, never ghost air"
	)
	for cycle in 8:
		var active: int = client.next_id
		stream.request_frame(Rect2i(32 if cycle % 2 == 0 else 0, 0, 1, 1), 16, 0)
		release(client, active)
		apply(client, client.next_id)
		check(
			(
				local._tables["terrain_chunk"].is_empty()
				and client.current_subscriptions.size() == 1
				and stream.resident_count() == 1
			),
			"repeated pan keeps real cache and server-owned handle residency bounded"
		)
	var active: int = client.next_id
	stream.request_frame(Rect2i(32, 0, 1, 1), 16, 0)
	release(client, active)
	var pending: int = client.next_id
	var sends := transport.packets.size()
	stream.stop()
	apply(client, pending)
	await get_tree().process_frame
	check(
		(
			transport.packets.size() == sends
			and client.current_subscriptions.is_empty()
			and stream._retired.is_empty()
		),
		"queued late ack on closed socket discards offline handle without unsubscribe, despite stale connected flag"
	)
	client.online = false
	stream.stop()
	spacetime.Continuum = previous
	local.free()
	client.queue_free()
	print("TERRAIN_SDK_CACHE_%s assertions=%d" % ["PASS" if failures == 0 else "FAIL", assertions])
	get_tree().quit(0 if failures == 0 else 1)
