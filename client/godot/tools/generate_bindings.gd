## Fetches configured schemas and generates bindings headlessly. Import the
## project first to populate Godot's class cache. Exits 0 on success, 1 on failure.
extends SceneTree

const CONFIG_PATH := "res://spacetime_bindings/plugin_config.tres"
const BINDINGS_SCHEMA_PATH := "res://spacetime_bindings/schema"
const REQUEST_TIMEOUT_SECONDS := 10.0


func _initialize() -> void:
	var config: Resource = ResourceLoader.load(CONFIG_PATH)
	if config == null:
		_die("could not load %s (run `godot --headless --import` once first)" % CONFIG_PATH)
		return

	var modules: Variant = config.get(&"module_configs")
	if typeof(modules) != TYPE_DICTIONARY or (modules as Dictionary).is_empty():
		_die("no modules configured in %s" % CONFIG_PATH)
		return

	var uri := String(config.get(&"uri")).trim_suffix("/")
	for argument: String in OS.get_cmdline_user_args():
		if argument.begins_with("--stdb-host="):
			uri = argument.trim_prefix("--stdb-host=").trim_suffix("/")

	var http := HTTPRequest.new()
	http.timeout = REQUEST_TIMEOUT_SECONDS
	root.add_child(http)
	await process_frame

	for alias: String in (modules as Dictionary).keys():
		var module: Resource = (modules as Dictionary)[alias]
		var module_name := String(module.get(&"name"))
		for argument: String in OS.get_cmdline_user_args():
			if argument.begins_with("--stdb-db="):
				module_name = argument.trim_prefix("--stdb-db=")
		# Schema v10 is what this SDK's parser speaks; SpacetimeDB 2.10 still serves it.
		var url := "%s/v1/database/%s/schema?version=10" % [uri, module_name]
		print("==> fetching schema: %s" % url)

		var error := http.request(url)
		if error != OK:
			_die("could not start request for %s (error %d)" % [module_name, error])
			return
		var result: Array = await http.request_completed
		var status: int = result[1]
		if status != 200:
			_die("schema fetch for '%s' returned HTTP %d - is the module published?"
					% [module_name, status])
			return

		module.set(&"unparsed_module_schema",
				(result[3] as PackedByteArray).get_string_from_utf8())
		print("    ok (%d bytes)" % (result[3] as PackedByteArray).size())

	print("==> generating into %s" % BINDINGS_SCHEMA_PATH)
	var codegen := SpacetimeCodegen.new(BINDINGS_SCHEMA_PATH)
	codegen._plugin_config = config
	var generated: Array[String] = codegen.generate_bindings()
	if generated.is_empty():
		_die("codegen produced no files")
		return
	for generated_path: String in generated:
		var input := FileAccess.open(generated_path, FileAccess.READ)
		if input == null:
			_die("could not read generated file %s" % generated_path)
			return
		var contents := input.get_as_text()
		if input.get_error() != OK and input.get_error() != ERR_FILE_EOF:
			input.close()
			_die("could not read generated contents %s" % generated_path)
			return
		input.close()
		while contents.ends_with("\n"):
			contents = contents.trim_suffix("\n")
		var output := FileAccess.open(generated_path, FileAccess.WRITE)
		if output == null:
			_die("could not normalize generated file %s" % generated_path)
			return
		output.store_string(contents + "\n")
		var write_error := output.get_error()
		output.close()
		if write_error != OK:
			_die("could not write generated file %s" % generated_path)
			return

	var save_error := ResourceSaver.save(config, CONFIG_PATH)
	if save_error != OK:
		_die("could not save cached schema (error %d)" % save_error)
		return

	print("==> generated %d files" % generated.size())
	quit(0)


func _die(message: String) -> void:
	printerr("generate_bindings: %s" % message)
	quit(1)
