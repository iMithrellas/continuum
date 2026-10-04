## Bounded cache-key contract: only schema-validated unit enums, never payload serialization.
extends SceneTree


class PayloadEnum:
	extends RustEnum
	const bsatn_enum_type: StringName = &"TestPayloadEnum"
	const Options = {"f64": 0, "i32": 1, "boolean": 2, "text": 3, "unit": 4}
	const enum_options: Array[StringName] = [&"F64", &"I32", &"Bool", &"String", &""]


class EmptyOptionsEnum:
	extends RustEnum
	const bsatn_enum_type: StringName = &"TestEmptyOptionsEnum"
	const Options = {"unit": 0}
	const enum_options: Array[StringName] = []


class InvalidTagsEnum:
	extends RustEnum
	const bsatn_enum_type: StringName = &"TestInvalidTagsEnum"
	const Options = {"unit": 1}
	const enum_options: Array[StringName] = [&""]


class PayloadRow:
	extends _ModuleTableType
	const primary_key: StringName = &"resource"
	const BSATN_TYPES = {&"resource": &"TestPayloadEnum"}
	var resource: RustEnum


class PayloadIndex:
	extends _ModuleTableUniqueIndex
	var cache: Dictionary[PackedByteArray, PayloadRow] = {}

	func _init() -> void:
		set_meta("table_name", "payload_test")
		set_meta("field_name", "resource")


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	var schema := SpacetimeDBSchema.new("Continuum")
	schema.module_types[&"TestPayloadEnum"] = PayloadEnum
	schema.module_types[&"TestEmptyOptionsEnum"] = EmptyOptionsEnum
	schema.module_types[&"TestInvalidTagsEnum"] = InvalidTagsEnum
	schema.module_types[&"TestPayloadRow"] = PayloadRow
	schema.module_table_name_to_type_name[&"payload_test"] = &"TestPayloadRow"
	var local_db := LocalDatabase.new(schema, null)
	local_db._is_event_table_cache[&"payload_test"] = false
	var db := ContinuumModuleDb.new(local_db)
	var payload_index := PayloadIndex.new()
	payload_index._connect_cache_to_db(payload_index.cache, local_db)
	var callbacks := [0]
	local_db.row_inserted.connect(func(_t: String, _r: Resource): callbacks[0] += 1)
	local_db.row_updated.connect(func(_t: String, _p: Resource, _r: Resource): callbacks[0] += 1)
	local_db.row_deleted.connect(func(_t: String, _r: Resource): callbacks[0] += 1)
	local_db.subscribe_to_transactions_completed("production_policy", func(): callbacks[0] += 1)
	local_db.subscribe_to_transactions_completed("payload_test", func(): callbacks[0] += 1)

	assert(db.production_policy.resource.find(null) == null)
	assert(ContinuumProductionPolicyResourceUniqueIndex.new().find(null) == null)
	assert(local_db.get_row_by_pk("production_policy", null) == null)
	assert(local_db.stable_key(null) == null)
	assert(local_db.stable_key(RustEnum.new()) == null)
	assert(local_db.stable_key(EmptyOptionsEnum.new()) == null)
	assert(local_db.stable_key(InvalidTagsEnum.new()) == null)
	var distinct: Dictionary = {}
	for tag: int in ContinuumResourceKind.Options.values():
		var key: Variant = local_db.stable_key(ContinuumResourceKind.create(tag))
		assert(key == PackedByteArray([tag]) and not distinct.has(key))
		distinct[key] = true
		assert(key == local_db.stable_key(ContinuumResourceKind.create(tag)))

	var invalid: Array[ContinuumResourceKind] = [
		null,
		ContinuumResourceKind.create(-1),
		ContinuumResourceKind.create(4),
		ContinuumResourceKind.create(256)
	]
	for data: Variant in [0, false, "", 1, "unexpected", PackedByteArray()]:
		invalid.append(ContinuumResourceKind.create(0, data))
	for resource: ContinuumResourceKind in invalid:
		assert(local_db.stable_key(resource) == null)
		assert(db.production_policy.resource.find(resource) == null)
		assert(local_db.get_row_by_pk("production_policy", resource) == null)
		var row := ContinuumProductionPolicy.create(resource, 10.0)
		_apply(local_db, "production_policy", row)
		for listener: Callable in local_db._insert_listeners_by_table["production_policy"]:
			listener.call(row)
		for listener: Callable in local_db._update_listeners_by_table["production_policy"]:
			listener.call(row, row)
		for listener: Callable in local_db._delete_listeners_by_table["production_policy"]:
			listener.call(row)
		assert(db.production_policy.resource._cache.is_empty())
	assert(db.production_policy.iter().is_empty())
	assert(callbacks[0] == 0)
	assert(
		local_db.column_key("production_policy", "resource", ContinuumWorkType.create(0)) == null
	)
	var registered: GDScript = schema.module_types[&"ContinuumResourceKind"]
	schema.module_types.erase(&"ContinuumResourceKind")
	assert(local_db.stable_key(ContinuumResourceKind.create_food()) == null)
	schema.module_types[&"ContinuumResourceKind"] = registered

	for pair: Array in [
		[0, 16777216.0], [0, 16777217.0], [0, 0.0], [1, 123], [1, 0], [2, false], [3, ""], [4, null]
	]:
		var value := PayloadEnum.new()
		value.value = pair[0]
		value.data = pair[1]
		assert(local_db.stable_key(value) == null)
		assert(local_db.get_row_by_pk("payload_test", value) == null)
		var row := PayloadRow.new()
		row.resource = value
		_apply(local_db, "payload_test", row)
	assert(local_db.count_all_rows("payload_test") == 0 and payload_index.cache.is_empty())
	assert(callbacks[0] == 0, "rejected table updates must not emit row callbacks")
	for value: Variant in [123, 0, false, "", "key", PackedByteArray([1, 2])]:
		assert(
			(
				local_db.stable_key(value) == value
				and typeof(local_db.stable_key(value)) == typeof(value)
			)
		)
	var main_source := FileAccess.get_file_as_string("res://scripts/main.gd")
	assert(
		main_source.count('"SELECT * FROM production_policy"') == 1,
		"Main must retain exactly one policy query; overlapping query ownership is outside this fix"
	)
	local_db.free()
	print(
		"UNIT_ENUM_KEY_CONTRACT_PASS: valid unit keys, malformed/payload/null rejection, primitives, one Main policy query"
	)
	quit.call_deferred(0)


func _apply(local_db: LocalDatabase, table: String, row: Resource) -> void:
	var update := TableUpdateData.new()
	update.table_name = table
	update.inserts = [row]
	update.deletes = [row]
	var change := local_db.apply_table_update(update)
	assert(change.inserts.is_empty() and change.updates.is_empty() and change.deletes.is_empty())
	local_db.emit_db_callbacks([change])
