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
		match entity.type:
			"facility":
				MapPaint.zone(self, rect, entity.kind, origin, pixels)
				if not entity.enabled:
					draw_line(rect.position + Vector2.ONE * 4 * unit, rect.end - Vector2.ONE * 4 * unit, ThemeTokens.color("map-paper"), 4 * unit)
					draw_line(rect.position + Vector2.ONE * 4 * unit, rect.end - Vector2.ONE * 4 * unit, ThemeTokens.color("map-ink"), 2 * unit)
					var other := rect.position + Vector2(rect.size.x - 4 * unit, 4 * unit)
					draw_line(other, rect.position + Vector2(4 * unit, rect.size.y - 4 * unit), ThemeTokens.color("map-paper"), 4 * unit)
					draw_line(other, rect.position + Vector2(4 * unit, rect.size.y - 4 * unit), ThemeTokens.color("map-ink"), 2 * unit)
			"stack":
				MapPaint.crate(self, rect)
			"colonist":
				MapPaint.sprite(self, entity.texture, rect, entity.source, float(entity.get("outline", 1.0 / 16.0)) * pixels)
				if entity.get("cargo", false):
					var cargo := Rect2(rect.end - Vector2(8, 8) * unit, Vector2(8, 8) * unit)
					MapPaint.crate(self, cargo)
