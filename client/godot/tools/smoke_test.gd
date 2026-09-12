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
	"SELECT * FROM item_stack", "SELECT * FROM work_order",
	"SELECT * FROM speed_control",
])

var client: ContinuumModuleClient
var elapsed := 0.0
var phase := 0
var phase_started := 0.0
var recreation_was_enabled := false
var original_policy: ContinuumHaulPolicy
var original_meal_policy: ContinuumMealPolicy
var original_order: ContinuumWorkOrder
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
		3:
			return _phase_check_policy()
		4:
			return _phase_restore_policy()
		5:
			return _phase_check_meal_policy()
		6:
			return _phase_restore_meal_policy()
	return false


## Wait for the initial subscription, then dump what the colony looks like.
func _phase_read_state() -> bool:
	var tiles: Array[ContinuumTile] = client.db.tile.iter()
	var colonists: Array[ContinuumColonist] = client.db.colonist.iter()
	var config: ContinuumConfig = client.db.config.id.find(0)
	var colony: ContinuumColony = client.db.colony.id.find(0)
	if tiles.is_empty() or colonists.is_empty() or config == null or colony == null:
		return false

	print("OK identity      = ", client.get_local_identity().hex_encode())
	if tiles.size() != 24 * 24 or colonists.size() != 8:
		return _fail("expected a 24x24 colony with eight workers")
	original_policy = config.haul_policy
	original_meal_policy = config.meal_policy
	if not _check_speed_control():
		return true
	print("OK tiles         = %d, colonists = %d, events = %d"
			% [tiles.size(), colonists.size(), client.db.event_log.iter().size()])
	print("OK day %d  time_scale = %.0f  (%.0fx)"
			% [int(config.game_seconds / 86400.0) + 1, config.time_scale,
				config.time_scale / 6.0])
	print("OK stored        = food %.1f wood %.1f stone %.1f meat %.1f"
			% [colony.food, colony.wood, colony.stone, colony.meat])
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


## Additive schema updates may have no row; when present, verify the generated
## binding decoded the public singleton and optionally match an integration value.
func _check_speed_control() -> bool:
	var speed_control: ContinuumSpeedControl = client.db.speed_control.id.find(0)
	var expected := int(_cli_option("--expected-speed-cooldown", "-1"))
	if speed_control == null:
		if expected >= 0:
			return _fail("speed_control row is absent but an expected cooldown was provided")
		print("OK speed_control row absent (legacy additive default is accepted)")
		return true
	if speed_control.id != 0 or speed_control.cooldown_seconds > 3600:
		return _fail("speed_control row decoded invalid singleton values")
	if expected >= 0 and speed_control.cooldown_seconds != expected:
		return _fail("speed_control cooldown %d != expected %d" % [
			speed_control.cooldown_seconds, expected])
	print("OK speed_control decoded: cooldown=%d last_changed_at_some=%s" % [
		speed_control.cooldown_seconds,
		speed_control.last_changed_at.is_some()])
	return true


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

	var policy := ContinuumHaulPolicy.create_dedicated_haulers() if original_policy.value == ContinuumHaulPolicy.Options.selfHaul else ContinuumHaulPolicy.create_self_haul()
	client.reducers.set_haul_policy(policy)
	_next_phase()
	return false


func _phase_check_policy() -> bool:
	var config: ContinuumConfig = client.db.config.id.find(0)
	if config.haul_policy.value == original_policy.value:
		return false
	if not _roles_match_policy(config.haul_policy):
		return false
	print("OK subscription reflected hauling mode and worker role changes")
	client.reducers.set_haul_policy(original_policy)
	_next_phase()
	return false


func _phase_restore_policy() -> bool:
	var config: ContinuumConfig = client.db.config.id.find(0)
	if config.haul_policy.value != original_policy.value:
		return false
	if not _roles_match_policy(original_policy):
		return false
	print("OK restored hauling mode")
	client.reducers.set_meal_policy(ContinuumMealPolicy.create_rationed())
	_next_phase()
	return false


func _phase_check_meal_policy() -> bool:
	var config: ContinuumConfig = client.db.config.id.find(0)
	if config.meal_policy.value != ContinuumMealPolicy.Options.rationed:
		return false
	print("OK subscription reflected rationed meal policy")
	client.reducers.set_meal_policy(original_meal_policy)
	_next_phase()
	return false


func _phase_restore_meal_policy() -> bool:
	var config: ContinuumConfig = client.db.config.id.find(0)
	if config.meal_policy.value != original_meal_policy.value:
		return false
	print("OK restored meal policy")
	_next_phase()
	_check_work_orders()
	return false


func _check_work_orders() -> void:
	var orders: Array[ContinuumWorkOrder] = client.db.work_order.iter()
	if orders.is_empty():
		_fail("no work orders: create one manually or explicitly reset the colony")
		return
	var first := orders[0]
	original_order = ContinuumWorkOrder.create(first.id, first.tile_id,
			first.work, first.priority, first.enabled)
	var order := original_order
	if not await _expect_rejected(client.reducers.set_work_order(
			order.tile_id, order.work, 0, true), "set_work_order invalid priority"):
		return
	if not await _expect_rejected(client.reducers.set_work_order(
			_recreation_tiles()[0].id, order.work, 2, true), "set_work_order wrong facility"):
		return

	var priority := 1 if order.priority != 1 else 3
	client.reducers.set_work_order(order.tile_id, order.work, priority, true)
	if not await _wait_for_order(priority, true):
		return
	client.reducers.set_work_order(order.tile_id, order.work, priority, false)
	if not await _wait_for_order(priority, false):
		return
	client.reducers.remove_work_order(order.id)
	if not await _wait_for_order(priority, false, true):
		return
	client.reducers.set_work_order(order.tile_id, order.work, order.priority, order.enabled)
	if not await _wait_for_order(order.priority, order.enabled):
		return
	print("OK subscription reflected work order priority, pause, removal, and restoration")
	_start_unauthorized_check()


func _wait_for_order(priority: int, enabled: bool, removed := false) -> bool:
	while not failed and elapsed <= TIMEOUT_SECONDS:
		var order: ContinuumWorkOrder = client.db.work_order.id.find(original_order.id)
		if removed:
			if order == null:
				return true
		elif order != null and order.tile_id == original_order.tile_id \
				and order.work.value == original_order.work.value \
				and order.priority == priority and order.enabled == enabled:
			return true
		await process_frame
	if not failed:
		_fail("subscription never reflected work order change")
	return false


func _roles_match_policy(policy: ContinuumHaulPolicy) -> bool:
	for colonist: ContinuumColonist in client.db.colonist.iter():
		var expected := ContinuumHaulRole.Options.both
		if policy.value == ContinuumHaulPolicy.Options.dedicatedHaulers:
			expected = ContinuumHaulRole.Options.producer if colonist.id % 2 == 1 else ContinuumHaulRole.Options.hauler
		if colonist.haul_role.value != expected:
			return false
	return true


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

	var haul_call := unauthorized_client.reducers.set_haul_policy(ContinuumHaulPolicy.create_dedicated_haulers())
	if not await _expect_rejected(haul_call, "set_haul_policy"):
		return

	var meal_call := unauthorized_client.reducers.set_meal_policy(ContinuumMealPolicy.create_rationed())
	if not await _expect_rejected(meal_call, "set_meal_policy"):
		return

	var order := original_order
	var order_call := unauthorized_client.reducers.set_work_order(
			order.tile_id, order.work, order.priority, not order.enabled)
	if not await _expect_rejected(order_call, "unauthorized set_work_order"):
		return
	var remove_call := unauthorized_client.reducers.remove_work_order(order.id)
	if not await _expect_rejected(remove_call, "unauthorized remove_work_order"):
		return

	print("OK unauthorized reducers rejected")
	unauthorized_client.disconnect_db()
	client.disconnect_db()
	print("SMOKE_PASS")
	quit(0)


func _expect_rejected(call: SpacetimeDBReducerCall, reducer_name: String) -> bool:
	if call.error != OK:
		_fail("%s could not be sent (%d)" % [reducer_name, call.error])
		return false
	var response: ReducerResultMessage = await call.response
	if response.reducer_result.value != ReducerOutcomeEnum.Options.err:
		_fail("%s was accepted but should have been rejected" % reducer_name)
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
