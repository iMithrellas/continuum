## Actual main, generated typed fixture rows, no SDK connection or reducer calls.
## Run through atlas_ui_checks.py to isolate HOME and every XDG directory.
extends Node

const MainScene = preload("res://tools/atlas_fixture_main.tscn")
const TerrainFixture = preload("res://tools/terrain_fixture.gd")
var main: Control
var local: LocalDatabase
var failures: Array[String] = []
var _previous_db: ContinuumModuleDb
var _previous_reducers: ContinuumModuleReducers
var _reducer_boundary: FixtureReducerClient
var _screen := Vector2i(1440, 900)
var _scale := 100
var _workspace := "diagnostics"
var _command := false
var _settings := false
var _keep_open := false
var _rich := true
var _capture := ""
var _cleaned := false


## Interactive fixture actions fail locally before serialization or SDK transport.
class FixtureReducerClient:
	extends SpacetimeDBClient

	var rejected_intents := 0

	func call_reducer(
		_reducer_name: String, _args: Array = [], _types: Array = []
	) -> SpacetimeDBReducerCall:
		rejected_intents += 1
		return SpacetimeDBReducerCall.fail(ERR_UNAUTHORIZED)


func _ready() -> void:
	_parse_arguments()
	if not _keep_open:
		ProjectSettings.set_setting("gui/timers/tooltip_delay_sec", 3600.0)
	get_window().size = _screen
	get_window().title = "Atlas UI — generated local fixture (no server)"
	get_window().close_requested.connect(_finish)
	_previous_db = SpacetimeDB.Continuum.db
	_previous_reducers = SpacetimeDB.Continuum.reducers
	_reducer_boundary = FixtureReducerClient.new()
	SpacetimeDB.Continuum.reducers = ContinuumModuleReducers.new(_reducer_boundary)
	_seed_database()
	main = MainScene.instantiate()
	add_child(main)
	await settle()
	main._server_management.probes.transport = _fixture_probe
	main._host = "http://fixture.invalid"
	main._database = "atlas-generated-local-fixture"
	main._authenticated_identity = "fixture-operator-not-a-live-session"
	main._return_key = ""
	main._session_requested = true
	main._state_ready = true
	main._menu.hide()
	main._server_management.hide()
	main._set_permissions("operator", true, false)
	var settings: ClientSettings = main._settings.clone()
	settings.ui_scale_percent = _scale
	settings.reduced_motion = true
	settings.diagnostics_enabled = _workspace == "diagnostics"
	settings.diagnostics_graph_enabled = false
	main.apply_settings(settings, false)
	main._sync_menu_input()
	main.map.bind_world_source(SpacetimeDB.Continuum.db)
	main.map.refresh()
	_sample_series()
	main._refresh_status()
	main._full_ui_refresh = true
	main._refresh()
	main.workspace.switch_workspace(_workspace)
	main.map.reset_camera()
	if _rich:
		main.map.zoom_at(2.0, main.map.size * 0.5)
	main._goto_colonist(0)
	# Never arm the production left-edge dwell while automated layout settles.
	_park_pointer(true)
	await settle()
	if _command and not _settings:
		check(main.workspace.has_method("open_command"), "deck exposes open_command")
		if main.workspace.has_method("open_command"):
			main.workspace.call("open_command", true)
	else:
		main.workspace.close_command()
	if _settings:
		await show_settings()
	_park_pointer()
	await settle()
	await run_contracts()
	check(
		main.workspace.is_command_open() == (_command and not _settings),
		"fixture Command visibility matches requested capture (Settings always closes Command)"
	)
	print(
		(
			"ATLAS_FIXTURE_COMPOSITION workspace=%s requested_command=%s settings=%s actual_command=%s"
			% [_workspace, _command, _settings, main.workspace.is_command_open()]
		)
	)
	check(main.forbidden_connections == 0, "fixture requests no SDK connections")
	check(main.recorded_acknowledgements.is_empty(), "fixture dispatches no acknowledgements")
	check(_reducer_boundary.rejected_intents == 0, "fixture setup/tests issue no reducer intents")
	if not _capture.is_empty():
		check(DisplayServer.get_name() != "headless", "screenshots require an actual render window")
		if DisplayServer.get_name() != "headless":
			await RenderingServer.frame_post_draw
			var image := get_viewport().get_texture().get_image()
			check(image.get_size() == _screen, "capture has requested physical dimensions")
			check(image.save_png(_capture) == OK, "rendered viewport PNG saves")
	if failures.is_empty():
		print("%s screen=%s scale=%d workspace=%s" % [pass_marker(), _screen, _scale, _workspace])
	else:
		for message: String in failures:
			push_error("ATLAS_UI_FAIL: " + message)
	if not _keep_open or not failures.is_empty():
		_finish()


func _parse_arguments() -> void:
	for argument: String in OS.get_cmdline_user_args():
		if argument.begins_with("--screen="):
			var parts := argument.trim_prefix("--screen=").split("x")
			assert(parts.size() == 2, "--screen expects WxH")
			_screen = Vector2i(int(parts[0]), int(parts[1]))
		elif argument.begins_with("--scale="):
			_scale = int(argument.trim_prefix("--scale="))
		elif argument.begins_with("--workspace="):
			_workspace = argument.trim_prefix("--workspace=")
		elif argument.begins_with("--capture="):
			_capture = argument.trim_prefix("--capture=")
		elif argument == "--command":
			_command = true
		elif argument == "--settings":
			_settings = true
		elif argument == "--keep-open":
			_keep_open = true
		elif argument == "--terrain=small":
			_rich = false


func _seed_database() -> void:
	var builder := preload("res://tools/map_client_profile.gd").new()
	builder.edge = 24
	local = builder.database()
	builder.free()
	if _rich:
		var landscape: LocalDatabase = preload("res://tools/world_art_fixture.gd").database(64)
		for table: String in [
			"world_geometry", "terrain_material", "terrain_chunk", "tile", "colonist", "item_stack"
		]:
			local._tables[table] = landscape._tables[table].duplicate()
		SpacetimeDB.Continuum._init_db(local)
		landscape.free()
	var config: ContinuumConfig = local._tables.config[0]
	config.game_seconds = 0.0
	config.generation = 7
	config.time_scale = 6.0
	var colony: ContinuumColony = local._tables.colony[0]
	colony.food = 100.0
	colony.wood = 160.0
	colony.stone = 90.0
	colony.meat = 20.0
	colony.population = local._tables.colonist.size()
	colony.avg_mood = 72.0
	colony.avg_productivity = 86.0
	colony.smoothed_mood = 70.0
	colony.smoothed_productivity = 84.0
	for id: int in local._tables.colonist:
		var row: ContinuumColonist = local._tables.colonist[id]
		row.name = ["Alexandria", "Bram", "Finn", "Enid", "Mara", "Otis", "Rin", "Sora"][id % 8]
		row.hunger = 10.0
		row.fatigue = 12.0
		row.recreation = 10.0
		row.mood = 72.0
		row.productivity = 86.0
	local._tables.alert.clear()
	for id in 4:
		var event := ContinuumEventLog.new()
		event.id = id + 1
		event.day = 1
		event.minute = id
		event.game_seconds = id * 60.0
		event.message = ["Bram started hauling", "Farm completed", "Enid is dining", "Food stored"][id]
		event.severity = ContinuumSeverity.create(0)
		local._tables.event_log[event.id] = event
	TerrainFixture.index_rows(local)


func show_settings() -> void:
	if main.workspace.has_method("open_command"):
		main.workspace.call("open_command", false)
		await settle()
	var button := find_button(main, "Settings")
	if button == null:
		main._menu.show_menu()
		await settle()
		button = find_button(main._menu, "Settings")
	check(button != null, "actual Settings action exists")
	if button != null:
		button.pressed.emit()
	main._sync_menu_input()
	await settle()


## Samples come from explicitly generated typed rows and real observation/history APIs.
func _sample_series() -> void:
	var config: ContinuumConfig = local._tables.config[0]
	var colony: ContinuumColony = local._tables.colony[0]
	for minute in 61:
		config.game_seconds = minute * 60.0
		colony.food = 88.0 + minute * 0.2
		colony.wood = 148.0 + minute * 0.2
		colony.stone = 96.0 - minute * 0.1
		colony.smoothed_mood = 66.0 + minute / 15.0
		colony.smoothed_productivity = 78.0 + minute / 10.0
		main._refresh_status()
		main._sample_history()
	print("ATLAS_FIXTURE_DATA generated typed rows; 61 one-minute clock samples; no server")


func _park_pointer(prefer_status := false) -> void:
	# The root Viewport caches its tooltip delay before this fixture's _ready.
	# Clear only the parked Status surface's tooltip copy for automated captures;
	# interactive keep-open fixtures retain the production hints unchanged.
	if not _keep_open:
		var status: Control = main.workspace.windows.status
		status.tooltip_text = ""
		for control: Control in status.find_children("*", "Control", true, false):
			control.tooltip_text = ""
	var point: Vector2 = main.workspace.windows.status.get_global_rect().get_center()
	if not prefer_status and main.workspace.is_command_open():
		point = main.workspace.command_card.get_global_rect().position + Vector2(20, 20)
	elif not prefer_status and main._menu.visible:
		point = main._menu._modal.get_global_rect().position + Vector2(10, 10)
	var physical: Vector2 = get_viewport().get_final_transform() * point
	if DisplayServer.get_name() != "headless":
		Input.warp_mouse(physical)
	var motion := InputEventMouseMotion.new()
	motion.position = physical
	motion.global_position = physical
	Input.parse_input_event(motion)


func _fixture_probe(_entry: Dictionary, complete: Callable) -> void:
	complete.call({"reachable": false, "error": "Generated fixture: networking disabled"})


func run_contracts() -> void:
	await settle()


func pass_marker() -> String:
	return "ATLAS_UI_FIXTURE_PASS"


func settle() -> void:
	for frame in 8:
		await get_tree().process_frame


func find_button(node: Node, text: String) -> Button:
	if (
		node is Button
		and node.is_visible_in_tree()
		and node.text.strip_edges().to_lower() == text.to_lower()
	):
		return node
	for child: Node in node.get_children():
		var found := find_button(child, text)
		if found != null:
			return found
	return null


func check(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)


func _finish() -> void:
	_cleanup()
	get_tree().quit(0 if failures.is_empty() else 1)


func _cleanup() -> void:
	if _cleaned:
		return
	_cleaned = true
	if is_instance_valid(main):
		main._state_ready = false
		main._return_key = ""
		main.free()
	SpacetimeDB.Continuum.db = _previous_db
	SpacetimeDB.Continuum.reducers = _previous_reducers
	if is_instance_valid(_reducer_boundary):
		_reducer_boundary.free()
	if is_instance_valid(local):
		local.free()


func _exit_tree() -> void:
	_cleanup()
