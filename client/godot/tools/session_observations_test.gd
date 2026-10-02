extends SceneTree

const Session = preload("res://scripts/session_observations.gd")
const Returns = preload("res://scripts/return_snapshots.gd")
var failures: Array[String] = []


func _initialize() -> void:
	_test_needs()
	_test_sampling()
	_test_returns()
	if failures.is_empty():
		print("Session observations and return snapshots: PASS")
	else:
		for failure: String in failures:
			push_error(failure)
	quit(0 if failures.is_empty() else 1)


func check(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)


func _test_needs() -> void:
	var needs: Dictionary = Session.satisfaction({"hunger": 91, "fatigue": 72, "recreation": 5, "mood": 110, "productivity": -5})
	check(needs == {"Fed": 9.0, "Rest": 28.0, "Leisure": 95.0, "Mood": 100.0, "Output": 0.0}, "needs invert and clamp actual fields")
	check(Session.need_level(14.9) == "critical" and Session.need_level(15) == "warn" and Session.need_level(35) == "notice", "bands are strict and critical wins")
	check(not Session.satisfaction({"mood": NAN}).has("Mood"), "nonfinite needs are unavailable")


func _test_sampling() -> void:
	var session = Session.new()
	check(session.observe(0, 1, {"food": 20}, {1: {"Fed": 40.0}}), "initial actual observation accepted")
	check(not session.resource("food").rate_available and not session.need_trend(1, "Fed").available, "initial trend and rate unavailable, not flat")
	check(not session.observe(0, 1, {"food": 10}, {}), "paused clock adds no sample")
	for minute in range(1, 61):
		session.observe(minute * 60.0, 1, {"food": 20.0 - minute / 6.0}, {1: {"Fed": 40.0 + minute / 60.0}})
	var rate: Dictionary = session.resource("food")
	check(rate.rate_available and is_equal_approx(rate.rate, -10.0), "stocks measured per game hour independent of time scale")
	check(rate.level == "critical" and is_equal_approx(rate.hours_left, 1.0), "negative rate has horizon and critical highest wins")
	check(session.need_trend(1, "Fed").direction == "up", "trend uses actual one-hour difference")
	for minute in range(61, 601):
		session.observe(minute * 60.0, 1, {"food": 10.0}, {1: {"Fed": 41.0}})
	check(session.sample_count() <= Session.MAX_SAMPLES and session.resource("food").rate_available, "bounded history retains more than one game hour after long session")
	check(is_equal_approx(session.resource("food").rate, -1.0) and session.need_trend(1, "Fed").direction == "stable", "rate is genuinely since connection; stable requires actual history")
	session.observe(36001, 2, {"food": 10}, {})
	check(not session.resource("food").rate_available, "generation resets before throttle")
	session.observe(36000, 2, {"food": 10}, {})
	check(session.sample_count() == 1, "backward clock resets even inside throttle")
	session.reset()
	check(not session.resource("food").available, "disconnect clears observations")
	session.observe(0, 1, {"food": 20}, {1: {"Fed": 40}})
	session.observe(7200, 1, {"food": 10}, {1: {"Fed": 40}})
	check(not session.resource("food").rate_available and not session.need_trend(1, "Fed").available, "large replication gap cannot pretend to be last-hour history")
	session.reset()
	for minute in range(61):
		session.observe(minute * 60.0, 1, {"food": 10.0}, {1: {"Fed": 40.0 + minute / 120.0}})
	check(session.resource("food").rate == 0.0 and not session.resource("food").has("hours_left"), "zero rate has no invented eta")
	check(session.need_trend(1, "Fed").direction == "stable", "defined stable epsilon includes half a point")
	check(session.resource("missing").available == false, "missing stock remains unavailable")
	session.reset()
	for minute in range(60):
		session.observe(minute * 60.0, 1, {"food": 10.0}, {})
	check(not session.resource("food").rate_available, "less than one game hour remains warming up")
	session.observe(3600, 1, {}, {})
	session.observe(3660, 1, {"food": 5.0}, {})
	check(not session.resource("food").rate_available, "missing observations cannot be reused for a connection-wide rate")
	for hours: float in [1.99, 2.0, 23.99, 24.0]:
		session.reset()
		for minute in range(61):
			session.observe(minute * 60.0, 1, {"food": hours + 1.0 - minute / 60.0}, {})
		var expected := "critical" if hours < 2.0 else ("warn" if hours < 24.0 else "notice")
		check(session.resource("food").level == expected, "forecast severity boundary %.2f gameh" % hours)


func _test_returns() -> void:
	var returns = Returns.new()
	var key: String = Returns.context_key("http://localhost:3000", "colony", "normal", "public-id")
	check(not key.is_empty() and key != Returns.context_key("http://localhost:3000", "colony", "admin", "public-id"), "profile isolates baseline")
	check(key != Returns.context_key("http://localhost:3000", "other", "normal", "public-id") and key != Returns.context_key("http://localhost:3000", "colony", "normal", "other-id"), "database and authenticated identity isolate baseline")
	check(Returns.context_key("http://secret@localhost", "colony", "normal", "id").is_empty(), "credential-bearing context rejected")
	var initial := {"generation": 2, "game_seconds": 100.0, "resources": {"food": 10.0}, "event_watermark": 3, "token": "must-not-persist", "role": "admin"}
	check(not returns.digest(key, initial, [], []).baseline_available, "first visit invents no baseline")
	check(returns.remember(key, initial), "authoritative snapshot accepted")
	var current := {"generation": 2, "game_seconds": 3700.0, "resources": {"food": 6.0, "wood": 7.0}, "event_watermark": 6}
	var result: Dictionary = returns.digest(key, current, [{"message": "actual alert"}], [{"id": 4, "message": "raw player-like message"}])
	check(result.baseline_available and result.resource_deltas == {"food": -4.0} and result.away_game_seconds == 3600, "return uses known resources and game duration only")
	check(not result.has("away_server_seconds") and result.changed_by_others.is_empty() and result.handled.is_empty(), "no invented wall time, actors or automations")
	check(result.events.size() == 1 and result.needs_you.size() == 1 and "Earlier events may be missing" in result.coverage_note, "raw events, actual alerts and retention caveat survive")
	var path := "user://return_snapshots_test.json"
	check(returns.save_file(path) == OK, "baseline saves")
	var stored := FileAccess.get_file_as_string(path)
	check(not "must-not-persist" in stored and not "role" in stored and not "public-id" in stored, "disk baseline excludes tokens, roles and raw identity")
	var loaded = Returns.new()
	check(loaded.load_file(path) == OK and loaded.digest(key, current, [], []).baseline_available, "baseline reopens across sessions")
	current.generation = 3
	check(loaded.digest(key, current, [], []).state == "reset" and not loaded.digest(key, initial, [], []).baseline_available, "reset invalidates rather than reuses baseline")
	loaded.remember(key, initial)
	current.generation = 2
	current.game_seconds = 99
	check(loaded.digest(key, current, [], []).state == "reset", "backward return clock invalidates baseline")
	loaded.remember(key, initial)
	current.game_seconds = 3700
	current.event_watermark = 2
	check(loaded.digest(key, current, [], []).state == "reset", "backward event watermark invalidates baseline")
	check(loaded.digest("", initial, [], []).state == "unsupported", "unsafe identity gives honest unsupported shell")
	check(not loaded.remember(key, {"generation": 1}) and not loaded.remember(key, {"generation": 1, "game_seconds": NAN, "resources": {}, "event_watermark": 0}), "incomplete or nonfinite snapshots cannot become baselines")
	DirAccess.remove_absolute(ProjectSettings.globalize_path(path))
