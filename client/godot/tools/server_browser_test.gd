extends SceneTree

const History = preload("res://scripts/connection_history.gd")
const Probes = preload("res://scripts/server_probes.gd")
var failures := 0

func _init() -> void:
	_test_keys()
	_test_persistence_boundaries()
	await _test_probes()
	if failures == 0: print("SERVER_BROWSER_PASS")
	else: print("SERVER_BROWSER_FAIL (%d failures)" % failures)
	quit(0 if failures == 0 else 1)

func _test_keys() -> void:
	var key := History.canonical_key("HTTPS://Example.COM:443", "Continuum", "main-world")
	_assert(key == "https://example.com/continuum/main-world", "canonical key normalizes scheme host database")
	_assert(History.canonical_key("http://[2001:DB8::1]:80", "Continuum") == "http://[2001:DB8::1]/continuum/default-world", "IPv6 remains bracketed and unrewritten")
	_assert(History.canonical_key("http://example.com:8080", "Continuum") == "http://example.com:8080/continuum/default-world", "non-default port retained")
	_assert(History.canonical_key("http://2001:db8::1", "Continuum") == "", "unbracketed IPv6 rejected")

func _test_persistence_boundaries() -> void:
	var base := "/tmp/continuum-browser-test-%d" % Time.get_ticks_usec()
	var history = History.new(); history.load_from(base + ".history", base + ".favorites")
	var key := history.record_successful_subscription("http://Host", "Continuum", "default-world", "Home", 5)
	_assert(key != "", "successful subscription recorded")
	_assert(history.record_successful_subscription("http://Host", "Continuum", "default-world", "Home", 6) == key, "case variants deduplicate")
	history.set_favorite(key, true); history.remove_history(key)
	_assert(history.entries().is_empty(), "history removal clears history only")
	var favorites = FileAccess.get_file_as_string(base + ".favorites")
	_assert(favorites.contains(key), "favorite persists separately from history")
	_assert(history.remove_favorite(key), "favorite remains independently removable")
	var loaded = History.new(); loaded.load_from(base + ".history", base + ".favorites")
	_assert(loaded.entries().is_empty(), "empty state persists")

func _test_probes() -> void:
	var probes = Probes.new(); probes.set_visible(true)
	var calls := [0]
	probes.transport = func(_entry: Dictionary, _complete: Callable) -> void: calls[0] += 1
	var entries: Array[Dictionary] = []
	for index in 6: entries.append({"key": "k%d" % index})
	probes.refresh(entries, 0.0)
	_assert(calls[0] == Probes.MAX_CONCURRENT, "probe concurrency is bounded")
	probes.process(3.1)
	_assert(probes.state("k0").status == "unreachable", "timeout is unreachable")
	_assert(probes.state("k0").stale == false, "timeout sample is not immediately stale")
	probes.set_visible(false); probes.refresh(entries, 100.0)
	_assert(calls[0] == Probes.MAX_CONCURRENT, "hidden browser does not poll")

func _assert(condition: bool, message: String) -> void:
	if not condition: failures += 1; printerr("FAIL: %s" % message)
