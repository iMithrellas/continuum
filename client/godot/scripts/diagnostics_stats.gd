class_name DiagnosticsStats
extends RefCounted

const DEFAULT_MAX_SAMPLES := 300
const DEFAULT_MAX_AGE_USEC := 10_000_000
const DEFAULT_MIN_SAMPLES := 10
const DEFAULT_REFRESH_USEC := 250_000
const DEFAULT_MAX_GAP_USEC := 2_000_000

var max_samples: int
var max_age_usec: int
var minimum_samples: int
var refresh_usec: int
var max_gap_usec: int
var _last_tick := -1
var _samples: Array[float] = []
var _sample_ticks: Array[int] = []
var _sorted: Array[float] = []
var _cached: Dictionary = {}
var _last_refresh := -1
var _dirty := true

func _init(sample_limit := DEFAULT_MAX_SAMPLES, age_usec := DEFAULT_MAX_AGE_USEC,
		minimum := DEFAULT_MIN_SAMPLES, refresh_interval_usec := DEFAULT_REFRESH_USEC,
		gap_usec := DEFAULT_MAX_GAP_USEC) -> void:
	max_samples = maxi(1, sample_limit)
	max_age_usec = maxi(1, age_usec)
	minimum_samples = maxi(1, minimum)
	refresh_usec = maxi(0, refresh_interval_usec)
	max_gap_usec = maxi(1, gap_usec)
	reset()

func reset() -> void:
	_last_tick = -1
	_samples.clear()
	_sample_ticks.clear()
	_sorted.clear()
	_cached = _empty_snapshot()
	_last_refresh = -1
	_dirty = true

func observe_tick(ticks_usec: int, valid := true) -> void:
	if not valid or ticks_usec < 0:
		reset()
		return
	if _last_tick < 0:
		_last_tick = ticks_usec
		return
	if ticks_usec <= _last_tick:
		reset()
		_last_tick = ticks_usec
		return
	var interval := ticks_usec - _last_tick
	_last_tick = ticks_usec
	if interval > max_gap_usec:
		_samples.clear()
		_sample_ticks.clear()
		_sorted.clear()
		_dirty = true
		return
	_samples.append(float(interval) / 1_000_000.0)
	_sample_ticks.append(ticks_usec)
	_trim(ticks_usec)
	_dirty = true

func refresh(now_usec: int, force := false) -> Dictionary:
	if _last_refresh >= 0 and now_usec < _last_refresh:
		reset()
	if _trim(now_usec):
		_dirty = true
	if not force and not _dirty and _last_refresh >= 0 and now_usec - _last_refresh < refresh_usec:
		return _cached.duplicate(true)
	_last_refresh = now_usec
	_sorted = _samples.duplicate()
	_sorted.sort()
	_cached = _make_snapshot(now_usec)
	_dirty = false
	return _cached.duplicate(true)

func samples() -> Array[float]:
	return _samples.duplicate()

func _trim(now_usec: int) -> bool:
	var changed := false
	while _samples.size() > max_samples:
		_samples.pop_front()
		_sample_ticks.pop_front()
		changed = true
	while not _sample_ticks.is_empty() and now_usec - _sample_ticks[0] > max_age_usec:
		_samples.pop_front()
		_sample_ticks.pop_front()
		changed = true
	return changed

func _empty_snapshot() -> Dictionary:
	return {"ready": false, "warmup": true, "count": 0, "window_age_sec": 0.0,
		"minimum": minimum_samples,
		"mean_fps": null, "p50_frame_ms": null, "p95_frame_ms": null,
		"p99_frame_ms": null, "frame_samples_ms": [], "frame_graph": []}

func _make_snapshot(now_usec: int) -> Dictionary:
	var count := _sorted.size()
	if count == 0:
		return _empty_snapshot()
	var sum := 0.0
	for interval in _samples:
		sum += interval
	var ready := count >= minimum_samples
	return {"ready": ready, "warmup": not ready, "count": count, "minimum": minimum_samples,
		"window_age_sec": float(now_usec - _sample_ticks[0]) / 1_000_000.0,
		"mean_fps": float(count) / sum if ready and sum > 0.0 else null,
		"p50_frame_ms": _nearest_rank(0.50) if ready else null,
		"p95_frame_ms": _nearest_rank(0.95) if ready else null,
		"p99_frame_ms": _nearest_rank(0.99) if ready else null,
		"frame_samples_ms": _sorted.map(func(value: float) -> float: return value * 1000.0),
		"frame_graph": _frame_graph()}

func _frame_graph() -> Array:
	var result: Array = []
	for i in _samples.size():
		result.append({"tick": _sample_ticks[i], "value": _samples[i] * 1000.0})
	return result

func _nearest_rank(percentile: float) -> float:
	var rank := clampi(ceili(percentile * _sorted.size()), 1, _sorted.size())
	return _sorted[rank - 1] * 1000.0
