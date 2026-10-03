## Token-backed map drawing shared by the legacy and depth-pass renderers.
class_name MapPaint
extends RefCounted

static var _silhouettes: Dictionary = {}
const OBJECTS = preload("res://assets/world/colony_objects.png")

static func sprite(canvas: CanvasItem, texture: Texture2D, rect: Rect2, source: Rect2, width: float) -> void:
	var key := "%s:%s" % [texture.get_instance_id(), source]
	if not _silhouettes.has(key):
		var image := texture.get_image().get_region(Rect2i(source))
		var ink := ThemeTokens.color("map-ink")
		for y in image.get_height():
			for x in image.get_width():
				ink.a = image.get_pixel(x, y).a
				image.set_pixel(x, y, ink)
		_silhouettes[key] = ImageTexture.create_from_image(image)
	for offset in [Vector2(-1, -1), Vector2(0, -1), Vector2(1, -1), Vector2(-1, 0), Vector2(1, 0), Vector2(-1, 1), Vector2(0, 1), Vector2(1, 1)]:
		canvas.draw_texture_rect(_silhouettes[key], Rect2(rect.position + offset * width, rect.size), false)
	canvas.draw_texture_rect_region(texture, rect, source)

static func zone_token(kind: int) -> String:
	match kind:
		ContinuumTileKind.Options.dining: return "zone-dining"
		ContinuumTileKind.Options.sleep: return "zone-sleep"
		ContinuumTileKind.Options.farm: return "zone-farm"
		ContinuumTileKind.Options.recreation: return "zone-rec"
		ContinuumTileKind.Options.forest: return "zone-forest"
		ContinuumTileKind.Options.mine: return "zone-mine"
		ContinuumTileKind.Options.storage: return "zone-storage"
	return "map-ground"

static func translucent(token: String, alpha: float) -> Color:
	var colour := ThemeTokens.color(token)
	colour.a = alpha
	return colour

static func selection(canvas: CanvasItem, rect: Rect2, scale := 1.0) -> void:
	canvas.draw_rect(rect, ThemeTokens.color("map-ink"), false, 4.0 * scale)
	canvas.draw_rect(rect, ThemeTokens.color("accent"), false, 2.0 * scale)

static func plan_edge(canvas: CanvasItem, a: Vector2, b: Vector2, scale := 1.0) -> void:
	canvas.draw_line(a, b, ThemeTokens.color("map-paper"), 4.0 * scale)
	canvas.draw_dashed_line(a, b, ThemeTokens.color("map-plan"), 2.0 * scale, 6.0 * scale)

static func zone(canvas: CanvasItem, rect: Rect2, kind: int, world_origin: Vector2, pixels: float) -> void:
	var row := -1
	match kind:
		ContinuumTileKind.Options.farm: row = 0
		ContinuumTileKind.Options.forest: row = 1
		ContinuumTileKind.Options.dining: row = 2
		ContinuumTileKind.Options.sleep: row = 3
		ContinuumTileKind.Options.recreation: row = 4
		ContinuumTileKind.Options.mine: row = 5
		ContinuumTileKind.Options.storage: row = 6
	if row < 0 or pixels <= 0:
		return
	var phase := world_origin * pixels
	var start := Vector2i(((rect.position + phase) / pixels).floor())
	var end := Vector2i(((rect.end + phase) / pixels).ceil())
	for y in range(start.y, end.y):
		for x in range(start.x, end.x):
			var whole := Rect2(Vector2(x, y) * pixels - phase, Vector2.ONE * pixels)
			var clipped := whole.intersection(rect)
			var variant := posmod(x * 73856093 ^ y * 19349663, 4)
			var source := Rect2(Vector2(variant, row) * 64 + (clipped.position - whole.position) * 64 / pixels, clipped.size * 64 / pixels)
			canvas.draw_texture_rect_region(OBJECTS, clipped, source)

static func crate(canvas: CanvasItem, rect: Rect2) -> void:
	canvas.draw_rect(rect, Color("a87c4c"))
	canvas.draw_rect(rect, Color("23362f"), false, maxf(0.75, rect.size.x * 0.10))
	canvas.draw_line(rect.position + rect.size * 0.18, rect.end - rect.size * 0.18, Color("e3c990"), maxf(0.75, rect.size.x * 0.13))
	canvas.draw_line(rect.position + Vector2(0, rect.size.y * 0.22), rect.position + Vector2(rect.size.x, rect.size.y * 0.22), Color("d0ad74"), maxf(0.5, rect.size.y * 0.1))

static func hatch(canvas: CanvasItem, rect: Rect2, phase: Vector2, pitch: float, colour: Color, width: float, direction := 1.0) -> void:
	# Clip y = direction*x + c analytically to the rectangle.
	var low := rect.position.y - (rect.end.x if direction > 0 else -rect.position.x)
	var high := rect.end.y - (rect.position.x if direction > 0 else -rect.end.x)
	var offset := phase.y - direction * phase.x
	var c := ceilf((low + offset - width) / pitch) * pitch - offset
	var boundary := PackedVector2Array([rect.position, Vector2(rect.end.x, rect.position.y), rect.end, Vector2(rect.position.x, rect.end.y)])
	while c <= high + width:
		var a := Vector2(rect.position.x - width, direction * (rect.position.x - width) + c)
		var b := Vector2(rect.end.x + width, direction * (rect.end.x + width) + c)
		var normal := Vector2(-direction, 1).normalized() * width * 0.5
		var strip := PackedVector2Array([a + normal, b + normal, b - normal, a - normal])
		for polygon in Geometry2D.intersect_polygons(strip, boundary):
			canvas.draw_colored_polygon(polygon, colour)
		c += pitch

## Corner brackets distinguish a replicated destination from the solid selection.
static func destination(canvas: CanvasItem, rect: Rect2, scale := 1.0) -> void:
	var arm := maxf(3 * scale, minf(rect.size.x, rect.size.y) * 0.3)
	for corner in [Vector2.ZERO, Vector2.RIGHT, Vector2.ONE, Vector2.DOWN]:
		var point: Vector2 = rect.position + rect.size * corner
		var inward: Vector2 = Vector2.ONE - corner * 2
		for direction in [Vector2(inward.x, 0), Vector2(0, inward.y)]:
			canvas.draw_line(point, point + direction * arm, ThemeTokens.color("map-ink"), 4 * scale)
			canvas.draw_line(point, point + direction * arm, ThemeTokens.color("accent"), 2 * scale)


## Optional viewport bounds keep transient feedback readable near map edges.
static func plate(canvas: CanvasItem, at: Vector2, title: String, count: String, scale := 1.0, planned := false, cache: Dictionary = {}, bounds := Rect2()) -> Rect2:
	var font := ThemeTokens.font("tag")
	var mono := ThemeTokens.font("readout")
	var size := maxi(11, roundi(ThemeTokens.font_size("tag") * scale))
	var count_size := maxi(11, roundi(ThemeTokens.font_size("readout") * scale))
	var padding := ThemeTokens.number("space-1") * scale
	var key := [title, count, scale, planned, bounds.size.x]
	if cache.get("key") != key:
		cache["key"] = key
		var available := bounds.size.x - padding * (3 if not count.is_empty() else 2) if bounds.has_area() else INF
		cache["title"] = fit_text(font, title, size, available)
		cache["title_width"] = font.get_string_size(cache.title, HORIZONTAL_ALIGNMENT_LEFT, -1, size).x
		cache["count"] = fit_text(mono, count, count_size, available - cache.title_width)
		var count_width := mono.get_string_size(cache.count, HORIZONTAL_ALIGNMENT_LEFT, -1, count_size).x
		var height := maxf(ThemeTokens.line_height("tag"), ThemeTokens.line_height("readout")) * scale + padding * 2
		cache["size"] = Vector2(cache.title_width + count_width + padding * (3 if not count.is_empty() else 2), height)
		var box := StyleBoxFlat.new()
		box.bg_color = ThemeTokens.color("map-paper")
		box.border_color = ThemeTokens.color("map-ink")
		box.set_corner_radius_all(roundi(ThemeTokens.number("radius-sm") * scale))
		box.set_border_width_all(0 if planned else maxi(1, roundi(scale)))
		cache["box"] = box
	if bounds.has_area():
		at.x = clampf(at.x, bounds.position.x, maxf(bounds.position.x, bounds.end.x - cache.size.x))
		at.y = clampf(at.y, bounds.position.y, maxf(bounds.position.y, bounds.end.y - cache.size.y))
	var rect := Rect2(at, cache.size)
	canvas.draw_style_box(cache.box, rect)
	var colour := ThemeTokens.color("map-plan" if planned else "map-ink")
	canvas.draw_string(font, at + Vector2(padding, padding + font.get_ascent(size)), cache.title, HORIZONTAL_ALIGNMENT_LEFT, -1, size, colour)
	if not count.is_empty():
		canvas.draw_string(mono, at + Vector2(padding * 2 + cache.title_width, padding + mono.get_ascent(count_size)), cache.count, HORIZONTAL_ALIGNMENT_LEFT, -1, count_size, colour)
	if planned:
		var corners := [rect.position, Vector2(rect.end.x, rect.position.y), rect.end, Vector2(rect.position.x, rect.end.y)]
		for side in 4:
			canvas.draw_dashed_line(corners[side], corners[(side + 1) % 4], colour, scale, 3 * scale)
	return rect


## Measured only when the plate's bounded, single-entry cache changes.
static func fit_text(font: Font, text: String, size: int, width: float) -> String:
	if font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, size).x <= width:
		return text
	if font.get_string_size("…", HORIZONTAL_ALIGNMENT_LEFT, -1, size).x > width:
		return ""
	while not text.is_empty():
		text = text.left(-1)
		if font.get_string_size(text + "…", HORIZONTAL_ALIGNMENT_LEFT, -1, size).x <= width:
			return text + "…"
	return "…"
