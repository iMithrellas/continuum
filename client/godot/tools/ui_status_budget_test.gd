## Actual typed main; game-clock observations only, no SDK or live reducers.
extends "res://tools/ui_review_regression.gd"

func _check_functional_contracts() -> void:
	await super._check_functional_contracts()
	for values: Array in [[1.0, 1.0, 1.0, 1.0], [1.0, 1.0, 1.0, 90.0], [90.0, 90.0, 90.0, 90.0], [1e12, 1e12, 1e12, 1e12], [150.0, 150.0, 150.0, 150.0]]:
		main._session_menu.grab_focus()
		var menu: MenuButton = main._session_menu
		await _observed_stocks(values)
		check(get_viewport().gui_get_focus_owner() == menu, "meaningful live stock changes retain Menu focus across internal reflow")
		main._refresh_status()
		await _settle()
		check(get_viewport().gui_get_focus_owner() == menu, "budget changes retain the existing Menu focus node")
		_check_complete_status(values)
		var retained: Node = main._resource_labels[ContinuumResourceKind.Options.food].get_child(0)
		main._refresh_status()
		await _settle()
		check(main._resource_labels[ContinuumResourceKind.Options.food].get_child(0) == retained, "unchanged reflowing status ticks do not rebuild resource controls")
		main.workspace.set_diagnostics_visible(true)
		main._refresh_status()
		await _settle()
		_check_complete_status(values)
		main.workspace.set_diagnostics_visible(false)
		main._refresh_status()
		await _settle()
	# Leave the original adversarial four-critical case visible for capture.
	await _observed_stocks([1.0, 1.0, 1.0, 1.0])
	_check_complete_status([1.0, 1.0, 1.0, 1.0])
	var point: Vector2 = main._session_menu.get_global_rect().get_center()
	await _native_pointer(_pointer_button(true, point))
	await _native_pointer(_pointer_button(false, point))
	check(main._session_menu.get_popup().visible, "native narrow Menu click opens its actual popup")
	main._session_menu.get_popup().hide()
	main._session_menu.get_popup().id_pressed.emit(0)
	check(main._digest_overlay.visible, "budgeted Menu retains live digest reopening")
	main._hide_away_digest()
	await _settle()
	check(main.workspace.area.get_global_rect().encloses(main._action_feedback.get_global_rect()) and main._action_feedback.get_global_rect().encloses(main._action_error.get_global_rect()), "persistent action failure remains visibly fitted after status reflow, including ultra-narrow width")
	print("UI_STATUS_BUDGET_PASS failures=%d" % failures.size())

func _observed_stocks(values: Array) -> void:
	var config: ContinuumConfig = local._tables.config[0]
	var colony: ContinuumColony = local._tables.colony[0]
	var names := ["food", "wood", "stone", "meat"]
	config.generation += 1
	main._session_observations = SessionObservations.new()
	for minute in range(61):
		config.game_seconds = minute * 60.0
		for index in 4:
			var origin: float = 100.0 if values[index] < 100 else values[index] - 100.0
			colony.set(names[index], lerpf(origin, values[index], minute / 60.0))
		main._observe_session_state()
	main._refresh_status()
	await _settle()

func _check_complete_status(values: Array) -> void:
	var status: Rect2 = main.workspace._rows[0].get_global_rect()
	check(status.encloses(main._session_menu.get_global_rect()), "actual Menu hit area is fully inside the clipped status viewport")
	check(status.encloses(main._connection_label.get_parent().get_global_rect()), "neutral connection glyph and word remain fully visible")
	for card: ResourceReadout in main._resource_labels.values():
		check(card.is_visible_in_tree() and status.encloses(card.get_global_rect()), "every live resource fits the aggregate clipped status budget: " + card.model.name)
		_assert_visible_labels(card, status)
		if card.model.level in ["warn", "critical"]:
			check(_find_label(card, "Critical" if card.model.level == "critical" else "Warning"), "every actual resource severity word is visibly rendered")
			var forecast := _forecast_label(card)
			check(forecast != null and "game h" in forecast.text and "Est " in forecast.text, "every warning retains estimated game-hour units")
			if card.model.level == "critical": check("<0.1 game h" in forecast.text, "positive sub-resolution ETA is less-than, never apparent zero")
	check(main.map.get_global_rect() == main.workspace.area.get_global_rect(), "status reflow leaves the map filling all remaining workspace area")
	var global_point: Vector2 = main.map.get_global_transform() * main.map.world_to_screen(Vector2(8.5, 8.5))
	check(main.map.screen_to_world(main.map.get_global_transform().affine_inverse() * global_point).distance_to(Vector2(8.5, 8.5)) < 0.001, "projection/global picking reconcile after state-driven status reflow")
	if values[0] == 150.0 and main.workspace.area.size.x >= 640:
		check(status.size.y == ThemeTokens.number("topbar"), "calm data restores the nominal 40px strip without a viewport resize")
	check(main.workspace._rows.size() == 2 and main.workspace._rows[1].get_global_rect().position.y >= status.end.y, "internal resource reflow does not overlap the workspace strip")

func _forecast_label(node: Node) -> Label:
	if node is Label and node.text.begins_with("Est "): return node
	for child in node.get_children():
		var found := _forecast_label(child)
		if found != null: return found
	return null

func _assert_visible_labels(node: Node, viewport: Rect2) -> void:
	if node is Label or node is TextureRect:
		check(viewport.encloses(node.get_global_rect()), "warning/value/glyph is wholly inside the real clipped viewport")
		if node is Label: check(node.get_theme_font_size("font_size") >= 11, "budget fix never shrinks logical type")
	for child in node.get_children(): _assert_visible_labels(child, viewport)
