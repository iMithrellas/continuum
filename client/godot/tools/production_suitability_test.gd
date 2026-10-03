## Parity checks for client ecological potential labels.
extends SceneTree

const Suitability = preload("res://scripts/production_suitability.gd")
const WorkType = preload("res://spacetime_bindings/schema/types/continuum_work_type.gd")


func _initialize() -> void:
	var work := WorkType.Options
	_check_close(Suitability.multiplier(work.farming, {"soil_fertility": 0.8, "moisture": 0.5}), 0.9,
		"farming uses 0.5 + fertility × moisture")
	_check_close(Suitability.multiplier(work.logging, {"forest_density": 0.25}), 0.75,
		"logging uses 0.5 + forest density")
	_check_close(Suitability.multiplier(work.hunting, {"forest_density": 0.25}), 0.75,
		"hunting uses 0.5 + forest density")
	_check_close(Suitability.multiplier(work.mining, {"forest_density": 1.0}), 1.0,
		"mining is ecologically unaffected")
	_check_close(Suitability.multiplier(work.none, {"soil_fertility": 1.0, "moisture": 1.0}), 1.0,
		"nonproductive work is unaffected")
	_check_close(Suitability.multiplier(work.farming, {}), 1.0,
		"missing entire terrain retains neutral backend fallback")
	_check_close(Suitability.multiplier(work.farming, {"soil_fertility": 1.0, "moisture": 1.0}), 1.5,
		"farming maximum is 1.5")
	_check_close(Suitability.multiplier(work.farming, {"soil_fertility": 0.0, "moisture": 0.0}), 0.5,
		"farming minimum is 0.5")
	_check_close(Suitability.multiplier(work.logging, {"forest_density": 0.0}), 0.5,
		"forest-work minimum is 0.5")
	_check_close(Suitability.multiplier(work.hunting, {"forest_density": 1.0}), 1.5,
		"forest-work maximum is 1.5")
	_check_close(Suitability.multiplier(work.farming, {"soil_fertility": -2.0, "moisture": 3.0}), 0.5,
		"finite fields clamp into [0, 1]")
	_check_close(Suitability.multiplier(work.farming, {"soil_fertility": NAN, "moisture": INF}), 0.5,
		"nonfinite fields normalize to zero")
	_check_close(Suitability.multiplier(work.logging, {"forest_density": -INF}), 0.5,
		"negative infinity normalizes to zero")
	_check(Suitability.work_line(work.farming, {}).contains("terrain data unavailable"),
		"missing terrain is described as unknown, not measured neutral suitability")
	_check(not Suitability.work_line(work.farming, {}).contains("backend"),
		"unknown terrain line avoids backend implementation details")
	var line := Suitability.work_line(work.farming, {"soil_fertility": 0.8, "moisture": 0.5})
	_check(line.contains("potential") and line.contains("Farming") and
		line.contains("90% of baseline"),
		"work line labels potential and includes work name and percentage")
	_check(line.length() <= 60, "work line stays compact")
	var missing_line := Suitability.work_line(work.farming, {})
	_check(missing_line.contains("Farming") and missing_line.contains("unavailable"),
		"unknown work line identifies work and missing terrain")
	_check(missing_line.length() <= 70, "unknown work line stays compact")
	var mining_line := Suitability.work_line(work.mining, {})
	_check(mining_line.contains("Mining") and mining_line.contains("100% of baseline"),
		"unaffected mining remains identifiable with baseline percent")
	var copy := Suitability.description(work.farming, {})
	_check(copy.contains("Terrain potential") and
		copy.contains("actual output") and copy.contains("current worker productivity") and
		copy.contains("orders") and copy.contains("hauled"),
		"description distinguishes terrain potential from output and delivery")
	_check(copy.length() <= 130, "description stays within the short-copy budget")
	if _failures == 0:
		print("PRODUCTION_SUITABILITY_PASS")
		quit(0)
	else:
		quit(1)


var _failures := 0


func _check(condition: bool, message: String) -> void:
	if not condition:
		_failures += 1
		printerr("FAIL: %s" % message)


func _check_close(actual: float, expected: float, message: String) -> void:
	_check(is_finite(actual) and is_equal_approx(actual, expected),
		"%s (expected %.4f, got %.4f)" % [message, expected, actual])
