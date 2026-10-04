## Real credential cache/REST paths with a recording WebSocket. No game server,
## database connection, publisher credential, or host process signal is used.
extends SceneTree

var failures := 0
var fixture := ""


class RecordingConnection:
	extends SpacetimeDBConnection
	var tokens: Array[String] = []

	func _init() -> void:
		super(SpacetimeDBConnectionOptions.new(), "continuum")

	func connect_to_database(
		_host: String, _database: String, _connection_id: String, _confirmed: bool
	):
		tokens.append(_token)


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	fixture = OS.get_environment("CONTINUUM_NATIVE_ROOT").get_base_dir().path_join(
		"credentials-%d" % OS.get_process_id()
	)
	if not fixture.is_absolute_path():
		fixture = "/tmp/opencode/credentials-%d" % OS.get_process_id()
	DirAccess.make_dir_recursive_absolute(fixture)
	_test_profile_scope()
	_test_validation_responses()
	var url := _option("--auth-fixture", "")
	if not url.is_empty():
		await _test_http_cache_flow(url, "existing", "existing-identity", "", "existing-identity")
		await _test_http_cache_flow(
			url, "recreated", "deleted-server-identity", "", "new-server-identity"
		)
		await _test_http_cache_flow(
			url, "preferred", "unused-legacy-identity", "existing-identity", "existing-identity"
		)
		await _test_http_cache_flow(url, "remote", "remote-identity", "", "", 401, false)
		await _test_http_cache_flow(url, "unavailable", "existing-identity", "", "", 503)
		await _test_http_cache_flow(
			url, "unavailable-cached", "unused-legacy-identity", "existing-identity", "", 503
		)
		await _test_http_cache_flow(url, "malformed", "existing-identity", "", "", ERR_INVALID_DATA)
		await _test_http_cache_flow(url, "fresh", "", "", "fresh-identity")
		await _test_retry_preserves_cache(url)
		await _test_one_time_does_not_touch_caches(url)
	print("CREDENTIAL_LIFECYCLE_PASS" if failures == 0 else "CREDENTIAL_LIFECYCLE_FAIL")
	quit(0 if failures == 0 else 1)


func _test_profile_scope() -> void:
	var catalog := ContinuumNativeServerCatalog.new()
	var root_path := fixture.path_join("native")
	_check(catalog.load_from(root_path) == OK, "credential scope catalog loads")
	var client := SpacetimeDBClient.new()
	var canonical := "http://127.0.0.1:3001"
	var legacy := ContinuumClientProfile.token_path("normal", canonical, "continuum")
	ContinuumClientProfile.configure_credentials(client, "normal", canonical, "continuum", catalog)
	var original := client.token_save_path
	_check(
		(
			original != legacy
			and client.fallback_token_save_path == legacy
			and client.validate_cached_token
		),
		"legacy endpoint credential is only a verified migration candidate"
	)
	_check(catalog.remove("default") == OK, "deleted profile leaves its port free")
	var replacement := catalog.create("Replacement")
	_check(
		replacement.ok and replacement.entry.port == 3001,
		"a new profile can reuse the deleted profile's port"
	)
	ContinuumClientProfile.configure_credentials(client, "normal", canonical, "continuum", catalog)
	var normal := client.token_save_path
	_check(
		normal != original and normal != legacy and client.recover_rejected_cached_token,
		"recreated profiles never share the old credential cache"
	)
	ContinuumClientProfile.configure_credentials(
		client, "normal", "http://localhost:3001", "continuum", catalog
	)
	_check(
		client.token_save_path == normal,
		"managed endpoint aliases share their profile-scoped identity"
	)
	var paths: Array[String] = [normal]
	for profile: String in ["admin", "developer"]:
		ContinuumClientProfile.configure_credentials(
			client, profile, canonical, "continuum", catalog
		)
		_check(
			not paths.has(client.token_save_path), "client profiles retain independent identities"
		)
		paths.append(client.token_save_path)
	var previous_root := OS.get_environment("CONTINUUM_NATIVE_ROOT")
	OS.set_environment("CONTINUUM_NATIVE_ROOT", root_path)
	ContinuumClientProfile.configure_credentials(client, "normal", canonical, "continuum")
	_check(
		client.token_save_path == normal,
		"admin/bootstrap tools and the main UI resolve the same persisted server identity"
	)
	var saved_catalog := FileAccess.get_file_as_string(catalog.path)
	_write(catalog.path, '[{"id":"../outside","name":"Invalid","port":3001}]')
	ContinuumClientProfile.configure_credentials(client, "normal", canonical, "continuum")
	_check(
		(
			client.token_save_path == legacy
			and not client.recover_rejected_cached_token
			and FileAccess.get_file_as_string(catalog.path).contains("../outside")
		),
		"malformed catalogs cannot authorize credential replacement and are not rewritten"
	)
	_write(catalog.path, saved_catalog)
	OS.set_environment("CONTINUUM_NATIVE_ROOT", previous_root)
	ContinuumClientProfile.configure_credentials(
		client, "normal", "https://example.com", "continuum", catalog
	)
	_check(
		(
			(
				client.token_save_path
				== ContinuumClientProfile.token_path("normal", "https://example.com", "continuum")
			)
			and client.fallback_token_save_path.is_empty()
			and not client.recover_rejected_cached_token
		),
		"remote identities are never silently replaced or given local permissions"
	)
	client.free()


func _test_validation_responses() -> void:
	var rest := SpacetimeDBRestAPI.new("http://127.0.0.1:1", false)
	var accepted: Array[String] = []
	var rejected: Array[int] = []
	rest.token_validated.connect(func(token: String): accepted.append(token))
	rest.token_validation_failed.connect(func(code: int, _body: String): rejected.append(code))
	rest._validating_token = "durable-identity"
	rest._pending_request_type = SpacetimeDBRestAPI.RequestType.TOKEN_VALIDATION
	rest._on_request_completed(
		HTTPRequest.RESULT_SUCCESS, 200, [], '{"token":"short-lived-re-signature"}'.to_utf8_buffer()
	)
	_check(
		accepted == ["durable-identity"] and rest._validating_token.is_empty(),
		"validation keeps the durable credential instead of the 60-second token"
	)
	for response: Array in [
		[HTTPRequest.RESULT_SUCCESS, 401],
		[HTTPRequest.RESULT_SUCCESS, 403],
		[HTTPRequest.RESULT_CANT_CONNECT, 0]
	]:
		rest._validating_token = "private-credential"
		rest._pending_request_type = SpacetimeDBRestAPI.RequestType.TOKEN_VALIDATION
		rest._on_request_completed(response[0], response[1], [], PackedByteArray())
	_check(
		(
			rejected == [401, 403, HTTPRequest.RESULT_CANT_CONNECT]
			and rest._pending_request_type == SpacetimeDBRestAPI.RequestType.NONE
		),
		"authentication rejection and transport failure remain distinct and release pending ownership"
	)
	_check(rest._http_request.timeout > 0.0, "credential preflight has a bounded timeout")
	rest.free()


func _client(url: String, name: String) -> SpacetimeDBClient:
	var client := SpacetimeDBClient.new()
	client.debug_mode = false
	client.use_threading = false
	client.connection_options = SpacetimeDBConnectionOptions.new()
	client.base_url = url
	client.database_name = "continuum"
	client.token_save_path = fixture.path_join(name + ".scoped.token")
	client.fallback_token_save_path = fixture.path_join(name + ".legacy.token")
	client.validate_cached_token = true
	client.recover_rejected_cached_token = true
	client._connection = RecordingConnection.new()
	client.add_child(client._connection)
	client._rest_api = SpacetimeDBRestAPI.new(url, false)
	client._rest_api.token_received.connect(client._on_token_received)
	client._rest_api.token_request_failed.connect(client._on_token_request_failed)
	client._rest_api.token_validated.connect(client._on_token_received)
	client._rest_api.token_validation_failed.connect(client._on_token_validation_failed)
	client.add_child(client._rest_api)
	root.add_child(client)
	return client


func _test_http_cache_flow(
	url: String,
	name: String,
	legacy: String,
	primary: String,
	expected: String,
	error := -1,
	recover := true
) -> void:
	var client := _client(url + "/" + name, name)
	client.recover_rejected_cached_token = recover
	if not legacy.is_empty():
		_write(client.fallback_token_save_path, legacy)
	if not primary.is_empty():
		_write(client.token_save_path, primary)
	var errors: Array[int] = []
	client.connection_error.connect(func(code: int, _reason: String): errors.append(code))
	client._load_token_or_request()
	var transport := client._connection as RecordingConnection
	_check(
		await _wait_for(func(): return not transport.tokens.is_empty() or not errors.is_empty()),
		name + " authentication completes"
	)
	if error < 0:
		_check(
			(
				errors.is_empty()
				and transport.tokens == [expected]
				and FileAccess.get_file_as_string(client.token_save_path) == expected
			),
			name + " opens only with the verified/current-server identity and persists it"
		)
	else:
		var cache_kept := (
			not FileAccess.file_exists(client.token_save_path)
			if primary.is_empty()
			else FileAccess.get_file_as_string(client.token_save_path) == primary
		)
		_check(
			errors == [error] and transport.tokens.is_empty() and cache_kept,
			name + " rejection never opens a socket or overwrites a cache"
		)
	if not legacy.is_empty():
		_check(
			FileAccess.get_file_as_string(client.fallback_token_save_path) == legacy,
			name + " preserves the legacy identity file"
		)
	client.queue_free()
	await process_frame


func _test_retry_preserves_cache(url: String) -> void:
	var client := _client(url + "/retry", "retry")
	_write(client.token_save_path, "deleted-server-identity")
	var errors: Array[int] = []
	client.connection_error.connect(func(code: int, _reason: String): errors.append(code))
	client._load_token_or_request()
	_check(
		await _wait_for(func(): return not errors.is_empty()),
		"failed replacement token request completes"
	)
	_check(
		FileAccess.get_file_as_string(client.token_save_path) == "deleted-server-identity",
		"failed recovery preserves the old cache for retry"
	)
	client._load_token_or_request()
	var transport := client._connection as RecordingConnection
	_check(
		await _wait_for(func(): return not transport.tokens.is_empty()),
		"credential recovery can be retried"
	)
	_check(
		(
			transport.tokens == ["new-server-identity"]
			and FileAccess.get_file_as_string(client.token_save_path) == "new-server-identity"
		),
		"only successful recovery replaces a rejected scoped cache"
	)
	client.queue_free()
	await process_frame


func _test_one_time_does_not_touch_caches(url: String) -> void:
	var client := _client(url + "/one-time", "one-time")
	_write(client.token_save_path, "saved-identity")
	_write(client.fallback_token_save_path, "legacy-identity")
	var options := SpacetimeDBConnectionOptions.new()
	options.one_time_token = true
	options.save_token = false
	options.threading = false
	client._is_initialized = true
	client.connect_db(url + "/one-time", "continuum", options)
	var transport := client._connection as RecordingConnection
	_check(
		await _wait_for(func(): return not transport.tokens.is_empty()),
		"one-time authentication completes"
	)
	_check(
		(
			transport.tokens == ["one-time-identity"]
			and FileAccess.get_file_as_string(client.token_save_path) == "saved-identity"
			and FileAccess.get_file_as_string(client.fallback_token_save_path) == "legacy-identity"
		),
		"one-time auth ignores and preserves both credential caches"
	)
	client.queue_free()
	await process_frame


func _write(path: String, contents: String) -> void:
	var file := FileAccess.open(path, FileAccess.WRITE)
	file.store_string(contents)
	file.close()


func _wait_for(condition: Callable) -> bool:
	var deadline := Time.get_ticks_msec() + 5000
	while Time.get_ticks_msec() < deadline:
		if condition.call():
			return true
		await create_timer(0.01).timeout
	return false


func _option(name: String, fallback: String) -> String:
	for argument: String in OS.get_cmdline_user_args():
		if argument.begins_with(name + "="):
			return argument.substr(name.length() + 1)
	return fallback


func _check(condition: bool, message: String) -> void:
	if not condition:
		failures += 1
		printerr("FAIL: " + message)
