## The single Continuum screen: colony map, status panel, alerts and event feed.
##
## Every value shown here comes from the SpacetimeDB subscription, and every button
## issues an intent-level reducer through the generated bindings. Nothing is
## predicted or mutated locally, so what you see is always what the server believes.
extends Control

const SessionHistoryModel = preload("res://scripts/session_history.gd")
const HistoryChartControl = preload("res://scripts/history_chart.gd")

## How often the side panel is rebuilt. The backend ticks once a real second;
## rebuilding on every individual row change would be wasteful.
const REFRESH_INTERVAL := 0.25

const MAX_FEED_LINES := 40

## `time_scale` is in-game seconds per real second. 6.0 is the intended rate
## (4 real hours per in-game day).
const BASE_TIME_SCALE := 6.0
const RECONNECT_DELAY := 2.0
static var SUBSCRIPTION_QUERIES := PackedStringArray([
	"SELECT * FROM config", "SELECT * FROM colony", "SELECT * FROM tile",
	"SELECT * FROM colonist", "SELECT * FROM alert", "SELECT * FROM event_log",
	"SELECT * FROM item_stack", "SELECT * FROM work_order",
	"SELECT * FROM speed_control", "SELECT * FROM terrain", "SELECT * FROM world_seed",
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
@onready var sidebar: ContinuumSidebar = $Layout/SidePanel

var _status_label: RichTextLabel
var _colonist_box: VBoxContainer
var _alert_box: VBoxContainer
var _tile_action_box: VBoxContainer
var _tile_info: Label
var _order_summary: Label
var _speed_buttons: Dictionary = {}
var _speed_label: Label
var _intent_feedback: Label
var _intent_request: SpacetimeDBReducerCall
var _intent_seconds := 0.0
var _intent_name := ""
var _recreation_button: Button
var _feed: RichTextLabel
var _connection_label: Label
var _connection_message := ""
var _connection_colour := Color("7f8b9c")
var _haul_button: Button
var _haul_description: Label
var _haul_feedback: Label
var _haul_request: SpacetimeDBReducerCall
var _haul_request_seconds := 0.0
var _meal_buttons: Dictionary = {}
var _meal_description: Label
var _meal_feedback: Label
var _meal_request: SpacetimeDBReducerCall
var _meal_request_seconds := 0.0
var _state_ready := false

var _subscription: SpacetimeDBSubscription
var _selected_tile_id: int = -1
var _selected_rect := Rect2i()
var _mode_buttons: Dictionary = {}
var _build_menu: OptionButton
var _block_box: VBoxContainer
var _block_info: Label
var _block_controls: Dictionary = {}
## Test harnesses may record the final intent without pretending a reducer succeeded.
var map_intent_override: Callable
var _dirty: bool = true
var _map_dirty: bool = true
var _refresh_timer: float = 0.0
var _host := ""
var _database := ""
var _reconnect_timer: SceneTreeTimer
var _closing := false
var _history: SessionHistory
var _history_chart: HistoryChart
var _build_help: Label
var _orders_help: Label
var _role_name := "Unknown"
var _can_operate := false
var _is_admin := false
var _sections: Dictionary = {}


func _ready() -> void:
	_history = SessionHistoryModel.new()
	sidebar.setup()
	_build_side_panel()
	map.tile_selected.connect(_on_tile_selected)
	map.rectangle_selected.connect(_on_rectangle_selected)
	map.build_rectangle_requested.connect(_on_build_rectangle_requested)

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
	options.one_time_token = false
	options.save_token = true

	# Host/database can be overridden on the command line, which makes running two
	# clients against one colony (or against a remote one) trivial:
	#   godot -- --stdb-host=http://127.0.0.1:3000 --stdb-db=continuum
	_host = _cli_option("--stdb-host", "http://127.0.0.1:3000")
	_database = _cli_option("--stdb-db", "continuum")
	client.token_save_path = _identity_token_path(_host, _database)

	_set_connection_text("connecting to %s / %s ..." % [_host, _database], Color("ffb74d"))
	client.connect_db(_host, _database, options)


## Integration seam for the next trusted, server-backed role provider. That module
## should call this after its server membership/role response is authoritative:
## `_set_permissions(server_role, server_role != "viewer", server_role == "admin")`.
## Do not derive these values from the identity token or local JWT. Until the call,
## and after disconnect, the UI remains fail-closed as Unknown/viewer. This slice
## is not live-admin ready until that provider is wired and its server tests exist.
func _set_permissions(role_name: String, can_operate: bool, is_admin: bool) -> void:
	var lost_operator := _can_operate and not can_operate
	_role_name = role_name if not role_name.is_empty() else "Unknown"
	_is_admin = is_admin and can_operate
	_can_operate = can_operate and _role_name != "Unknown"
	if lost_operator and map.interaction_mode == &"build":
		map.set_interaction_mode(&"select")
		_set_feedback(_intent_feedback, "Build cancelled", "Build cancelled: operator permission was lost.")
		_intent_feedback.add_theme_color_override("font_color", Color("ffb74d"))
	_refresh_permissions()
	_refresh_controls()
	_render_connection_role()


func _cli_option(option: String, fallback: String) -> String:
	for argument: String in OS.get_cmdline_user_args():
		if argument.begins_with(option + "="):
			return argument.substr(option.length() + 1)
	return fallback


func _identity_token_path(host: String, database: String) -> String:
	return "user://continuum_identity_%s.token" % (host + "/" + database).md5_text()


func _unhandled_input(event: InputEvent) -> void:
	if not event is InputEventKey or not event.pressed or event.echo:
		return
	var key_event := event as InputEventKey
	if key_event.ctrl_pressed and key_event.keycode == KEY_F:
		sidebar.search.grab_focus()
		get_viewport().set_input_as_handled()
	elif key_event.ctrl_pressed and key_event.keycode == KEY_BACKSLASH:
		sidebar.toggle()
		get_viewport().set_input_as_handled()
	elif key_event.keycode == KEY_ESCAPE and sidebar.search.has_focus():
		sidebar.search.clear()
		get_viewport().set_input_as_handled()


func _process(delta: float) -> void:
	_sample_history()
	if _intent_request != null:
		_intent_seconds -= delta
		if _intent_seconds <= 0.0:
			_intent_request = null
			_set_feedback(_intent_feedback, "No response", "%s: no response. Outcome unknown; check server state before retrying." % _intent_name)
			_dirty = true
	if _haul_request != null:
		_haul_request_seconds -= delta
		if _haul_request_seconds <= 0.0:
			_haul_request = null
			_set_feedback(_haul_feedback, "No response", "No response received. Outcome unknown; check the server mode before retrying.")
			_haul_feedback.add_theme_color_override("font_color", Color("ffb74d"))
			_dirty = true
	if _meal_request != null:
		_meal_request_seconds -= delta
		if _meal_request_seconds <= 0.0:
			_meal_request = null
			_set_feedback(_meal_feedback, "No response", "No response received. Outcome unknown; check the server meal policy before retrying.")
			_meal_feedback.add_theme_color_override("font_color", Color("ffb74d"))
			_dirty = true
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


func _on_connected(identity: PackedByteArray, _token: String) -> void:
	_reconnect_timer = null
	print("Continuum identity: %s" % identity.hex_encode())
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
	_state_ready = true
	_dirty = true
	_map_dirty = true


func _on_disconnected() -> void:
	_set_permissions("Unknown", false, false)
	_history.reset()
	_history_chart.set_points([])
	_set_connection_text("disconnected - the colony keeps running without us",
			Color("ff5c6c"))
	_schedule_reconnect()


func _on_connection_error(code: int, reason: String) -> void:
	_set_connection_text("connection error %d: %s" % [code, reason], Color("ff5c6c"))
	_schedule_reconnect()


func _schedule_reconnect() -> void:
	_state_ready = false
	if _intent_request != null:
		_intent_request = null
		_set_feedback(_intent_feedback, "Connection lost", "%s: connection lost; outcome unknown. Waiting for server state." % _intent_name)
	if _haul_request != null:
		_haul_request = null
		_set_feedback(_haul_feedback, "Connection lost", "Connection lost. Hauling request outcome unknown; waiting for server state.")
		_haul_feedback.add_theme_color_override("font_color", Color("ffb74d"))
	if _meal_request != null:
		_meal_request = null
		_set_feedback(_meal_feedback, "Connection lost", "Connection lost. Meal policy outcome unknown; waiting for server state.")
		_meal_feedback.add_theme_color_override("font_color", Color("ffb74d"))
	_dirty = true
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
	options.debug_mode = false
	options.one_time_token = false
	options.save_token = true
	SpacetimeDB.Continuum.connect_db(_host, _database, options)


func _on_table_changed(table_name: String) -> void:
	_dirty = true
	if table_name in ["tile", "terrain", "world_seed", "colonist", "item_stack", "work_order", "colony", "config"]:
		_map_dirty = true


func _on_tile_selected(tile_id: int) -> void:
	_selected_tile_id = tile_id
	_selected_rect = map.selected_rect()
	_refresh_controls()
	_dirty = true


func _on_rectangle_selected(rect: Rect2i) -> void:
	_selected_rect = rect
	map.set_selected_rect(rect)
	var tile: ContinuumTile = _tile_at(rect.position)
	_selected_tile_id = tile.id if tile != null else -1
	_refresh_controls()
	_dirty = true


func _tile_at(pos: Vector2i) -> ContinuumTile:
	for tile: ContinuumTile in SpacetimeDB.Continuum.db.tile.iter():
		if Vector2i(tile.x, tile.y) == pos:
			return tile
	return null


func _on_build_rectangle_requested(rect: Rect2i) -> void:
	_selected_rect = rect
	map.set_selected_rect(rect)
	_refresh_controls()
	if not _can_operate:
		_set_feedback(_intent_feedback, "Build blocked", "Build blocked: operator permission is not available.")
		return
	if not can_send_map_intent(_state_ready, _intent_request != null):
		_set_feedback(_intent_feedback, "Build blocked", "Build blocked: waiting for subscription or another request.")
		return
	var colony: ContinuumColony = SpacetimeDB.Continuum.db.colony.id.find(0)
	var occupied := 0
	for tile: ContinuumTile in SpacetimeDB.Continuum.db.tile.iter():
		if rect.has_point(Vector2i(tile.x, tile.y)) and tile.kind.value != ContinuumTileKind.Options.empty:
			occupied += 1
	var cost := rect.size.x * rect.size.y * 20.0
	if occupied > 0:
		_set_feedback(_intent_feedback, "Build rejected", "Build rejected locally: %d cell(s) already occupied." % occupied)
		return
	if colony == null or colony.wood < cost:
		_set_feedback(_intent_feedback, "Build unavailable", "Build unavailable: needs %.0f wood (stored %.1f)." % [cost, 0.0 if colony == null else colony.wood])
		return
	_dispatch_build_block(rect, ContinuumTileKind.create(_build_menu.get_selected_id()))


func _dispatch_build_block(rect: Rect2i, kind: ContinuumTileKind) -> void:
	if not _can_operate:
		_set_feedback(_intent_feedback, "Build blocked", "Build blocked: operator permission is not available.")
		return
	if map_intent_override.is_valid():
		map_intent_override.call("build_tile_block", [rect.position.x, rect.position.y,
			rect.end.x - 1, rect.end.y - 1, kind])
		return
	_track_intent(SpacetimeDB.Continuum.reducers.build_tile_block(
			rect.position.x, rect.position.y, rect.end.x - 1, rect.end.y - 1, kind),
			"Build %dx%d block" % [rect.size.x, rect.size.y])


static func can_send_map_intent(state_ready: bool, pending: bool) -> bool:
	return state_ready and not pending


func _set_mode(mode: StringName) -> void:
	if mode == &"build" and not _can_operate:
		_set_feedback(_intent_feedback, "Operator permission required", "Build mode requires operator permission.")
		return
	map.set_interaction_mode(mode)
	for key: StringName in _mode_buttons:
		_mode_buttons[key].set_pressed_no_signal(key == mode)
	if mode == &"build":
		_set_feedback(_intent_feedback, "Build: drag rectangle", "Choose a type, then drag a rectangle on empty ground. Esc/right-click cancels.")
	else:
		_set_feedback(_intent_feedback, "Select: drag rectangle", "Drag a rectangle to control the whole block.")


func _recreation_tiles() -> Array[ContinuumTile]:
	var result: Array[ContinuumTile] = []
	for tile: ContinuumTile in SpacetimeDB.Continuum.db.tile.iter():
		if tile.kind.value == ContinuumTileKind.Options.recreation:
			result.append(tile)
	return result


func _toggle_recreation_zone() -> void:
	if not _can_operate:
		return
	var any_enabled: bool = false
	for tile: ContinuumTile in _recreation_tiles():
		if tile.enabled:
			any_enabled = true
			break
	_report(SpacetimeDB.Continuum.reducers.set_zone_enabled(
			ContinuumTileKind.create_recreation(), not any_enabled), "set_zone_enabled")


func _change_speed(speed: float) -> void:
	if not _is_admin:
		return
	_refresh_controls()
	# Authorization remains entirely in the reducer; there is no client-side admin guess.
	if _state_ready and _intent_request == null:
		_track_intent(SpacetimeDB.Continuum.reducers.set_time_scale(speed), "Simulation speed")


func _track_intent(call: SpacetimeDBReducerCall, description: String) -> void:
	_intent_feedback.add_theme_color_override("font_color", Color("ffb74d"))
	if call.error != OK:
		_set_feedback(_intent_feedback, "Send failed", "%s could not be sent (%d)." % [description, call.error])
		_refresh_controls()
		return
	_intent_request = call
	_intent_name = description
	_intent_seconds = 10.0
	_set_feedback(_intent_feedback, "Pending", "%s: pending. Displayed values follow the server." % description)
	call.response.connect(func(response: ReducerResultMessage) -> void:
		if _intent_request != call:
			return
		_intent_request = null
		_dirty = true
		_intent_feedback.add_theme_color_override("font_color", Color("ff5c6c"))
		if response.reducer_result.value == ReducerOutcomeEnum.Options.err:
			_set_feedback(_intent_feedback, "Rejected", "%s rejected: %s" % [description, response.reducer_result.get_err()])
		elif response.reducer_result.value == ReducerOutcomeEnum.Options.internalError:
			_set_feedback(_intent_feedback, "Failed", "%s failed: %s" % [description, response.reducer_result.get_internal_error()])
		else:
			_set_feedback(_intent_feedback, "Accepted", "%s accepted. Values follow server state." % description)
			_intent_feedback.add_theme_color_override("font_color", Color("6fcf7f"))
	, CONNECT_ONE_SHOT)
	_refresh_controls()


func _acknowledge(alert_id: int) -> void:
	if not _can_operate:
		return
	_report(SpacetimeDB.Continuum.reducers.acknowledge_alert(alert_id), "acknowledge_alert")


func _toggle_haul_policy() -> void:
	if not _can_operate or not _state_ready or _haul_request != null:
		return
	var config: ContinuumConfig = SpacetimeDB.Continuum.db.config.id.find(0)
	if config == null:
		return
	var policy := ContinuumHaulPolicy.create_dedicated_haulers()
	if config.haul_policy.value == ContinuumHaulPolicy.Options.dedicatedHaulers:
		policy = ContinuumHaulPolicy.create_self_haul()
	var call := SpacetimeDB.Continuum.reducers.set_haul_policy(policy)
	_haul_feedback.add_theme_color_override("font_color", Color("ffb74d"))
	if call.error != OK:
		_set_feedback(_haul_feedback, "Send failed", "Hauling mode could not be sent (%d)." % call.error)
		return
	_haul_request = call
	_haul_request_seconds = 10.0
	_set_feedback(_haul_feedback, "Pending", "Request sent. Waiting for the server; displayed mode is not changed locally.")
	call.response.connect(_on_haul_policy_response.bind(call.request_id), CONNECT_ONE_SHOT)
	_dirty = true
	_haul_button.disabled = true


func _on_haul_policy_response(response: ReducerResultMessage, request_id: int) -> void:
	if _haul_request == null or request_id != _haul_request.request_id:
		return
	_haul_request = null
	_dirty = true
	_haul_feedback.add_theme_color_override("font_color", Color("ff5c6c"))
	if response.reducer_result.value == ReducerOutcomeEnum.Options.err:
		_set_feedback(_haul_feedback, "Rejected", "Hauling mode rejected: %s" % response.reducer_result.get_err())
	elif response.reducer_result.value == ReducerOutcomeEnum.Options.internalError:
		_set_feedback(_haul_feedback, "Failed", "Hauling mode failed: %s" % response.reducer_result.get_internal_error())
	else:
		_set_feedback(_haul_feedback, "Accepted", "Request accepted. The mode above follows server state.")
		_haul_feedback.add_theme_color_override("font_color", Color("6fcf7f"))


func _set_meal_policy(policy: int) -> void:
	if not _can_operate or not _state_ready or _meal_request != null:
		return
	var config: ContinuumConfig = SpacetimeDB.Continuum.db.config.id.find(0)
	if config == null:
		return
	if config.meal_policy.value == policy:
		_refresh_controls()
		return
	var call := SpacetimeDB.Continuum.reducers.set_meal_policy(ContinuumMealPolicy.create(policy))
	_meal_feedback.add_theme_color_override("font_color", Color("ffb74d"))
	if call.error != OK:
		_set_feedback(_meal_feedback, "Send failed", "Meal policy could not be sent (%d)." % call.error)
		_refresh_controls()
		return
	_meal_request = call
	_meal_request_seconds = 10.0
	_set_feedback(_meal_feedback, "Pending", "Request sent. Waiting for the server; displayed policy is not changed locally.")
	call.response.connect(_on_meal_policy_response.bind(call.request_id), CONNECT_ONE_SHOT)
	_dirty = true
	_refresh_controls()


func _on_meal_policy_response(response: ReducerResultMessage, request_id: int) -> void:
	if _meal_request == null or request_id != _meal_request.request_id:
		return
	_meal_request = null
	_dirty = true
	_meal_feedback.add_theme_color_override("font_color", Color("ff5c6c"))
	if response.reducer_result.value == ReducerOutcomeEnum.Options.err:
		_set_feedback(_meal_feedback, "Rejected", "Meal policy rejected: %s" % response.reducer_result.get_err())
	elif response.reducer_result.value == ReducerOutcomeEnum.Options.internalError:
		_set_feedback(_meal_feedback, "Failed", "Meal policy failed: %s" % response.reducer_result.get_internal_error())
	else:
		_set_feedback(_meal_feedback, "Accepted", "Request accepted. The policy above follows server state.")
		_meal_feedback.add_theme_color_override("font_color", Color("6fcf7f"))


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


func _build_side_panel() -> void:
	var side: VBoxContainer = sidebar.add_section("overview", "Overview", ["status", "colony", "resources"])
	_sections["overview"] = side
	_sections["operations"] = sidebar.add_section("operations", "Operations", ["map", "build", "select", "block", "production"])
	_sections["policies"] = sidebar.add_section("policies", "Policies", ["meal", "hauling", "recreation"])
	_sections["people"] = sidebar.add_section("people", "People", ["colonists", "workers", "roster"])
	_sections["alerts"] = sidebar.add_section("alerts", "Alerts", ["warning", "acknowledge"])
	_sections["activity"] = sidebar.add_section("activity", "Activity", ["history", "events", "feed"])
	_sections["administration"] = sidebar.add_section("administration", "Administration", ["speed", "admin"])
	var section: VBoxContainer = _sections["overview"]
	side = section

	_connection_label = Label.new()
	_connection_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_connection_label.add_theme_font_size_override("font_size", 11)
	side.add_child(_connection_label)

	section = _sections["policies"]
	side = section
	side.add_child(_heading("Global hauling mode"))
	_haul_button = Button.new()
	_haul_button.text = "Waiting for hauling policy..."
	_haul_button.disabled = true
	_haul_button.add_theme_font_size_override("font_size", 15)
	_haul_button.tooltip_text = "Toggle hauling assignment. Server state remains authoritative."
	_haul_button.pressed.connect(_toggle_haul_policy)
	side.add_child(_haul_button)
	_haul_description = Label.new()
	_haul_description.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_haul_description.add_theme_font_size_override("font_size", 12)
	side.add_child(_haul_description)
	_haul_feedback = Label.new()
	_haul_feedback.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_haul_feedback.add_theme_font_size_override("font_size", 11)
	side.add_child(_haul_feedback)

	side.add_child(_heading("Global meal policy"))
	var meal_buttons := HBoxContainer.new()
	for policy: int in [ContinuumMealPolicy.Options.normal, ContinuumMealPolicy.Options.rationed]:
		var button := Button.new()
		button.text = "Normal" if policy == ContinuumMealPolicy.Options.normal else "Rationed"
		button.toggle_mode = true
		button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		button.pressed.connect(_set_meal_policy.bind(policy))
		meal_buttons.add_child(button)
		_meal_buttons[policy] = button
	side.add_child(meal_buttons)
	_meal_description = Label.new()
	_meal_description.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_meal_description.add_theme_font_size_override("font_size", 12)
	side.add_child(_meal_description)
	_meal_feedback = Label.new()
	_meal_feedback.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_meal_feedback.add_theme_font_size_override("font_size", 11)
	side.add_child(_meal_feedback)

	section = _sections["overview"]
	side = section
	side.add_child(_heading("Colony"))
	_status_label = RichTextLabel.new()
	_status_label.bbcode_enabled = true
	_status_label.fit_content = true
	_status_label.scroll_active = false
	side.add_child(_status_label)

	section = _sections["activity"]
	side = section
	side.add_child(_heading("Session history"))
	var history_note := Label.new()
	history_note.text = "Session history"
	history_note.tooltip_text = "This session / since connection. Not saved on the server."
	history_note.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	history_note.add_theme_font_size_override("font_size", 11)
	history_note.add_theme_color_override("font_color", Color("7f8b9c"))
	side.add_child(history_note)
	_history_chart = HistoryChartControl.new()
	side.add_child(_history_chart)

	section = _sections["administration"]
	side = section
	side.add_child(_heading("Simulation speed (admin-only)"))
	_speed_label = Label.new()
	side.add_child(_speed_label)
	var speeds := HBoxContainer.new()
	for speed: int in [0, 6, 60, 600, 3600]:
		var button := Button.new()
		button.text = "Pause" if speed == 0 else "%dx" % (speed / 6)
		button.toggle_mode = true
		button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		button.pressed.connect(_change_speed.bind(float(speed)))
		speeds.add_child(button)
		_speed_buttons[speed] = button
	side.add_child(speeds)

	section = _sections["operations"]
	side = section
	side.add_child(_heading("Map tools"))
	var modes := HBoxContainer.new()
	for mode: StringName in [&"select", &"build"]:
		var button := Button.new()
		button.text = "Select" if mode == &"select" else "Build"
		button.toggle_mode = true
		button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		button.pressed.connect(_set_mode.bind(mode))
		modes.add_child(button)
		_mode_buttons[mode] = button
	side.add_child(modes)
	_build_menu = OptionButton.new()
	for kind: int in [ContinuumTileKind.Options.farm, ContinuumTileKind.Options.forest,
			ContinuumTileKind.Options.mine, ContinuumTileKind.Options.storage,
			ContinuumTileKind.Options.dining, ContinuumTileKind.Options.sleep,
			ContinuumTileKind.Options.recreation]:
		_build_menu.add_item(ContinuumTileKind.parse_enum_name(kind).capitalize(), kind)
	_build_menu.item_selected.connect(func(index: int) -> void:
		map.set_build_kind(_build_menu.get_item_id(index)))
	side.add_child(_build_menu)
	_build_help = Label.new()
	_build_help.text = "7 types | 20 wood/cell"
	_build_help.tooltip_text = "Farm, Forestry, Mine, Storage, Dining, Sleep, Recreation. Forestry creates a Forest work zone; natural forest cover is separate terrain."
	_build_help.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_build_help.add_theme_font_size_override("font_size", 11)
	side.add_child(_build_help)
	_block_box = VBoxContainer.new()
	_block_info = Label.new()
	_block_info.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_block_box.add_child(_block_info)
	var enabled_row := HBoxContainer.new()
	for enabled: bool in [true, false]:
		var button := Button.new()
		button.text = "Enable block" if enabled else "Disable block"
		button.pressed.connect(_set_block_enabled.bind(enabled))
		enabled_row.add_child(button)
		_block_controls["enabled_%s" % enabled] = button
	_block_box.add_child(enabled_row)
	for work: int in [ContinuumWorkType.Options.farming, ContinuumWorkType.Options.logging,
			ContinuumWorkType.Options.mining, ContinuumWorkType.Options.hunting]:
		var row := HBoxContainer.new()
		var label := Label.new()
		label.text = ContinuumWorkType.parse_enum_name(work).capitalize()
		label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		row.add_child(label)
		var add := Button.new()
		add.text = "N"
		add.tooltip_text = "Normal priority"
		add.pressed.connect(_set_block_work.bind(work, 2, true))
		row.add_child(add)
		var priority_buttons: Array[Button] = []
		for priority: int in [1, 2, 3]:
			var priority_button := Button.new()
			priority_button.text = ColonyMap.PRIORITY_NAMES[priority].left(1)
			priority_button.tooltip_text = "%s priority" % ColonyMap.PRIORITY_NAMES[priority]
			priority_button.pressed.connect(_set_block_work.bind(work, priority, true))
			row.add_child(priority_button)
			priority_buttons.append(priority_button)
		var pause := Button.new()
		pause.text = "Pause"
		pause.pressed.connect(_set_block_work.bind(work, 2, false))
		row.add_child(pause)
		_block_controls[work] = {"row": row, "label": label, "set": add, "priority": priority_buttons, "pause": pause}
		_block_box.add_child(row)
	side.add_child(_block_box)

	side.add_child(_heading("Selected tile detail (inspect)"))
	_tile_action_box = VBoxContainer.new()
	side.add_child(_tile_action_box)
	_tile_info = Label.new()
	_tile_info.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_tile_action_box.add_child(_tile_info)
	_order_summary = Label.new()
	_order_summary.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	side.add_child(_order_summary)
	_orders_help = Label.new()
	_orders_help.text = "Orders: priority + distance"
	_orders_help.tooltip_text = "Orders rank sites within fixed professions: priority, then distance (server decides ties). Missing/paused orders stop production, not hauling old goods. Create starts enabled / Normal."
	side.add_child(_orders_help)
	_intent_feedback = Label.new()
	_intent_feedback.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_intent_feedback.add_theme_font_size_override("font_size", 11)
	side.add_child(_intent_feedback)
	_set_mode(&"select")

	section = _sections["policies"]
	side = section
	side.add_child(_heading("Control"))
	_recreation_button = Button.new()
	_recreation_button.pressed.connect(_toggle_recreation_zone)
	side.add_child(_recreation_button)

	section = _sections["people"]
	side = section
	side.add_child(_heading("Colonists"))
	_colonist_box = VBoxContainer.new()
	_colonist_box.add_theme_constant_override("separation", 8)
	side.add_child(_colonist_box)

	section = _sections["alerts"]
	side = section
	side.add_child(_heading("Alerts"))
	_alert_box = VBoxContainer.new()
	_alert_box.add_theme_constant_override("separation", 4)
	side.add_child(_alert_box)

	section = _sections["activity"]
	side = section
	side.add_child(_heading("Recent events"))
	_feed = RichTextLabel.new()
	_feed.bbcode_enabled = true
	_feed.custom_minimum_size = Vector2(0, 220)
	_feed.scroll_following = true
	side.add_child(_feed)

	for entry: Array in [
		["overview", _status_label, "Colony status", ["resources", "population"]],
		["operations", _mode_buttons[&"select"], "Select", ["inspect", "selection"]],
		["operations", _mode_buttons[&"build"], "Build", ["construct"]],
		["operations", _build_menu, "Build type", ["farm", "forest", "mine", "storage"]],
		["operations", _block_box, "Block tools", ["enable", "disable", "work order"]],
		["policies", _haul_button, "Hauling policy", ["haul", "producer"]],
		["policies", _meal_buttons[ContinuumMealPolicy.Options.normal], "Meal policy", ["ration"]],
		["people", _colonist_box, "Colonists", ["workers", "roster"]],
		["alerts", _alert_box, "Alerts", ["ack"]],
		["activity", _history_chart, "History", ["trend"]],
		["activity", _feed, "Recent events", ["log"]],
		["administration", _speed_label, "Simulation speed", ["pause", "time scale"]],
	]:
		sidebar.register_entry(entry[0], entry[1], entry[2], PackedStringArray(entry[3]))
	_style_sidebar_buttons(sidebar)
	_refresh_permissions()


func _style_sidebar_buttons(node: Node) -> void:
	for child: Node in node.get_children():
		if child is Button:
			var button := child as Button
			button.custom_minimum_size.y = maxf(button.custom_minimum_size.y, 40.0)
			sidebar._apply_button_style(button)
		_style_sidebar_buttons(child)


func _refresh_permissions() -> void:
	if not is_instance_valid(sidebar):
		return
	# Unknown and disconnected are deliberately equivalent to viewer permissions.
	sidebar.set_section_authorized("policies", _can_operate)
	sidebar.set_section_authorized("administration", _is_admin)
	if is_instance_valid(_mode_buttons.get(&"build")):
		_mode_buttons[&"build"].visible = _can_operate
	if is_instance_valid(_build_menu):
		_build_menu.visible = _can_operate
	if is_instance_valid(_block_box):
		_block_box.visible = _can_operate
	if is_instance_valid(_recreation_button):
		_recreation_button.visible = _can_operate
	if is_instance_valid(_haul_button):
		_haul_button.visible = _can_operate
	for button: Button in _meal_buttons.values():
		button.visible = _can_operate


func _heading(text: String) -> Label:
	var label := Label.new()
	label.text = text.to_upper()
	label.add_theme_font_size_override("font_size", 11)
	label.add_theme_color_override("font_color", Color("7f8b9c"))
	return label


func _set_connection_text(text: String, colour: Color) -> void:
	if _connection_label == null:
		return
	_connection_message = text
	_connection_colour = colour
	_render_connection_role()


func _set_feedback(label: Label, compact: String, details: String) -> void:
	label.text = compact
	label.tooltip_text = details


func _compact_text(text: String, limit: int) -> String:
	return text if text.length() <= limit else text.substr(0, maxi(1, limit - 3)) + "..."


func _render_connection_role() -> void:
	if _connection_label == null:
		return
	_connection_label.text = "%s\nRole: %s%s" % [_compact_text(_connection_message, 48), _role_name,
		" (admin)" if _is_admin else (" (operator)" if _can_operate else " (view only)")]
	_connection_label.tooltip_text = "%s\nRole: %s" % [_connection_message, _role_name]
	_connection_label.add_theme_color_override("font_color", _connection_colour)


func _refresh() -> void:
	_refresh_status()
	_refresh_colonists()
	_refresh_controls()
	_refresh_alerts()
	_refresh_feed()
	sidebar._apply_responsive_theme()


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

	_status_label.text = "\n".join([
		"[b]Day %d[/b]  %02d:%02d   [color=#7f8b9c](%.0fx speed)[/color]"
				% [day, hour, minute, config.time_scale / BASE_TIME_SCALE],
		"[b]Resources[/b]  [color=#7f8b9c]unlimited storage[/color]",
		_resource_text(ContinuumResourceKind.Options.food, colony.food) + "    "
				+ _resource_text(ContinuumResourceKind.Options.wood, colony.wood),
		_resource_text(ContinuumResourceKind.Options.stone, colony.stone) + "    "
				+ _resource_text(ContinuumResourceKind.Options.meat, colony.meat),
		"[color=#7f8b9c]Ground / cargo tracked separately[/color]",
		"Average mood: %s  [color=#7f8b9c](trend %.0f)[/color]" % [
			_coloured("%.0f%%" % colony.avg_mood, colony.avg_mood), colony.smoothed_mood,
		],
		"Average productivity: %s  [color=#7f8b9c](trend %.0f)[/color]" % [
			_coloured("%.0f%%" % colony.avg_productivity, colony.avg_productivity),
			colony.smoothed_productivity,
		],
		"Population: %d" % colony.population,
	])


func _sample_history() -> void:
	if not _state_ready:
		return
	var config: ContinuumConfig = SpacetimeDB.Continuum.db.config.id.find(0)
	var colony: ContinuumColony = SpacetimeDB.Continuum.db.colony.id.find(0)
	if config == null or colony == null:
		return
	if _history.sample(config.game_seconds, {
		"mood": colony.smoothed_mood,
		"productivity": colony.smoothed_productivity,
	}, config.generation):
		_history_chart.set_points(_history.points())


func _set_block_enabled(enabled: bool) -> void:
	if not _can_operate or _selected_rect.size == Vector2i.ZERO:
		return
	if not _state_ready or _intent_request != null:
		return
	_track_intent(SpacetimeDB.Continuum.reducers.set_tile_block_enabled(
		_selected_rect.position.x, _selected_rect.position.y, _selected_rect.end.x - 1,
		_selected_rect.end.y - 1, enabled), "Set block %s" % ("enabled" if enabled else "disabled"))


func _set_block_work(work: int, priority: int, enabled: bool) -> void:
	if not _can_operate or _selected_rect.size == Vector2i.ZERO or not _state_ready or _intent_request != null:
		return
	_track_intent(SpacetimeDB.Continuum.reducers.set_block_work_order(
		_selected_rect.position.x, _selected_rect.position.y, _selected_rect.end.x - 1,
		_selected_rect.end.y - 1, ContinuumWorkType.create(work), priority, enabled),
		"Set %s work for block" % ContinuumWorkType.parse_enum_name(work).capitalize())


func _map_soil_name(fertility: float, moisture: float) -> String:
	if fertility > 0.68 and moisture > 0.52:
		return "chernozem"
	if fertility > 0.36:
		return "loamy ground"
	return "sandy ground"


func _map_cover_name(density: float) -> String:
	if density > 0.72:
		return "forest"
	if density > 0.45:
		return "woodland"
	return "grassland"


func _resource_text(kind: int, amount: float) -> String:
	return "[color=#%s]%s: %.1f[/color]" % [
		ColonyMap.RESOURCE_COLORS[kind].to_html(false),
		ContinuumResourceKind.parse_enum_name(kind).capitalize(), amount,
	]


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
		header.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		panel.add_child(header)

		var role := "Produce + haul" if colonist.haul_role.value == ContinuumHaulRole.Options.both \
				else ContinuumHaulRole.parse_enum_name(colonist.haul_role.value).capitalize()
		var job := Label.new()
		job.text = "%s / %s" % [
			ContinuumWorkType.parse_enum_name(colonist.work.value).capitalize(), role,
		]
		job.add_theme_font_size_override("font_size", 12)
		panel.add_child(job)
		var cargo := Label.new()
		cargo.text = "Cargo: empty hands"
		cargo.add_theme_font_size_override("font_size", 12)
		if colonist.carried_amount > 0.0:
			cargo.text = "Cargo: %.1f %s" % [colonist.carried_amount,
				ContinuumResourceKind.parse_enum_name(colonist.carried_kind.value)]
			cargo.add_theme_color_override("font_color",
					ColonyMap.RESOURCE_COLORS[colonist.carried_kind.value])
		panel.add_child(cargo)

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
	var config: ContinuumConfig = SpacetimeDB.Continuum.db.config.id.find(0)
	var busy := not _state_ready or _intent_request != null
	_build_menu.disabled = busy or not _can_operate
	# Block operations are the primary map workflow. Keep the authoritative one-cell
	# detail text visible for inspection, but do not expose single-tile mutators.
	_tile_action_box.visible = true
	_block_box.visible = _can_operate
	var block_tiles := 0
	var occupied := 0
	var enabled_count := 0
	var compatible_counts: Dictionary = {}
	if _selected_rect.size != Vector2i.ZERO:
		for tile: ContinuumTile in SpacetimeDB.Continuum.db.tile.iter():
			if not _selected_rect.has_point(Vector2i(tile.x, tile.y)):
				continue
			block_tiles += 1
			if tile.kind.value != ContinuumTileKind.Options.empty:
				occupied += 1
				if tile.enabled:
					enabled_count += 1
				for work: int in ColonyMap.compatible_work(tile.kind.value):
					compatible_counts[work] = int(compatible_counts.get(work, 0)) + 1
	var rect_text := "No rectangle selected."
	if _selected_rect.size != Vector2i.ZERO:
		rect_text = "%dx%d block: %d cells, %d occupied, %d enabled" % [
			_selected_rect.size.x, _selected_rect.size.y, block_tiles, occupied, enabled_count]
		if map.interaction_mode == &"build":
			rect_text += "\nPreview cost: %.0f wood" % (_selected_rect.size.x * _selected_rect.size.y * 20.0)
		else:
			rect_text += "\nControls skip empty cells; work controls skip incompatible tiles."
		var terrain_count := 0
		var fertility := 0.0
		var moisture := 0.0
		var cover := 0.0
		for tile: ContinuumTile in SpacetimeDB.Continuum.db.tile.iter():
			if not _selected_rect.has_point(Vector2i(tile.x, tile.y)):
				continue
			var fields: ContinuumTerrain = SpacetimeDB.Continuum.db.terrain.tile_id.find(tile.id)
			if fields != null:
				terrain_count += 1
				fertility += fields.soil_fertility
				moisture += fields.moisture
				cover += fields.forest_density
		if terrain_count > 0:
			fertility /= terrain_count
			moisture /= terrain_count
			cover /= terrain_count
			rect_text += "\nSoil avg: %s (fertility %.2f, moisture %.2f) | Cover avg: %s (density %.2f)" % [
				_map_soil_name(fertility, moisture), fertility, moisture, _map_cover_name(cover), cover]
	_block_info.text = rect_text.get_slice("\n", 0)
	_block_info.tooltip_text = rect_text
	var block_busy := busy or not _can_operate or _selected_rect.size == Vector2i.ZERO
	for key: String in ["enabled_true", "enabled_false"]:
		_block_controls[key].disabled = block_busy
	for work: int in [ContinuumWorkType.Options.farming, ContinuumWorkType.Options.logging,
			ContinuumWorkType.Options.mining, ContinuumWorkType.Options.hunting]:
		var controls: Dictionary = _block_controls[work]
		var count: int = compatible_counts.get(work, 0)
		controls.label.text = "%s (%d compatible)" % [ContinuumWorkType.parse_enum_name(work).capitalize(), count]
		controls.set.disabled = block_busy or count == 0
		controls.pause.disabled = block_busy or count == 0
		for priority_button: Button in controls.priority:
			priority_button.disabled = block_busy or count == 0
		controls.row.tooltip_text = "Only compatible facility tiles are changed; unrelated jobs remain untouched."

	_haul_button.disabled = not _can_operate or not _state_ready or config == null or _haul_request != null
	if config != null:
		var dedicated := config.haul_policy.value == ContinuumHaulPolicy.Options.dedicatedHaulers
		_haul_button.text = "Paired" if dedicated else "Everyone"
		_haul_description.text = "Producer + hauler" if dedicated else "Produce + haul"
		_haul_description.tooltip_text = ("Each job's pair splits into one producer and one hauler. Haulers carry only their job's resource."
			if dedicated else "All workers produce their job's resource and haul full stacks to storage.")
		if not _state_ready:
			_haul_description.text += " | stale"
	else:
		_haul_button.text = "Waiting for hauling policy..."
		_haul_description.text = ""

	var meal_busy := not _state_ready or _meal_request != null
	for policy: int in _meal_buttons:
		var button: Button = _meal_buttons[policy]
		button.disabled = not _can_operate or meal_busy or config == null
		button.set_pressed_no_signal(config != null and config.meal_policy.value == policy)
	if config != null:
		var rationed := config.meal_policy.value == ContinuumMealPolicy.Options.rationed
		_meal_description.text = "Cost 50% | recovery 65%" if rationed else "Normal cost | normal recovery"
		_meal_description.tooltip_text = ("Rationed: 50% food cost per eating time, 65% hunger recovery; higher hunger can lower mood and productivity." if rationed
				else "Normal: existing food cost and hunger recovery. No direct mood penalty either way.")
		if not _state_ready:
			_meal_description.text += " | stale"
	else:
		_meal_description.text = "Waiting for meal policy..."

	var recreation: Array[ContinuumTile] = _recreation_tiles()
	var any_enabled: bool = false
	for tile: ContinuumTile in recreation:
		if tile.enabled:
			any_enabled = true
			break

	if recreation.is_empty():
		_recreation_button.text = "Recreation: unknown"
		_recreation_button.tooltip_text = "No recreation tiles are currently subscribed."
		_recreation_button.disabled = true
	else:
		_recreation_button.disabled = not _can_operate or not _state_ready
		_recreation_button.text = ("Disable recreation zone" if any_enabled
				else "Enable recreation zone")

	_speed_label.text = "Config: waiting" if config == null else (
		"Paused" if config.time_scale == 0.0 else "%.2fx" % (config.time_scale / BASE_TIME_SCALE))
	_speed_label.tooltip_text = "Server simulation speed. 1x equals four real hours per in-game day."
	if not _state_ready and config != null:
		_speed_label.text += " | stale"
	for speed: int in _speed_buttons:
		var speed_button: Button = _speed_buttons[speed]
		speed_button.disabled = not _is_admin or busy or config == null
		speed_button.set_pressed_no_signal(config != null and is_equal_approx(config.time_scale, float(speed)))
	var tile: ContinuumTile = SpacetimeDB.Continuum.db.tile.id.find(_selected_tile_id)
	var compatible: Array[int] = []
	if tile != null:
		compatible = ColonyMap.compatible_work(tile.kind.value)
	var active_counts: Dictionary = {}
	for order: ContinuumWorkOrder in SpacetimeDB.Continuum.db.work_order.iter():
		if order.enabled:
			active_counts[order.work.value] = int(active_counts.get(order.work.value, 0)) + 1
	var counts := PackedStringArray()
	for work: int in [ContinuumWorkType.Options.farming, ContinuumWorkType.Options.mining,
			ContinuumWorkType.Options.logging, ContinuumWorkType.Options.hunting]:
		var work_name := ContinuumWorkType.parse_enum_name(work).capitalize()
		counts.append("%s %d" % [work_name, active_counts.get(work, 0)])
	_order_summary.text = "Orders: %s%s" % [", ".join(counts), " | stale" if not _state_ready else ""]
	_order_summary.tooltip_text = "Enabled standing orders by work type. Values come from subscribed server rows."
	if tile == null:
		_tile_info.text = "Click a tile on the map to select it."
		_tile_info.tooltip_text = "Select a tile or drag a rectangle on the map."
		return

	var tile_details := "Selected: %s tile #%d at (%d, %d) - %s" % [
		ContinuumTileKind.parse_enum_name(tile.kind.value).capitalize(), tile.id, tile.x, tile.y,
		"enabled" if tile.enabled else "disabled",
	]
	for stack: ContinuumItemStack in SpacetimeDB.Continuum.db.item_stack.iter():
		if stack.x == tile.x and stack.y == tile.y:
			tile_details += "\nGround: %.1f %s" % [stack.amount,
				ContinuumResourceKind.parse_enum_name(stack.kind.value)]
	if tile.kind.value == ContinuumTileKind.Options.storage:
		tile_details += "\nStorage: shared unlimited stock"
	if not compatible.is_empty() and not tile.enabled:
		tile_details += "\nProduction: disabled"
	if not _state_ready:
		tile_details += "\nState: stale"
	_tile_info.text = tile_details.get_slice("\n", 0)
	_tile_info.tooltip_text = tile_details


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
		label.text = _compact_text(alert.message, 56) + ("  [ack]" if alert.acknowledged else "")
		label.tooltip_text = alert.message + (" (acknowledged)" if alert.acknowledged else "")
		label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		label.add_theme_font_size_override("font_size", 11)
		label.add_theme_color_override("font_color", _severity_colour(alert.severity))
		label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		row.add_child(label)

		if not alert.acknowledged:
			var ack := Button.new()
			ack.text = "Ack"
			ack.tooltip_text = "Acknowledge this alert (operator)"
			ack.visible = _can_operate
			ack.add_theme_font_size_override("font_size", 10)
			sidebar._apply_button_style(ack)
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
	var details := PackedStringArray()
	for event: ContinuumEventLog in events:
		details.append("d%d %02d:%02d %s" % [event.day, event.hour, event.minute, event.message])
		lines.append("[color=#5c6675]d%d %02d:%02d[/color] [color=%s]%s[/color]" % [
			event.day, event.hour, event.minute,
			_severity_colour(event.severity).to_html(false), _compact_text(event.message, 72),
		])
	_feed.text = "\n".join(lines)
	_feed.tooltip_text = "\n".join(details)
