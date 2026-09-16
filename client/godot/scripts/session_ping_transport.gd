class_name SessionPingTransport
extends RefCounted

var _client
var _sampler: SessionDiagnostics
var _calls: Dictionary = {}
var _disposed := false

func _init(client, sampler: SessionDiagnostics) -> void:
	_client = client
	_sampler = sampler
	_sampler.probe_closed.connect(_on_probe_closed)
	if _client.has_signal("connected"):
		_client.connected.connect(_on_connected)
	if _client.has_signal("disconnected"):
		_client.disconnected.connect(_on_disconnected)
	_sampler.configure_probe(_send_echo)
	_sampler.set_connected(_client.is_connected_db())

func _send_echo(probe_id: int) -> bool:
	if _disposed or not _client.is_connected_db():
		return false
	var call = _client.reducers.diagnostic_echo(probe_id)
	if call.error != OK:
		_sampler.reject(probe_id)
		return false
	_calls[probe_id] = call
	_sampler.mark_sent(probe_id, call.transport_sent_at_usec)
	call.on_ok.connect(func(_response): _respond(probe_id))
	call.on_ok_empty.connect(func(_response): _respond(probe_id))
	call.on_error.connect(func(_error): _reject(probe_id))
	call.on_internal_error.connect(func(_error): _reject(probe_id))
	return true

func _respond(probe_id: int) -> void:
	var call: SpacetimeDBReducerCall = _calls.get(probe_id)
	if call == null:
		return
	var received_at_usec := call.transport_received_at_usec
	if received_at_usec < 0:
		received_at_usec = Time.get_ticks_usec()
	_sampler.respond(probe_id, received_at_usec)

func _reject(probe_id: int) -> void:
	_sampler.reject(probe_id)

func _on_probe_closed(probe_id: int, outcome: String) -> void:
	var call = _calls.get(probe_id)
	_calls.erase(probe_id)
	if call != null and outcome != "success":
		_client.cancel_reducer_call(call)

func _on_connected(_identity = null, _token = "") -> void:
	_sampler.set_connected(true)

func _on_disconnected() -> void:
	_sampler.set_connected(false)

func dispose() -> void:
	if _disposed:
		return
	_disposed = true
	_sampler.set_connected(false)
	for call in _calls.values():
		_client.cancel_reducer_call(call)
	_calls.clear()
	if _sampler.probe_closed.is_connected(_on_probe_closed):
		_sampler.probe_closed.disconnect(_on_probe_closed)
	if _client.has_signal("connected") and _client.connected.is_connected(_on_connected):
		_client.connected.disconnect(_on_connected)
	if _client.has_signal("disconnected") and _client.disconnected.is_connected(_on_disconnected):
		_client.disconnected.disconnect(_on_disconnected)
