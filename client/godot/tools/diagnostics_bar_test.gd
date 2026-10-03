extends SceneTree

var failed := false

class RecordingBar extends DiagnosticsBar:
	var drawn_text: Array[String] = []
	var drawn_series: Array = []
	var drawn_widths: Array[float] = []

	func _draw_line(font: Font, point: Vector2, text: String, font_size: int, width: float) -> bool:
		var rendered := super._draw_line(font, point, text, font_size, width)
		if rendered:
			drawn_text.append(text)
			drawn_widths.append(font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size).x)
		return rendered

	func _draw_sparkline(_rect: Rect2, values: Array, _color: Color) -> void:
		drawn_series.append(values)


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	var bar := RecordingBar.new()
	root.add_child(bar)
	bar.configure(true, true)
	_assert(bar.session_rtt_text() == "Session RTT N/A", "detached session is unavailable")
	var session := SessionDiagnostics.new()
	var sent: Array[int] = []
	session.configure_probe(func(id: int) -> bool:
		sent.append(id)
		return true)
	session.set_connected(true)
	var stats := DiagnosticsStats.new()
	bar.set_snapshots(stats.refresh(0, true), session.snapshot(0))
	_assert(bar.frame_text() == "FPS --  p95 N/A", "real frame warmup stays unavailable")
	_assert(DiagnosticsOverlay.session_summary_lines(session.snapshot(0)) == ["Session echo RTT: unavailable", "probe timeouts N/A", "Packet loss: unavailable"], "warmup summary distinguishes unavailable measurements")
	_assert(session.pump(0) and session.mark_sent(sent[0], 100), "real sampler starts an echo with transport send timestamp")
	_assert(session.respond(sent[0], 7_300), "real sampler settles an acknowledged 7.2 ms echo")
	_assert(session.pump(1_000_000) and session.respond(sent[1], 1_008_100), "second real echo supplies a line segment")
	var snapshot := session.snapshot(1_008_100)
	_assert(not snapshot.has("source"), "production sampler has no synthetic TCP source")
	bar.set_snapshots({"ready": true, "mean_fps": 60.0, "p95_frame_ms": 16.7}, snapshot)
	_assert(bar.session_rtt_text() == "Session RTT 8.1 ms", "real echo is visible and labeled as session RTT")
	_assert(bar.session_rtt_text(true) == "Echo 8 ms", "compact label identifies the echo and retains units")
	bar.size = Vector2(700, 38)
	await process_frame
	await process_frame
	_assert("Session RTT 8.1 ms" in bar.drawn_text, "actual draw path receives the real sampler readout")
	_assert(snapshot.rtt_graph in bar.drawn_series and snapshot.rtt_graph.size() == 2, "actual draw path receives the real sampler RTT sparkline")
	var overlay := DiagnosticsOverlay.new()
	overlay.set_snapshots({}, snapshot)
	_assert(overlay.session_rtt_text() == bar.session_rtt_text() and overlay.session_rtt_graph() == snapshot.rtt_graph, "older overlay shares real session formatting and graph")
	_assert(DiagnosticsOverlay.session_summary_lines(snapshot) == ["Session echo RTT ms: 8.10", "probe timeouts 0%", "Packet loss: unavailable"], "developer summary reports echo RTT without inventing packet loss")
	var untrusted := snapshot.duplicate(true)
	untrusted["headers"] = "secret-header"
	untrusted["token"] = "secret-token"
	untrusted["packet_loss"] = 0.5
	_assert(DiagnosticsOverlay.session_summary_lines(untrusted) == DiagnosticsOverlay.session_summary_lines(snapshot), "summary allowlist excludes credentials and unsupported packet-loss claims")
	_assert("p95" in bar.frame_text(true), "compact frame label retains p95")
	_assert(session.pump(2_000_000), "timeout probe starts")
	snapshot = session.snapshot(5_000_000)
	_assert(session.pump(5_000_000) and session.reject(sent.back(), 5_000_001), "rejected probe is not a timeout")
	snapshot = session.snapshot(5_000_001)
	bar.set_snapshots({}, snapshot)
	_assert(DiagnosticsOverlay.probe_timeout_text(snapshot) == "probe timeouts 33%", "timeout denominator counts two successes and one timeout, excluding rejection")
	_assert(bar.session_rtt_graph().back().value == null and snapshot.packet_loss == null, "timeout is a graph gap, never packet loss or zero RTT")
	snapshot = session.snapshot(12_000_000)
	bar.set_snapshots({}, snapshot)
	_assert(bar.session_rtt_text() == "Session RTT N/A" and bar.session_rtt_graph().back().value == null, "stale RTT is unavailable while historical graph preserves its gap")
	_assert(DiagnosticsOverlay.session_summary_lines(snapshot)[0] == "Session echo RTT: unavailable", "stale summary cannot publish old latency")
	session.set_connected(false)
	bar.set_snapshots({}, session.snapshot(12_000_001))
	_assert(bar.session_rtt_text() == "Session RTT N/A" and bar.session_rtt_graph().is_empty(), "disconnect clears latency and sparkline")
	for latency in [NAN, INF, -1.0]:
		bar.set_snapshots({}, {"rtt_ms": latency})
		_assert(bar.session_rtt_text() == "Session RTT N/A", "invalid RTT cannot appear as a measurement")
	overlay.free()
	await _check_readout_fit(bar)
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
	bar.set_snapshots({}, {})
	_assert(not bar.show_graph and not bar.visible and not bar.processing_enabled, "graph remains subordinate to diagnostics")
	bar.configure(true, true)
	_assert(bar.session_rtt_text() == "Session RTT N/A" and bar.session_rtt_graph().is_empty(), "disabled reset cannot revive previous RTT or graph")
	_assert(bar.mouse_filter == Control.MOUSE_FILTER_IGNORE, "bar never captures input")
	bar.free()
	if not failed:
		print("DIAGNOSTICS_BAR_PASS")
	quit(1 if failed else 0)


func _check_readout_fit(bar: RecordingBar) -> void:
	var session := SessionDiagnostics.new()
	var sent: Array[int] = []
	session.configure_probe(func(id: int) -> bool:
		sent.append(id)
		return true, 60_000_000)
	session.set_connected(true)
	var stats := DiagnosticsStats.new()
	var cases: Array[Dictionary] = [{"snapshot": session.snapshot(0), "compact": "Echo N/A", "full": "Session RTT N/A"}]
	for milliseconds in [100.0, 999.0, 1000.0, 2500.0, 25_000.0]:
		session.reset()
		_assert(session.pump(0) and session.respond(sent.back(), int(milliseconds * 1000)), "fit fixture uses settled real echo samples")
		cases.append({"snapshot": session.snapshot(int(milliseconds * 1000)),
			"compact": "Echo %.0f ms" % milliseconds if milliseconds < 1000 else "Echo %.1f s" % (milliseconds / 1000),
			"full": "Session RTT %.1f ms" % milliseconds})
	var maximum_compact := 0.0
	var maximum_full := 0.0
	var maximum_narrow := 0.0
	for font_size in [10, 13, 24]:
		bar.apply_metrics(UiMetrics.new(font_size))
		for width in [100, 120, 700]:
			bar.size = Vector2(width, bar.metrics.px(38))
			for test_case in cases:
				bar.drawn_text.clear()
				bar.drawn_widths.clear()
				bar.set_snapshots(stats.refresh(0, true), test_case.snapshot)
				await process_frame
				await process_frame
				var font := ThemeTokens.font("readout")
				var available: float = width - bar.metrics.px(6) - (bar.metrics.px(77) if not bar.graph_lane_rects().is_empty() else 0.0)
				var full_width := font.get_string_size(test_case.full, HORIZONTAL_ALIGNMENT_LEFT, -1, ThemeTokens.font_size("readout")).x
				var expected: String = test_case.full if full_width <= available else test_case.compact
				_assert(expected in bar.drawn_text, "production fit guard draws %s at width %d / metrics %d" % [expected, width, font_size])
				_assert(bar.drawn_text.any(func(text: String) -> bool: return text.begins_with("FPS --")), "frame warmup remains visibly unavailable at every width")
				var index := bar.drawn_text.find(expected)
				if index >= 0:
					if width == 120:
						maximum_narrow = maxf(maximum_narrow, bar.drawn_widths[index])
					if expected == test_case.compact:
						maximum_compact = maxf(maximum_compact, bar.drawn_widths[index])
					else:
						maximum_full = maxf(maximum_full, bar.drawn_widths[index])
	print("DIAGNOSTICS_RTT_FIT compact_max=%.2f full_max=%.2f narrow_max=%.2f production_available=114.00" % [maximum_compact, maximum_full, maximum_narrow])


func _assert(condition: bool, message: String) -> void:
	if not condition:
		failed = true
		push_error(message)
