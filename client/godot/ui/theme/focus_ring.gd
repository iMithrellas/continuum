@tool
extends StyleBox
## Two explicit passes: desk casing then accent, including on accent-filled controls.
@export var casing: StyleBoxFlat
@export var ring: StyleBoxFlat


func _draw(canvas_item: RID, rect: Rect2) -> void:
	casing.draw(canvas_item, rect)
	ring.draw(canvas_item, rect)
