## Actual native-cursor hover contracts; never substitute parsed mouse motion.
extends "res://tools/atlas_ui_test.gd"


func pass_marker() -> String:
	return "ATLAS_UI_HOVER_TEST_PASS"


func run_contracts() -> void:
	check(DisplayServer.get_name() != "headless", "native hover gate requires a render window")
	if DisplayServer.get_name() == "headless":
		return
	var deck: Variant = main.workspace
	var workspaces: Dictionary = deck.model.workspaces.duplicate(true)
	var saved: Dictionary = deck.model.saved_workspaces.duplicate(true)
	var active: String = deck.model.active
	var focus := get_viewport().gui_get_focus_owner()
	if focus != null:
		focus.release_focus()
	Input.warp_mouse(get_viewport().get_final_transform() * Vector2(80, 80))
	await settle()
	deck.model.workspaces = WorkspaceLayout.defaults()
	deck.model.saved_workspaces = deck.model.workspaces.duplicate(true)
	deck.model.active = "daily"
	deck.close_command()
	deck._rebuild_navigation()
	deck._apply_layout()
	await settle()
	deck.save_workspace()
	var status: Variant = deck.windows.status
	var before: Dictionary = deck.state("status").duplicate(true)
	var baseline: Dictionary = deck.model.saved_workspaces.daily.duplicate(true)
	Input.warp_mouse(
		get_viewport().get_final_transform() * status.micro_content.get_global_rect().get_center()
	)
	await settle()
	print(
		(
			"ATLAS_NATIVE_HOVER_REVEAL physical=%s window=%s paint=%s natural=%s controls_visible=%s"
			% [
				_screen,
				status.get_global_rect(),
				status.get_visible_global_rect(),
				status.micro_size(),
				status._controls.is_visible_in_tree()
			]
		)
	)
	check(status._controls.is_visible_in_tree(), "native Status hover reveals controls")
	check(
		status.size.is_equal_approx(status.micro_size()),
		"native Status hover relayout uses actual painted micro extent"
	)
	check(
		deck.area.get_global_rect().grow(1).encloses(status.get_visible_global_rect()),
		"native Status hovered paint remains bounded"
	)
	check(
		is_equal_approx(
			status.header_ground.get_global_rect().get_center().x,
			deck.area.get_global_rect().get_center().x
		),
		"native Status hover retains centered natural anchor"
	)
	var close: Button = status.close_button
	Input.warp_mouse(get_viewport().get_final_transform() * close.get_global_rect().get_center())
	await settle()
	var hovered := get_viewport().gui_get_hovered_control()
	print(
		(
			"ATLAS_NATIVE_HOVER physical=%s scale=%d hovered=%s close=%s window=%s paint=%s controls_visible=%s"
			% [
				_screen,
				_scale,
				hovered.get_path() if hovered != null else "none",
				close.get_global_rect(),
				status.get_global_rect(),
				status.get_visible_global_rect(),
				status._controls.is_visible_in_tree()
			]
		)
	)
	check(
		(
			close.is_visible_in_tree()
			and (hovered == close or (hovered != null and close.is_ancestor_of(hovered)))
		),
		"native Status Close is actual hovered GUI target, not Resources"
	)
	check(
		status.get_visible_global_rect().grow(1).encloses(close.get_global_rect()),
		"native Close is enclosed by Status owned paint"
	)
	_check_gesture_unchanged(deck, "status", before, baseline, "native cursor hover only")
	Input.warp_mouse(
		(
			get_viewport().get_final_transform()
			* (status.micro_content.get_global_rect().position + Vector2(8, 8))
		)
	)
	await settle()
	var point: Vector2 = status.micro_content.get_global_rect().position + Vector2(8, 8)
	await _click(point)
	await settle()
	_check_gesture_unchanged(
		deck, "status", before, baseline, "native hovered Status stationary click"
	)
	deck.model.workspaces = workspaces
	deck.model.saved_workspaces = saved
	deck.model.active = active
	deck._rebuild_navigation()
	deck._apply_layout()
	if _command and not _settings:
		deck.open_command(true)
	else:
		deck.close_command()
	_park_pointer()
	await settle()
