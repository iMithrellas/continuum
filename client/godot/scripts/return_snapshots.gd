## Minimal local last-session baselines. No credentials, roles or actor inference.
class_name ReturnSnapshots
extends RefCounted

const PATH := "user://return_snapshots.json"
const VERSION := 1
const MAX_BASELINES := 64
const RETAINED_EVENTS := 200

var _baselines: Dictionary = {}


## Identity is the authenticated public identity, never a token or token hash.
## Reject credential-bearing endpoints rather than deriving a key from secrets.
static func context_key(host: String, database: String, profile: String, identity: String) -> String:
	if host.is_empty() or database.is_empty() or profile.is_empty() or identity.is_empty():
		return ""
	if "@" in host or "?" in host or "#" in host:
		return ""
	return JSON.stringify([host.trim_suffix("/"), database, profile, identity]).sha256_text()


func load_file(path := PATH) -> Error:
	_baselines.clear()
	if not FileAccess.file_exists(path):
		return OK
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return FileAccess.get_open_error()
	var parsed: Variant = JSON.parse_string(file.get_as_text())
	if not parsed is Dictionary or parsed.get("version", -1) != VERSION or not parsed.get("baselines") is Dictionary:
		return ERR_FILE_CORRUPT
	for key: Variant in parsed.baselines:
		if key is String and key.length() == 64 and _valid_baseline(parsed.baselines[key]):
			_baselines[key] = _minimal(parsed.baselines[key])
	_trim()
	return OK


func save_file(path := PATH) -> Error:
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		return FileAccess.get_open_error()
	file.store_string(JSON.stringify({"version": VERSION, "baselines": _baselines}))
	return file.get_error()


## Snapshot is supplied only once authoritative state was observed. The optional
## server time must come from a server source; the current contract lacks one.
func remember(key: String, snapshot: Dictionary) -> bool:
	if key.is_empty() or not _valid_baseline(snapshot):
		return false
	_baselines[key] = _minimal(snapshot)
	_trim()
	return true


func forget(key: String) -> void:
	_baselines.erase(key)


## Capture digest BEFORE remembering the newly applied session baseline.
## Actual open alerts are passed through even without a previous baseline.
func digest(key: String, current: Dictionary, open_alerts: Array, events: Array) -> Dictionary:
	var result := {
		"baseline_available": false, "baseline_label": "Locally observed last-session baseline",
		"needs_you": open_alerts.duplicate(true), "resource_deltas": {},
		"events": [], "changed_by_others": [], "handled": [],
		"coverage_note": "Earlier events may be missing · up to 200 retained events",
		"unsupported_note": "Player attribution and handled summaries are unavailable from this server contract.",
		"state": "first_visit", "message": "No local baseline for this colony and identity.",
	}
	if key.is_empty():
		result.state = "unsupported"
		result.message = "A safe authenticated colony identity is unavailable."
		return result
	if not _valid_baseline(current):
		result.state = "unavailable"
		result.message = "Waiting for authoritative colony state."
		return result
	if not _baselines.has(key):
		return result
	var baseline: Dictionary = _baselines[key]
	if int(current.generation) != int(baseline.generation) or float(current.game_seconds) < float(baseline.game_seconds) or int(current.event_watermark) < int(baseline.event_watermark):
		forget(key)
		result.state = "reset"
		result.message = "Colony reset or clock moved backward · previous local baseline discarded."
		return result
	result.baseline_available = true
	result.state = "available"
	result.message = "Changes since your locally observed last session."
	result.away_game_seconds = float(current.game_seconds) - float(baseline.game_seconds)
	if current.has("server_time") and baseline.has("server_time") and float(current.server_time) >= float(baseline.server_time):
		result.away_server_seconds = float(current.server_time) - float(baseline.server_time)
	for resource: Variant in current.resources:
		if baseline.resources.has(resource):
			result.resource_deltas[resource] = float(current.resources[resource]) - float(baseline.resources[resource])
	for event: Variant in events:
		if event is Dictionary and event.get("id", -1) > baseline.event_watermark:
			result.events.append(event.duplicate(true))
	return result


static func _valid_baseline(value: Variant) -> bool:
	if not value is Dictionary:
		return false
	for field: String in ["generation", "game_seconds", "event_watermark"]:
		if not value.has(field) or not _number(value[field]) or float(value[field]) < 0.0:
			return false
	if not value.get("resources") is Dictionary:
		return false
	for resource: Variant in value.resources:
		if not resource is String or not _number(value.resources[resource]):
			return false
	return not value.has("server_time") or (_number(value.server_time) and float(value.server_time) >= 0.0)


static func _number(value: Variant) -> bool:
	return (value is float or value is int) and is_finite(float(value))


static func _minimal(value: Dictionary) -> Dictionary:
	var result := {"generation": int(value.generation), "game_seconds": float(value.game_seconds), "event_watermark": int(value.event_watermark), "resources": value.resources.duplicate()}
	if value.has("server_time"):
		result.server_time = float(value.server_time)
	return result


func _trim() -> void:
	while _baselines.size() > MAX_BASELINES:
		_baselines.erase(_baselines.keys()[0])
