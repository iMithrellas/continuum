## Connected acceptance driver: unmodified Main, real Controls, map input, reducers.
extends SceneTree

var main: Node
var spacetime: Node
var directory: String
var serial := 0
var busy := false
var driver_error := ""

func _initialize() -> void:
	for argument in OS.get_cmdline_user_args():
		if argument.begins_with("--gate-dir="): directory = argument.trim_prefix("--gate-dir=")
	assert(not directory.is_empty())
	call_deferred("start")

func start() -> void:
	root.size = Vector2i(1600, 1000)
	spacetime = root.get_node("SpacetimeDB")
	main = load("res://scenes/main.tscn").instantiate()
	root.add_child(main)
	create_timer(0.1).timeout.connect(poll)

func poll() -> void:
	if not busy and FileAccess.file_exists(directory + "/command.json"):
		var command = JSON.parse_string(FileAccess.get_file_as_string(directory + "/command.json"))
		if command is Dictionary and int(command.id) > serial:
			busy = true
			serial = int(command.id)
			await run(command)
			busy = false
	create_timer(0.1).timeout.connect(poll)

func answer(extra: Dictionary = {}) -> void:
	var result := {"id": serial, "ready": main._state_ready, "operator": main._can_operate,
		"snapshot": main.map.has_world_snapshot(), "pending": main._intent_request != null,
		"feedback": main._intent_feedback.text,
		"feedback_detail": main._intent_feedback.tooltip_text,
		"room": main._construction_panel.selection.text, "usage": main._zones_panel.selection.text,
		"driver_error": driver_error,
		"identity": spacetime.Continuum.get_local_identity().hex_encode()}
	result.merge(extra)
	var file := FileAccess.open(directory + "/response.tmp", FileAccess.WRITE)
	file.store_string(JSON.stringify(result))
	file.close()
	DirAccess.rename_absolute(directory + "/response.tmp", directory + "/response.json")

func button(control: Button, panel: String) -> void:
	if main.workspace.map_only or not main.workspace.state(panel).open or main.workspace.state(panel).minimized:
		main.workspace.toggle_panel(panel)
	main.workspace.focus_panel(panel)
	await process_frame
	if not control.is_visible_in_tree():
		if main._can_operate and main._state_ready: driver_error = "authorized planning button was not visible"
		else: print("GATE_BLOCKED hidden planning control without actionable authority")
		return
	var ancestor := control.get_parent()
	while ancestor != null:
		if ancestor is ScrollContainer: ancestor.ensure_control_visible(control)
		ancestor = ancestor.get_parent()
	await process_frame
	control.grab_focus()
	var point := control.get_global_rect().get_center()
	print("GATE_BUTTON ", control.text, " disabled=", control.disabled, " point=", point, " viewport=", root.get_visible_rect(), " focus=", root.gui_get_focus_owner())
	var motion := InputEventMouseMotion.new()
	motion.position = point
	Input.parse_input_event(motion)
	for pressed in [true, false]:
		var event := InputEventMouseButton.new()
		event.position = point
		event.button_index = MOUSE_BUTTON_LEFT
		event.pressed = pressed
		Input.parse_input_event(event)
		await process_frame
	await process_frame
	print("GATE_TOOL ", main._planning_system, " hovered=", root.gui_get_hovered_control())

func gesture(x: int, y: int, width: int, depth: int) -> void:
	if not main.workspace.map_only: main.workspace.toggle_map_only()
	var map = main.map
	var center := Vector2(x + width * 0.5, y + depth * 0.5)
	map.pan_by(map.size * 0.5 - map.world_to_screen(center))
	map.zoom_at(32.0 / maxf(map._cell_size(), 0.0001), map.size * 0.5)
	await process_frame
	var start: Vector2 = map.get_global_transform() * map.world_to_screen(Vector2(x + 0.5, y + 0.5))
	var finish: Vector2 = map.get_global_transform() * map.world_to_screen(Vector2(x + width - 0.5, y + depth - 0.5))
	var press := InputEventMouseButton.new()
	press.button_index = MOUSE_BUTTON_LEFT
	press.pressed = true
	press.position = start
	root.push_input(press)
	var motion := InputEventMouseMotion.new()
	motion.position = finish
	motion.button_mask = MOUSE_BUTTON_MASK_LEFT
	root.push_input(motion)
	var release := InputEventMouseButton.new()
	release.button_index = MOUSE_BUTTON_LEFT
	release.position = finish
	root.push_input(release)

func run(command: Dictionary) -> void:
	match command.action:
		"status": pass
		"detail":
			await gesture(command.x, command.y, 1, 1)
			answer({"resident": not main.map.layered or main.map.terrain_model.placement_clear(Rect2i(command.x, command.y, 2, 2), 0, 4)})
			return
		"draw":
			var panel = main._construction_panel if command.system == "construction" else main._zones_panel
			var key := "construction" if command.system == "construction" else "operations"
			if command.system == "zones": await button(panel.choices[ContinuumTileKind.Options.storage], key)
			await button(panel.activate, key)
			await gesture(command.x, command.y, command.width, command.depth)
			var pending: bool = main._intent_request != null
			var feedback: String = main._intent_feedback.text
			if command.get("double", false):
				# gesture's camera await would allow polling; send raw second press/release now.
				var position: Vector2 = main.map.get_global_transform() * main.map.world_to_screen(Vector2(command.x + 0.5, command.y + 0.5))
				for pressed in [true, false]:
					var event := InputEventMouseButton.new()
					event.button_index = MOUSE_BUTTON_LEFT
					event.position = position
					event.pressed = pressed
					root.push_input(event)
			answer({"observed_pending": pending, "pending_feedback": feedback})
			return
		"select":
			await button(main._construction_panel.inspect, "construction")
			await gesture(command.x, command.y, 1, 1)
		"remove":
			var room: bool = command.system == "construction"
			await button(main._construction_panel.remove if room else main._zones_panel.remove, "construction" if room else "operations")
		"wire_denials":
			var errors := []
			var reducers = spacetime.Continuum.reducers
			for spec in [["construct_room", [command.x, command.y, command.x + 1, command.y + 1, 0, 4]],
				["designate_zone_at", [command.x, command.y, command.x, command.y, 0, ContinuumTileKind.create_storage()]],
				["clear_zone", [command.tile_id]], ["demolish_building", [command.building_id]]]:
				var call = reducers.callv(spec[0], spec[1])
				assert(call.error == OK)
				var response = await call.response
				errors.append(response.reducer_result.get_err() if response.reducer_result.value == ReducerOutcomeEnum.Options.err else "NOT_ROLE_DENIAL")
			answer({"errors": errors})
			return
		"disconnect": main.leave_session()
		"quit":
			main.leave_session()
			answer()
			quit()
			return
	answer()
