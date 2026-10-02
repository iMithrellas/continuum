extends SceneTree

const BASE = "res://client/godot/ui/components/"
var failures: int = 0
var checks: int = 0

func expect(condition: bool, message: String) -> void:
	checks += 1
	if not condition:
		failures += 1
		push_error(message)

func _initialize() -> void:
	call_deferred("run")

func run() -> void:
	var host = VBoxContainer.new()
	host.theme = load("res://ui/theme/theme.tres")
	root.add_child(host)
	var fixtures = {
		"resource_readout": {"name": "Wood", "value": 32, "rate_per_game_hour": -4, "eta_game_hours": 8},
		"need_meter": {"label": "Rest", "value": 28},
		"colonist_card": {"id": 1, "name": "Ada", "hunger": 91, "selected": true, "target": {"x": 1}},
		"roster_row": {"id": 1, "name": "Ada", "hunger": 91, "selected": true},
		"alert_row": {"id": 1, "level": "critical", "message": "Raw problem", "acknowledged": false},
		"log_entry": {"level": "critical", "message": "Raw historical event"},
		"away_digest": {"needs_you": [{"id": 1, "level": "critical", "message": "Raw problem"}]}
	}
	for component in fixtures:
		var script = load(BASE + component + ".gd")
		expect(script != null and script.can_instantiate(), component + " compiles")
		if script == null or not script.can_instantiate():
			continue
		var node = script.new()
		host.add_child(node)
		node.set_model(fixtures[component])
		expect(node.get_child_count() > 0, component + " renders")
		node.set_model({})
		expect(node.get_child_count() > 0, component + " handles unavailable")
		node.queue_free()
	var alert = load(BASE + "alert_row.gd").new()
	host.add_child(alert)
	alert.set_model(fixtures.alert_row)
	expect(alert.is_processing(), "unacknowledged critical pulses")
	var emitted: Array = []
	alert.acknowledge_requested.connect(func(id): emitted.append(id))
	var ack_buttons = alert.find_children("*", "Button", true, false)
	ack_buttons[0].pressed.emit()
	expect(emitted == [1], "acknowledgement click emits command")
	expect(alert.model.acknowledged == false and not alert.pending, "click does not invent reducer success or pending")
	alert.set_acknowledgement_state(true)
	expect(not alert.model.acknowledged, "pending is not shared ack")
	alert.set_reduced_motion(true)
	expect(not alert.is_processing(), "reduced motion stops pulse")
	alert.set_reduced_motion(false)
	alert.set_model({"id": 1, "level": "critical", "acknowledged": true})
	expect(not alert.is_processing(), "shared ack stops pulse")
	expect(not alert.pending, "authoritative ack clears pending")
	alert.set_model({"level": "critical"})
	expect(not alert.is_processing(), "missing acknowledgement does not pretend unacknowledged")
	var list = load(BASE + "alert_list.gd").new()
	host.add_child(list)
	list.set_model([])
	expect(list.get_child_count() == 1, "nominal empty alert list")
	list.set_model([fixtures.alert_row])
	list.set_acknowledgement_state(1, true, "")
	list.set_model([fixtures.alert_row])
	expect(list.get_child(0).pending, "list preserves callback pending state across updates")
	list.set_acknowledgement_state(1, false, "Acknowledgement failed")
	expect(list.get_child(0).error_copy == "Acknowledgement failed", "authoritative error callback")
	list.set_reduced_motion(true)
	expect(not list.get_child(0).is_processing(), "list propagates reduced motion")
	var feed = load(BASE + "activity_feed.gd").new()
	host.add_child(feed)
	feed.set_model([{"message": "Raw event", "routine": true}])
	expect(feed.model.hidden_count == 1, "feed hidden count")
	feed.set_show_routine(true)
	expect(feed.model.hidden_count == 0, "feed toggles routine")
	var digest = load(BASE + "away_digest.gd").new()
	host.add_child(digest)
	digest.set_model({"needs_you": [{"id": 1, "level": "critical", "message": "Raw problem"}, {"id": 2, "level": "warn", "message": "Other problem"}]})
	var primary_count = 0
	for button in digest.find_children("*", "Button", true, false):
		if button.theme_type_variation == "ButtonPrimary":
			primary_count += 1
	expect(primary_count == 1, "digest has exactly one primary for provided alerts")
	expect(digest.theme_type_variation == "PanelFloating", "digest delegates floating shadow to foundation")
	await process_frame
	host.queue_free()
	await process_frame
	print("UI controls: %d checks, %d failures" % [checks, failures])
	quit(1 if failures else 0)
