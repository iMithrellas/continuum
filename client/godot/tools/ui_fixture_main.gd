extends "res://scripts/main.gd"

const FixtureAccess = preload("res://tools/ui_fixture_access.gd")
var fixture_access: FixtureAccess
var fixture_workspace_path := "user://map_ui_test_%d.json" % Time.get_ticks_usec()

func _cli_option(option: String, fallback: String) -> String:
	if option == "--workspace-file":
		return fixture_workspace_path
	return super._cli_option(option, fallback)

func _create_access(_client: ContinuumModuleClient) -> ContinuumAccess:
	fixture_access = FixtureAccess.new(_client)
	return fixture_access
