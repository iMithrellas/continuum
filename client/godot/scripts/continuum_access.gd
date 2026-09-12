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
var _view_applied := false
var _stopped := false
var _release_timer: SceneTreeTimer

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
	_stopped = false
	if _subscription and not _subscription.ended:
		return
	_set_unknown()
	_view_applied = false
	if _client == null or not _client.is_connected_db():
		return
	_subscribe()

func _on_connected(_identity: PackedByteArray, _token: String) -> void:
	if _stopped:
		return
	_set_unknown()
	_view_applied = false
	_subscribe()

func _subscribe() -> void:
	if _stopped:
		return
	if _subscription and not _subscription.ended:
		return
	_client.get_local_database().clear_role_view()
	_subscription = _client.subscribe(PackedStringArray(["SELECT * FROM my_role"]))
	_subscription.applied.connect(_on_view_applied)
	_subscription.end.connect(_on_view_ended)

func _on_disconnected() -> void:
	_view_applied = false
	_release_subscription(false)
	_set_unknown()

func _on_connection_error(_code: int, _reason: String) -> void:
	_view_applied = false
	_release_subscription(false)
	_set_unknown()

func _on_view_applied() -> void:
	_view_applied = true
	_refresh_from_view()

func _on_view_ended() -> void:
	_view_applied = false
	_subscription = null
	_release_timer = null
	_set_unknown()
	if _stopped:
		_client = null

func stop() -> void:
	if _stopped:
		return
	_stopped = true
	_view_applied = false
	_set_unknown()
	if _client != null:
		if _client.connected.is_connected(_on_connected):
			_client.connected.disconnect(_on_connected)
		if _client.disconnected.is_connected(_on_disconnected):
			_client.disconnected.disconnect(_on_disconnected)
		if _client.connection_error.is_connected(_on_connection_error):
			_client.connection_error.disconnect(_on_connection_error)
		if _client.row_inserted.is_connected(_on_role_row_change):
			_client.row_inserted.disconnect(_on_role_row_change)
		if _client.row_deleted.is_connected(_on_role_row_change):
			_client.row_deleted.disconnect(_on_role_row_change)
		if _client.row_updated.is_connected(_on_role_row_updated):
			_client.row_updated.disconnect(_on_role_row_updated)
	_release_subscription()
	if _subscription == null:
		_client = null

func _release_subscription(use_network: bool = true) -> void:
	if _subscription == null:
		return
	var subscription := _subscription
	if use_network and not subscription.ended and _client != null and _client.is_connected_db():
		if subscription.unsubscribe() == OK:
			# Do not retain a handle indefinitely if teardown loses the server ack.
			_release_timer = _client.get_tree().create_timer(1.0)
			_release_timer.timeout.connect(_force_release.bind(subscription), CONNECT_ONE_SHOT)
			return
	_subscription = null
	if _client != null:
		_client.discard_subscription(subscription)
	else:
		subscription.queue_free()

func _force_release(subscription: SpacetimeDBSubscription) -> void:
	if _subscription != subscription:
		return
	_subscription = null
	_release_timer = null
	if _client != null:
		_client.discard_subscription(subscription)
		_client = null

func _on_role_row_updated(_table_name: String, _old_row: Resource, _new_row: Resource) -> void:
	if _table_name != "my_role":
		return
	_refresh_from_view()

func _on_role_row_change(table_name: String, _row: Resource) -> void:
	if table_name == "my_role":
		_refresh_from_view()

func _refresh_from_view() -> void:
	if not _view_applied or _client == null or not _client.is_connected_db():
		_set_unknown()
		return
	var rows: Array[ContinuumMembership] = _client.db.my_role.iter()
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
