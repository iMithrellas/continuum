extends SceneTree

const Stats = preload("res://scripts/diagnostics_stats.gd")
const Session = preload("res://scripts/session_diagnostics.gd")
const PingTransport = preload("res://scripts/session_ping_transport.gd")
const Overlay = preload("res://scripts/diagnostics_overlay.gd")

class FakeReducers extends RefCounted:
	var calls: Array = []

	func diagnostic_echo(_nonce: int):
		var call := SpacetimeDBReducerCall.new()
		call.request_id = calls.size() + 1
		calls.append(call)
		return call

class FakeClient extends RefCounted:
	signal connected(identity: PackedByteArray, token: String)
	signal disconnected
	var reducers := FakeReducers.new()
	var cancelled: Array[int] = []
	var online := true

	func is_connected_db() -> bool:
		return online

	func cancel_reducer_call(call: SpacetimeDBReducerCall) -> bool:
		cancelled.append(call.request_id)
		return true

func _init() -> void:
	var stats := Stats.new(4, 10_000_000, 3, 100, 2_000_000)
	for tick in [0, 10_000, 30_000, 60_000, 100_000]:
		stats.observe_tick(tick)
	var snap := stats.refresh(100_000, true)
	assert(snap.count == 4 and is_equal_approx(snap.mean_fps, 40.0), "mean FPS uses N/sum intervals")
	assert(is_equal_approx(snap.p50_frame_ms, 20.0) and is_equal_approx(snap.p95_frame_ms, 40.0) and is_equal_approx(snap.p99_frame_ms, 40.0), "nearest-rank percentiles")
	assert(stats.refresh(100_050).count == 4, "refresh is low frequency")
	stats.observe_tick(3_000_000, false)
	stats.observe_tick(3_010_000)
	assert(stats.refresh(3_010_000, true).count == 0, "invalid pause transition is not a frame")
	stats.observe_tick(3_020_000)
	var warmup := stats.refresh(3_020_000, true)
	assert(warmup.count == 1 and warmup.warmup and warmup.p95_frame_ms == null, "resume anchors and exposes warmup")
	var bounded := Stats.new(2, 25_000, 1, 0, 2_000_000)
	for tick in [0, 10_000, 20_000, 30_000, 40_000]:
		bounded.observe_tick(tick)
	var bounded_snapshot := bounded.refresh(40_000, true)
	assert(bounded_snapshot.count == 2 and is_equal_approx(bounded_snapshot.window_age_sec, 0.01), "count and age bounds are enforced")
	var aging := Stats.new(10, 100, 1, 1_000, 2_000_000)
	for tick in [0, 10, 20]:
		aging.observe_tick(tick)
	aging.refresh(20, true)
	assert(aging.refresh(500).count == 0, "refresh trims aged samples before refresh interval")
	aging.observe_tick(600)
	assert(aging.refresh(600, true).count == 1, "long pause reanchors without stale cache")
	aging.observe_tick(550)
	assert(aging.refresh(550, true).count == 0, "backward ticks reset history and do not bridge rewind")

	var sent: Array[int] = []
	var session := Session.new()
	session.configure_probe(func(id: int) -> bool:
		sent.append(id)
		return true)
	session.timeout_usec = 100
	session.freshness_usec = 2_000_000
	session.set_connected(true)
	assert(session.pump(0) and not session.pump(1) and sent.size() == 1, "one probe in flight")
	assert(session.respond(sent[0], 50), "successful response settles")
	session.pump(1_000_000)
	session.advance(1_000_100)
	var network := session.snapshot(1_000_100)
	assert(network.successful == 1 and network.timed_out == 1 and is_equal_approx(network.probe_timeout_ratio, 0.5), "timeouts denominator excludes inflight")
	assert(network.rtt_samples_ms.size() == 2 and network.rtt_samples_ms[1] == null, "timeout is a graph gap, not zero")
	var closed: Array[Dictionary] = []
	session.probe_closed.connect(func(id: int, outcome: String): closed.append({"id": id, "outcome": outcome}))
	assert(not session.respond(sent[1], 1_000_099), "deadline response is not successful")
	assert(closed.is_empty(), "already expired response does not emit a second close")
	assert(session.snapshot(1_000_100).probe_timeout_ratio == 0.5, "expired response remains a timeout")
	assert(session.pump(2_000_000), "one-flight interval permits a later probe")
	session.reject(sent[2], 2_000_001)
	assert(closed.size() == 1 and closed[0].outcome == "rejected", "rejection is a separate settled outcome")
	var stale := session.snapshot(2_000_600)
	assert(stale.rtt_ms == null and stale.rtt_smoothed_ms == null and stale.rtt_stale and stale.rtt_graph.back().value == null, "stale RTT is unavailable with a historical graph gap")
	var stale_again := session.snapshot(2_000_601)
	assert(stale_again.rtt_graph.size() == stale.rtt_graph.size(), "stale transition adds one gap only")
	session.reset()
	assert(not session.respond(sent[1], 300) and session.snapshot(300).rtt_ms == null, "late response after reset is ignored")
	session.set_connected(false)
	session.set_connected(true)
	assert(session.snapshot(301).successful == 0, "disconnect/reconnect resets session samples")
	assert(network.packet_loss == null, "packet loss remains N/A")

	var fake_client := FakeClient.new()
	var transport_session := Session.new()
	var transport := PingTransport.new(fake_client, transport_session)
	assert(transport_session.pump(0), "transport installs an authenticated sender")
	fake_client.reducers.calls[0].on_ok_empty.emit(null)
	var transport_ok := transport_session.snapshot(Time.get_ticks_usec())
	assert(transport_ok.successful == 1 and transport_ok.timed_out == 0, "okEmpty is a successful probe")
	assert(transport_session.pump(1_000_000), "transport remains configured after success")
	fake_client.reducers.calls[1].on_error.emit("missing reducer")
	var transport_error := transport_session.snapshot(Time.get_ticks_usec())
	assert(transport_error.rejected == 1 and transport_error.timed_out == 0, "reducer error is rejected, not timeout")
	assert(fake_client.cancelled == [2], "rejected reducer releases the SDK pending map")
	assert(transport_session.pump(2_000_000), "transport can start another bounded probe")
	transport.dispose()
	assert(fake_client.cancelled == [2, 3], "dispose cancels the in-flight reducer")
	fake_client.reducers.calls.clear()
	transport = null
	transport_session = null
	fake_client = null

	var expiry := Session.new()
	expiry.configure_probe(func(_id: int) -> bool: return true, 10, 1_000, 1)
	expiry.set_connected(true)
	assert(expiry.pump(0), "expiry probe starts")
	assert(not expiry.respond(1, 10), "expired reply is rejected even before advance")
	assert(expiry.snapshot(10).timed_out == 1, "expired reply is counted as timeout")

	var overlay := Overlay.new()
	overlay.configure(false, true)
	assert(not overlay.visible and not overlay.processing_enabled and overlay.mouse_filter == Control.MOUSE_FILTER_IGNORE, "disabled overlay does no work and passes input")
	overlay.configure(true, true)
	overlay.apply_metrics(UiMetrics.new(24))
	overlay.size = Vector2(1000, 500)
	var lanes := overlay.graph_lane_rects()
	var panel := overlay.panel_rect()
	assert(lanes[0].position.y < lanes[1].position.y and lanes[1].end.y <= panel.end.y and lanes[1].end.x <= panel.end.x, "graph uses separate bounded lanes")
	overlay.set_safe_rect(Rect2(20, 15, 300, 200))
	assert(overlay.panel_rect().position.x >= 20.0 and overlay.panel_rect().position.y >= 15.0 and overlay.panel_rect().end.x <= 320.0 and overlay.panel_rect().end.y <= 215.0, "offset safe rect contains panel")
	overlay.apply_metrics(UiMetrics.new(10))
	assert(overlay.show_graph and overlay.metrics.base_font_size == 10, "graph and repeated font scaling follow configuration")
	overlay.size = Vector2(100, 100)
	overlay.apply_metrics(UiMetrics.new(24))
	overlay.set_safe_rect(Rect2(5, 7, 90, 86))
	assert(overlay.graph_lane_rects().is_empty() and overlay.panel_rect().end.x <= 95.0 and overlay.panel_rect().end.y <= 93.0, "tiny viewport collapses graph and clamps panel")
	overlay.free()
	print("DIAGNOSTICS_PASS deterministic stats RTT overlay")
	quit(0)
