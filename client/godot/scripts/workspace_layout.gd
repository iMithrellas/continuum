## Personal UI preferences only. Never contains replicated game state or roles.
class_name WorkspaceLayout
extends RefCounted

const SAVE_PATH := "user://workspaces.json"
const PANEL_NAMES := {
	"overview": "Colony overview",
	"people": "Colonist roster",
	"inspector": "Tile inspector",
	"operations": "Zones",
	"policies": "Colony policies",
	"alerts": "Alerts",
	"activity": "Activity feed",
	"trends": "Session trends",
	"admin": "Admin",
	"developer": "Developer",
	"construction": "Construction",
	"status": "Colony status",
	"resources": "Resources",
	"session": "Session / connection",
	"performance": "Performance",
}
const MIN_SIZE := Vector2(280, 180)
const SNAP_DISTANCE := 14.0
const GAP := 16.0


static func minimum_size(metrics := UiMetrics.new()) -> Vector2:
	return metrics.min_size(MIN_SIZE.x, MIN_SIZE.y)


var workspaces: Dictionary = defaults()
var active := "daily"
var show_panel_headers := true
var last_load_status := "missing"
var saved_workspaces: Dictionary = defaults()


static func panel(rect: Array, opened := true) -> Dictionary:
	return {"rect": rect, "open": opened, "minimized": false, "pinned": false, "z": 0}


static func defaults() -> Dictionary:
	var base := {
		"status": ["center", 0, "top", 12, 360, 30],
		"session": ["right", 16, "bottom", 12, 220, 30],
		"performance": ["right", 248, "bottom", 12, 224, 30],
		"resources": ["right", 16, "top", 12, 320, 156],
		"alerts": ["right", 16, "top", 168, 320, 190],
		"people": ["left", 16, "bottom", 16, 330, 326],
		"activity": ["center", 0, "bottom", 12, 340, 246],
		"overview": ["left", 16, "top", 12, 280, 240],
		"policies": ["right", 328, "top", 12, 300, 280],
		"construction": ["left", 16, "top", 12, 300, 400],
		"operations": ["left", 16, "bottom", 16, 300, 280],
		"inspector": ["right", 328, "top", 12, 280, 300],
		"trends": ["right", 16, "bottom", 56, 440, 143],
		"admin": ["center", 0, "top", 60, 480, 250],
		"developer": ["center", 0, "top", 330, 480, 450],
	}
	var presets := {
		"daily":
		["Daily operations", ["status", "resources", "alerts", "people", "activity", "session"]],
		"build":
		[
			"Construction & zones",
			["status", "construction", "operations", "inspector", "resources", "session"]
		],
		"welfare": ["Colonist welfare", ["status", "overview", "people", "policies", "alerts"]],
		"diagnostics": ["Diagnostics", ["status", "performance", "session", "trends", "activity"]],
	}
	var result := {}
	for id: String in presets:
		var panels := {}
		for key: String in PANEL_NAMES:
			var design: Array = base[key].duplicate()
			if id == "build" and key == "inspector":
				design = ["right", 16, "top", 12, 300, 300]
			if id == "build" and key == "resources":
				design[3] = 324
			if id == "welfare":
				if key == "people":
					design = ["right", 16, "top", 12, 380, 420]
				elif key == "policies":
					design = ["right", 16, "bottom", 16, 380, 280]
				elif key == "alerts":
					design = ["left", 16, "bottom", 16, 320, 190]
			if id == "diagnostics":
				if key == "performance":
					design = ["right", 16, "top", 12, 224, 30]
				elif key == "session":
					design = ["right", 16, "top", 52, 220, 30]
				elif key == "trends":
					design = ["left", 16, "bottom", 16, 520, 143]
				elif key == "activity":
					design = ["right", 16, "bottom", 16, 360, 326]
			var anchor := {
				"x": design[0],
				"dx": design[1],
				"y": design[2],
				"dy": design[3],
				"width": design[4],
				"height": design[5]
			}
			var rect := design_rect(anchor, Vector2(1440, 900))
			panels[key] = panel(to_normalized(rect, Vector2(1440, 900)), key in presets[id][1])
			panels[key].design = anchor
			panels[key].minimized = (
				(id == "daily" and key == "activity")
				or (id == "build" and key == "resources")
				or (id == "diagnostics" and key == "performance")
			)
		result[id] = {"name": presets[id][0], "panels": panels}
	return result


static func design_rect(anchor: Dictionary, area: Vector2, extent := Vector2.ZERO) -> Rect2:
	var dimensions := Vector2(anchor.width, anchor.height) if extent == Vector2.ZERO else extent
	var origin := Vector2(anchor.dx, anchor.dy)
	if anchor.x == "right":
		origin.x = area.x - dimensions.x - anchor.dx
	elif anchor.x == "center":
		origin.x = (area.x - dimensions.x) / 2 + anchor.dx
	if anchor.y == "bottom":
		origin.y = area.y - dimensions.y - anchor.dy
	return Rect2(
		origin.clamp(Vector2.ZERO, (area - dimensions).max(Vector2.ZERO)), dimensions.min(area)
	)


## A collapsed frame supplies its header minimum without changing expanded limits.
static func clamp_rect(
	rect: Rect2, area: Vector2, metrics := UiMetrics.new(), minimum := Vector2.ZERO
) -> Rect2:
	var available := area.max(Vector2.ONE)
	var floor_size := minimum_size(metrics) if minimum == Vector2.ZERO else minimum
	var extent := rect.size.clamp(floor_size.min(available), available)
	return Rect2(rect.position.clamp(Vector2.ZERO, available - extent), extent)


## Clamp only the dragged edges, keeping the opposite edges fixed.
static func clamp_resize_rect(
	rect: Rect2, area: Vector2, edges: Vector2i, metrics := UiMetrics.new()
) -> Rect2:
	var available := area.max(Vector2.ONE)
	var minimum := minimum_size(metrics).min(available)
	var result := rect
	for axis in 2:
		var start := rect.position[axis]
		var end := rect.end[axis]
		if edges[axis] < 0:
			end = clampf(end, minimum[axis], available[axis])
			start = clampf(start, 0.0, end - minimum[axis])
		elif edges[axis] > 0:
			start = clampf(start, 0.0, available[axis] - minimum[axis])
			end = clampf(end, start + minimum[axis], available[axis])
		else:
			var extent := clampf(rect.size[axis], minimum[axis], available[axis])
			start = clampf(start, 0.0, available[axis] - extent)
			end = start + extent
		result.position[axis] = start
		result.size[axis] = end - start
	return result


static func to_pixels(values: Array, area: Vector2, metrics := UiMetrics.new()) -> Rect2:
	return clamp_rect(
		Rect2(Vector2(values[0], values[1]) * area, Vector2(values[2], values[3]) * area),
		area,
		metrics
	)


static func to_normalized(rect: Rect2, area: Vector2) -> Array:
	var divisor := area.max(Vector2.ONE)
	return [
		rect.position.x / divisor.x,
		rect.position.y / divisor.y,
		rect.size.x / divisor.x,
		rect.size.y / divisor.y
	]


## Align parallel edges and leave a small gutter between adjacent windows.
static func snap_rect(
	rect: Rect2,
	area: Vector2,
	others: Array[Rect2],
	resizing := false,
	metrics := UiMetrics.new(),
	resize_edges := Vector2i.ONE,
	minimum := Vector2.ZERO
) -> Rect2:
	var result := (
		clamp_resize_rect(rect, area, resize_edges, metrics)
		if resizing
		else clamp_rect(rect, area, metrics, minimum)
	)
	var distance := metrics.px(SNAP_DISTANCE)
	var gap := metrics.px(GAP)
	for axis in 2:
		if resizing and resize_edges[axis] == 0:
			continue
		var edges: Array[float] = [0.0, area[axis]]
		for other: Rect2 in others:
			var cross := 1 - axis
			if (
				result.end[cross] < other.position[cross] - distance
				or result.position[cross] > other.end[cross] + distance
			):
				continue
			edges.append_array(
				[
					other.position[axis],
					other.end[axis],
					other.position[axis] - gap,
					other.end[axis] + gap
				]
			)
		var best := distance + 1.0
		var shift := 0.0
		for edge: float in edges:
			var candidates: Array[float] = [
				(
					edge
					- (
						result.position[axis]
						if resizing and resize_edges[axis] < 0
						else result.end[axis]
					)
				)
			]
			if not resizing:
				candidates.append(edge - result.position[axis])
			for delta: float in candidates:
				if absf(delta) < best:
					best = absf(delta)
					shift = delta
		if best <= distance:
			if resizing:
				if resize_edges[axis] < 0:
					result.position[axis] += shift
					result.size[axis] -= shift
				else:
					result.size[axis] += shift
			else:
				result.position[axis] += shift
	return (
		clamp_resize_rect(result, area, resize_edges, metrics)
		if resizing
		else clamp_rect(result, area, metrics, minimum)
	)


func create_workspace(title: String, selected: Array[String], copy_current := true) -> String:
	var clean := title.strip_edges().left(40)
	if clean.is_empty() or workspaces.size() >= 24:
		return ""
	var id := "custom_%d" % Time.get_ticks_usec()
	var panels: Dictionary = (
		workspaces[active].panels.duplicate(true) if copy_current else defaults().daily.panels
	)
	for key: String in panels:
		panels[key].open = key in selected
		panels[key].minimized = false
	workspaces[id] = {"name": clean, "panels": panels}
	saved_workspaces[id] = workspaces[id].duplicate(true)
	active = id
	return id


func remove_workspace(id: String) -> bool:
	if workspaces.size() <= 1 or not workspaces.has(id):
		return false
	workspaces.erase(id)
	saved_workspaces.erase(id)
	if active == id:
		active = workspaces.keys()[0]
	return true


func reset_active() -> void:
	var presets := defaults()
	if presets.has(active):
		workspaces[active] = presets[active]
	else:
		for key: String in workspaces[active].panels:
			var state: Dictionary = workspaces[active].panels[key]
			state.rect = presets.daily.panels[key].rect.duplicate()
			state.design = presets.daily.panels[key].design.duplicate()
			state.pinned = false
			state.minimized = false


func save_to(path := SAVE_PATH) -> Error:
	var file := FileAccess.open(path + ".tmp", FileAccess.WRITE)
	if file == null:
		return FileAccess.get_open_error()
	(
		file
		. store_string(
			(
				JSON
				. stringify(
					{
						"version": 4,
						"active": active,
						"show_panel_headers": show_panel_headers,
						"workspaces": workspaces,
						"saved_workspaces": saved_workspaces,
					},
					"",
					false,
					true
				)
			)
		)
	)
	file.flush()
	var error := file.get_error()
	file.close()
	if error != OK:
		return error
	return DirAccess.rename_absolute(path + ".tmp", path)


func load_from(path := SAVE_PATH) -> bool:
	if not FileAccess.file_exists(path):
		last_load_status = "missing"
		return true
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null or file.get_length() > 1048576:
		last_load_status = "unreadable"
		return false
	var data: Variant = JSON.parse_string(file.get_as_text())
	if (
		not data is Dictionary
		or (
			data.get("version") != 1
			and data.get("version") != 2
			and data.get("version") != 3
			and data.get("version") != 4
		)
		or not data.get("workspaces") is Dictionary
	):
		last_load_status = "corrupt"
		return false
	var migrate: bool = data.version != 4
	workspaces = _read_workspaces(data.workspaces, migrate)
	if workspaces.is_empty():
		workspaces = defaults()
	saved_workspaces = workspaces.duplicate(true)
	if data.get("saved_workspaces") is Dictionary:
		var baselines := _read_workspaces(data.saved_workspaces, migrate)
		for id: String in workspaces:
			if data.saved_workspaces.has(id) and baselines.has(id):
				saved_workspaces[id] = baselines[id]
	show_panel_headers = (
		data.get("show_panel_headers", true)
		if data.get("show_panel_headers", true) is bool
		else true
	)
	active = str(data.get("active", "daily"))
	if not workspaces.has(active):
		active = workspaces.keys()[0]
	last_load_status = "loaded"
	return true


func _read_workspaces(entries: Dictionary, migrate := false) -> Dictionary:
	var loaded := defaults() if migrate else {}
	for id: Variant in entries:
		if not id is String or loaded.size() >= 24:
			continue
		var entry: Variant = entries[id]
		if (
			not entry is Dictionary
			or not entry.get("name") is String
			or not entry.get("panels") is Dictionary
		):
			continue
		if entry.name.strip_edges().is_empty():
			continue
		var presets := defaults()
		var panels: Dictionary = loaded.get(id, presets.get(id, presets.daily)).panels.duplicate(
			true
		)
		if not entry.panels.has("construction"):
			panels.construction.open = false
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
			panels[key] = panel(
				[
					clampf(saved.rect[0], 0, 1),
					clampf(saved.rect[1], 0, 1),
					clampf(
						saved.rect[2],
						(
							0.001
							if not migrate or key in ["status", "session", "performance"]
							else 0.05
						),
						1
					),
					clampf(
						saved.rect[3],
						(
							0.001
							if not migrate or key in ["status", "session", "performance"]
							else 0.05
						),
						1
					)
				]
			)
			for flag: String in ["open", "minimized", "pinned"]:
				if saved.get(flag) is bool:
					panels[key][flag] = saved[flag]
			if _valid_design(saved.get("design")):
				panels[key].design = saved.design.duplicate()
			var z: Variant = saved.get("z", 0)
			if (z is int or z is float) and is_finite(float(z)):
				panels[key].z = clampi(int(z), 0, 10000)
		loaded[id] = {"name": entry.name.left(40), "panels": panels}
	return loaded


func _valid_design(value: Variant) -> bool:
	if not value is Dictionary:
		return false
	if value.get("x") not in ["left", "right", "center"] or value.get("y") not in ["top", "bottom"]:
		return false
	for key: String in ["dx", "dy", "width", "height"]:
		var number: Variant = value.get(key)
		if not (number is int or number is float) or not is_finite(float(number)):
			return false
		if absf(float(number)) > 10000:
			return false
	return value.width > 0 and value.height > 0


func save_active() -> void:
	saved_workspaces[active] = workspaces[active].duplicate(true)


func revert_active() -> void:
	if saved_workspaces.has(active):
		var current_name: String = workspaces[active].name
		workspaces[active] = saved_workspaces[active].duplicate(true)
		workspaces[active].name = current_name


func rename_active(title: String) -> void:
	var clean := title.strip_edges().left(40)
	if clean.is_empty():
		return
	workspaces[active].name = clean
	if saved_workspaces.has(active):
		saved_workspaces[active].name = clean


func is_active_dirty() -> bool:
	if not saved_workspaces.has(active):
		return false
	for key: String in workspaces[active].panels:
		var current: Dictionary = workspaces[active].panels[key]
		var baseline: Dictionary = saved_workspaces[active].panels[key]
		for property: String in ["rect", "design", "open", "minimized", "pinned"]:
			if current.get(property) != baseline.get(property):
				return true
	return false
