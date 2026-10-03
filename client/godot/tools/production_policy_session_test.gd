## Real subscription regression; only an explicitly supplied disposable QA metadata file is accepted.
## Default probes Meat removal; --all-resources also exercises update, fresh enum lookup and reconnect.
extends SceneTree

var client: ContinuumModuleClient
var metadata: Dictionary
var failed := false
var inserts := 0
var updates := 0
var deletes := 0


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	var path := ""
	var all_resources := OS.get_cmdline_user_args().has("--all-resources")
	for arg: String in OS.get_cmdline_user_args():
		if arg.begins_with("--qa-metadata="): path = arg.trim_prefix("--qa-metadata=")
	if not _require(not path.is_empty(), "explicit disposable QA metadata required"): return
	metadata = JSON.parse_string(FileAccess.get_file_as_string(path))
	if not _require(String(metadata.endpoint).begins_with("http://127.0.0.1:")
		and String(metadata.database).begins_with("connected-colony-"), "not a disposable QA endpoint"): return
	client = await _connect_client()
	if failed: return
	if not _require(client.db.production_policy.iter().is_empty(), "QA policy table must start empty"): return
	client.row_inserted.connect(func(t: String, _r: Resource):
		if t == "production_policy": inserts += 1)
	client.row_updated.connect(func(t: String, _p: Resource, _r: Resource):
		if t == "production_policy": updates += 1)
	client.row_deleted.connect(func(t: String, _r: Resource):
		if t == "production_policy": deletes += 1)
	var kinds: Array = ContinuumResourceKind.Options.values() if all_resources else [ContinuumResourceKind.Options.meat]
	for kind: int in kinds:
		await _call(client.reducers.set_production_policy(ContinuumResourceKind.create(kind), 20.0))
		if not await _wait(func(): return _matches(kind, 20.0), "initial policy snapshot"): return
		if all_resources:
			if not _require(client.db.production_policy.resource.find(ContinuumResourceKind.create(kind)) != null,
				"fresh enum instance must resolve index"): return
			await _call(client.reducers.set_production_policy(ContinuumResourceKind.create(kind), 30.0))
			if not await _wait(func(): return _matches(kind, 30.0), "update replaces same enum PK"): return
			var observer: ContinuumModuleClient = await _connect_client()
			if failed: return
			if not _require(observer.db.production_policy.iter().size() == 1
				and observer.db.production_policy.resource.find(ContinuumResourceKind.create(kind)).target == 30.0,
				"fresh connection snapshot must equal updated cache"): return
			observer.disconnect_db()
			observer.queue_free()
			client.disconnect_db()
			if not await _wait(func(): return not client.is_connected_db(), "disconnect before reconnect"): return
			client.reconnect_db(true)
			if not await _wait(func(): return _matches(kind, 30.0), "reconnect snapshot"): return
		await _call(client.reducers.remove_production_policy(ContinuumResourceKind.create(kind)))
		var witness: ContinuumModuleClient = await _connect_client()
		if failed: return
		if not _require(witness.db.production_policy.iter().is_empty(), "fresh server snapshot confirms removal"): return
		witness.disconnect_db()
		witness.queue_free()
		print("SERVER_SNAPSHOT_EMPTY_AFTER_REMOVE kind=%d cached_rows=%d" % [kind, client.db.production_policy.iter().size()])
		if not await _wait(func(): return client.db.production_policy.iter().is_empty(), "cached policy removal"): return
		if all_resources:
			if not _require(client.db.production_policy.resource.find(ContinuumResourceKind.create(kind)) == null,
				"deleted enum index entry must be absent"): return
	if all_resources and not _require(inserts >= 4 and updates == 4 and deletes >= 4,
		"row notification flow must include insert/update/delete for every resource"): return
	client.disconnect_db()
	client.queue_free()
	await process_frame
	print("PRODUCTION_POLICY_SESSION_PASS resources=%d inserts=%d updates=%d deletes=%d" % [kinds.size(), inserts, updates, deletes])
	quit(0)


func _connect_client() -> ContinuumModuleClient:
	var result := ContinuumModuleClient.new()
	root.add_child(result)
	result.connection_error.connect(func(_code: int, _reason: String): _require(false, "QA connection error"))
	var ready := [false]
	result.connected.connect(func(_identity: PackedByteArray, _token: String):
		var subscription := result.subscribe(PackedStringArray(["SELECT * FROM production_policy"]))
		subscription.applied.connect(func(): ready[0] = true))
	var options := SpacetimeDBConnectionOptions.new()
	options.one_time_token = false
	options.save_token = false
	options.debug_mode = false
	result.token_save_path = metadata.token_paths.admin
	await process_frame
	result.connect_db(metadata.endpoint, metadata.database, options)
	await _wait(func(): return ready[0], "QA subscription applied")
	return result


func _call(request: SpacetimeDBReducerCall) -> void:
	if not _require(request != null and request.error == OK, "reducer dispatch failed"): return
	var complete := [false]
	request.on_error.connect(func(_error: String): _require(false, "QA reducer rejected"))
	request.on_internal_error.connect(func(_error: String): _require(false, "QA reducer internal error"))
	request.response.connect(func(_response: Resource): complete[0] = true)
	await _wait(func(): return complete[0], "reducer acknowledgement")


func _matches(kind: int, target: float) -> bool:
	var rows := client.db.production_policy.iter()
	return rows.size() == 1 and rows[0].resource.value == kind and rows[0].target == target


func _wait(predicate: Callable, label: String) -> bool:
	var deadline := Time.get_ticks_msec() + 10000
	while not failed and Time.get_ticks_msec() < deadline:
		if predicate.call(): return true
		await process_frame
	return _require(false, "timed out: " + label)


func _require(condition: bool, label: String) -> bool:
	if not condition:
		failed = true
		printerr("PRODUCTION_POLICY_SESSION_FAIL: " + label)
		quit(1)
	return condition
