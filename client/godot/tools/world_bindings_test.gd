## Production world schema: real BSATN bytes, table lookups and reducer contracts.
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


var schema: SpacetimeDBSchema
var client: RecordingClient
var serializer: BSATNSerializer
var deserializer: BSATNDeserializer


func insert(local: LocalDatabase, table: String, row: Resource) -> void:
	var update := TableUpdateData.new()
	update.table_name = table
	update.inserts = [row]
	local.emit_db_callbacks([local.apply_table_update(update)])


func roundtrip(row: Resource) -> Resource:
	serializer._reset_buffer()
	serializer.write_nested_resource(row)
	if serializer.has_error():
		push_error(serializer.get_last_error())
		quit(1)
		return null
	var stream := StreamPeerBuffer.new()
	stream.big_endian = false
	stream.data_array = serializer._spb.data_array
	var decoded: Resource = deserializer._parse_generic_type(
		stream, row.get_script().get_global_name()
	)
	assert(not deserializer.has_error(), deserializer.get_last_error())
	assert(stream.get_position() == stream.data_array.size())
	for field: StringName in row.BSATN_TYPES:
		if row.get(field) is RustEnum:
			assert(decoded.get(field).value == row.get(field).value)
		else:
			assert(decoded.get(field) == row.get(field), "roundtrip field: %s" % field)
	return decoded


func _initialize() -> void:
	schema = SpacetimeDBSchema.new("Continuum")
	client = RecordingClient.new()
	serializer = BSATNSerializer.new(schema)
	deserializer = BSATNDeserializer.new(schema, client)
	assert(not schema.module_types.has(&"ContinuumOwnRole"))
	assert(schema.get_type_of_table_name(&"my_role") == &"ContinuumMembership")
	assert(
		not FileAccess.file_exists("res://spacetime_bindings/schema/types/continuum_own_role.gd")
	)
	assert(
		not FileAccess.file_exists(
			"res://spacetime_bindings/schema/types/continuum_own_role.gd.uid"
		)
	)
	var phases := ["preparing", "terrain", "overview", "validating", "founding", "ready", "failed"]
	for ordinal in range(7):
		assert(ContinuumGenerationPhase.parse_enum_name(ordinal) == phases[ordinal])
		var row := ContinuumWorldGeneration.create(
			0,
			0x100000002,
			1,
			1,
			0x100000003,
			2048,
			2048,
			-16,
			15,
			1012,
			1012,
			ContinuumGenerationPhase.create(ordinal),
			4096,
			4096,
			0x100000001,
			0x200000002,
			ordinal == 5,
			"failure" if ordinal == 6 else ""
		)
		roundtrip(row)
		assert(serializer._spb.data_array.decode_u64(20) == row.seed)
		assert(serializer._spb.data_array[52] == ordinal)
	var base: Array[int] = []
	var ecology := PackedByteArray()
	for i in range(1024):
		base.append(-16 if i % 2 == 0 else 15)
		ecology.append(i % 256)
	var source := ContinuumTerrainColumnChunk.create(
		0x3f0000003f, 63, 63, 0x100000002, 0, base, ecology, ecology, ecology, ecology
	)
	var decoded_source := roundtrip(source) as ContinuumTerrainColumnChunk
	assert(decoded_source.base_z.size() == 1024 and decoded_source.base_z[0] == -16)
	assert(serializer._spb.data_array.size() == 6192)
	assert(ContinuumTerrainColumnChunk.BSATN_TYPES[&"base_z"] == &"vec_I16")
	assert(ContinuumTerrainColumnChunk.BSATN_TYPES[&"moisture"] == &"vec_U8")
	var surfaces: Array[int] = []
	var materials: Array[int] = []
	var overview_ecology := PackedByteArray()
	for i in range(256):
		surfaces.append(-17 if i == 0 else -1)
		materials.append(0 if i == 0 else 65535)
		overview_ecology.append(i)
	var overviews: Array[ContinuumTerrainOverviewChunk] = []
	for lod in [3, 5, 7, 9]:
		var packed_id: int = (lod << 56) | (15 << 48) | (3 << 24) | 2
		var row := ContinuumTerrainOverviewChunk.create(
			packed_id,
			source.generation_id,
			7,
			lod,
			-1,
			2,
			3,
			surfaces,
			materials,
			overview_ecology,
			overview_ecology,
			overview_ecology
		)
		overviews.append(roundtrip(row))
		assert(serializer._spb.data_array.size() == 1845)
	assert(ContinuumTerrainOverviewChunk.BSATN_TYPES[&"surface_z"] == &"vec_I16")
	assert(ContinuumTerrainOverviewChunk.BSATN_TYPES[&"material"] == &"vec_U16")
	var voxels: Array[int] = []
	voxels.resize(4096)
	voxels.fill(0)
	voxels[4095] = 65535
	var edit := ContinuumTerrainChunk.create(0x100000003, 64, 64, -1, voxels, 9)
	roundtrip(edit)
	assert(serializer._spb.data_array.size() == 8220)
	var local := LocalDatabase.new(schema, client)
	var db := ContinuumModuleDb.new(local)
	insert(local, "terrain_column_chunk", decoded_source)
	insert(local, "terrain_chunk", edit)
	for row in overviews:
		insert(local, "terrain_overview_chunk", row)
	assert(db.terrain_column_chunk.id.find(source.id) == decoded_source)
	assert(db.terrain_column_chunk.iter().size() == 1)
	assert(db.terrain_overview_chunk.iter().size() == 4)
	assert(db.terrain_overview_chunk.id.find(overviews[0].id) == overviews[0])
	assert(db.terrain_chunk.id.find(edit.id).materials[0] == 0)
	assert(db.terrain_chunk.id.find(edit.id).materials[4095] == 65535)
	assert(db.world_generation.id.find(0) == null)
	var status := ContinuumWorldGeneration.create(
		0,
		1,
		1,
		1,
		123,
		2048,
		2048,
		-16,
		15,
		1012,
		1012,
		ContinuumGenerationPhase.create_ready(),
		4096,
		4096,
		4096,
		4096,
		true,
		""
	)
	insert(local, "world_generation", roundtrip(status))
	assert(db.world_generation.id.find(0).ready and db.world_generation.iter().size() == 1)
	var reducers := ContinuumModuleReducers.new(client)
	reducers.reset_world_large(2048, 2048, 0x100000003)
	var reset_bytes := serializer._serialize_arguments(client.arguments, client.argument_types)
	assert(not serializer.has_error() and reset_bytes.size() == 16)
	assert(reset_bytes.decode_s32(0) == 2048 and reset_bytes.decode_s32(4) == 2048)
	assert(reset_bytes.decode_u64(8) == 0x100000003)
	reducers.reset_world_large(2048, 2048, -9223372036854775807)
	assert(client.reducer_name == "reset_world_large")
	assert(client.arguments == [2048, 2048, -9223372036854775807])
	assert(client.argument_types == [&"I32", &"I32", &"U64"])
	reducers.retry_world_generation()
	assert(client.reducer_name == "retry_world_generation")
	assert(client.arguments.is_empty() and client.argument_types.is_empty())
	assert(serializer._serialize_arguments(client.arguments, client.argument_types).is_empty())
	assert(not serializer.has_error())
	for method: Dictionary in reducers.get_method_list():
		assert(not String(method.name).begins_with("generation_test_"))
	print(
		"WORLD_BINDINGS_BASE_PASS: enum0..6, arrays, complete edits, table/index/reducer contracts"
	)
	status.seed = -9223372036854775807
	if roundtrip(status) == null:
		local.free()
		client.free()
		return
	reducers.reset_world_large(2048, 2048, status.seed)
	reset_bytes = serializer._serialize_arguments(client.arguments, client.argument_types)
	assert(not serializer.has_error() and reset_bytes.size() == 16)
	assert(reset_bytes.decode_u64(8) == status.seed)
	local.free()
	client.free()
	print(
		"WORLD_BINDINGS_PASS: production BSATN, enum0..6, signed u64, arrays, complete edits, typed indexes and reducers; Membership owns my_role"
	)
	quit(0)
