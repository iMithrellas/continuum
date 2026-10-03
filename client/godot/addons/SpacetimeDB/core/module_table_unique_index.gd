class_name _ModuleTableUniqueIndex extends Resource

var _key_db: LocalDatabase

func _key(value: Variant) -> Variant:
	if not is_instance_valid(_key_db): return null
	return _key_db.column_key(get_meta("table_name", ""), get_meta("field_name", ""), value)

func _connect_cache_to_db(cache: Dictionary, db: LocalDatabase) -> void:
	_key_db = db
	var table_name: String = get_meta("table_name", "")
	var field_name: String = get_meta("field_name", "")

	db.subscribe_to_inserts(table_name, func(r: _ModuleTableType):
		var col_val = _key(r[field_name])
		if col_val == null: return
		cache[col_val] = r
	)
	db.subscribe_to_updates(table_name, func(p: _ModuleTableType, r: _ModuleTableType):
		var previous_col_val = _key(p[field_name])
		var col_val = _key(r[field_name])
		if previous_col_val == null or col_val == null: return

		if previous_col_val != col_val:
			cache.erase(previous_col_val)
		cache[col_val] = r
	)
	db.subscribe_to_deletes(table_name, func(r: _ModuleTableType):
		var col_val = _key(r[field_name])
		if col_val == null: return
		cache.erase(col_val)
	)
