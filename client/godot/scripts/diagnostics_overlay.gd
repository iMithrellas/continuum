class_name DiagnosticsOverlay
extends Control

var metrics: UiMetrics = UiMetrics.new()
var show_diagnostics := false
var show_graph := false
var processing_enabled := false
var frame_snapshot: Dictionary = {}
var rtt_snapshot: Dictionary = {}

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

func panel_rect() -> Rect2:
	var inset := metrics.px(8.0)
	var width := minf(metrics.px(260.0 if show_graph else 210.0), maxf(0.0, size.x - inset * 2.0))
	var height := minf(metrics.px(150.0 if show_graph else 70.0), maxf(0.0, size.y - inset * 2.0))
	return Rect2(Vector2(maxf(inset, size.x - width - inset), inset), Vector2(width, height))

func graph_lane_rects() -> Array[Rect2]:
	var panel := panel_rect()
	var graph_top := panel.position.y + metrics.px(72.0)
	var lane_height := maxf(metrics.px(20.0), (panel.size.y - metrics.px(78.0)) / 2.0)
	return [Rect2(panel.position.x, graph_top, panel.size.x, lane_height),
		Rect2(panel.position.x, graph_top + lane_height, panel.size.x, lane_height)]

func _draw() -> void:
	if not show_diagnostics:
		return
	var rect := panel_rect()
	draw_rect(rect, Color("181b1fdd"), true)
	draw_rect(rect, Color("68727add"), false, metrics.px(1.0))
	var font := ThemeDB.fallback_font
	draw_string(font, rect.position + Vector2(metrics.px(8), metrics.px(16)), "DIAGNOSTICS", HORIZONTAL_ALIGNMENT_LEFT, -1, metrics.font(10), Color("b6c0c5"))
	var frame_text := "FPS --  frame-time N/A"
	if frame_snapshot.get("ready", false):
		frame_text = "FPS %.1f  p95 %.2f ms" % [frame_snapshot.mean_fps, frame_snapshot.p95_frame_ms]
	else:
		frame_text = "FPS --  warmup %d/%d" % [frame_snapshot.get("count", 0), frame_snapshot.get("minimum", 0)]
	draw_string(font, rect.position + Vector2(metrics.px(8), metrics.px(33)), frame_text, HORIZONTAL_ALIGNMENT_LEFT, -1, metrics.font(10), Color("d6dadd"))
	var rtt_text := "RTT N/A  packet loss N/A"
	if rtt_snapshot.get("rtt_ms", null) != null:
		rtt_text = "RTT %.1f ms  avg %.1f ms" % [rtt_snapshot.rtt_ms, rtt_snapshot.get("rtt_smoothed_ms", rtt_snapshot.rtt_ms)]
	elif rtt_snapshot.get("rtt_stale", false):
		rtt_text = "RTT N/A (stale)  packet loss N/A"
	draw_string(font, rect.position + Vector2(metrics.px(8), metrics.px(48)), rtt_text, HORIZONTAL_ALIGNMENT_LEFT, -1, metrics.font(10), Color("d6dadd"))
	draw_string(font, rect.position + Vector2(metrics.px(8), metrics.px(63)), "probe timeouts %.0f%%" % (float(rtt_snapshot.get("probe_timeout_ratio", 0.0)) * 100.0) if rtt_snapshot.get("probe_timeout_ratio", null) != null else "probe timeouts N/A", HORIZONTAL_ALIGNMENT_LEFT, -1, metrics.font(9), Color("9ca8ad"))
	if show_graph:
		var lanes := graph_lane_rects()
		_draw_series(lanes[0], frame_snapshot.get("frame_graph_ms", frame_snapshot.get("frame_samples_ms", [])), Color("b07b4f"), "frame-time ms")
		_draw_series(lanes[1], rtt_snapshot.get("rtt_samples_ms", []), Color("7fa6b8"), "RTT ms")

func _draw_series(rect: Rect2, values: Array, color: Color, _label: String) -> void:
	if values.is_empty():
		return
	var plot := Rect2(rect.position + Vector2(metrics.px(8), metrics.px(2)), Vector2(maxf(1.0, rect.size.x - metrics.px(16)), maxf(1.0, rect.size.y - metrics.px(4))))
	draw_string(ThemeDB.fallback_font, plot.position, _label, HORIZONTAL_ALIGNMENT_LEFT, -1, metrics.font(8), color)
	var maximum := 1.0
	for value in values:
		if value != null:
			maximum = maxf(maximum, float(value))
	var previous := Vector2.ZERO
	for i in values.size():
		if values[i] == null:
			previous = Vector2.ZERO
			continue
		var point := Vector2(plot.position.x + plot.size.x * float(i) / maxi(1, values.size() - 1), plot.end.y - clampf(float(values[i]) / maximum, 0.0, 1.0) * plot.size.y)
		if previous != Vector2.ZERO:
			draw_line(previous, point, color, metrics.px(1.0))
		previous = point
