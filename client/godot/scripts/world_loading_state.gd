## Readiness is distinct from bootstrap subscription and local terrain loading.
## Backend adapter explicitly declares generation capability; absent data is not
## treated as legacy unless capability itself is absent.
class_name WorldLoadingState
extends RefCounted

signal changed
signal cancel_requested

var client: Variant
var epoch := 0
var generation := 0
var phase := "Connecting"
var completed := 0
var total := 0
var playable := false
var error := ""
var _bootstrap := false
var _world_ready := false
var _terrain_ready := false


func begin(owner: Variant, session_epoch: int, world_generation: int) -> void:
	client = owner
	epoch = session_epoch
	generation = world_generation
	phase = "Connecting"
	completed = 0
	total = 0
	error = ""
	playable = false
	_bootstrap = false
	_world_ready = false
	_terrain_ready = false
	changed.emit()


func current(owner: Variant, session_epoch: int, world_generation: int) -> bool:
	return (
		client != null
		and client == owner
		and epoch == session_epoch
		and generation == world_generation
	)


func bootstrap_applied(
	owner: Variant, session_epoch: int, world_generation: int, generation_capability: bool
) -> void:
	if not current(owner, session_epoch, world_generation):
		return
	_bootstrap = true
	_world_ready = not generation_capability
	phase = "Waiting for generation state" if generation_capability else "Loading nearby terrain"
	_refresh()


## Normalized backend state, not guessed generated schema properties.
func server_progress(
	owner: Variant,
	session_epoch: int,
	world_generation: int,
	server_phase: String,
	done: int,
	count: int,
	ready: bool,
	failure := ""
) -> void:
	if not current(owner, session_epoch, world_generation):
		return
	completed = maxi(0, done)
	total = maxi(0, count)
	_world_ready = ready and failure.is_empty()
	error = failure
	phase = "Loading nearby terrain" if _world_ready else server_phase
	_refresh()


func terrain_applied(
	owner: Variant, session_epoch: int, world_generation: int, ready: bool
) -> void:
	if not current(owner, session_epoch, world_generation):
		return
	_terrain_ready = ready
	_refresh()


func fail(message: String) -> void:
	error = message
	playable = false
	changed.emit()


func disconnect_current() -> void:
	var owner: Variant = client
	client = null
	playable = false
	phase = "Disconnected"
	if owner != null:
		owner.disconnect_db()
	cancel_requested.emit()
	changed.emit()


func _refresh() -> void:
	playable = _bootstrap and _world_ready and _terrain_ready and error.is_empty()
	if playable:
		phase = "Ready"
	changed.emit()


func progress_fraction() -> float:
	return clampf(float(completed) / total, 0.0, 1.0) if total > 0 else -1.0
