## Live colony panels inside the player's personal workspace deck.
##
## Replicated values remain authoritative and mutation commands use guarded reducers.
## Resource forecasts are labelled local-observation estimates, never new server
## alerts. Workspace preferences, selection and return baselines stay client-local.
extends Control

signal session_ready
signal session_failed(message: String)
signal session_left

const SessionHistoryModel = preload("res://scripts/session_history.gd")
const HistoryChartControl = preload("res://scripts/history_chart.gd")
const DiagnosticsStatsControl = preload("res://scripts/diagnostics_stats.gd")
const SessionDiagnosticsControl = preload("res://scripts/session_diagnostics.gd")
const DiagnosticsOverlayControl = preload("res://scripts/diagnostics_overlay.gd")
const ConnectionHistoryModel = preload("res://scripts/connection_history.gd")
const ServerProbesControl = preload("res://scripts/server_probes.gd")
const ServerManagementControl = preload("res://scripts/server_management.gd")
const NativeServerController = preload("res://scripts/native_server_controller.gd")
const SessionSamples = preload("res://scripts/session_observations.gd")
const PresentationModels = preload("res://ui/components/models.gd")
const ReturnStore = preload("res://scripts/return_snapshots.gd")
const ResourceControl = preload("res://ui/components/resource_readout.gd")
const RosterControl = preload("res://ui/components/roster_row.gd")
const ColonistControl = preload("res://ui/components/colonist_card.gd")
const AlertsControl = preload("res://ui/components/alert_list.gd")
const ActivityControl = preload("res://ui/components/activity_feed.gd")
const DigestControl = preload("res://ui/components/away_digest.gd")
const InterfaceIcons = preload("res://ui/theme/icons.gd")
const ALERT_PANEL_OWNERS := {"low_food": "overview", "low_mood": "people", "low_productivity": "overview", "recreation_unavailable": "policies"}

## How often the panel contents are refreshed. The backend ticks once a real second;
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
	"SELECT * FROM world_geometry", "SELECT * FROM terrain_chunk",
	"SELECT * FROM terrain_material", "SELECT * FROM excavation_designation",
])

@onready var map: ColonyMap = $Map
@onready var workspace: WorkspaceDeck = $Workspace

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
var _feed: ActivityFeed
var _connection_label: Label
var _connection_message := ""
var _connection_colour := ThemeTokens.color("ink-muted")
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
var _selected_surface: Dictionary = {}
var _mode_buttons: Dictionary = {}
var _build_menu: OptionButton
var _block_box: VBoxContainer
var _block_info: Label
var _block_controls: Dictionary = {}
## Test harnesses may record the final intent without pretending a reducer succeeded.
var map_intent_override: Callable
var _dirty: bool = false
var _map_dirty: bool = false
var _map_tables_changed: Dictionary = {}
var _ui_tables_changed: Dictionary = {}
var _full_ui_refresh := true
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
var _access: ContinuumAccess
var _profile := ContinuumClientProfile.NORMAL
var _clock: Label
var _resource_labels: Dictionary = {}
var _population: Label
var _speed_strip: HFlowContainer
var _developer_summary: Label
var _developer_diagnostics: CheckBox
var _developer_graph: CheckBox
var _developer_refresh_timer := 0.0
var _settings := ClientSettings.new()
var _metrics := UiMetrics.new()
var _settings_warning := ""
var _menu: ContinuumMainMenu
var _session_requested := false
var _direct_launch := false
var _session_generation := 0
var _bound_client: ContinuumModuleClient
var _client_bindings: Array[Dictionary] = []
var _has_configured_client := false
var _diagnostics_stats: DiagnosticsStats
var _session_diagnostics: SessionDiagnostics
var _session_ping: SessionPingTransport
var _diagnostics_overlay: DiagnosticsOverlay
var _diagnostics_focus_paused := false
var _diagnostics_last_tick := -1
var _diagnostics_last_refresh := -1
var _server_history: ContinuumConnectionHistory
var _server_probes: ContinuumServerProbes
var _server_management: ContinuumServerManagement
var _native_controller: ContinuumNativeServerController
var _native_join_epoch := -1
var _native_join_generation := -1
var _native_force_dialog: ConfirmationDialog
var _exit_requested := false
var _layer_label: Label
var _cell_label: Label
var _excavation_list: VBoxContainer
var _dimension_inputs: Dictionary = {}
var _map_toolbar: PanelContainer
var _map_layer_label: Label
var _map_zoom_label: Label
var _map_layer_buttons: Dictionary = {}
var _map_zoom_buttons: Dictionary = {}
var _map_navigation_buttons: Array[Button] = []
var _toolbar_metric_font := -1
var _excavation_signature: Array = []
var _colonist_cards: Dictionary = {}
var _colonist_empty: Label
var _selected_colonist := -1
var _selected_card: ColonistCard
var _alert_waiting: Label
var _identity_label: Label
var _connection_glyph: TextureRect
var _authenticated_identity := ""
var _session_observations := SessionSamples.new()
var _return_snapshots := ReturnStore.new()
var _return_key := ""
var _return_observed := false
var _return_snapshot: Dictionary = {}
var _return_digest: Dictionary = {}
var _digest_overlay: Control
var _digest: AwayDigest
var _digest_focus: Control
var _ack_requests: Dictionary = {}
var _permission_revision := 0
var _action_feedback: PanelContainer
var _action_error: Label
var _session_menu: MenuButton
var _rates_status: Label
var _resource_group: GridContainer
var _status_balance_pending := false
var _status_resource_inputs: Dictionary = {}
var _status_resource_configs: Dictionary = {}
var _status_effective_configs: Dictionary = {}
var _status_balance_signature := ""
var _status_secondary_hidden := false
var _action_fit_pending := false
var _alert_summary_cache: Dictionary = {}


func _ready() -> void:
	get_tree().auto_accept_quit = false
	_profile = ContinuumClientProfile.validated(_cli_option("--profile", ContinuumClientProfile.NORMAL))
	var settings_path := _cli_option("--settings-file", ClientSettings.path_from_args())
	_settings_warning = _settings.load_from(settings_path)
	get_window().content_scale_size = Vector2i.ZERO
	_settings.apply_ui_scale(get_window())
	_metrics = _settings.ui_metrics()
	_return_snapshots.load_file()
	_server_history = ConnectionHistoryModel.new()
	var history_path := ClientSettings.companion_path_from_settings(settings_path, ".history.json", ClientSettings.HISTORY_PATH)
	var favorites_path := ClientSettings.companion_path_from_settings(settings_path, ".favorites.json", ClientSettings.FAVORITES_PATH)
	_server_history.legacy_import_marker_path = history_path + ".legacy-imported"
	_server_history.load_from(history_path, favorites_path)
	_server_history.import_legacy_entry_once(_settings.server_host, _settings.database)
	_server_probes = ServerProbesControl.new()
	_server_management = ServerManagementControl.new()
	_server_management.apply_metrics(_metrics)
	_server_management.set_connection_defaults(_settings.server_host, _settings.database)
	_server_management.set_native_autostart(_settings.native_autostart)
	_server_management.set_history_store(_server_history)
	_server_management.set_probe_service(_server_probes)
	_server_management.set_local_management_state({"can_start": false, "can_stop": false, "can_force_stop": false,
		"message": "Checking native server..."})
	_server_management.visible = false
	_server_management.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(_server_management)
	_diagnostics_stats = DiagnosticsStatsControl.new()
	_session_diagnostics = SessionDiagnosticsControl.new()
	_history = SessionHistoryModel.new()
	theme = DeckTheme.create(_metrics)
	map.metrics = _metrics
	workspace.setup(map, _cli_option("--workspace-file", WorkspaceLayout.SAVE_PATH), _metrics)
	_build_panels()
	workspace.finish_setup()
	map.visible = true
	workspace.visible = true
	_menu = preload("res://scenes/main_menu.tscn").instantiate()
	add_child(_menu)
	_menu.setup(self, _settings, _metrics)
	_menu.join_requested.connect(_on_menu_join_requested)
	_menu.server_management_requested.connect(_show_server_management)
	_server_management.join_requested.connect(_on_server_management_join_requested)
	_server_management.back_requested.connect(_hide_server_management)
	_server_management.local_start_requested.connect(_native_start)
	_server_management.local_cancel_requested.connect(cancel_local_setup)
	_server_management.local_stop_requested.connect(_native_stop)
	_server_management.local_force_stop_requested.connect(_native_force_stop)
	_server_management.local_refresh_requested.connect(_native_refresh)
	_server_management.native_autostart_requested.connect(set_native_autostart)
	_menu.exit_requested.connect(_request_exit)
	_menu.visibility_changed.connect(_sync_menu_input)
	_server_management.visibility_changed.connect(_sync_menu_input)
	_create_away_digest()
	_sync_menu_input()
	workspace.workspace_changed.connect(func() -> void:
		_set_mode(&"select")
		_publish_alert_counts(_live_alert_models()))
	map.input_blocked = _map_input_blocked
	map.tile_selected.connect(_on_tile_selected)
	map.rectangle_selected.connect(_on_rectangle_selected)
	map.build_rectangle_requested.connect(_on_build_rectangle_requested)
	map.excavation_requested.connect(_on_excavation_requested)
	map.facility_requested.connect(_on_facility_requested)
	map.cell_selected.connect(func(cell: Vector3i) -> void:
		var material_id := map.terrain_model.material_at(cell)
		_cell_label.text = "%s (%d,%d,%d); base z=%d" % [
			LayeredTerrainModel.field(map.terrain_model.materials.get(material_id), "name", "Surface"),
			cell.x, cell.y, cell.z, map.selected_base])
	map.cut_changed.connect(func(_layer: int) -> void:
		_selected_tile_id = -1
		_selected_rect = Rect2i()
		_selected_surface = {}
		_cell_label.text = "Select a visible surface"
		_dirty = true)
	map.camera_changed.connect(_sync_map_toolbar)
	map.cut_changed.connect(func(_layer: int) -> void: _sync_map_toolbar())
	map.selection_invalidated.connect(func() -> void:
		_selected_rect = Rect2i()
		_selected_tile_id = -1
		_selected_surface = {}
		_dirty = true)
	_create_diagnostics_overlay()
	_configure_diagnostics_overlay()
	_setup_native_controller()

	var client: ContinuumModuleClient = SpacetimeDB.Continuum
	_bind_client(client)
	if _has_cli_connection():
		_direct_launch = true
		configure_connection(_cli_option("--stdb-host", "http://127.0.0.1:3001"),
			_cli_option("--stdb-db", "continuum"), _profile, true)


func _setup_native_controller() -> void:
	_native_controller = NativeServerController.new()
	_native_controller.state_changed.connect(_on_native_state, CONNECT_DEFERRED)
	_native_controller.server_ready.connect(_on_native_ready.bind(_native_controller.get_instance_id()), CONNECT_DEFERRED)
	add_child(_native_controller)
	_native_controller.autostart_changed.connect(_on_native_autostart_changed)
	_native_controller.request_autostart_status()

## Menu-facing runtime API. Rebuilds theme metrics without changing server state.
func apply_settings(settings: ClientSettings, persist := true) -> Error:
	_settings.font_size = clampi(settings.font_size, ClientSettings.MIN_FONT_SIZE, ClientSettings.MAX_FONT_SIZE)
	_settings.ui_scale_percent = ClientSettings.normalize_ui_scale(settings.ui_scale_percent)
	_settings.reduced_motion = settings.reduced_motion
	_settings.server_host = settings.server_host
	_settings.database = settings.database
	_settings.diagnostics_enabled = settings.diagnostics_enabled
	_settings.diagnostics_graph_enabled = settings.diagnostics_graph_enabled
	_settings.native_autostart = settings.native_autostart
	get_window().content_scale_size = Vector2i.ZERO
	_settings.apply_ui_scale(get_window())
	_metrics = _settings.ui_metrics()
	theme = DeckTheme.create(_metrics)
	map.metrics = _metrics
	_history_chart.metrics = _metrics
	workspace.apply_metrics(_metrics)
	if _alert_box is AlertList:
		_alert_box.set_reduced_motion(_settings.reduced_motion)
	_sync_map_toolbar()
	_configure_diagnostics_overlay()
	if _menu != null:
		_menu.apply_metrics(_metrics)
	if _server_management != null:
		_server_management.apply_metrics(_metrics)
	map.queue_redraw()
	_history_chart.queue_redraw()
	if persist:
		return _settings.save_to()
	return OK

func set_native_autostart(enabled: bool) -> void:
	if _native_controller != null: _native_controller.request_autostart(enabled)

func _on_native_autostart_changed(enabled: bool, error: String) -> void:
	if not error.is_empty():
		_server_management.set_status(error, true)
	else:
		_settings.native_autostart = enabled
		_settings.save_to()
	_server_management.set_native_autostart(_settings.native_autostart)

func _native_start() -> void:
	if _native_controller == null or _closing or _exit_requested: return
	if _session_requested and _direct_launch and not _state_ready:
		leave_session()
		_show_server_management()
	_menu.set_busy(true)
	_server_management.set_native_busy(true)
	_server_management.set_status("")
	_native_join_epoch = _native_controller.request_start()
	_native_join_generation = _session_generation
	if _native_join_epoch < 0:
		_invalidate_native_join()
		_server_management.set_native_busy(false)
		_menu.set_busy(_manual_connection_busy())
		_server_management.set_status("Native startup request could not be queued.", true)

func _invalidate_native_join() -> void:
	_native_join_epoch = -1
	_native_join_generation = -1

func cancel_local_setup() -> void:
	_invalidate_native_join()
	if _session_requested and not _state_ready and _host == ContinuumNativeServerManager.DEFAULT_HOST:
		leave_session()
	if _native_controller != null:
		_native_controller.cancel_startup()
	_menu.set_busy(false)
	_server_management.set_native_busy(false)
	_server_management.set_status("Startup cancelled. The current atomic preparation step may finish, but it will not join a server.")

func _request_exit() -> void:
	_end_session_observations()
	if _exit_requested:
		return
	_exit_requested = true
	_closing = true
	_invalidate_native_join()
	_session_requested = false
	_unbind_client(SpacetimeDB.Continuum)
	_clear_pending_requests()
	_set_permissions("Unknown", false, false)
	if _access != null: _access.stop()
	_cancel_reconnect()
	_reset_diagnostics_epoch()
	if SpacetimeDB.Continuum.is_connected_db():
		SpacetimeDB.Continuum.disconnect_db()
	_menu.set_status("Closing after the current atomic setup step finishes...")
	if _native_controller != null:
		_native_controller.request_shutdown()

func _native_stop() -> void:
	_invalidate_native_join()
	if _session_requested and _host == ContinuumNativeServerManager.DEFAULT_HOST:
		leave_session()
		_show_server_management()
	if _native_controller != null: _native_controller.request_stop(false)

func _native_force_stop() -> void:
	if _native_controller == null or _native_controller.cached_state() != "stop_timeout": return
	if _native_force_dialog == null:
		_native_force_dialog = ConfirmationDialog.new()
		_native_force_dialog.title = "Force stop native server?"
		_native_force_dialog.dialog_text = "The native server did not stop gracefully. Terminate both owned processes?"
		_native_force_dialog.confirmed.connect(func() -> void: _native_controller.request_stop(true))
		add_child(_native_force_dialog)
	_native_force_dialog.popup_centered()

func _native_refresh() -> void:
	if _native_controller != null: _native_controller.request_status()

func _on_native_ready(value_host: String, value_database: String, epoch: int,
		source_id: int) -> void:
	if _closing or _exit_requested: return
	if epoch != _native_join_epoch or _native_join_generation != _session_generation:
		return
	if not is_instance_valid(_native_controller) or _native_controller.get_instance_id() != source_id or not _native_controller.is_startup_current(epoch):
		return
	_invalidate_native_join()
	_show_server_management()
	_server_management.set_native_busy(false)
	_server_management.set_busy(true)
	_server_management.set_status("Native server ready. Joining...")
	configure_connection(value_host, value_database, _profile)

func _on_native_state(value: String, message: String) -> void:
	if _exit_requested:
		return
	var can_start := value == "offline"
	var can_stop := value in ["online", "starting", "unhealthy"]
	var can_force := value == "stop_timeout"
	var display := "Native server: %s" % value
	if message.is_empty():
		match value:
			"offline": message = "No managed native server was found. You can still join an existing server manually."
			"conflict": message = "Native ownership does not match this configuration. Local start and stop are unavailable; you can still join manually."
			"unhealthy": message = "The owned native server did not pass its health check."
	if not message.is_empty(): display += " | " + message
	_server_management.set_local_management_state({"can_start": can_start, "can_stop": can_stop,
		"can_force_stop": can_force, "message": display})
	_server_management.set_native_busy(value in ["installing", "preparing", "starting"])
	if not _session_requested:
		_menu.set_busy(value in ["installing", "preparing", "starting"])


## Menu-facing diagnostics API. Graph collection is subordinate to diagnostics.
func configure_diagnostics(show: bool, graph: bool, persist := true) -> Error:
	var settings := _settings.clone()
	settings.diagnostics_enabled = show
	settings.diagnostics_graph_enabled = graph
	return apply_settings(settings, persist)


func configure_connection(host: String, database: String, profile := ContinuumClientProfile.NORMAL,
		direct_launch := false) -> void:
	if _closing or _exit_requested: return
	_end_session_observations()
	_invalidate_native_join()
	var client: ContinuumModuleClient = SpacetimeDB.Continuum
	_unbind_client(client)
	_release_main_subscription()
	map.reset_world()
	_full_ui_refresh = true
	_map_tables_changed.clear()
	_ui_tables_changed.clear()
	_state_ready = false
	_session_generation += 1
	_clear_pending_requests()
	_set_permissions("Unknown", false, false)
	_reset_diagnostics_epoch()
	_cancel_reconnect()
	_host = host.strip_edges()
	_database = database.strip_edges()
	_profile = ContinuumClientProfile.validated(profile)
	_refresh_permissions()
	_direct_launch = direct_launch
	_session_requested = true
	if _access != null:
		_access.stop()
		_access = null
	if _has_configured_client:
		_replace_client_and_connect.call_deferred(_session_generation)
		return
	_has_configured_client = true
	_bind_client(client)
	_start_configured_client(client, _session_generation)


func _replace_client_and_connect(generation: int) -> void:
	if not _session_epoch_current(generation): return
	map.reset_world()
	var old_client: ContinuumModuleClient = SpacetimeDB.Continuum
	_unbind_client(old_client)
	if old_client.is_connected_db():
		old_client.disconnect_db()
	# Removing the client also closes a connecting socket, which disconnect_db()
	# deliberately does not do for the SDK's not-yet-open state.
	if old_client.get_parent() != null:
		old_client.get_parent().remove_child(old_client)
	old_client.queue_free()
	var fresh_client: ContinuumModuleClient = preload("res://spacetime_bindings/schema/module_continuum_client.gd").new()
	SpacetimeDB.Continuum = fresh_client
	SpacetimeDB.add_child(fresh_client)
	_bind_client(fresh_client)
	await get_tree().process_frame
	if not _client_epoch_current(fresh_client, generation):
		return
	_start_configured_client(fresh_client, generation)


func _start_configured_client(client: ContinuumModuleClient, generation: int) -> void:
	if not _client_epoch_current(client, generation):
		return
	client.token_save_path = ContinuumClientProfile.token_path(_profile, _host, _database)
	client.handle_window_close = false
	_access = _create_access(client)
	_bind_access(_access, client, generation)
	_access.start()
	var options := SpacetimeDBConnectionOptions.new()
	options.compression = SpacetimeDBConnection.CompressionPreference.NONE
	options.debug_mode = false
	options.one_time_token = false
	options.save_token = true
	_set_connection_text("Connecting · %s / %s" % [_host, _database], ThemeTokens.color("ink-muted"))
	if client.is_connected_db():
		_on_connected(client.get_local_identity(), str(client.get_token()))
	else:
		client.connect_db(_host, _database, options)


func _bind_access(access: ContinuumAccess, client: ContinuumModuleClient, generation: int) -> void:
	access.changed.connect(func(role: String, can_operate: bool, is_admin: bool) -> void:
		if _client_epoch_current(client, generation): _set_permissions(role, can_operate, is_admin))

func _bind_client(client: ContinuumModuleClient) -> void:
	if _bound_client != null: _unbind_client(_bound_client)
	_bound_client = client
	var generation := _session_generation
	_bind_client_signal(client.connected, func(identity: PackedByteArray, token: String) -> void:
		if _client_epoch_current(client, generation): _on_connected(identity, token))
	_bind_client_signal(client.disconnected, func() -> void:
		if _client_epoch_current(client, generation): _on_disconnected())
	_bind_client_signal(client.connection_error, func(code: int, reason: String) -> void:
		if _client_epoch_current(client, generation): _on_connection_error(code, reason))
	_bind_client_signal(client.row_inserted, func(table_name: String, _row: Resource) -> void:
		if _client_epoch_current(client, generation): _on_table_changed(table_name))
	_bind_client_signal(client.row_updated, func(table_name: String, _old: Resource, _new: Resource) -> void:
		if _client_epoch_current(client, generation): _on_table_changed(table_name))
	_bind_client_signal(client.row_deleted, func(table_name: String, _row: Resource) -> void:
		if _client_epoch_current(client, generation): _on_table_changed(table_name))

func _bind_client_signal(source: Signal, callback: Callable) -> void:
	source.connect(callback)
	_client_bindings.append({"source": source, "callback": callback})

func _session_epoch_current(generation: int) -> bool:
	return generation == _session_generation and _session_requested and not _closing and not _exit_requested

func _client_epoch_current(client: ContinuumModuleClient, generation: int) -> bool:
	return _session_epoch_current(generation) and is_instance_valid(client) and client == SpacetimeDB.Continuum

func _clear_pending_requests() -> void:
	_intent_request = null
	_haul_request = null
	_meal_request = null


func _unbind_client(client: ContinuumModuleClient) -> void:
	if client != _bound_client: return
	if _session_ping != null:
		_session_ping.dispose()
		_session_ping = null
	for binding in _client_bindings:
		var source: Signal = binding.source
		var callback: Callable = binding.callback
		if source.is_connected(callback): source.disconnect(callback)
	_client_bindings.clear()
	_bound_client = null


func leave_session() -> void:
	_end_session_observations()
	_invalidate_native_join()
	_session_generation += 1
	_unbind_client(SpacetimeDB.Continuum)
	_clear_pending_requests()
	_set_permissions("Unknown", false, false)
	_reset_diagnostics_epoch()
	_session_requested = false
	_cancel_reconnect()
	_release_main_subscription()
	if _access != null:
		_access.stop()
		_access = null
	if SpacetimeDB.Continuum.is_connected_db():
		SpacetimeDB.Continuum.disconnect_db()
	_state_ready = false
	map.visible = true
	workspace.visible = true
	_menu.show_menu()
	_server_management.set_busy(false)
	_hide_server_management()
	session_left.emit()


func _on_menu_join_requested(host: String, database: String) -> void:
	configure_connection(host, database, _profile, false)

func _show_server_management() -> void:
	_menu.visible = false
	_server_management.visible = true
	_server_management.set_busy(_manual_connection_busy())
	_server_management.set_browser_visible(true)

func _hide_server_management() -> void:
	if _server_management == null:
		return
	if _native_join_epoch >= 0:
		cancel_local_setup()
	_server_management.set_browser_visible(false)
	_server_management.visible = false
	if _menu != null:
		_menu.visible = true
		_menu.set_busy(_manual_connection_busy() or _server_management._native_busy)

func _manual_connection_busy() -> bool:
	return _session_requested and not _state_ready and not _direct_launch

func _sync_menu_input() -> void:
	var blocked := _menu.visible or _server_management.visible or (is_instance_valid(_digest_overlay) and _digest_overlay.visible)
	if blocked:
		map.cancel_gestures()
	map.process_mode = Node.PROCESS_MODE_DISABLED if blocked else Node.PROCESS_MODE_INHERIT
	workspace.process_mode = Node.PROCESS_MODE_DISABLED if blocked else Node.PROCESS_MODE_INHERIT

func _on_server_management_join_requested(target: Dictionary) -> void:
	var host := str(target.get("endpoint", ""))
	var database := str(target.get("database", ""))
	if not host.is_empty() and not database.is_empty():
		configure_connection(host, database, _profile, false)


func _has_cli_connection() -> bool:
	for argument: String in OS.get_cmdline_user_args():
		if argument.begins_with("--stdb-host=") or argument.begins_with("--stdb-db="):
			return true
	return _profile == ContinuumClientProfile.ADMIN

func apply_font_size(value: int, persist := true) -> Error:
	var settings := _settings.clone()
	settings.font_size = value
	settings.ui_scale_percent = ClientSettings.legacy_ui_scale(value)
	return apply_settings(settings, persist)

## Apply only the authenticated sender-scoped role view. The backend remains
## authoritative; this state only controls what the UI exposes.
func _set_permissions(role_name: String, can_operate: bool, is_admin: bool) -> void:
	var normalized_role := role_name.strip_edges().to_lower()
	var valid_role := normalized_role in ["viewer", "operator", "admin"]
	var role_can_operate := normalized_role in ["operator", "admin"]
	var role_is_admin := normalized_role == "admin"
	if not valid_role or can_operate != role_can_operate or is_admin != role_is_admin:
		normalized_role = "unknown"
	var old_can_operate := _can_operate
	var old_is_admin := _is_admin
	var old_role := _role_name
	_role_name = normalized_role.capitalize()
	_is_admin = role_is_admin and normalized_role != "unknown"
	_can_operate = role_can_operate and normalized_role != "unknown"
	var lost_operator := old_can_operate and not _can_operate
	if lost_operator:
		for id: int in _ack_requests:
			_alert_box.set_acknowledgement_state(id, false)
		_ack_requests.clear()
	if lost_operator and map.interaction_mode != &"select":
		map.set_interaction_mode(&"select")
		_set_feedback(_intent_feedback, "Build cancelled", "Build cancelled: operator permission was lost.")
		_intent_feedback.add_theme_color_override("font_color", ThemeTokens.color("warn"))
	_refresh_permissions()
	_refresh_controls()
	_render_connection_role()
	if old_can_operate != _can_operate or old_is_admin != _is_admin or old_role != _role_name:
		_permission_revision += 1
		_alert_summary_cache.clear()
		_alert_box.model = {}
		_refresh_alerts()
		_dirty = true


func _cli_option(option: String, fallback: String) -> String:
	for argument: String in OS.get_cmdline_user_args():
		if argument.begins_with(option + "="):
			return argument.substr(option.length() + 1)
	return fallback


func _create_access(client: ContinuumModuleClient) -> ContinuumAccess:
	return ContinuumAccess.new(client)


func _process(delta: float) -> void:
	if _exit_requested:
		if _native_controller == null or _native_controller.finish_shutdown():
			get_tree().quit()
		return
	_process_diagnostics()
	if _profile == ContinuumClientProfile.DEVELOPER:
		_developer_refresh_timer -= delta
		if _developer_refresh_timer <= 0.0:
			_developer_refresh_timer = REFRESH_INTERVAL
			_refresh_developer_summary()
	_sample_history()
	_process_acknowledgements(delta)
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
			_haul_feedback.add_theme_color_override("font_color", ThemeTokens.color("warn"))
			_dirty = true
	if _meal_request != null:
		_meal_request_seconds -= delta
		if _meal_request_seconds <= 0.0:
			_meal_request = null
			_set_feedback(_meal_feedback, "No response", "No response received. Outcome unknown; check the server meal policy before retrying.")
			_meal_feedback.add_theme_color_override("font_color", ThemeTokens.color("warn"))
			_dirty = true
	_refresh_timer -= delta
	if (_dirty or _map_dirty) and _refresh_timer <= 0.0:
		_refresh_timer = REFRESH_INTERVAL
		if _map_dirty:
			_map_dirty = false
			map.refresh(_map_tables_changed)
			_map_tables_changed.clear()
		if _dirty:
			_dirty = false
			_refresh()


func _notification(what: int) -> void:
	if what == NOTIFICATION_APPLICATION_FOCUS_OUT or what == NOTIFICATION_WM_WINDOW_FOCUS_OUT:
		_diagnostics_focus_paused = true
		_reset_diagnostics_samples()
	elif what == NOTIFICATION_APPLICATION_FOCUS_IN or what == NOTIFICATION_WM_WINDOW_FOCUS_IN:
		_diagnostics_focus_paused = false
		_diagnostics_last_tick = -1
	elif what == NOTIFICATION_WM_SIZE_CHANGED:
		_resize_diagnostics_overlay()
	if what == NOTIFICATION_WM_CLOSE_REQUEST:
		_request_exit()
	elif what == NOTIFICATION_CRASH:
		_closing = true
		SpacetimeDB.Continuum.disconnect_db()


func _exit_tree() -> void:
	_save_return_baseline()
	if _session_ping != null:
		_session_ping.dispose()
		_session_ping = null
	_release_main_subscription()
	if _access != null:
		_access.stop()
		_access = null


func _on_connected(identity: PackedByteArray, _token: String) -> void:
	if not _session_requested:
		return
	_authenticated_identity = identity.hex_encode()
	_return_key = ReturnStore.context_key(_host, _database, _profile, _authenticated_identity)
	if _session_ping == null:
		_session_ping = SessionPingTransport.new(SpacetimeDB.Continuum, _session_diagnostics)
	_cancel_reconnect()
	_session_diagnostics.set_connected(true)
	print("Continuum identity: %s" % identity.hex_encode())
	_set_connection_text("Connected · %s · waiting for colony state" % identity.hex_encode().substr(0, 12),
			ThemeTokens.color("ink-muted"))
	_release_main_subscription()
	_subscription = SpacetimeDB.Continuum.subscribe(SUBSCRIPTION_QUERIES)
	if _subscription.error != OK:
		_set_connection_text("Subscription failed · %d" % _subscription.error, ThemeTokens.color("critical"))
		if not _direct_launch:
			_fail_manual_session("Subscription failed (%d)." % _subscription.error)
		return
	_subscription.applied.connect(_on_subscription_applied.bind(_subscription, _session_generation))


func _release_main_subscription() -> void:
	if _subscription == null:
		return
	var subscription := _subscription
	_subscription = null
	SpacetimeDB.Continuum.discard_subscription(subscription)


func _on_subscription_applied(subscription: SpacetimeDBSubscription, generation: int) -> void:
	if _subscription != subscription or not _session_epoch_current(generation):
		return
	_state_ready = true
	_full_ui_refresh = true
	_dirty = true
	_map_dirty = true
	_settings.remember_server(_host, _database)
	_server_history.record_successful_subscription(_host, _database, ConnectionHistoryModel.DEFAULT_WORLD)
	_menu.set_status("Connected to %s / %s" % [_host, _database])
	_menu.set_busy(false)
	_menu.visible = false
	_server_management.set_busy(false)
	_server_management.set_status("")
	_server_management.set_browser_visible(false)
	_server_management.visible = false
	map.visible = true
	workspace.visible = true
	session_ready.emit()


func _on_disconnected() -> void:
	_end_session_observations()
	_state_ready = false
	_session_diagnostics.set_connected(false)
	_reset_diagnostics_samples()
	_release_main_subscription()
	_set_permissions("Unknown", false, false)
	_history.reset()
	_history_chart.set_points([])
	_set_connection_text("Offline · the colony keeps running without us",
			ThemeTokens.color("critical"))
	if _session_requested and _direct_launch:
		_server_management.set_status("Disconnected. Retrying in the background; you can join another server.", true)
		_server_management.set_busy(false)
		_menu.set_busy(_server_management._native_busy)
		_schedule_reconnect()
	elif _session_requested:
		_fail_manual_session("Disconnected before the server subscription was ready.")


func _on_connection_error(code: int, reason: String) -> void:
	_session_diagnostics.set_connected(false)
	_reset_diagnostics_samples()
	_release_main_subscription()
	_set_connection_text("Connection error · %d: %s" % [code, reason], ThemeTokens.color("critical"))
	if _session_requested and _direct_launch:
		_server_management.set_status("Connection error %d: %s. Retrying in the background; you can join another server." % [code, reason], true)
		_server_management.set_busy(false)
		_menu.set_busy(_server_management._native_busy)
		_schedule_reconnect()
	elif _session_requested:
		_fail_manual_session("Connection error %d: %s" % [code, reason])


func _fail_manual_session(message: String) -> void:
	_end_session_observations()
	if not _session_requested or _direct_launch:
		return
	_session_requested = false
	_session_generation += 1
	_unbind_client(SpacetimeDB.Continuum)
	_clear_pending_requests()
	_reset_diagnostics_epoch()
	var failed_generation := _session_generation
	_set_permissions("Unknown", false, false)
	var failed_client: ContinuumModuleClient = SpacetimeDB.Continuum
	_cancel_reconnect()
	_state_ready = false
	_release_main_subscription()
	if _access != null:
		_access.stop()
		_access = null
	map.visible = true
	workspace.visible = true
	_server_management.set_busy(false)
	if _server_management.visible:
		_server_management.set_status(message, true)
	else:
		_menu.join_failed(message)
		_menu.show_menu()
	session_failed.emit(message)
	# Do not close synchronously from inside the SDK callback. If a new join was
	# started before this deferred cleanup runs, the epoch guard leaves it alone.
	call_deferred("_close_failed_client", failed_client, failed_generation)


func _close_failed_client(client: ContinuumModuleClient, generation: int) -> void:
	if generation == _session_generation and not _session_requested and client == SpacetimeDB.Continuum:
		if client.is_connected_db():
			client.disconnect_db()


func _schedule_reconnect() -> void:
	_state_ready = false
	if _intent_request != null:
		_intent_request = null
		_set_feedback(_intent_feedback, "Connection lost", "%s: connection lost; outcome unknown. Waiting for server state." % _intent_name)
	if _haul_request != null:
		_haul_request = null
		_set_feedback(_haul_feedback, "Connection lost", "Connection lost. Hauling request outcome unknown; waiting for server state.")
		_haul_feedback.add_theme_color_override("font_color", ThemeTokens.color("warn"))
	if _meal_request != null:
		_meal_request = null
		_set_feedback(_meal_feedback, "Connection lost", "Connection lost. Meal policy outcome unknown; waiting for server state.")
		_meal_feedback.add_theme_color_override("font_color", ThemeTokens.color("warn"))
	_dirty = true
	if _closing or _reconnect_timer != null:
		return
	_set_connection_text("Reconnecting · retrying in %.0f s" % RECONNECT_DELAY, ThemeTokens.color("warn"))
	_reconnect_timer = get_tree().create_timer(RECONNECT_DELAY)
	_reconnect_timer.timeout.connect(_retry_connection.bind(_reconnect_timer))


func _cancel_reconnect() -> void:
	_reconnect_timer = null


func _retry_connection(timer: SceneTreeTimer) -> void:
	if timer != _reconnect_timer or not _session_requested or not _direct_launch or SpacetimeDB.Continuum.is_connected_db():
		return
	_reconnect_timer = null
	var options := SpacetimeDBConnectionOptions.new()
	options.compression = SpacetimeDBConnection.CompressionPreference.NONE
	options.debug_mode = false
	options.one_time_token = false
	options.save_token = true
	SpacetimeDB.Continuum.connect_db(_host, _database, options)


func _create_diagnostics_overlay() -> void:
	_diagnostics_overlay = preload("res://scripts/diagnostics_bar.gd").new()
	_diagnostics_overlay.mouse_filter = Control.MOUSE_FILTER_IGNORE
	workspace.diagnostics_host.add_child(_diagnostics_overlay)
	_diagnostics_overlay.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	workspace.diagnostics_host.resized.connect(_resize_diagnostics_overlay)
	get_viewport().size_changed.connect(_resize_diagnostics_overlay)
	_resize_diagnostics_overlay()


func _resize_diagnostics_overlay() -> void:
	if _diagnostics_overlay != null:
		_diagnostics_overlay.queue_redraw()


func _configure_diagnostics_overlay() -> void:
	if _diagnostics_overlay == null:
		return
	_diagnostics_overlay.apply_metrics(_metrics)
	_diagnostics_overlay.configure(_settings.diagnostics_enabled,
		_settings.diagnostics_graph_enabled)
	workspace.set_diagnostics_visible(_settings.diagnostics_enabled)
	if not _settings.diagnostics_enabled:
		_reset_diagnostics_samples()


func _reset_diagnostics_samples() -> void:
	if _diagnostics_stats == null:
		return
	_diagnostics_stats.reset()
	_session_diagnostics.reset()
	_diagnostics_last_tick = -1
	_diagnostics_last_refresh = -1
	if _diagnostics_overlay != null:
		_diagnostics_overlay.set_snapshots({}, {})


func _reset_diagnostics_epoch() -> void:
	if _session_ping != null:
		_session_ping.dispose()
		_session_ping = null
	_reset_diagnostics_samples()
	if _session_diagnostics != null:
		_session_diagnostics.set_connected(false)


func _process_diagnostics() -> void:
	if _diagnostics_stats == null or not _settings.diagnostics_enabled or _diagnostics_focus_paused:
		return
	var now_usec := Time.get_ticks_usec()
	_diagnostics_stats.observe_tick(now_usec)
	if _diagnostics_last_refresh >= 0 and now_usec - _diagnostics_last_refresh < DiagnosticsStats.DEFAULT_REFRESH_USEC:
		return
	_diagnostics_last_tick = now_usec
	_diagnostics_last_refresh = now_usec
	_session_diagnostics.advance(now_usec)
	_session_diagnostics.pump(now_usec)
	_diagnostics_overlay.set_snapshots(_diagnostics_stats.refresh(now_usec),
		_session_diagnostics.snapshot(now_usec))


func _on_table_changed(table_name: String) -> void:
	_dirty = true
	_ui_tables_changed[table_name] = true
	if table_name in ["tile", "terrain", "world_seed", "colonist", "item_stack", "work_order", "colony", "config",
		"world_geometry", "terrain_chunk", "terrain_material", "excavation_designation"]:
		_map_dirty = true
		_map_tables_changed[table_name] = true


func _on_tile_selected(tile_id: int) -> void:
	_selected_tile_id = tile_id
	_selected_rect = map.selected_rect()
	_selected_surface = map.terrain_model.capture_selection(_selected_rect) if map.layered else {}
	map.set_selected_rect(_selected_rect)
	_refresh_controls()
	_dirty = true


func _on_rectangle_selected(rect: Rect2i) -> void:
	_selected_rect = rect
	map.set_selected_rect(rect)
	_selected_surface = map.terrain_model.capture_selection(rect) if map.layered else {}
	var tile: ContinuumTile = _tile_at(rect.position)
	_selected_tile_id = tile.id if tile != null else -1
	_refresh_controls()
	_dirty = true
	if not workspace.map_only and not workspace.windows["inspector"].visible:
		workspace.toggle_panel("inspector")


func _tile_at(pos: Vector2i) -> ContinuumTile:
	return map.tile_at(pos)


func _on_build_rectangle_requested(rect: Rect2i) -> void:
	_selected_rect = rect
	map.set_selected_rect(rect)
	_selected_surface = map.terrain_model.capture_selection(rect) if map.layered else {}
	_refresh_controls()
	if not _can_operate:
		_set_feedback(_intent_feedback, "Build blocked", "Build blocked: operator permission is not available.")
		return
	if not can_send_map_intent(_state_ready, _intent_request != null):
		_set_feedback(_intent_feedback, "Build blocked", "Build blocked: waiting for subscription or another request.")
		return
	if map.layered and (map.terrain_model.uniform_base(rect) == null or map.terrain_model.uniform_base(rect) != map.selected_base):
		_set_feedback(_intent_feedback, "Build rejected", "Mixed elevations or unknown floors: select a single exposed elevation.")
		return
	if map.layered and not map.terrain_model.placement_clear(rect, map.selected_base, 1):
		_set_feedback(_intent_feedback, "Build rejected", "Solid cut rock must be excavated first; building needs supported air cells.")
		return
	var colony: ContinuumColony = SpacetimeDB.Continuum.db.colony.id.find(0)
	var occupied := 0
	for tile: ContinuumTile in map.facility_tiles():
		if rect.intersects(ColonyMap.tile_footprint(tile)) and tile.kind.value != ContinuumTileKind.Options.empty:
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
	if map.layered:
		var z: Variant = map.terrain_model.uniform_base(rect)
		if z == null:
			_set_feedback(_intent_feedback, "Build rejected", "Mixed elevations or unknown floors.")
			return
		_dispatch_vertical("build_tile_block_at", [rect.position.x, rect.position.y,
			rect.end.x - 1, rect.end.y - 1, int(z), kind], "Build visible floor")
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
	if mode != &"select" and not _can_operate:
		_set_feedback(_intent_feedback, "Operator permission required", "Build mode requires operator permission.")
		return
	map.set_interaction_mode(mode)
	for key: StringName in _mode_buttons:
		_mode_buttons[key].set_pressed_no_signal(key == mode)
	if mode == &"build":
		_set_feedback(_intent_feedback, "Build: drag rectangle", "Choose a type, then drag a rectangle on empty ground. Esc/right-click cancels.")
	else:
		_set_feedback(_intent_feedback, "Select: drag rectangle", "Drag a rectangle to control the whole block.")
	if mode == &"excavate":
		_set_feedback(_intent_feedback, "Excavate: drag solids", "Bottom is the clicked visible/base z; height extends upward in 0.5m cells. Cut changes cancel drags.")
	elif mode == &"facility":
		_set_feedback(_intent_feedback, "Place complete facility", "Click an exposed floor; width/depth/clearance are reserved in full.")


func _dispatch_vertical(reducer: String, payload: Array, description: String) -> void:
	if not _can_operate or not can_send_map_intent(_state_ready, _intent_request != null):
		_set_feedback(_intent_feedback, "Request blocked", "Operator permission, ready subscription, and no pending request are required.")
		return
	if map_intent_override.is_valid():
		map_intent_override.call(reducer, payload)
		return
	var reducers: Object = SpacetimeDB.Continuum.reducers
	if not reducers.has_method(reducer):
		_set_feedback(_intent_feedback, "Bindings unavailable", "Regenerate matching bindings for %s." % reducer)
		return
	_track_intent(reducers.callv(reducer, payload), description)


func _on_excavation_requested(rect: Rect2i, bottom: int, height: int) -> void:
	if not map.layered:
		_set_feedback(_intent_feedback, "Terrain unavailable", "Excavation needs authoritative voxel terrain.")
		return
	var payload := map.terrain_model.excavation_payload(rect, bottom, height)
	if payload.is_empty():
		_set_feedback(_intent_feedback, "Invalid excavation", "Height must be positive and fit within world bounds.")
		return
	_dispatch_vertical("designate_excavation", payload, "Excavate z=%d through %d" % [bottom, bottom + height - 1])


func _on_facility_requested(cell: Vector3i) -> void:
	var footprint := Rect2i(Vector2i(cell.x, cell.y), Vector2i(map.facility_width, map.facility_depth))
	if not map.layered or map.terrain_model.uniform_base(footprint) != cell.z:
		_set_feedback(_intent_feedback, "Invalid facility", "Entire footprint must have the same exposed floor elevation.")
		return
	if cell.z + map.facility_height - 1 > map.terrain_model.max_z:
		_set_feedback(_intent_feedback, "Invalid facility", "Clearance extends beyond world bounds.")
		return
	if not map.terrain_model.placement_clear(footprint, cell.z, map.facility_height):
		_set_feedback(_intent_feedback, "Invalid facility", "Needs real supporting floors and known empty space throughout the full clearance.")
		return
	_dispatch_vertical("place_facility", [cell.x, cell.y, cell.z,
		ContinuumTileKind.create(_build_menu.get_selected_id()), map.facility_width,
		map.facility_depth, map.facility_height], "Place complete facility")


func _recreation_tiles() -> Array[ContinuumTile]:
	var result: Array[ContinuumTile] = []
	for tile: ContinuumTile in map.facility_tiles():
		if tile.kind.value == ContinuumTileKind.Options.recreation:
			result.append(tile)
	return result


func _toggle_recreation_zone() -> void:
	if not _can_operate:
		return
	if map.layered:
		_set_feedback(_intent_feedback, "Use exposed block controls", "Select recreation facilities on one visible floor, then enable/disable the block.")
		return
	var any_enabled: bool = false
	for tile: ContinuumTile in _recreation_tiles():
		if tile.enabled:
			any_enabled = true
			break
	_report(SpacetimeDB.Continuum.reducers.set_zone_enabled(
			ContinuumTileKind.create_recreation(), not any_enabled), "set_zone_enabled")


func _change_speed(speed: float) -> void:
	if not _is_admin or not _state_ready or _intent_request != null or SpacetimeDB.Continuum.db == null:
		return
	_refresh_controls()
	if _state_ready and _intent_request == null and SpacetimeDB.Continuum.db.config.id.find(0) != null:
		_track_intent(SpacetimeDB.Continuum.reducers.set_time_scale(speed), "Simulation speed")


func _track_intent(call: SpacetimeDBReducerCall, description: String) -> void:
	var generation := _session_generation
	_intent_feedback.add_theme_color_override("font_color", ThemeTokens.color("warn"))
	if call.error != OK:
		_set_feedback(_intent_feedback, "Send failed", "%s could not be sent (%d)." % [description, call.error])
		_refresh_controls()
		return
	_intent_request = call
	_intent_name = description
	_intent_seconds = 10.0
	_set_feedback(_intent_feedback, "Pending", "%s: pending. Displayed values follow the server." % description)
	call.response.connect(func(response: ReducerResultMessage) -> void:
		if _intent_request != call or not _session_epoch_current(generation):
			return
		_intent_request = null
		_dirty = true
		_intent_feedback.add_theme_color_override("font_color", ThemeTokens.color("critical"))
		if response.reducer_result.value == ReducerOutcomeEnum.Options.err:
			_set_feedback(_intent_feedback, "Rejected", "%s rejected: %s" % [description, response.reducer_result.get_err()])
		elif response.reducer_result.value == ReducerOutcomeEnum.Options.internalError:
			_set_feedback(_intent_feedback, "Failed", "%s failed: %s" % [description, response.reducer_result.get_internal_error()])
		else:
			_set_feedback(_intent_feedback, "Accepted", "%s accepted. Values follow server state." % description)
			_intent_feedback.add_theme_color_override("font_color", ThemeTokens.color("ink-muted"))
	, CONNECT_ONE_SHOT)
	_refresh_controls()


func _acknowledge(alert_id: Variant) -> void:
	if not alert_id is int or not _can_operate or not _state_ready or SpacetimeDB.Continuum.db == null or _ack_requests.has(alert_id):
		return
	var alert: ContinuumAlert = SpacetimeDB.Continuum.db.alert.id.find(alert_id)
	if alert == null or not alert.active or alert.acknowledged:
		return
	var call := _dispatch_acknowledgement(alert_id)
	if call == null or call.error != OK:
		_alert_box.set_acknowledgement_state(alert_id, false, "Could not send acknowledgement.")
		return
	var generation := _session_generation
	_ack_requests[alert_id] = {"call": call, "remaining": 10.0, "accepted": false}
	_alert_box.set_acknowledgement_state(alert_id, true)
	call.response.connect(func(response: ReducerResultMessage) -> void:
		if not _can_operate or not _session_epoch_current(generation) or not _ack_requests.has(alert_id) or _ack_requests[alert_id].call != call:
			return
		var error := ""
		if response.reducer_result.value == ReducerOutcomeEnum.Options.err:
			error = "Acknowledgement rejected: " + str(response.reducer_result.get_err())
		elif response.reducer_result.value == ReducerOutcomeEnum.Options.internalError:
			error = "Acknowledgement failed: " + str(response.reducer_result.get_internal_error())
		if not error.is_empty():
			_ack_requests.erase(alert_id)
			_alert_box.set_acknowledgement_state(alert_id, false, error)
		else:
			_ack_requests[alert_id].accepted = true
			_dirty = true
	, CONNECT_ONE_SHOT)


func _dispatch_acknowledgement(alert_id: int) -> SpacetimeDBReducerCall:
	return SpacetimeDB.Continuum.reducers.acknowledge_alert(alert_id)


func _process_acknowledgements(delta: float) -> void:
	for id: int in _ack_requests.keys():
		_ack_requests[id].remaining -= delta
		if _ack_requests[id].remaining <= 0.0:
			_ack_requests.erase(id)
			_alert_box.set_acknowledgement_state(id, false, "No shared acknowledgement observed · outcome unknown; check server state before retrying.")


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
	_haul_feedback.add_theme_color_override("font_color", ThemeTokens.color("warn"))
	if call.error != OK:
		_set_feedback(_haul_feedback, "Send failed", "Hauling mode could not be sent (%d)." % call.error)
		return
	_haul_request = call
	_haul_request_seconds = 10.0
	_set_feedback(_haul_feedback, "Pending", "Request sent. Waiting for the server; displayed mode is not changed locally.")
	call.response.connect(_on_haul_policy_response.bind(call.request_id, _session_generation), CONNECT_ONE_SHOT)
	_dirty = true
	_haul_button.disabled = true


func _on_haul_policy_response(response: ReducerResultMessage, request_id: int, generation: int) -> void:
	if not _session_epoch_current(generation) or _haul_request == null or request_id != _haul_request.request_id:
		return
	_haul_request = null
	_dirty = true
	_haul_feedback.add_theme_color_override("font_color", ThemeTokens.color("critical"))
	if response.reducer_result.value == ReducerOutcomeEnum.Options.err:
		_set_feedback(_haul_feedback, "Rejected", "Hauling mode rejected: %s" % response.reducer_result.get_err())
	elif response.reducer_result.value == ReducerOutcomeEnum.Options.internalError:
		_set_feedback(_haul_feedback, "Failed", "Hauling mode failed: %s" % response.reducer_result.get_internal_error())
	else:
		_set_feedback(_haul_feedback, "Accepted", "Request accepted. The mode above follows server state.")
		_haul_feedback.add_theme_color_override("font_color", ThemeTokens.color("ink-muted"))


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
	_meal_feedback.add_theme_color_override("font_color", ThemeTokens.color("warn"))
	if call.error != OK:
		_set_feedback(_meal_feedback, "Send failed", "Meal policy could not be sent (%d)." % call.error)
		_refresh_controls()
		return
	_meal_request = call
	_meal_request_seconds = 10.0
	_set_feedback(_meal_feedback, "Pending", "Request sent. Waiting for the server; displayed policy is not changed locally.")
	call.response.connect(_on_meal_policy_response.bind(call.request_id, _session_generation), CONNECT_ONE_SHOT)
	_dirty = true
	_refresh_controls()


func _on_meal_policy_response(response: ReducerResultMessage, request_id: int, generation: int) -> void:
	if not _session_epoch_current(generation) or _meal_request == null or request_id != _meal_request.request_id:
		return
	_meal_request = null
	_dirty = true
	_meal_feedback.add_theme_color_override("font_color", ThemeTokens.color("critical"))
	if response.reducer_result.value == ReducerOutcomeEnum.Options.err:
		_set_feedback(_meal_feedback, "Rejected", "Meal policy rejected: %s" % response.reducer_result.get_err())
	elif response.reducer_result.value == ReducerOutcomeEnum.Options.internalError:
		_set_feedback(_meal_feedback, "Failed", "Meal policy failed: %s" % response.reducer_result.get_internal_error())
	else:
		_set_feedback(_meal_feedback, "Accepted", "Request accepted. The policy above follows server state.")
		_meal_feedback.add_theme_color_override("font_color", ThemeTokens.color("ink-muted"))


func _report(call: SpacetimeDBReducerCall, reducer_name: String) -> void:
	var client: ContinuumModuleClient = SpacetimeDB.Continuum
	var generation := _session_generation
	var permission_revision := _permission_revision
	if not _state_ready or not _can_operate:
		return
	if call.error != OK:
		_show_action_error("%s could not be sent (%d)" % [reducer_name, call.error])
		return
	var response: ReducerResultMessage = await call.response
	if not _client_epoch_current(client, generation) or not _can_operate or permission_revision != _permission_revision: return
	if response.reducer_result.value == ReducerOutcomeEnum.Options.err:
		_show_action_error("%s was rejected: %s" % [reducer_name, response.reducer_result.get_err()])
	elif response.reducer_result.value == ReducerOutcomeEnum.Options.internalError:
		_show_action_error("%s failed: %s" % [reducer_name, response.reducer_result.get_internal_error()])

func _show_action_error(copy: String) -> void:
	_action_error.text = "Action failed · " + copy
	_layout_action_feedback()
	_action_feedback.show()

func _layout_action_feedback() -> void:
	if not is_instance_valid(_action_feedback): return
	var available := maxf(1, workspace.area.size.x - 32)
	_action_feedback.custom_minimum_size.x = minf(280, available)
	_action_feedback.size.x = minf(600, available)
	if not _action_fit_pending:
		_action_fit_pending = true
		get_tree().process_frame.connect(_fit_action_feedback_height.bind(2), CONNECT_ONE_SHOT)

func _fit_action_feedback_height(settling_frames: int) -> void:
	if not is_inside_tree(): return
	if settling_frames > 0:
		get_tree().process_frame.connect(_fit_action_feedback_height.bind(settling_frames - 1), CONNECT_ONE_SHOT)
		return
	_action_fit_pending = false
	_action_feedback.size.y = _action_feedback.get_combined_minimum_size().y

func _build_action_feedback() -> void:
	_action_feedback = PanelContainer.new()
	_action_feedback.name = "ActionFailure"
	_action_feedback.add_theme_stylebox_override("panel", DeckTheme.box(ThemeTokens.color("critical-soft"), ThemeTokens.color("critical"), int(ThemeTokens.number("space-2"))))
	var stack := _map_toolbar.get_parent()
	stack.add_child(_action_feedback)
	_action_feedback.z_index = 20
	_action_feedback.position = Vector2(16, 64)
	_action_feedback.custom_minimum_size.x = 280
	workspace.area.resized.connect(_layout_action_feedback)
	var row := HBoxContainer.new()
	_action_feedback.add_child(row)
	var glyph := TextureRect.new()
	glyph.texture = ThemeTokens.glyph("critical")
	glyph.custom_minimum_size = Vector2(16, 16)
	glyph.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	glyph.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	row.add_child(glyph)
	_action_error = Label.new()
	ThemeTokens.apply_label(_action_error, "body")
	_action_error.add_theme_color_override("font_color", ThemeTokens.color("ink"))
	_action_error.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_action_error.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(_action_error)
	var dismiss := Button.new()
	dismiss.text = "Dismiss"
	dismiss.pressed.connect(func() -> void: _action_feedback.hide())
	row.add_child(dismiss)
	_action_feedback.hide()


func _build_panels() -> void:
	for key: String in WorkspaceLayout.PANEL_NAMES:
		_sections[key] = workspace.add_panel(key)
	_build_telemetry()
	_build_map_toolbar()
	_build_action_feedback()
	var side: VBoxContainer
	var section: VBoxContainer = _sections["overview"]
	side = section

	section = _sections["policies"]
	side = section
	side.add_child(_heading("Global hauling mode"))
	_haul_button = Button.new()
	_haul_button.text = "Waiting for hauling policy..."
	_haul_button.disabled = true
	_haul_button.add_theme_font_size_override("font_size", ThemeTokens.font_size("body"))
	_haul_button.tooltip_text = "Toggle hauling assignment. Server state remains authoritative."
	_haul_button.pressed.connect(_toggle_haul_policy)
	side.add_child(_haul_button)
	_haul_description = Label.new()
	_haul_description.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	ThemeTokens.apply_label(_haul_description, "small")
	side.add_child(_haul_description)
	_haul_feedback = Label.new()
	_haul_feedback.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	ThemeTokens.apply_label(_haul_feedback, "small")
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
	ThemeTokens.apply_label(_meal_description, "small")
	side.add_child(_meal_description)
	_meal_feedback = Label.new()
	_meal_feedback.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	ThemeTokens.apply_label(_meal_feedback, "small")
	side.add_child(_meal_feedback)

	section = _sections["overview"]
	side = section
	side.add_child(_heading("Colony"))
	_status_label = RichTextLabel.new()
	_status_label.bbcode_enabled = true
	_status_label.fit_content = true
	_status_label.scroll_active = false
	_status_label.add_theme_font_override("normal_font", ThemeTokens.font("readout"))
	_status_label.add_theme_font_size_override("normal_font_size", ThemeTokens.font_size("readout"))
	side.add_child(_status_label)
	var rate_note := Label.new()
	rate_note.text = "Rates since connection · observed stocks per game hour. Estimates are not server alerts."
	rate_note.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	ThemeTokens.apply_label(rate_note, "small")
	rate_note.add_theme_color_override("font_color", ThemeTokens.color("ink-muted"))
	side.add_child(rate_note)

	section = _sections["trends"]
	side = section
	var history_note := Label.new()
	history_note.text = "Smoothed mood / output\nLocally observed since connection; not saved with the colony."
	history_note.tooltip_text = "This session / since connection. Not saved on the server."
	history_note.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	ThemeTokens.apply_label(history_note, "small")
	history_note.add_theme_color_override("font_color", ThemeTokens.color("ink-muted"))
	side.add_child(history_note)
	_history_chart = HistoryChartControl.new()
	_history_chart.metrics = _metrics
	_history_chart.size_flags_vertical = Control.SIZE_EXPAND_FILL
	side.add_child(_history_chart)

	side = _sections["admin"]
	side.add_child(_heading("Simulation speed"))
	_speed_label = Label.new()
	_speed_label.text = "Config: waiting"
	_speed_label.tooltip_text = "Authoritative simulation speed"
	side.add_child(_speed_label)
	_speed_strip = HFlowContainer.new()
	for speed: int in [0, 6, 60, 600, 3600]:
		var button := Button.new()
		button.text = "Pause" if speed == 0 else "%dx" % (speed / 6)
		button.toggle_mode = true
		button.disabled = true
		button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		button.pressed.connect(_change_speed.bind(float(speed)))
		_speed_strip.add_child(button)
		_speed_buttons[speed] = button
	side.add_child(_speed_strip)
	_build_developer_panel()

	section = _sections["operations"]
	side = section
	side.add_child(_heading("Map tools"))
	var modes := HFlowContainer.new()
	for mode: StringName in [&"select", &"build", &"excavate", &"facility"]:
		var button := Button.new()
		button.text = String(mode).capitalize()
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
	_build_vertical_controls(side)
	_build_help = Label.new()
	_build_help.text = "7 types | 20 wood/cell"
	_build_help.tooltip_text = "Farm, Forestry, Mine, Storage, Dining, Sleep, Recreation. Forestry creates a Forest work zone; natural forest cover is separate terrain."
	_build_help.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	ThemeTokens.apply_label(_build_help, "small")
	side.add_child(_build_help)
	_block_box = VBoxContainer.new()
	_block_info = Label.new()
	ThemeTokens.apply_label(_block_info, "readout")
	_block_info.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_block_box.add_child(_block_info)
	var enabled_row := HFlowContainer.new()
	for enabled: bool in [true, false]:
		var button := Button.new()
		button.text = "Enable block" if enabled else "Disable block"
		button.pressed.connect(_set_block_enabled.bind(enabled))
		enabled_row.add_child(button)
		_block_controls["enabled_%s" % enabled] = button
	_block_box.add_child(enabled_row)
	for work: int in [ContinuumWorkType.Options.farming, ContinuumWorkType.Options.logging,
			ContinuumWorkType.Options.mining, ContinuumWorkType.Options.hunting]:
		var row := HFlowContainer.new()
		var label := Label.new()
		label.text = ContinuumWorkType.parse_enum_name(work).capitalize()
		label.custom_minimum_size.x = _metrics.px(110)
		row.add_child(label)
		var count_label := Label.new()
		ThemeTokens.apply_label(count_label, "readout")
		row.add_child(count_label)
		var add := Button.new()
		add.text = "Set"
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
		_block_controls[work] = {"row": row, "label": label, "count": count_label, "set": add, "priority": priority_buttons, "pause": pause}
		_block_box.add_child(row)
	side.add_child(_block_box)

	side = _sections["inspector"]
	side.add_child(_heading("Selected terrain & facilities"))
	_tile_action_box = VBoxContainer.new()
	side.add_child(_tile_action_box)
	_tile_info = Label.new()
	ThemeTokens.apply_label(_tile_info, "readout")
	_tile_info.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_tile_action_box.add_child(_tile_info)
	_order_summary = Label.new()
	ThemeTokens.apply_label(_order_summary, "readout")
	_order_summary.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	side.add_child(_order_summary)
	_orders_help = Label.new()
	_orders_help.text = "Orders: priority + distance"
	_orders_help.tooltip_text = "Orders rank sites within fixed professions: priority, then distance (server decides ties). Missing/paused orders stop production, not hauling old goods. Create starts enabled / Normal."
	_orders_help.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	side.add_child(_orders_help)
	_intent_feedback = Label.new()
	_intent_feedback.custom_minimum_size.x = _metrics.px(160)
	_intent_feedback.clip_text = true
	ThemeTokens.apply_label(_intent_feedback, "small")
	var intent_row := HBoxContainer.new()
	intent_row.position = Vector2(16, 64)
	workspace.area.add_child(intent_row)
	intent_row.add_child(_intent_feedback)
	var cancel := Button.new()
	cancel.text = "Cancel · Esc"
	cancel.theme_type_variation = "ButtonQuiet"
	cancel.pressed.connect(func() -> void: _set_mode(&"select"))
	intent_row.add_child(cancel)
	intent_row.hide()
	_intent_feedback.hide()
	_set_mode(&"select")

	section = _sections["policies"]
	side = section
	side.add_child(_heading("Control"))
	_recreation_button = Button.new()
	_recreation_button.pressed.connect(_toggle_recreation_zone)
	side.add_child(_recreation_button)

	section = _sections["people"]
	side = section
	side.add_child(_heading("Needs / assignments / cargo"))
	_colonist_box = VBoxContainer.new()
	_colonist_box.add_theme_constant_override("separation", _metrics.px(8))
	side.add_child(_colonist_box)
	_selected_card = ColonistControl.new()
	_selected_card.visible = false
	_selected_card.goto_requested.connect(_goto_colonist)
	side.add_child(_selected_card)

	section = _sections["alerts"]
	side = section
	side.add_child(_heading("Colony attention"))
	_alert_waiting = Label.new()
	_alert_waiting.text = "Waiting for authoritative alert state."
	ThemeTokens.apply_label(_alert_waiting, "body")
	_alert_waiting.add_theme_color_override("font_color", ThemeTokens.color("ink-muted"))
	side.add_child(_alert_waiting)
	_alert_box = AlertsControl.new()
	_alert_box.set_reduced_motion(_settings.reduced_motion)
	_alert_box.acknowledge_requested.connect(_acknowledge)
	_alert_box.add_theme_constant_override("separation", _metrics.px(4))
	side.add_child(_alert_box)

	section = _sections["activity"]
	side = section
	side.add_child(_heading("Server events / latest 40"))
	_feed = ActivityControl.new()
	_feed.custom_minimum_size = _metrics.min_size(0, 70)
	_feed.size_flags_vertical = Control.SIZE_EXPAND_FILL
	side.add_child(_feed)

	_refresh_permissions()


## Developer is a local client mode, never an authorization role.
func _build_developer_panel() -> void:
	var side: VBoxContainer = _sections["developer"]
	side.add_child(_heading("Local troubleshooting"))
	_developer_summary = Label.new()
	ThemeTokens.apply_label(_developer_summary, "readout")
	_developer_summary.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	side.add_child(_developer_summary)
	for action: String in ["copy", "refresh", "fit", "camera", "samples"]:
		var button := Button.new()
		button.text = {"copy": "Copy sanitized summary", "refresh": "Refresh local view/cache",
			"fit": "Fit map camera", "camera": "Reset camera to 1:1", "samples": "Reset diagnostic samples"}[action]
		button.pressed.connect(_developer_action.bind(action))
		side.add_child(button)
	_developer_diagnostics = CheckBox.new()
	_developer_diagnostics.text = "Show diagnostics"
	_developer_diagnostics.toggled.connect(_developer_toggle_diagnostics)
	side.add_child(_developer_diagnostics)
	_developer_graph = CheckBox.new()
	_developer_graph.text = "Show diagnostics graph"
	_developer_graph.toggled.connect(_developer_toggle_graph)
	side.add_child(_developer_graph)
	var note := Label.new()
	note.text = "Local tools only: no world reset, reducers, grants or server commands. Tests and builds run from the terminal. Server role still controls colony editing."
	note.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	side.add_child(note)
	_refresh_developer_summary()


func _developer_summary_text() -> String:
	if _profile != ContinuumClientProfile.DEVELOPER:
		return ""
	var frame: Dictionary = _diagnostics_overlay.frame_snapshot if is_instance_valid(_diagnostics_overlay) else {}
	var rtt: Dictionary = _diagnostics_overlay.rtt_snapshot if is_instance_valid(_diagnostics_overlay) else {}
	var lines: Array[String] = ["Continuum local diagnostics", "Endpoint: %s" % _sanitized_endpoint(_host),
		"Database: %s" % _safe_summary_identifier(_database), "Client profile: developer",
		"Verified role: %s" % (_role_name if _role_name in ["Viewer", "Operator", "Admin"] else "Unknown"),
		"Session: %s" % ("state ready" if _state_ready else ("joining" if _session_requested else "offline"))]
	for key: String in ["mean_fps", "p50_frame_ms", "p95_frame_ms", "p99_frame_ms"]:
		var value: Variant = frame.get(key)
		if (value is float or value is int) and is_finite(float(value)):
			lines.append("%s: %.2f" % [key, float(value)])
	var latency: Variant = rtt.get("rtt_ms")
	if rtt.get("source", "") == "tcp_info" and not rtt.get("rtt_stale", false) and (latency is float or latency is int) and is_finite(float(latency)):
		lines.append("TCP RTT ms: %.2f" % float(latency))
	else:
		lines.append("TCP RTT: unavailable")
	return "\n".join(lines)


func _safe_summary_identifier(value: String) -> String:
	var result := ""
	for character: String in value.left(128):
		if character in "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-:":
			result += character
	return result


func _sanitized_endpoint(value: String) -> String:
	var scheme := ""
	var authority := value
	var separator := value.find("://")
	if separator >= 0:
		var candidate := value.left(separator).to_lower()
		if candidate not in ["http", "https", "ws", "wss"]:
			return "(not configured)"
		scheme = candidate + "://"
		authority = value.substr(separator + 3)
	for delimiter: String in ["/", "?", "#"]:
		authority = authority.get_slice(delimiter, 0)
	authority = authority.get_slice("@", authority.get_slice_count("@") - 1)
	return scheme + _safe_summary_identifier(authority) if not authority.is_empty() else "(not configured)"


func _refresh_developer_summary() -> void:
	if _profile != ContinuumClientProfile.DEVELOPER or not is_instance_valid(_developer_summary):
		return
	var text := _developer_summary_text()
	if _developer_summary.text != text:
		_developer_summary.text = text
	_developer_diagnostics.set_pressed_no_signal(_settings.diagnostics_enabled)
	_developer_graph.set_pressed_no_signal(_settings.diagnostics_graph_enabled)
	_developer_graph.disabled = not _settings.diagnostics_enabled


func _developer_action(action: String) -> void:
	if _profile != ContinuumClientProfile.DEVELOPER or _closing or _exit_requested:
		return
	match action:
		"copy": DisplayServer.clipboard_set(_developer_summary_text())
		"refresh":
			_full_ui_refresh = true
			_dirty = true
			_map_dirty = true
			_map_tables_changed.clear()
		"fit": map.fit_camera()
		"camera": map.reset_camera()
		"samples": _reset_diagnostics_samples()
	_refresh_developer_summary()


func _developer_toggle_diagnostics(enabled: bool) -> void:
	if _profile != ContinuumClientProfile.DEVELOPER or _closing or _exit_requested:
		return
	configure_diagnostics(enabled, _settings.diagnostics_graph_enabled, false)
	_refresh_developer_summary()


func _developer_toggle_graph(enabled: bool) -> void:
	if _profile != ContinuumClientProfile.DEVELOPER or _closing or _exit_requested:
		return
	configure_diagnostics(_settings.diagnostics_enabled, enabled, false)
	_refresh_developer_summary()


func _build_telemetry() -> void:
	_clock = Label.new()
	_clock.text = "Day --  --:--"
	ThemeTokens.apply_label(_clock, "log")
	_clock.custom_minimum_size.x = 100
	workspace.telemetry.add_child(_clock)
	_resource_group = GridContainer.new()
	_resource_group.columns = 4
	_resource_group.add_theme_constant_override("h_separation", int(ThemeTokens.number("space-2")))
	_resource_group.add_theme_constant_override("v_separation", 0)
	workspace.telemetry.add_child(_resource_group)
	for kind: int in [ContinuumResourceKind.Options.food, ContinuumResourceKind.Options.wood, ContinuumResourceKind.Options.stone, ContinuumResourceKind.Options.meat]:
		var card := ResourceControl.new()
		card.tooltip_text = "Stored %s. Ground stacks and carried cargo are separate." % ContinuumResourceKind.parse_enum_name(kind)
		card.set_model({"name": ContinuumResourceKind.parse_enum_name(kind).capitalize()}, {"compact": true})
		_resource_group.add_child(card)
		_resource_labels[kind] = card
	_rates_status = Label.new()
	ThemeTokens.apply_label(_rates_status, "small")
	workspace.telemetry.add_child(_rates_status)
	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	workspace.telemetry.add_child(spacer)
	_population = Label.new()
	_population.text = "Crew --"
	ThemeTokens.apply_label(_population, "readout")
	workspace.telemetry.add_child(_population)
	var connection_row := HBoxContainer.new()
	workspace.telemetry.add_child(connection_row)
	_connection_glyph = TextureRect.new()
	_connection_glyph.custom_minimum_size = Vector2(16, 16)
	_connection_glyph.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_connection_glyph.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	connection_row.add_child(_connection_glyph)
	_connection_label = Label.new()
	ThemeTokens.apply_label(_connection_label, "body")
	connection_row.add_child(_connection_label)
	_identity_label = Label.new()
	ThemeTokens.apply_label(_identity_label, "small")
	workspace.telemetry.add_child(_identity_label)
	_session_menu = MenuButton.new()
	_session_menu.focus_mode = Control.FOCUS_ALL
	_session_menu.text = "Menu"
	_session_menu.theme_type_variation = "ButtonQuiet"
	var popup := _session_menu.get_popup()
	popup.add_item("Since you left", 0)
	popup.add_item("Copy authenticated identity", 1)
	popup.add_separator()
	popup.add_item("Settings / servers / disconnect", 2)
	popup.add_separator("Stored resources")
	for kind: int in _resource_labels:
		popup.add_item(ContinuumResourceKind.parse_enum_name(kind).capitalize() + " · unavailable", 10 + kind)
		popup.set_item_disabled(popup.item_count - 1, true)
	popup.id_pressed.connect(_session_menu_action)
	workspace.telemetry.add_child(_session_menu)
	workspace.area.resized.connect(func() -> void: _refresh_status.call_deferred())
	workspace.diagnostics_host.resized.connect(func() -> void: _refresh_status.call_deferred())

func _session_menu_action(id: int) -> void:
	match id:
		0: _show_away_digest()
		1:
			if not _authenticated_identity.is_empty(): DisplayServer.clipboard_set(_authenticated_identity)
		2: leave_session()


func _build_map_toolbar() -> void:
	_map_toolbar = PanelContainer.new()
	_map_toolbar.name = "MapToolbar"
	_map_toolbar.tooltip_text = "Wheel: zoom at cursor. Middle-drag: pan. PgUp/PgDn: half-metre layers."
	workspace.area.add_child(_map_toolbar)
	_map_toolbar.position = Vector2(16, 16)
	var flow := HFlowContainer.new()
	flow.add_theme_constant_override("h_separation", int(ThemeTokens.number("space-2")))
	_map_toolbar.add_child(flow)
	var layer_row := HBoxContainer.new()
	flow.add_child(layer_row)
	var down := _map_navigation_button(layer_row, "↓", "Layer down by 0.5m (PgDn / [)", func() -> void: map.set_cut(map.terrain_model.cut - 1))
	_map_layer_label = Label.new()
	_map_layer_label.tooltip_text = "Inclusive cut layer z; every layer is 0.5 metres. Navigation is available to Viewers too."
	ThemeTokens.apply_label(_map_layer_label, "readout")
	layer_row.add_child(_map_layer_label)
	var up := _map_navigation_button(layer_row, "↑", "Layer up by 0.5m (PgUp / ])", func() -> void: map.set_cut(map.terrain_model.cut + 1))
	_map_layer_buttons = {-1: down, 1: up}
	var zoom_row := HBoxContainer.new()
	flow.add_child(zoom_row)
	_map_navigation_button(zoom_row, "−", "Zoom out; mouse wheel anchors at the cursor", func() -> void: map.zoom_at(1.0 / 1.2, map.size * 0.5))
	_map_zoom_label = Label.new()
	_map_zoom_label.tooltip_text = "Zoom relative to native 32px cells. Middle-drag pans the map; Fit recentres it."
	ThemeTokens.apply_label(_map_zoom_label, "readout")
	zoom_row.add_child(_map_zoom_label)
	_map_navigation_button(zoom_row, "+", "Zoom in; middle-drag pans without editing", func() -> void: map.zoom_at(1.2, map.size * 0.5))
	_map_zoom_buttons["reset"] = _map_navigation_button(zoom_row, "1:1", "Reset to native 100% zoom and centre", map.reset_camera)
	_map_zoom_buttons["fit"] = _map_navigation_button(zoom_row, "Fit", "Fit the entire map and centre it", map.fit_camera)
	_sync_map_toolbar()

func _map_input_blocked(point: Vector2) -> bool:
	if is_instance_valid(_session_menu) and _session_menu.get_popup().visible:
		return true
	if workspace.blocks_map_input(point):
		return true
	for overlay: Control in [_map_toolbar, _action_feedback, _intent_feedback.get_parent() if is_instance_valid(_intent_feedback) else null]:
		if is_instance_valid(overlay) and overlay.is_visible_in_tree() and overlay.get_global_rect().has_point(point):
			return true
	return false


func _map_navigation_button(parent: Control, caption: String, hint: String, callback: Callable) -> Button:
	var button := Button.new()
	button.text = caption
	button.theme_type_variation = "ButtonQuiet"
	var icon_name: String = {"↓": "chevron-down", "↑": "chevron-up", "−": "chevron-left", "+": "plus", "Fit": "camera-fit"}.get(caption, "")
	if not icon_name.is_empty():
		button.icon = InterfaceIcons.texture(icon_name)
		button.text = ""
	button.tooltip_text = hint
	button.add_theme_font_size_override("font_size", _metrics.font(12))
	button.set_meta("ui_font_reference", 12.0)
	button.custom_minimum_size = _metrics.min_size(24, 24)
	button.pressed.connect(callback)
	parent.add_child(button)
	_map_navigation_buttons.append(button)
	return button


func _sync_map_toolbar() -> void:
	if _map_layer_label == null:
		return
	if _toolbar_metric_font != _metrics.base_font_size:
		_toolbar_metric_font = _metrics.base_font_size
		_map_toolbar.add_theme_stylebox_override("panel", DeckTheme.box(DeckTheme.PANEL_GROUND, DeckTheme.LINE, int(ThemeTokens.number("space-1"))))
		_map_toolbar.get_child(0).add_theme_constant_override("h_separation", int(ThemeTokens.number("space-2")))
		_map_toolbar.get_child(0).add_theme_constant_override("v_separation", int(ThemeTokens.number("space-1")))
		for button in _map_navigation_buttons:
			for state in ["normal", "hover", "pressed", "disabled"]:
				var style: StyleBox = theme.get_stylebox(state, "ButtonQuiet").duplicate()
				style.set_content_margin(SIDE_TOP, ThemeTokens.number("space-1"))
				style.set_content_margin(SIDE_BOTTOM, ThemeTokens.number("space-1"))
				style.set_content_margin(SIDE_LEFT, ThemeTokens.number("space-1"))
				style.set_content_margin(SIDE_RIGHT, ThemeTokens.number("space-1"))
				button.add_theme_stylebox_override(state, style)
	_map_layer_label.text = "z=%d · %.1fm" % [map.terrain_model.cut, map.terrain_model.cut * LayeredTerrainModel.METRES_PER_LAYER]
	_map_zoom_label.text = "%d%%" % roundi(map.zoom_percent())
	for step: int in _map_layer_buttons:
		_map_layer_buttons[step].disabled = not map.layered or (map.terrain_model.cut <= map.terrain_model.min_z if step < 0 else map.terrain_model.cut >= map.terrain_model.max_z)


func _refresh_permissions() -> void:
	if not is_instance_valid(workspace):
		return
	workspace.set_panel_authorized("policies", _can_operate)
	workspace.set_panel_authorized("operations", _can_operate)
	workspace.set_panel_authorized("admin", _is_admin)
	workspace.set_panel_authorized("developer", _profile == ContinuumClientProfile.DEVELOPER)
	for button: Button in _speed_buttons.values():
		if not _is_admin or not _state_ready:
			button.disabled = true
	if is_instance_valid(_speed_strip):
		_speed_strip.visible = _is_admin
	for mode: StringName in [&"build", &"excavate", &"facility"]:
		if is_instance_valid(_mode_buttons.get(mode)):
			_mode_buttons[mode].visible = _can_operate
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
	ThemeTokens.apply_label(label, "section")
	return label


func _set_connection_text(text: String, colour: Color) -> void:
	if _connection_label == null:
		return
	_connection_message = text
	if _settings_warning not in ["loaded", "missing"]:
		_connection_message += " | settings %s; defaults" % _settings_warning
	_connection_colour = colour
	_render_connection_role()


func _set_feedback(label: Label, compact: String, details: String) -> void:
	if label == _intent_feedback:
		label.visible = compact != "Select: drag rectangle"
		if label.get_parent() is HBoxContainer:
			label.get_parent().visible = label.visible
	label.text = compact
	label.tooltip_text = details


func _render_connection_role() -> void:
	if _connection_label == null:
		return
	_connection_label.text = "Live" if _state_ready else (_connection_message if _connection_message.length() <= 18 else "Connection problem")
	_connection_label.tooltip_text = "%s\nRole: %s" % [_connection_message, _role_name]
	var token := "ink-muted" if _state_ready else ("critical" if _connection_colour == ThemeTokens.color("critical") else ("warn" if _connection_colour == ThemeTokens.color("warn") else "ink-muted"))
	_connection_label.add_theme_color_override("font_color", ThemeTokens.color(token))
	_connection_glyph.texture = ThemeTokens.glyph(token if token in ["warn", "critical"] else "notice")
	_identity_label.text = _role_name + (" · dev" if _profile == ContinuumClientProfile.DEVELOPER else "")
	_identity_label.tooltip_text = "Authenticated identity: %s\nVerified server role: %s\nLocal profile: %s" % [_authenticated_identity, _role_name, _profile]
	if is_instance_valid(_session_menu):
		_session_menu.tooltip_text = _identity_label.tooltip_text + "\n" + _clock.text + " · " + _population.text
		_session_menu.get_popup().set_item_disabled(1, _authenticated_identity.is_empty())


func _refresh() -> void:
	if SpacetimeDB.Continuum.db == null:
		map.bind_world_source(null)
		_session_observations.reset()
		_state_ready = false
		_refresh_alerts()
		_full_ui_refresh = true
		return
	_observe_session_state()
	_refresh_status()
	if _full_ui_refresh or _ui_tables_changed.has("colonist"):
		_refresh_colonists()
	_refresh_controls()
	if _full_ui_refresh or _ui_tables_changed.has("alert"):
		_refresh_alerts()
	if _full_ui_refresh or _ui_tables_changed.has("event_log"):
		_refresh_feed()
	_full_ui_refresh = false
	_ui_tables_changed.clear()


func _refresh_status() -> void:
	if SpacetimeDB.Continuum.db == null or not is_instance_valid(_rates_status):
		return
	var config: ContinuumConfig = SpacetimeDB.Continuum.db.config.id.find(0)
	var colony: ContinuumColony = SpacetimeDB.Continuum.db.colony.id.find(0)
	if config == null or colony == null:
		_status_label.text = "Waiting for authoritative colony state…"
		return

	var day: int = int(config.game_seconds / 86400.0) + 1
	var second_of_day: float = fmod(config.game_seconds, 86400.0)
	var hour: int = int(second_of_day / 3600.0)
	var minute: int = int(fmod(second_of_day, 3600.0) / 60.0)
	_clock.text = "Day %02d  %02d:%02d%s" % [day, hour, minute, " · stale" if not _state_ready else ""]
	var warming := 0
	var usable := 0
	var budget := workspace.area.size.x - (workspace.diagnostics_host.custom_minimum_size.x if workspace.diagnostics_host.visible else 0.0)
	var wide := budget >= 1100
	for kind: int in _resource_labels:
		var resource := ContinuumResourceKind.parse_enum_name(kind)
		var observed := _session_observations.resource(resource) if config.time_scale > 0.0 else {"rate_available": false}
		var data := {"name": resource.capitalize(), "value": float(colony.get(resource)), "availability": "warming" if _state_ready and config.time_scale > 0.0 else "unavailable"}
		if observed.rate_available and _state_ready and config.time_scale > 0.0:
			usable += 1
			data.rate_per_game_hour = observed.rate
			if observed.rate < 0.0:
				data.eta_game_hours = maxf(0.0, float(colony.get(resource))) / -float(observed.rate)
		else:
			warming += 1
		var base_config := {"compact": true, "show_rate": wide, "narrow": budget < 800}
		var effective: Dictionary = _status_effective_configs.get(kind, base_config) if data == _status_resource_inputs.get(kind) and base_config == _status_resource_configs.get(kind) else base_config
		_resource_labels[kind].set_model(data, effective)
		_status_effective_configs[kind] = effective
		_resource_labels[kind].show()
		_status_resource_inputs[kind] = data
		_status_resource_configs[kind] = base_config
		var entry: int = _session_menu.get_popup().get_item_index(10 + kind)
		_session_menu.get_popup().set_item_text(entry, "%s · %.1f stored" % [resource.capitalize(), data.value])
		_resource_labels[kind].tooltip_text = "%s stored: %s · %s\nMeasured per game hour since connection. Ground stacks and carried cargo are separate." % [resource.capitalize(), str(data.value), _resource_labels[kind].model.rate_copy]
	_rates_status.text = "Rates warming" if usable == 0 and _state_ready and config.time_scale > 0 else ("Rates unavailable" if usable == 0 else ("Rates partial" if warming > 0 else ""))
	_rates_status.tooltip_text = "Observed rates require a usable game hour since connection. %d of 4 rates available; paused clocks have no rate or ETA." % usable
	_rates_status.visible = wide and not _status_secondary_hidden and not _rates_status.text.is_empty()
	_clock.tooltip_text = _rates_status.tooltip_text
	_population.visible = wide and not _status_secondary_hidden
	_identity_label.visible = budget >= 800 and not _status_secondary_hidden
	_population.text = "Crew %02d" % colony.population
	workspace.set_panel_live_count("people", colony.population)
	_status_label.text = "Average mood %.0f%%\nAverage output %.0f%%\nGround stocks and cargo tracked separately." % [clampf(colony.avg_mood, 0, 100), clampf(colony.avg_productivity, 0, 100)]
	_render_connection_role()
	_queue_status_balance()

func _queue_status_balance() -> void:
	if _status_balance_pending or not is_instance_valid(_resource_group): return
	_status_balance_pending = true
	get_tree().process_frame.connect(_balance_status, CONNECT_ONE_SHOT)

func _balance_status() -> void:
	_status_balance_pending = false
	if not is_inside_tree() or not is_instance_valid(_resource_group): return
	var budget := workspace.area.size.x - (workspace.diagnostics_host.custom_minimum_size.x if workspace.diagnostics_host.visible else 0.0)
	var signature := JSON.stringify([_status_resource_inputs, _status_resource_configs, budget, _connection_label.text, _identity_label.text, _clock.get_combined_minimum_size().x])
	if signature == _status_balance_signature: return
	_status_balance_signature = signature
	_population.visible = budget >= 1100
	_identity_label.visible = budget >= 800
	_rates_status.visible = budget >= 1100 and not _rates_status.text.is_empty()
	# Reserve the actual Menu and neutral connection controls before stock layout.
	# Re-evaluate complete live minima after every data refresh, not just resize.
	var menu_width := _session_menu.get_combined_minimum_size().x
	var connection_width: float = _connection_label.get_parent().get_combined_minimum_size().x
	var clock_width := _clock.get_combined_minimum_size().x
	var spacing := float(workspace.telemetry.get_theme_constant("separation"))
	var stocks_width := float(_resource_group.get_theme_constant("h_separation")) * 3
	for card: ResourceReadout in _resource_labels.values(): stocks_width += card.get_combined_minimum_size().x
	var secondary_width := (_population.get_combined_minimum_size().x if _population.visible else 0.0) + (_identity_label.get_combined_minimum_size().x if _identity_label.visible else 0.0) + (_rates_status.get_combined_minimum_size().x if _rates_status.visible else 0.0)
	var base := menu_width + connection_width + clock_width + spacing * 4
	_status_secondary_hidden = stocks_width + base + secondary_width > budget
	if _status_secondary_hidden:
		_population.hide()
		_identity_label.hide()
		_rates_status.hide()
		# Keep all warning words/glyphs/horizons; optional observed rates go first.
		for kind: int in _resource_labels:
			var compact_config: Dictionary = _status_resource_configs[kind].duplicate()
			compact_config.show_rate = false
			compact_config.narrow = true
			compact_config.abbreviate_stock = true
			_resource_labels[kind].set_model(_status_resource_inputs[kind], compact_config)
			_status_effective_configs[kind] = compact_config
		stocks_width = float(_resource_group.get_theme_constant("h_separation")) * 3
		for card: ResourceReadout in _resource_labels.values(): stocks_width += card.get_combined_minimum_size().x
	# At genuinely tight budgets the resource grid moves BELOW the metadata row,
	# still within the one status group. This is preferable to hiding a warning.
	var reflow := stocks_width + base > budget
	_clock.visible = not reflow or clock_width + menu_width + connection_width + spacing * 3 <= budget
	if reflow:
		if _resource_group.get_parent() != workspace.status_content:
			_resource_group.reparent(workspace.status_content)
		_resource_group.columns = 4
		while _resource_group.columns > 1 and _resource_group.get_combined_minimum_size().x > budget:
			_resource_group.columns -= 1
	else:
		if _resource_group.get_parent() != workspace.telemetry:
			_resource_group.reparent(workspace.telemetry)
		workspace.telemetry.move_child(_resource_group, 1)
		_resource_group.columns = 4


func _sample_history() -> void:
	if not _state_ready or SpacetimeDB.Continuum.db == null:
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


func _build_vertical_controls(side: Control) -> void:
	var row := HFlowContainer.new()
	for step: int in [-1, 1]:
		var button := Button.new()
		button.text = "Layer down" if step < 0 else "Layer up"
		button.tooltip_text = "Exactly 0.5m. PgUp/PgDn or [ / ]"
		button.pressed.connect(func() -> void: map.set_cut(map.terrain_model.cut + step))
		row.add_child(button)
	side.add_child(row)
	_layer_label = Label.new()
	ThemeTokens.apply_label(_layer_label, "readout")
	_layer_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	side.add_child(_layer_label)
	_cell_label = Label.new()
	ThemeTokens.apply_label(_cell_label, "readout")
	_cell_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_cell_label.text = "Select a visible surface"
	side.add_child(_cell_label)
	_dimension_inputs["excavation"] = _dimension_control(side, "Excavation height (0.5m layers)", 6, 1, 256,
		func(value: float) -> void: map.excavation_height = int(value))
	_dimension_inputs["width"] = _dimension_control(side, "Facility width (cells)", 1, 1, 24,
		func(value: float) -> void: map.facility_width = int(value))
	_dimension_inputs["depth"] = _dimension_control(side, "Facility depth (cells)", 1, 1, 24,
		func(value: float) -> void: map.facility_depth = int(value))
	_dimension_inputs["clearance"] = _dimension_control(side, "Facility clearance (0.5m layers)", 6, 1, 256,
		func(value: float) -> void: map.facility_height = int(value))
	_excavation_list = VBoxContainer.new()
	side.add_child(_excavation_list)


func _dimension_control(side: Control, caption: String, value: int, minimum: int, maximum: int, changed: Callable) -> SpinBox:
	var row := VBoxContainer.new()
	var label := Label.new()
	label.text = caption
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(label)
	var number := SpinBox.new()
	number.min_value = minimum
	number.max_value = maximum
	number.step = 1
	number.value = value
	number.value_changed.connect(changed)
	row.add_child(number)
	side.add_child(row)
	return number


func _refresh_excavations() -> void:
	var rows := ColonyMap.table_rows(SpacetimeDB.Continuum.db, "excavation_designation")
	var signature: Array = [map.layered, map.terrain_model.revision, _can_operate, _state_ready, _intent_request != null]
	for row in rows:
		signature.append([row.id, row.x_0, row.y_0, row.x_1, row.y_1, row.bottom_z, row.height, row.enabled, row.completed_cells, row.total_cells])
	if signature == _excavation_signature:
		return
	_excavation_signature = signature
	for child in _excavation_list.get_children():
		_excavation_list.remove_child(child)
		child.queue_free()
	if not map.layered:
		return
	for designation in rows:
		var exposed := false
		var area := ColonyMap.designation_rect(designation)
		for y in range(area.position.y, area.end.y):
			for x in range(area.position.x, area.end.x):
				var surface: Variant = map.terrain_model.surface_at(Vector2i(x, y))
				if surface != null and surface.z >= designation.bottom_z and surface.z < designation.bottom_z + designation.height:
					exposed = true
		if not exposed:
			continue
		var row := HFlowContainer.new()
		var label := Label.new()
		label.text = "Dig #%d z=%d h=%d: %d/%d" % [designation.id, designation.bottom_z,
			designation.height, designation.completed_cells, designation.total_cells]
		row.add_child(label)
		var toggle := Button.new()
		toggle.text = "Pause" if designation.enabled else "Resume"
		toggle.disabled = not _can_operate or not _state_ready or _intent_request != null
		toggle.pressed.connect(_dispatch_vertical.bind("set_excavation_enabled", [designation.id, not designation.enabled], "Toggle excavation"))
		row.add_child(toggle)
		var cancel := Button.new()
		cancel.text = "Cancel"
		cancel.disabled = toggle.disabled
		cancel.pressed.connect(_dispatch_vertical.bind("cancel_excavation", [designation.id], "Cancel excavation"))
		row.add_child(cancel)
		_excavation_list.add_child(row)


func _selection_z() -> Variant:
	if not map.has_world_snapshot() or not map.terrain_model.selection_valid(_selected_surface):
		_selected_rect = Rect2i()
		_selected_surface = {}
		map.clear_selection()
		_set_feedback(_intent_feedback, "Selection changed", "The selected surface changed; select the exposed floor again.")
		return null
	return _selected_surface.get("base")


func _set_block_enabled(enabled: bool) -> void:
	if not _can_operate or _selected_rect.size == Vector2i.ZERO:
		return
	if not _state_ready or _intent_request != null:
		return
	if map.layered:
		var z: Variant = _selection_z()
		if z == null:
			_set_feedback(_intent_feedback, "Mixed elevations", "Block controls require one exposed floor elevation.")
			return
		_dispatch_vertical("set_tile_block_enabled_at", [_selected_rect.position.x, _selected_rect.position.y,
			_selected_rect.end.x - 1, _selected_rect.end.y - 1, int(z), enabled], "Set visible block enabled")
		return
	_track_intent(SpacetimeDB.Continuum.reducers.set_tile_block_enabled(
		_selected_rect.position.x, _selected_rect.position.y, _selected_rect.end.x - 1,
		_selected_rect.end.y - 1, enabled), "Set block %s" % ("enabled" if enabled else "disabled"))


func _set_block_work(work: int, priority: int, enabled: bool) -> void:
	if not _can_operate or _selected_rect.size == Vector2i.ZERO or not _state_ready or _intent_request != null:
		return
	if map.layered:
		var z: Variant = _selection_z()
		if z == null:
			_set_feedback(_intent_feedback, "Mixed elevations", "Work controls require one exposed floor elevation.")
			return
		_dispatch_vertical("set_block_work_order_at", [_selected_rect.position.x, _selected_rect.position.y,
			_selected_rect.end.x - 1, _selected_rect.end.y - 1, int(z), ContinuumWorkType.create(work), priority, enabled],
			"Set visible block work")
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


func _refresh_colonists() -> void:
	var colonists: Array[ContinuumColonist] = SpacetimeDB.Continuum.db.colonist.iter()
	colonists.sort_custom(func(a: ContinuumColonist, b: ContinuumColonist) -> bool:
		return a.id < b.id)
	for id in _colonist_cards.keys():
		if SpacetimeDB.Continuum.db.colonist.id.find(id) == null:
			var removed: PanelContainer = _colonist_cards[id]
			_colonist_box.remove_child(removed)
			removed.queue_free()
			_colonist_cards.erase(id)
	if colonists.is_empty():
		_selected_colonist = -1
		_selected_card.visible = false
		if not is_instance_valid(_colonist_empty):
			_colonist_empty = _heading("Waiting for colonist data")
			_colonist_box.add_child(_colonist_empty)
		return
	if is_instance_valid(_colonist_empty):
		_colonist_box.remove_child(_colonist_empty)
		_colonist_empty.queue_free()
		_colonist_empty = null

	if _selected_colonist >= 0 and SpacetimeDB.Continuum.db.colonist.id.find(_selected_colonist) == null:
		_selected_colonist = -1
	var index := 0
	for colonist: ContinuumColonist in colonists:
		if not _colonist_cards.has(colonist.id):
			var row := RosterControl.new()
			row.selection_requested.connect(_select_colonist)
			_colonist_box.add_child(row)
			_colonist_cards[colonist.id] = row
		var card: RosterRow = _colonist_cards[colonist.id]
		_colonist_box.move_child(card, index)
		index += 1
		var data := UiData.colonist(colonist, _session_observations, colonist.id == _selected_colonist)
		if card.get_meta("live_input", {}) != data:
			card.set_meta("live_input", data.duplicate(true))
			card.set_model(data)
	_selected_card.visible = _selected_colonist >= 0
	if _selected_card.visible:
		var data := UiData.colonist(SpacetimeDB.Continuum.db.colonist.id.find(_selected_colonist), _session_observations, true)
		if _selected_card.get_meta("live_input", {}) != data:
			_selected_card.set_meta("live_input", data.duplicate(true))
			_selected_card.set_model(data)
	workspace.set_panel_live_count("people", colonists.size())


func _select_colonist(id: Variant) -> void:
	if not id is int or SpacetimeDB.Continuum.db == null or not _state_ready or SpacetimeDB.Continuum.db.colonist.id.find(id) == null:
		return
	_selected_colonist = id
	_refresh_colonists()
	map.set_selected_colonist(id)


func _goto_colonist(id: Variant) -> void:
	if not id is int or SpacetimeDB.Continuum.db == null or not _state_ready:
		return
	var row: ContinuumColonist = SpacetimeDB.Continuum.db.colonist.id.find(id)
	if row == null:
		return
	_select_colonist(id)
	if map.layered:
		map.set_cut(row.z)
	map.pan_by(map.size * 0.5 - map.world_to_screen(Vector2(row.x, row.y) + Vector2(0.5, 0.5)))


func _refresh_controls() -> void:
	if SpacetimeDB.Continuum.db == null:
		map.bind_world_source(null)
		_state_ready = false
		_build_menu.disabled = true
		_sync_map_toolbar()
		return
	var config: ContinuumConfig = SpacetimeDB.Continuum.db.config.id.find(0)
	var busy := not _state_ready or _intent_request != null
	_build_menu.disabled = busy or not _can_operate
	_layer_label.text = "Cut z=%d / %.1fm (inclusive)" % [map.terrain_model.cut, map.terrain_model.cut * 0.5]
	_sync_map_toolbar()
	if map.layered:
		_dimension_inputs["excavation"].max_value = map.terrain_model.max_z - map.terrain_model.min_z + 1
		_dimension_inputs["clearance"].max_value = map.terrain_model.max_z - map.terrain_model.min_z + 1
		_dimension_inputs["width"].max_value = map.terrain_model.width
		_dimension_inputs["depth"].max_value = map.terrain_model.height
	for number: SpinBox in _dimension_inputs.values():
		number.editable = _can_operate and not busy
	for mode: StringName in _mode_buttons:
		_mode_buttons[mode].disabled = mode != &"select" and (not _can_operate or busy)
	_refresh_excavations()
	_tile_action_box.visible = true
	_block_box.visible = _can_operate
	var block_tiles := 0
	var occupied := 0
	var enabled_count := 0
	var compatible_counts: Dictionary = {}
	var block_rows: Array[ContinuumTile] = []
	if _selected_rect.size != Vector2i.ZERO:
		block_rows = map.tiles_in_rect(_selected_rect)
	if _selected_rect.size != Vector2i.ZERO:
		for tile: ContinuumTile in block_rows:
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
		for tile: ContinuumTile in block_rows:
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
	if map.layered and (not map.terrain_model.selection_valid(_selected_surface) or _selected_surface.get("base") == null):
		block_busy = true
	for key: String in ["enabled_true", "enabled_false"]:
		_block_controls[key].disabled = block_busy
	for work: int in [ContinuumWorkType.Options.farming, ContinuumWorkType.Options.logging,
			ContinuumWorkType.Options.mining, ContinuumWorkType.Options.hunting]:
		var controls: Dictionary = _block_controls[work]
		var count: int = compatible_counts.get(work, 0)
		controls.label.text = ContinuumWorkType.parse_enum_name(work).capitalize()
		controls.count.text = "(%d)" % count
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
		speed_button.disabled = not _is_admin or not _state_ready or busy or config == null
		speed_button.set_pressed_no_signal(config != null and is_equal_approx(config.time_scale, float(speed)))
	var tile: ContinuumTile = SpacetimeDB.Continuum.db.tile.id.find(_selected_tile_id)
	if tile != null and not map.row_visible(tile):
		tile = null
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
	if map.layered:
		tile_details += " | z=%d footprint %dx%d clearance %d" % [LayeredTerrainModel.field(tile, "z", 0),
			LayeredTerrainModel.field(tile, "width", 1), LayeredTerrainModel.field(tile, "depth", 1),
			LayeredTerrainModel.field(tile, "clearance_height", 6)]
	for stack: ContinuumItemStack in SpacetimeDB.Continuum.db.item_stack.iter():
		if map.row_visible(stack) and stack.x == tile.x and stack.y == tile.y:
			tile_details += "\nGround: %.1f %s" % [stack.amount,
				ContinuumResourceKind.parse_enum_name(stack.kind.value)]
	if tile.kind.value == ContinuumTileKind.Options.storage:
		tile_details += "\nStorage: shared unlimited stock"
	if not compatible.is_empty() and not tile.enabled:
		tile_details += "\nProduction: disabled"
	if not _state_ready:
		tile_details += "\nState: stale"
	var terrain: ContinuumTerrain = SpacetimeDB.Continuum.db.terrain.tile_id.find(tile.id)
	if terrain != null:
		tile_details += "\n\nSoil: %s\nFertility: %.0f%%\nMoisture: %.0f%%\nCover: %s (%.0f%%)" % [
			_map_soil_name(terrain.soil_fertility, terrain.moisture), terrain.soil_fertility * 100.0,
			terrain.moisture * 100.0, _map_cover_name(terrain.forest_density), terrain.forest_density * 100.0]
	_tile_info.text = tile_details
	_tile_info.tooltip_text = tile_details


func _refresh_alerts() -> void:
	var available := _state_ready and SpacetimeDB.Continuum.db != null
	_alert_waiting.visible = not available
	_alert_box.visible = available
	var rows := _live_alert_models() if available else []
	map.set_alert_pins([])
	if available:
		_alert_box.set_reduced_motion(_settings.reduced_motion)
		_alert_box.set_model(rows)
		for row: Dictionary in rows:
			if row.acknowledged:
				_ack_requests.erase(row.id)
	workspace.set_panel_live_count("alerts", rows.size() if available else -1)
	if not available:
		_alert_box.set_model(null, {"status": "unavailable"})
	_publish_alert_counts(rows)
	_sync_open_digest()


func _refresh_feed() -> void:
	var events: Array[ContinuumEventLog] = SpacetimeDB.Continuum.db.event_log.iter()
	events.sort_custom(func(a: ContinuumEventLog, b: ContinuumEventLog) -> bool:
		return a.id < b.id)
	if events.size() > MAX_FEED_LINES:
		events = events.slice(events.size() - MAX_FEED_LINES)

	var rows: Array = []
	for event: ContinuumEventLog in events:
		rows.append(UiData.event(event))
	_feed.set_model(rows)
	workspace.set_panel_live_count("activity", rows.size())


func _authoritative_snapshot() -> Dictionary:
	if not _state_ready or SpacetimeDB.Continuum.db == null:
		return {}
	var config: ContinuumConfig = SpacetimeDB.Continuum.db.config.id.find(0)
	var colony: ContinuumColony = SpacetimeDB.Continuum.db.colony.id.find(0)
	if config == null or colony == null:
		return {}
	var resources := {"food": colony.food, "wood": colony.wood, "stone": colony.stone, "meat": colony.meat}
	var watermark := 0
	for event: ContinuumEventLog in SpacetimeDB.Continuum.db.event_log.iter():
		watermark = maxi(watermark, event.id)
	return {"resources": resources, "generation": config.generation, "game_seconds": config.game_seconds, "event_watermark": watermark}


func _observe_session_state() -> void:
	var snapshot := _authoritative_snapshot()
	if snapshot.is_empty():
		return
	var needs := {}
	for row: ContinuumColonist in SpacetimeDB.Continuum.db.colonist.iter():
		var raw := {}
		for descriptor: Array in PresentationModels.NEEDS:
			var field: String = descriptor[1]
			raw[field] = row.get(field)
		needs[row.id] = SessionObservations.satisfaction(raw)
	if _session_observations.observe(snapshot.game_seconds, snapshot.generation, snapshot.resources, needs):
		_ui_tables_changed["colonist"] = true
	if not _return_observed:
		var events: Array = []
		for row: ContinuumEventLog in SpacetimeDB.Continuum.db.event_log.iter():
			events.append(UiData.event(row))
		_return_digest = _return_snapshots.digest(_return_key, snapshot, _live_alert_models(), events)
		_return_digest["current_resources"] = snapshot.resources.duplicate()
		_return_digest["captured_game_seconds"] = snapshot.game_seconds
		_return_observed = true
		_return_snapshot = snapshot
		_save_return_baseline()
		if _return_digest.baseline_available:
			_show_away_digest()
	else:
		if not _return_snapshot.is_empty() and (snapshot.generation != _return_snapshot.generation or snapshot.game_seconds < _return_snapshot.game_seconds or snapshot.event_watermark < _return_snapshot.event_watermark):
			_return_digest = {"baseline_available": false, "state": "reset", "message": "Colony reset or clock moved backward · previous local baseline discarded.", "coverage_note": "Earlier events may be missing · up to 200 retained events"}
			_return_snapshots.forget(_return_key)
		_return_snapshot = snapshot
	_sync_open_digest()


func _save_return_baseline() -> void:
	if _return_observed and not _return_key.is_empty() and not _return_snapshot.is_empty():
		if _return_snapshots.remember(_return_key, _return_snapshot):
			var error := _return_snapshots.save_file()
			if error != OK:
				_return_digest["persistence_note"] = "Local baseline could not be saved; cross-session changes may be unavailable."


func _end_session_observations() -> void:
	if is_instance_valid(_action_feedback):
		_action_feedback.hide()
	var latest := _authoritative_snapshot()
	if not latest.is_empty() and _return_observed:
		_return_snapshot = latest
	_save_return_baseline()
	_session_observations.reset()
	_return_key = ""
	_return_observed = false
	_return_snapshot.clear()
	_return_digest.clear()
	_authenticated_identity = ""
	_selected_colonist = -1
	map.set_selected_colonist(-1)
	for id: int in _ack_requests:
		_alert_box.set_acknowledgement_state(id, false)
	_ack_requests.clear()
	if is_instance_valid(_digest_overlay):
		_hide_away_digest()


func _live_alert_models() -> Array:
	var rows: Array = []
	if not _state_ready or SpacetimeDB.Continuum.db == null:
		return rows
	var config: ContinuumConfig = SpacetimeDB.Continuum.db.config.id.find(0)
	for alert: ContinuumAlert in SpacetimeDB.Continuum.db.alert.iter():
		if alert.active:
			rows.append(UiData.alert(alert, config.game_seconds if config != null else null, _can_operate))
	return rows


func _publish_alert_counts(rows: Array) -> void:
	for id: String in workspace.model.workspaces:
		var count := 0
		var level := "notice"
		var panels: Dictionary = workspace.model.workspaces[id].panels
		for alert: Dictionary in rows:
			if alert.level not in ["warn", "critical"]:
				continue
			var owner: String = ALERT_PANEL_OWNERS.get(alert.code, "alerts")
			if workspace.authorized.get(owner, false) and panels.get(owner, {}).get("open", false):
				count += 1
				if alert.level == "critical" or level == "notice":
					level = alert.level
		var summary := {"level": level, "count": count}
		if _alert_summary_cache.get(id) != summary:
			_alert_summary_cache[id] = summary
			workspace.set_workspace_alert_summary(id, level, count)


func _create_away_digest() -> void:
	_digest_overlay = Control.new()
	_digest_overlay.name = "AwayDigestModal"
	_digest_overlay.mouse_filter = Control.MOUSE_FILTER_STOP
	_digest_overlay.focus_mode = Control.FOCUS_ALL
	_digest_overlay.visible = false
	add_child(_digest_overlay)
	_digest_overlay.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	var center := CenterContainer.new()
	center.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_digest_overlay.add_child(center)
	center.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	var scroll := ScrollContainer.new()
	scroll.name = "DigestScroll"
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	scroll.follow_focus = true
	center.add_child(scroll)
	_digest = DigestControl.new()
	_digest.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(_digest)
	_digest.dismiss_requested.connect(_hide_away_digest)
	_digest.review_requested.connect(func(_ids: Array) -> void:
		_hide_away_digest()
		if not workspace.state("alerts").open:
			workspace.toggle_panel("alerts")
		workspace.focus_panel("alerts"))
	_digest_overlay.gui_input.connect(func(event: InputEvent) -> void:
		if event is InputEventKey and event.pressed and event.keycode == KEY_ESCAPE:
			_hide_away_digest()
			_digest_overlay.accept_event())
	_digest_overlay.resized.connect(_layout_away_digest)


func _layout_away_digest() -> void:
	var scroll: ScrollContainer = _digest.get_parent()
	scroll.custom_minimum_size = Vector2(minf(500, maxf(280, size.x - 32)), maxf(0, size.y - 64))
	_digest.custom_minimum_size.x = scroll.custom_minimum_size.x


func _show_away_digest() -> void:
	if not is_instance_valid(_digest_overlay):
		return
	_digest.set_model(_away_digest_data())
	_layout_away_digest()
	_digest_focus = get_viewport().gui_get_focus_owner()
	_digest_overlay.show()
	_digest_overlay.grab_focus()
	_sync_menu_input()

func _sync_open_digest() -> void:
	if is_instance_valid(_digest_overlay) and _digest_overlay.visible:
		_digest.set_model(_away_digest_data())

func _away_digest_data() -> Dictionary:
	var data := {"span": "Waiting for authoritative colony state.", "coverage": "Locally observed last-session baseline. Earlier events may be missing · up to 200 retained events."}
	if _return_observed:
		if _state_ready and SpacetimeDB.Continuum.db != null:
			data.needs_you = _live_alert_models()
			for alert: Dictionary in data.needs_you:
				alert.erase("time")
				alert.erase("time_label")
		else:
			data.group_coverage = {"needs_you": {"status": "unavailable"}}
		data.span = UiData.duration(_return_digest.away_game_seconds) + " since your local last session" if _return_digest.get("baseline_available", false) else _return_digest.get("message", "No local last-session baseline.")
		data.coverage = "Locally observed last-session baseline. " + _return_digest.get("coverage_note", "Earlier events may be missing · up to 200 retained events") + "\nPlayer attribution and handled summaries are unavailable. Same-generation database replacements cannot always be detected."
		if _return_digest.has("persistence_note"):
			data.coverage += "\n" + _return_digest.persistence_note
		if _return_digest.get("baseline_available", false):
			data.span += " · captured at game time " + UiData.duration(_return_digest.captured_game_seconds) + " on reconnect (frozen comparison)" if _return_digest.has("captured_game_seconds") else " · captured on reconnect (game time unavailable; frozen comparison)"
			data.deltas = []
			for resource: String in _return_digest.resource_deltas:
				var current: float = _return_digest.current_resources[resource]
				data.deltas.append({"name": resource.capitalize(), "current": current, "baseline": current - float(_return_digest.resource_deltas[resource]), "level": "notice"})
	return data


func _hide_away_digest() -> void:
	_digest_overlay.hide()
	_sync_menu_input()
	if is_instance_valid(_digest_focus) and _digest_focus.is_visible_in_tree():
		_digest_focus.grab_focus()
	_digest_focus = null
