extends "res://scripts/main.gd"

# Exercise the real cold-menu lifecycle without reading/writing human settings
# or honoring CLI connection arguments supplied by another test harness.
func _cli_option(option: String, fallback: String) -> String:
	var fixture := "/tmp/opencode/native-controls-%d" % OS.get_process_id()
	if option == "--settings-file": return fixture.path_join("settings.cfg")
	if option == "--workspace-file": return fixture.path_join("workspace.json")
	return fallback

func _has_cli_connection() -> bool:
	return false
