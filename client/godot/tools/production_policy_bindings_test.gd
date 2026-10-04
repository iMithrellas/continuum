## Backend-free contract for schema-generated policy rows, indexes and reducer arguments.
## Run after headless import with --script res://tools/production_policy_bindings_test.gd.
extends SceneTree


class RecordingClient:
	extends SpacetimeDBClient
	var reducer_name := ""
	var arguments: Array = []
	var argument_types: Array = []

	func call_reducer(
		p_name: String, args: Array = [], types: Array = []
	) -> SpacetimeDBReducerCall:
		reducer_name = p_name
		arguments = args
		argument_types = types
		return null


func _initialize() -> void:
	var schema := SpacetimeDBSchema.new("Continuum")
	var client := RecordingClient.new()
	var serializer := BSATNSerializer.new(schema)
	var deserializer := BSATNDeserializer.new(schema, client)
	for kind: int in ContinuumResourceKind.Options.values():
		var row := ContinuumProductionPolicy.create(ContinuumResourceKind.create(kind), 123.25)
		serializer._reset_buffer()
		serializer.write_nested_resource(row)
		assert(not serializer.has_error(), serializer.get_last_error())
		var bytes: PackedByteArray = serializer._spb.data_array
		assert(bytes.size() == 5, "ResourceKind tag plus f32 must occupy five bytes")
		var stream := StreamPeerBuffer.new()
		stream.data_array = bytes
		stream.big_endian = false
		var decoded: ContinuumProductionPolicy = deserializer._parse_generic_type(
			stream, &"ContinuumProductionPolicy"
		)
		assert(not deserializer.has_error(), deserializer.get_last_error())
		assert(decoded.resource.value == kind and decoded.target == row.target)
		assert(stream.get_position() == bytes.size())

	var local_db := LocalDatabase.new(schema, client)
	var db := ContinuumModuleDb.new(local_db)
	var table: ContinuumProductionPolicyTable = db.production_policy
	var index: ContinuumProductionPolicyResourceUniqueIndex = table.resource
	assert(table.iter().is_empty())
	assert(index.find(ContinuumResourceKind.create_wood()) == null)
	assert(ContinuumProductionPolicy.primary_key == &"resource")
	assert(ContinuumProductionPolicy.BSATN_TYPES[&"target"] == &"F32")
	assert(ContinuumModuleDb.table_names.has("production_policy"))

	var resource := ContinuumResourceKind.create_wood()
	var reducers := ContinuumModuleReducers.new(client)
	reducers.set_production_policy(resource, 42.5)
	assert(client.reducer_name == "set_production_policy")
	assert(client.arguments == [resource, 42.5])
	assert(client.argument_types == [&"ContinuumResourceKind", &"F32"])
	reducers.remove_production_policy(resource)
	assert(client.reducer_name == "remove_production_policy")
	assert(client.arguments == [resource])
	assert(client.argument_types == [&"ContinuumResourceKind"])
	local_db.free()
	client.free()
	print("PRODUCTION_POLICY_BINDINGS_PASS: typed BSATN roundtrip, table/index, reducer signatures")
	quit(0)
