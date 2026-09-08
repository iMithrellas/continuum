## Headless end-to-end check of the client <-> SpacetimeDB loop.
##
##   godot --headless --path client/godot --script res://tools/smoke_test.gd
##
## Connects, subscribes, reads the colony through the generated bindings, calls a
## reducer, and asserts the change comes back through the subscription rather than
## being assumed locally. Prints SMOKE_PASS / SMOKE_FAIL and exits 0 / 1.
##
## Instantiates the module client directly instead of using the `SpacetimeDB`
## autoload, because a `--script` run replaces the main loop and never registers it.
extends SceneTree

const TIMEOUT_SECONDS := 40.0
static var SUBSCRIPTION_QUERIES := PackedStringArray([
	"SELECT * FROM config", "SELECT * FROM colony", "SELECT * FROM tile",
	"SELECT * FROM colonist", "SELECT * FROM alert", "SELECT * FROM event_log",
])

var client: ContinuumModuleClient
var elapsed := 0.0
var phase := 0
var phase_started := 0.0
var recreation_was_enabled := false
var failed := false
var started := false
var unauthorized_client: ContinuumModuleClient


func _initialize() -> void:
	client = ContinuumModuleClient.new()
	root.add_child(client)
	client.connection_error.connect(func(code: int, reason: String) -> void:
		_fail("connection error %d: %s" % [code, reason]))
	client.connected.connect(func(_identity: PackedByteArray, _token: String) -> void:
		client.subscribe(SUBSCRIPTION_QUERIES))


## Connecting is deferred by one frame: the client's own `HTTPRequest` child (used
## for the token fetch) must be inside the tree before `connect_db`, and `add_child`
## in `_initialize` has not taken effect yet.
func _connect() -> void:
	var host := _cli_option("--stdb-host", "http://127.0.0.1:3000")
	var database := _cli_option("--stdb-db", "continuum")
	var options := SpacetimeDBConnectionOptions.new()
	options.compression = SpacetimeDBConnection.CompressionPreference.NONE
	options.debug_mode = false
	options.one_time_token = false
	options.save_token = true
	client.token_save_path = "user://continuum_identity_%s.token" % \
			(host + "/" + database).md5_text()
	client.connect_db(host, database, options)


func _cli_option(option: String, fallback: String) -> String:
	for argument: String in OS.get_cmdline_user_args():
		if argument.begins_with(option + "="):
			return argument.substr(option.length() + 1)
	return fallback


func _process(delta: float) -> bool:
	elapsed += delta
	if failed:
		return true
	if not started:
		started = true
		_connect()
		return false
	if elapsed > TIMEOUT_SECONDS:
		return _fail("timed out in phase %d" % phase)

	match phase:
		0:
			return _phase_read_state()
		1:
			return _phase_check_reducer_applied()
		2:
			return _phase_restore()
	return false


## Wait for the initial subscription, then dump what the colony looks like.
func _phase_read_state() -> bool:
	var tiles: Array[ContinuumTile] = client.db.tile.iter()
	var colonists: Array[ContinuumColonist] = client.db.colonist.iter()
	var config: ContinuumConfig = client.db.config.id.find(0)
	var colony: ContinuumColony = client.db.colony.id.find(0)
	if tiles.is_empty() or colonists.is_empty() or config == null or colony == null:
		return false

	print("OK identity      = ", client.get_local_identity().hex_encode().substr(0, 16))
	print("OK tiles         = %d, colonists = %d, events = %d"
			% [tiles.size(), colonists.size(), client.db.event_log.iter().size()])
	print("OK day %d  time_scale = %.0f  (%.0fx)"
			% [int(config.game_seconds / 86400.0) + 1, config.time_scale,
				config.time_scale / 6.0])
	print("OK food          = %.1f / %.1f" % [colony.food, colony.food_capacity])
	print("OK mood %.0f (trend %.0f)   productivity %.0f (trend %.0f)"
			% [colony.avg_mood, colony.smoothed_mood, colony.avg_productivity,
				colony.smoothed_productivity])
	for colonist: ContinuumColonist in colonists:
		print("   %-5s %-11s goal=%-9s pos=(%2d,%2d) hunger=%3.0f fatigue=%3.0f rec=%3.0f mood=%3.0f prod=%3.0f"
				% [colonist.name, ContinuumActivity.parse_enum_name(colonist.activity.value),
					ContinuumGoal.parse_enum_name(colonist.goal.value), colonist.x, colonist.y,
					colonist.hunger, colonist.fatigue, colonist.recreation,
					colonist.mood, colonist.productivity])

	var recreation := _recreation_tiles()
	if recreation.is_empty():
		return _fail("no recreation tiles in the colony")
	recreation_was_enabled = recreation[0].enabled
	print("OK recreation enabled = %s (%d tiles) -> toggling via reducer"
			% [recreation_was_enabled, recreation.size()])

	client.reducers.set_zone_enabled(ContinuumTileKind.create_recreation(),
			not recreation_was_enabled)
	_next_phase()
	return false


## The toggle must arrive back through the subscription, not be assumed locally.
func _phase_check_reducer_applied() -> bool:
	var recreation := _recreation_tiles()
	if recreation.is_empty():
		return false
	if recreation[0].enabled == recreation_was_enabled:
		if elapsed - phase_started > 8.0:
			return _fail("subscription never reflected set_zone_enabled")
		return false

	print("OK subscription reflected the reducer: recreation enabled = %s"
			% recreation[0].enabled)
	client.reducers.set_zone_enabled(ContinuumTileKind.create_recreation(),
			recreation_was_enabled)
	_next_phase()
	return false


func _phase_restore() -> bool:
	var recreation := _recreation_tiles()
	if recreation.is_empty() or recreation[0].enabled != recreation_was_enabled:
		if elapsed - phase_started > 8.0:
			return _fail("could not restore the recreation zone")
		return false

	print("OK restored recreation enabled = %s" % recreation_was_enabled)
	var events: Array[ContinuumEventLog] = client.db.event_log.iter()
	events.sort_custom(func(a: ContinuumEventLog, b: ContinuumEventLog) -> bool:
		return a.id < b.id)
	print("OK recent events:")
	for event: ContinuumEventLog in events.slice(maxi(0, events.size() - 6)):
		print("   d%d %02d:%02d  %s" % [event.day, event.hour, event.minute, event.message])

	phase = 3
	_start_unauthorized_check()
	return false


func _start_unauthorized_check() -> void:
	unauthorized_client = ContinuumModuleClient.new()
	root.add_child(unauthorized_client)
	unauthorized_client.connection_error.connect(func(code: int, reason: String) -> void:
		_fail("unauthorized client connection error %d: %s" % [code, reason]))
	unauthorized_client.connected.connect(_on_unauthorized_connected)
	call_deferred("_connect_unauthorized_client")


func _connect_unauthorized_client() -> void:
	var host := _cli_option("--stdb-host", "http://127.0.0.1:3000")
	var database := _cli_option("--stdb-db", "continuum")
	var options := SpacetimeDBConnectionOptions.new()
	options.compression = SpacetimeDBConnection.CompressionPreference.NONE
	options.debug_mode = false
	options.one_time_token = true
	options.save_token = false
	unauthorized_client.connect_db(host, database, options)


func _on_unauthorized_connected(_identity: PackedByteArray, _token: String) -> void:
	var zone_call := unauthorized_client.reducers.set_zone_enabled(
			ContinuumTileKind.create_recreation(), false)
	if not await _expect_rejected(zone_call, "set_zone_enabled"):
		return

	var speed_call := unauthorized_client.reducers.set_time_scale(6.0)
	if not await _expect_rejected(speed_call, "set_time_scale"):
		return

	print("OK unauthorized reducers rejected")
	unauthorized_client.disconnect_db()
	client.disconnect_db()
	print("SMOKE_PASS")
	quit(0)


func _expect_rejected(call: SpacetimeDBReducerCall, reducer_name: String) -> bool:
	if call.error != OK:
		_fail("%s could not be sent by unauthorized client (%d)" % [reducer_name, call.error])
		return false
	var response: ReducerResultMessage = await call.response
	if response.reducer_result.value != ReducerOutcomeEnum.Options.err:
		_fail("unauthorized %s was accepted" % reducer_name)
		return false
	return true


func _next_phase() -> void:
	phase += 1
	phase_started = elapsed


func _recreation_tiles() -> Array[ContinuumTile]:
	var result: Array[ContinuumTile] = []
	for tile: ContinuumTile in client.db.tile.iter():
		if tile.kind.value == ContinuumTileKind.Options.recreation:
			result.append(tile)
	return result


func _fail(message: String) -> bool:
	printerr("SMOKE_FAIL: %s" % message)
	failed = true
	quit(1)
	return true
