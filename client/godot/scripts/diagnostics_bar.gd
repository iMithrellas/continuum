## Inline header diagnostics. The inherited snapshots remain available to tools,
## but reducer echoes and HTTP probes are never presented as TCP measurements.
class_name DiagnosticsBar
extends DiagnosticsOverlay


func _ready() -> void:
	super._ready()
	clip_contents = true
	resized.connect(queue_redraw)


func panel_rect() -> Rect2:
	return Rect2(Vector2.ZERO, size)


func session_rtt_text() -> String:
	if rtt_snapshot.get("source", "") != "tcp_info" or rtt_snapshot.get("rtt_ms", null) == null or rtt_snapshot.get("rtt_stale", false):
		return "TCP RTT N/A"
	return "TCP RTT %.1f ms" % float(rtt_snapshot.rtt_ms)


func frame_text(compact_text := false) -> String:
	if not frame_snapshot.get("ready", false):
		return "FPS -- p95 --" if compact_text else "FPS --  p95 N/A"
	if compact_text:
		return "FPS %.0f p95 %.0f" % [float(frame_snapshot.get("mean_fps", 0)), float(frame_snapshot.get("p95_frame_ms", 0))]
	return "FPS %.0f  p95 %.1f ms" % [float(frame_snapshot.get("mean_fps", 0)), float(frame_snapshot.get("p95_frame_ms", 0))]


func graph_lane_rects() -> Array[Rect2]:
	# Sparklines share the same 38px header, never a second row or the map.
	if not show_graph or size.x < metrics.px(340) or size.y < metrics.px(30):
		return []
	var width := metrics.px(65)
	var height := maxf(0, (size.y - metrics.px(12)) / 2)
	return [Rect2(size.x - width - metrics.px(6), metrics.px(4), width, height),
		Rect2(size.x - width - metrics.px(6), size.y / 2 + metrics.px(2), width, height)]


func _draw() -> void:
	if not show_diagnostics or size.x <= 0 or size.y <= 0:
		return
	var font := ThemeDB.fallback_font
	var font_size := metrics.font(10)
	var lanes := graph_lane_rects()
	var padding := metrics.px(3)
	var available := maxf(0, size.x - padding * 2 - (metrics.px(77) if not lanes.is_empty() else 0))
	var full_frame := frame_text()
	var compact_text := font.get_string_size(full_frame, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size).x > available
	if compact_text:
		font_size = metrics.font(9)
	var baseline := (size.y / 2 - font.get_height(font_size)) / 2 + font.get_ascent(font_size)
	_draw_line(font, Vector2(padding, baseline), frame_text(compact_text), font_size, available)
	_draw_line(font, Vector2(padding, size.y / 2 + baseline), session_rtt_text(), font_size, available)
	if not lanes.is_empty():
		_draw_sparkline(lanes[0], frame_snapshot.get("frame_graph", []), DeckTheme.ACCENT)
		if rtt_snapshot.get("source", "") == "tcp_info" and not rtt_snapshot.get("rtt_stale", false):
			_draw_sparkline(lanes[1], rtt_snapshot.get("rtt_graph", []), Color("7fa6b8"))


func _draw_line(font: Font, point: Vector2, text: String, font_size: int, width: float) -> void:
	# draw_string's width does not truncate unwrapped text. Clip at the host and
	# explicitly fit the text; no tooltip promises on this input-transparent UI.
	var fitted := text
	while not fitted.is_empty() and font.get_string_size(fitted, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size).x > width:
		fitted = fitted.left(fitted.length() - 1)
	draw_string(font, point, fitted, HORIZONTAL_ALIGNMENT_RIGHT, width, font_size, Color("e8e1d5"))


func _draw_sparkline(rect: Rect2, values: Array, color: Color) -> void:
	var maximum := 1.0
	for value in values:
		var scalar = value.get("value") if value is Dictionary else value
		if scalar != null:
			maximum = maxf(maximum, float(scalar))
	var previous: Variant = null
	var first_tick := int(values[0].get("tick", 0)) if not values.is_empty() and values[0] is Dictionary else 0
	var last_tick := int(values.back().get("tick", 0)) if not values.is_empty() and values.back() is Dictionary else maxi(1, values.size() - 1)
	for index in values.size():
		var scalar = values[index].get("value") if values[index] is Dictionary else values[index]
		if scalar == null:
			previous = null
			continue
		var tick := int(values[index].get("tick", index)) if values[index] is Dictionary else index
		var point := Vector2(rect.position.x + rect.size.x * clampf(float(tick - first_tick) / maxi(1, last_tick - first_tick), 0, 1), rect.end.y - clampf(float(scalar) / maximum, 0, 1) * rect.size.y)
		if previous != null:
			draw_line(previous, point, color, 1.0)
		previous = point
