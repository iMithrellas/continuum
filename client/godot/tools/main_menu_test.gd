extends Node

const MenuScene = preload("res://scenes/main_menu.tscn")

var failed := false

func _ready() -> void:
	var settings := ClientSettings.new()
	var path := "user://main_menu_test_%d.cfg" % Time.get_ticks_usec()
	settings.save_to(path)
	var restored := ClientSettings.new()
	restored.load_from(path)
	_assert(restored.server_host.is_empty() and restored.database.is_empty(), "last server is absent by default")
	_assert(restored.font_size == ClientSettings.DEFAULT_FONT_SIZE, "default font size is stable")
	_assert(UiMetrics.new(ClientSettings.MIN_FONT_SIZE).base_font_size == ClientSettings.MIN_FONT_SIZE, "font minimum clamps")
	_assert(UiMetrics.new(ClientSettings.MAX_FONT_SIZE).base_font_size == ClientSettings.MAX_FONT_SIZE, "font maximum clamps")
	restored.remember_server("http://example.test", "continuum", path)
	var persisted := ClientSettings.new()
	persisted.load_from(path)
	_assert(persisted.server_host == "http://example.test" and persisted.database == "continuum", "successful endpoint persists")
	DirAccess.remove_absolute(ProjectSettings.globalize_path(path))

	var menu: ContinuumMainMenu = MenuScene.instantiate()
	add_child(menu)
	menu.setup(null, ClientSettings.new(), UiMetrics.new())
	var buttons := menu.find_children("*", "Button", true, false)
	var expected_buttons := ["Join last server", "Disconnect", "Servers", "Settings", "Exit", "Reduce motion", "Show diagnostics", "Show frame/RTT graph", "100%"]
	_assert(buttons.size() == expected_buttons.size(), "menu contains only navigation, join-last, and display/diagnostics controls")
	for button: Button in buttons:
		_assert(expected_buttons.has(button.text), "no direct join, local lifecycle, or autostart control: " + button.text)
	for line: LineEdit in menu.find_children("*", "LineEdit", true, false):
		_assert(menu._ui_scale.is_ancestor_of(line), "only the UI-scale popup may contain an internal search input: " + str(line.get_path()))
	var server_menu_opened := [0]
	menu.server_management_requested.connect(func() -> void: server_menu_opened[0] += 1)
	_button(menu, "Servers").pressed.emit()
	_assert(server_menu_opened[0] == 1, "Servers entry emits standalone browser navigation")
	var exit_requests := [0]
	menu.exit_requested.connect(func() -> void: exit_requests[0] += 1)
	_button(menu, "Exit").pressed.emit()
	_assert(exit_requests[0] == 1, "Exit remains available")
	var joins: Array[Dictionary] = []
	menu.join_requested.connect(func(host: String, database: String) -> void:
		joins.append({"host": host, "database": database})
		_assert(menu._last_button.disabled, "join-last is busy before dispatch")
		_assert(menu._status.text == "Connecting to %s / %s ..." % [host, database], "join status includes the stored endpoint"))
	_assert(menu._last_button.disabled, "join last is disabled without a successful endpoint")
	menu._join_last()
	menu.set_busy(false)
	_assert(joins.is_empty() and menu._last_button.disabled, "clearing busy does not enable an absent last endpoint")
	_assert(menu._ui_scale.item_count == 3 and menu._ui_scale.get_item_id(2) == 150,
		"settings expose only 100/125/150 percent UI scales")
	_button(menu, "Settings").pressed.emit()
	_assert(menu._settings_panel.visible, "settings are reachable from the menu")
	_assert(not menu._diagnostics_toggle.button_pressed and menu._graph_toggle.disabled, "diagnostics graph is subordinate by default")
	var settings_changes := [0]
	menu.settings_changed.connect(func(_settings: ClientSettings) -> void: settings_changes[0] += 1)
	menu._diagnostics_toggle.button_pressed = true
	_assert(menu.settings.diagnostics_enabled and not menu._graph_toggle.disabled, "diagnostics toggle enables graph control")
	menu._graph_toggle.button_pressed = true
	_assert(menu.settings.diagnostics_graph_enabled, "graph toggle persists independently")
	menu._diagnostics_toggle.button_pressed = false
	_assert(not menu.settings.diagnostics_enabled and not menu.settings.diagnostics_graph_enabled and menu._graph_toggle.disabled, "disabling diagnostics clears subordinate graph")
	menu._ui_scale.item_selected.emit(2)
	_assert(menu.settings.ui_scale_percent == 150 and menu.settings.font_size == 13, "scale control keeps base token fonts normalized")
	menu._reduced_motion.button_pressed = true
	_assert(menu.settings.reduced_motion and settings_changes[0] >= 5, "motion and scale controls emit settings updates")
	menu.apply_metrics(UiMetrics.new(24))
	_assert(menu.theme.default_font_size == 13 and menu.metrics.scale == 1, "legacy metrics cannot double-scale the new menu")
	menu._toggle_settings()

	for endpoint: Array in [["localhost:3000", "continuum"], ["http://localhost", "bad name"]]:
		menu.settings.server_host = endpoint[0]
		menu.settings.database = endpoint[1]
		menu.show_menu()
		menu._last_button.pressed.emit()
		_assert(joins.is_empty() and not menu._last_button.disabled, "invalid stored endpoints do not dispatch or stay busy")
		_assert(menu._error.text == ContinuumServerManagement.validate_endpoint(endpoint[0], endpoint[1]), "join-last uses shared browser validation")
	menu.settings.server_host = "  https://[2001:db8::1]:443  "
	menu.settings.database = "  continuum-home  "
	menu.visible = false
	menu.show_menu()
	_assert(menu.visible and not menu._last_button.disabled, "show_menu refreshes the remembered endpoint")
	_assert(menu._last_button.tooltip_text.contains("continuum-home"), "join-last tooltip identifies the endpoint")
	menu._last_button.pressed.emit()
	_assert(joins == [{"host": "https://[2001:db8::1]:443", "database": "continuum-home"}], "join-last emits the trimmed stored endpoint without line edits")
	_assert(menu._error.text.is_empty(), "valid join clears prior validation errors")
	menu._join_last()
	_assert(joins.size() == 1, "busy join-last cannot dispatch twice")
	for text: String in ["Servers", "Settings", "Exit"]:
		_assert(not _button(menu, text).disabled, "busy leaves " + text + " available")
	_assert(not menu._ui_scale.disabled and not menu._diagnostics_toggle.disabled, "busy leaves display and diagnostics settings available")
	menu.join_failed("Connection failed")
	_assert(not menu._last_button.disabled and menu._status.text == "Warning · Connection failed", "failed joins release busy and show the failure")
	_assert(menu._status.get_theme_color("font_color") == ThemeTokens.color("warn") and menu._status_glyph.texture != null, "failed join uses warning glyph and token")
	menu._last_button.pressed.emit()
	_assert(joins.size() == 2, "failed join can be retried")
	menu.show_menu()
	_assert(not menu._last_button.disabled, "returning to the menu releases busy")
	menu.queue_free()
	await _test_layout()
	await _test_controller_resume()
	await _test_sdk_menu_route()

	if failed:
		get_tree().quit(1)
		return
	print("MAIN_MENU_PASS")
	get_tree().quit(0)

func _test_layout() -> void:
	for font_size: int in [100, 125, 150]:
		var menu: ContinuumMainMenu = MenuScene.instantiate()
		add_child(menu)
		menu.set_anchors_and_offsets_preset(Control.PRESET_TOP_LEFT)
		var logical_size := Vector2(360, 480) / (float(font_size) / 100.0)
		menu.size = logical_size
		var settings := ClientSettings.new()
		settings.ui_scale_percent = font_size
		menu.setup(null, settings, settings.ui_metrics())
		menu._toggle_settings()
		menu.set_status("Connecting to http://" + "longhostname".repeat(8) + " / continuum-home ...")
		menu._error.text = "A long connection failure remains readable without widening the launch menu."
		for _frame in 4:
			await get_tree().process_frame
		var scroll: ScrollContainer = menu.find_child("MenuScroll", true, false)
		_assert(scroll != null and scroll.follow_focus, "small menu provides keyboard-following scrolling")
		_assert(menu.get_global_rect().encloses(scroll.get_global_rect()), "scroll viewport fits 360x480 at font %d" % font_size)
		for control: Control in menu.find_children("*", "Control", true, false):
			if not control.is_visible_in_tree():
				continue
			var rect := control.get_global_rect()
			_assert(rect.position.x >= -0.5 and rect.end.x <= logical_size.x + 0.5, "scale %d control fits horizontally: %s" % [font_size, control.name])
		_assert(menu._status.get_line_count() > 1 and menu._error.get_line_count() > 1, "status and errors wrap in narrow menus")
		_assert(not scroll.get_h_scroll_bar().visible, "narrow menu never needs horizontal scrolling")
		scroll.ensure_control_visible(menu._graph_toggle)
		await get_tree().process_frame
		_assert(scroll.scroll_vertical > 0 and scroll.get_global_rect().encloses(menu._graph_toggle.get_global_rect()), "scrolling reaches the final settings control at font %d" % font_size)
		menu.queue_free()
		await get_tree().process_frame

func _test_controller_resume() -> void:
	var fixture = preload("res://tools/main_menu_controller_fixture.gd")
	var previous := SpacetimeDB.Continuum
	var client = fixture.ClientFixture.new()
	SpacetimeDB.add_child(client)
	SpacetimeDB.Continuum = client
	var main = preload("res://scenes/main.tscn").instantiate()
	main.set_script(fixture)
	add_child(main)
	main.set_process(false)
	main._settings.server_host = "http://menu-fixture.test"
	main._settings.database = "colony"
	main._menu.show_menu()
	main._menu._last_button.pressed.emit()
	_assert(main.starts == 1 and client.connects == 1 and client.subscriptions == 1, "cold last-server join connects and subscribes once")
	main._menu.show_menu()
	_assert(main._menu._last_button.text == "Join last server" and not main._can_resume_colony(), "half-ready connection cannot resume")
	var subscription: SpacetimeDBSubscription = main._subscription
	subscription.applied.emit()
	var generation: int = main._session_generation
	var bindings: int = main._client_bindings.size()
	var return_key: String = main._return_key
	var snapshot: Dictionary = main._return_snapshot.duplicate(true)
	var digest: Dictionary = main._return_digest.duplicate(true)
	var ready_events := [0]
	main.session_ready.connect(func() -> void: ready_events[0] += 1)
	main._menu.show_menu()
	_assert(main._menu._last_button.text == "Resume colony", "ready connected menu offers Resume colony")
	main._menu._toggle_settings()
	main._menu._ui_scale.item_selected.emit(1)
	var layout: String = JSON.stringify(main.workspace.model.workspaces)
	main._menu._last_button.pressed.emit()
	_assert(not main._menu.visible and main.workspace.process_mode == Node.PROCESS_MODE_INHERIT, "settings scale then Resume restores existing game input")
	_assert(main._session_generation == generation and SpacetimeDB.Continuum == client and main._subscription == subscription, "Resume preserves generation, client identity and subscription")
	_assert(main.starts == 1 and client.connects == 1 and client.disconnects == 0 and client.subscriptions == 1 and client.discards == 0 and main._client_bindings.size() == bindings, "Resume does not reconnect, duplicate subscriptions or rebind signals")
	_assert(client.token_save_path == "user://main_menu_fixture.token" and main._return_key == return_key and ready_events[0] == 0, "Resume preserves token/return context and does not trigger session-ready digest work")
	_assert(main._return_snapshot == snapshot and main._return_digest == digest and JSON.stringify(main.workspace.model.workspaces) == layout, "Resume preserves digest and workspace layout payloads")
	main._show_server_management()
	main._hide_server_management()
	_assert(main._menu._last_button.text == "Resume colony", "server browser Back retains ready Resume")
	main._settings.server_host = "http://different.test"
	main._menu._process(0)
	_assert(main._menu._last_button.text == "Join last server" and not main._can_resume_colony(), "different remembered endpoint cannot resume old game")
	main._settings.server_host = main._host
	client.base_url = "http://stale.test"
	_assert(not main._can_resume_colony(), "client transport endpoint mismatch fails closed")
	client.base_url = main._host
	subscription.end.emit()
	_assert(not main._can_resume_colony(), "ended subscription cannot resume")
	subscription.applied.emit()
	_assert(not main._state_ready and not main._can_resume_colony(), "late applied cannot revive terminal ended subscription")
	main._session_generation += 1
	_assert(not main._can_resume_colony(), "stale ready generation cannot resume")
	main._session_generation = generation
	var replacement = fixture.ClientFixture.new()
	SpacetimeDB.Continuum = replacement
	_assert(not main._can_resume_colony(), "replaced client cannot resume")
	SpacetimeDB.Continuum = client
	replacement.free()
	main._menu.show_menu()
	client.live = false
	_assert(main._menu.visible and main.starts == 1 and main._menu._last_button.text == "Join last server", "terminal subscription offers cold join rather than stale Resume")
	client.disconnected.emit()
	_assert(not main._can_resume_colony() and not main._menu._last_button.disabled, "disconnect while settings open immediately offers cold retry")
	main._menu._last_button.pressed.emit()
	for _frame in 3: await get_tree().process_frame
	_assert(main.starts == 2 and main._session_generation > generation and SpacetimeDB.Continuum != client, "disconnected retry uses real controller replacement epoch")
	var retry_generation: int = main._session_generation
	main._on_server_management_join_requested({"endpoint": "http://different.test", "database": "other-colony"})
	for _frame in 3: await get_tree().process_frame
	_assert(main.starts == 3 and main._session_generation > retry_generation and main._host == "http://different.test" and main._database == "other-colony", "explicit different-target Join configures a new session, never Resume")
	main._session_requested = false
	main._state_ready = false
	main.queue_free()
	await get_tree().process_frame
	var final_client := SpacetimeDB.Continuum
	SpacetimeDB.Continuum = previous
	final_client.queue_free()
	await get_tree().process_frame
	client = fixture.ClientFixture.new()
	SpacetimeDB.add_child(client)
	SpacetimeDB.Continuum = client
	main = preload("res://scenes/main.tscn").instantiate()
	main.set_script(fixture)
	add_child(main)
	main.set_process(false)
	main.configure_connection("http://menu-fixture.test", "colony")
	main._subscription.applied.emit()
	main._menu.show_menu()
	generation = main._session_generation
	_assert(main._can_resume_colony(), "explicit-target test begins with a live resumable colony")
	main._on_server_management_join_requested({"endpoint": "http://different.test", "database": "other-colony"})
	_assert(main._session_generation > generation and not main._can_resume_colony(), "explicit different-target Join invalidates live Resume synchronously")
	for _frame in 3: await get_tree().process_frame
	_assert(main.starts == 2 and SpacetimeDB.Continuum != client, "explicit different-target Join replaces the live client and starts the selected target")
	main._session_requested = false
	main._state_ready = false
	main.queue_free()
	await get_tree().process_frame
	final_client = SpacetimeDB.Continuum
	SpacetimeDB.Continuum = previous
	final_client.queue_free()
	get_window().content_scale_factor = 1.0

func _test_sdk_menu_route() -> void:
	var server := TCPServer.new()
	_assert(server.listen(0, "127.0.0.1") == OK, "private SDK transport listens on an ephemeral port")
	var peer := WebSocketPeer.new()
	peer.supported_protocols = [SpacetimeDBConnection.BSATN_PROTOCOL]
	var previous := SpacetimeDB.Continuum
	var client := ContinuumModuleClient.new()
	client._token = "private-menu-fixture-token"
	SpacetimeDB.add_child(client)
	SpacetimeDB.Continuum = client
	var main = preload("res://scenes/main.tscn").instantiate()
	main.set_script(preload("res://tools/main_menu_controller_fixture.gd"))
	main.use_sdk_setup = true
	add_child(main)
	main.set_process(false)
	var host := "http://127.0.0.1:%d/" % server.get_local_port()
	main.configure_connection(host, "Menu-Colony", ContinuumClientProfile.NORMAL, true)
	var accepted := false
	for _frame in 240:
		if not accepted and server.is_connection_available():
			_assert(peer.accept_stream(server.take_connection()) == OK, "private WebSocket handshake accepts SDK")
			accepted = true
		if accepted:
			peer.poll()
		await get_tree().process_frame
		if client.is_connected_db():
			break
	_assert(client.is_connected_db(), "actual SDK transport becomes live")
	_assert(client.base_url == host.trim_suffix("/") and client.database_name == "menu-colony", "SDK strips one trailing slash and lowercases database, retaining HTTP client base_url")
	_assert(client._connection._target_url.begins_with("ws://127.0.0.1:%d/v1/database/menu-colony/subscribe?" % server.get_local_port()), "SDK converts only the transport URL to WebSocket")
	if not client.is_connected_db():
		main.queue_free()
		await get_tree().process_frame
		SpacetimeDB.Continuum = previous
		client.queue_free()
		server.stop()
		return
	var identity := IdentityTokenMessage.new()
	identity.identity = PackedByteArray([1, 2, 3])
	identity.token = "private-menu-fixture-token"
	client._handle_parsed_message(identity)
	_assert(main._subscription != null and main._subscription.error == OK, "actual SDK creates and sends main subscription")
	main._session_menu.get_popup().id_pressed.emit(2)
	_assert(not main._can_resume_colony() and main._menu._last_button.text == "Join last server", "actual SDK half-ready transport is never resumable")
	var applied := SubscribeAppliedMessage.new()
	applied.query_id.id = main._subscription.query_id
	var sdk_database := client.db
	var world := preload("res://tools/terrain_fixture.gd").database()
	client.db = sdk_database
	world._tables["colony"][0] = ContinuumColony.new()
	for table_name in ["world_geometry", "terrain_material", "colony"]:
		var table := TableUpdateData.new()
		table.table_name = table_name
		for row: Resource in world._tables[table_name].values():
			table.inserts.append(row)
		applied.tables.append(table)
	client._handle_parsed_message(applied)
	var dense := SubscribeAppliedMessage.new()
	dense.query_id.id = main._large_world._legacy_handle.query_id
	var chunks := TableUpdateData.new()
	chunks.table_name = "terrain_chunk"
	for row: Resource in world._tables["terrain_chunk"].values():
		chunks.inserts.append(row)
	dense.tables.append(chunks)
	client._handle_parsed_message(dense)
	world.free()
	main._set_permissions("Viewer", false, false)
	_assert(main._state_ready and main._subscription.active and main._role_name == "Viewer", "applied real SDK subscription is ready for read-only Viewer")
	client.base_url = "ws://127.0.0.1:%d" % server.get_local_port()
	_assert(not main._can_resume_colony(), "different client base_url scheme cannot masquerade as the configured HTTP endpoint")
	client.base_url = host.trim_suffix("/")
	main._settings.server_host = "http://localhost:%d/" % server.get_local_port()
	_assert(not main._can_resume_colony(), "DNS/IP host equivalence is deliberately not accepted for Resume")
	main._settings.server_host = host
	client.database_name = "other-colony"
	_assert(not main._can_resume_colony(), "actual SDK database mismatch fails closed")
	client.database_name = "menu-colony"
	var generation: int = main._session_generation
	var subscription: SpacetimeDBSubscription = main._subscription
	var token: StringName = client.get_token()
	var token_path: String = client.token_save_path
	var next_query: int = client._next_query_id
	var next_request: int = client._next_request_id
	var bindings: int = main._client_bindings.size()
	var digest: Dictionary = main._return_digest.duplicate(true)
	var snapshot: Dictionary = main._return_snapshot.duplicate(true)
	main._session_menu.get_popup().id_pressed.emit(2)
	_assert(main._menu.visible and main._menu._last_button.text == "Resume colony" and main._can_resume_colony(), "actual in-game menu signal preserves Viewer session and offers Resume")
	_assert(main._menu._disconnect_button.visible, "connected menu exposes explicit Disconnect rather than disconnecting on navigation")
	main._menu._toggle_settings()
	main._menu._ui_scale.item_selected.emit(2)
	main._menu._last_button.pressed.emit()
	_assert(not main._menu.visible and main.workspace.process_mode == Node.PROCESS_MODE_INHERIT, "actual menu Settings-scale-Resume route restores game input")
	_assert(SpacetimeDB.Continuum == client and main._session_generation == generation and main._subscription == subscription and client.is_connected_db(), "real SDK Resume retains ready generation/client/transport/subscription")
	_assert(client._next_query_id == next_query and client._next_request_id == next_request and main.starts == 1 and main._client_bindings.size() == bindings, "real SDK Resume sends no subscription/reducer/reconnect or duplicate bindings")
	_assert(client.get_token() == token and client.token_save_path == token_path and main._return_digest == digest and main._return_snapshot == snapshot, "real SDK Resume preserves token and digest payloads")
	main._session_menu.get_popup().id_pressed.emit(2)
	main._show_server_management()
	main._hide_server_management()
	_assert(main._menu._last_button.text == "Resume colony", "actual route browser Back still resumes Viewer")
	main._menu._disconnect_button.pressed.emit()
	_assert(not main._session_requested and main._session_generation > generation and main._subscription == null and main._menu._last_button.text == "Join last server", "explicit Disconnect ends session and restores cold join")
	_assert(not main._menu._disconnect_button.visible and not main._menu._status.text.contains("Connected to"), "disconnected menu hides Disconnect and clears connected status")
	main.queue_free()
	await get_tree().process_frame
	SpacetimeDB.Continuum = previous
	client.queue_free()
	await get_tree().process_frame
	peer.close()
	server.stop()
	get_window().content_scale_factor = 1.0

func _button(menu: ContinuumMainMenu, text: String) -> Button:
	for button: Button in menu.find_children("*", "Button", true, false):
		if button.text == text:
			return button
	return null

func _assert(condition: bool, message: String) -> void:
	if not condition:
		failed = true
		printerr("FAIL: " + message)
