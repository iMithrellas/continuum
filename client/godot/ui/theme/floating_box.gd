@tool
extends StyleBox
## Godot's single shadow cannot express shadow-float; draw both token layers.
@export var shadows: Array[StyleBoxFlat] = []
@export var body: StyleBoxFlat


func _draw(canvas_item: RID, rect: Rect2) -> void:
	for index in range(shadows.size() - 1, -1, -1):
		shadows[index].draw(canvas_item, rect)
	body.draw(canvas_item, rect)
