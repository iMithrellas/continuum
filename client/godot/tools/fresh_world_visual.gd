## Real Main observation/input driver. No replicated state or permission overrides.
extends SceneTree

var main: Node
var spacetime: Node
var directory := ""
var serial := 0
var busy := false
var driver_error := ""
var watch_progress := false
var last_progress := ""
var capture_busy := false
var phase_captures := {}


func _initialize() -> void:
	for argument in OS.get_cmdline_user_args():
		if argument.begins_with("--gate-dir="):
			directory = argument.trim_prefix("--gate-dir=")
	assert(not directory.is_empty())
	call_deferred("start")


func start() -> void:
	root.size = Vector2i(1280, 720)
	spacetime = root.get_node("SpacetimeDB")
	main = load("res://scenes/main.tscn").instantiate()
	root.add_child(main)
	create_timer(0.05).timeout.connect(poll)


func poll() -> void:
	if not busy and FileAccess.file_exists(directory + "/command.json"):
		var command = JSON.parse_string(FileAccess.get_file_as_string(directory + "/command.json"))
		if command is Dictionary and int(command.id) > serial:
			busy = true
			serial = int(command.id)
			await run(command)
			busy = false
	create_timer(0.05).timeout.connect(poll)


func snapshot() -> Dictionary:
	var loading = main._large_world.loading
	var map = main.map
	var center: Vector2 = map.screen_to_world(map.size * 0.5)
	var ecology := {}
	var source := Vector2i(floori(center.x / 32.0), floori(center.y / 32.0))
	if map.terrain_model.source_chunks.has(source):
		var payload = map.terrain_model.source_chunks[source].payload
		var index := posmod(floori(center.x), 32) + 32 * posmod(floori(center.y), 32)
		for field in ["soil_fertility", "forest_density", "moisture"]:
			ecology[field] = payload.get(field)[index]
	var windows := {}
	for key in ["construction", "operations"]:
		var window: Control = main.workspace.windows[key]
		windows[key] = {
			"visible": window.is_visible_in_tree(),
			"rect": str(window.get_global_rect()),
			"inside": main.workspace.area.get_global_rect().encloses(window.get_global_rect()),
			"horizontal_overflow":
			window.scroll.get_h_scroll_bar().max_value > window.scroll.size.x + 1
		}
	return {
		"id": serial,
		"ready": main._state_ready,
		"operator": main._can_operate,
		"admin": main._is_admin,
		"pending": main._intent_request != null,
		"feedback": main._intent_feedback.text,
		"feedback_detail": main._intent_feedback.tooltip_text,
		"room": main._construction_panel.selection.text,
		"usage": main._zones_panel.selection.text,
		"driver_error": driver_error,
		"identity": spacetime.Continuum.get_local_identity().hex_encode(),
		"phase": loading.phase,
		"completed": loading.completed,
		"total": loading.total,
		"generation": loading.generation,
		"playable": loading.playable,
		"world_ready": loading._world_ready,
		"overlay": main._world_overlay.visible,
		"loading_error": loading.error,
		"mode": str(map.terrain_model.presentation_mode),
		"cut": map.terrain_model.cut,
		"cell_pixels": map._cell_size(),
		"center": [center.x, center.y],
		"center_ecology_u8": ecology,
		"visible_rect": str(map.visible_grid_rect()),
		"resident": map.terrain_model.source_chunks.size(),
		"terrain_pending_samples": map.terrain_view.pending_samples,
		"render_sample_count": map.terrain_view._frame.get("samples", {}).size(),
		"detail_entries": main._large_world.detail.resident_count(),
		"overview_rows":
		(
			spacetime.Continuum.db.terrain_overview_chunk.iter().size()
			if spacetime.Continuum.db != null
			else 0
		),
		"size": [root.size.x, root.size.y],
		"ui_scale": main._settings.ui_scale_percent,
		"map_only": main.workspace.map_only,
		"windows": windows,
		"selection": str(main._selected_rect),
		"cell_label": main._cell_label.text
	}


func answer(extra: Dictionary = {}) -> void:
	var result := snapshot()
	result.merge(extra, true)
	var file := FileAccess.open(directory + "/response.tmp", FileAccess.WRITE)
	file.store_string(JSON.stringify(result))
	file.close()
	DirAccess.rename_absolute(directory + "/response.tmp", directory + "/response.json")


func _process(_delta: float) -> bool:
	if main == null or not watch_progress:
		return false
	var loading = main._large_world.loading
	var key := (
		"%d/%s/%d/%d/%s"
		% [loading.generation, loading.phase, loading.completed, loading.total, loading.playable]
	)
	if key != last_progress:
		last_progress = key
		var state := snapshot()
		state.erase("identity")
		state["msec"] = Time.get_ticks_msec()
		var file := FileAccess.open(directory + "/progress.ndjson", FileAccess.READ_WRITE)
		if file == null:
			file = FileAccess.open(directory + "/progress.ndjson", FileAccess.WRITE)
		file.seek_end()
		file.store_line(JSON.stringify(state))
		file.close()
		var bucket := (
			"%d-%s-%d"
			% [
				loading.generation,
				loading.phase,
				floori(4.0 * loading.completed / maxi(1, loading.total))
			]
		)
		if not phase_captures.has(bucket) and not capture_busy:
			phase_captures[bucket] = true
			capture_busy = true
			capture_progress.call_deferred(bucket)
	return false


func capture_progress(bucket: String) -> void:
	await capture("generation-" + bucket.to_lower().replace(" ", "-"))
	capture_busy = false


func capture(name: String) -> void:
	await RenderingServer.frame_post_draw
	var image := root.get_texture().get_image()
	image.save_png(directory + "/" + name + ".png")
	var state := snapshot()
	state.erase("identity")
	var file := FileAccess.open(directory + "/" + name + ".json", FileAccess.WRITE)
	file.store_string(JSON.stringify(state, "\t"))
	file.close()


func key(code: Key, ctrl := false, target: Window = null) -> void:
	if target == null:
		target = root
	for pressed in [true, false]:
		var event := InputEventKey.new()
		event.keycode = code
		event.pressed = pressed
		event.ctrl_pressed = ctrl
		event.window_id = target.get_window_id()
		Input.parse_input_event(event)
		await process_frame


func click(control: Control) -> void:
	if control == null or not control.is_visible_in_tree():
		driver_error = (
			"Control not visible: "
			+ (str(control.get_path()) if control != null else "missing named button")
		)
		return
	var parent := control.get_parent()
	while parent != null:
		if parent is ScrollContainer:
			parent.ensure_control_visible(control)
		parent = parent.get_parent()
	await process_frame
	control.grab_focus()
	var point := control.get_global_rect().get_center()
	var motion := InputEventMouseMotion.new()
	motion.position = point
	root.push_input(motion)
	for pressed in [true, false]:
		var event := InputEventMouseButton.new()
		event.position = point
		event.button_index = MOUSE_BUTTON_LEFT
		event.pressed = pressed
		root.push_input(event)
		await process_frame


func named(node: Node, text: String) -> Button:
	if node is Button and node.text == text and node.is_visible_in_tree():
		return node
	for child in node.get_children():
		var found := named(child, text)
		if found != null:
			return found
	return null


func input_text(control: LineEdit, text: String) -> void:
	await click(control)
	await key(KEY_A, true)
	for character in text:
		var event := InputEventKey.new()
		event.unicode = character.unicode_at(0)
		event.pressed = true
		root.push_input(event)
	await process_frame


func map_only(value: bool) -> void:
	if main.workspace.map_only != value:
		await key(KEY_BACKSLASH, true)


func build_view() -> void:
	await map_only(false)
	await click(main.workspace._tab_buttons["build"])


func camera(x: float, y: float, pixels: float) -> void:
	var map = main.map
	map.pan_by(map.size * 0.5 - map.world_to_screen(Vector2(x, y)))
	map.zoom_at(pixels / maxf(map._cell_size(), 0.0001), map.size * 0.5)
	var motion := InputEventMouseMotion.new()
	motion.position = Vector2(4, 4)
	root.push_input(motion)
	await process_frame


func gesture(x: int, y: int, width: int, depth: int) -> void:
	await map_only(true)
	await camera(x + width * 0.5, y + depth * 0.5, 32)
	var map = main.map
	var start: Vector2 = map.get_global_transform() * map.world_to_screen(Vector2(x + 0.5, y + 0.5))
	var finish: Vector2 = (
		map.get_global_transform() * map.world_to_screen(Vector2(x + width - 0.5, y + depth - 0.5))
	)
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
	driver_error = ""
	match command.action:
		"status":
			pass
		"capture":
			await capture(command.name)
		"watch":
			watch_progress = command.enabled
		"early_attempt":
			var before := snapshot()
			await click(main._construction_panel.activate)
			# Keep the probe away from the overlay's real Disconnect button.
			var point: Vector2 = (
				main.map.get_global_rect().position + main.map.size * Vector2(0.4, 0.8)
			)
			for pressed in [true, false]:
				var event := InputEventMouseButton.new()
				event.position = point
				event.button_index = MOUSE_BUTTON_LEFT
				event.pressed = pressed
				root.push_input(event)
				await process_frame
			answer(
				{
					"before_attempt":
					{"ready": before.ready, "phase": before.phase, "overlay": before.overlay}
				}
			)
			return
		"servers":
			await click(named(main._menu, "Servers"))
		"join":
			await input_text(main._server_management._join_host, command.host)
			await input_text(main._server_management._join_database, command.database)
			await capture("02-private-server-input")
			await click(main._server_management._join_button)
		"resize":
			root.size = Vector2i(command.width, command.height)
			for frame in 4:
				await process_frame
		"camera":
			await camera(command.x, command.y, command.pixels)
		"navigate_capture":
			await camera(command.x, command.y, command.pixels)
			await capture(command.name)
		"hover_capture":
			var motion := InputEventMouseMotion.new()
			motion.position = main.map.get_global_transform() * (main.map.size * 0.5)
			root.push_input(motion)
			await create_timer(1.0).timeout
			await capture(command.name)
			answer({"tooltip": main.map._get_tooltip(main.map.size * 0.5)})
			return
		"map_only":
			await map_only(command.enabled)
		"build_view":
			await build_view()
		"scale":
			await click(main._session_menu)
			var popup: PopupMenu = main._session_menu.get_popup()
			await key(KEY_HOME, false, popup)
			await key(KEY_DOWN, false, popup)
			await key(KEY_DOWN, false, popup)
			await key(KEY_ENTER, false, popup)
			await click(named(main._menu, "Settings"))
			await click(main._menu._ui_scale)
			var options: PopupMenu = main._menu._ui_scale.get_popup()
			await key(KEY_HOME, false, options)
			for index in ClientSettings.UI_SCALES.find(int(command.percent)):
				await key(KEY_DOWN, false, options)
			await key(KEY_ENTER, false, options)
			await click(main._menu._last_button)
		"fit":
			await click(main._map_zoom_buttons["fit"])
		"cut":
			while main.map.terrain_model.cut != int(command.z):
				var previous: int = main.map.terrain_model.cut
				await click(main._map_layer_buttons[1 if previous < int(command.z) else -1])
				if main.map.terrain_model.cut == previous:
					driver_error = "cut toolbar did not move"
					break
		"select":
			await build_view()
			await click(main._construction_panel.inspect)
			await gesture(command.x, command.y, 1, 1)
		"draw":
			await build_view()
			var panel = (
				main._construction_panel if command.system == "construction" else main._zones_panel
			)
			if command.system == "zones":
				await click(panel.choices[ContinuumTileKind.Options.storage])
			await click(panel.activate)
			await gesture(command.x, command.y, command.width, command.depth)
			var pending: bool = main._intent_request != null
			var feedback: String = main._intent_feedback.text
			await capture(command.get("name", "planning-request"))
			answer({"observed_pending": pending, "pending_feedback": feedback})
			return
		"key":
			await key(int(command.code), command.get("ctrl", false))
		"quit":
			main.leave_session()
			answer()
			quit()
			return
	answer()
