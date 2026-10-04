class_name DiagnosticsOverlay
extends Control

var metrics: UiMetrics = UiMetrics.new()
var show_diagnostics := false
var show_graph := false
var processing_enabled := false
var frame_snapshot: Dictionary = {}
var rtt_snapshot: Dictionary = {}
var safe_rect_override: Variant = null


## Snapshots follow SessionDiagnostics: acknowledged session echoes, not TCP or HTTP.
static func has_session_rtt(snapshot: Dictionary) -> bool:
	var latency: Variant = snapshot.get("rtt_ms")
	return (
		not snapshot.get("rtt_stale", false)
		and (latency is float or latency is int)
		and is_finite(float(latency))
		and float(latency) >= 0.0
	)


## Explicit allowlist for the developer's copyable diagnostics summary.
static func session_summary_lines(snapshot: Dictionary) -> Array[String]:
	var lines: Array[String] = []
	if has_session_rtt(snapshot):
		lines.append("Session echo RTT ms: %.2f" % float(snapshot.rtt_ms))
	else:
		lines.append("Session echo RTT: unavailable")
	lines.append(probe_timeout_text(snapshot))
	lines.append("Packet loss: unavailable")
	return lines


static func probe_timeout_text(snapshot: Dictionary) -> String:
	var ratio: Variant = snapshot.get("probe_timeout_ratio")
	if (
		(ratio is float or ratio is int)
		and is_finite(float(ratio))
		and float(ratio) >= 0.0
		and float(ratio) <= 1.0
	):
		return "probe timeouts %.0f%%" % (float(ratio) * 100.0)
	return "probe timeouts N/A"


func session_rtt_text(compact_text := false) -> String:
	var label := "Session" if compact_text else "Session RTT"
	if not has_session_rtt(rtt_snapshot):
		return "%s N/A" % label
	return "%s %.1f ms" % [label, float(rtt_snapshot.rtt_ms)]


## Historical RTT remains visible when stale; null samples break the line.
func session_rtt_graph() -> Array:
	return rtt_snapshot.get("rtt_graph", [])


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
	return Rect2(
		Vector2(safe.end.x - width - inset, safe.position.y + inset), Vector2(width, height)
	)


func graph_lane_rects() -> Array[Rect2]:
	var panel := panel_rect()
	if not _graph_fits(_safe_rect()):
		return []
	var graph_top := panel.position.y + metrics.px(72.0)
	var lane_height := maxf(metrics.px(20.0), (panel.size.y - metrics.px(78.0)) / 2.0)
	return [
		Rect2(panel.position.x, graph_top, panel.size.x, lane_height),
		Rect2(panel.position.x, graph_top + lane_height, panel.size.x, lane_height)
	]


func _safe_rect() -> Rect2:
	if safe_rect_override is Rect2:
		return Rect2(safe_rect_override).intersection(Rect2(Vector2.ZERO, size))
	var viewport_size := size
	if viewport_size == Vector2.ZERO and get_viewport():
		viewport_size = get_viewport_rect().size
	# Desktop safe areas are monitor-relative, not game-window-relative.
	if not OS.has_feature("mobile") or DisplayServer.get_name() == "headless":
		return Rect2(Vector2.ZERO, viewport_size)
	var display_safe := Rect2(DisplayServer.get_display_safe_area())
	if display_safe.size.x <= 0.0 or display_safe.size.y <= 0.0:
		return Rect2(Vector2.ZERO, viewport_size)
	var inverse := get_viewport().get_screen_transform().affine_inverse()
	var start := inverse * display_safe.position
	return Rect2(start, inverse * display_safe.end - start).intersection(
		Rect2(Vector2.ZERO, viewport_size)
	)


func _graph_fits(safe: Rect2) -> bool:
	return show_graph and safe.size.y >= metrics.px(150.0) + metrics.px(16.0)


func _draw_text(
	font: Font, position: Vector2, text: String, font_size: int, color: Color, width: float
) -> void:
	var bounds := panel_rect()
	if position.y - font_size < bounds.position.y or position.y + font_size > bounds.end.y:
		return
	if font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size).x <= width:
		draw_string(font, position, text, HORIZONTAL_ALIGNMENT_LEFT, width, font_size, color)


func _draw() -> void:
	if not show_diagnostics:
		return
	var rect := panel_rect()
	draw_rect(rect, ThemeTokens.color("bg-100"), true)
	draw_rect(rect, ThemeTokens.color("line-100"), false, metrics.px(1.0))
	var font := ThemeTokens.font("readout")
	var text_width := maxf(1.0, rect.size.x - metrics.px(16))
	_draw_text(
		ThemeTokens.font("section"),
		rect.position + Vector2(metrics.px(8), metrics.px(16)),
		"DIAGNOSTICS",
		ThemeTokens.font_size("section"),
		ThemeTokens.color("ink-subtle"),
		text_width
	)
	var frame_text := "FPS --  frame-time N/A"
	if frame_snapshot.get("ready", false):
		frame_text = (
			"FPS %.1f  p95 %.2f ms" % [frame_snapshot.mean_fps, frame_snapshot.p95_frame_ms]
		)
	else:
		frame_text = (
			"FPS --  warmup %d/%d"
			% [frame_snapshot.get("count", 0), frame_snapshot.get("minimum", 0)]
		)
	_draw_text(
		font,
		rect.position + Vector2(metrics.px(8), metrics.px(33)),
		frame_text,
		ThemeTokens.font_size("readout"),
		ThemeTokens.color("ink"),
		text_width
	)
	var rtt_text := session_rtt_text()
	if rtt_snapshot.get("rtt_stale", false):
		rtt_text += " (stale)"
	_draw_text(
		font,
		rect.position + Vector2(metrics.px(8), metrics.px(48)),
		rtt_text,
		ThemeTokens.font_size("readout"),
		ThemeTokens.color("ink"),
		text_width
	)
	_draw_text(
		font,
		rect.position + Vector2(metrics.px(8), metrics.px(63)),
		probe_timeout_text(rtt_snapshot),
		ThemeTokens.font_size("log"),
		ThemeTokens.color("ink-subtle"),
		text_width
	)
	if not graph_lane_rects().is_empty():
		var lanes := graph_lane_rects()
		_draw_series(
			lanes[0],
			frame_snapshot.get("frame_graph", []),
			ThemeTokens.color("ink-muted"),
			"frame-time ms"
		)
		_draw_series(
			lanes[1], session_rtt_graph(), ThemeTokens.color("meter-fill"), "session RTT ms"
		)


func _draw_series(rect: Rect2, values: Array, color: Color, _label: String) -> void:
	if values.is_empty():
		return
	var plot := Rect2(
		rect.position + Vector2(metrics.px(8), metrics.px(2)),
		Vector2(maxf(1.0, rect.size.x - metrics.px(16)), maxf(1.0, rect.size.y - metrics.px(4)))
	)
	_draw_text(
		ThemeTokens.font("small"),
		plot.position,
		_label,
		ThemeTokens.font_size("small"),
		color,
		plot.size.x
	)
	var maximum := 1.0
	for value in values:
		var scalar = value.value if value is Dictionary else value
		if scalar != null:
			maximum = maxf(maximum, float(scalar))
	var first_tick := int(values[0].tick) if values[0] is Dictionary else 0
	var last_tick := (
		int(values.back().tick) if values.back() is Dictionary else maxi(1, values.size() - 1)
	)
	var previous := Vector2.ZERO
	for i in values.size():
		var scalar = values[i].value if values[i] is Dictionary else values[i]
		if scalar == null:
			previous = Vector2.ZERO
			continue
		var tick := int(values[i].tick) if values[i] is Dictionary else i
		var point := Vector2(
			(
				plot.position.x
				+ plot.size.x * float(tick - first_tick) / maxi(1, last_tick - first_tick)
			),
			plot.end.y - clampf(float(scalar) / maximum, 0.0, 1.0) * plot.size.y
		)
		if previous != Vector2.ZERO:
			draw_line(previous, point, color, metrics.px(1.0))
		previous = point
	_draw_text(
		ThemeTokens.font("small"),
		plot.end - Vector2(metrics.px(36), -metrics.px(1)),
		"time",
		ThemeTokens.font_size("small"),
		color,
		metrics.px(36)
	)
