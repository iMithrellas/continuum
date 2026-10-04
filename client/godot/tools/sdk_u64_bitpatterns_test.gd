## Full-bit-pattern U64 contract through real primitive/generated BSATN paths.
extends SceneTree

const MIN_I64: int = -9223372036854775807 - 1
const CASES := [
	[0, "0000000000000000"],
	[9223372036854775807, "ffffffffffffff7f"],
	[MIN_I64, "0000000000000080"],
	[-1, "ffffffffffffffff"],
	[MIN_I64 | 0x0123456789abcdef, "efcdab8967452381"],
]


class RecordingClient:
	extends SpacetimeDBClient
	var arguments: Array = []
	var types: Array = []

	func call_reducer(
		name: String, args: Array = [], arg_types: Array = []
	) -> SpacetimeDBReducerCall:
		assert(name == "reset_world_large")
		arguments = args
		types = arg_types
		return null


var writer: BSATNSerializer
var reader: BSATNDeserializer


func _initialize() -> void:
	var schema := SpacetimeDBSchema.new("Continuum")
	var client := RecordingClient.new()
	writer = BSATNSerializer.new(schema)
	reader = BSATNDeserializer.new(schema, client)
	var reducers := ContinuumModuleReducers.new(client)
	for boundary: Array in CASES:
		var bits: int = boundary[0]
		var expected: PackedByteArray = boundary[1].hex_decode()
		assert(reader.read_u64_le(_stream(expected)) == bits)
		assert(not reader.has_error())
		_reset()
		writer.write_u64_le(bits)
		assert(not writer.has_error() and writer._spb.data_array == expected)
		var bytes := writer._serialize_arguments([bits], [&"U64"])
		assert(not writer.has_error() and bytes == expected)
		assert(reader.read_u64_le(_stream(bytes)) == bits)
		var status := ContinuumWorldGeneration.new()
		status.phase = ContinuumGenerationPhase.create_ready()
		status.seed = bits
		_reset()
		writer.write_nested_resource(status)
		assert(not writer.has_error())
		assert(writer._spb.data_array.slice(20, 28) == expected)
		var decoded: ContinuumWorldGeneration = reader._parse_generic_type(
			_stream(writer._spb.data_array), &"ContinuumWorldGeneration"
		)
		assert(not reader.has_error() and decoded.seed == bits)
		reducers.reset_world_large(2048, 2048, decoded.seed)
		assert(client.types == [&"I32", &"I32", &"U64"])
		bytes = writer._serialize_arguments(client.arguments, client.types)
		assert(not writer.has_error() and bytes.size() == 16)
		assert(bytes.slice(8, 16) == expected)
		assert(reader.read_u64_le(_stream(bytes.slice(8, 16))) == bits)
		_reset()
		writer.write_i64_le(bits)
		assert(not writer.has_error() and writer._spb.data_array == expected)
		assert(reader.read_i64_le(_stream(expected)) == bits)
	_check_invalid_u64()
	_check_small_unsigned_and_sentinels()
	_check_other_encodings()
	client.free()
	print(
		"SDK_U64_BITPATTERNS_PASS: exact boundary bytes, high seed generated roundtrip/reset, strict types/lengths, unsigned guards, unchanged I64/identity/UUID"
	)
	quit(0)


func _stream(bytes: PackedByteArray) -> StreamPeerBuffer:
	var buffer := StreamPeerBuffer.new()
	buffer.big_endian = false
	buffer.data_array = bytes
	return buffer


func _reset() -> void:
	writer.clear_error()
	writer._reset_buffer()
	reader.clear_error()


func _check_invalid_u64() -> void:
	for invalid: Variant in [
		0.0,
		-1.5,
		INF,
		NAN,
		true,
		false,
		"18446744073709551615",
		&"1",
		null,
		[],
		{},
		PackedByteArray(),
		PackedByteArray([255]),
		"ffffffffffffffff".hex_decode(),
		Resource.new()
	]:
		_reset()
		writer.write_u64_le(invalid)
		assert(writer.has_error() and writer._spb.data_array.is_empty())
		var bytes := writer._serialize_arguments([invalid], [&"U64"])
		assert(writer.has_error() and bytes.is_empty())
	assert(writer._serialize_arguments([[0, -1, 1.5]], [&"vec_U64"]).is_empty())
	assert(writer.has_error())
	for length in range(8):
		_reset()
		var bytes := PackedByteArray()
		bytes.resize(length)
		var buffer := _stream(bytes)
		reader.read_u64_le(buffer)
		assert(reader.has_error() and buffer.get_position() == 0)
	_reset()
	var offsets := StreamPeerBuffer.new()
	offsets.big_endian = false
	offsets.put_u8(1)  # RowOffsets.
	offsets.put_u32(1)
	offsets.put_u64(-1)  # Valid U64 bits, invalid offset into a one-byte row list.
	offsets.put_u32(1)
	offsets.put_u8(0)
	offsets.seek(0)
	assert(reader.read_bsatn_row_list(offsets).is_empty() and reader.has_error())


func _check_small_unsigned_and_sentinels() -> void:
	for spec: Array in [[&"U8", 255, 1], [&"U16", 65535, 2], [&"U32", 4294967295, 4]]:
		for invalid: int in [-1, spec[1] + 1]:
			assert(writer._serialize_arguments([invalid], [spec[0]]).is_empty())
			assert(writer.has_error())
		var bytes := writer._serialize_arguments([spec[1]], [spec[0]])
		assert(not writer.has_error() and bytes.size() == spec[2])
		for byte in bytes:
			assert(byte == 255)
	writer.serialize_client_message(SpacetimeDBClientMessage.UNSUBSCRIBE, UnsubscribeMessage.new())
	assert(writer.has_error())
	_reset()
	writer.write_i64_le(-17)
	assert(not writer.has_error() and writer._spb.data_array.hex_encode() == "efffffffffffffff")
	assert(reader.read_i64_le(_stream(writer._spb.data_array)) == -17)


func _check_other_encodings() -> void:
	for spec: Array in [[&"U128", 16], [&"__identity__", 32], [&"__connection_id__", 16]]:
		var bytes := PackedByteArray()
		for i in range(spec[1]):
			bytes.append(i)
		var expected := bytes.duplicate()
		expected.reverse()
		var encoded := writer._serialize_arguments([bytes], [spec[0]])
		assert(not writer.has_error() and encoded == expected)
		# Existing connection-ID reader exposes raw wire order (unlike identity
		# and U128). Preserve that behavior rather than incidentally repairing it.
		var decoded_expected := expected if spec[0] == &"__connection_id__" else bytes
		assert(
			(
				reader._get_primitive_reader_from_bsatn_type(_stream(encoded), spec[0])
				== decoded_expected
			)
		)
		for length: int in [0, spec[1] - 1, spec[1] + 1]:
			var invalid := PackedByteArray()
			invalid.resize(length)
			assert(writer._serialize_arguments([invalid], [spec[0]]).is_empty())
			assert(writer.has_error())
	var uuid := "0123456789abcdeffedcba9876543210"
	var encoded := writer._serialize_arguments([uuid], [&"__uuid__"])
	assert(not writer.has_error() and encoded.hex_encode() == "1032547698badcfeefcdab8967452301")
	assert(reader._get_primitive_reader_from_bsatn_type(_stream(encoded), &"__uuid__") == uuid)
