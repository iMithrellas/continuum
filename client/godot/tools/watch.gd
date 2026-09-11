## A terminal observer for the colony: a second "client" with no UI.
##
##   godot --headless --path client/godot --script res://tools/watch.gd -- --seconds=120
##
## Connects with the same generated bindings the game client uses and prints a
## status line each in-game hour plus every new event and alert. Useful for
## watching the failure chain unfold, and for proving that a reducer invoked from
## the SpacetimeDB CLI reaches a connected client.
extends SceneTree

static var SUBSCRIPTION_QUERIES := PackedStringArray([
	"SELECT * FROM config", "SELECT * FROM colony", "SELECT * FROM tile",
	"SELECT * FROM colonist", "SELECT * FROM alert", "SELECT * FROM event_log",
	"SELECT * FROM item_stack",
	"SELECT * FROM speed_control",
])

var client: ContinuumModuleClient
var started := false
var elapsed := 0.0
var deadline := 120.0
var _last_reported_hour := -1
var _seen_events: Dictionary[int, bool] = {}
var _table_signals_connected := false


func _initialize() -> void:
	deadline = float(_cli_option("--seconds", "120"))
	client = ContinuumModuleClient.new()
	root.add_child(client)

	client.connected.connect(func(identity: PackedByteArray, _t: String) -> void:
		print("[watch] connected as %s" % identity.hex_encode().substr(0, 12))
		var subscription := client.subscribe(SUBSCRIPTION_QUERIES)
		subscription.applied.connect(_on_subscription_applied))
	client.connection_error.connect(func(code: int, reason: String) -> void:
		printerr("[watch] connection error %d: %s" % [code, reason]))


func _on_subscription_applied() -> void:
	# Initial subscription rows are delivered as inserts. Seed the history first so
	# the watcher only narrates events created after it connected.
	for event: ContinuumEventLog in client.db.event_log.iter():
		_seen_events[event.id] = true
	_connect_table_signals()
	for alert: ContinuumAlert in client.db.alert.iter():
		if alert.active:
			_on_alert(alert)


func _connect_table_signals() -> void:
	if _table_signals_connected:
		return
	_table_signals_connected = true
	# The database cache is created during connect_db, not client construction.
	client.db.event_log.on_insert(func(row: ContinuumEventLog) -> void:
		if not _seen_events.has(row.id):
			_seen_events[row.id] = true
			print("  [event] d%d %02d:%02d  %s" % [row.day, row.hour, row.minute, row.message]))
	client.db.alert.on_insert(_on_alert)
	client.db.alert.on_update(func(_old: ContinuumAlert, new_row: ContinuumAlert) -> void:
		_on_alert(new_row))


func _on_alert(alert: ContinuumAlert) -> void:
	print("  [ALERT %s] %s%s" % [
		"ACTIVE " if alert.active else "cleared",
		alert.message,
		"  (acknowledged)" if alert.acknowledged else "",
	])


func _cli_option(option: String, fallback: String) -> String:
	for argument: String in OS.get_cmdline_user_args():
		if argument.begins_with(option + "="):
			return argument.substr(option.length() + 1)
	return fallback


func _process(delta: float) -> bool:
	if not started:
		started = true
		var options := SpacetimeDBConnectionOptions.new()
		options.compression = SpacetimeDBConnection.CompressionPreference.NONE
		options.debug_mode = false
		client.connect_db(_cli_option("--stdb-host", "http://127.0.0.1:3000"),
				_cli_option("--stdb-db", "continuum"), options)
		return false

	elapsed += delta
	if elapsed > deadline:
		client.disconnect_db()
		quit(0)
		return true

	var config: ContinuumConfig = client.db.config.id.find(0)
	var colony: ContinuumColony = client.db.colony.id.find(0)
	if config == null or colony == null:
		return false

	var day: int = int(config.game_seconds / 86400.0) + 1
	var second_of_day: float = fmod(config.game_seconds, 86400.0)
	var hour: int = int(second_of_day / 3600.0)
	if hour == _last_reported_hour:
		return false
	_last_reported_hour = hour

	var workers := PackedStringArray()
	var colonists: Array[ContinuumColonist] = client.db.colonist.iter()
	colonists.sort_custom(func(a: ContinuumColonist, b: ContinuumColonist) -> bool:
		return a.id < b.id)
	for colonist: ContinuumColonist in colonists:
		var cargo := "empty"
		if colonist.carried_amount > 0.0:
			cargo = "%.1f %s" % [colonist.carried_amount,
				ContinuumResourceKind.parse_enum_name(colonist.carried_kind.value)]
		workers.append("    %-7s %-7s / %-8s %-10s cargo=%s" % [colonist.name,
			ContinuumWorkType.parse_enum_name(colonist.work.value),
			ContinuumHaulRole.parse_enum_name(colonist.haul_role.value),
			ContinuumActivity.parse_enum_name(colonist.activity.value), cargo])

	var ground: Dictionary[int, float] = {}
	for stack: ContinuumItemStack in client.db.item_stack.iter():
		ground[stack.kind.value] = ground.get(stack.kind.value, 0.0) + stack.amount
	var piles := PackedStringArray()
	for kind: int in [ContinuumResourceKind.Options.food, ContinuumResourceKind.Options.wood,
			ContinuumResourceKind.Options.stone, ContinuumResourceKind.Options.meat]:
		piles.append("%s %.1f" % [ContinuumResourceKind.parse_enum_name(kind), ground.get(kind, 0.0)])

	var recreation_on := false
	for tile: ContinuumTile in client.db.tile.iter():
		if tile.kind.value != ContinuumTileKind.Options.recreation:
			continue
		if tile.enabled:
			recreation_on = true
			break

	print("d%d %02d:00  stored: food %.1f wood %.1f stone %.1f meat %.1f (unlimited)  mood %3.0f  prod %3.0f  rec-zone %-3s  haul=%s" % [
		day, hour, colony.food, colony.wood, colony.stone, colony.meat,
		colony.smoothed_mood, colony.smoothed_productivity,
		"on" if recreation_on else "OFF", ContinuumHaulPolicy.parse_enum_name(config.haul_policy.value),
	])
	print("  ground (not stored): %s\n%s" % [", ".join(piles), "\n".join(workers)])
	return false
