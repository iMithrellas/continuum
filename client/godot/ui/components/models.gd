extends RefCounted
## Pure presentation adapters. Optional measurements are null, never guessed.
## Inputs are dictionaries; returned models are owned copies. No reducer calls.

const NEEDS = [["Fed", "hunger", true], ["Rest", "fatigue", true], ["Leisure", "recreation", true], ["Mood", "mood", false], ["Output", "productivity", false]]
const LEVELS = {"nominal": 0, "notice": 0, "warn": 1, "critical": 2}

static func numeric(value: Variant) -> bool:
	return (value is int or value is float) and is_finite(float(value))

## Entity identifiers are nonnegative integers (including zero) or nonblank
## strings. Booleans, floats, null and containers are not identifiers.
static func valid_identifier(value: Variant) -> bool:
	return (value is int and value >= 0) or (value is String and not value.strip_edges().is_empty())

## GDScript equality can error on heterogeneous Variants. Identity matching must
## reject invalid values and mismatched types before evaluating equality.
static func same_identifier(left: Variant, right: Variant) -> bool:
	return valid_identifier(left) and valid_identifier(right) and typeof(left) == typeof(right) and left == right

## Optional navigation target: {x: finite number, y: finite number, z?: finite
## number}, or {colonist_id: valid identifier}. Negative/zero coordinates work.
static func valid_target(value: Variant) -> bool:
	if not value is Dictionary:
		return false
	if value.has("x") or value.has("y") or value.has("z"):
		return numeric(value.get("x")) and numeric(value.get("y")) and (not value.has("z") or numeric(value.z))
	return valid_identifier(value.get("colonist_id"))

static func valid_command(value: Variant) -> bool:
	return value is String and not value.strip_edges().is_empty()

static func text(data: Dictionary, key: String, fallback: String = "") -> String:
	return data[key] if data.get(key) is String else fallback

static func measurement(data: Dictionary, key: String) -> Variant:
	return float(data[key]) if numeric(data.get(key)) else null

static func level(value: Variant) -> String:
	return value if value is String and LEVELS.has(value) else "notice"

static func thresholds(config: Dictionary, warn_default: float, critical_default: float) -> Dictionary:
	var warn = measurement(config, "warn")
	var critical = measurement(config, "critical")
	if warn == null or critical == null or critical < 0 or warn < critical:
		return {"warn": warn_default, "critical": critical_default}
	return {"warn": warn, "critical": critical}

static func band(value: Variant, limits: Dictionary) -> String:
	if not numeric(value):
		return "nominal"
	if value < limits.critical:
		return "critical"
	if value < limits.warn:
		return "warn"
	return "nominal"

static func need(data: Dictionary, config: Dictionary = {}) -> Dictionary:
	var limits = thresholds(config, 35, 15)
	limits.warn = minf(limits.warn, 100)
	limits.critical = minf(limits.critical, 100)
	var value = measurement(data, "value")
	if value != null:
		value = clampf(value, 0, 100)
	var trend = text(data, "trend")
	var horizon = text(data, "trend_horizon")
	if trend not in ["rising", "flat", "falling"] or horizon.is_empty():
		trend = ""
	var severity = band(value, limits)
	var distance = 0.0
	if severity in ["warn", "critical"]:
		distance = limits[severity] - value
	return {"label": text(data, "label", "Need"), "value": value, "level": severity, "thresholds": limits, "deviation": distance, "trend": trend, "trend_horizon": horizon, "availability": text(data, "availability", "unavailable")}

static func colonist(data: Dictionary, config: Dictionary = {}) -> Dictionary:
	var out = data.duplicate(true)
	var needs: Array = []
	for descriptor in NEEDS:
		var value = measurement(data, descriptor[1])
		if value != null and descriptor[2]:
			value = 100 - value
		var need_data = {"label": descriptor[0], "value": value}
		if data.get("need_trends") is Dictionary and data.need_trends.get(descriptor[1]) is Dictionary:
			var trend_data: Dictionary = data.need_trends[descriptor[1]]
			need_data["trend"] = text(trend_data, "trend")
			need_data["trend_horizon"] = text(trend_data, "trend_horizon")
		needs.append(need(need_data, config))
	out["needs"] = needs
	out["worst"] = worst_need(needs)
	out["name"] = text(data, "name", "Name unavailable")
	out["state"] = text(data, "state", "State unavailable")
	out["state_level"] = level(data.get("state_level", "notice"))
	out["job"] = text(data, "job", "Job unavailable")
	out["cargo"] = text(data, "cargo", "Cargo unavailable")
	out["selected"] = data.get("selected") == true
	out["id_available"] = valid_identifier(data.get("id"))
	out["target_available"] = valid_target(data.get("target"))
	return out

static func worst_need(needs: Array) -> Dictionary:
	var worst: Dictionary = {}
	for item in needs:
		if not item is Dictionary or item.get("level") not in ["warn", "critical"]:
			continue
		if worst.is_empty() or LEVELS[item.level] > LEVELS[worst.level] or (item.level == worst.level and item.deviation > worst.deviation):
			worst = item
	return worst.duplicate(true)

static func signed(value: Variant) -> String:
	if not numeric(value):
		return "Unavailable"
	return ("+" if value > 0 else "−" if value < 0 else "") + str(abs(value))

static func resource(data: Dictionary, config: Dictionary = {}) -> Dictionary:
	var rate = measurement(data, "rate_per_game_hour")
	var eta = measurement(data, "eta_game_hours")
	if eta != null and eta < 0:
		eta = null
	var severity = "nominal"
	var copy = "Rate warming up" if text(data, "availability") == "warming" else "Rate unavailable"
	if rate != null:
		copy = signed(rate) + "/game h"
		if rate < 0:
			if eta != null:
				severity = band(eta, thresholds(config, 24, 2))
				copy += " · estimate " + str(eta) + " game h left"
			else:
				copy += " · horizon unavailable"
	return {"name": text(data, "name", "Resource"), "value": measurement(data, "value"), "level": severity, "rate_copy": copy}

static func alert(data: Dictionary) -> Dictionary:
	var out = data.duplicate(true)
	out["level"] = level(data.get("level"))
	out["title"] = text(data, "title", text(data, "message", "Alert details unavailable"))
	out["detail"] = text(data, "detail")
	out["time_label"] = text(data, "time_label", "Time unavailable")
	out["acknowledged"] = data.get("acknowledged") if data.get("acknowledged") is bool else null
	out["ack_handle"] = text(data, "ack_handle")
	out["ack_time"] = text(data, "ack_time")
	out["consequence_game_hours"] = measurement(data, "consequence_game_hours")
	if out.consequence_game_hours != null and out.consequence_game_hours < 0:
		out.consequence_game_hours = null
	out["time"] = measurement(data, "time")
	out["id_available"] = valid_identifier(data.get("id"))
	out["target_available"] = valid_target(data.get("target"))
	return out

static func ordered_alerts(rows: Array) -> Array:
	var result: Array = []
	for row in rows:
		if valid_alert(row):
			var item = alert(row)
			item["_index"] = result.size()
			result.append(item)
	result.sort_custom(func(a, b):
		if LEVELS[a.level] != LEVELS[b.level]:
			return LEVELS[a.level] > LEVELS[b.level]
		for key in ["consequence_game_hours", "time"]:
			if a[key] != b[key]:
				return a[key] != null and (b[key] == null or a[key] < b[key])
		var a_id: Variant = a.get("id", "")
		var b_id: Variant = b.get("id", "")
		if numeric(a_id) and numeric(b_id) and a_id != b_id:
			return a_id < b_id
		if str(a_id) != str(b_id):
			return str(a_id) < str(b_id)
		return a._index < b._index)
	return result

static func valid_alert(row: Variant) -> bool:
	return row is Dictionary and row.get("level") in ["notice", "warn", "critical"] and (not text(row, "title").strip_edges().is_empty() or not text(row, "message").strip_edges().is_empty())

static func valid_event(row: Variant) -> bool:
	if not row is Dictionary or (row.has("level") and row.level not in ["nominal", "notice", "warn", "critical"]):
		return false
	return not text(row, "message").strip_edges().is_empty() or (not text(row, "actor").strip_edges().is_empty() and not text(row, "verb").strip_edges().is_empty() and not text(row, "subject").strip_edges().is_empty())

static func valid_delta(row: Variant) -> bool:
	return row is Dictionary and not text(row, "name").strip_edges().is_empty() and numeric(row.get("baseline")) and numeric(row.get("current")) and (not row.has("level") or row.level in ["nominal", "notice", "warn", "critical"])

## Complete empty arrays are known empty; rejected/missing input is never empty
## reassurance. Optional coverage.status may only downgrade completeness.
static func checked_collection(rows: Variant, validator: Callable, coverage: Dictionary = {}) -> Dictionary:
	var accepted: Array = []
	var rejected = 0
	if rows is Array:
		for row in rows:
			if validator.call(row):
				accepted.append(row.duplicate(true))
			else:
				rejected += 1
	var status = "complete" if rows is Array else "unavailable"
	if rejected > 0:
		status = "unavailable" if accepted.is_empty() else "partial"
	if coverage.has("status"):
		if coverage.status == "unavailable" or coverage.status not in ["complete", "partial", "unavailable"]:
			status = "unavailable"
		elif coverage.status == "partial" and status == "complete":
			status = "partial"
	return {"rows": accepted, "status": status, "rejected_count": rejected, "copy": text(coverage, "copy")}

static func alert_collection(rows: Variant = null, coverage: Dictionary = {}) -> Dictionary:
	var result = checked_collection(rows, valid_alert, coverage)
	result.rows = ordered_alerts(result.rows)
	return result

static func event(data: Dictionary) -> Dictionary:
	var out = alert(data)
	out["source"] = text(data, "source")
	out["actor"] = text(data, "actor")
	out["verb"] = text(data, "verb")
	out["subject"] = text(data, "subject")
	out["day"] = data.get("day") if data.get("day") is int and data.day >= 0 else null
	out["message"] = text(data, "message")
	if out.message.is_empty():
		out.message = " ".join([out.actor, out.verb, out.subject]).strip_edges()
	if out.message.is_empty():
		out.message = "Event details unavailable"
	out["routine"] = data.get("routine") == true and out.level not in ["warn", "critical"]
	out["count"] = 1
	return out

static func repeat_key(item: Dictionary) -> Array:
	# Only an explicit safe identity and complete structured fields permit merging.
	if item.day == null or text(item, "repeat_key").is_empty() or item.actor.is_empty() or item.verb.is_empty() or item.subject.is_empty() or item.source not in ["colonist", "player", "automation"]:
		return []
	return [item.day, item.repeat_key, item.actor, item.verb, item.subject, item.source, item.level, item.message, item.routine]

static func activity(rows: Array, show_routine: bool = false) -> Dictionary:
	var groups: Array = []
	var hidden = 0
	var day_indices: Dictionary = {}
	for row in rows:
		if not row is Dictionary:
			continue
		var item = event(row)
		if item.routine and not show_routine:
			hidden += 1
			continue
		var day_key = str(item.day)
		if not day_indices.has(day_key):
			day_indices[day_key] = groups.size()
			groups.append({"day": item.day, "entries": []})
		var entries: Array = groups[day_indices[day_key]].entries
		var key = repeat_key(item)
		if not entries.is_empty() and not key.is_empty() and repeat_key(entries[-1]) == key:
			entries[-1].count += 1
			entries[-1]["last_time_label"] = item.time_label
		else:
			entries.append(item)
	return {"groups": groups, "hidden_count": hidden}

static func digest(data: Dictionary) -> Dictionary:
	var out = {"span": text(data, "span", "Time away unavailable"), "coverage": text(data, "coverage", "Digest coverage unavailable"), "deltas": [], "needs_you": [], "needs_you_available": false, "changed_by_others": [], "handled": [], "group_coverage": {}}
	var supplied_coverage: Dictionary = data.group_coverage if data.get("group_coverage") is Dictionary else {}
	var invalid_coverage = data.has("group_coverage") and not data.group_coverage is Dictionary
	for key in ["needs_you", "changed_by_others", "handled"]:
		var metadata: Dictionary = supplied_coverage[key] if supplied_coverage.get(key) is Dictionary else {}
		if invalid_coverage or (supplied_coverage.has(key) and not supplied_coverage[key] is Dictionary):
			metadata = {"status": "unavailable"}
		var collection = alert_collection(data.get(key), metadata) if key == "needs_you" else checked_collection(data.get(key), valid_event, metadata)
		out.group_coverage[key] = collection
		out[key] = collection.rows
	out.needs_you = out.needs_you.filter(func(row): return row.get("level") in ["warn", "critical"] and row.get("resolved") != true)
	out.needs_you_available = out.group_coverage.needs_you.status == "complete"
	var delta_metadata: Dictionary = supplied_coverage.deltas if supplied_coverage.get("deltas") is Dictionary else {}
	if invalid_coverage or (supplied_coverage.has("deltas") and not supplied_coverage.deltas is Dictionary):
		delta_metadata = {"status": "unavailable"}
	var deltas = checked_collection(data.get("deltas"), valid_delta, delta_metadata)
	out.group_coverage["deltas"] = deltas
	for row in deltas.rows:
		out.deltas.append({"name": row.name, "delta": row.current - row.baseline, "level": level(row.get("level", "nominal"))})
	return out
