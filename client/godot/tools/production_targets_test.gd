## Backend-free real-control contract. Run with --headless --path client/godot
## res://tools/production_targets_test.tscn after a headless editor import.
extends Node

const TargetsPanel = preload("res://ui/panels/production_targets.gd")
var failed := false
var requests: Array = []
var removals: Array = []


func check(condition: bool, message: String) -> void:
	if not condition:
		failed = true
		push_error("PRODUCTION_TARGETS_FAIL: " + message)


func _ready() -> void:
	var panel := TargetsPanel.new()
	panel.size.x = 320
	add_child(panel)
	check(panel._rows.is_empty(), "default advertises no unsupported automation")
	panel.set_supported_resources(["Food", "1", 3, 3, -1, 2.5, true])
	check(
		panel._rows.size() == 3 and not panel._rows.has(2),
		"explicit support excludes mining and malformed resources"
	)
	panel.target_requested.connect(
		func(resource: int, target: float) -> void: requests.append([resource, target])
	)
	panel.target_removed.connect(func(resource: int) -> void: removals.append(resource))
	var row: Dictionary = panel._rows[0]
	var input: SpinBox = row.input
	var editor := input.get_line_edit()
	var set_button: Button = row.set
	var remove_button: Button = row.remove
	panel.set_snapshot([{"kind": "0", "target": "120.5"}], {"Food": "35.5"}, true, true)
	check(
		input.value == 120.5 and row.state.text == "Target: 120.5",
		"normalizes authoritative policy"
	)
	check(
		row.heading.text.contains("35.5") and panel._rows[1].heading.text.contains("unknown"),
		"total supply and missing supply"
	)
	check(requests.is_empty() and removals.is_empty(), "snapshot does not dispatch")
	panel.set_snapshot([{"resource": 0, "target": 120.5}], {0: 16.3626689910889}, true, true)
	check(
		row.heading.text.ends_with("16.4") and row.heading.tooltip_text.contains("16.3626"),
		"supply is readable while exact observed precision remains inspectable"
	)
	input.value = 140
	await get_tree().process_frame
	panel.set_snapshot([{"resource": 0, "target": 120.5}], {0: 45}, true, true)
	check(input.value == 140, "tick preserves draft")
	set_button.pressed.emit()
	check(
		(
			requests == [[0, 140.0]]
			and row.state.text == "Target: 120.5"
			and row.feedback.text.contains("awaiting")
		),
		"actual Set control emits without optimistic success"
	)
	input.value = 160
	await get_tree().process_frame
	panel.set_snapshot([{"resource": 0, "target": 140}], {}, true, true)
	check(
		(
			input.value == 160
			and row.state.text.begins_with("Target: 140")
			and row.feedback.text.contains("Confirmed")
		),
		"acknowledgement preserves newer draft"
	)
	remove_button.pressed.emit()
	check(
		removals == [0] and row.state.text.begins_with("Target: 140"),
		"Unlimited requests removal without optimistic change"
	)
	panel.set_snapshot([], {}, true, true)
	check(
		(
			row.state.text == "Target: unlimited"
			and remove_button.disabled
			and row.feedback.text.contains("Confirmed")
		),
		"authoritative removal acknowledged"
	)
	for access: Array in [[false, true], [true, false], [false, false]]:
		panel.set_snapshot([{"resource": 0, "target": 90}], {}, access[0], access[1])
		check(
			set_button.disabled and remove_button.disabled and not editor.editable,
			"viewer/disconnected controls disabled"
		)
		set_button.pressed.emit()
		remove_button.pressed.emit()
	check(
		requests.size() == 1 and removals.size() == 1,
		"programmatic button dispatch also fails closed"
	)
	panel.set_snapshot([{"resource": 0, "target": 90}], {}, true, true)
	for text: String in ["", "oops", "nan", "inf", "-5", "0", "1000001", "true"]:
		editor.text = text
		set_button.pressed.emit()
	check(requests.size() == 1, "malformed/out-of-bounds raw input never dispatches")
	editor.text = "unfinished"
	editor.text_changed.emit(editor.text)
	panel.set_snapshot([{"resource": 0, "target": 95}], {}, true, true)
	check(editor.text == "unfinished", "tick preserves raw pending input, not just SpinBox value")
	for value: Variant in [null, true, "bad", INF, NAN, -1, 0]:
		panel.set_snapshot([{"resource": 0, "target": value}], {0: value}, true, true)
		check(row.state.text.contains("unknown"), "invalid policy snapshot fails safely")
		if not (value is int and value == 0):
			check(row.heading.text.contains("unknown"), "invalid supply snapshot displays unknown")
	panel.set_snapshot(
		[
			{"resource": 0, "target": 50},
			{"kind": "Food", "target": 70},
			{"resource": 99, "target": 1},
			null
		],
		{},
		true,
		true
	)
	check(
		row.state.text.contains("unknown"), "duplicate policies do not claim unlimited or success"
	)
	panel.set_snapshot([{"resource": 0, "target": 0.000001}], {}, true, true)
	check(
		row.state.text != "Target: 0.0", "small valid authoritative policy is not displayed as zero"
	)
	check(
		requests.size() == 1 and removals.size() == 1, "all snapshot refreshes remain signal-free"
	)
	panel.set_snapshot([], {}, true, true)
	for factor: float in [1.0, 1.25, 1.5]:
		panel.scale = Vector2.ONE * factor
		panel.size.x = 320.0 / factor
		await get_tree().process_frame
		await get_tree().process_frame
		check(
			panel.get_combined_minimum_size().x * factor <= 320.0,
			"minimum width fits 320px at scale %s" % factor
		)
		check(
			(
				set_button.focus_mode == Control.FOCUS_ALL
				and remove_button.focus_mode == Control.FOCUS_ALL
				and editor.focus_mode == Control.FOCUS_ALL
			),
			"keyboard-focusable controls"
		)
	input.value = 200
	await get_tree().process_frame
	set_button.grab_focus()
	check(set_button.has_focus(), "keyboard focus can reach Set target")
	var key := InputEventKey.new()
	key.keycode = KEY_ENTER
	key.pressed = true
	Input.parse_input_event(key)
	await get_tree().process_frame
	key = InputEventKey.new()
	key.keycode = KEY_ENTER
	key.pressed = false
	Input.parse_input_event(key)
	await get_tree().process_frame
	check(
		requests.size() == 2 and requests.back() == [0, 200.0],
		"keyboard Enter activates real Set target control"
	)
	panel.set_snapshot([{"resource": 0, "target": 200}], {}, true, true)
	check(
		not row.dirty and row.feedback.text.contains("Confirmed"),
		"matching acknowledgement releases unchanged draft"
	)
	panel.set_snapshot([{"resource": 0, "target": 220}], {}, true, true)
	check(
		input.value == 220 and requests.size() == 2,
		"clean editor follows subsequent server change without signals"
	)
	panel.queue_free()
	await get_tree().process_frame
	if not failed:
		print("PRODUCTION_TARGETS_PASS")
	get_tree().quit(1 if failed else 0)
