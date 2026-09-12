## Sender-scoped authorization state for an existing ContinuumModuleClient.
## Unknown is the safe state until the authenticated my_role view is applied.
class_name ContinuumAccess extends RefCounted

signal changed(role_name: String, can_operate: bool, is_admin: bool)

const ROLE_UNKNOWN := "Unknown"
const ROLE_VIEWER := "Viewer"
const ROLE_OPERATOR := "Operator"
const ROLE_ADMIN := "Admin"

var role_name := ROLE_UNKNOWN
var can_operate := false
var is_admin := false

var _client: ContinuumModuleClient
var _subscription: SpacetimeDBSubscription

func _init(client: SpacetimeDBClient) -> void:
	_client = client as ContinuumModuleClient
	if _client == null:
		push_error("ContinuumAccess requires a ContinuumModuleClient")
		return
	_client.connected.connect(_on_connected)
	_client.disconnected.connect(_on_disconnected)
	_client.connection_error.connect(_on_connection_error)
	_client.row_inserted.connect(_on_role_row_change)
	_client.row_updated.connect(_on_role_row_updated)
	_client.row_deleted.connect(_on_role_row_change)
	if _client.is_connected_db():
		_on_connected(PackedByteArray(), &"")

func start() -> void:
	_set_unknown()
	if _client == null or not _client.is_connected_db():
		return
	_subscribe()

func _on_connected(_identity: PackedByteArray, _token: String) -> void:
	_set_unknown()
	_subscribe()

func _subscribe() -> void:
	if _subscription and not _subscription.ended:
		return
	_subscription = _client.subscribe(PackedStringArray(["SELECT * FROM my_role"]))
	_subscription.applied.connect(_refresh_from_view)
	_subscription.end.connect(_set_unknown)

func _on_disconnected() -> void:
	_set_unknown()

func _on_connection_error(_code: int, _reason: String) -> void:
	_set_unknown()

func _on_role_row_updated(_table_name: String, _old_row: Resource, _new_row: Resource) -> void:
	_refresh_from_view()

func _on_role_row_change(table_name: String, _row: Resource) -> void:
	if table_name == "my_role":
		_refresh_from_view()

func _refresh_from_view() -> void:
	if _client == null or not _client.is_connected_db():
		_set_unknown()
		return
	var rows: Array[ContinuumOwnRole] = _client.db.my_role.iter()
	if rows.is_empty():
		_set_role(ROLE_VIEWER, false, false)
		return
	var role := rows[0].role
	if role == null:
		_set_unknown()
		return
	match role.value:
		ContinuumRole.Options.admin:
			_set_role(ROLE_ADMIN, true, true)
		ContinuumRole.Options.operator:
			_set_role(ROLE_OPERATOR, true, false)
		_:
			_set_unknown()

func _set_unknown() -> void:
	_set_role(ROLE_UNKNOWN, false, false)

func _set_role(next_name: String, next_can_operate: bool, next_is_admin: bool) -> void:
	if role_name == next_name and can_operate == next_can_operate and is_admin == next_is_admin:
		return
	role_name = next_name
	can_operate = next_can_operate
	is_admin = next_is_admin
	changed.emit(role_name, can_operate, is_admin)
