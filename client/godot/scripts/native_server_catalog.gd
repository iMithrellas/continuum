## Durable local server profiles. Paths are derived from IDs, never loaded from JSON.
class_name ContinuumNativeServerCatalog
extends RefCounted

const Manager = preload("res://scripts/native_server_manager.gd")
const MAX_SERVERS := 16
var path := ""
var _entries: Array[Dictionary] = []


func load_from(root := "") -> Error:
	var native_root: String = root if not root.is_empty() else Manager.native_root()
	path = native_root.path_join("servers.json")
	if not FileAccess.file_exists(path):
		# Adopt the original server in place; never move an existing colony.
		return _save([{"id": "default", "name": "Local server", "port": 3001}])
	return _reload()


func entries() -> Array[Dictionary]:
	return _entries.duplicate(true)


func entry(id: String) -> Dictionary:
	for value in _entries:
		if value.id == id:
			return value.duplicate(true)
	return {}


func create(display_name: String) -> Dictionary:
	var name := display_name.strip_edges()
	if name.is_empty() or name.length() > 64 or name.contains("\n") or name.contains("\r"):
		return {"ok": false, "error": "Enter a server name of 1–64 characters on one line."}
	if _reload() != OK:
		return {"ok": false, "error": "Could not read the managed server list; it was not changed."}
	if _entries.size() >= MAX_SERVERS:
		return {
			"ok": false,
			"error":
			"You can manage up to %d local servers. Delete a stopped server first." % MAX_SERVERS
		}
	var used_ports: Array[int] = []
	for value in _entries:
		if str(value.name).to_lower() == name.to_lower():
			return {"ok": false, "error": "A managed server already has that name."}
		used_ports.append(int(value.port))
	var port := 3001
	while used_ports.has(port):
		port += 1
	var entropy := Crypto.new().generate_random_bytes(12)
	if entropy.size() != 12:
		return {
			"ok": false, "error": "Could not allocate a unique server identity. Retry creation."
		}
	var value := {"id": "server-" + entropy.hex_encode(), "name": name, "port": port}
	if not entry(value.id).is_empty():
		return {
			"ok": false, "error": "Could not allocate a unique server identity. Retry creation."
		}
	var candidate := entries()
	candidate.append(value)
	if _save(candidate) != OK:
		return {
			"ok": false,
			"error": "Could not save the new server. Check the native data directory permissions."
		}
	return {"ok": true, "entry": value}


## Called only after the worker has confirmed deletion of the stopped server's data.
func remove(id: String) -> Error:
	var error := _reload()
	if error != OK:
		return error
	var candidate: Array[Dictionary] = []
	for value in _entries:
		if value.id != id:
			candidate.append(value)
	if candidate.size() == _entries.size():
		return ERR_DOES_NOT_EXIST
	return _save(candidate)


func _reload() -> Error:
	var parser := JSON.new()
	if parser.parse(FileAccess.get_file_as_string(path)) != OK:
		return ERR_FILE_CORRUPT
	var parsed = parser.data
	if not parsed is Array or parsed.size() > MAX_SERVERS:
		return ERR_FILE_CORRUPT
	var candidate: Array[Dictionary] = []
	var ids := {}
	var ports := {}
	for value in parsed:
		if (
			not value is Dictionary
			or value.size() != 3
			or not value.get("id") is String
			or not value.get("name") is String
			or not (value.get("port") is int or value.get("port") is float)
		):
			return ERR_FILE_CORRUPT
		var port := int(value.port)
		if (
			not Manager.valid_instance_id(value.id)
			or ids.has(value.id)
			or ports.has(port)
			or port != value.port
			or port < 1024
			or port > 65535
			or (value.id == "default" and port != 3001)
			or value.name.strip_edges().is_empty()
			or value.name.length() > 64
			or value.name.contains("\n")
			or value.name.contains("\r")
		):
			return ERR_FILE_CORRUPT
		ids[value.id] = true
		ports[port] = true
		candidate.append({"id": value.id, "name": value.name, "port": port})
	_entries = candidate
	return OK


func _save(candidate: Array[Dictionary]) -> Error:
	var error := DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	if error != OK:
		return error
	var temporary := path + ".tmp.%d" % OS.get_process_id()
	var file := FileAccess.open(temporary, FileAccess.WRITE)
	if file == null:
		return FileAccess.get_open_error()
	file.store_string(JSON.stringify(candidate, "\t"))
	file.close()
	error = DirAccess.rename_absolute(temporary, path)
	if error == OK:
		_entries = candidate.duplicate(true)
	else:
		DirAccess.remove_absolute(temporary)
	return error
