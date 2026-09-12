## Private end-to-end gate for the untouched production main scene.
extends Node

const MainScene = preload("res://scenes/main.tscn")
const TIMEOUT_FRAMES := 600

var main: Control
var failed := false

func _ready() -> void:
	main = MainScene.instantiate()
	add_child(main)
	if _option("--mode", "normal") == "admin":
		await _test_admin()
	else:
		await _test_operator_lifecycle()
	if not failed:
		print("SIDEBAR_ACCESS_PASS")
		get_tree().quit(0)

func _test_operator_lifecycle() -> void:
	await _wait_role("Viewer")
	_assert(not main.sidebar.sections["policies"].wrapper.visible and
			not main.sidebar.sections["administration"].wrapper.visible and
			not main._build_menu.visible, "viewer mutation and admin controls are hidden")
	_write_identity(_option("--identity-file", ""))
	await _wait_file(_option("--operator-granted-file", ""))
	await _wait_role("Operator")
	_assert(main.sidebar.sections["policies"].wrapper.visible and
			not main.sidebar.sections["administration"].wrapper.visible and
		main._haul_button.visible, "operator sees operations and policies, not administration")
	var rationed := main._meal_buttons[ContinuumMealPolicy.Options.rationed] as Button
	rationed.pressed.emit()
	await _wait_until(func() -> bool:
		var config: ContinuumConfig = SpacetimeDB.Continuum.db.config.id.find(0)
		return config != null and config.meal_policy.value == ContinuumMealPolicy.Options.rationed)
	_assert(not failed and main._meal_request == null, "operator meal control changed authoritative config")
	main._set_mode(&"build")
	main.sidebar.search.text = "build"
	_write_marker(_option("--revoke-request-file", ""))
	await _wait_file(_option("--operator-revoked-file", ""))
	await _wait_role("Viewer")
	_assert(not main.sidebar.sections["policies"].wrapper.visible and
			not main._build_menu.visible and main.map.interaction_mode == &"select",
		"revocation while searching hides controls and keeps map out of Build mode")
	SpacetimeDB.Continuum.disconnect_db()
	await _wait_role("Unknown")
	_assert(not main.sidebar.sections["policies"].wrapper.visible and
			not main.sidebar.sections["administration"].wrapper.visible,
		"disconnect fails closed in the main scene")
	SpacetimeDB.Continuum.reconnect_db()
	await _wait_role("Viewer")
	_assert(SpacetimeDB.Continuum.current_subscriptions.size() == 2,
		"reconnect keeps main and role subscription handles stable")

func _test_admin() -> void:
	await _wait_role("Admin")
	_assert(main.sidebar.sections["administration"].wrapper.visible and
		main._speed_buttons[60].visible and main._is_admin,
		"authenticated admin sees administration controls")
	(main._speed_buttons[60] as Button).pressed.emit()
	await _wait_until(func() -> bool:
		var config: ContinuumConfig = SpacetimeDB.Continuum.db.config.id.find(0)
		return config != null and is_equal_approx(config.time_scale, 60.0)
	)
	_assert(not failed, "admin speed control changed authoritative config")

func _wait_role(expected: String) -> void:
	await _wait_until(func() -> bool: return main._role_name == expected)
	_assert(not failed, "main scene did not apply role %s" % expected)

func _wait_until(condition: Callable) -> void:
	for _frame in TIMEOUT_FRAMES:
		if failed or condition.call():
			return
		await get_tree().process_frame
	_fail("timed out waiting for sidebar state")

func _wait_file(path: String) -> void:
	_assert(not path.is_empty(), "required coordination path is configured")
	if failed:
		return
	await _wait_until(func() -> bool: return FileAccess.file_exists(path))
	DirAccess.remove_absolute(path)

func _write_identity(path: String) -> void:
	_assert(not path.is_empty(), "identity coordination path is configured")
	if failed:
		return
	_write_marker(path, SpacetimeDB.Continuum.get_local_identity().hex_encode())

func _write_marker(path: String, contents: String = "ready") -> void:
	_assert(not path.is_empty(), "coordination path is configured")
	if failed:
		return
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file:
		file.store_string(contents)
		file.close()
	else:
		_fail("could not write identity coordination file")

func _option(name: String, fallback: String) -> String:
	for argument: String in OS.get_cmdline_user_args():
		if argument.begins_with(name + "="):
			return argument.substr(name.length() + 1)
	return fallback

func _assert(condition: bool, message: String) -> void:
	if not condition:
		_fail(message)

func _fail(message: String) -> void:
	if failed:
		return
	failed = true
	printerr("SIDEBAR_ACCESS_FAIL: %s" % message)
	get_tree().quit(1)
