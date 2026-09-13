extends "res://scripts/main.gd"

const FixtureAccess = preload("res://tools/ui_fixture_access.gd")
var fixture_access: FixtureAccess

func _create_access(_client: ContinuumModuleClient) -> ContinuumAccess:
	fixture_access = FixtureAccess.new(_client)
	return fixture_access
