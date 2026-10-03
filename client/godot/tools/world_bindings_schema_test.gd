## Verify the cached production schema; optionally refresh it from an explicit private endpoint.
## Codegen consumes unparsed_module_schema and its parsed Resource is not exported,
## so --cache-schema restores the exact fetched JSON after running generate_bindings.gd.
extends SceneTree

const CONFIG := "res://spacetime_bindings/plugin_config.tres"

func _initialize() -> void:
	call_deferred("run")

func run() -> void:
	var config: Resource = load(CONFIG)
	var module: Resource = config.module_configs["Continuum"]
	var host := ""
	var database := ""
	for argument in OS.get_cmdline_user_args():
		if argument.begins_with("--stdb-host="):
			host = argument.trim_prefix("--stdb-host=").trim_suffix("/")
		if argument.begins_with("--stdb-db="):
			database = argument.trim_prefix("--stdb-db=")
	if OS.get_cmdline_user_args().has("--cache-schema"):
		assert(not host.is_empty() and not database.is_empty(), "explicit private host/db required")
		var request := HTTPRequest.new()
		root.add_child(request)
		request.timeout = 10
		assert(request.request("%s/v1/database/%s/schema?version=10" % [host, database]) == OK)
		var response: Array = await request.request_completed
		assert(response[1] == 200)
		module.unparsed_module_schema = (response[3] as PackedByteArray).get_string_from_utf8()
		request.queue_free()
	var parsed: Dictionary = JSON.parse_string(module.unparsed_module_schema)
	assert(parsed.has("sections"), "production schema must survive editor imports")
	var tables := {}
	var reducers := {}
	var views := {}
	for section: Dictionary in parsed.sections:
		for type: Dictionary in section.get("Types", []):
			assert(type.source_name.source_name != "OwnRole")
		for table: Dictionary in section.get("Tables", []):
			tables[table.source_name] = table
		for reducer: Dictionary in section.get("Reducers", []):
			reducers[reducer.source_name] = reducer
			assert(not String(reducer.source_name).begins_with("generation_test_"))
		for view: Dictionary in section.get("Views", []):
			views[view.source_name] = view
	for spec in [["terrain_column_chunk", "by_xy", [1, 2]],
		["terrain_overview_chunk", "by_view", [3, 4, 5, 6]],
		["terrain_chunk", "by_xyz", [1, 2, 3]]]:
		var found := false
		for index: Dictionary in tables[spec[0]].indexes:
			if index.accessor_name.some == spec[1]:
				assert(index.algorithm.BTree.map(func(value: Variant) -> int: return int(value)) == spec[2])
				found = true
		assert(found, "backend spatial index missing: %s" % spec[1])
	assert(reducers.reset_world_large.params.elements.size() == 3)
	assert(reducers.retry_world_generation.params.elements.is_empty())
	assert(views.has("my_role"))
	assert(views.my_role.return_type.Sum.variants[0].algebraic_type.Ref == tables.membership.product_type_ref)
	var schema := SpacetimeDBSchema.new("Continuum")
	assert(schema.get_type_of_table_name(&"my_role") == &"ContinuumMembership")
	assert(not schema.module_types.has(&"ContinuumOwnRole"))
	if OS.get_cmdline_user_args().has("--cache-schema"):
		assert(ResourceSaver.save(config, CONFIG) == OK)
	print("WORLD_BINDINGS_SCHEMA_PASS: production schema cache, backend XY/view/XYZ indexes and Membership view mapping")
	quit(0)
