## Targeted production-main regressions for the combined review's F1/F2.
extends "res://tools/ui_composition_fixture.gd"

func _check_functional_contracts() -> void:
	await super._check_functional_contracts()
	await _action_errors()
	await _live_digest()
	var svg := UiIcons.svg_source("plus", "ink")
	check('stroke-linecap="square"' in svg and 'stroke-width="2.25"' in svg and 'viewBox="0 0 24 24"' in svg, "actual runtime/PCK icon wrapper uses literal square caps and the required stroke scale")
	for label: Label in [main._block_info, main._tile_info, main._order_summary, main._cell_label]:
		check("Mono" in label.get_theme_font("font").get_font_name(), "numeric inspection/order/surface readouts use actual Plex Mono")
	for controls in main._block_controls.values():
		if controls is Dictionary and controls.has("count"):
			check("Mono" in controls.count.get_theme_font("font").get_font_name(), "separated changing work counts use Mono while word labels remain Sans")
	main._show_action_error("set_zone_enabled was rejected: permission denied")
	print("UI_REVIEW_REGRESSIONS_DONE failures=%d" % failures.size())

func _settle() -> void:
	for frame in 6:
		await get_tree().process_frame

func _reply(outcome: ReducerOutcomeEnum) -> ReducerResultMessage:
	var reply := ReducerResultMessage.new()
	reply.reducer_result = outcome
	return reply

func _action_errors() -> void:
	main._set_permissions("operator", true, false)
	for outcome in [ReducerOutcomeEnum.create_err("(  permission denied".to_utf8_buffer()), ReducerOutcomeEnum.create_internal_error("internal failure")]:
		var call := SpacetimeDBReducerCall.new()
		main._report(call, "set_zone_enabled")
		call.response.emit(_reply(outcome))
		check(main._action_feedback.visible and "set_zone_enabled" in main._action_error.text, "ready-session reducer rejection/internal failure is visibly separate from health")
		main._render_connection_role()
		main._refresh_status()
		check(main._connection_label.text == "Live" and main._action_feedback.visible, "ordinary health rendering cannot clear action failure")
	check("internal failure" in main._action_error.text, "actual failure detail remains literal visible text")
	main._report(SpacetimeDBReducerCall.fail(ERR_CANT_CONNECT), "set_zone_enabled")
	check("could not be sent" in main._action_error.text, "send failure stays visible on an authoritative ready session")
	check(main._action_error.get_theme_font_size("font_size") >= 11, "failure typography meets logical floor")
	var surface: StyleBoxFlat = main._action_feedback.get_theme_stylebox("panel")
	check(surface.bg_color == ThemeTokens.color("critical-soft") and surface.border_color == ThemeTokens.color("critical"), "failure uses token-safe critical ground and casing")
	var stale := SpacetimeDBReducerCall.new()
	main._report(stale, "stale_epoch")
	main._session_generation += 1
	var text: String = main._action_error.text
	stale.response.emit(_reply(ReducerOutcomeEnum.create_internal_error("stale")))
	check(main._action_error.text == text, "old-epoch report callback is ignored")
	stale = SpacetimeDBReducerCall.new()
	main._report(stale, "old_permission")
	main._set_permissions("viewer", false, false)
	main._set_permissions("operator", true, false)
	stale.response.emit(_reply(ReducerOutcomeEnum.create_internal_error("deauthorized")))
	check(main._action_error.text == text, "permission loss then regrant cannot revive an old action callback")
	_find_button(main._action_feedback, "Dismiss").pressed.emit()
	check(not main._action_feedback.visible, "explicit dismissal clears action feedback")

func _seed_return() -> void:
	var current: Dictionary = main._authoritative_snapshot()
	var baseline: Dictionary = current.duplicate(true)
	baseline.game_seconds = maxf(0, current.game_seconds - 3600)
	baseline.resources.food = float(current.resources.food) + 10
	main._return_snapshots.remember(main._return_key, baseline)
	main._return_observed = false
	main._return_snapshot.clear()
	main._observe_session_state()
	main._show_away_digest()

func _live_digest() -> void:
	_seed_return()
	await _settle()
	check(not main._digest.model.deltas.is_empty() and "frozen comparison" in main._digest.model.span and "captured at game time" in main._digest.model.span, "resource comparison has an explicit frozen reconnect boundary")
	var captured: String = main._digest.model.span
	var back := _find_button(main._digest, "Back to the colony")
	back.grab_focus()
	await _settle()
	var scroll: ScrollContainer = main._digest.get_parent()
	scroll.scroll_vertical = 10
	var offset := scroll.scroll_vertical
	var config: ContinuumConfig = local._tables.config[0]
	config.game_seconds += 1
	main._observe_session_state()
	main._refresh_alerts()
	await _settle()
	check(_find_button(main._digest, "Back to the colony") == back and get_viewport().gui_get_focus_owner() == back and scroll.scroll_vertical == offset, "ordinary ticks preserve modal control identity, focus and scroll")
	local._tables.alert[1].acknowledged = true
	main._refresh_alerts()
	await _settle()
	check(main._digest.model.needs_you[0].acknowledged and _find_label(main._digest, "Acknowledged"), "open modal displays actual shared acknowledgement")
	check(not main._alert_box.get_child(0).is_processing(), "shared acknowledgement stops background critical pulse")
	check(get_viewport().gui_get_focus_owner().get_meta("digest_focus_key", "") == "back" and scroll.scroll_vertical == offset, "meaningful live acknowledgement preserves modal focus and scroll")
	local._tables.alert[1].severity = ContinuumSeverity.create(1)
	main._refresh_alerts()
	check(main._digest.model.needs_you[0].level == "warn", "open modal reconciles actual severity")
	local._tables.alert[1].active = false
	main._refresh_alerts()
	check(main._digest.model.needs_you.size() == 1 and main._digest.model.needs_you[0].id == 2, "resolved alert disappears from live current collection")
	main._set_permissions("viewer", false, false)
	check(not main._digest.model.needs_you[0].can_acknowledge, "open digest reflects deauthorization")
	main._set_permissions("operator", true, false)
	var reviewed: Array = []
	main._digest.review_requested.connect(func(ids: Array) -> void: reviewed.assign(ids))
	_find_button(main._digest, "Review alerts").pressed.emit()
	check(reviewed == [2], "footer review IDs are current known IDs, not captured removed rows")
	main._show_away_digest()
	check(main._digest.model.span == captured and main._digest.model.needs_you[0].id == 2, "reopening explicitly mixes frozen comparison with labelled live alerts")
	await _settle()
	_find_button(main._digest, "Review alerts").grab_focus()
	local._tables.alert[2].active = false
	main._refresh_alerts()
	await _settle()
	check(main._digest.model.needs_you.is_empty() and get_viewport().gui_get_focus_owner().get_meta("digest_focus_key", "") == "back", "removing the legitimately focused review command restores stable modal focus")
	config.generation += 1
	main._observe_session_state()
	check(main._digest.model.deltas.is_empty() and "discarded" in main._digest.model.span and not "frozen comparison" in main._digest.model.span, "generation reset immediately invalidates visible comparisons and span")
	_seed_return()
	config.game_seconds -= 1
	main._observe_session_state()
	check(main._digest.model.deltas.is_empty(), "backward clock immediately invalidates open comparison")
	_seed_return()
	local._tables.event_log.clear()
	main._observe_session_state()
	check(main._digest.model.deltas.is_empty(), "backward retained event watermark immediately invalidates open comparison")
	main._digest.set_model({"needs_you": [], "group_coverage": {"needs_you": {"status": "partial"}}})
	check(main._digest.model.group_coverage.needs_you.status == "partial" and not _find_label(main._digest, "Nothing needs you"), "partial coverage cannot imply reassuring emptiness")
	main._hide_away_digest()

func _find_label(node: Node, text: String) -> bool:
	if node is Label and node.text == text:
		return true
	for child in node.get_children():
		if _find_label(child, text):
			return true
	return false
