## Client-local browser history. It deliberately has no credential or world-data access.
class_name ContinuumConnectionHistory
extends RefCounted

const Endpoint = preload("res://scripts/server_endpoint.gd")
const DEFAULT_WORLD := "default-world"
const MAX_ENTRIES := 100
const HISTORY_PATH := "user://continuum_connection_history.json"
const FAVORITES_PATH := "user://continuum_connection_favorites.json"

var history_path := HISTORY_PATH
var favorites_path := FAVORITES_PATH
var legacy_import_marker_path := ""
var _entries: Dictionary = {}
var _favorites: Dictionary = {}

func load_from(history_file := "", favorites_file := "") -> Error:
	if not history_file.is_empty(): history_path = history_file
	if not favorites_file.is_empty(): favorites_path = favorites_file
	_entries = _read_map(history_path)
	_favorites = _read_favorites(favorites_path)
	var before_trim := _entries.size()
	_trim_map(_entries)
	if _entries.size() != before_trim: return _write_map(history_path, _entries)
	return OK

func import_legacy_entry_once(endpoint: String, database: String, world_slug := DEFAULT_WORLD,
		display_name := "", now := -1) -> Error:
	if legacy_import_marker_path.is_empty() or FileAccess.file_exists(legacy_import_marker_path):
		return OK
	var error := import_legacy_entry(endpoint, database, world_slug, display_name, now)
	if error != OK:
		return error
	var marker := FileAccess.open(legacy_import_marker_path, FileAccess.WRITE)
	if marker == null:
		return ERR_CANT_OPEN
	marker.store_string("legacy-last-server-imported")
	marker.close()
	return OK

## This is the only method that creates history records: callers must report a successful subscription.
func record_successful_subscription(endpoint: String, database: String, world_slug := DEFAULT_WORLD,
		display_name := "", now := -1) -> Error:
	var target := _target(endpoint, database, world_slug)
	if target.is_empty():
		return ERR_INVALID_PARAMETER
	var key: String = target.key
	var entry: Dictionary = _entries.get(key, {})
	entry.merge(target)
	entry["last_seen"] = now if now >= 0 else int(Time.get_unix_time_from_system())
	entry["status"] = "online"
	if not display_name.is_empty():
		entry["display_name"] = display_name.strip_edges()
	var candidate := _entries.duplicate(true)
	candidate[key] = entry
	_trim_map(candidate)
	var error := _write_map(history_path, candidate)
	if error == OK: _entries = candidate
	return error

func import_legacy_entry(endpoint: String, database: String, world_slug: String,
		display_name := "", now := -1) -> Error:
	# Adoption is explicit: callers must name the world instead of guessing from a catalog.
	if world_slug.strip_edges().is_empty():
		return ERR_INVALID_PARAMETER
	return record_successful_subscription(endpoint, database, world_slug, display_name, now)

func entries(search := "") -> Array[Dictionary]:
	var needle := search.strip_edges().to_lower()
	var result: Array[Dictionary] = []
	for key in _entries:
		var entry: Dictionary = _entries[key].duplicate(true)
		entry["favorite"] = _favorites.has(key)
		if needle.is_empty() or _matches(entry, needle):
			result.append(entry)
	result.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
			if a.favorite != b.favorite: return a.favorite
			return int(a.last_seen) > int(b.last_seen))
	return result

func set_favorite(key: String, favorite: bool) -> Error:
	if not _entries.has(key): return ERR_DOES_NOT_EXIST
	var candidate := _favorites.duplicate(true)
	if favorite: candidate[key] = true
	else: candidate.erase(key)
	var error := _write_map(favorites_path, candidate)
	if error == OK: _favorites = candidate
	return error

func remove_history(key: String) -> Error:
	if not _entries.has(key): return ERR_DOES_NOT_EXIST
	var candidate := _entries.duplicate(true); candidate.erase(key)
	var error := _write_map(history_path, candidate)
	if error == OK: _entries = candidate
	return error

func remove_favorite(key: String) -> Error:
	if not _favorites.has(key): return ERR_DOES_NOT_EXIST
	var candidate := _favorites.duplicate(true); candidate.erase(key)
	var error := _write_map(favorites_path, candidate)
	if error == OK: _favorites = candidate
	return error

func clear_history() -> Error:
	var error := _write_map(history_path, {})
	if error == OK: _entries.clear()
	return error

static func canonical_key(endpoint: String, database: String, world_slug := DEFAULT_WORLD) -> String:
	var target := _target(endpoint, database, world_slug)
	return target.get("key", "")

static func _target(endpoint: String, database: String, world_slug: String) -> Dictionary:
	var parsed := Endpoint.parse(endpoint)
	var db := database.strip_edges()
	var world := world_slug.strip_edges().to_lower()
	if parsed.is_empty() or not Endpoint.valid_database(db) or not _valid_slug(world): return {}
	return {"key": parsed.canonical + "/" + db.to_lower() + "/" + world, "endpoint": parsed.endpoint,
		"database": db, "database_canonical": db.to_lower(), "world": world,
		"status": "unknown", "last_seen": 0, "last_sample": 0}

static func _valid_slug(value: String) -> bool:
	if value.length() == 0 or value.length() > 64 or value != value.to_lower() or value.strip_edges() != value: return false
	if not ((value[0] >= "a" and value[0] <= "z") or (value[0] >= "0" and value[0] <= "9")): return false
	if not ((value[-1] >= "a" and value[-1] <= "z") or (value[-1] >= "0" and value[-1] <= "9")): return false
	var previous_dash := false
	for character in value:
		var alphanumeric := (character >= "a" and character <= "z") or (character >= "0" and character <= "9")
		if not alphanumeric and character != "-": return false
		if character == "-" and previous_dash: return false
		previous_dash = character == "-"
	return true

func _matches(entry: Dictionary, needle: String) -> bool:
	for field in ["display_name", "endpoint", "database", "world"]:
		if str(entry.get(field, "")).to_lower().contains(needle): return true
	return false

func _trim_map(entries: Dictionary) -> void:
	while entries.size() > MAX_ENTRIES:
		var oldest := ""
		var oldest_time := 9223372036854775807
		for key in entries:
			if int(entries[key].get("last_seen", 0)) < oldest_time:
				oldest = key; oldest_time = int(entries[key].get("last_seen", 0))
		entries.erase(oldest)

func _read_map(path: String) -> Dictionary:
	if not FileAccess.file_exists(path): return {}
	var parsed = JSON.parse_string(FileAccess.get_file_as_string(path))
	if not parsed is Dictionary: return {}
	var valid := {}
	for key in parsed:
		if key is String and parsed[key] is Dictionary and parsed[key].has("key") and parsed[key]["key"] == key:
			var entry: Dictionary = parsed[key]
			var valid_types := entry.get("endpoint", null) is String and entry.get("database", null) is String and entry.get("world", null) is String and _valid_timestamp(entry.get("last_seen", null)) and _valid_timestamp(entry.get("last_sample", null)) and (not entry.has("display_name") or entry.get("display_name") is String)
			var allowed := true
			for field in entry.keys():
				if not ["key", "endpoint", "database", "database_canonical", "world", "display_name", "status", "last_seen", "last_sample"].has(str(field)): allowed = false
			if valid_types and allowed and entry.get("status", "unknown") in ["unknown", "checking", "online", "unreachable"] and canonical_key(entry.endpoint, entry.database, entry.world) == key:
				valid[key] = entry
	return valid

static func _valid_timestamp(value: Variant) -> bool:
	if typeof(value) == TYPE_INT: return true
	return typeof(value) == TYPE_FLOAT and is_finite(value) and value == floor(value)

func _read_favorites(path: String) -> Dictionary:
	if not FileAccess.file_exists(path): return {}
	var parsed = JSON.parse_string(FileAccess.get_file_as_string(path))
	if not parsed is Dictionary: return {}
	var valid := {}
	for key in parsed:
		if key is String and key.length() <= 320 and parsed[key] is bool and parsed[key]: valid[key] = true
	return valid

func _write_map(path: String, value: Dictionary) -> Error:
	var temporary := path + ".tmp"
	var file := FileAccess.open(temporary, FileAccess.WRITE)
	if file == null: return ERR_CANT_OPEN
	file.store_string(JSON.stringify(value)); file.close()
	return DirAccess.rename_absolute(temporary, path)
