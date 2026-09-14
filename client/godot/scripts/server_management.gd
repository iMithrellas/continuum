## Standalone server browser. Integration owns navigation, credentials, and local server management.
class_name ContinuumServerManagement
extends Control

signal join_requested(target: Dictionary)
signal back_requested
signal favorite_requested(key: String, favorite: bool)
signal history_remove_requested(key: String)
signal local_start_requested
signal local_stop_requested
signal local_force_stop_requested
signal world_selected(world_id: String, world_slug: String)

var history: ContinuumConnectionHistory
var probes: ContinuumServerProbes
var selected_key := ""
var _world_catalog: Array[Dictionary] = []
var _search := ""
var local_management_state: Dictionary = {}
var _history_list: VBoxContainer
var _metrics := UiMetrics.new()

func _ready() -> void:
	if history == null:
		history = ContinuumConnectionHistory.new(); history.load_from()
	if probes == null: probes = ContinuumServerProbes.new()
	_build_ui()

func set_history_store(store: ContinuumConnectionHistory) -> void:
	history = store

func set_probe_service(service: ContinuumServerProbes) -> void:
	probes = service
	probes.probe_finished.connect(func(_key: String, _result: Dictionary) -> void: _refresh_history_list())

func apply_metrics(value: UiMetrics) -> void:
	_metrics = value
	if is_inside_tree():
		theme = DeckTheme.create(_metrics)
		_build_ui()

func set_world_catalog(worlds: Array[Dictionary]) -> void:
	_world_catalog = worlds.duplicate(true)

func set_local_management_state(state: Dictionary) -> void:
	# The host application supplies capability/status; this component never assumes Docker.
	local_management_state = state.duplicate(true)

func select_world(world_id: String, world_slug: String) -> void:
	world_selected.emit(world_id, world_slug)

func set_search(value: String) -> void:
	_search = value
	_refresh_history_list()

func visible_entries() -> Array[Dictionary]:
	return history.entries(_search) if history else []

func request_join(key: String) -> bool:
	for entry in visible_entries():
		if entry.key == key:
			selected_key = key; join_requested.emit(entry.duplicate(true)); return true
	return false

func set_browser_visible(value: bool) -> void:
	if probes: probes.set_visible(value)

func request_favorite(key: String, favorite: bool) -> bool:
	var accepted := history != null and history.set_favorite(key, favorite) == OK
	if accepted: favorite_requested.emit(key, favorite)
	return accepted

func request_history_removal(key: String) -> bool:
	var accepted := history != null and history.remove_history(key) == OK
	if accepted: history_remove_requested.emit(key)
	return accepted

func request_local_start() -> void:
	if bool(local_management_state.get("can_start", false)): local_start_requested.emit()
func request_local_stop() -> void:
	if bool(local_management_state.get("can_stop", false)): local_stop_requested.emit()
func request_local_force_stop() -> void:
	if bool(local_management_state.get("can_force_stop", false)): local_force_stop_requested.emit()

func _process(_delta: float) -> void:
	if probes and probes.visible:
		probes.refresh(visible_entries())
		probes.process()

func _build_ui() -> void:
	# The scene is intentionally self-contained; navigation and local ownership stay outside it.
	for child in get_children(): child.queue_free()
	theme = DeckTheme.create(_metrics)
	var margin := MarginContainer.new(); margin.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	margin.add_theme_constant_override("margin_left", _metrics.px(24)); margin.add_theme_constant_override("margin_right", _metrics.px(24))
	margin.add_theme_constant_override("margin_top", _metrics.px(24)); margin.add_theme_constant_override("margin_bottom", _metrics.px(24))
	add_child(margin)
	var column := VBoxContainer.new(); margin.add_child(column)
	var heading := Label.new(); heading.text = "SERVER MANAGEMENT"; heading.add_theme_font_size_override("font_size", _metrics.font(20)); column.add_child(heading)
	var search := LineEdit.new(); search.placeholder_text = "Search connections"; search.custom_minimum_size = _metrics.min_size(240, 32); search.text_changed.connect(set_search); column.add_child(search)
	var list := VBoxContainer.new(); list.name = "ConnectionHistory"; list.size_flags_vertical = Control.SIZE_EXPAND_FILL; column.add_child(list)
	_history_list = list
	_refresh_history_list()
	var local := HBoxContainer.new()
	var start := Button.new(); start.text = "Start local"; start.disabled = not bool(local_management_state.get("can_start", false)); start.pressed.connect(request_local_start); local.add_child(start)
	var stop := Button.new(); stop.text = "Stop local"; stop.disabled = not bool(local_management_state.get("can_stop", false)); stop.pressed.connect(request_local_stop); local.add_child(stop)
	var force := Button.new(); force.text = "Force stop"; force.disabled = not bool(local_management_state.get("can_force_stop", false)); force.pressed.connect(request_local_force_stop); local.add_child(force)
	column.add_child(local)
	var back := Button.new(); back.text = "Return"; back.pressed.connect(func() -> void: back_requested.emit()); column.add_child(back)

func _refresh_history_list() -> void:
	if not is_instance_valid(_history_list): return
	for child in _history_list.get_children(): child.queue_free()
	for entry in visible_entries():
		var row := HBoxContainer.new(); row.name = str(entry.key)
		var text := Label.new(); text.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		var probe_state := probes.state(entry.key) if probes else {"status": "unknown"}
		var rtt := str(probe_state.get("rtt_ms", "unavailable")) + " ms HTTP" if probe_state.has("rtt_ms") and int(probe_state.rtt_ms) >= 0 else "HTTP RTT unavailable"
		var freshness := "stale" if probe_state.get("stale", false) else "current"
		row.add_child(text)
		var join := Button.new(); join.text = "Join"; join.custom_minimum_size = _metrics.min_size(64, 32); join.pressed.connect(request_join.bind(entry.key)); row.add_child(join)
		var favorite := Button.new(); favorite.text = "Unfavorite" if entry.get("favorite", false) else "Favorite"; favorite.custom_minimum_size = _metrics.min_size(86, 32); favorite.pressed.connect(request_favorite.bind(entry.key, not entry.get("favorite", false))); row.add_child(favorite)
		var remove := Button.new(); remove.text = "Remove history"; remove.custom_minimum_size = _metrics.min_size(120, 32); remove.pressed.connect(request_history_removal.bind(entry.key)); row.add_child(remove)
		_history_list.add_child(row)
