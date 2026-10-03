## Backend-free contract for generated construction/property rows and reducer calls.
extends SceneTree


class RecordingClient extends SpacetimeDBClient:
	var reducer_name := ""
	var arguments: Array = []
	var argument_types: Array = []

	func call_reducer(p_name: String, args: Array = [], types: Array = []) -> SpacetimeDBReducerCall:
		reducer_name = p_name
		arguments = args
		argument_types = types
		return null


func _initialize() -> void:
	var schema := SpacetimeDBSchema.new("Continuum")
	var client := RecordingClient.new()
	var serializer := BSATNSerializer.new(schema)
	var deserializer := BSATNDeserializer.new(schema, client)
	var kind := ContinuumBuildingKind.create_insulated_room()
	var building := ContinuumBuilding.create(41, kind, 3, 4, -5, 2, 3, 6, 30.0)
	var property := ContinuumBuildingThermalProperty.create(41, 2.0)
	for row: Resource in [building, property]:
		serializer._reset_buffer()
		serializer.write_nested_resource(row)
		assert(not serializer.has_error(), serializer.get_last_error())
		var stream := StreamPeerBuffer.new()
		stream.data_array = serializer._spb.data_array
		stream.big_endian = false
		var type_name: StringName = &"ContinuumBuilding" if row == building else &"ContinuumBuildingThermalProperty"
		var decoded: Resource = deserializer._parse_generic_type(stream, type_name)
		assert(not deserializer.has_error(), deserializer.get_last_error())
		assert(stream.get_position() == stream.data_array.size())
		if row == building:
			var result := decoded as ContinuumBuilding
			assert(result.id == 41 and result.kind.value == kind.value)
			assert(result.x == 3 and result.y == 4 and result.z == -5)
			assert(result.width == 2 and result.depth == 3 and result.clearance_height == 6)
			assert(result.wood_cost == 30.0)
		else:
			var result := decoded as ContinuumBuildingThermalProperty
			assert(result.building_id == 41 and result.thermal_resistance_m_2_k_per_w == 2.0)

	var local_db := LocalDatabase.new(schema, client)
	var db := ContinuumModuleDb.new(local_db)
	assert(db.building.iter().is_empty() and db.building.id.find(41) == null)
	assert(db.building_thermal_property.iter().is_empty())
	assert(db.building_thermal_property.building_id.find(41) == null)
	assert(ContinuumBuilding.primary_key == &"id")
	assert(ContinuumBuildingThermalProperty.primary_key == &"building_id")
	assert(ContinuumBuildingThermalProperty.BSATN_TYPES[&"thermal_resistance_m_2_k_per_w"] == &"F32")
	assert(ContinuumModuleDb.table_names.has("building"))
	assert(ContinuumModuleDb.table_names.has("building_thermal_property"))
	var reducers := ContinuumModuleReducers.new(client)
	reducers.construct_room(1, 2, 3, 4, -5, 6)
	assert(client.reducer_name == "construct_room" and client.arguments == [1, 2, 3, 4, -5, 6])
	assert(client.argument_types == [&"I32", &"I32", &"I32", &"I32", &"I32", &"U16"])
	reducers.demolish_building(41)
	assert(client.reducer_name == "demolish_building" and client.arguments == [41])
	assert(client.argument_types == [&"U64"])
	var storage := ContinuumTileKind.create_storage()
	reducers.designate_zone_at(1, 2, 3, 4, -5, storage)
	assert(client.reducer_name == "designate_zone_at" and client.arguments == [1, 2, 3, 4, -5, storage])
	assert(client.argument_types == [&"I32", &"I32", &"I32", &"I32", &"I32", &"ContinuumTileKind"])
	reducers.clear_zone(7)
	assert(client.reducer_name == "clear_zone" and client.arguments == [7])
	assert(client.argument_types == [&"U32"])
	local_db.free()
	client.free()
	print("BUILDING_PROPERTIES_BINDINGS_PASS: typed BSATN rows, table/index and exact reducer signatures")
	quit(0)
