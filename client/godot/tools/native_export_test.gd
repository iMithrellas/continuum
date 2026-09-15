extends SceneTree

func _initialize() -> void:
	var native_root := OS.get_environment("CONTINUUM_NATIVE_ROOT")
	if native_root.is_empty():
		printerr("Set an isolated CONTINUUM_NATIVE_ROOT for this packaging test.")
		quit(1)
		return
	var manager = load("res://scripts/native_server_manager.gd").new()
	if manager._module_source() != "res://native/continuum_module.wasm" or not manager.prepare_module():
		printerr("Packaged module could not be staged without a source build.")
		quit(1)
		return
	for extension in ["sh", "ps1"]:
		var staged: String = manager._stage_installer_assets(extension)
		if not staged.is_absolute_path() or not FileAccess.file_exists(staged) or FileAccess.get_sha256(staged) != FileAccess.get_sha256("res://native/install-spacetimedb." + extension):
			printerr("Packaged bootstrap assets did not survive PCK staging: " + extension)
			quit(1)
			return
	print("NATIVE_EXPORT_ASSETS_PASS")
	quit(0)
