## Actual main scene fed generated typed local rows, never a live SDK connection.
extends Node

const MainScene = preload("res://tools/ui_main_fixture.tscn")
const TerrainFixture = preload("res://tools/terrain_fixture.gd")
var failures: Array[String] = []
var main: Control
var local: LocalDatabase
var _previous_db: ContinuumModuleDb
var _capture := ""
var _problem := false
var _focus := false
var _reduced := false
var _screen := Vector2i(1440, 900)
var _scale := 100
var _layout_qa := false
var _floating := false
var _digest_capture := false


func _ready() -> void:
	for argument: String in OS.get_cmdline_user_args():
		if argument.begins_with("--screen="):
			var parts := argument.trim_prefix("--screen=").split("x")
			_screen = Vector2i(int(parts[0]), int(parts[1]))
		elif argument.begins_with("--scale="):
			_scale = int(argument.trim_prefix("--scale="))
		elif argument == "--status=problem":
			_problem = true
		elif argument == "--reduced-motion":
			_reduced = true
		elif argument == "--focus":
			_focus = true
		elif argument == "--layout-qa":
			_layout_qa = true
		elif argument == "--floating":
			_floating = true
		elif argument == "--digest":
			_digest_capture = true
		elif argument.begins_with("--capture="):
			_capture = argument.trim_prefix("--capture=")
	get_window().size = _screen
	_previous_db = SpacetimeDB.Continuum.db
	_seed_database()
	main = MainScene.instantiate()
	get_tree().root.add_child.call_deferred(main)
	await get_tree().process_frame
	main._host = "http://fixture.invalid"
	main._database = "fixture-colony"
	main._authenticated_identity = "typed-local-fixture-identity"
	main._return_key = ReturnSnapshots.context_key(main._host, main._database, main._profile, main._authenticated_identity)
	main._return_snapshots.forget(main._return_key)
	main._session_requested = true
	main._state_ready = true
	main._menu.hide()
	main._server_management.hide()
	main._set_permissions("operator", true, false)
	var settings: ClientSettings = main._settings.clone()
	settings.ui_scale_percent = _scale
	settings.reduced_motion = _reduced
	main.apply_settings(settings, false)
	main._sync_menu_input()
	main.map.bind_world_source(SpacetimeDB.Continuum.db)
	main.map.refresh()
	main._refresh()
	# Measure real stock/need changes with a full game-hour of minute observations.
	var config: ContinuumConfig = local._tables.config[0]
	var colony: ContinuumColony = local._tables.colony[0]
	for minute in range(1, 61):
		config.game_seconds = minute * 60.0
		colony.food = 100.0 - minute if _problem else 100.0
		main._observe_session_state()
	main._full_ui_refresh = true
	main._refresh()
	main._select_colonist(0)
	if _focus:
		main.workspace.switch_workspace("welfare")
		if main.workspace.compact and main.workspace._compact_panel != "people":
			main.workspace.toggle_panel("people")
	if _floating:
		if not main.workspace.windows.people.visible:
			main.workspace.toggle_panel("people")
	for frame in 8:
		await get_tree().process_frame
	await _check_functional_contracts()
	_check_typography(main)
	if _layout_qa:
		await _check_floating_input()
		await _check_roster_layout_and_input()
		await _check_tick_focus()
		_check_day_readouts(main._feed)
	_check_contrast(main._colonist_cards[0], ThemeTokens.color("bg-100"))
	if _digest_capture:
		main._show_away_digest()
		for frame in 3:
			await get_tree().process_frame
	if not _capture.is_empty() and DisplayServer.get_name() != "headless":
		await RenderingServer.frame_post_draw
		var image := get_viewport().get_texture().get_image()
		check(image.get_size() == _screen, "actual main viewport capture matches requested size")
		check(image.save_png(_capture) == OK, "actual main viewport capture saves")
	if failures.is_empty():
		print("UI_LIVE_FIXTURE_PASS screen=%s scale=%d status=%s reduced_motion=%s focus=%s layout_qa=%s" % [_screen, _scale, "problem" if _problem else "nominal", _reduced, _focus, _layout_qa])
	else:
		for message: String in failures:
			push_error("UI_LIVE_FIXTURE_FAIL: " + message)
	main._state_ready = false
	main._return_key = ""
	for frame in 4:
		await get_tree().process_frame
	main.free()
	SpacetimeDB.Continuum.db = _previous_db
	local.free()
	get_tree().quit(0 if failures.is_empty() else 1)


func _seed_database() -> void:
	var builder := preload("res://tools/map_client_profile.gd").new()
	builder.edge = 24
	local = builder.database()
	builder.free()
	var config: ContinuumConfig = local._tables.config[0]
	config.game_seconds = 0.0
	config.generation = 7
	config.time_scale = 6.0
	var colony: ContinuumColony = local._tables.colony[0]
	colony.food = 100.0
	colony.wood = 160.0
	colony.stone = 90.0
	colony.meat = 20.0
	colony.population = 8
	colony.avg_mood = 72.0
	colony.avg_productivity = 86.0
	colony.smoothed_mood = 70.0
	colony.smoothed_productivity = 84.0
	for id: int in local._tables.colonist:
		var row: ContinuumColonist = local._tables.colonist[id]
		row.name = ["Alexandria Verylongfamilyname", "Bram", "Finn", "Enid", "Mara", "Otis", "Rin", "Sora"][id]
		row.hunger = 92.0 if _problem and id == 0 else 10.0
		row.fatigue = 72.0 if _problem and id == 1 else 12.0
		row.recreation = 10.0
		row.mood = 72.0
		row.productivity = 86.0
		row.x = 8 + id
		row.y = 8
		row.z = 0
		row.next_x = row.x
		row.next_y = row.y
		row.next_z = 0
	local._tables.alert.clear()
	if _problem:
		for id in 2:
			var alert := ContinuumAlert.new()
			alert.id = id + 1
			alert.code = "low_food" if id == 0 else "low_mood"
			alert.message = "Food reserves are low (40 stored, 5 per colonist)." if id == 0 else "Average colonist mood dropped below 45% (42%)."
			alert.severity = ContinuumSeverity.create(2 if id == 0 else 1)
			alert.active = true
			alert.acknowledged = id == 1
			alert.raised_game_seconds = 0.0
			local._tables.alert[alert.id] = alert
	for id in 4:
		var event := ContinuumEventLog.new()
		event.id = id + 1
		event.day = 1
		event.hour = 0
		event.minute = id
		event.game_seconds = id * 60.0
		event.message = "Bram started hauling" if id < 2 else ("[literal] kestrel changed an order" if id == 2 else "Alert resolved: low food")
		event.severity = ContinuumSeverity.create(0)
		local._tables.event_log[event.id] = event
	TerrainFixture.index_rows(local)


func _check_functional_contracts() -> void:
	check(main.forbidden_connections == 0, "fixture never requests an SDK connection")
	var icon_notice := FileAccess.get_file_as_string("res://ui/theme/icons/LICENSE")
	check("ISC License" in icon_notice and "The MIT License (MIT)" in icon_notice and "Cole Bemis" in icon_notice, "licensed icon notices survive a real exported PCK")
	for name: String in UiIcons.NAMES:
		var texture := UiIcons.texture(name)
		check(texture != null and texture.get_size() == Vector2(16, 16) and not texture.get_image().is_invisible(), "runtime icon geometry rasterizes from source or real PCK: " + name)
	check(main._metrics.base_font_size == 13 and is_equal_approx(get_window().content_scale_factor, _scale / 100.0), "viewport is sole scale authority")
	check(main._colonist_cards[0] is RosterRow and main._selected_card is ColonistCard and main._selected_card.visible, "actual main uses compact roster plus selected expanded card")
	var fed: Dictionary = main._selected_card.model.needs[0]
	check(is_equal_approx(fed.value, 8.0 if _problem else 90.0), "raw hunger is inverted exactly once")
	check(fed.trend == "flat", "stable arrow requires an actual game-hour lookback")
	check(not main._selected_card.model.has("commands") and not main._selected_card.model.has("automation_rules"), "no unsupported rest order or fictional automation")
	check(main._resource_labels[0] is ResourceReadout, "actual main uses resource readout controls")
	check(main.workspace.telemetry.get_combined_minimum_size().y <= ThemeTokens.number("topbar") + 1, "resource estimates cannot inflate the 40px logical topbar content")
	check(main._alert_box is AlertList and main._feed is ActivityFeed, "actual main uses alert and activity components")
	check(main._return_digest.baseline_available == false, "first visit invents no return baseline")
	check(main._connection_label.text == "Live" and main._connection_label.get_theme_color("font_color") == ThemeTokens.color("ink-muted"), "healthy connection is neutral")
	check(main._identity_label.get_theme_color("font_color") == ThemeTokens.color("accent"), "actual authenticated identity and verified role use accent")
	if _problem:
		var critical: AlertRow = main._alert_box.get_child(0)
		check(critical.model.level == "critical" and critical.is_processing() == (not _reduced), "critical pulse obeys reduced motion (preference=%s row=%s processing=%s)" % [_reduced, critical.reduced_motion, critical.is_processing()])
		var border_before: Color = critical._border.border_color
		await get_tree().create_timer(0.6).timeout
		check(critical._border.border_color == border_before if _reduced else critical._border.border_color != border_before, "actual critical border animates only with motion enabled")
		check(critical.model.ack_handle.is_empty() and critical.model.ack_time.is_empty(), "shared boolean acknowledgement has no invented actor/time")
		main._set_permissions("viewer", false, false)
		main._acknowledge(1)
		check(main.recorded_acknowledgements.is_empty(), "viewer cannot dispatch acknowledgement")
		check(_find_button(main._alert_box, "Acknowledge") == null, "viewer has no acknowledgement command")
		main._set_permissions("operator", true, false)
		main._acknowledge(1)
		main._acknowledge(1)
		check(main.recorded_acknowledgements.size() == 1 and main._ack_requests.has(1), "pending acknowledgement suppresses duplicate dispatch")
		check(not local._tables.alert[1].acknowledged, "pending intent cannot optimistically change shared acknowledgement")
		var rejected := ReducerResultMessage.new()
		rejected.reducer_result = ReducerOutcomeEnum.create_internal_error("fixture rejection")
		main.fixture_ack_calls[0].response.emit(rejected)
		check(not main._ack_requests.has(1) and "fixture rejection" in main._alert_box.get_child(0).error_copy, "actual reducer error callback leaves shared state unchanged and exposes failure")
		main._acknowledge(1)
		var accepted := ReducerResultMessage.new()
		accepted.reducer_result = ReducerOutcomeEnum.create_ok_empty()
		main.fixture_ack_calls[1].response.emit(accepted)
		check(main._ack_requests.has(1) and not local._tables.alert[1].acknowledged, "accepted response still waits for authoritative shared acknowledgement")
		local._tables.alert[1].acknowledged = true
		main._refresh_alerts()
		await get_tree().process_frame
		check(not main._ack_requests.has(1) and main._alert_box.get_child(0).model.acknowledged and not main._alert_box.get_child(0).is_processing(), "replicated acknowledgement reconciles pending and stops critical pulse")
		local._tables.alert[1].acknowledged = false
		main._refresh_alerts()
		main._acknowledge(1)
		var stale: SpacetimeDBReducerCall = main.fixture_ack_calls[-1]
		main._set_permissions("viewer", false, false)
		stale.response.emit(rejected)
		check(main._ack_requests.is_empty(), "permission revocation invalidates pending acknowledgement callbacks")
		main._set_permissions("operator", true, false)
		main._acknowledge(1)
		stale = main.fixture_ack_calls[-1]
		main._session_generation += 1
		main._ack_requests.clear()
		main._alert_box.set_acknowledgement_state(1, false)
		stale.response.emit(rejected)
		check(main._alert_box.get_child(0).error_copy.is_empty(), "old-session acknowledgement callback cannot change new-session feedback")
	main._goto_colonist(0)
	check(main.map.selected_colonist_id == 0, "roster selection reaches actual map selection contract including ID zero")
	var center: Vector2 = main.map.world_to_screen(Vector2(8.5, 8.5))
	check(center.distance_to(main.map.size * 0.5) < 1.0, "Go to centers actual observed coordinates")
	check(main.map.screen_to_world(center).distance_to(Vector2(8.5, 8.5)) < 0.001, "actual map coordinate picking survives global scale and floating overlays")
	var focus: Control = main._colonist_cards[0] if main._colonist_cards[0].is_visible_in_tree() else _find_button(main, "Menu")
	if _focus and focus != null:
		focus.grab_focus()
	main._show_away_digest()
	check(main.workspace.process_mode == Node.PROCESS_MODE_DISABLED and main.map.process_mode == Node.PROCESS_MODE_DISABLED, "away digest blocks background map and workspace input")
	main._hide_away_digest()
	check(main.workspace.process_mode == Node.PROCESS_MODE_INHERIT and main.map.process_mode == Node.PROCESS_MODE_INHERIT, "digest dismissal restores workspace input")
	if _focus and focus != null:
		check(get_viewport().gui_get_focus_owner() == focus, "digest dismissal restores keyboard focus")
	for row: Dictionary in _all_event_models():
		check(not row.has("actor") and not row.has("source"), "raw event messages stay unattributed")
	var map_rect: Rect2 = main.map.get_global_rect()
	check(map_rect == main.workspace.area.get_global_rect(), "all panels overlay the full workspace map without reserving geometry")
	check(not main.workspace.has_method("set_panel_dock"), "no docking API remains")
	for window: WorkspaceWindow in main.workspace.windows.values():
		check(window.get_parent() == main.workspace.area and not window.has_signal("dock_requested"), "every panel is a direct overlay with no docking controls")
		if window.visible:
			check(window.size.x >= 280, "visible panels retain 280 logical pixel minimum")
			if not main.workspace.compact:
				var surface: StyleBox = window.get_theme_stylebox("panel")
				check(not surface is StyleBoxFlat and surface.shadows.size() == 2, "actual floating frame uses the foundation two-layer shadow")
			check(_find_button(window, "Dock") == null and _find_button(window, "Float") == null, "no Dock/Float UI is exposed")
	check(main._session_observations.resource("food").rate_available, "rendered composition retains its actual observed one-hour rate")


func _all_event_models() -> Array:
	var rows: Array = []
	for row: ContinuumEventLog in SpacetimeDB.Continuum.db.event_log.iter():
		rows.append(UiData.event(row))
	return rows

func _pointer_button(pressed: bool, point: Vector2) -> InputEventMouseButton:
	var event := InputEventMouseButton.new()
	event.button_index = MOUSE_BUTTON_LEFT
	event.pressed = pressed
	event.position = point
	event.global_position = point
	return event

func _pointer_drag(start: Vector2, delta: Vector2) -> void:
	await _native_pointer(_pointer_button(true, start))
	var motion := InputEventMouseMotion.new()
	motion.position = start + delta
	motion.global_position = motion.position
	motion.relative = delta
	motion.button_mask = MOUSE_BUTTON_MASK_LEFT
	motion.alt_pressed = true
	await _native_pointer(motion)
	await _native_pointer(_pointer_button(false, start + delta))

func _native_pointer(event: InputEventMouse) -> void:
	event.position = get_viewport().get_final_transform() * event.position
	event.global_position = event.position
	Input.parse_input_event(event)
	await get_tree().process_frame
	await get_tree().process_frame

func _check_floating_input() -> void:
	# Functional callback checks may just have revealed the action banner.
	# Settle top-level container geometry before measuring panel-only effects.
	for frame in 4:
		await get_tree().process_frame
	var window: WorkspaceWindow = main.workspace.windows.people
	var map_rect: Rect2 = main.map.get_global_rect()
	if not main.workspace.compact:
		var saved: Dictionary = main.workspace.state("people").duplicate(true)
		main.workspace.state("people").pinned = false
		main.workspace.state("people").rect = [0.15, 0.15, 0.5, 0.65]
		main.workspace._apply_layout()
		window.move_to_front()
		await get_tree().process_frame
		var origin := window.position
		await _pointer_drag(window.titlebar.global_position + Vector2(70, 14), Vector2(18, 12))
		check(window.position.distance_to(origin + Vector2(18, 12)) < 1, "production titlebar pointer drag uses logical global coordinates at current UI scale")
		var before := window.size
		await _pointer_drag(window.grip.get_global_rect().get_center(), Vector2(20, 16))
		check(window.size.distance_to(before + Vector2(20, 16)) < 1, "production resize corner receives pointer input without clipping")
		main.workspace.model.show_panel_headers = false
		main.workspace._apply_layout()
		await get_tree().process_frame
		origin = window.position
		await _pointer_drag(window.drag_strip.global_position + Vector2(70, 12), Vector2(16, 10))
		check(window.position.distance_to(origin + Vector2(16, 10)) < 1 and window.drag_strip.visible, "hidden headers retain a working discoverable pointer drag strip")
		main.workspace.state("people").pinned = true
		main.workspace._apply_layout()
		origin = window.position
		await _pointer_drag(window.drag_strip.global_position + Vector2(70, 12), Vector2(16, 10))
		check(window.position == origin and not window.grip.visible, "pin alone locks floating geometry")
		main.workspace.model.show_panel_headers = true
		main.workspace.model.workspaces[main.workspace.model.active].panels.people = saved
		main.workspace._apply_layout()
	check(main.map.get_global_rect() == map_rect, "moving/resizing/pinning overlays never changes map geometry")
	var world_point := Vector2(8.5, 8.5)
	var global_point: Vector2 = main.map.get_global_transform() * main.map.world_to_screen(world_point)
	check(main.map.screen_to_world(main.map.get_global_transform().affine_inverse() * global_point).distance_to(world_point) < 0.001, "global map picking round-trips at actual UI scale after panel input")
	main.workspace.edit_workspace(false)
	await get_tree().process_frame
	check(main.workspace._dialog.visible and main.workspace.blocks_map_input(map_rect.get_center()), "workspace popup blocks map input over the full map")
	var popup_focus: Control = main.workspace._dialog.gui_get_focus_owner()
	check(popup_focus != null and main.workspace._dialog.is_ancestor_of(popup_focus), "workspace popup retains keyboard focus inside its own viewport controls")
	main.workspace._dialog.hide()
	await get_tree().process_frame


func _find_button(node: Node, text: String) -> Button:
	if node is Button and node.text == text:
		return node
	for child: Node in node.get_children():
		var found := _find_button(child, text)
		if found != null:
			return found
	return null


func _check_typography(node: Node) -> void:
	if node is Label or node is Button:
		check(node.get_theme_font_size("font_size") >= 11, "no text below 11 logical pixels")
	for child: Node in node.get_children():
		_check_typography(child)


func _check_roster_layout_and_input() -> void:
	var window: WorkspaceWindow = main.workspace.windows.people
	if not window.visible:
		return
	var viewport := window.scroll.get_global_rect()
	for row: RosterRow in main._colonist_cards.values():
		var rect := row.get_global_rect()
		check(rect.position.x >= viewport.position.x and rect.end.x <= viewport.end.x + 1, "roster fits actual panel viewport without horizontal clipping: %s row=%s viewport=%s" % [row.model.name, rect, viewport])
	var expanded: Rect2 = main._selected_card.get_global_rect()
	check(expanded.end.x <= viewport.end.x + 1, "expanded needs and actions fit panel viewport at 280 logical pixel minimum")
	var other: RosterRow = main._colonist_cards[1]
	var point := other.get_global_rect().get_center()
	if viewport.has_point(point):
		for pressed: bool in [true, false]:
			var click := InputEventMouseButton.new()
			click.position = point
			click.button_index = MOUSE_BUTTON_LEFT
			click.pressed = pressed
			get_viewport().push_input(click, true)
		await get_tree().process_frame
		check(main._selected_colonist == 1, "actual GUI pick reaches roster selection through decorative descendants")
		main._select_colonist(0)


func _check_tick_focus() -> void:
	var button := _find_button(main._selected_card, "Go to")
	if button == null or not button.is_visible_in_tree():
		return
	button.grab_focus()
	var actor: ContinuumColonist = local._tables.colonist[0]
	var original := actor.hunger
	actor.hunger = original + 0.1
	main._refresh_colonists()
	check(get_viewport().gui_get_focus_owner() == button and is_instance_valid(button), "changing authoritative need values retains the focused Go to control")
	actor.hunger = original
	main._refresh_colonists()
	for frame in 6:
		await get_tree().process_frame
	check(main.workspace._visible_control_rect(button).encloses(button.get_global_rect()), "focused expanded-card action is fully onscreen through nested scrolling")


func _check_contrast(node: Node, ground: Color) -> void:
	if node is PanelContainer:
		var style: StyleBox = node.get_theme_stylebox("panel")
		if style is StyleBoxFlat and style.bg_color.a == 1.0:
			ground = style.bg_color
	if node is Label:
		var ink: Color = node.get_theme_color("font_color")
		var a := _luminance(ink)
		var b := _luminance(ground)
		check((maxf(a, b) + 0.05) / (minf(a, b) + 0.05) >= 4.5, "selected roster label has readable contrast on its actual nested ground: " + node.text)
	for child: Node in node.get_children():
		_check_contrast(child, ground)


func _luminance(color: Color) -> float:
	var linear := color.srgb_to_linear()
	return linear.r * 0.2126 + linear.g * 0.7152 + linear.b * 0.0722


func _check_day_readouts(node: Node) -> void:
	if node is Label:
		var text: String = node.text
		var day_number := text.to_upper().begins_with("DAY") and text.substr(3).strip_edges().is_valid_int()
		if day_number or text.is_valid_int():
			check("Mono" in node.get_theme_font("font").get_font_name(), "activity day number is a mono readout, not condensed text")
	for child: Node in node.get_children():
		_check_day_readouts(child)


func check(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)
