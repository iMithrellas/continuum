class_name DiagnosticsOverlay
extends Control

var metrics: UiMetrics = UiMetrics.new()
var show_diagnostics := false
var show_graph := false
var processing_enabled := false
var frame_snapshot: Dictionary = {}
var rtt_snapshot: Dictionary = {}
var safe_rect_override: Variant = null

func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE

func configure(show: bool, graph: bool) -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	show_diagnostics = show
	show_graph = show and graph
	visible = show_diagnostics
	processing_enabled = show_diagnostics
	set_process(show_diagnostics)
	queue_redraw()

func apply_metrics(next_metrics: UiMetrics) -> void:
	metrics = next_metrics
	queue_redraw()

func set_snapshots(frame: Dictionary, rtt: Dictionary) -> void:
	frame_snapshot = frame
	rtt_snapshot = rtt
	if show_diagnostics:
		queue_redraw()

func set_safe_rect(rect: Rect2) -> void:
	safe_rect_override = rect
	queue_redraw()

func panel_rect() -> Rect2:
	var safe := _safe_rect()
	var inset := metrics.px(8.0)
	var graph := _graph_fits(safe)
	var width := minf(metrics.px(260.0 if graph else 210.0), maxf(0.0, safe.size.x - inset * 2.0))
	var height := minf(metrics.px(150.0 if graph else 70.0), maxf(0.0, safe.size.y - inset * 2.0))
	return Rect2(Vector2(safe.end.x - width - inset, safe.position.y + inset), Vector2(width, height))

func graph_lane_rects() -> Array[Rect2]:
	var panel := panel_rect()
	if not _graph_fits(_safe_rect()):
		return []
	var graph_top := panel.position.y + metrics.px(72.0)
	var lane_height := maxf(metrics.px(20.0), (panel.size.y - metrics.px(78.0)) / 2.0)
	return [Rect2(panel.position.x, graph_top, panel.size.x, lane_height),
		Rect2(panel.position.x, graph_top + lane_height, panel.size.x, lane_height)]

func _safe_rect() -> Rect2:
	if safe_rect_override is Rect2:
		return Rect2(safe_rect_override).intersection(Rect2(Vector2.ZERO, size))
	var viewport_size := size
	if viewport_size == Vector2.ZERO and get_viewport():
		viewport_size = get_viewport_rect().size
	if DisplayServer.get_name() == "headless":
		return Rect2(Vector2.ZERO, viewport_size)
	var display_safe := Rect2(DisplayServer.get_display_safe_area())
	if display_safe.size.x <= 0.0 or display_safe.size.y <= 0.0:
		return Rect2(Vector2.ZERO, viewport_size)
	var inverse := get_viewport().get_screen_transform().affine_inverse()
	return Rect2(inverse * display_safe.position, inverse * display_safe.end).intersection(Rect2(Vector2.ZERO, viewport_size))

func _graph_fits(safe: Rect2) -> bool:
	return show_graph and safe.size.y >= metrics.px(150.0) + metrics.px(16.0)

func _draw_text(font: Font, position: Vector2, text: String, font_size: int, color: Color, width: float) -> void:
	var bounds := panel_rect()
	if position.y - font_size < bounds.position.y or position.y + font_size > bounds.end.y:
		return
	var fitted := text
	while not fitted.is_empty() and font.get_string_size(fitted, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size).x > width:
		fitted = fitted.left(fitted.length() - 1)
	draw_string(font, position, fitted, HORIZONTAL_ALIGNMENT_LEFT, width, font_size, color)

func _draw() -> void:
	if not show_diagnostics:
		return
	var rect := panel_rect()
	draw_rect(rect, Color("181b1fdd"), true)
	draw_rect(rect, Color("68727add"), false, metrics.px(1.0))
	var font := ThemeDB.fallback_font
	var text_width := maxf(1.0, rect.size.x - metrics.px(16))
	_draw_text(font, rect.position + Vector2(metrics.px(8), metrics.px(16)), "DIAGNOSTICS", metrics.font(10), Color("b6c0c5"), text_width)
	var frame_text := "FPS --  frame-time N/A"
	if frame_snapshot.get("ready", false):
		frame_text = "FPS %.1f  p95 %.2f ms" % [frame_snapshot.mean_fps, frame_snapshot.p95_frame_ms]
	else:
		frame_text = "FPS --  warmup %d/%d" % [frame_snapshot.get("count", 0), frame_snapshot.get("minimum", 0)]
	_draw_text(font, rect.position + Vector2(metrics.px(8), metrics.px(33)), frame_text, metrics.font(10), Color("d6dadd"), text_width)
	var rtt_text := "RTT N/A  packet loss N/A"
	if rtt_snapshot.get("rtt_ms", null) != null:
		rtt_text = "RTT %.1f ms  avg %.1f ms" % [rtt_snapshot.rtt_ms, rtt_snapshot.get("rtt_smoothed_ms", rtt_snapshot.rtt_ms)]
	elif rtt_snapshot.get("rtt_stale", false):
		rtt_text = "RTT N/A (stale)  packet loss N/A"
	_draw_text(font, rect.position + Vector2(metrics.px(8), metrics.px(48)), rtt_text, metrics.font(10), Color("d6dadd"), text_width)
	_draw_text(font, rect.position + Vector2(metrics.px(8), metrics.px(63)), "probe timeouts %.0f%%" % (float(rtt_snapshot.get("probe_timeout_ratio", 0.0)) * 100.0) if rtt_snapshot.get("probe_timeout_ratio", null) != null else "probe timeouts N/A", metrics.font(9), Color("9ca8ad"), text_width)
	if not graph_lane_rects().is_empty():
		var lanes := graph_lane_rects()
		_draw_series(lanes[0], frame_snapshot.get("frame_graph", []), Color("b07b4f"), "frame-time ms")
		_draw_series(lanes[1], rtt_snapshot.get("rtt_graph", []), Color("7fa6b8"), "RTT ms")

func _draw_series(rect: Rect2, values: Array, color: Color, _label: String) -> void:
	if values.is_empty():
		return
	var plot := Rect2(rect.position + Vector2(metrics.px(8), metrics.px(2)), Vector2(maxf(1.0, rect.size.x - metrics.px(16)), maxf(1.0, rect.size.y - metrics.px(4))))
	_draw_text(ThemeDB.fallback_font, plot.position, _label, metrics.font(8), color, plot.size.x)
	var maximum := 1.0
	for value in values:
		var scalar = value.value if value is Dictionary else value
		if scalar != null:
			maximum = maxf(maximum, float(scalar))
	var first_tick := int(values[0].tick) if values[0] is Dictionary else 0
	var last_tick := int(values.back().tick) if values.back() is Dictionary else maxi(1, values.size() - 1)
	var previous := Vector2.ZERO
	for i in values.size():
		var scalar = values[i].value if values[i] is Dictionary else values[i]
		if scalar == null:
			previous = Vector2.ZERO
			continue
		var tick := int(values[i].tick) if values[i] is Dictionary else i
		var point := Vector2(plot.position.x + plot.size.x * float(tick - first_tick) / maxi(1, last_tick - first_tick), plot.end.y - clampf(float(scalar) / maximum, 0.0, 1.0) * plot.size.y)
		if previous != Vector2.ZERO:
			draw_line(previous, point, color, metrics.px(1.0))
		previous = point
	_draw_text(ThemeDB.fallback_font, plot.end - Vector2(metrics.px(36), -metrics.px(1)), "time", metrics.font(7), color, metrics.px(36))
