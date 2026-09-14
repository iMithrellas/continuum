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

func _draw() -> void:
	if not show_diagnostics:
		return
	var padding := metrics.px(8.0)
	var width := metrics.px(260.0 if show_graph else 210.0)
	var height := metrics.px(96.0 if show_graph else 54.0)
	var rect := Rect2(padding, padding, width, height)
	draw_rect(rect, Color("181b1fdd"), true)
	draw_rect(rect, Color("68727add"), false, metrics.px(1.0))
	var font := ThemeDB.fallback_font
	draw_string(font, rect.position + Vector2(metrics.px(8), metrics.px(16)), "DIAGNOSTICS", HORIZONTAL_ALIGNMENT_LEFT, -1, metrics.font(10), Color("b6c0c5"))
	var frame_text := "FPS --  frame-time N/A"
	if frame_snapshot.get("ready", false):
		frame_text = "FPS %.1f  p95 %.2f ms" % [frame_snapshot.mean_fps, frame_snapshot.p95_frame_ms]
	draw_string(font, rect.position + Vector2(metrics.px(8), metrics.px(33)), frame_text, HORIZONTAL_ALIGNMENT_LEFT, -1, metrics.font(10), Color("d6dadd"))
	var rtt_text := "RTT N/A  packet loss N/A"
	if rtt_snapshot.get("rtt_ms", null) != null:
		rtt_text = "RTT %.1f ms  packet loss N/A" % rtt_snapshot.rtt_ms
	draw_string(font, rect.position + Vector2(metrics.px(8), metrics.px(48)), rtt_text, HORIZONTAL_ALIGNMENT_LEFT, -1, metrics.font(10), Color("d6dadd"))
	if show_graph:
		_draw_series(rect, frame_snapshot.get("frame_samples_ms", []), Color("b07b4f"), "frame-time ms")
		_draw_series(rect, rtt_snapshot.get("rtt_samples_ms", []), Color("7fa6b8"), "RTT ms")

func _draw_series(rect: Rect2, values: Array, color: Color, _label: String) -> void:
	if values.is_empty():
		return
	var plot := Rect2(rect.position + Vector2(metrics.px(8), metrics.px(56)), Vector2(rect.size.x - metrics.px(16), rect.size.y - metrics.px(64)))
	draw_string(ThemeDB.fallback_font, plot.position, _label, HORIZONTAL_ALIGNMENT_LEFT, -1, metrics.font(8), color)
	var previous := Vector2.ZERO
	for i in values.size():
		if values[i] == null:
			previous = Vector2.ZERO
			continue
		var point := Vector2(plot.position.x + plot.size.x * float(i) / maxi(1, values.size() - 1), plot.end.y - clampf(float(values[i]) / 100.0, 0.0, 1.0) * plot.size.y)
		if previous != Vector2.ZERO:
			draw_line(previous, point, color, metrics.px(1.0))
		previous = point
