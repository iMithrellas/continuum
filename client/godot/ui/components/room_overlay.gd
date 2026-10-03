## Independent room-envelope overlay; does not paint terrain or usage sprites.
## Floor tint, open corners and roof ridge denote properties, never blocking walls.
extends Control

var map: ColonyMap
var rooms: Array = []
var selected_id := -1

func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)

func _draw() -> void:
	if map == null or not map.has_world_snapshot(): return
	var viewport := Rect2(Vector2.ZERO, size)
	for room in rooms:
		var area := PlanningModel.footprint(room)
		var rect := Rect2(map.world_to_screen(Vector2(area.position)), Vector2(area.size) * map._cell_size())
		if not rect.intersects(viewport): continue
		if map.layered and not map.terrain_model.entity_visible(room): continue
		var ink := Color("e5c39a") if int(room.id) == selected_id else Color("b99c79")
		draw_rect(rect.grow(-1), Color(ink, 0.09))
		var inner := rect.grow(-2)
		draw_rect(inner, Color(ink, 0.6), false, 1)
		var length := minf(10, minf(inner.size.x, inner.size.y) * 0.3)
		for corner in [inner.position, Vector2(inner.end.x, inner.position.y), inner.end, Vector2(inner.position.x, inner.end.y)]:
			var direction: Vector2 = (inner.get_center() - corner).sign()
			draw_line(corner, corner + Vector2(direction.x * length, 0), ink, 2)
			draw_line(corner, corner + Vector2(0, direction.y * length), ink, 2)
		if rect.size.x > 24 and rect.size.y > 24:
			var ridge := inner.position + Vector2(inner.size.x * 0.5, 6)
			draw_polyline(PackedVector2Array([ridge + Vector2(-6, 4), ridge, ridge + Vector2(6, 4)]), ink, 1)
