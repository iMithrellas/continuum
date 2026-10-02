## Backend-free role/profile and local utility contract.
extends Node

var failed := false

func check(condition: bool, message: String) -> void:
	if not condition:
		failed = true
		push_error("ROLE_PANELS_FAIL: " + message)

func _ready() -> void:
	var host := "http://127.0.0.1:3001"
	var db := "continuum"
	var key := (host + "/" + db).md5_text()
	check(ContinuumClientProfile.token_path("normal", host, db) == "user://continuum_identity_%s.token" % key, "normal token path unchanged")
	check(ContinuumClientProfile.token_path("admin", host, db) == "user://continuum_admin_identity_%s.token" % key, "admin token path unchanged")
	var developer := ContinuumClientProfile.token_path("developer", host, db)
	check(developer == "user://continuum_developer_identity_%s.token" % key, "developer identity is separate")
	check(developer != ContinuumClientProfile.token_path("developer", host + "2", db) and developer != ContinuumClientProfile.token_path("developer", host, db + "2"), "host/database isolate developer identity")
	check(ContinuumClientProfile.validated("invalid") == "normal" and not ContinuumClientProfile.token_path("invalid", host, db).contains("invalid"), "invalid profile safely falls back without a shared sentinel")
	var main = preload("res://tools/ui_fixture_main.tscn").instantiate()
	add_child(main)
	await get_tree().process_frame
	check(main._profile == "developer" and main.workspace.authorized.developer and not main.workspace.authorized.admin, "CLI profile gates utilities before panels finish setup, not admin")
	for profile: String in ["normal", "admin", "developer"]:
		main._profile = profile
		for role: String in ["unknown", "viewer", "operator", "admin"]:
			main._set_permissions(role, role in ["operator", "admin"], role == "admin")
			check(main.workspace.authorized.admin == (role == "admin"), "admin access follows verified role independently of profile")
			check(main.workspace.authorized.developer == (profile == "developer"), "developer access follows local mode")
			check(main.workspace.authorized.operations == (role in ["operator", "admin"]), "developer is not an editing grant")
			main._change_speed(6.0) # Nil DB / unready calls must never reach reducers.
	main._profile = "developer"
	main._set_permissions("viewer", false, false)
	main._host = "https://secret-user:secret-password@example.org:443/path?token=secret-query#secret-fragment"
	main._database = "safe-db"
	main._diagnostics_overlay.set_snapshots({"mean_fps": 60, "token": "secret-snapshot"}, {"rtt_ms": 42, "headers": "secret-header"})
	var summary: String = main._developer_summary_text()
	check(summary.contains("https://example.org:443") and summary.contains("mean_fps: 60") and not summary.contains("secret"), "summary uses sanitized endpoint and numeric snapshot allowlist")
	var generation: int = main._session_generation
	var before_db = SpacetimeDB.Continuum.db
	for action: String in ["refresh", "fit", "camera", "samples"]:
		main._developer_action(action)
	check(main._session_generation == generation and SpacetimeDB.Continuum.db == before_db and main._intent_request == null, "local utilities do not reconnect, replace replicated state or call reducers")
	check(main._dirty and main._map_dirty and main._full_ui_refresh, "local refresh invalidates derived view caches")
	main._developer_toggle_diagnostics(true)
	main._developer_toggle_graph(true)
	check(main._settings.diagnostics_enabled and main._settings.diagnostics_graph_enabled, "developer diagnostic toggles work locally")
	main._profile = "normal"
	main._developer_toggle_diagnostics(false)
	main._developer_toggle_graph(false)
	main._dirty = false
	main._developer_action("refresh")
	check(main._settings.diagnostics_enabled and main._settings.diagnostics_graph_enabled and not main._dirty and main._developer_summary_text().is_empty(), "programmatic developer calls are guarded outside developer mode")
	main._profile = "developer"
	main._on_disconnected()
	check(not main._is_admin and not main.workspace.authorized.admin and main.workspace.authorized.developer, "disconnect revokes admin but leaves safe offline local tools")
	main.queue_free()
	await get_tree().process_frame
	if not failed:
		print("ROLE_PANELS_PASS")
	get_tree().quit(1 if failed else 0)
