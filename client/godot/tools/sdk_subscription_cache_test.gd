## Backend-free real SDK wire/cache regression. Only the WebSocket transport is replaced.
extends SceneTree


class CaptureConnection:
	extends SpacetimeDBConnection
	var packets: Array[PackedByteArray] = []

	func is_connected_db() -> bool:
		return _is_connected

	func send_bytes(bytes: PackedByteArray) -> Error:
		packets.append(bytes)
		return OK

	func _process(_delta: float) -> void:
		pass  # Do not poll the unopened socket during asynchronous lifecycle checks.


var client: ContinuumModuleClient
var transport: CaptureConnection
var schema: SpacetimeDBSchema
var parser: BSATNDeserializer
var db: ContinuumModuleDb
var deleted: Array[int] = []


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	schema = SpacetimeDBSchema.new("Continuum")
	client = ContinuumModuleClient.new()
	client.debug_mode = false
	client.use_threading = false
	root.add_child(client)
	client._serializer = BSATNSerializer.new(schema)
	client._local_db = LocalDatabase.new(schema, client)
	client.add_child(client._local_db)
	db = ContinuumModuleDb.new(client._local_db)
	parser = BSATNDeserializer.new(schema, client, false)
	var options := SpacetimeDBConnectionOptions.new()
	options.monitor_mode = false
	transport = CaptureConnection.new(options, "cache-fixture")
	transport._is_connected = true
	client._connection = transport
	client.add_child(transport)
	client._local_db.subscribe_to_deletes("terrain_chunk", func(row): deleted.append(row.id))
	_deleted_while_unsubscribed()
	_overlap_and_replacement()
	await _bounded_pans()
	await _offline_teardown()
	client.free()
	print(
		"SDK_SUBSCRIPTION_CACHE_PASS: wire flag, parsed acks, deleted edit, overlaps, late acks, offline teardown, bounded pans"
	)
	quit(0)


func _row(id: int) -> ContinuumTerrainChunk:
	var materials: Array[int] = []
	materials.resize(4096)
	materials.fill(0)
	return ContinuumTerrainChunk.create(id, id, 0, 0, materials, 1)


func _subscribe(rows: Array[ContinuumTerrainChunk]) -> SpacetimeDBSubscription:
	var handle := client.subscribe(["SELECT * FROM terrain_chunk"])
	assert(not handle.ended and client._pending_subscriptions.has(handle.query_id))
	_subscribe_ack(handle.query_id, rows)
	assert(handle.active and client.current_subscriptions.get(handle.query_id) == handle)
	return handle


## Encodes v2 QueryRows with one table and RowOffsets over generated BSATN rows.
func _payload(
	id: int, rows: Array[ContinuumTerrainChunk], unsubscribe: bool, has_rows := true
) -> StreamPeerBuffer:
	var buffer := StreamPeerBuffer.new()
	buffer.big_endian = false
	buffer.put_u32(0)
	buffer.put_u32(id)
	if unsubscribe:
		buffer.put_u8(0 if has_rows else 1)  # Option::Some / None.
		if not has_rows:
			buffer.seek(0)
			return buffer
	buffer.put_u32(1)
	var name_bytes := "terrain_chunk".to_utf8_buffer()
	buffer.put_u32(name_bytes.size())
	buffer.put_data(name_bytes)
	buffer.put_u8(1)  # RowOffsets.
	buffer.put_u32(rows.size())
	var data := PackedByteArray()
	for row in rows:
		buffer.put_u64(data.size())
		var writer := BSATNSerializer.new(schema)
		writer._reset_buffer()
		assert(writer._serialize_resource_fields(row))
		assert(not writer.has_error())
		data.append_array(writer._spb.data_array)
	buffer.put_u32(data.size())
	buffer.put_data(data)
	buffer.seek(0)
	return buffer


func _subscribe_ack(id: int, rows: Array[ContinuumTerrainChunk]) -> void:
	var buffer := _payload(id, rows, false)
	var message := parser._read_subscripton_applied_message(buffer)
	assert(not parser.has_error() and buffer.get_available_bytes() == 0)
	client._handle_parsed_message(message)


func _unsubscribe_ack(id: int, rows: Array[ContinuumTerrainChunk], has_rows := true) -> void:
	var buffer := _payload(id, rows, true, has_rows)
	var message := parser._read_unsubscription_applied_message(buffer)
	assert(not parser.has_error() and buffer.get_available_bytes() == 0)
	client._handle_parsed_message(message)


func _unsubscribe(handle: SpacetimeDBSubscription) -> void:
	var before := transport.packets.size()
	assert(handle.unsubscribe() == OK)
	assert(transport.packets.size() == before + 1)
	var wire := StreamPeerBuffer.new()
	wire.big_endian = false
	wire.data_array = transport.packets.back()
	assert(wire.get_u8() == SpacetimeDBClientMessage.UNSUBSCRIBE)
	wire.get_u32()  # Request ID.
	assert(wire.get_u32() == handle.query_id)
	assert(wire.get_u8() == 1 and wire.get_available_bytes() == 0)
	assert(handle.active and not handle.ended)
	assert(client.current_subscriptions.get(handle.query_id) == handle)


func _deleted_while_unsubscribed() -> void:
	var edit := _row(1)
	var a := _subscribe([edit])
	assert(db.terrain_chunk.id.find(1).materials.size() == 4096)
	_unsubscribe(a)
	assert(db.terrain_chunk.id.find(1) != null, "no speculative eviction before ack")
	_unsubscribe_ack(a.query_id, [edit])
	assert(a.ended and not client.current_subscriptions.has(a.query_id))
	assert(db.terrain_chunk.id.find(1) == null and deleted.has(1))
	var returning := _subscribe([])
	assert(db.terrain_chunk.iter().is_empty(), "empty snapshot must not resurrect an air edit")
	_unsubscribe(returning)
	_unsubscribe_ack(returning.query_id, [])
	var opt_out := _subscribe([_row(2)])
	assert(client.unsubscribe(opt_out.query_id, UnsubscribeMessage.UnsubscribeFlags.Default) == OK)
	assert(transport.packets.back()[-1] == 0)
	_unsubscribe_ack(opt_out.query_id, [], false)
	assert(db.terrain_chunk.id.find(2) != null)
	client._local_db.clear_local_db()
	assert(db.terrain_chunk.iter().is_empty())


func _overlap_and_replacement() -> void:
	var first := _subscribe([_row(10), _row(11)])
	var second := _subscribe([_row(11), _row(12)])
	_unsubscribe(first)
	_unsubscribe_ack(first.query_id, [_row(10)])
	assert(db.terrain_chunk.iter().size() == 2)
	assert(db.terrain_chunk.id.find(11) != null and second.active)
	_unsubscribe(second)
	var replacement := _subscribe([_row(11)])
	assert(replacement.query_id > second.query_id)
	_unsubscribe_ack(second.query_id, [_row(12)])
	assert(db.terrain_chunk.iter().size() == 1 and replacement.active)
	_unsubscribe_ack(second.query_id, [_row(11)])
	assert(db.terrain_chunk.id.find(11) != null)
	assert(client.current_subscriptions.get(replacement.query_id) == replacement)
	_unsubscribe(replacement)
	_unsubscribe_ack(replacement.query_id, [_row(11)])
	assert(db.terrain_chunk.iter().is_empty())
	var pending := client.subscribe(["SELECT * FROM terrain_chunk"])
	assert(pending.unsubscribe() == OK)
	assert(client._pending_subscriptions.get(pending.query_id) == pending)
	_subscribe_ack(pending.query_id, [_row(13)])
	_unsubscribe_ack(pending.query_id, [_row(13)])
	assert(pending.ended and db.terrain_chunk.iter().is_empty())


func _bounded_pans() -> void:
	var old: SpacetimeDBSubscription
	var old_rows: Array[ContinuumTerrainChunk] = []
	for pan in range(12):
		var rows: Array[ContinuumTerrainChunk] = []
		for source in range(64):
			rows.append(_row(1000 + pan * 64 + source))
		var handle := _subscribe(rows)
		if old != null:
			assert(db.terrain_chunk.iter().size() == 128)
			_unsubscribe(old)
			_unsubscribe_ack(old.query_id, old_rows)
		assert(db.terrain_chunk.iter().size() == 64)
		var material_count := 0
		for row in db.terrain_chunk.iter():
			material_count += row.materials.size()
		assert(material_count == 64 * 4096)
		assert(
			client.current_subscriptions.size() == 1 and client._pending_subscriptions.is_empty()
		)
		old = handle
		old_rows = rows
		await process_frame
		assert(client.get_child_count() == 3)
	_unsubscribe(old)
	_unsubscribe_ack(old.query_id, old_rows)
	await process_frame
	assert(db.terrain_chunk.iter().is_empty() and client.get_child_count() == 2)


func _offline_teardown() -> void:
	var handle := _subscribe([_row(9999)])
	var pending := client.subscribe(["SELECT * FROM terrain_chunk"])
	var sends := transport.packets.size()
	transport._is_connected = false
	client.discard_subscription(handle)
	client.discard_subscription(pending)
	client._local_db.clear_local_db()
	assert(transport.packets.size() == sends)
	_subscribe_ack(pending.query_id, [_row(9999)])
	_unsubscribe_ack(handle.query_id, [_row(9999)])
	assert(db.terrain_chunk.iter().is_empty())
	assert(client.current_subscriptions.is_empty() and client._pending_subscriptions.is_empty())
	await process_frame
	assert(client.get_child_count() == 2)
