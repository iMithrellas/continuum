## Local fixture session boundary only; production auth/resume checks stay intact.
extends "res://tools/ui_main_fixture.gd"

var fixture_settings_path := ""


func _cli_option(option: String, fallback: String) -> String:
	if option == "--settings-file" and not fixture_settings_path.is_empty():
		return fixture_settings_path
	return super._cli_option(option, fallback)


func _can_resume_colony() -> bool:
	return _state_ready and _session_requested
