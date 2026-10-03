## Backend-free regression against actual Construction / Zones controls.
## The typed provider is explicit; requests stop at Main's dispatch boundary.
extends Node
var failures := 0
var assertions := 0
var requests: Array = []
func check(value: bool, message: String) -> void:
	assertions += 1
	if not value:
		failures += 1
		push_error(message)

func _ready() -> void:
	get_window().size = Vector2i(1440, 900)
	var previous := SpacetimeDB.Continuum.db
	var local := preload("res://tools/terrain_fixture.gd").database()
	var colony := ContinuumColony.new()
	colony.wood = 1000
	local._tables.colony[0] = colony
	preload("res://tools/terrain_fixture.gd").index_rows(local)
	var main := preload("res://scenes/main.tscn").instantiate()
	main.set_script(preload("res://tools/terrain_ui_fixture_main.gd"))
	add_child(main)
	main._session_requested = true
	main._state_ready = true
	main._menu.hide()
	main._server_management.hide()
	main.map.refresh()
	main._set_permissions("operator", true, false)
	main.map_intent_override = func(reducer: String, payload: Array) -> void: requests.append([reducer, payload])
	main.workspace.switch_workspace("build")
	check(main._excavation_list.get_child_count() == 1 and main._excavation_list.get_parent() == main._sections["construction"], "Construction inspects canonical generated excavation coordinates")
	check(main._construction_panel.get_parent() == main._sections["construction"] and main._zones_panel.get_parent() == main._sections["operations"], "room and usage controls have independent panel ownership")
	check(main._zones_panel.choices.size() == 7 and main._dimension_inputs.keys() == ["excavation"], "seven kinds belong to Zones; terrain work has no legacy facility dimensions")
	check(main._dimension_inputs["excavation"].value == 6 and main._construction_panel.clearance.value == 4,
		"excavation starts at six layers and room clearance starts at the four-layer minimum")
	var area := Rect2i(6, 0, 1, 2)
	main._construction_panel.activate.pressed.emit()
	main.map.build_rectangle_requested.emit(area)
	check(requests == [["construct_room", [6, 0, 6, 1, -8, 4]]], "actual Construction action and map signal dispatch inclusive bounds at the exposed base")
	main._construction_panel.clearance.value = 6
	main.map.build_rectangle_requested.emit(area)
	check(requests.size() == 2 and requests.back() == ["construct_room", [6, 0, 6, 1, -8, 6]], "actual clearance editor changes room payload without changing the terrain cut")
	colony.wood = 0
	main._zones_panel.activate.pressed.emit()
	main._zones_panel.choices[ContinuumTileKind.Options.storage].pressed.emit()
	main.map.build_rectangle_requested.emit(area)
	check(requests.size() == 3 and requests.back()[0] == "designate_zone_at" and requests.back()[1].slice(0, 5) == [6, 0, 6, 1, -8] and requests.back()[1][5].value == ContinuumTileKind.Options.storage,
		"actual Zones controls dispatch free usage at the exposed base even with zero wood")
	main._mode_buttons[&"excavate"].pressed.emit()
	main.map.excavation_requested.emit(area, -8, int(main._dimension_inputs["excavation"].value))
	check(requests.size() == 4 and requests.back() == ["designate_excavation", [6, 0, 6, 1, -8, 6, 2]], "Construction terrain-work action preserves exact excavation geometry")
	for font in range(10, 25):
		main.apply_font_size(font, false)
		for frame in 3: await get_tree().process_frame
		for key: String in ["construction", "operations"]:
			main.workspace.windows[key].size = Vector2(280, 180)
			main.workspace.windows[key].show()
		for frame in 3: await get_tree().process_frame
		for key: String in ["construction", "operations"]:
			var window: WorkspaceWindow = main.workspace.windows[key]
			check(window.content.get_combined_minimum_size().x <= window.scroll.size.x + 1,
				"%s controls fit minimum panel at legacy font %d: content=%s scroll=%s" % [key, font, window.content.get_combined_minimum_size(), window.scroll.size])
			check(window.scroll.follow_focus, "minimum-height planning bodies retain keyboard-following scroll")
		for number: SpinBox in main._dimension_inputs.values():
			check(number.get_parent() is VBoxContainer, "numeric dimensions wrap vertically instead of forcing long-label HBox overflow")
	for system: StringName in [&"construction", &"zones", &"excavate"]:
		if system == &"construction": main._construction_panel.activate.pressed.emit()
		elif system == &"zones": main._zones_panel.activate.pressed.emit()
		else: main._mode_buttons[&"excavate"].pressed.emit()
		check(main._planning_system == system and main.map.interaction_mode == (&"excavate" if system == &"excavate" else &"build"), "actual %s action exclusively arms its map tool" % system)
		main.map._dragging = true
		main._set_permissions("viewer", false, false)
		check(main.map.interaction_mode == &"select" and not main.map._dragging and main._planning_system == &"", "permission loss cancels %s paint and its owner" % system)
		check(not main.workspace.authorized["construction"] and not main.workspace.authorized["operations"] and main._construction_panel.activate.disabled and main._zones_panel.activate.disabled, "Viewer revokes both panels and their actual mutation controls")
		check(not main._intent_feedback.get_parent().visible, "revoked tool does not leave an idle header row")
		var before := requests.size()
		main.map.build_rectangle_requested.emit(area)
		main.map.excavation_requested.emit(area, -8, 6)
		main._construction_panel.activate.pressed.emit()
		main._zones_panel.activate.pressed.emit()
		check(requests.size() == before and main._planning_system == &"", "Viewer cannot bypass disabled controls or map signal routing")
		main._set_permissions("Unknown", false, false)
		main._mode_buttons[&"excavate"].pressed.emit()
		check(requests.size() == before and main._planning_system == &"", "Unknown cannot arm terrain work")
		main._set_permissions("operator", true, false)
	var source := SpacetimeDB.Continuum.db
	SpacetimeDB.Continuum.db = null
	main._refresh_controls()
	main._construction_panel.activate.pressed.emit()
	main._zones_panel.activate.pressed.emit()
	main._mode_buttons[&"excavate"].pressed.emit()
	check(requests.size() == 4 and main._planning_system == &"" and main._construction_panel.activate.disabled and main._zones_panel.activate.disabled and main._mode_buttons[&"excavate"].disabled,
		"detached provider denies and disables all planning controls despite cached Operator access")
	SpacetimeDB.Continuum.db = source
	var workspace_path: String = main.fixture_workspace_path
	var settings_path: String = main.fixture_settings_path
	main.free()
	SpacetimeDB.Continuum.db = previous
	local.free()
	DirAccess.remove_absolute(ProjectSettings.globalize_path(workspace_path))
	DirAccess.remove_absolute(ProjectSettings.globalize_path(settings_path))
	print("TERRAIN_UI_%s: %d assertions" % ["PASS" if failures == 0 else "FAIL", assertions])
	get_tree().quit(0 if failures == 0 else 1)
