## Headless binding generation.
##
##   godot --headless --path client/godot --script res://tools/generate_bindings.gd
##
## The SpacetimeDB addon's own binding generation lives on its `EditorPlugin`, which
## cannot be instantiated outside the editor, so it is only reachable by clicking
## "Generate" in the editor dock. This script does the same two steps directly:
## fetch each configured module's schema over HTTP, then run `SpacetimeCodegen`,
## so regenerating bindings is a scriptable, reviewable, CI-able command rather
## than a manual click.
##
## Reads `res://spacetime_bindings/plugin_config.tres` for the server URI and the
## module list. Exits 0 on success, 1 on failure.
##
## Nothing here names a `class_name` from the addon at parse time where it can be
## avoided: Godot resolves those through `.godot/global_script_class_cache.cfg`,
## which only an `--import` writes, so the project must be imported once first.
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

	var http := HTTPRequest.new()
	http.timeout = REQUEST_TIMEOUT_SECONDS
	root.add_child(http)
	# One frame so the HTTPRequest is actually inside the tree before it is used.
	await process_frame

	for alias: String in (modules as Dictionary).keys():
		var module: Resource = (modules as Dictionary)[alias]
		var module_name := String(module.get(&"name"))
		# Fetch from an isolated development database without changing the client endpoint.
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

	# The schema is cached back into the config so the editor dock shows the same
	# state a headless run produced.
	ResourceSaver.save(config, CONFIG_PATH)

	print("==> generated %d files" % generated.size())
	quit(0)


func _die(message: String) -> void:
	printerr("generate_bindings: %s" % message)
	quit(1)
