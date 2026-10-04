extends SceneTree

const History = preload("res://scripts/connection_history.gd")
const Probes = preload("res://scripts/server_probes.gd")
const Management = preload("res://scripts/server_management.gd")
const Profile = preload("res://scripts/client_profile.gd")
var failures := 0


func _init() -> void:
	_test_keys()
	_test_validation()
	_test_persistence_boundaries()
	_test_management_contract()
	await _test_probes()
	await _test_http_adapter()
	await _test_rendered_browser()
	if failures == 0:
		print("SERVER_BROWSER_PASS")
	else:
		print("SERVER_BROWSER_FAIL (%d failures)" % failures)
	quit(0 if failures == 0 else 1)


func _test_validation() -> void:
	for endpoint: Array in [
		["http://127.0.0.1:3000", "continuum"],
		["https://[2001:db8::1]:443", "continuum"],
		["http://localhost", "continuum-sidebar-access-it-648299"],
		["http://[::1]:65535", "a"],
		["https://" + "a".repeat(63) + ".example", "a".repeat(128)],
		[
			"http://" + ".".join(["a".repeat(63), "b".repeat(63), "c".repeat(63), "d".repeat(61)]),
			"continuum"
		]
	]:
		_assert(
			Management.validate_endpoint(endpoint[0], endpoint[1]).is_empty(),
			"valid direct endpoint accepted: %s" % endpoint[0]
		)
		_assert(
			not History.canonical_key(endpoint[0], endpoint[1]).is_empty(),
			"accepted direct endpoint can be saved: %s" % endpoint[0]
		)
	for endpoint: Array in [
		["127.0.0.1:3000", "continuum"],
		["http://", "continuum"],
		["http://?", "continuum"],
		["http://:3000", "continuum"],
		["http://localhost:0", "continuum"],
		["http://localhost", "bad name"],
		["http://localhost", "continuum_worker"],
		["http://[::1]3000", "continuum"],
		["http://[::::]", "continuum"],
		["http://[1:2:3]", "continuum"],
		["http://[::1", "continuum"],
		["http://[127.0.0.1]", "continuum"],
		["http://2001:db8::1", "continuum"],
		["http://" + "a".repeat(64) + ".example", "continuum"],
		[
			"http://" + ".".join(["a".repeat(63), "b".repeat(63), "c".repeat(63), "d".repeat(62)]),
			"continuum"
		],
		["http://example..com", "continuum"],
		["http://-example.com", "continuum"],
		["http://example.com:65536", "continuum"],
		["http://example.com:080", "continuum"],
		["http://example.com:+80", "continuum"],
		["http://example.com:" + "9".repeat(30), "continuum"],
		["http://user@example.com", "continuum"],
		["http://example.com/path", "continuum"],
		["http://example.com?query", "continuum"],
		["http://example.com#fragment", "continuum"],
		["http://localhost", "a".repeat(129)],
		["http://localhost", "-colony"],
		["http://localhost", "colony-"],
		["http://localhost", "colony--one"]
	]:
		_assert(
			not Management.validate_endpoint(endpoint[0], endpoint[1]).is_empty(),
			"invalid direct endpoint rejected: %s / %s" % endpoint
		)
		_assert(
			History.canonical_key(endpoint[0], endpoint[1]).is_empty(),
			"invalid endpoint cannot be saved: %s / %s" % endpoint
		)
	for endpoint: Array in [
		["HTTP://Example.com", "continuum"],
		["http://example.com", "Continuum"],
		["ws://example.com", "continuum"]
	]:
		_assert(
			not Management.validate_endpoint(endpoint[0], endpoint[1]).is_empty(),
			"direct form keeps its lowercase HTTP(S)/database policy"
		)
		_assert(
			not History.canonical_key(endpoint[0], endpoint[1]).is_empty(),
			"history still accepts supported SDK/CLI spellings"
		)


func _test_keys() -> void:
	var key := History.canonical_key("HTTPS://Example.COM:443", "Continuum", "main-world")
	_assert(
		key == "https://example.com/continuum/main-world",
		"canonical key normalizes scheme host database"
	)
	var ipv6_key := History.canonical_key("http://[2001:DB8::1]:80", "Continuum")
	_assert(
		ipv6_key == "http://[2001:DB8::1]/continuum/default-world",
		"IPv6 remains bracketed and unrewritten"
	)
	_assert(
		(
			History.canonical_key("http://example.com:8080", "Continuum")
			== "http://example.com:8080/continuum/default-world"
		),
		"non-default port retained"
	)
	_assert(
		History.canonical_key("http://example.com:08080", "Continuum") == "",
		"zero-padded port rejected"
	)
	_assert(
		History.canonical_key("http://example.com:+8080", "Continuum") == "", "signed port rejected"
	)
	_assert(
		(
			History.canonical_key("http://[::1]", "Continuum")
			== "http://[::1]/continuum/default-world"
		),
		"compressed IPv6 accepted"
	)
	_assert(
		(
			History.canonical_key("http://[fe80::]", "Continuum")
			== "http://[fe80::]/continuum/default-world"
		),
		"empty-tail compressed IPv6 accepted"
	)
	_assert(
		History.canonical_key("http://2001:db8::1", "Continuum") == "", "unbracketed IPv6 rejected"
	)
	_assert(
		History.canonical_key("http://example.com", "-continuum") == "",
		"database leading dash rejected"
	)
	_assert(
		History.canonical_key("http://example.com", "continuum-") == "",
		"database trailing dash rejected"
	)
	_assert(
		History.canonical_key("http://example.com", "continuum--db") == "",
		"database repeated dash rejected"
	)
	_assert(
		(
			History.canonical_key("http://example.com", "Continuum-DB")
			== "http://example.com/continuum-db/default-world"
		),
		"database case canonicalized"
	)
	_assert(
		(
			(
				History.canonical_key("WS://Example.com:80", "Continuum")
				== "ws://example.com/continuum/default-world"
			)
			and (
				History.canonical_key("wss://Example.com:443", "Continuum")
				== "wss://example.com/continuum/default-world"
			)
		),
		"WebSocket history keys retain known default-port rules"
	)
	_assert(
		(
			Profile.token_path(Profile.NORMAL, "http://Example.com:80", "Continuum")
			!= Profile.token_path(Profile.NORMAL, "http://example.com", "continuum")
		),
		"history normalization does not merge raw credential keys"
	)


func _test_persistence_boundaries() -> void:
	var base := "/tmp/continuum-browser-test-%d" % Time.get_ticks_usec()
	var paths: Array[String] = []
	paths.append_array([base + ".history", base + ".favorites"])
	var history = History.new()
	history.load_from(base + ".history", base + ".favorites")
	var key := History.canonical_key("http://Host", "Continuum", "default-world")
	_assert(
		(
			history.record_successful_subscription(
				"http://Host", "Continuum", "default-world", "Home", 5
			)
			== OK
		),
		"successful subscription recorded"
	)
	_assert(
		(
			history.record_successful_subscription(
				"HTTP://HOST:80", "continuum", "default-world", "Home", 6
			)
			== OK
		),
		"case variants deduplicate"
	)
	_assert(
		(
			history.entries().size() == 1
			and history.entries()[0].database == "Continuum"
			and history.entries()[0].endpoint == "http://Host"
		),
		"deduplication preserves original display spelling"
	)
	_assert(history.set_favorite(key, true) == OK, "favorite can be persisted")
	_assert(history.remove_history(key) == OK, "history can be removed")
	_assert(history.entries().is_empty(), "history removal clears history only")
	var favorites = FileAccess.get_file_as_string(base + ".favorites")
	_assert(favorites.contains(key), "favorite persists separately from history")
	_assert(history.remove_favorite(key) == OK, "favorite remains independently removable")
	var loaded = History.new()
	loaded.load_from(base + ".history", base + ".favorites")
	_assert(loaded.entries().is_empty(), "empty state persists")
	var named_base := "/tmp/continuum-browser-named-%d" % Time.get_ticks_usec()
	paths.append_array(
		[
			named_base + ".history",
			named_base + ".favorites",
			named_base + ".legacy",
			named_base + ".legacy-history",
			named_base + ".legacy-favorites"
		]
	)
	var named := History.new()
	named.load_from(named_base + ".history", named_base + ".favorites")
	var named_key := History.canonical_key("http://token-server.example", "named-db")
	_assert(
		(
			named.record_successful_subscription(
				"http://token-server.example", "named-db", "default-world", "Named home", 7
			)
			== OK
		),
		"named entry records"
	)
	var named_loaded := History.new()
	named_loaded.load_from(named_base + ".history", named_base + ".favorites")
	_assert(
		named_loaded.entries()[0].get("display_name", "") == "Named home",
		"named entry survives reload"
	)
	var legacy := History.new()
	legacy.legacy_import_marker_path = named_base + ".legacy"
	legacy.load_from(named_base + ".legacy-history", named_base + ".legacy-favorites")
	_assert(
		legacy.import_legacy_entry_once("http://legacy.example", "continuum") == OK,
		"legacy last server adopts explicit default world"
	)
	_assert(
		(
			legacy.import_legacy_entry_once("http://other.example", "continuum") == OK
			and legacy.entries().size() == 1
		),
		"legacy adoption is one-time"
	)
	_assert(
		named_loaded.set_favorite(named_key, true) == OK,
		"token-containing canonical key can be favorited"
	)
	var favorite_loaded := History.new()
	favorite_loaded.load_from(named_base + ".history", named_base + ".favorites")
	_assert(
		favorite_loaded.entries()[0].favorite,
		"token-containing canonical key favorite survives reload"
	)
	var corrupt_path := "/tmp/continuum-browser-corrupt-%d.json" % Time.get_ticks_usec()
	paths.append(corrupt_path)
	var corrupt_file := FileAccess.open(corrupt_path, FileAccess.WRITE)
	corrupt_file.store_string(
		JSON.stringify(
			{
				"bad":
				{
					"key": "bad",
					"endpoint": 4,
					"database": "db",
					"world": "world",
					"last_seen": "new",
					"last_sample": 0
				}
			}
		)
	)
	corrupt_file.close()
	var corrupt := History.new()
	corrupt.load_from(corrupt_path, corrupt_path + ".favorites")
	_assert(corrupt.entries().is_empty(), "corrupt typed entry is discarded")
	var denied_parent := "/tmp/continuum-browser-denied-%d" % Time.get_ticks_usec()
	paths.append(denied_parent)
	var denied_file := FileAccess.open(denied_parent, FileAccess.WRITE)
	denied_file.store_string("not a directory")
	denied_file.close()
	var denied := History.new()
	denied.load_from(denied_parent + "/history.json", denied_parent + "/favorites.json")
	var denied_before := denied.entries().duplicate(true)
	var denied_error := denied.record_successful_subscription(
		"http://example.com", "db", "default-world", "Denied", 8
	)
	_assert(
		denied_error != OK and denied.entries() == denied_before,
		"failed save leaves state unchanged"
	)
	_cleanup(paths)


func _test_probes() -> void:
	var probes = Probes.new()
	probes.set_visible(true)
	var calls := [0]
	var callbacks: Array[Callable] = []
	probes.transport = func(_entry: Dictionary, complete: Callable) -> void:
		calls[0] += 1
		callbacks.append(complete)
	var entries: Array[Dictionary] = []
	for index in 6:
		entries.append({"key": "k%d" % index})
	probes.refresh(entries, 0.0)
	_assert(calls[0] == Probes.MAX_CONCURRENT, "probe concurrency is bounded")
	probes.process(3.1)
	_assert(probes.state("k0").status == "unreachable", "timeout is unreachable")
	_assert(probes.state("k0").stale == false, "timeout sample is not immediately stale")
	var old_callback: Callable = callbacks[0]
	probes.set_visible(false)
	probes.set_visible(true)
	probes.refresh([{"key": "k0"}], 20.0)
	old_callback.call({"reachable": true, "rtt_ms": 4})
	_assert(
		probes.state("k0").status == "checking", "late callback cannot complete a reopened attempt"
	)
	probes.set_visible(false)
	var hidden_calls: int = calls[0]
	probes.refresh(entries, 100.0)
	_assert(calls[0] == hidden_calls, "hidden browser does not poll")
	probes.free()


func _test_management_contract() -> void:
	var manager = Management.new()
	var base := "/tmp/continuum-manager-%d" % Time.get_ticks_usec()
	var store = History.new()
	store.load_from(base + ".history", base + ".favorites")
	store.record_successful_subscription(
		"http://example.com", "Continuum", "default-world", "Home", 1
	)
	manager.set_history_store(store)
	var stopped := [0]
	manager.local_stop_requested.connect(func() -> void: stopped[0] += 1)
	manager.set_local_management_state({"can_stop": false})
	manager.request_local_stop()
	_assert(stopped[0] == 0, "remote or unowned entries cannot stop a managed process")
	manager.set_local_management_state({"can_stop": true})
	manager.request_local_stop()
	_assert(stopped[0] == 1, "owned local stop capability emits")
	manager.request_join(History.canonical_key("http://example.com", "Continuum"))
	var selected: String = manager.selected_key
	manager.set_search("not found")
	_assert(manager.selected_key == selected, "selection identifier survives filtering")
	manager.free()
	_cleanup([base + ".history", base + ".favorites"])


func _test_http_adapter() -> void:
	var server := TCPServer.new()
	_assert(server.listen(0, "127.0.0.1") == OK, "sandbox HTTP fixture listens")
	var probes = Probes.new()
	get_root().add_child(probes)
	probes.set_visible(true)
	var result := [{}]
	var peers: Array[StreamPeerTCP] = []
	probes.probe_finished.connect(func(_key: String, value: Dictionary) -> void: result[0] = value)
	var port := server.get_local_port()
	await process_frame
	probes.refresh([{"key": "http", "endpoint": "http://127.0.0.1:%d" % port}], 0.0)
	for _frame in 120:
		for peer in peers:
			peer.poll()
		if server.is_connection_available():
			var peer := server.take_connection()
			peers.append(peer)
			peer.poll()
			peer.put_data(
				"HTTP/1.1 200 OK\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".to_utf8_buffer()
			)
		await process_frame
		if result[0].has("rtt_ms"):
			break
	_assert(result[0].get("status", "") == "online", "owned HTTP health adapter reports online")
	if result[0].get("status", "") != "online":
		print("HTTP RESULT ", result[0], " PORT ", port)
	_assert(float(result[0].get("rtt_ms", -1)) >= 0.0, "HTTP RTT is measured separately")
	_assert(
		result[0].get("joinable", "missing") == null, "health does not claim database joinability"
	)
	probes.queue_free()
	server.stop()
	await process_frame


func _test_rendered_browser() -> void:
	var base := "/tmp/continuum-render-%d" % Time.get_ticks_usec()
	var store = History.new()
	store.load_from(base + ".history", base + ".favorites")
	store.clear_history()
	store.record_successful_subscription(
		"http://example.com", "Continuum", "default-world", "Home", 9
	)
	for index in 30:
		store.record_successful_subscription(
			"http://example.com",
			"colony-%d" % index,
			"default-world",
			"Colony %d" % index,
			10 + index
		)
	var manager = Management.new()
	var probes := Probes.new()
	probes.transport = func(_entry: Dictionary, _complete: Callable) -> void: pass
	manager.set_probe_service(probes)
	manager.set_connection_defaults("http://localhost:3001", "continuum")
	manager.set_history_store(store)
	manager.set_managed_servers(
		[
			{"id": "default", "name": "Original colony", "port": 3001, "state": "online"},
			{
				"id": "server-" + "b".repeat(24),
				"name": "A second independently managed colony",
				"port": 3002,
				"state": "offline"
			}
		],
		"default"
	)
	get_root().add_child(manager)
	manager.set_anchors_and_offsets_preset(Control.PRESET_TOP_LEFT)
	for viewport_size: Vector2 in [Vector2(1440, 860), Vector2(360, 480)]:
		manager.set_size(viewport_size)
		manager.apply_metrics(UiMetrics.new(24 if viewport_size.x == 360 else 13))
		for _frame in 8:
			await process_frame
		_assert(_nodes_named(manager, "Home").size() == 1, "browser renders one stable history row")
		_assert(
			(
				_nodes_named(manager, "http://example.com / Continuum").size() == 1
				and _nodes_named(manager, "World: default-world").size() == 31
				and _nodes_named(manager, "HTTP RTT unavailable").size() == 31
			),
			"rows identify address, database, world and HTTP RTT"
		)
		_assert(
			_all_controls_fit(manager, viewport_size.x),
			"browser controls fit horizontally at %s" % viewport_size
		)
		_assert(
			manager._managed_rows.size() == 2,
			"both managed servers remain visible in compact and wide layouts"
		)
		var background: ColorRect = manager.get_node("ServerBackground")
		_assert(
			background.color.a == 1.0 and background.get_global_rect() == manager.get_global_rect(),
			"opaque backdrop covers the entire viewport"
		)
		_assert(
			manager.get_global_rect().encloses(manager._content.get_global_rect()),
			"browser panel stays inside viewport: %s" % manager._content.get_global_rect()
		)
		_assert(
			manager.get_global_rect().encloses(manager._back_button.get_global_rect()),
			"Return remains on screen with long history"
		)
		var scroll: ScrollContainer = manager.find_child("ServerContentScroll", true, false)
		_assert(
			scroll.clip_contents and scroll.follow_focus and not scroll.get_h_scroll_bar().visible,
			"body clips and scrolls vertically with keyboard focus"
		)
		_assert(
			manager._sections.vertical == (viewport_size.x == 360),
			"server forms stack only in compact view"
		)
		for button: Button in [
			manager._join_button,
			manager._local_start,
			manager._native_autostart,
			manager._history_join_buttons[-1]
		]:
			scroll.ensure_control_visible(button)
			await process_frame
			_assert(
				scroll.get_global_rect().grow(2).encloses(button.get_global_rect()),
				(
					"scroll reaches %s at %s: %s in %s"
					% [
						button.text,
						viewport_size,
						button.get_global_rect(),
						scroll.get_global_rect()
					]
				)
			)
		for label: Label in manager._history_list.find_children("*", "Label", true, false):
			_assert(
				(
					label.size.y >= label.get_theme_font_size("font_size")
					and label.get_theme_font_size("font_size") >= 11
				),
				"history labels retain readable logical typography"
			)
		for message: String in [
			"The server module does not match this client: no such table: production_policy.",
			"A detailed connection failure. ".repeat(30)
		]:
			manager.set_status(message, true)
			for _frame in 8:
				await process_frame
			_assert(
				manager._status_tag.get_line_count() == 1 and manager._status_tag.size.x > 40,
				"Warning tag never wraps one character at a time at %s" % viewport_size
			)
			_assert(
				(
					manager._status_glyph.size.y == 16
					and manager._status_tag.size.y <= manager._status.size.y
					and (
						manager._status_tag.size.y
						<= manager._status_tag.get_combined_minimum_size().y + 1
					)
				),
				(
					"warning glyph and tag stay compact beside wrapped feedback at %s: glyph=%s tag=%s status=%s"
					% [
						viewport_size,
						manager._status_glyph.size,
						manager._status_tag.size,
						manager._status.size
					]
				)
			)
			_assert(
				scroll.scroll_vertical == 0 and _all_controls_fit(manager, viewport_size.x),
				"long warnings reveal their beginning and fit horizontally"
			)
		manager.set_status("")
	manager.set_status("A detailed connection failure. ".repeat(30), true)
	for _frame in 8:
		await process_frame
	_assert(
		(
			manager.get_global_rect().encloses(manager._content.get_global_rect())
			and manager.get_global_rect().encloses(manager._back_button.get_global_rect())
		),
		"long errors scroll instead of pushing Return out of the viewport"
	)
	manager.set_status("")

	var key := History.canonical_key("http://example.com", "Continuum")
	manager.set_search("Home")
	manager.set_search("Home")
	_assert(
		manager._history_list.get_child_count() == 1,
		"same-frame filtering detaches old rows immediately"
	)
	for _frame in 8:
		await process_frame
	var join: Button = manager._history_join_buttons[0]
	join.grab_focus()
	probes.set_visible(true)
	probes.refresh(manager.visible_entries(), 0.0)
	probes.complete(key, {"reachable": true, "health_ok": true, "rtt_ms": 12}, 1.0)
	_assert(
		manager._history_join_buttons[0] == join and join.has_focus(),
		"health results preserve history row identity and keyboard focus"
	)
	_assert(
		manager._probe_labels[key].text.contains("12 ms HTTP"),
		"health result updates only the matching sample"
	)
	probes.set_visible(false)
	var joins: Array[Dictionary] = []
	manager.join_requested.connect(func(target: Dictionary) -> void: joins.append(target))
	for host: String in ["invalid", "http://[::::]", "http://" + "a".repeat(64) + ".example"]:
		manager._join_host.text = host
		manager._join_server()
		_assert(
			joins.is_empty() and manager._status_warning and not manager._busy,
			"invalid direct join shows feedback without dispatch or busy state: " + host
		)
	manager._join_host.text = "  http://localhost:3001  "
	manager._join_database.text = "  continuum  "
	manager._join_server()
	manager._join_server()
	_assert(
		(
			joins == [{"endpoint": "http://localhost:3001", "database": "continuum"}]
			and manager._join_button.disabled
		),
		"direct join dispatches trimmed endpoint once and stays busy"
	)
	_assert(not manager.request_join(key), "pending direct join blocks history joins")
	manager.set_busy(false)
	manager.set_status("Connection failed", true)
	_assert(
		not manager._join_button.disabled and manager._status.text == "Connection failed",
		"failed connection leaves retry and feedback in Servers"
	)
	manager.apply_metrics(UiMetrics.new(19))
	_assert(
		(
			manager._join_host.text == "  http://localhost:3001  "
			and manager._status.text == "Connection failed"
		),
		"font changes preserve typed endpoint and feedback"
	)
	_assert(
		_nodes_named(manager, "BrowserContent").size() == 1,
		"font rebuild detaches old content immediately"
	)
	var managed_actions := [0, 0]
	manager.local_server_selected.connect(func(_id: String) -> void: managed_actions[0] += 1)
	manager.local_delete_requested.connect(func() -> void: managed_actions[1] += 1)
	manager.request_server_selection("unknown")
	manager.set_local_management_state({"can_delete": false})
	manager.request_local_delete()
	_assert(
		managed_actions == [0, 0], "unknown or running servers cannot acquire deletion capabilities"
	)
	manager.set_local_management_state({"can_delete": true})
	manager.request_server_selection("server-" + "b".repeat(24))
	manager.request_local_delete()
	_assert(
		managed_actions == [1, 1],
		"selection and stopped-server deletion dispatch explicit management signals"
	)
	manager.set_local_management_state({"can_stop": true})
	await process_frame
	var stop_buttons := _nodes_named(manager, "Stop local")
	_assert(
		stop_buttons.size() == 1 and not (stop_buttons[0] as Button).disabled,
		"capability update refreshes local controls"
	)
	var local_actions := [0, 0, 0]
	manager.local_start_requested.connect(func() -> void: local_actions[0] += 1)
	manager.local_cancel_requested.connect(func() -> void: local_actions[1] += 1)
	manager.native_autostart_requested.connect(func(_enabled: bool) -> void: local_actions[2] += 1)
	manager.set_local_management_state({"can_start": true})
	manager.request_local_start()
	manager.request_local_start()
	_assert(
		local_actions[0] == 1 and manager._local_cancel.visible and manager._join_button.disabled,
		"local startup blocks repeated starts and offers cancellation in Servers"
	)
	manager._local_cancel.pressed.emit()
	manager.set_native_busy(false)
	manager._native_autostart.button_pressed = true
	_assert(
		local_actions == [1, 1, 1],
		"cancel and autostart controls dispatch server-management signals"
	)
	manager.set_native_autostart(false)
	_assert(
		not manager._native_autostart.button_pressed and local_actions[2] == 1,
		"OS autostart readback does not emit another request"
	)
	manager.request_favorite(key, true)
	await process_frame
	_assert(
		manager.visible_entries()[0].get("favorite", false), "favorite mutation refreshes labels"
	)
	manager.request_join(key)
	manager.set_search("missing")
	await process_frame
	_assert(manager.selected_key == key, "selection identifier survives search filtering")
	manager.set_busy(false)
	manager.set_search("Home")
	manager.request_history_removal(key)
	await process_frame
	_assert(
		(
			manager.visible_entries().is_empty()
			and _nodes_named(manager, "No connections match").size() == 1
		),
		"filtered history removal shows an empty state"
	)
	store.clear_history()
	manager.set_search("")
	_assert(
		_nodes_named(manager, "No saved connections yet").size() == 1,
		"new players see a useful empty history message"
	)
	manager.queue_free()
	await process_frame
	_cleanup([base + ".history", base + ".favorites"])


func _nodes_named(root: Node, target: String) -> Array[Node]:
	var result: Array[Node] = []
	if (
		target.is_empty()
		or root.name == target
		or (root is Button and root.text == target)
		or (root is Label and root.text.contains(target))
	):
		result.append(root)
	for child in root.get_children():
		result.append_array(_nodes_named(child, target))
	return result


func _all_controls_fit(root: Node, width: float) -> bool:
	for node in _nodes_named(root, ""):
		if (
			node is Control
			and node.is_visible_in_tree()
			and (
				node.get_global_rect().position.x < -0.5
				or node.get_global_rect().end.x > width + 0.5
			)
		):
			printerr("Overflow: %s %s" % [node.get_path(), node.get_global_rect()])
			return false
	return true


func _cleanup(paths: Array[String]) -> void:
	for path in paths:
		if FileAccess.file_exists(path):
			DirAccess.remove_absolute(path)


func _assert(condition: bool, message: String) -> void:
	if not condition:
		failures += 1
		printerr("FAIL: %s" % message)
