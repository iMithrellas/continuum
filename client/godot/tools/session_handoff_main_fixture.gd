extends "res://tools/native_controls_main_fixture.gd"

var starts: Array[Dictionary] = []
var connected_events := 0
var row_events := 0
var native_ready_deliveries := 0


## Preserves selection and deferred replacement without starting network requests.
func _start_configured_client(client: ContinuumModuleClient, generation: int) -> void:
	if generation == _session_generation and _session_requested:
		starts.append({"client": client, "generation": generation, "database": _database})


func _on_connected(_identity: PackedByteArray, _token: String) -> void:
	connected_events += 1


func _on_table_changed(_table_name: String, _row: Variant = null) -> void:
	row_events += 1


func _refresh_alerts() -> void:
	pass


func _on_native_ready(host: String, database: String, epoch: int, source_id: int) -> void:
	native_ready_deliveries += 1
	super._on_native_ready(host, database, epoch, source_id)
