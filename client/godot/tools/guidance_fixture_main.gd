## Exercise the production controller without touching native processes or files.
extends "res://scripts/main.gd"

var fixture_root := "user://guidance_%d" % Time.get_ticks_usec()

func _setup_native_controller() -> void:
	pass

func _cli_option(option: String, fallback: String) -> String:
	if option == "--settings-file": return fixture_root + ".cfg"
	if option == "--workspace-file": return fixture_root + ".workspace.json"
	return fallback

func _has_cli_connection() -> bool:
	return false
