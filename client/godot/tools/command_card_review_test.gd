## Focused regressions for workspace typography, unknown recap coverage and late permissions.
extends "res://tools/atlas_ui_fixture.gd"


func pass_marker() -> String:
	return "COMMAND_CARD_REVIEW_TEST_PASS"


func run_contracts() -> void:
	var deck: WorkspaceDeck = main.workspace
	deck.open_command(true)
	await settle()
	var card: CommandCard = deck.command_card
	check(card._digest_count == -1, "recap starts with unknown coverage, not an invented zero")
	check(card._digest_label.text == "—", "unknown recap renders an em dash")
	check(
		"Coverage unavailable" in card._footer_buttons.digest.tooltip_text,
		"unknown recap explains its missing coverage"
	)
	for count: int in [0, 14, -1, -20]:
		card.set_recap_count(count)
		check(
			card._digest_label.text == ("—" if count < 0 else str(count)),
			"recap distinguishes supplied zero, actual count and unavailable coverage"
		)
	card.set_digest_count(3)
	check(card._digest_label.text == "3", "existing digest setter delegates to coverage API")
	card.set_recap_count(-1)
	await _workspace_labels(card, deck)
	await _late_permissions(card, deck)
	deck._fit_command()
	await settle()
	await _save_feedback(card, deck)


func _save_feedback(card: CommandCard, deck: WorkspaceDeck) -> void:
	check(deck.get("preference_error") is String, "deck exposes save failure feedback")
	var path: String = deck._save_path
	deck.state("people").open = not deck.state("people").open
	deck._save_path = "user://command_review_missing_directory/layout.cfg"
	card._workspace_action("save")
	await settle()
	check(deck.is_layout_dirty() and card._modified.visible, "failed Save retains dirty controls")
	var note: Label = card._preference_error
	check(note.is_visible_in_tree(), "explicit failed Save exposes a visible footer note")
	check(note.text == deck.get("preference_error"), "footer note carries the actual failure")
	check(note.tooltip_text == note.text, "save failure tooltip retains the whole message")
	check(note.get_visible_line_count() in [1, 2], "save failure note renders one or two lines")
	check(card._footer.get_global_rect().encloses(note.get_global_rect()), "error stays in footer")
	check(
		deck.area.get_global_rect().grow(1).encloses(card._footer.get_global_rect()),
		"error footer remains bounded at current viewport scale"
	)
	deck.close_command()
	card.refresh()
	check(not deck.is_command_open(), "save feedback never opens or cancels a command gesture")
	deck._save_path = path
	deck.save_workspace()
	card.refresh()
	check(not note.visible, "successful Save clears footer failure note")
	deck.open_command(true)
	await settle()


func _workspace_labels(card: CommandCard, deck: WorkspaceDeck) -> void:
	var original: String = deck.model.workspaces.daily.name
	for title: String in [
		original,
		"Production operations workspace with a deliberately long user name",
		"UnbrokenUserWorkspaceNameThatStillNeedsReadableEllipsis",
	]:
		deck.model.workspaces.daily.name = title
		for width: float in [272.0, 240.0]:
			card.set_available_size(Vector2(width + 16, deck.size.y))
			card.refresh()
			await settle()
			check(card._workspace_grid.columns == 2, "workspace grid remains two columns")
			for id: String in card._workspace_buttons:
				var nodes: Dictionary = card._workspace_buttons[id]
				var label: Label = nodes.label
				var button: Button = nodes.button
				check(is_equal_approx(button.size.y, 44), "workspace cards retain 44px height")
				check(label.get_theme_font_size("font_size") == 12, "workspace font stays 12px")
				check(
					label.size.x >= 16 and label.size.y >= 16,
					"workspace name has readable width and minimum line height: " + id
				)
				check(
					label.get_visible_line_count() in [1, 2],
					"workspace name renders one or two lines: " + id
				)
				if label.get_line_count() > 1:
					check(
						label.get_visible_line_count() == 2,
						"wrapped workspace names use both readable lines: " + id
					)
				check(
					button.get_global_rect().encloses(label.get_global_rect()),
					"workspace name stays inside its card: " + id
				)
				check(
					label.text_overrun_behavior == TextServer.OVERRUN_TRIM_ELLIPSIS,
					"workspace name preserves readable ellipsis: " + id
				)
				check(label.text in button.tooltip_text, "tooltip retains the whole name: " + id)
	deck.model.workspaces.daily.name = original
	card.refresh()


func _late_permissions(card: CommandCard, deck: WorkspaceDeck) -> void:
	var permissions := deck.authorized.duplicate()
	# Simulate creation in the opposite order from the declared registry.
	for key: String in ["overview", "people", "policies", "construction", "operations"]:
		if card._panel_rows.has(key):
			var row: Control = card._panel_rows[key].row
			row.get_parent().remove_child(row)
			row.queue_free()
			card._panel_rows.erase(key)
		deck.authorized[key] = false
	card.refresh()
	for key: String in ["operations", "construction", "policies", "people", "overview"]:
		deck.authorized[key] = true
		card.refresh()
		await settle()
	for group: String in ["Colony", "Build"]:
		var actual: Array[String] = []
		for child: Node in card._group_nodes[group].section.get_children():
			if str(child.name).begins_with("Panel_"):
				actual.append(str(child.name).trim_prefix("Panel_"))
		check(actual == CommandCard.GROUPS[group], "late permission rows follow registry: " + group)
	deck.authorized.people = false
	card.refresh()
	check(not card._panel_rows.people.row.visible, "revoked row remains hidden")
	check(card._group_nodes.Colony.count.text.ends_with(" / 3"), "revoked row is not counted")
	card._on_query_changed("colonist")
	check(not card._panel_rows.people.row.visible, "search never reveals revoked row")
	check(not card._panel_rows.people.button in card._results, "revoked row is not a search result")
	card._on_query_changed("")
	deck.authorized = permissions
	card.refresh()
