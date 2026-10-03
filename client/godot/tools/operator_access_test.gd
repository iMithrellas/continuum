## Role discovery alone grants operations: neither local profiles nor an empty
## view, warmup, disconnect, or a late subscription acknowledgement may do so.
extends SceneTree

class ConnectedClient extends ContinuumModuleClient:
	var online := true
	func is_connected_db() -> bool:
		return online

class AccessFixture extends ContinuumAccess:
	func _init(client: SpacetimeDBClient) -> void:
		_client = client

class Transport extends SpacetimeDBConnection:
	var packets: Array[PackedByteArray] = []
	func send_bytes(bytes: PackedByteArray) -> Error:
		packets.append(bytes)
		return OK
	func _process(_delta: float) -> void: pass

class LifecycleClient extends ConnectedClient:
	var discards := 0
	var next_id := 0
	func subscribe(sql: PackedStringArray) -> SpacetimeDBSubscription:
		next_id += 1
		var handle := SpacetimeDBSubscription.create(self, next_id, sql)
		add_child(handle)
		_pending_subscriptions[next_id] = handle
		return handle
	func discard_subscription(handle: SpacetimeDBSubscription) -> void:
		discards += 1
		super.discard_subscription(handle)

func lifecycle() -> void:
	for mode in ["disconnect", "error", "closing", "ack", "timeout", "freed", "owner_lost", "owner_ack", "owner_freed", "handle_freed", "replacement", "early_quit"]:
		var client := LifecycleClient.new()
		root.add_child(client)
		client.set_process(false)
		var local := LocalDatabase.new(SpacetimeDBSchema.new("Continuum"), client)
		client._local_db = local
		client.db = ContinuumModuleDb.new(local)
		client._serializer = BSATNSerializer.new(SpacetimeDBSchema.new("Continuum"))
		var transport := Transport.new(SpacetimeDBConnectionOptions.new(), "access-fixture")
		client._connection = transport
		client.add_child(transport)
		var server := TCPServer.new()
		var peer := WebSocketPeer.new()
		if mode not in ["disconnect", "error"]:
			var port := 20000 + randi() % 30000
			while server.listen(port, "127.0.0.1") != OK:
				port = 20000 + randi() % 30000
			assert(transport._websocket.connect_to_url("ws://127.0.0.1:%d" % port) == OK)
			var deadline := Time.get_ticks_msec() + 3000
			while transport._websocket.get_ready_state() != WebSocketPeer.STATE_OPEN:
				if server.is_connection_available():
					assert(peer.accept_stream(server.take_connection()) == OK)
				peer.poll()
				transport._websocket.poll()
				assert(Time.get_ticks_msec() < deadline)
				await process_frame
		var access := ContinuumAccess.new(client)
		var handle := access._subscription
		var handle_reference: WeakRef = weakref(handle)
		var access_reference: WeakRef = weakref(access)
		var row := ContinuumMembership.new()
		row.role = ContinuumRole.create_operator()
		var insert := TableUpdateData.new()
		insert.table_name = "my_role"
		insert.inserts.append(row)
		local.apply_table_update(insert)
		handle.applied.emit()
		assert(access.can_operate)
		if mode == "closing":
			transport._websocket.close()
			assert(transport._websocket.get_ready_state() == WebSocketPeer.STATE_CLOSING)
		if mode == "disconnect": client.disconnected.emit()
		if mode == "error": client.connection_error.emit(ERR_CONNECTION_ERROR, "fixture")
		access.stop()
		access.stop()
		assert(access.role_name == "Unknown" and not access.can_operate and not access.is_admin)
		if mode in ["disconnect", "error", "closing"]:
			assert(client.online and transport.packets.is_empty() and client.discards == 1)
			assert(local._tables["my_role"].is_empty() and access._subscription == null)
			handle.applied.emit()
		else:
			assert(transport.packets.size() == 1 and client.discards == 0)
			assert(transport.packets[0][-1] == UnsubscribeMessage.UnsubscribeFlags.SendDroppedRows)
			access._release_subscription()
			assert(transport.packets.size() == 1)
			var replacement: ContinuumAccess
			if mode in ["owner_lost", "owner_ack", "owner_freed", "handle_freed", "replacement", "early_quit"]:
				client._pending_subscriptions.erase(1)
				client.current_subscriptions[1] = handle
				access = null
				assert(access_reference.get_ref() == null)
				if mode == "owner_lost": transport._websocket.close()
				if mode == "replacement":
					replacement = ContinuumAccess.new(client)
					local.apply_table_update(insert)
					replacement._subscription.applied.emit()
					assert(replacement.can_operate)
			if mode in ["ack", "owner_ack"]:
				client._pending_subscriptions.erase(1)
				client.current_subscriptions[1] = handle
				var ack := UnsubscribeAppliedMessage.new()
				ack.query_id.id = 1
				var table := TableUpdateData.new()
				table.table_name = "my_role"
				table.deletes.append(row)
				ack.tables.append(table)
				client._handle_parsed_message(ack)
				assert(client.discards == 0 and local._tables["my_role"].is_empty())
				if access != null: assert(access._subscription == null)
			elif mode in ["freed", "owner_freed"]:
				client.free()
			elif mode == "handle_freed":
				client.discard_subscription(handle)
			if mode == "early_quit":
				peer.close()
				server.stop()
				client.free()
				local.free()
				continue
			await create_timer(1.1).timeout
			if access != null: assert(access._subscription == null and access._release_timer == null)
			assert(handle_reference.get_ref() == null)
			if is_instance_valid(client):
				assert(not client.current_subscriptions.has(1) and not client._pending_subscriptions.has(1))
			if mode in ["owner_lost", "replacement"]: assert(client.discards == 1)
			if replacement != null:
				assert(replacement.can_operate and not local._tables["my_role"].is_empty() and client._pending_subscriptions[2] == replacement._subscription)
				var late := UnsubscribeAppliedMessage.new()
				late.query_id.id = 1
				client._handle_parsed_message(late)
				assert(replacement.can_operate and client._pending_subscriptions.has(2))
				transport._websocket.close()
				replacement.stop()
			if mode == "timeout": assert(client.discards == 1 and local._tables["my_role"].is_empty())
		if access != null: assert(access.role_name == "Unknown" and not access.can_operate)
		peer.close()
		server.stop()
		if is_instance_valid(client): client.free()
		local.free()
	print("ACCESS_TERMINAL_LIFECYCLE_PASS modes=12 ownerless_deadlines=6")

func _initialize() -> void:
	call_deferred("run")

func run() -> void:
	var client := ConnectedClient.new()
	var schema := SpacetimeDBSchema.new("Continuum")
	var local := LocalDatabase.new(schema, client)
	client.db = ContinuumModuleDb.new(local)
	var access := AccessFixture.new(client)
	access._refresh_from_view()
	assert(access.role_name == "Unknown" and not access.can_operate)
	access._on_view_applied()
	assert(access.role_name == "Viewer" and not access.can_operate)
	var row := ContinuumMembership.new()
	local._tables["my_role"] = {"fixture": row}
	for value: int in [0, 1, 2]:
		row.role = ContinuumRole.create(value)
		access._refresh_from_view()
		assert(access.role_name == ["Admin", "Operator", "Viewer"][value])
		assert(access.can_operate == (value < 2) and access.is_admin == (value == 0))
	client.online = false
	access._refresh_from_view()
	assert(access.role_name == "Unknown" and not access.can_operate)
	client.online = true
	access._stopped = true
	row.role = ContinuumRole.create_admin()
	access._on_view_applied()
	access._on_role_row_change("my_role", row)
	assert(access.role_name == "Unknown" and not access.can_operate and not access.is_admin)
	local.free()
	client.free()
	print("OPERATOR_ACCESS_PASS")
	await lifecycle()
	quit()
