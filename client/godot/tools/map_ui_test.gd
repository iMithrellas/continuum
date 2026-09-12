## Headless geometry contract for rectangle painting and selection.
##   godot --headless --path client/godot --script res://tools/map_ui_test.gd
extends SceneTree


func _initialize() -> void:
	var reversed := MapUiModel.normalize_rect(Vector2i(7, 4), Vector2i(2, 1))
	_assert(reversed == Rect2i(2, 1, 6, 4), "reverse drag is normalized inclusively")
	_assert(MapUiModel.normalize_rect(Vector2i(3, 3), Vector2i(3, 3)) == Rect2i(3, 3, 1, 1),
		"single cell remains one cell")
	_assert(MapUiModel.cells(Rect2i(0, 0, 5, 2)) == 10, "rectangle cost uses area")
	_assert(MapUiModel.clamp_cell(Vector2i(-4, 30), Vector2i(24, 24)) == Vector2i(0, 23),
		"outside motion clamps deterministically")
	print("MAP_UI_PASS")
	quit(0)


func _assert(condition: bool, message: String) -> void:
	if not condition:
		printerr("MAP_UI_FAIL: %s" % message)
		quit(1)
