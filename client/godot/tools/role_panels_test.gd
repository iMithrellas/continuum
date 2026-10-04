## Backend-free role/profile and local utility contract.
extends Node

var failed := false
var assertions := 0


func check(condition: bool, message: String) -> void:
	assertions += 1
	if not condition:
		failed = true
		push_error("ROLE_PANELS_FAIL: " + message)


func _ready() -> void:
	var host := "http://127.0.0.1:3001"
	var db := "continuum"
	var key := (host + "/" + db).md5_text()
	check(
		(
			ContinuumClientProfile.token_path("normal", host, db)
			== "user://continuum_identity_%s.token" % key
		),
		"normal token path unchanged"
	)
	check(
		(
			ContinuumClientProfile.token_path("admin", host, db)
			== "user://continuum_admin_identity_%s.token" % key
		),
		"admin token path unchanged"
	)
	var developer := ContinuumClientProfile.token_path("developer", host, db)
	check(
		developer == "user://continuum_developer_identity_%s.token" % key,
		"developer identity is separate"
	)
	check(
		(
			developer != ContinuumClientProfile.token_path("developer", host + "2", db)
			and developer != ContinuumClientProfile.token_path("developer", host, db + "2")
		),
		"host/database isolate developer identity"
	)
	check(
		(
			ContinuumClientProfile.validated("invalid") == "normal"
			and not ContinuumClientProfile.token_path("invalid", host, db).contains("invalid")
		),
		"invalid profile safely falls back without a shared sentinel"
	)
	var main = preload("res://tools/ui_fixture_main.tscn").instantiate()
	add_child(main)
	await get_tree().process_frame
	check(
		(
			main._profile == "developer"
			and main.workspace.authorized.developer
			and not main.workspace.authorized.admin
		),
		"CLI profile gates utilities before panels finish setup, not admin"
	)
	for profile: String in ["normal", "admin", "developer"]:
		main._profile = profile
		main._authenticated_identity = "0123456789abcdef0123456789abcdef"
		for role: String in ["unknown", "viewer", "operator", "admin"]:
			main._set_permissions(role, role in ["operator", "admin"], role == "admin")
			check(
				(
					main._identity_label.text.contains("Identity: 01234567")
					and not main._identity_label.text.contains(main._authenticated_identity)
					and main._identity_label.tooltip_text.contains(
						"Verified server role: " + role.capitalize()
					)
					and main._identity_label.tooltip_text.contains(main._authenticated_identity)
					and (
						main._identity_label.get_parent()
						== main.workspace.windows.session.micro_content
					)
				),
				"independent Session micro shows truthful role and identity prefix with full tooltip"
			)
			check(
				main.workspace.authorized.admin == (role == "admin"),
				"admin access follows verified role independently of profile"
			)
			check(
				main.workspace.authorized.developer == (profile == "developer"),
				"developer access follows local mode"
			)
			check(
				main.workspace.authorized.operations == (role in ["operator", "admin"]),
				"developer is not an editing grant"
			)
			if role == "viewer":
				check(
					(
						(
							main._identity_label.text.begins_with("Read-only")
							or main._identity_label.text.begins_with("Viewer")
						)
						and main._identity_label.tooltip_text.contains("Operator access")
						and not main._can_operate
						and main._construction_panel.activate.disabled
						and main._zones_panel.activate.disabled
					),
					"viewer badge explains the read-only restriction and correct management role"
				)
			elif role == "operator":
				check(
					(
						main._identity_label.text.begins_with("Operator")
						and main._identity_label.tooltip_text.contains("Speed, pause")
					),
					"ordinary player badge distinguishes colony management from administration"
				)
			main._change_speed(6.0)
	main._profile = "developer"
	main._set_permissions("viewer", false, false)
	main._host = "https://secret-user:secret-password@example.org:443/path?token=secret-query#secret-fragment"
	main._database = "safe-db"
	main._diagnostics_overlay.set_snapshots(
		{"mean_fps": 60, "token": "secret-snapshot"}, {"rtt_ms": 42, "headers": "secret-header"}
	)
	var summary: String = main._developer_summary_text()
	check(
		(
			summary.contains("https://example.org:443")
			and summary.contains("mean_fps: 60")
			and not summary.contains("secret")
		),
		"summary uses sanitized endpoint and numeric snapshot allowlist"
	)
	var generation: int = main._session_generation
	var before_db = SpacetimeDB.Continuum.db
	for action: String in ["refresh", "fit", "camera", "samples"]:
		main._developer_action(action)
	check(
		(
			main._session_generation == generation
			and SpacetimeDB.Continuum.db == before_db
			and main._intent_request == null
		),
		"local utilities do not reconnect, replace replicated state or call reducers"
	)
	check(
		main._dirty and main._map_dirty and main._full_ui_refresh,
		"local refresh invalidates derived view caches"
	)
	main._developer_toggle_diagnostics(true)
	main._developer_toggle_graph(true)
	check(
		main._settings.diagnostics_enabled and main._settings.diagnostics_graph_enabled,
		"developer diagnostic toggles work locally"
	)
	main._profile = "normal"
	main._developer_toggle_diagnostics(false)
	main._developer_toggle_graph(false)
	main._dirty = false
	main._developer_action("refresh")
	check(
		(
			main._settings.diagnostics_enabled
			and main._settings.diagnostics_graph_enabled
			and not main._dirty
			and main._developer_summary_text().is_empty()
		),
		"programmatic developer calls are guarded outside developer mode"
	)
	main._profile = "developer"
	main._on_disconnected()
	check(
		(
			not main._is_admin
			and not main.workspace.authorized.admin
			and main.workspace.authorized.developer
		),
		"disconnect revokes admin but leaves safe offline local tools"
	)
	await _test_workspace_teardown(main)
	var offline_client := ContinuumModuleClient.new()
	main._access = ContinuumAccess.new(offline_client)
	main._access.changed.connect(main._set_permissions)
	main._access._set_role("Admin", true, true)
	var deck: WorkspaceDeck = main.workspace
	main.remove_child(deck)
	check(
		not deck.is_inside_tree() and deck.get_viewport() == null,
		"workspace exits before main role teardown"
	)
	main.free()
	check(
		not deck.authorized.operations and not deck.authorized.admin,
		"real main exit revokes roles on detached workspace"
	)
	deck.free()
	offline_client.free()
	await get_tree().process_frame
	if not failed:
		print("ROLE_PANELS_PASS ", assertions, " assertions")
	get_tree().quit(1 if failed else 0)


func _test_workspace_teardown(main: Node) -> void:
	get_tree().root.size = Vector2i(1440, 900)
	await get_tree().process_frame
	await get_tree().process_frame
	var deck: WorkspaceDeck = main.workspace
	main._set_permissions("operator", true, false)
	deck.state("operations").open = true
	deck.state("operations").minimized = false
	deck.state("operations").pinned = false
	deck._apply_layout()
	deck.focus_panel("operations")
	deck._apply_layout()
	var window: WorkspaceWindow = deck.windows.operations
	var body_focus := Button.new()
	window.content.add_child(body_focus)
	body_focus.grab_focus()
	check(
		deck.get_viewport().gui_get_focus_owner() == body_focus,
		"authorized panel body receives focus"
	)
	window._start_gesture("move", window.global_position)
	main.map._dragging = true
	deck.set_panel_authorized("operations", false)
	check(
		window._gesture.is_empty() and not main.map._dragging and not window.visible,
		"live revocation cancels panel and map capture"
	)
	check(
		deck.get_viewport().gui_get_focus_owner() != body_focus,
		"live revocation releases restricted body focus"
	)
	deck.set_panel_authorized("operations", true)
	body_focus.grab_focus()
	window._start_gesture("move", window.global_position)
	main.remove_child(deck)
	main.map._dragging = true
	deck.set_panel_authorized("operations", false)
	check(
		(
			not deck.authorized.operations
			and not window.visible
			and window._gesture.is_empty()
			and not main.map._dragging
		),
		"detached revocation retains authorization and cancels capture"
	)
	deck.set_panel_authorized("operations", true)
	deck.set_panel_authorized("operations", false)
	main.add_child(deck)
	await get_tree().process_frame
	check(
		deck.get_viewport().gui_get_focus_owner() != body_focus and not window.visible,
		"reentry does not restore stale restricted focus"
	)
	deck.set_panel_authorized("operations", true)
	deck.focus_panel("operations")
	deck._apply_layout()
	check(window.visible, "role regrant after reentry restores permitted panel")
	body_focus.grab_focus()
	deck.set_panel_authorized("operations", false)
	check(
		not window.visible and deck.get_viewport().gui_get_focus_owner() != body_focus,
		"rerole after reentry still revokes focus"
	)
