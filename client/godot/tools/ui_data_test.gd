extends SceneTree

var failures: Array[String] = []

func _initialize() -> void:
	var actor := ContinuumColonist.new()
	actor.id = 8
	actor.name = "Actual row"
	actor.activity = ContinuumActivity.create(0)
	actor.work = ContinuumWorkType.create(0)
	actor.haul_role = ContinuumHaulRole.create(0)
	actor.carried_kind = ContinuumResourceKind.create(0)
	actor.hunger = 92
	actor.fatigue = 72
	actor.recreation = 4
	actor.mood = 72
	actor.productivity = 86
	actor.x = 9
	actor.y = 4
	actor.z = -2
	var session := SessionObservations.new()
	var raw := {"hunger": actor.hunger, "fatigue": actor.fatigue, "recreation": actor.recreation, "mood": actor.mood, "productivity": actor.productivity}
	var data := UiData.colonist(actor, session, true)
	check(data.hunger == 92 and not data.need_trends.has("hunger"), "live adapter sends raw backend needs and unavailable trends")
	check(data.target == {"colonist_id": 8} and not data.has("commands") and not data.has("automation_rules"), "target refers to actual colonist; unsupported orders and automations omitted")
	for minute in range(61):
		session.observe(minute * 60.0, 7, {"food": 100.0}, {8: SessionObservations.satisfaction(raw)})
	data = UiData.colonist(actor, session, false)
	check(data.need_trends.hunger.trend == "flat" and data.need_trends.hunger.trend_horizon == "last observed game hour", "stable trend requires actual one-hour samples")
	var alert := ContinuumAlert.new()
	alert.id = 3
	alert.code = "low_food"
	alert.severity = ContinuumSeverity.create(2)
	alert.message = "Raw [actual] message"
	alert.acknowledged = true
	alert.raised_game_seconds = 60.0
	var presented := UiData.alert(alert, 3660.0, false)
	check(presented.title == alert.message and presented.level == "critical" and presented.time_label == "1 gameh 00m ago", "alert severity, raw message and game age are actual")
	check(presented.can_acknowledge == false and not presented.has("ack_handle") and not presented.has("ack_time"), "permissions explicit; bool acknowledgement has no invented attribution")
	check(UiData.alert(alert, 0.0, true).time_label == "Age unavailable", "backward alert age is unavailable, not fabricated zero")
	var event := ContinuumEventLog.new()
	event.id = 4
	event.day = 2
	event.hour = 11
	event.minute = 7
	event.severity = ContinuumSeverity.create(1)
	event.message = "kestrel changed [something]"
	var history := UiData.event(event)
	check(history.message == event.message and history.day == 2 and history.time_label == "11:07" and history.level == "warn", "literal historical message/time/severity survives")
	check(not history.has("actor") and not history.has("source") and not history.has("repeat_key") and not history.has("routine"), "freeform messages cannot manufacture actor, automation or safe repeat identity")
	for message: String in failures:
		push_error(message)
	if failures.is_empty():
		print("UI_LIVE_ADAPTER_PASS")
	quit(0 if failures.is_empty() else 1)

func check(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)
