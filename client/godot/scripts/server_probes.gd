## Bounded HTTP health probes. The transport is injected and must never create a subscription.
class_name ContinuumServerProbes
extends RefCounted

signal probe_started(key: String)
signal probe_finished(key: String, result: Dictionary)

const MAX_CONCURRENT := 4
const TIMEOUT_SECONDS := 3.0
const REFRESH_SECONDS := 10.0
const BACKOFF_CAP_SECONDS := 60.0

var transport: Callable
var visible := false
var _active: Dictionary = {}
var _state: Dictionary = {}
var _epoch := 0
var _next_attempt := 0

func set_visible(value: bool) -> void:
	visible = value
	if not visible:
		_epoch += 1
		_active.clear()

## A visible owner calls this from its process loop; hidden views must not call it.
func refresh(entries: Array[Dictionary], now := -1.0) -> void:
	if not visible: return
	var current := now if now >= 0 else Time.get_ticks_msec() / 1000.0
	for entry in entries:
		if _active.size() >= MAX_CONCURRENT: break
		var key: String = entry.get("key", "")
		var state: Dictionary = _state.get(key, {"status": "unknown", "failures": 0, "next": 0.0})
		if key.is_empty() or _active.has(key) or current < float(state.next): continue
		_next_attempt += 1
		var attempt := _next_attempt
		_active[key] = {"started": current, "entry": entry, "epoch": _epoch, "attempt": attempt}
		state.status = "checking"; _state[key] = state
		probe_started.emit(key)
		if transport.is_valid(): transport.call(entry, Callable(self, "_transport_complete").bind(key, _epoch, attempt))

func process(now := -1.0) -> void:
	var current := now if now >= 0 else Time.get_ticks_msec() / 1000.0
	for key in _active.keys():
		if current - float(_active[key].started) >= TIMEOUT_SECONDS:
			complete(key, {"reachable": false, "error": "timeout"}, current)

func complete(key: String, result: Dictionary, now := -1.0, epoch := -1, attempt := -1) -> void:
	if not _active.has(key): return
	if epoch >= 0 and (_active[key].epoch != epoch or _active[key].attempt != attempt): return
	var current := now if now >= 0 else Time.get_ticks_msec() / 1000.0
	var state: Dictionary = _state.get(key, {})
	var reachable := bool(result.get("reachable", false))
	state.status = "online" if reachable else "unreachable"
	state.last_sample = current
	state.rtt_ms = result.get("rtt_ms", -1)
	state.joinable = result.get("joinable", null)
	state.auth = result.get("auth", "unknown")
	state.failures = 0 if reachable else int(state.get("failures", 0)) + 1
	state.next = current + (REFRESH_SECONDS if reachable else min(BACKOFF_CAP_SECONDS, pow(2.0, state.failures)))
	_active.erase(key); _state[key] = state
	probe_finished.emit(key, state.duplicate(true))

func _transport_complete(result: Dictionary, key: String, epoch: int, attempt: int) -> void:
	complete(key, result, -1.0, epoch, attempt)

func state(key: String, now := -1.0) -> Dictionary:
	var result: Dictionary = _state.get(key, {"status": "unknown"}).duplicate(true)
	if result.has("last_sample"):
		var current := now if now >= 0 else Time.get_ticks_msec() / 1000.0
		result["stale"] = current - float(result.last_sample) > REFRESH_SECONDS
	return result
