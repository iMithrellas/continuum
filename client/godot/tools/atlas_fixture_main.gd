## Local fixture session boundary only; production auth/resume checks stay intact.
extends "res://tools/ui_main_fixture.gd"


func _can_resume_colony() -> bool:
	return _state_ready and _session_requested
