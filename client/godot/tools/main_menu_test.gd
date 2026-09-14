extends Node

const Menu = preload("res://scripts/main_menu.gd")

var failed := false

class FakeRunner extends RefCounted:
	signal progress(message: String)
	signal ready(host: String, database: String)
	signal failed(message: String)
	var started := 0
	var cancelled := 0
	var running := false

	func is_running() -> bool:
		return running

	func start() -> bool:
		started += 1
		running = true
		return true

	func cancel() -> void:
		cancelled += 1
		running = false

	func dispose() -> void:
		cancel()

func _ready() -> void:
	_assert(Menu.validate_endpoint("http://127.0.0.1:3000", "continuum").is_empty(), "valid endpoint accepted")
	_assert(Menu.validate_endpoint("https://[2001:db8::1]:443", "continuum").is_empty(), "bracketed IPv6 endpoint accepted")
	_assert(not Menu.validate_endpoint("127.0.0.1:3000", "continuum").is_empty(), "host scheme is required")
	_assert(not Menu.validate_endpoint("http://", "continuum").is_empty(), "empty host rejected")
	_assert(not Menu.validate_endpoint("http://?", "continuum").is_empty(), "query-only host rejected")
	_assert(not Menu.validate_endpoint("http://:3000", "continuum").is_empty(), "port-only host rejected")
	_assert(not Menu.validate_endpoint("http://localhost:0", "continuum").is_empty(), "zero port rejected")
	_assert(not Menu.validate_endpoint("http://localhost", "bad name").is_empty(), "invalid database rejected")

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

	var menu: ContinuumMainMenu = preload("res://scenes/main_menu.tscn").instantiate()
	add_child(menu)
	menu.setup(null, ClientSettings.new(), UiMetrics.new())
	_assert(menu._last_button.disabled, "join last is disabled without a successful endpoint")
	_assert(menu._font_size.min_value == ClientSettings.MIN_FONT_SIZE and
			menu._font_size.max_value == ClientSettings.MAX_FONT_SIZE, "settings enforce font bounds")
	menu._toggle_settings()
	_assert(menu._settings_panel.visible, "settings are reachable from the menu")
	menu._toggle_settings()
	menu._join_host.text = "http://localhost:3000"
	menu._join_database.text = "continuum"
	menu._join_server()
	_assert(menu._join_button.disabled, "join disables repeated clicks while pending")
	_assert(menu._status.text.begins_with("Connecting"), "join status is visible")

	var fake := FakeRunner.new()
	menu.runner_factory = func() -> RefCounted: return fake
	menu.set_busy(false)
	menu._start_local_server()
	menu._start_local_server()
	_assert(fake.started == 1, "repeated local clicks do not start another runner")
	menu._cancel_local_server()
	_assert(fake.cancelled == 1, "local setup is cancellable")
	await get_tree().process_frame
	_assert(not menu._join_button.disabled, "menu returns from cancellation after runner cleanup: join")
	_assert(not menu._cancel_local_button.visible, "menu returns from cancellation after runner cleanup: cancel")
	menu.queue_free()

	if failed:
		get_tree().quit(1)
		return
	print("MAIN_MENU_PASS")
	get_tree().quit(0)

func _assert(condition: bool, message: String) -> void:
	if not condition:
		failed = true
		printerr("FAIL: " + message)
