## Backend-free wire-value key regression: independently decoded enum instances must share a row.
extends SceneTree

var local_db: LocalDatabase
var db: ContinuumModuleDb
var inserts := 0
var updates := 0
var deletes := 0


func _initialize() -> void:
	var schema := SpacetimeDBSchema.new("Continuum")
	local_db = LocalDatabase.new(schema, null)
	db = ContinuumModuleDb.new(local_db)
	local_db.row_inserted.connect(func(t: String, _r: Resource):
		if t == "production_policy": inserts += 1)
	local_db.row_updated.connect(func(t: String, _p: Resource, _r: Resource):
		if t == "production_policy": updates += 1)
	local_db.row_deleted.connect(func(t: String, _r: Resource):
		if t == "production_policy": deletes += 1)
	for kind: int in ContinuumResourceKind.Options.values():
		var original := _policy(kind, 20.0)
		var replacement := _policy(kind, 30.0)
		assert(original.resource != replacement.resource, "fixture must use distinct enum instances")
		_apply("production_policy", [original], [])
		assert(db.production_policy.resource.find(ContinuumResourceKind.create(kind)) == original)
		assert(local_db.get_row_by_pk("production_policy", ContinuumResourceKind.create(kind)) == original)
		_apply("production_policy", [replacement], [_policy(kind, 20.0)])
		assert(db.production_policy.iter().size() == 1)
		assert(db.production_policy.resource.find(ContinuumResourceKind.create(kind)) == replacement)
		assert(inserts == kind + 1 and updates == kind + 1 and deletes == kind)
		_apply("production_policy", [], [_policy(kind, 30.0)])
		assert(db.production_policy.iter().is_empty())
		assert(db.production_policy.resource.find(ContinuumResourceKind.create(kind)) == null)
		assert(local_db.get_row_by_pk("production_policy", ContinuumResourceKind.create(kind)) == null)
	assert(inserts == 4 and updates == 4 and deletes == 4)
	_apply("production_policy", [_policy(1, 40.0)], [])
	local_db.clear_local_db()
	assert(db.production_policy.resource.find(ContinuumResourceKind.create_wood()) == null)
	_apply("production_policy", [_policy(1, 50.0)], [])
	assert(db.production_policy.resource.find(ContinuumResourceKind.create_wood()).target == 50.0)
	local_db.clear_local_db()
	_check_primitive_indexes()
	local_db.free()
	print("ENUM_KEY_CACHE_PASS: all enum variants, replacement/delete signals, reload, primitive indexes")
	quit(0)


func _policy(kind: int, target: float) -> ContinuumProductionPolicy:
	return ContinuumProductionPolicy.create(ContinuumResourceKind.create(kind), target)


func _apply(table: String, inserted: Array[Resource], deleted: Array[Resource]) -> void:
	var change := TableUpdateData.new()
	change.table_name = table
	change.inserts = inserted
	change.deletes = deleted
	local_db.emit_db_callbacks([local_db.apply_table_update(change)])


func _check_primitive_indexes() -> void:
	for value: Variant in [123, "code", PackedByteArray([1, 2, 3])]:
		assert(local_db.stable_key(value) == value)
		assert(typeof(local_db.stable_key(value)) == typeof(value))
	var old := ContinuumAlert.new()
	old.id = 7
	old.code = "old"
	_apply("alert", [old], [])
	assert(db.alert.id.find(7) == old and db.alert.code.find("old") == old)
	var updated := ContinuumAlert.new()
	updated.id = 7
	updated.code = "new"
	_apply("alert", [updated], [old])
	assert(db.alert.id.find(7) == updated and db.alert.code.find("new") == updated)
	assert(db.alert.code.find("old") == null)
	var deleted := ContinuumAlert.new()
	deleted.id = 7
	deleted.code = "new"
	_apply("alert", [], [deleted])
	assert(db.alert.iter().is_empty())
	assert(db.alert.id.find(7) == null and db.alert.code.find("new") == null)
