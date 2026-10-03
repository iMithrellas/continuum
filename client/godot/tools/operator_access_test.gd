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

func _initialize() -> void:
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
	quit()
