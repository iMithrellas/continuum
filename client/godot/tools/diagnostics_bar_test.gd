extends SceneTree

var failed := false


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	var bar := DiagnosticsBar.new()
	root.add_child(bar)
	bar.configure(true, true)
	_assert(bar.session_rtt_text() == "TCP RTT N/A", "detached session is unavailable")
	for source in ["", "reducer_echo", "http", "websocket"]:
		bar.set_snapshots({}, {"source": source, "rtt_ms": 7.2, "rtt_graph": [7.2, 8.1]})
		_assert(bar.session_rtt_text() == "TCP RTT N/A", "non-TCP sources cannot masquerade as kernel RTT")
	bar.set_snapshots({"ready": true, "mean_fps": 60.0, "p95_frame_ms": 16.7}, {"source": "tcp_info", "rtt_ms": 7.2})
	_assert(bar.session_rtt_text() == "TCP RTT 7.2 ms", "genuine TCP RTT is labeled explicitly")
	_assert("p95" in bar.frame_text(true), "compact frame label retains p95")
	bar.set_snapshots({}, {"source": "tcp_info", "rtt_ms": 7.2, "rtt_stale": true})
	_assert(bar.session_rtt_text() == "TCP RTT N/A", "stale TCP values are unavailable")
	for font_size in [10, 13, 24]:
		bar.apply_metrics(UiMetrics.new(font_size))
		for width in [120, 350, 700]:
			bar.size = Vector2(width, bar.metrics.px(38))
			_assert(bar.panel_rect() == Rect2(Vector2.ZERO, bar.size), "bar uses only parent-local bounds")
			for lane in bar.graph_lane_rects():
				_assert(bar.panel_rect().encloses(lane), "sparkline fits header bounds")
			if width == 120:
				_assert(bar.graph_lane_rects().is_empty(), "small bar hides graphs")
	bar.configure(false, true)
	_assert(not bar.show_graph and not bar.visible and not bar.processing_enabled, "graph remains subordinate to diagnostics")
	_assert(bar.mouse_filter == Control.MOUSE_FILTER_IGNORE, "bar never captures input")
	bar.free()
	if not failed:
		print("DIAGNOSTICS_BAR_PASS")
	quit(1 if failed else 0)


func _assert(condition: bool, message: String) -> void:
	if not condition:
		failed = true
		push_error(message)
