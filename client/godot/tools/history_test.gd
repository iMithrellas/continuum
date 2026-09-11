## Deterministic unit check for the client-only session history buffer.
extends SceneTree

const History = preload("res://scripts/session_history.gd")


func _init() -> void:
	var history = History.new()
	assert(history.sample(10.0, {"food": 4.0, "mood": 60.0}))
	assert(not history.sample(10.0, {"food": 5.0, "mood": 61.0}))
	assert(not history.sample(50.0, {"food": 5.0, "mood": 61.0}))
	assert(history.sample(70.0, {"food": 5.0, "mood": 62.0}))
	assert(history.size() == 2)
	assert(is_equal_approx(history.points()[1]["values"]["food"], 5.0))
	history.reset()
	assert(history.size() == 0)
	assert(history.sample(2.0, {"mood": 33.0, "productivity": 81.0}))
	for index in 360:
		history.sample(62.0 + index * 60.0, {"mood": index, "productivity": 100.0 - index})
	assert(history.size() == History.MAX_POINTS)
	assert(history.points()[0]["seconds"] > 62.0)
	history.sample(1.0, {"mood": 10.0})
	assert(history.size() == 1)
	print("HISTORY_PASS cap duplicate pause reset selected-values rewind")
	quit(0)
