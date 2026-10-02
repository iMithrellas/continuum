extends SceneTree

const BASE = "res://client/godot/ui/components/"
var checks: int = 0
var failures: int = 0

func expect(condition: bool, message: String) -> void:
	checks += 1
	if not condition:
		failures += 1
		push_error(message)

func _initialize() -> void:
	call_deferred("run")

func settle() -> void:
	for _frame in range(4):
		await process_frame

func click(control: Control) -> void:
	var point = control.get_global_rect().get_center()
	var motion = InputEventMouseMotion.new()
	motion.position = point
	motion.global_position = point
	Input.parse_input_event(motion)
	for down in [true, false]:
		var event = InputEventMouseButton.new()
		event.button_index = MOUSE_BUTTON_LEFT
		event.position = point
		event.global_position = point
		event.pressed = down
		Input.parse_input_event(event)
		await process_frame

func assert_panel_fit(component: String, data: Dictionary, case_name: String) -> void:
	var control = load(BASE + component + ".gd").new()
	# The digest is itself the floating outer panel; other controls live inside it.
	var outer: PanelContainer = control if component == "away_digest" else PanelContainer.new()
	outer.theme = load("res://ui/theme/theme.tres")
	outer.position = Vector2(16, 16)
	outer.size = Vector2(280, 1)
	if control != outer:
		outer.add_child(control)
	root.add_child(outer)
	control.set_model(data)
	await settle()
	expect(outer.get_combined_minimum_size().x <= 280, case_name + " outer minimum fits 280")
	expect(outer.size.x <= 280, case_name + " actual viewport outer fits 280")
	var body: Control = control.get_child(0) if control == outer else control
	expect(body.get_combined_minimum_size().x <= 256, case_name + " component minimum fits padded 256 body")
	var bounds = outer.get_global_rect()
	for descendant in outer.find_children("*", "Control", true, false):
		var rect = descendant.get_global_rect()
		expect(rect.position.x >= bounds.position.x - 0.1 and rect.end.x <= bounds.end.x + 0.1, case_name + " descendant stays within viewport width: " + descendant.get_class())
		if descendant is Label or descendant is Button:
			expect(descendant.get_theme_font_size("font_size") >= 11, case_name + " no font shrinking")
		if descendant is Button:
			expect(descendant.tooltip_text == descendant.text and not descendant.text.is_empty(), case_name + " full command retained in text and tooltip")
	outer.queue_free()
	await settle()

func visible_text(node: Node) -> String:
	var copies: Array[String] = []
	for label in node.find_children("*", "Label", true, false):
		copies.append(label.text)
	return "\n".join(copies)

func collection_rendering() -> void:
	var list = load(BASE + "alert_list.gd").new()
	list.theme = load("res://ui/theme/theme.tres")
	list.size = Vector2(256, 1)
	root.add_child(list)
	var digest = load(BASE + "away_digest.gd").new()
	digest.theme = list.theme
	digest.size = Vector2(280, 1)
	root.add_child(digest)
	var valid = {"id": 1, "level": "critical", "message": "Actual provided problem", "acknowledged": false}
	var cases = [{"input": null, "status": "unavailable", "count": 0}, {"input": "invalid", "status": "unavailable", "count": 0}, {"input": [null, "invalid"], "status": "unavailable", "count": 0}, {"input": [null, {"level": "banana"}], "status": "unavailable", "count": 0}, {"input": [valid, null, {"level": "banana"}], "status": "partial", "count": 1}, {"input": [], "status": "complete", "count": 0}, {"input": [valid], "status": "complete", "count": 1}]
	for fixture in cases:
		list.set_model(fixture.input)
		digest.set_model({"needs_you": fixture.input, "changed_by_others": [], "handled": [], "deltas": []})
		await settle()
		expect(list.model.status == fixture.status, "rendered alert collection coverage " + fixture.status)
		var actual_rows = 0
		for child in list.get_children():
			if child is AlertRow:
				actual_rows += 1
		expect(actual_rows == fixture.count, "invalid collections do not generate alert row controls")
		var reassure = fixture.status == "complete" and fixture.count == 0
		expect(visible_text(list).contains("Nominal · no active alerts") == reassure, "nominal only for truly empty complete alerts")
		expect(visible_text(digest).contains("Nothing needs you") == reassure, "nothing needs you only for truly empty complete group")
		if fixture.status != "complete":
			expect(visible_text(list).contains("unavailable") or visible_text(list).contains("partial"), "invalid alerts visibly state coverage")
			expect(visible_text(digest).contains("Needs-you unavailable") or visible_text(digest).contains("Needs-you coverage partial"), "invalid needs-you visibly states coverage")
	list.set_model()
	digest.set_model({})
	await settle()
	expect(not visible_text(list).contains("Nominal") and visible_text(list).contains("unavailable"), "missing alert argument is unavailable")
	expect(not visible_text(digest).contains("Nothing needs you") and visible_text(digest).contains("Needs-you unavailable"), "missing digest group is unavailable")
	list.set_model([], {"status": "partial", "copy": "Query coverage is incomplete"})
	digest.set_model({"needs_you": [], "group_coverage": {"needs_you": {"status": "partial"}}})
	await settle()
	expect(not visible_text(list).contains("Nominal") and visible_text(list).contains("Query coverage is incomplete"), "explicit partial query metadata suppresses nominal")
	expect(not visible_text(digest).contains("Nothing needs you") and visible_text(digest).contains("partial"), "explicit partial digest metadata suppresses reassurance")
	list.queue_free()
	digest.queue_free()
	await settle()

func command_rendering(component: String, fixture: Dictionary) -> void:
	var node = load(BASE + component + ".gd").new()
	node.theme = load("res://ui/theme/theme.tres")
	node.position = Vector2(16, 16)
	node.size = Vector2(280, 1)
	root.add_child(node)
	var data = fixture.duplicate(true)
	data.level = "critical"
	data.message = "Actual provided problem"
	data.acknowledged = false
	data.name = "Finn"
	data.state = "Working"
	data.commands = [{"id": "rest", "label": "Rest"}, {"id": null, "label": "Invalid command"}]
	node.set_model({"needs_you": [data], "changed_by_others": [], "handled": [], "deltas": []} if component == "away_digest" else data)
	var ack: Array = []
	var navigation: Array = []
	var reviews: Array = []
	var commands: Array = []
	var selections: Array = []
	if node.has_signal("acknowledge_requested"):
		node.acknowledge_requested.connect(func(id): ack.append(id))
	if node.has_signal("goto_requested"):
		node.goto_requested.connect(func(id): navigation.append(id))
	if node.has_signal("review_requested"):
		node.review_requested.connect(func(ids): reviews.append(ids))
	if node.has_signal("command_requested"):
		node.command_requested.connect(func(id, command): commands.append([id, command]))
	if node.has_signal("selection_requested"):
		node.selection_requested.connect(func(id): selections.append(id))
	await settle()
	var models = load(BASE + "models.gd")
	var valid_id: bool = models.valid_identifier(data.get("id"))
	var valid_target: bool = models.valid_target(data.get("target"))
	for button in node.find_children("*", "Button", true, false):
		if button.text.begins_with("Back to"):
			continue
		var available = valid_id
		if button.text.begins_with("Go to"):
			available = valid_id and valid_target
		elif button.text.begins_with("Invalid command"):
			available = false
		expect(button.disabled != available, component + " actual button availability: " + button.text)
		var before = ack.size() + navigation.size() + reviews.size() + commands.size()
		await click(button)
		var after = ack.size() + navigation.size() + reviews.size() + commands.size()
		expect(after == before + (1 if available else 0), component + " viewport button click emits only available command")
		if not available:
			expect(button.text.contains("unavailable"), component + " disabled reason is clear")
			button.pressed.emit()
			expect(ack.size() + navigation.size() + reviews.size() + commands.size() == after, component + " invalid command callback is also guarded")
	expect(selections.is_empty(), component + " real buttons do not leak duplicate selection")
	for id in ack + navigation:
		expect(valid_id and id == data.get("id"), component + " signal preserves legitimate zero identifier")
	for ids in reviews:
		expect(ids == [data.get("id")] and valid_id, "digest review filters invalid identifiers")
	for command in commands:
		expect(command == [data.get("id"), "rest"] and valid_id, "card command preserves entity id and command")
	node.queue_free()
	await settle()

func find_alert(list: Node, title: String) -> AlertRow:
	for child in list.get_children():
		if child is AlertRow and child.model.title == title:
			return child
	return null

func mixed_identifier_callbacks() -> void:
	var list = load(BASE + "alert_list.gd").new()
	list.theme = load("res://ui/theme/theme.tres")
	list.position = Vector2(16, 16)
	list.size = Vector2(280, 1)
	list.set_reduced_motion(true)
	root.add_child(list)
	# The first pair is the exact boolean-false/integer-zero review repro.
	var identifiers: Array = [false, 0, null, "", [], {}, 0.5, "0", "actual-id", 0.0]
	var rows: Array = []
	for index in range(identifiers.size()):
		rows.append({"id": identifiers[index], "level": "warn" if index == 1 else "critical", "title": "Row " + str(index), "acknowledged": false, "target": {"x": 0, "y": 0}})
	list.set_model(rows)
	await settle()
	list.set_acknowledgement_state(0, true, "Waiting on server")
	var integer_zero = find_alert(list, "Row 1")
	var string_zero = find_alert(list, "Row 7")
	var string_id = find_alert(list, "Row 8")
	expect(integer_zero != null and string_zero != null and string_id != null, "mixed list renders valid typed identifiers alongside invalid rows")
	expect(integer_zero.pending and integer_zero.error_copy == "Waiting on server", "valid zero callback passes invalid boolean row and applies pending/error")
	expect(not string_zero.pending and string_zero.error_copy.is_empty(), "integer zero callback does not touch string zero")
	list.set_acknowledgement_state("0", true, "String zero request")
	expect(string_zero.pending and string_zero.error_copy == "String zero request", "string zero callback matches its own typed row")
	expect(integer_zero.pending and integer_zero.error_copy == "Waiting on server", "string zero callback does not overwrite integer zero")
	list.set_acknowledgement_state("actual-id", false, "Error for actual-id")
	expect(not string_id.pending and string_id.error_copy == "Error for actual-id", "other valid string callback applies authoritative error")
	for invalid_index in [0, 2, 3, 4, 5, 6, 9]:
		var invalid_row = find_alert(list, "Row " + str(invalid_index))
		expect(invalid_row != null and not invalid_row.pending and invalid_row.error_copy.is_empty(), "invalid row remains untouched by valid callbacks " + str(invalid_index))
		list.set_acknowledgement_state(identifiers[invalid_index], true, "Must not apply")
		expect(not invalid_row.pending and invalid_row.error_copy.is_empty(), "invalid callback identifier is ignored " + str(invalid_index))
		expect(integer_zero.pending and integer_zero.error_copy == "Waiting on server", "invalid callback cannot alter integer zero " + str(invalid_index))
		expect(string_zero.pending and string_zero.error_copy == "String zero request", "invalid callback cannot alter string zero " + str(invalid_index))
	# Invalid read-only acknowledged rows cannot erase a valid cached request.
	rows[0].acknowledged = true
	list.set_model(rows)
	await settle()
	integer_zero = find_alert(list, "Row 1")
	string_zero = find_alert(list, "Row 7")
	string_id = find_alert(list, "Row 8")
	expect(integer_zero.pending and integer_zero.error_copy == "Waiting on server", "integer zero callback state survives rebuild with invalid acknowledged row")
	expect(string_zero.pending and string_zero.error_copy == "String zero request", "string zero has separate cached state after rebuild")
	expect(not string_id.pending and string_id.error_copy == "Error for actual-id", "other string error survives rebuild")
	for invalid_index in [0, 2, 3, 4, 5, 6, 9]:
		var invalid_row = find_alert(list, "Row " + str(invalid_index))
		expect(not invalid_row.pending and invalid_row.error_copy.is_empty(), "cached callback never leaks into invalid row " + str(invalid_index))
	var navigation: Array = []
	list.goto_requested.connect(func(id): navigation.append(id))
	for button in integer_zero.find_children("*", "Button", true, false):
		if button.text == "Go to":
			expect(not button.disabled, "origin target remains available while zero-id callback is pending")
			await click(button)
	expect(navigation.size() == 1 and typeof(navigation[0]) == TYPE_INT and navigation[0] == 0, "real origin-target click emits integer zero exactly once")
	list.set_acknowledgement_state(0, false, "Zero request failed")
	expect(not integer_zero.pending and integer_zero.error_copy == "Zero request failed", "valid zero error callback still applies after navigation")
	expect(string_zero.pending and string_zero.error_copy == "String zero request", "zero error callback leaves string-zero request untouched")
	list.queue_free()
	await settle()
	var row = load(BASE + "alert_row.gd").new()
	root.add_child(row)
	row.set_model({"id": "0", "level": "critical", "title": "Typed identity", "acknowledged": false})
	row.set_acknowledgement_state(true, "String-zero transient state")
	row.set_model({"id": 0, "level": "critical", "title": "Typed identity", "acknowledged": false})
	expect(not row.pending and row.error_copy.is_empty(), "single row string-zero to integer-zero identity clears transient state")
	row.set_acknowledgement_state(true, "Integer-zero transient state")
	row.set_model({"id": "0", "level": "critical", "title": "Typed identity", "acknowledged": false})
	expect(not row.pending and row.error_copy.is_empty(), "single row integer-zero to string-zero identity clears transient state")
	row.queue_free()
	await settle()

func run() -> void:
	root.size = Vector2i(800, 600)
	var row = load(BASE + "roster_row.gd").new()
	row.theme = load("res://ui/theme/theme.tres")
	row.position = Vector2(16, 16)
	row.size = Vector2(600, 32)
	root.add_child(row)
	row.set_model({"id": 7, "name": "Finn", "state": "Starving", "state_level": "critical", "job": "Mining", "hunger": 91, "fatigue": 30, "recreation": 30, "mood": 60, "productivity": 60})
	var selections: Array = []
	row.selection_requested.connect(func(id): selections.append(id))
	await settle()
	for node_name in ["ColonistName", "StateTag", "WorstNeed"]:
		var target = row.find_child(node_name, true, false)
		expect(target != null, "viewport click target exists: " + node_name)
		var before = selections.size()
		await click(target)
		expect(selections.size() == before + 1, "viewport click selects exactly once: " + node_name)
		expect(selections[-1] == 7 if not selections.is_empty() else false, "viewport click preserves id: " + node_name)
	row.grab_focus()
	var before_keyboard = selections.size()
	for down in [true, false]:
		var event = InputEventAction.new()
		event.action = "ui_accept"
		event.pressed = down
		Input.parse_input_event(event)
		await process_frame
	expect(selections.size() == before_keyboard + 1, "viewport keyboard selection emits exactly once")
	row.queue_free()
	await settle()
	var alert = load(BASE + "alert_row.gd").new()
	alert.theme = load("res://ui/theme/theme.tres")
	root.add_child(alert)
	alert.set_model({"id": 1, "level": "critical", "message": "First problem", "acknowledged": false})
	alert.set_acknowledgement_state(true, "Failure for id1")
	alert.set_model({"id": 1, "level": "critical", "message": "Updated first problem", "acknowledged": false})
	expect(alert.pending and alert.error_copy == "Failure for id1", "same identity retains authoritative callback state")
	alert.set_model({"id": 2, "level": "critical", "message": "Second problem", "acknowledged": false})
	expect(not alert.pending and alert.error_copy.is_empty(), "different identity clears stale pending and error")
	expect(alert.is_processing(), "new unacknowledged critical resumes pulse")
	alert.set_acknowledgement_state(true, "Failure for id2")
	alert.set_model({"id": 3, "level": "notice", "message": "Notice", "acknowledged": false})
	expect(not alert.is_processing(), "identity replacement with notice cancels pulse")
	expect(not alert.pending and alert.error_copy.is_empty(), "notice replacement clears stale state")
	alert.set_model({"id": 4, "level": "critical", "message": "Shared acknowledged", "acknowledged": true})
	expect(not alert.is_processing(), "identity replacement with shared acknowledgement cancels pulse")
	alert.queue_free()
	await settle()
	var ordinary = {"id": 7, "name": "Finn", "state": "Starving", "state_level": "critical", "job": "Mining", "selected": true, "hunger": 91, "fatigue": 30, "recreation": 30, "mood": 60, "productivity": 60}
	await assert_panel_fit("roster_row", ordinary, "ordinary selected roster")
	var hostile = ordinary.duplicate(true)
	hostile.name = "UntrustedNameWithoutBreaks".repeat(20)
	hostile.state = "UntrustedStateWithoutBreaks".repeat(20)
	hostile.job = "UntrustedJobWithoutBreaks".repeat(20)
	hostile.cargo = "UntrustedCargoWithoutBreaks".repeat(20)
	hostile.target = {"x": 0, "y": 0}
	hostile.commands = [{"id": "rest", "label": "Send to rest " + "untrusted command".repeat(30)}, {"id": "work", "label": "Return to work"}]
	hostile.automation_rules = [{"label": "Provided rule " + "untrusted rule".repeat(30)}]
	await assert_panel_fit("roster_row", hostile, "long untrusted roster")
	await assert_panel_fit("colonist_card", hostile, "long untrusted card and actions")
	await assert_panel_fit("colonist_card", {}, "unavailable card")
	await assert_panel_fit("alert_row", {"id": 1, "level": "critical", "message": "Finn is starving", "acknowledged": false, "target": {"x": 0, "y": 0}}, "ordinary unacknowledged alert")
	await assert_panel_fit("alert_row", {"id": 1, "level": "critical", "message": hostile.name, "detail": hostile.job, "time_label": hostile.state, "acknowledged": true, "ack_handle": hostile.name, "ack_time": hostile.state, "target": {"x": 0, "y": 0}}, "long untrusted alert metadata")
	await assert_panel_fit("away_digest", {"needs_you": [{"id": 1, "level": "critical", "message": hostile.name, "detail": hostile.job, "target": {"x": 0, "y": 0}}], "deltas": [{"name": hostile.name, "baseline": 2, "current": 3}], "changed_by_others": [{"source": "player", "actor": hostile.name, "verb": "designated", "subject": hostile.job, "time_label": hostile.state}]}, "long untrusted digest")
	await assert_panel_fit("need_meter", {"label": hostile.name, "value": 9}, "long untrusted need label")
	await assert_panel_fit("resource_readout", {"name": hostile.name, "value": 123456789, "rate_per_game_hour": -123456789, "eta_game_hours": 1.5}, "long untrusted resource label")
	await collection_rendering()
	root.size = Vector2i(800, 2000)
	await mixed_identifier_callbacks()
	for component in ["alert_row", "colonist_card", "away_digest"]:
		for id in [null, "", "  ", false, -1, 0.0, {}, [], 0, "actual-id"]:
			await command_rendering(component, {"id": id, "target": {"x": 0, "y": 0}})
		await command_rendering(component, {"target": {"x": 0, "y": 0}})
		for target in [null, "", {}, [], {"x": 0}, {"x": null, "y": 0}, {"x": 0, "y": false}, {"x": INF, "y": 0}, {"x": 0, "y": 0, "z": null}, {"colonist_id": 0}]:
			await command_rendering(component, {"id": 0, "target": target})
		await command_rendering(component, {"id": 0})
	await assert_panel_fit("away_digest", {"needs_you": [{"id": null, "level": "critical", "message": "Actual provided problem", "target": null}]}, "disabled digest commands still fit")
	await assert_panel_fit("alert_row", {"id": null, "level": "critical", "message": "Actual provided problem", "acknowledged": false, "target": null}, "disabled alert commands still fit")
	var feed = load(BASE + "activity_feed.gd").new()
	feed.theme = load("res://ui/theme/theme.tres")
	root.add_child(feed)
	feed.set_model([{"day": 12, "message": "Actual historical event"}])
	await settle()
	var day_labels = feed.get_child(0).get_children()
	expect(day_labels[0].text == "Day" and day_labels[0].theme_type_variation == "LabelSection", "day word retains condensed section style")
	expect(day_labels[1].text == "12" and day_labels[1].theme_type_variation == "LabelReadout", "day number uses separate mono readout style")
	expect(day_labels[1].get_theme_font("font").get_font_name().contains("Plex Mono"), "day number actually uses Plex Mono")
	feed.queue_free()
	await settle()
	print("UI regressions: %d checks, %d failures" % [checks, failures])
	quit(1 if failures else 0)
