## Client-local browser history. It deliberately has no credential or world-data access.
class_name ContinuumConnectionHistory
extends RefCounted

const DEFAULT_WORLD := "default-world"
const MAX_ENTRIES := 100
const HISTORY_PATH := "user://continuum_connection_history.json"
const FAVORITES_PATH := "user://continuum_connection_favorites.json"
const DEFAULT_PORTS := {"http": 80, "https": 443, "ws": 80, "wss": 443}

var history_path := HISTORY_PATH
var favorites_path := FAVORITES_PATH
var _entries: Dictionary = {}
var _favorites: Dictionary = {}

func load_from(history_file := "", favorites_file := "") -> Error:
	if not history_file.is_empty(): history_path = history_file
	if not favorites_file.is_empty(): favorites_path = favorites_file
	_entries = _read_map(history_path)
	_favorites = _read_favorites(favorites_path)
	_trim()
	return OK

## This is the only method that creates history records: callers must report a successful subscription.
func record_successful_subscription(endpoint: String, database: String, world_slug := DEFAULT_WORLD,
		display_name := "", now := -1) -> String:
	var target := _target(endpoint, database, world_slug)
	if target.is_empty():
		return ""
	var key: String = target.key
	var entry: Dictionary = _entries.get(key, {})
	entry.merge(target)
	entry["last_seen"] = now if now >= 0 else int(Time.get_unix_time_from_system())
	entry["status"] = "online"
	if not display_name.is_empty():
		entry["display_name"] = display_name.strip_edges()
	_entries[key] = entry
	_trim()
	_write_map(history_path, _entries)
	return key

func import_legacy_entry(endpoint: String, database: String, world_slug: String,
		display_name := "", now := -1) -> String:
	# Adoption is explicit: callers must name the world instead of guessing from a catalog.
	if world_slug.strip_edges().is_empty():
		return ""
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

func set_favorite(key: String, favorite: bool) -> bool:
	if not _entries.has(key): return false
	if favorite: _favorites[key] = true
	else: _favorites.erase(key)
	_write_map(favorites_path, _favorites)
	return true

func remove_history(key: String) -> bool:
	if not _entries.has(key): return false
	_entries.erase(key)
	_write_map(history_path, _entries)
	return true

func remove_favorite(key: String) -> bool:
	if not _favorites.has(key): return false
	_favorites.erase(key)
	_write_map(favorites_path, _favorites)
	return true

func clear_history() -> void:
	_entries.clear()
	_write_map(history_path, _entries)

static func canonical_key(endpoint: String, database: String, world_slug := DEFAULT_WORLD) -> String:
	var target := _target(endpoint, database, world_slug)
	return target.get("key", "")

static func _target(endpoint: String, database: String, world_slug: String) -> Dictionary:
	var raw := endpoint.strip_edges()
	var marker := raw.find("://")
	if marker <= 0: return {}
	var scheme := raw.substr(0, marker).to_lower()
	if not _valid_scheme(scheme): return {}
	var authority := raw.substr(marker + 3)
	if authority.is_empty() or authority.contains("/") or authority.contains("?") or authority.contains("#") or authority.contains("@"): return {}
	var host := ""
	var port := -1
	if authority.begins_with("["):
		var close := authority.find("]")
		if close < 0 or close == 1: return {}
		host = authority.substr(0, close + 1)
		if authority.length() > close + 1:
			if authority[close + 1] != ":": return {}
			port = _port(authority.substr(close + 2))
			if port < 0: return {}
		if not host.contains(":"): return {}
	else:
		var colon := authority.find(":")
		if colon >= 0:
			host = authority.substr(0, colon)
			port = _port(authority.substr(colon + 1))
			if port < 0: return {}
		else: host = authority
		if host.is_empty() or host.contains(":"): return {}
	if host.is_empty(): return {}
	var db := database.strip_edges()
	var world := world_slug.strip_edges().to_lower()
	if db.is_empty() or db.contains("/") or world.is_empty() or not _valid_slug(world): return {}
	var canonical_host := host if host.begins_with("[") else host.to_lower()
	var endpoint_key := scheme + "://" + canonical_host
	if port >= 0 and (not DEFAULT_PORTS.has(scheme) or port != DEFAULT_PORTS[scheme]): endpoint_key += ":%d" % port
	return {"key": endpoint_key + "/" + db.to_lower() + "/" + world, "endpoint": raw,
		"database": db, "database_canonical": db.to_lower(), "world": world,
		"status": "unknown", "last_seen": 0, "last_sample": 0}

static func _valid_slug(value: String) -> bool:
	if value.length() == 0 or value.length() > 64 or value != value.to_lower() or value.strip_edges() != value: return false
	for character in value:
		if not (character >= "a" and character <= "z") and not (character >= "0" and character <= "9") and character != "-": return false
	return true

static func _valid_scheme(value: String) -> bool:
	if value.is_empty() or not ((value[0] >= "a" and value[0] <= "z")): return false
	for character in value:
		if not ((character >= "a" and character <= "z") or (character >= "0" and character <= "9") or character in ["+", ".", "-"]): return false
	return true

static func _port(value: String) -> int:
	return int(value) if value.is_valid_int() and int(value) > 0 and int(value) <= 65535 else -1

func _matches(entry: Dictionary, needle: String) -> bool:
	for field in ["display_name", "endpoint", "database", "world"]:
		if str(entry.get(field, "")).to_lower().contains(needle): return true
	return false

func _trim() -> void:
	while _entries.size() > MAX_ENTRIES:
		var oldest := ""
		var oldest_time := 9223372036854775807
		for key in _entries:
			if int(_entries[key].get("last_seen", 0)) < oldest_time:
				oldest = key; oldest_time = int(_entries[key].get("last_seen", 0))
		_entries.erase(oldest)

func _read_map(path: String) -> Dictionary:
	if not FileAccess.file_exists(path): return {}
	var parsed = JSON.parse_string(FileAccess.get_file_as_string(path))
	if not parsed is Dictionary: return {}
	var valid := {}
	for key in parsed:
		if key is String and parsed[key] is Dictionary and parsed[key].has("key") and parsed[key]["key"] == key:
			var entry: Dictionary = parsed[key]
			if canonical_key(str(entry.get("endpoint", "")), str(entry.get("database", "")), str(entry.get("world", ""))) == key:
				valid[key] = entry
	return valid

func _read_favorites(path: String) -> Dictionary:
	if not FileAccess.file_exists(path): return {}
	var parsed = JSON.parse_string(FileAccess.get_file_as_string(path))
	if not parsed is Dictionary: return {}
	var valid := {}
	for key in parsed:
		if key is String and bool(parsed[key]): valid[key] = true
	return valid

func _write_map(path: String, value: Dictionary) -> Error:
	var temporary := path + ".tmp"
	var file := FileAccess.open(temporary, FileAccess.WRITE)
	if file == null: return ERR_CANT_OPEN
	file.store_string(JSON.stringify(value)); file.close()
	return DirAccess.rename_absolute(temporary, path)
