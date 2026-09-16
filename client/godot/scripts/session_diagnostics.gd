class_name SessionDiagnostics
extends RefCounted

const DEFAULT_MAX_SAMPLES := 60
const DEFAULT_MAX_AGE_USEC := 30_000_000
const DEFAULT_TIMEOUT_USEC := 3_000_000
const DEFAULT_FRESHNESS_USEC := 10_000_000
const DEFAULT_INTERVAL_USEC := 1_000_000

var sender: Callable
var max_samples := DEFAULT_MAX_SAMPLES
var max_age_usec := DEFAULT_MAX_AGE_USEC
var timeout_usec := DEFAULT_TIMEOUT_USEC
var freshness_usec := DEFAULT_FRESHNESS_USEC
var interval_usec := DEFAULT_INTERVAL_USEC
var connected := false
var _epoch := 0
var _next_id := 1
var _inflight: Dictionary = {}
var _settled: Array[Dictionary] = []
var _last_success_tick := -1
var _last_rtt_ms: Variant = null
var _stale_gap_tick := -1
var _last_started_tick := -1

signal probe_closed(request_id: int, outcome: String)

func configure_probe(send_authenticated_echo: Callable, timeout := DEFAULT_TIMEOUT_USEC,
		freshness := DEFAULT_FRESHNESS_USEC, interval := DEFAULT_INTERVAL_USEC) -> void:
	sender = send_authenticated_echo
	timeout_usec = maxi(1, timeout)
	freshness_usec = maxi(1, freshness)
	interval_usec = maxi(1_000_000, interval)

func set_connected(value: bool, now_usec := -1) -> void:
	if connected != value and not value:
		reset()
	connected = value

func reset() -> void:
	for request_id in _inflight:
		probe_closed.emit(request_id, "cancelled")
	_epoch += 1
	_inflight.clear()
	_settled.clear()
	_last_success_tick = -1
	_last_rtt_ms = null
	_stale_gap_tick = -1
	_last_started_tick = -1

func pump(now_usec: int) -> bool:
	_expire(now_usec)
	if not connected or not _inflight.is_empty() or not sender.is_valid():
		return false
	if _last_started_tick >= 0 and now_usec - _last_started_tick < interval_usec:
		return false
	var id := _next_id
	_next_id += 1
	_inflight[id] = {"epoch": _epoch, "started": now_usec}
	_last_started_tick = now_usec
	var accepted = sender.call(id)
	if accepted is bool and not accepted:
		reject(id)
	return accepted is bool and accepted


func mark_sent(request_id: int, sent_tick_usec: int) -> bool:
	if sent_tick_usec < 0 or not _inflight.has(request_id):
		return false
	var probe: Dictionary = _inflight[request_id]
	probe.started = sent_tick_usec
	_inflight[request_id] = probe
	return true


func respond(request_id: int, response_tick_usec: int, response_epoch := -1) -> bool:
	if response_epoch >= 0 and response_epoch != _epoch:
		return false
	_expire(response_tick_usec)
	if not _inflight.has(request_id):
		return false
	var probe: Dictionary = _inflight[request_id]
	if int(probe.epoch) != _epoch or response_tick_usec < int(probe.started):
		return false
	_inflight.erase(request_id)
	probe_closed.emit(request_id, "success")
	var rtt_usec := response_tick_usec - int(probe.started)
	_record(response_tick_usec, rtt_usec, true)
	_last_success_tick = response_tick_usec
	_last_rtt_ms = float(rtt_usec) / 1000.0
	_stale_gap_tick = -1
	return true

func reject(request_id: int, now_usec := -1) -> bool:
	if not _inflight.has(request_id):
		return false
	_inflight.erase(request_id)
	_record(Time.get_ticks_usec() if now_usec < 0 else now_usec, 0.0, false, "rejected")
	probe_closed.emit(request_id, "rejected")
	return true

func advance(now_usec: int) -> void:
	_expire(now_usec)

func snapshot(now_usec: int) -> Dictionary:
	_expire(now_usec)
	var fresh := _last_success_tick >= 0 and now_usec - _last_success_tick <= freshness_usec and connected
	var timeout_count := 0
	var rejected_count := 0
	var success_count := 0
	var rtts: Array[float] = []
	var graph_values: Array = []
	var graph_points: Array = []
	for sample in _settled:
		if sample.tick < now_usec - max_age_usec:
			continue
		if sample.outcome == "success":
			success_count += 1
			rtts.append(sample.rtt_ms)
			graph_values.append(sample.rtt_ms)
			graph_points.append({"tick": sample.tick, "value": sample.rtt_ms})
		elif sample.outcome == "timeout":
			timeout_count += 1
			graph_values.append(null)
			graph_points.append({"tick": sample.tick, "value": null})
		else:
			rejected_count += 1
	rtts.sort()
	if _last_success_tick >= 0 and not fresh:
		if _stale_gap_tick < 0:
			_stale_gap_tick = now_usec
		graph_values.append(null)
		graph_points.append({"tick": _stale_gap_tick, "value": null})
	var smoothed: Variant = null
	if fresh and not rtts.is_empty():
		var total := 0.0
		for value in rtts:
			total += value
		smoothed = total / rtts.size()
	return {"rtt_ms": _last_rtt_ms if fresh else null, "rtt_smoothed_ms": smoothed,
		"rtt_stale": _last_success_tick >= 0 and not fresh,
		"rtt_samples_ms": graph_values, "successful": success_count, "timed_out": timeout_count,
		"rejected": rejected_count,
		"rtt_graph": graph_points,
		"probe_timeout_ratio": float(timeout_count) / (success_count + timeout_count) if success_count + timeout_count > 0 else null,
		"packet_loss": null, "inflight": not _inflight.is_empty()}

func _expire(now_usec: int) -> void:
	for request_id in _inflight.keys():
		var probe: Dictionary = _inflight[request_id]
		if now_usec - int(probe.started) >= timeout_usec:
			_inflight.erase(request_id)
			_record(now_usec, 0.0, false, "timeout")
			probe_closed.emit(request_id, "timeout")
	while not _settled.is_empty() and (now_usec - int(_settled[0].tick) > max_age_usec or _settled.size() > max_samples):
		_settled.pop_front()

func _record(tick: int, rtt_usec: float, success: bool, outcome := "success") -> void:
	_settled.append({"tick": tick, "success": success, "outcome": outcome, "rtt_ms": rtt_usec / 1000.0})
