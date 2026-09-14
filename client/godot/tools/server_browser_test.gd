extends SceneTree

const History = preload("res://scripts/connection_history.gd")
const Probes = preload("res://scripts/server_probes.gd")
const Management = preload("res://scripts/server_management.gd")
var failures := 0

func _init() -> void:
	_test_keys()
	_test_persistence_boundaries()
	_test_management_contract()
	await _test_probes()
	if failures == 0: print("SERVER_BROWSER_PASS")
	else: print("SERVER_BROWSER_FAIL (%d failures)" % failures)
	quit(0 if failures == 0 else 1)

func _test_keys() -> void:
	var key := History.canonical_key("HTTPS://Example.COM:443", "Continuum", "main-world")
	_assert(key == "https://example.com/continuum/main-world", "canonical key normalizes scheme host database")
	var ipv6_key := History.canonical_key("http://[2001:DB8::1]:80", "Continuum")
	_assert(ipv6_key == "http://[2001:DB8::1]/continuum/default-world", "IPv6 remains bracketed and unrewritten")
	_assert(History.canonical_key("http://example.com:8080", "Continuum") == "http://example.com:8080/continuum/default-world", "non-default port retained")
	_assert(History.canonical_key("http://2001:db8::1", "Continuum") == "", "unbracketed IPv6 rejected")

func _test_persistence_boundaries() -> void:
	var base := "/tmp/continuum-browser-test-%d" % Time.get_ticks_usec()
	var history = History.new(); history.load_from(base + ".history", base + ".favorites")
	var key := History.canonical_key("http://Host", "Continuum", "default-world")
	_assert(history.record_successful_subscription("http://Host", "Continuum", "default-world", "Home", 5) == OK, "successful subscription recorded")
	_assert(history.record_successful_subscription("http://Host", "Continuum", "default-world", "Home", 6) == OK, "case variants deduplicate")
	_assert(history.set_favorite(key, true) == OK, "favorite can be persisted")
	_assert(history.remove_history(key) == OK, "history can be removed")
	_assert(history.entries().is_empty(), "history removal clears history only")
	var favorites = FileAccess.get_file_as_string(base + ".favorites")
	_assert(favorites.contains(key), "favorite persists separately from history")
	_assert(history.remove_favorite(key) == OK, "favorite remains independently removable")
	var loaded = History.new(); loaded.load_from(base + ".history", base + ".favorites")
	_assert(loaded.entries().is_empty(), "empty state persists")

func _test_probes() -> void:
	var probes = Probes.new(); probes.set_visible(true)
	var calls := [0]
	var callbacks: Array[Callable] = []
	probes.transport = func(_entry: Dictionary, complete: Callable) -> void:
		calls[0] += 1
		callbacks.append(complete)
	var entries: Array[Dictionary] = []
	for index in 6: entries.append({"key": "k%d" % index})
	probes.refresh(entries, 0.0)
	_assert(calls[0] == Probes.MAX_CONCURRENT, "probe concurrency is bounded")
	probes.process(3.1)
	_assert(probes.state("k0").status == "unreachable", "timeout is unreachable")
	_assert(probes.state("k0").stale == false, "timeout sample is not immediately stale")
	var old_callback: Callable = callbacks[0]
	probes.set_visible(false); probes.set_visible(true); probes.refresh([{"key": "k0"}], 20.0)
	old_callback.call({"reachable": true, "rtt_ms": 4})
	_assert(probes.state("k0").status == "checking", "late callback cannot complete a reopened attempt")
	probes.set_visible(false)
	var hidden_calls: int = calls[0]
	probes.refresh(entries, 100.0)
	_assert(calls[0] == hidden_calls, "hidden browser does not poll")

func _test_management_contract() -> void:
	var manager = Management.new()
	var store = History.new(); store.load_from("/tmp/continuum-manager.history", "/tmp/continuum-manager.favorites")
	store.record_successful_subscription("http://example.com", "Continuum", "default-world", "Home", 1)
	manager.set_history_store(store)
	var stopped := [0]
	manager.local_stop_requested.connect(func() -> void: stopped[0] += 1)
	manager.set_local_management_state({"can_stop": false})
	manager.request_local_stop()
	_assert(stopped[0] == 0, "remote or unowned entries cannot stop a managed process")
	manager.set_local_management_state({"can_stop": true})
	manager.request_local_stop()
	_assert(stopped[0] == 1, "owned local stop capability emits")
	manager.request_join(History.canonical_key("http://example.com", "Continuum"))
	var selected: String = manager.selected_key
	manager.set_search("not found")
	_assert(manager.selected_key == selected, "selection identifier survives filtering")
	manager.free()

func _assert(condition: bool, message: String) -> void:
	if not condition: failures += 1; printerr("FAIL: %s" % message)
