extends "res://scripts/main.gd"

var diagnostics_settings_path := ""


func _cli_option(option: String, fallback: String) -> String:
	if option == "--settings-file" and not diagnostics_settings_path.is_empty():
		return diagnostics_settings_path
	return super._cli_option(option, fallback)
