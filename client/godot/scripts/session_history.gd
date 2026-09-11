## Bounded, client-local samples from one live connection.
class_name SessionHistory
extends RefCounted

const MAX_POINTS := 240
const SAMPLE_INTERVAL_SECONDS := 60.0

var _points: Array[Dictionary] = []
var _last_game_seconds := -1.0
var _last_generation := -1
var _reset_generation := 0


func reset() -> void:
	_reset_generation += 1
	_points.clear()
	_last_game_seconds = -1.0
	_last_generation = -1


## Returns true only when a new replicated clock sample was accepted.
## A paused clock therefore cannot add duplicate points.
func sample(game_seconds: float, values: Dictionary, generation: int = 0) -> bool:
	# A new colony can restart its clock at the same timestamp as the old one.
	# Reset before applying the interval check so that sample is never carried over.
	if _last_generation >= 0 and generation != _last_generation:
		reset()
	if _last_game_seconds >= 0.0 and game_seconds < _last_game_seconds:
		reset()
	if _last_game_seconds >= 0.0 and game_seconds - _last_game_seconds < SAMPLE_INTERVAL_SECONDS:
		return false
	_last_generation = generation
	_last_game_seconds = game_seconds
	_points.append({"seconds": game_seconds, "values": values.duplicate()})
	if _points.size() > MAX_POINTS:
		_points.pop_front()
	return true


func points() -> Array[Dictionary]:
	return _points.duplicate(true)


func size() -> int:
	return _points.size()
