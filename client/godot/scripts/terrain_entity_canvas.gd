## Each descriptor is drawn exactly once as a whole icon into its feet-depth pass.
## The compositor clips spatial occlusion; no occupied-height slicing occurs.
extends Node2D

var entities: Array = []
var pixels := 32.0

func _draw() -> void:
	for entity: Dictionary in entities:
		var rect: Rect2 = entity.rect
		rect = Rect2(rect.position * pixels, rect.size * pixels)
		var colour: Color = entity.colour
		match entity.type:
			"facility":
				draw_rect(rect.grow(-1), colour)
				draw_rect(rect.grow(-3), colour.lightened(0.3), false, 1)
				if not entity.enabled:
					draw_line(rect.position + Vector2.ONE * 4, rect.end - Vector2.ONE * 4, Color("ff5c6c"), 2)
					var other := rect.position + Vector2(rect.size.x - 4, 4)
					draw_line(other, rect.position + Vector2(4, rect.size.y - 4), Color("ff5c6c"), 2)
				if entity.has("label"):
					draw_string(ThemeDB.fallback_font, rect.position + Vector2(3, 13), entity.label, HORIZONTAL_ALIGNMENT_LEFT, rect.size.x - 6, 11, Color.WHITE)
			"stack":
				draw_rect(rect, Color("151920"))
				draw_rect(rect, colour, false, 2)
				draw_line(rect.position, rect.end, colour, 1)
			"colonist":
				draw_circle(rect.get_center(), rect.size.x * 0.36, colour)
				draw_texture_rect_region(entity.texture, rect, entity.source)
				if entity.get("cargo", false):
					draw_rect(Rect2(rect.end - Vector2(8, 8), Vector2(8, 8)), entity.cargo_colour)
