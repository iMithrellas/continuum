extends SceneTree

const Regions = preload("res://scripts/map_regions.gd")
var failed := false


func check(condition: bool, message: String) -> void:
	if not condition:
		failed = true
		push_error(message)


func footprint(rect: Rect2i, kind := 1, z := 0) -> Dictionary:
	return {"rect": rect, "kind": kind, "z": z}


func _initialize() -> void:
	var separate := Regions.build(
		[
			footprint(Rect2i(0, 0, 1, 1)),
			footprint(Rect2i(1, 1, 1, 1)),
			footprint(Rect2i(4, 0, 1, 1))
		]
	)
	check(separate.size() == 3, "diagonal and disconnected same-kind cells get separate plates")
	var joined := Regions.build(
		[
			footprint(Rect2i(15, 2, 2, 3)),
			footprint(Rect2i(17, 2, 2, 3)),
			footprint(Rect2i(16, 3, 1, 1))
		]
	)
	check(
		joined.size() == 1 and joined[0].count == 12,
		"multi-cell cross-chunk footprints merge and overlap is counted once"
	)
	check(
		joined[0].anchor == Vector2i(15, 2) and joined[0].edges.size() == 14,
		"top-left anchor and exterior-only boundary survive chunk seams"
	)
	var levels := Regions.build(
		[
			footprint(Rect2i(0, 0, 2, 2), 1, -1),
			footprint(Rect2i(0, 0, 2, 2), 1, 0),
			footprint(Rect2i(2, 0, 1, 1), 2, 0)
		]
	)
	check(levels.size() == 3, "different actual base z and kind never merge")
	var ring := Regions.build(
		[
			footprint(Rect2i(0, 0, 3, 1)),
			footprint(Rect2i(0, 2, 3, 1)),
			footprint(Rect2i(0, 1, 1, 1)),
			footprint(Rect2i(2, 1, 1, 1))
		]
	)
	check(
		ring.size() == 1 and ring[0].count == 8 and ring[0].edges.size() == 16,
		"hole stays empty and keeps its inner boundary without an extra plate"
	)
	var bent := [footprint(Rect2i(2, 0, 1, 3)), footprint(Rect2i(0, 2, 2, 1))]
	var first := Regions.build(bent)
	bent.reverse()
	var reversed := Regions.build(bent)
	check(
		first == reversed and first[0].anchor == Vector2i(2, 0),
		"anchor is occupied and deterministic, never an empty bounding-box corner"
	)
	check(Regions.build([]).is_empty(), "empty snapshots clear all plates")
	print("UI_MAP_REGIONS_%s" % ["FAIL" if failed else "PASS"])
	quit(1 if failed else 0)
