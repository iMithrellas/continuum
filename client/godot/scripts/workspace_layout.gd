## Personal UI preferences only. Never contains replicated game state or roles.
class_name WorkspaceLayout
extends RefCounted

const SAVE_PATH := "user://workspaces.json"
const PANEL_NAMES := {
	"overview": "Colony overview", "people": "Colonist roster",
	"inspector": "Tile inspector", "operations": "Build & work orders",
	"policies": "Colony policies", "alerts": "Alerts",
	"activity": "Activity feed", "trends": "Session trends",
}
const MIN_SIZE := Vector2(280, 180)
const SNAP_DISTANCE := 14.0
const GAP := 8.0

static func minimum_size(metrics := UiMetrics.new()) -> Vector2:
	return metrics.min_size(MIN_SIZE.x, MIN_SIZE.y)

var workspaces: Dictionary = defaults()
var active := "daily"


static func panel(rect: Array, opened := true) -> Dictionary:
	return {"rect": rect, "open": opened, "minimized": false, "pinned": false, "z": 0}


static func defaults() -> Dictionary:
	var result := {}
	var presets := {
		"daily": ["Daily operations", {
			"people": [0.01, 0.02, 0.235, 0.65], "overview": [0.755, 0.02, 0.235, 0.44],
			"alerts": [0.755, 0.65, 0.235, 0.33], "activity": [0.01, 0.69, 0.235, 0.29]}],
		"build": ["Logistics & build", {
			"operations": [0.01, 0.02, 0.255, 0.76], "inspector": [0.755, 0.02, 0.235, 0.52],
			"policies": [0.755, 0.56, 0.235, 0.42]}],
		"welfare": ["Colonist welfare", {
			"people": [0.01, 0.02, 0.255, 0.96], "policies": [0.755, 0.02, 0.235, 0.47],
			"trends": [0.705, 0.54, 0.285, 0.44]}],
		"diagnostics": ["Diagnostics", {
			"inspector": [0.01, 0.02, 0.235, 0.52], "alerts": [0.755, 0.02, 0.235, 0.42],
			"trends": [0.01, 0.58, 0.29, 0.40], "activity": [0.65, 0.52, 0.34, 0.46]}],
	}
	for id: String in presets:
		var panels := {}
		for key: String in PANEL_NAMES:
			panels[key] = panel(presets[id][1].get(key, [0.33, 0.12, 0.32, 0.65]), presets[id][1].has(key))
		result[id] = {"name": presets[id][0], "panels": panels}
	return result


static func clamp_rect(rect: Rect2, area: Vector2, metrics := UiMetrics.new()) -> Rect2:
	var available := area.max(Vector2.ONE)
	var extent := rect.size.clamp(minimum_size(metrics).min(available), available)
	return Rect2(rect.position.clamp(Vector2.ZERO, available - extent), extent)


static func to_pixels(values: Array, area: Vector2) -> Rect2:
	return clamp_rect(Rect2(Vector2(values[0], values[1]) * area,
		Vector2(values[2], values[3]) * area), area)


static func to_normalized(rect: Rect2, area: Vector2) -> Array:
	var divisor := area.max(Vector2.ONE)
	return [rect.position.x / divisor.x, rect.position.y / divisor.y,
		rect.size.x / divisor.x, rect.size.y / divisor.y]


## Align parallel edges and leave a small gutter between adjacent windows.
static func snap_rect(rect: Rect2, area: Vector2, others: Array[Rect2], resizing := false, metrics := UiMetrics.new()) -> Rect2:
	var result := clamp_rect(rect, area, metrics)
	for axis in 2:
		var edges: Array[float] = [0.0, area[axis]]
		for other: Rect2 in others:
			var cross := 1 - axis
			if result.end[cross] < other.position[cross] - SNAP_DISTANCE or result.position[cross] > other.end[cross] + SNAP_DISTANCE:
				continue
			edges.append_array([other.position[axis], other.end[axis],
				other.position[axis] - GAP, other.end[axis] + GAP])
		var best := SNAP_DISTANCE + 1.0
		var shift := 0.0
		for edge: float in edges:
			var candidates: Array[float] = [edge - result.end[axis]]
			if not resizing:
				candidates.append(edge - result.position[axis])
			for delta: float in candidates:
				if absf(delta) < best:
					best = absf(delta)
					shift = delta
		if best <= SNAP_DISTANCE:
			if resizing:
				result.size[axis] += shift
			else:
				result.position[axis] += shift
	return clamp_rect(result, area, metrics)


func create_workspace(title: String, selected: Array[String], copy_current := true) -> String:
	var clean := title.strip_edges().left(40)
	if clean.is_empty() or workspaces.size() >= 24:
		return ""
	var id := "custom_%d" % Time.get_ticks_usec()
	var panels: Dictionary = workspaces[active].panels.duplicate(true) if copy_current else defaults().daily.panels
	for key: String in panels:
		panels[key].open = key in selected
		panels[key].minimized = false
	workspaces[id] = {"name": clean, "panels": panels}
	active = id
	return id


func remove_workspace(id: String) -> bool:
	if defaults().has(id) or not workspaces.has(id):
		return false
	workspaces.erase(id)
	if active == id:
		active = "daily"
	return true


func reset_active() -> void:
	var presets := defaults()
	if presets.has(active):
		workspaces[active] = presets[active]
	else:
		for key: String in workspaces[active].panels:
			var state: Dictionary = workspaces[active].panels[key]
			state.rect = presets.daily.panels[key].rect.duplicate()
			state.pinned = false
			state.minimized = false


func save_to(path := SAVE_PATH) -> Error:
	# Replace atomically, so an interrupted write cannot destroy the last layout.
	var file := FileAccess.open(path + ".tmp", FileAccess.WRITE)
	if file == null:
		return FileAccess.get_open_error()
	file.store_string(JSON.stringify({"version": 1, "active": active, "workspaces": workspaces}))
	file.flush()
	var error := file.get_error()
	file.close()
	if error != OK:
		return error
	return DirAccess.rename_absolute(path + ".tmp", path)


func load_from(path := SAVE_PATH) -> bool:
	if not FileAccess.file_exists(path):
		return true
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null or file.get_length() > 1048576:
		return false
	var data: Variant = JSON.parse_string(file.get_as_text())
	if not data is Dictionary or data.get("version") != 1 or not data.get("workspaces") is Dictionary:
		return false
	var loaded := defaults()
	for id: Variant in data.workspaces:
		if not id is String or loaded.size() >= 24:
			continue
		var entry: Variant = data.workspaces[id]
		if not entry is Dictionary or not entry.get("name") is String or not entry.get("panels") is Dictionary:
			continue
		if entry.name.strip_edges().is_empty():
			continue
		var panels: Dictionary = loaded.get(id, defaults().daily).panels.duplicate(true)
		for key: String in PANEL_NAMES:
			var saved: Variant = entry.panels.get(key)
			if not saved is Dictionary or not saved.get("rect") is Array or saved.rect.size() != 4:
				continue
			var valid := true
			for value: Variant in saved.rect:
				if not (value is float or value is int) or not is_finite(float(value)):
					valid = false
			if not valid:
				continue
			panels[key] = panel([clampf(saved.rect[0], 0, 1), clampf(saved.rect[1], 0, 1),
				clampf(saved.rect[2], 0.05, 1), clampf(saved.rect[3], 0.05, 1)])
			for flag: String in ["open", "minimized", "pinned"]:
				if saved.get(flag) is bool:
					panels[key][flag] = saved[flag]
			var z: Variant = saved.get("z", 0)
			if (z is int or z is float) and is_finite(float(z)):
				panels[key].z = clampi(int(z), 0, 10000)
		loaded[id] = {"name": entry.name.left(40), "panels": panels}
	workspaces = loaded
	active = str(data.get("active", "daily"))
	if not workspaces.has(active):
		active = "daily"
	return true
