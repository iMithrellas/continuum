## Presentation contract for independent room envelopes and operational usage.
## No optimistic rows: reducers and subscribed tables remain authoritative.
class_name PlanningModel
extends RefCounted

const WOOD_PER_CELL := 5.0
const MIN_CLEARANCE := 4
const MAX_CELLS := 4096
const ZONES := {
	ContinuumTileKind.Options.storage: ["Storage", "Shared stock destination"],
	ContinuumTileKind.Options.farm: ["Farm", "Farming work orders"],
	ContinuumTileKind.Options.forest: ["Forestry", "Logging & hunting orders"],
	ContinuumTileKind.Options.mine: ["Mine", "Mining work orders"],
	ContinuumTileKind.Options.dining: ["Dining", "A place to eat"],
	ContinuumTileKind.Options.sleep: ["Sleep", "A place to rest"],
	ContinuumTileKind.Options.recreation: ["Recreation", "A place for leisure"],
}

static func footprint(row: Variant) -> Rect2i:
	return Rect2i(int(row.x), int(row.y), int(row.width), int(row.depth))

static func rectangle_error(rect: Rect2i, bounds: Rect2i) -> String:
	if not rect.has_area() or not bounds.encloses(rect): return "Choose an area inside the world."
	if rect.size.x * rect.size.y > MAX_CELLS: return "Maximum 4,096 cells per request."
	return ""

static func preview(system: StringName, rect: Rect2i, zone_kind: int) -> String:
	var cells := rect.size.x * rect.size.y
	if system == &"construction":
		return "Insulated room · %d×%d · %d wood" % [rect.size.x, rect.size.y, cells * WOOD_PER_CELL]
	return "%s zone · %d×%d · Free" % [ZONES.get(zone_kind, ["Unknown"])[0], rect.size.x, rect.size.y]

static func zone_conflict(rect: Rect2i, z: int, kind: int, tiles: Array) -> String:
	for tile in tiles:
		if int(tile.z) != z or not rect.intersects(footprint(tile)) or tile.kind.value == ContinuumTileKind.Options.empty: continue
		if tile.kind.value != kind or int(tile.width) != 1 or int(tile.depth) != 1 or int(tile.clearance_height) != MIN_CLEARANCE:
			return "Existing usage conflicts. Clear it before designating this zone."
	return ""
