## The single Continuum screen: colony map, status panel, alerts and event feed.
##
## Every value shown here comes from the SpacetimeDB subscription, and every button
## issues an intent-level reducer through the generated bindings. Nothing is
## predicted or mutated locally, so what you see is always what the server believes.
extends Control

## How often the side panel is rebuilt. The backend ticks once a real second;
## rebuilding on every individual row change would be wasteful.
const REFRESH_INTERVAL := 0.25

const MAX_FEED_LINES := 40

## `time_scale` is in-game seconds per real second. 6.0 is the intended rate
## (4 real hours per in-game day); the rest are development accelerations.
const TIME_SCALE_PRESETS := [
	{"label": "1x (4h/day)", "value": 6.0},
	{"label": "10x", "value": 60.0},
	{"label": "100x", "value": 600.0},
	{"label": "600x", "value": 3600.0},
]
const BASE_TIME_SCALE := 6.0
const RECONNECT_DELAY := 2.0
static var SUBSCRIPTION_QUERIES := PackedStringArray([
	"SELECT * FROM config", "SELECT * FROM colony", "SELECT * FROM tile",
	"SELECT * FROM colonist", "SELECT * FROM alert", "SELECT * FROM event_log",
])

const SEVERITY_COLORS: Array[Color] = [
	Color("9aa4b2"), Color("ffb74d"), Color("ff5c6c"),
]

## `invert` marks a need where high is bad, so the colour ramp is reversed.
const NEED_BARS := [
	{"key": "hunger", "label": "Hunger", "invert": true},
	{"key": "fatigue", "label": "Fatigue", "invert": true},
	{"key": "recreation", "label": "Recreation", "invert": true},
	{"key": "mood", "label": "Mood", "invert": false},
	{"key": "productivity", "label": "Productivity", "invert": false},
]

@onready var map: ColonyMap = $Layout/MapPanel/Map

var _status_label: RichTextLabel
var _colonist_box: VBoxContainer
var _alert_box: VBoxContainer
var _tile_action_box: VBoxContainer
var _recreation_button: Button
var _feed: RichTextLabel
var _connection_label: Label

var _subscription: SpacetimeDBSubscription
var _selected_tile_id: int = -1
var _dirty: bool = true
var _map_dirty: bool = true
var _refresh_timer: float = 0.0
var _host := ""
var _database := ""
var _reconnect_timer: SceneTreeTimer
var _closing := false


func _ready() -> void:
	_build_side_panel()
	map.tile_selected.connect(_on_tile_selected)

	var client: ContinuumModuleClient = SpacetimeDB.Continuum
	client.connected.connect(_on_connected)
	client.disconnected.connect(_on_disconnected)
	client.connection_error.connect(_on_connection_error)
	# Upstream currently gates its global transaction-completed signal behind
	# table-specific listeners. Row signals are always emitted, so coalesce them
	# into the existing refresh interval instead.
	client.row_inserted.connect(func(table_name: String, _row: Resource) -> void:
		_on_table_changed(table_name))
	client.row_updated.connect(func(table_name: String, _old: Resource, _new: Resource) -> void:
		_on_table_changed(table_name))
	client.row_deleted.connect(func(table_name: String, _row: Resource) -> void:
		_on_table_changed(table_name))

	var options := SpacetimeDBConnectionOptions.new()
	options.compression = SpacetimeDBConnection.CompressionPreference.NONE
	options.debug_mode = false

	# Host/database can be overridden on the command line, which makes running two
	# clients against one colony (or against a remote one) trivial:
	#   godot -- --stdb-host=http://127.0.0.1:3000 --stdb-db=continuum
	_host = _cli_option("--stdb-host", "http://127.0.0.1:3000")
	_database = _cli_option("--stdb-db", "continuum")

	_set_connection_text("connecting to %s / %s ..." % [_host, _database], Color("ffb74d"))
	client.connect_db(_host, _database, options)


func _cli_option(option: String, fallback: String) -> String:
	for argument: String in OS.get_cmdline_user_args():
		if argument.begins_with(option + "="):
			return argument.substr(option.length() + 1)
	return fallback


func _process(delta: float) -> void:
	_refresh_timer -= delta
	if (_dirty or _map_dirty) and _refresh_timer <= 0.0:
		_refresh_timer = REFRESH_INTERVAL
		if _dirty:
			_dirty = false
			_refresh()
		if _map_dirty:
			_map_dirty = false
			map.refresh()


func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_CLOSE_REQUEST or what == NOTIFICATION_CRASH:
		# Leaving cleanly matters here: the colony keeps running server-side, and a
		# tidy close means the server is not left holding a dead session.
		_closing = true
		SpacetimeDB.Continuum.disconnect_db()


# ---------------------------------------------------------------------------
# Connection lifecycle
# ---------------------------------------------------------------------------

func _on_connected(identity: PackedByteArray, _token: String) -> void:
	_reconnect_timer = null
	_set_connection_text("connected as %s..." % identity.hex_encode().substr(0, 12),
			Color("6fcf7f"))
	# Held for the life of the screen: a drop suspends this handle and the
	# reconnect re-registers it, so it must not be replaced.
	_subscription = SpacetimeDB.Continuum.subscribe(SUBSCRIPTION_QUERIES)
	if _subscription.error != OK:
		_set_connection_text("subscription failed (%d)" % _subscription.error, Color("ff5c6c"))
		return
	_subscription.applied.connect(_on_subscription_applied)


func _on_subscription_applied() -> void:
	_dirty = true
	_map_dirty = true


func _on_disconnected() -> void:
	_set_connection_text("disconnected - the colony keeps running without us",
			Color("ff5c6c"))
	_schedule_reconnect()


func _on_connection_error(code: int, reason: String) -> void:
	_set_connection_text("connection error %d: %s" % [code, reason], Color("ff5c6c"))
	_schedule_reconnect()


func _schedule_reconnect() -> void:
	if _closing or _reconnect_timer != null:
		return
	_set_connection_text("disconnected - retrying in %.0fs" % RECONNECT_DELAY, Color("ffb74d"))
	_reconnect_timer = get_tree().create_timer(RECONNECT_DELAY)
	_reconnect_timer.timeout.connect(_retry_connection.bind(_reconnect_timer))


func _retry_connection(timer: SceneTreeTimer) -> void:
	# A late timeout from an earlier attempt must not reconnect an active client.
	if timer != _reconnect_timer or SpacetimeDB.Continuum.is_connected_db():
		return
	_reconnect_timer = null
	var options := SpacetimeDBConnectionOptions.new()
	options.compression = SpacetimeDBConnection.CompressionPreference.NONE
	SpacetimeDB.Continuum.connect_db(_host, _database, options)


func _on_table_changed(table_name: String) -> void:
	_dirty = true
	if table_name == "tile" or table_name == "colonist":
		_map_dirty = true


# ---------------------------------------------------------------------------
# Intents
# ---------------------------------------------------------------------------

func _on_tile_selected(tile_id: int) -> void:
	_selected_tile_id = tile_id
	_dirty = true


func _recreation_tiles() -> Array[ContinuumTile]:
	var result: Array[ContinuumTile] = []
	for tile: ContinuumTile in SpacetimeDB.Continuum.db.tile.iter():
		if tile.kind.value == ContinuumTileKind.Options.recreation:
			result.append(tile)
	return result


func _toggle_recreation_zone() -> void:
	var any_enabled: bool = false
	for tile: ContinuumTile in _recreation_tiles():
		if tile.enabled:
			any_enabled = true
			break
	_report(SpacetimeDB.Continuum.reducers.set_zone_enabled(
			ContinuumTileKind.create_recreation(), not any_enabled), "set_zone_enabled")


func _toggle_selected_tile() -> void:
	var tile: ContinuumTile = SpacetimeDB.Continuum.db.tile.id.find(_selected_tile_id)
	if tile == null:
		return
	_report(SpacetimeDB.Continuum.reducers.set_tile_enabled(tile.id, not tile.enabled),
			"set_tile_enabled")


func _acknowledge(alert_id: int) -> void:
	_report(SpacetimeDB.Continuum.reducers.acknowledge_alert(alert_id), "acknowledge_alert")


func _set_time_scale(value: float) -> void:
	_report(SpacetimeDB.Continuum.reducers.set_time_scale(value), "set_time_scale")


## Surface a rejected reducer instead of letting it fail silently. The server is
## authoritative, so a refusal is real information.
func _report(call: SpacetimeDBReducerCall, reducer_name: String) -> void:
	if call.error != OK:
		_set_connection_text("%s could not be sent (%d)" % [reducer_name, call.error],
				Color("ff5c6c"))
		return
	var response: ReducerResultMessage = await call.response
	if response.reducer_result.value == ReducerOutcomeEnum.Options.err:
		_set_connection_text("%s was rejected: %s" % [
			reducer_name, response.reducer_result.get_err()], Color("ff5c6c"))
	elif response.reducer_result.value == ReducerOutcomeEnum.Options.internalError:
		_set_connection_text("%s failed: %s" % [
			reducer_name, response.reducer_result.get_internal_error()], Color("ff5c6c"))


# ---------------------------------------------------------------------------
# Side panel construction
# ---------------------------------------------------------------------------

func _build_side_panel() -> void:
	var side: VBoxContainer = $Layout/SidePanel/Margin/Scroll/Side
	side.add_theme_constant_override("separation", 10)

	_connection_label = Label.new()
	_connection_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_connection_label.add_theme_font_size_override("font_size", 11)
	side.add_child(_connection_label)

	side.add_child(_heading("Colony"))
	_status_label = RichTextLabel.new()
	_status_label.bbcode_enabled = true
	_status_label.fit_content = true
	_status_label.scroll_active = false
	side.add_child(_status_label)

	side.add_child(_heading("Colonists"))
	_colonist_box = VBoxContainer.new()
	_colonist_box.add_theme_constant_override("separation", 8)
	side.add_child(_colonist_box)

	side.add_child(_heading("Control"))
	_recreation_button = Button.new()
	_recreation_button.pressed.connect(_toggle_recreation_zone)
	side.add_child(_recreation_button)

	_tile_action_box = VBoxContainer.new()
	side.add_child(_tile_action_box)

	var speed_label := Label.new()
	speed_label.text = "Simulation speed"
	speed_label.add_theme_font_size_override("font_size", 11)
	side.add_child(speed_label)

	var speed_row := HBoxContainer.new()
	for preset: Dictionary in TIME_SCALE_PRESETS:
		var button := Button.new()
		button.text = str(preset["label"])
		button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		button.add_theme_font_size_override("font_size", 10)
		button.pressed.connect(_set_time_scale.bind(float(preset["value"])))
		speed_row.add_child(button)
	side.add_child(speed_row)

	side.add_child(_heading("Alerts"))
	_alert_box = VBoxContainer.new()
	_alert_box.add_theme_constant_override("separation", 4)
	side.add_child(_alert_box)

	side.add_child(_heading("Recent events"))
	_feed = RichTextLabel.new()
	_feed.bbcode_enabled = true
	_feed.custom_minimum_size = Vector2(0, 220)
	_feed.scroll_following = true
	side.add_child(_feed)


func _heading(text: String) -> Label:
	var label := Label.new()
	label.text = text.to_upper()
	label.add_theme_font_size_override("font_size", 11)
	label.add_theme_color_override("font_color", Color("7f8b9c"))
	return label


func _set_connection_text(text: String, colour: Color) -> void:
	if _connection_label == null:
		return
	_connection_label.text = text
	_connection_label.add_theme_color_override("font_color", colour)


# ---------------------------------------------------------------------------
# Refresh
# ---------------------------------------------------------------------------

func _refresh() -> void:
	_refresh_status()
	_refresh_colonists()
	_refresh_controls()
	_refresh_alerts()
	_refresh_feed()


func _refresh_status() -> void:
	var config: ContinuumConfig = SpacetimeDB.Continuum.db.config.id.find(0)
	var colony: ContinuumColony = SpacetimeDB.Continuum.db.colony.id.find(0)
	if config == null or colony == null:
		_status_label.text = "[color=#7f8b9c]waiting for colony state...[/color]"
		return

	var day: int = int(config.game_seconds / 86400.0) + 1
	var second_of_day: float = fmod(config.game_seconds, 86400.0)
	var hour: int = int(second_of_day / 3600.0)
	var minute: int = int(fmod(second_of_day, 3600.0) / 60.0)

	var food_pct: float = 0.0
	if colony.food_capacity > 0.0:
		food_pct = colony.food / colony.food_capacity * 100.0

	_status_label.text = "\n".join([
		"[b]Day %d[/b]  %02d:%02d   [color=#7f8b9c](%.0fx speed)[/color]"
				% [day, hour, minute, config.time_scale / BASE_TIME_SCALE],
		"Food: %s  [color=#7f8b9c](%.0f%%)[/color]" % [
			_coloured("%.0f / %.0f" % [colony.food, colony.food_capacity], food_pct),
			food_pct,
		],
		"Average mood: %s  [color=#7f8b9c](trend %.0f)[/color]" % [
			_coloured("%.0f%%" % colony.avg_mood, colony.avg_mood), colony.smoothed_mood,
		],
		"Average productivity: %s  [color=#7f8b9c](trend %.0f)[/color]" % [
			_coloured("%.0f%%" % colony.avg_productivity, colony.avg_productivity),
			colony.smoothed_productivity,
		],
		"Population: %d" % colony.population,
	])


func _coloured(text: String, value_0_100: float) -> String:
	var colour := "#6fcf7f"
	if value_0_100 < 30.0:
		colour = "#ff5c6c"
	elif value_0_100 < 60.0:
		colour = "#ffb74d"
	return "[color=%s]%s[/color]" % [colour, text]


func _refresh_colonists() -> void:
	for child in _colonist_box.get_children():
		child.queue_free()

	var colonists: Array[ContinuumColonist] = SpacetimeDB.Continuum.db.colonist.iter()
	colonists.sort_custom(func(a: ContinuumColonist, b: ContinuumColonist) -> bool:
		return a.id < b.id)

	for colonist: ContinuumColonist in colonists:
		var panel := VBoxContainer.new()
		panel.add_theme_constant_override("separation", 1)

		var header := Label.new()
		var suffix := ""
		if colonist.activity.value == ContinuumActivity.Options.travelling:
			suffix = " -> %s" % ContinuumGoal.parse_enum_name(colonist.goal.value).capitalize()
		header.text = "%s - %s%s" % [
			colonist.name, ContinuumActivity.parse_enum_name(colonist.activity.value).capitalize(), suffix,
		]
		header.add_theme_font_size_override("font_size", 13)
		panel.add_child(header)

		for bar: Dictionary in NEED_BARS:
			panel.add_child(_stat_row(str(bar["label"]),
					float(colonist.get(str(bar["key"]))), bool(bar["invert"])))

		_colonist_box.add_child(panel)


## One labelled 0-100 bar. `invert` means "high is bad" (a need), so the colour
## ramp is reversed relative to mood/productivity.
func _stat_row(label_text: String, value: float, invert: bool) -> HBoxContainer:
	var row := HBoxContainer.new()

	var label := Label.new()
	label.text = label_text
	label.custom_minimum_size = Vector2(84, 0)
	label.add_theme_font_size_override("font_size", 11)
	row.add_child(label)

	var bar := ProgressBar.new()
	bar.min_value = 0.0
	bar.max_value = 100.0
	bar.value = value
	bar.show_percentage = false
	bar.custom_minimum_size = Vector2(0, 12)
	bar.size_flags_horizontal = Control.SIZE_EXPAND_FILL

	var goodness := 100.0 - value if invert else value
	var fill := Color("6fcf7f")
	if goodness < 30.0:
		fill = Color("ff5c6c")
	elif goodness < 60.0:
		fill = Color("ffb74d")
	var style := StyleBoxFlat.new()
	style.bg_color = fill
	bar.add_theme_stylebox_override("fill", style)
	row.add_child(bar)

	var value_label := Label.new()
	value_label.text = "%3.0f" % value
	value_label.custom_minimum_size = Vector2(28, 0)
	value_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	value_label.add_theme_font_size_override("font_size", 11)
	row.add_child(value_label)

	return row


func _refresh_controls() -> void:
	var recreation: Array[ContinuumTile] = _recreation_tiles()
	var any_enabled: bool = false
	for tile: ContinuumTile in recreation:
		if tile.enabled:
			any_enabled = true
			break

	if recreation.is_empty():
		_recreation_button.text = "Recreation zone: unknown"
		_recreation_button.disabled = true
	else:
		_recreation_button.disabled = false
		_recreation_button.text = ("Disable recreation zone" if any_enabled
				else "Enable recreation zone")

	for child in _tile_action_box.get_children():
		child.queue_free()

	var info := Label.new()
	info.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	info.add_theme_font_size_override("font_size", 11)

	var tile: ContinuumTile = SpacetimeDB.Continuum.db.tile.id.find(_selected_tile_id)
	if tile == null:
		info.text = "Click a tile on the map to select it."
		_tile_action_box.add_child(info)
		return

	info.text = "Selected: %s tile #%d at (%d, %d) - %s" % [
		ContinuumTileKind.parse_enum_name(tile.kind.value).capitalize(), tile.id, tile.x, tile.y,
		"enabled" if tile.enabled else "disabled",
	]
	_tile_action_box.add_child(info)

	var button := Button.new()
	button.disabled = tile.kind.value == ContinuumTileKind.Options.empty
	if button.disabled:
		button.text = "Empty tiles cannot be toggled"
	else:
		button.text = "Disable this tile" if tile.enabled else "Enable this tile"
	button.pressed.connect(_toggle_selected_tile)
	_tile_action_box.add_child(button)


func _refresh_alerts() -> void:
	for child in _alert_box.get_children():
		child.queue_free()

	var active: Array[ContinuumAlert] = []
	for alert: ContinuumAlert in SpacetimeDB.Continuum.db.alert.iter():
		if alert.active:
			active.append(alert)
	active.sort_custom(func(a: ContinuumAlert, b: ContinuumAlert) -> bool: return a.id < b.id)

	if active.is_empty():
		var none := Label.new()
		none.text = "No active alerts."
		none.add_theme_font_size_override("font_size", 11)
		none.add_theme_color_override("font_color", Color("6fcf7f"))
		_alert_box.add_child(none)
		return

	for alert: ContinuumAlert in active:
		var row := HBoxContainer.new()

		var label := Label.new()
		label.text = alert.message + ("  (acknowledged)" if alert.acknowledged else "")
		label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		label.add_theme_font_size_override("font_size", 11)
		label.add_theme_color_override("font_color", _severity_colour(alert.severity))
		label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		row.add_child(label)

		if not alert.acknowledged:
			var ack := Button.new()
			ack.text = "Ack"
			ack.add_theme_font_size_override("font_size", 10)
			ack.pressed.connect(_acknowledge.bind(alert.id))
			row.add_child(ack)

		_alert_box.add_child(row)


func _severity_colour(severity: ContinuumSeverity) -> Color:
	return SEVERITY_COLORS[clampi(severity.value, 0, SEVERITY_COLORS.size() - 1)]


func _refresh_feed() -> void:
	var events: Array[ContinuumEventLog] = SpacetimeDB.Continuum.db.event_log.iter()
	events.sort_custom(func(a: ContinuumEventLog, b: ContinuumEventLog) -> bool:
		return a.id < b.id)
	if events.size() > MAX_FEED_LINES:
		events = events.slice(events.size() - MAX_FEED_LINES)

	var lines := PackedStringArray()
	for event: ContinuumEventLog in events:
		lines.append("[color=#5c6675]d%d %02d:%02d[/color] [color=%s]%s[/color]" % [
			event.day, event.hour, event.minute,
			_severity_colour(event.severity).to_html(false), event.message,
		])
	_feed.text = "\n".join(lines)
