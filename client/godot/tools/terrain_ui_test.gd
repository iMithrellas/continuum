## Backend-free regression against the actual instantiated Operations panel.
extends Node
var failures := 0
func check(value: bool, message: String) -> void:
	if not value:
		failures += 1
		push_error(message)

func _ready() -> void:
	var previous := SpacetimeDB.Continuum.db
	var local := preload("res://tools/terrain_fixture.gd").database()
	var main := preload("res://scenes/main.tscn").instantiate()
	main.set_script(preload("res://tools/terrain_ui_fixture_main.gd"))
	add_child(main)
	main._state_ready = true
	main.map.refresh()
	main._set_permissions("operator", true, false)
	check(main._excavation_list.get_child_count() == 1, "actual Operations panel inspects canonical generated designation coordinates")
	check(main._mode_buttons.size() == 4, "actual Operations panel exposes all four modes")
	for font in range(10, 25):
		main.apply_font_size(font, false)
		main.workspace.windows["operations"].size = main._metrics.min_size(280, 180)
		main.workspace.windows["operations"].show()
		await get_tree().process_frame
		await get_tree().process_frame
		var window: WorkspaceWindow = main.workspace.windows["operations"]
		check(window.content.get_combined_minimum_size().x <= window.scroll.size.x + 1,
			"Operations controls and dimension labels fit minimum panel at font %d: content=%s scroll=%s" % [font, window.content.get_combined_minimum_size(), window.scroll.size])
		for number: SpinBox in main._dimension_inputs.values():
			check(number.get_parent() is VBoxContainer, "numeric dimensions wrap vertically instead of forcing long-label HBox overflow")
	for mode: StringName in [&"build", &"excavate", &"facility"]:
		main._mode_buttons[mode].pressed.emit()
		check(main.map.interaction_mode == mode, "actual %s mode button arms requested tool" % mode)
		main.map._dragging = true
		main._set_permissions("viewer", false, false)
		check(main.map.interaction_mode == &"select" and not main.map._dragging, "permission loss cancels %s paint" % mode)
		for mutation: StringName in [&"build", &"excavate", &"facility"]:
			check(not main._mode_buttons[mutation].visible, "viewer hides %s mutation mode consistently" % mutation)
		main._set_permissions("operator", true, false)
	check(main._dimension_inputs["excavation"].value == 6 and main._dimension_inputs["clearance"].value == 6,
		"actual numeric default excavation/clearance controls remain six half-metre layers")
	var workspace_path: String = main.fixture_workspace_path
	var settings_path: String = main.fixture_settings_path
	main.free()
	SpacetimeDB.Continuum.db = previous
	local.free()
	DirAccess.remove_absolute(ProjectSettings.globalize_path(workspace_path))
	DirAccess.remove_absolute(ProjectSettings.globalize_path(settings_path))
	print("TERRAIN_UI_%s" % ["PASS" if failures == 0 else "FAIL"])
	get_tree().quit(0 if failures == 0 else 1)
