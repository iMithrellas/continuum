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
var _history_list: ItemList

func _ready() -> void:
	history = ContinuumConnectionHistory.new(); history.load_from()
	probes = ContinuumServerProbes.new()
	_build_ui()

func set_history_store(store: ContinuumConnectionHistory) -> void:
	history = store

func set_probe_service(service: ContinuumServerProbes) -> void:
	probes = service

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
	var accepted := history != null and history.set_favorite(key, favorite)
	if accepted: favorite_requested.emit(key, favorite)
	return accepted

func request_history_removal(key: String) -> bool:
	var accepted := history != null and history.remove_history(key)
	if accepted: history_remove_requested.emit(key)
	return accepted

func request_local_start() -> void: local_start_requested.emit()
func request_local_stop() -> void: local_stop_requested.emit()
func request_local_force_stop() -> void: local_force_stop_requested.emit()

func _process(_delta: float) -> void:
	if probes and probes.visible:
		probes.refresh(visible_entries())
		probes.process()

func _build_ui() -> void:
	# The scene is intentionally self-contained; navigation and local ownership stay outside it.
	theme = DeckTheme.create(UiMetrics.new())
	var margin := MarginContainer.new(); margin.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	margin.add_theme_constant_override("margin_left", 24); margin.add_theme_constant_override("margin_right", 24)
	margin.add_theme_constant_override("margin_top", 24); margin.add_theme_constant_override("margin_bottom", 24)
	add_child(margin)
	var column := VBoxContainer.new(); margin.add_child(column)
	var heading := Label.new(); heading.text = "SERVER MANAGEMENT"; heading.add_theme_font_size_override("font_size", UiMetrics.new().font(20)); column.add_child(heading)
	var search := LineEdit.new(); search.placeholder_text = "Search connections"; search.custom_minimum_size = UiMetrics.new().min_size(240, 32); search.text_changed.connect(set_search); column.add_child(search)
	var list := ItemList.new(); list.name = "ConnectionHistory"; list.size_flags_vertical = Control.SIZE_EXPAND_FILL; list.item_selected.connect(func(index: int) -> void:
		var rows := visible_entries()
		if index < rows.size(): selected_key = rows[index].key); column.add_child(list)
	_history_list = list
	_refresh_history_list()
	var back := Button.new(); back.text = "Return"; back.pressed.connect(func() -> void: back_requested.emit()); column.add_child(back)

func _refresh_history_list() -> void:
	if not is_instance_valid(_history_list): return
	_history_list.clear()
	for entry in visible_entries():
		var prefix := "[favorite] " if entry.get("favorite", false) else ""
		_history_list.add_item(prefix + str(entry.get("display_name", entry.get("endpoint", ""))))
