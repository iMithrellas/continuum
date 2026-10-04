## Private-GPU, backend-free production-main capture for floating workspaces.
## Uses typed fixture data with floating-panel geometry contracts.
extends "res://tools/ui_composition_fixture.gd"


func _check_functional_contracts() -> void:
	check(
		main.map.get_global_rect() == main.workspace.area.get_global_rect(),
		"open floating panels never reserve or shrink the map"
	)
	check(not main.workspace.has_method("set_panel_dock"), "no docking API remains")
	for window: WorkspaceWindow in main.workspace.windows.values():
		check(window.get_parent() == main.workspace.area, "all panels directly overlay the map")
		check(not window.has_signal("dock_requested"), "no docking controls remain")
		if window.is_visible_in_tree():
			check(window.size.x >= 280, "floating width keeps the logical 280px floor")
			check(window.scroll.follow_focus, "floating body keeps keyboard-following scroll")
			if not window.compact and not window.pinned and not window.collapsed:
				check(
					window.grip.visible and window.grip.size.x >= 16,
					"visible resize corner has a usable hit area"
				)
