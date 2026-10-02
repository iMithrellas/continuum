extends SceneTree

const Models = preload("../client/godot/ui/components/models.gd")
var checks: int = 0
var failures: int = 0

func expect(condition: bool, message: String) -> void:
	checks += 1
	if not condition:
		failures += 1
		push_error(message)

func _initialize() -> void:
	var limits = {"warn": 35.0, "critical": 15.0}
	expect(Models.band(35, limits) == "nominal", "warn boundary is strict")
	expect(Models.band(15, limits) == "warn", "critical boundary is strict")
	expect(Models.band(14.99, limits) == "critical", "critical wins")
	expect(Models.need({"value": -2}).value == 0, "need lower clamp")
	expect(Models.need({"value": 102}).value == 100, "need upper clamp")
	expect(Models.need({"value": "4"}).value == null, "reject numeric string")
	expect(Models.need({"value": NAN}).value == null, "reject nonfinite")
	expect(Models.need({"trend": "flat"}).trend == "", "no trend without horizon")
	expect(Models.need({"trend": "flat", "trend_horizon": "1 game h"}).trend == "flat", "explicit flat with horizon allowed")
	expect(Models.need({"value": 20}, {"warn": 10, "critical": 30}).level == "warn", "invalid thresholds fall back")
	var crew = Models.colonist({"hunger": 91, "fatigue": 72, "recreation": 55, "mood": 54, "productivity": 78})
	expect(crew.needs.map(func(n): return n.value) == [9.0, 28.0, 45.0, 54.0, 78.0], "satisfaction adapter")
	expect(crew.worst.label == "Fed", "highest severity wins")
	expect(not crew.has("alerts"), "local bands never become alerts")
	expect(Models.colonist({}).needs[0].value == null, "missing needs not nominal fiction")
	var tied = [Models.need({"label": "A", "value": 20}), Models.need({"label": "B", "value": 20})]
	expect(Models.worst_need(tied).label == "A", "stable worst tie")
	tied.append(Models.need({"label": "C", "value": 19}))
	expect(Models.worst_need(tied).label == "C", "distance below threshold wins")
	expect(Models.resource({"value": 10, "rate_per_game_hour": -5}).level == "nominal", "no auto forecast")
	expect(Models.resource({"rate_per_game_hour": -1, "eta_game_hours": 24}).level == "nominal", "eta warn strict")
	expect(Models.resource({"rate_per_game_hour": -1, "eta_game_hours": 2}).level == "warn", "eta critical strict")
	expect(Models.resource({"rate_per_game_hour": -1, "eta_game_hours": 1.99}).level == "critical", "eta critical wins")
	expect(Models.resource({"rate_per_game_hour": 1, "eta_game_hours": 1}).level == "nominal", "positive rate cannot deplete")
	expect(Models.resource({"rate_per_game_hour": -1, "eta_game_hours": 3}, {"warn": 6, "critical": 4}).level == "critical", "configurable eta")
	expect(Models.resource({"availability": "warming"}).rate_copy == "Rate warming up", "honest warmup")
	expect(Models.resource({"rate_per_game_hour": -1, "eta_game_hours": 8}).rate_copy.contains("estimate 8.0 game h left"), "estimate and horizon labelled")
	var raw = Models.alert({"message": "someone acknowledged this", "acknowledged": true})
	expect(raw.ack_handle == "" and raw.ack_time == "", "raw ack cannot invent actor/time")
	expect(raw.title == "someone acknowledged this", "raw message retained")
	var sorted = Models.ordered_alerts([{ "id": "w", "level": "warn", "message": "Warning", "consequence_game_hours": 1}, {"id": "c2", "level": "critical", "message": "Critical"}, {"id": "c1", "level": "critical", "message": "Critical", "consequence_game_hours": 4}])
	expect(sorted.map(func(a): return a.id) == ["c1", "c2", "w"], "severity then known consequence")
	expect(Models.ordered_alerts([{"id": "b", "level": "notice", "message": "Notice", "time": 2}, {"id": "a", "level": "notice", "message": "Notice", "time": 2}])[0].id == "a", "stable id tie")
	var event = {"day": 1, "time_label": "14:00", "actor": "Ada", "verb": "hauled", "subject": "wood", "source": "colonist", "repeat_key": "haul", "routine": true}
	var feed = Models.activity([event, event, {"message": "Raw backend message"}])
	expect(feed.hidden_count == 2, "actual hidden raw row count")
	feed = Models.activity([event, event, {"message": "Raw backend message"}], true)
	expect(feed.groups[0].entries[0].count == 2, "safe exact repeat merges")
	expect(feed.groups[1].day == null, "no guessed in-game day")
	expect(Models.activity([{"message": "same"}, {"message": "same"}], true).groups[0].entries.size() == 2, "raw repeats not merged")
	var different = event.duplicate()
	different.subject = "stone"
	expect(Models.activity([event, different], true).groups[0].entries.size() == 2, "different subject not merged")
	different = event.duplicate()
	different.level = "critical"
	expect(Models.activity([event, different]).hidden_count == 1, "historical critical never hidden as routine")
	var digest = Models.digest({"deltas": [{"name": "Wood", "current": 8}, {"name": "Food", "baseline": 2, "current": 8}]})
	expect(digest.deltas.size() == 1 and digest.deltas[0].delta == 6, "digest requires provided baseline")
	expect(digest.coverage == "Digest coverage unavailable", "honest digest coverage")
	expect(digest.needs_you.is_empty(), "explicit empty needs-you model")
	expect(Models.event({"message": "mithrel designated 8 tiles"}).actor == "", "freeform actor not parsed")
	expect(Models.alert({}).acknowledged == null, "missing ack is unavailable")
	expect(Models.digest({"needs_you": [{"level": "notice"}, {"level": "critical", "resolved": true}]}).needs_you.is_empty(), "digest only provided open deviations")
	var day_grouped = Models.activity([{"day": 1, "message": "A"}, {"day": 2, "message": "B"}, {"day": 1, "message": "C"}])
	expect(day_grouped.groups.size() == 2 and day_grouped.groups[0].entries.size() == 2, "group by explicit day")
	expect(not event.has("count"), "models do not mutate input")
	var trend_crew = Models.colonist({"fatigue": 72, "need_trends": {"fatigue": {"trend": "falling", "trend_horizon": "1 game h"}}})
	expect(trend_crew.needs[1].trend == "falling", "provided satisfaction trend retained")
	expect(not Models.digest({}).needs_you_available, "missing digest group is unavailable, not empty")
	expect(Models.digest({"needs_you": []}).needs_you_available, "explicit empty digest group is known")
	expect(Models.ordered_alerts([{"id": 10, "level": "notice", "message": "Notice"}, {"id": 2, "level": "notice", "message": "Notice"}])[0].id == 2, "numeric id stable tie order")
	var valid_problem = {"id": 1, "level": "critical", "message": "Actual provided problem"}
	for input in [null, "invalid", [null, {"level": "banana"}], [null, "invalid"]]:
		var collection = Models.alert_collection(input)
		expect(collection.status == "unavailable" and collection.rows.is_empty(), "invalid/missing alert collection is unavailable")
		var invalid_digest = Models.digest({"needs_you": input})
		expect(not invalid_digest.needs_you_available and invalid_digest.needs_you.is_empty(), "invalid/missing needs-you is not known empty")
	var partial = Models.alert_collection([valid_problem, null])
	expect(partial.status == "partial" and partial.rows.size() == 1 and partial.rejected_count == 1, "mixed alerts preserve valid data and partial coverage")
	expect(Models.alert_collection([]).status == "complete", "truly empty alerts are complete")
	expect(Models.alert_collection([], {"status": "partial"}).status == "partial", "caller can downgrade query coverage")
	expect(Models.alert_collection([null], {"status": "complete"}).status == "unavailable", "metadata cannot make rejected input reassuring")
	expect(Models.ordered_alerts([null, {"level": "banana"}, valid_problem]).size() == 1, "ordered alerts never invent records from invalid dictionary")
	var mixed_digest = Models.digest({"needs_you": [valid_problem, null], "changed_by_others": [null], "handled": ["invalid"], "deltas": [{"name": "Food", "baseline": 2, "current": 3}, null]})
	expect(mixed_digest.group_coverage.needs_you.status == "partial" and mixed_digest.needs_you.size() == 1, "mixed digest exposes partial needs-you")
	expect(mixed_digest.changed_by_others.is_empty() and mixed_digest.handled.is_empty(), "invalid event groups do not create fake event records")
	expect(mixed_digest.group_coverage.deltas.status == "partial" and mixed_digest.deltas.size() == 1, "mixed baselines retain valid delta with partial coverage")
	expect(not Models.digest({"needs_you": [], "group_coverage": {"needs_you": null}}).needs_you_available, "malformed explicit coverage is not complete")
	for id in [null, "", "  ", false, -1, 0.0, {}, []]:
		expect(not Models.valid_identifier(id), "malformed identifier is unavailable")
	for id in [0, 1, "alert-zero"]:
		expect(Models.valid_identifier(id), "legitimate identifier including zero is available")
	for target in [null, "", {}, [], {"x": 0}, {"x": null, "y": 0}, {"x": 0, "y": false}, {"x": INF, "y": 0}, {"x": 0, "y": 0, "z": null}]:
		expect(not Models.valid_target(target), "malformed target is unavailable")
	for target in [{"x": 0, "y": 0}, {"x": -1, "y": 0, "z": 0}, {"colonist_id": 0}]:
		expect(Models.valid_target(target), "legitimate origin/negative/entity target available")
	expect(not Models.valid_command(" ") and Models.valid_command("rest"), "commands require nonblank string identifiers")
	for invalid_id in [false, null, "", " ", [], {}, 0.0, 0.5, -1]:
		for valid_id in [0, "0", "actual-id"]:
			expect(not Models.same_identifier(invalid_id, valid_id), "invalid left identifier never matches valid identifier")
			expect(not Models.same_identifier(valid_id, invalid_id), "invalid right identifier never matches valid identifier")
	expect(Models.same_identifier(0, 0), "integer zero matches itself")
	expect(Models.same_identifier("0", "0"), "string zero matches itself")
	expect(not Models.same_identifier(0, "0") and not Models.same_identifier("0", 0), "string and integer zero identities stay distinct")
	expect(not Models.same_identifier(false, false) and not Models.same_identifier(null, null), "invalid identifiers never establish identity")
	print("UI models: %d checks, %d failures" % [checks, failures])
	quit(1 if failures else 0)
