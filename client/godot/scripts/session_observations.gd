## Presentation-only observations from one authoritative connection.
## Clock units are game seconds, never wall time or Config.time_scale.
class_name SessionObservations
extends RefCounted

const GAME_HOUR := 3600.0
const SAMPLE_INTERVAL := 60.0
const MAX_SAMPLES := 122
const STABLE_EPSILON := 0.5
const NEED_FIELDS := {"Fed": "hunger", "Rest": "fatigue", "Leisure": "recreation", "Mood": "mood", "Output": "productivity"}

var _samples: Array[Dictionary] = []
var _generation := -1
var _last_clock := -1.0
var _initial_stocks: Dictionary = {}
var _initial_clock := -1.0
var _missing_stocks: Dictionary = {}


func reset() -> void:
	_samples.clear()
	_generation = -1
	_last_clock = -1.0
	_initial_stocks.clear()
	_initial_clock = -1.0
	_missing_stocks.clear()


static func satisfaction(raw: Dictionary) -> Dictionary:
	var result := {}
	for label: String in NEED_FIELDS:
		var field: String = NEED_FIELDS[label]
		if not raw.has(field) or not _finite_number(raw[field]):
			continue
		var value := float(raw[field])
		if label in ["Fed", "Rest", "Leisure"]:
			value = 100.0 - value
		result[label] = clampf(value, 0.0, 100.0)
	return result


static func need_level(value: float) -> String:
	return "critical" if value < 15.0 else ("warn" if value < 35.0 else "notice")


## Needs and stocks must be actual replicated values, not smoothed estimates.
## Call only after the subscription has applied; reset on disconnect/session switch.
func observe(game_seconds: float, generation: int, stocks: Dictionary, needs: Dictionary) -> bool:
	if not is_finite(game_seconds) or game_seconds < 0.0:
		reset()
		return false
	if _generation != generation or (_last_clock >= 0.0 and game_seconds < _last_clock):
		reset()
	_generation = generation
	_last_clock = game_seconds
	if not _samples.is_empty() and game_seconds - float(_samples.back().seconds) < SAMPLE_INTERVAL:
		return false
	var actual_stocks := _numeric_values(stocks)
	if _initial_clock < 0.0:
		_initial_clock = game_seconds
		_initial_stocks = actual_stocks.duplicate()
	for name: Variant in _initial_stocks:
		if not actual_stocks.has(name):
			_missing_stocks[name] = true
	_samples.append({"seconds": game_seconds, "stocks": actual_stocks, "needs": needs.duplicate(true)})
	while _samples.size() > MAX_SAMPLES:
		_samples.pop_front()
	return true


func resource(name: String) -> Dictionary:
	var result := {"available": false, "rate_available": false, "rate_label": "rate since connection", "level": "notice", "warming_up": true}
	if _samples.is_empty() or not _samples.back().stocks.has(name):
		return result
	var current: Dictionary = _samples.back()
	result.available = true
	result.value = current.stocks[name]
	var anchor := _hour_anchor()
	if anchor.is_empty() or not _initial_stocks.has(name) or _missing_stocks.has(name):
		return result
	var elapsed := (float(current.seconds) - _initial_clock) / GAME_HOUR
	var rate := (float(current.stocks[name]) - float(_initial_stocks[name])) / elapsed
	result.rate_available = true
	result.warming_up = false
	result.rate = rate
	result.lookback_game_seconds = float(current.seconds) - _initial_clock
	if rate < 0.0:
		var horizon := maxf(0.0, float(result.value)) / -rate
		result.hours_left = horizon
		result.estimate_label = "estimate · %.1f gameh left" % horizon
		result.level = "critical" if horizon < 2.0 else ("warn" if horizon < 24.0 else "notice")
	return result


func need_trend(id: Variant, label: String) -> Dictionary:
	var unavailable := {"available": false}
	var anchor := _hour_anchor()
	if anchor.is_empty() or _samples.is_empty():
		return unavailable
	for sample: Dictionary in _samples:
		if float(sample.seconds) >= float(anchor.seconds):
			if not sample.needs.has(id) or not sample.needs[id].has(label) or not _finite_number(sample.needs[id][label]):
				return unavailable
	var difference := float(_samples.back().needs[id][label]) - float(anchor.needs[id][label])
	return {"available": true, "difference": difference, "direction": "up" if difference > STABLE_EPSILON else ("down" if difference < -STABLE_EPSILON else "stable"), "lookback_game_seconds": float(_samples.back().seconds) - float(anchor.seconds)}


func sample_count() -> int:
	return _samples.size()


func _hour_anchor() -> Dictionary:
	if _samples.size() < 2:
		return {}
	var target := float(_samples.back().seconds) - GAME_HOUR
	for index in range(_samples.size() - 2, -1, -1):
		var point: Dictionary = _samples[index]
		if float(point.seconds) <= target:
			if target - float(point.seconds) <= SAMPLE_INTERVAL:
				return point
			return {}
	return {}


static func _finite_number(value: Variant) -> bool:
	return (value is int or value is float) and is_finite(float(value))


static func _numeric_values(values: Dictionary) -> Dictionary:
	var result := {}
	for key: Variant in values:
		if _finite_number(values[key]):
			result[key] = float(values[key])
	return result
