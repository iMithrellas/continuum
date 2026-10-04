extends "res://tools/ui_fixture_main.gd"
var fixture_settings_path := "user://terrain_ui_settings_%d.cfg" % Time.get_ticks_usec()


func _ready() -> void:
	var settings := ClientSettings.new()
	settings.native_autostart = false
	settings.save_to(fixture_settings_path)
	super._ready()


func _cli_option(option: String, fallback: String) -> String:
	if option == "--settings-file":
		return fixture_settings_path
	return super._cli_option(option, fallback)
