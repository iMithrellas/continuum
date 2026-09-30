## Each descriptor is drawn exactly once as a whole icon into its feet-depth pass.
## The compositor clips spatial occlusion; no occupied-height slicing occurs.
extends Node2D

var entities: Array = []
var pixels := 32.0
var origin := Vector2.ZERO

func _draw() -> void:
	var unit := pixels / 32.0
	for entity: Dictionary in entities:
		var rect: Rect2 = entity.rect
		rect = Rect2((rect.position - origin) * pixels, rect.size * pixels)
		var colour: Color = entity.colour
		match entity.type:
			"facility":
				draw_rect(rect.grow(-unit), colour)
				draw_rect(rect.grow(-3 * unit), colour.lightened(0.3), false, unit)
				if not entity.enabled:
					draw_line(rect.position + Vector2.ONE * 4 * unit, rect.end - Vector2.ONE * 4 * unit, Color("ff5c6c"), 2 * unit)
					var other := rect.position + Vector2(rect.size.x - 4 * unit, 4 * unit)
					draw_line(other, rect.position + Vector2(4 * unit, rect.size.y - 4 * unit), Color("ff5c6c"), 2 * unit)
				if entity.has("label"):
					draw_string(ThemeDB.fallback_font, rect.position + Vector2(3, 13) * unit, entity.label, HORIZONTAL_ALIGNMENT_LEFT, rect.size.x - 6 * unit, maxi(1, roundi(11 * unit)), Color.WHITE)
			"stack":
				draw_rect(rect, Color("151920"))
				draw_rect(rect, colour, false, 2 * unit)
				draw_line(rect.position, rect.end, colour, unit)
			"colonist":
				draw_circle(rect.get_center(), rect.size.x * 0.36, colour)
				draw_texture_rect_region(entity.texture, rect, entity.source)
				if entity.get("cargo", false):
					draw_rect(Rect2(rect.end - Vector2(8, 8) * unit, Vector2(8, 8) * unit), entity.cargo_colour)
