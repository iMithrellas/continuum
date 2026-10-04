## Production main composition with injectable native/network boundaries.
extends "res://scripts/main.gd"

var forbidden_connections := 0
var recorded_acknowledgements: Array[int] = []
var fixture_ack_calls: Array[SpacetimeDBReducerCall] = []
var fixture_workspace_path := "user://ui_composition_fixture_%d.json" % Time.get_ticks_usec()


func _has_cli_connection() -> bool:
	return false


func _setup_native_controller() -> void:
	pass


func _start_configured_client(_client: ContinuumModuleClient, _generation: int) -> void:
	forbidden_connections += 1


func _cli_option(option: String, fallback: String) -> String:
	if option == "--workspace-file":
		return fixture_workspace_path
	if option == "--settings-file":
		return "user://ui_composition_fixture_settings.cfg"
	return super._cli_option(option, fallback)


func _dispatch_acknowledgement(alert_id: int) -> SpacetimeDBReducerCall:
	recorded_acknowledgements.append(alert_id)
	var call := SpacetimeDBReducerCall.new()
	fixture_ack_calls.append(call)
	return call
