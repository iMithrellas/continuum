## Token-backed map drawing shared by the legacy and depth-pass renderers.
class_name MapPaint
extends RefCounted

static var _silhouettes: Dictionary = {}

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
	# Enum values belong to the wire contract, not a duplicated numeric palette.
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
	var token := zone_token(kind)
	canvas.draw_rect(rect, ThemeTokens.color(token))
	if token == "zone-sleep":
		return
	var light := token in ["zone-farm", "zone-storage"]
	var ink := translucent("map-ink" if light else "map-paper", 0.24 if light else 0.3)
	# A cell is 16 logical design pixels; the source pass may rasterize at 32.
	var unit := pixels / ThemeTokens.number("tile")
	var pitch := (8.0 if token == "zone-storage" else 6.0) * unit
	var phase := world_origin * pixels
	var width := maxf(0.5, unit)
	if token == "zone-forest":
		var y := ceilf((rect.position.y + phase.y - unit) / pitch) * pitch - phase.y
		while y <= rect.end.y + unit:
			var x := ceilf((rect.position.x + phase.x - unit) / pitch) * pitch - phase.x
			while x <= rect.end.x + unit:
				# Clip dot geometry, rather than dropping boundary dots: neighbouring
				# facility footprints reconstruct the same world-anchored stipple.
				var dot := PackedVector2Array()
				for index in 8:
					dot.append(Vector2(x, y) + Vector2.from_angle(index * TAU / 8.0) * unit)
				var boundary := PackedVector2Array([rect.position, Vector2(rect.end.x, rect.position.y), rect.end, Vector2(rect.position.x, rect.end.y)])
				for polygon in Geometry2D.intersect_polygons(dot, boundary):
					canvas.draw_colored_polygon(polygon, ink)
				x += pitch
			y += pitch
		return
	if token in ["zone-farm", "zone-storage"]:
		var y := ceilf((rect.position.y + phase.y - width * 0.5) / pitch) * pitch - phase.y
		while y <= rect.end.y + width * 0.5:
			canvas.draw_rect(Rect2(Vector2(rect.position.x, y - width * 0.5), Vector2(rect.size.x, width)).intersection(rect), ink)
			y += pitch
	if token in ["zone-rec", "zone-storage"]:
		var x := ceilf((rect.position.x + phase.x - width * 0.5) / pitch) * pitch - phase.x
		while x <= rect.end.x + width * 0.5:
			canvas.draw_rect(Rect2(Vector2(x - width * 0.5, rect.position.y), Vector2(width, rect.size.y)).intersection(rect), ink)
			x += pitch
	if token in ["zone-dining", "zone-mine"]:
		hatch(canvas, rect, phase, pitch, ink, width)
		if token == "zone-mine":
			hatch(canvas, rect, phase, pitch, ink, width, -1.0)

static func hatch(canvas: CanvasItem, rect: Rect2, phase: Vector2, pitch: float, colour: Color, width: float, direction := 1.0) -> void:
	# Lines y = direction*x + c, clipped analytically to the rectangle.
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

static func plate(canvas: CanvasItem, at: Vector2, title: String, count: String, scale := 1.0, planned := false, cache: Dictionary = {}) -> Rect2:
	var font := ThemeTokens.font("tag")
	var mono := ThemeTokens.font("readout")
	var size := maxi(11, roundi(ThemeTokens.font_size("tag") * scale))
	var count_size := maxi(11, roundi(ThemeTokens.font_size("readout") * scale))
	var padding := ThemeTokens.number("space-1") * scale
	var key := [title, count, scale, planned]
	if cache.get("key") != key:
		cache["key"] = key
		cache["title_width"] = font.get_string_size(title, HORIZONTAL_ALIGNMENT_LEFT, -1, size).x
		var count_width := mono.get_string_size(count, HORIZONTAL_ALIGNMENT_LEFT, -1, count_size).x
		var height := maxf(ThemeTokens.line_height("tag"), ThemeTokens.line_height("readout")) * scale + padding * 2
		cache["size"] = Vector2(cache.title_width + count_width + padding * (3 if not count.is_empty() else 2), height)
		var box := StyleBoxFlat.new()
		box.bg_color = ThemeTokens.color("map-paper")
		box.border_color = ThemeTokens.color("map-ink")
		box.set_corner_radius_all(roundi(ThemeTokens.number("radius-sm") * scale))
		box.set_border_width_all(0 if planned else maxi(1, roundi(scale)))
		cache["box"] = box
	var rect := Rect2(at, cache.size)
	canvas.draw_style_box(cache.box, rect)
	var colour := ThemeTokens.color("map-plan" if planned else "map-ink")
	canvas.draw_string(font, at + Vector2(padding, padding + font.get_ascent(size)), title, HORIZONTAL_ALIGNMENT_LEFT, -1, size, colour)
	if not count.is_empty():
		canvas.draw_string(mono, at + Vector2(padding * 2 + cache.title_width, padding + mono.get_ascent(count_size)), count, HORIZONTAL_ALIGNMENT_LEFT, -1, count_size, colour)
	if planned:
		var corners := [rect.position, Vector2(rect.end.x, rect.position.y), rect.end, Vector2(rect.position.x, rect.end.y)]
		for side in 4:
			canvas.draw_dashed_line(corners[side], corners[(side + 1) % 4], colour, scale, 3 * scale)
	return rect
