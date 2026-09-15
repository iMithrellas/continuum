## Server UI. Main owns navigation, credentials, and native process management.
class_name ContinuumServerManagement
extends Control

signal join_requested(target: Dictionary)
signal back_requested
signal favorite_requested(key: String, favorite: bool)
signal history_remove_requested(key: String)
signal local_start_requested
signal local_cancel_requested
signal local_stop_requested
signal local_force_stop_requested
signal local_refresh_requested
signal native_autostart_requested(enabled: bool)
signal world_selected(world_id: String, world_slug: String)

const HOST_PLACEHOLDER := "http://127.0.0.1:3001"
const DATABASE_PATTERN := "^[a-z0-9]+(-[a-z0-9]+)*$"

var history: ContinuumConnectionHistory
var probes: ContinuumServerProbes
var selected_key := ""
var local_management_state: Dictionary = {}
var _world_catalog: Array[Dictionary] = []
var _search := ""
var _host := ""
var _database := ""
var _metrics := UiMetrics.new()
var _content: PanelContainer
var _sections: BoxContainer
var _history_list: VBoxContainer
var _probe_labels: Dictionary = {}
var _history_join_buttons: Array[Button] = []
var _join_host: LineEdit
var _join_database: LineEdit
var _join_button: Button
var _back_button: Button
var _local_start: Button
var _local_cancel: Button
var _local_stop: Button
var _local_force: Button
var _native_autostart: CheckButton
var _native_note: Label
var _status: Label
var _status_message := ""
var _status_warning := false
var _busy := false
var _native_busy := false
var _autostart_enabled := false

func _ready() -> void:
	if history == null:
		history = ContinuumConnectionHistory.new()
		history.load_from()
	if probes == null:
		probes = ContinuumServerProbes.new()
	set_probe_service(probes)
	mouse_filter = Control.MOUSE_FILTER_STOP
	var background := ColorRect.new()
	background.name = "ServerBackground"
	background.color = Color("17191b")
	background.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(background)
	background.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	resized.connect(_layout_content)
	_build_ui()

func set_history_store(store: ContinuumConnectionHistory) -> void:
	history = store

func set_probe_service(service: ContinuumServerProbes) -> void:
	probes = service
	if is_inside_tree() and probes.get_parent() == null:
		add_child(probes)
	if not probes.probe_finished.is_connected(_on_probe_finished):
		probes.probe_finished.connect(_on_probe_finished)
	if not probes.probe_started.is_connected(_update_probe_label):
		probes.probe_started.connect(_update_probe_label)

func set_connection_defaults(host: String, database: String) -> void:
	_host = host
	_database = database

func apply_metrics(value: UiMetrics) -> void:
	_metrics = value
	if is_inside_tree():
		_host = _join_host.text
		_database = _join_database.text
		_build_ui()

func set_world_catalog(worlds: Array[Dictionary]) -> void:
	_world_catalog = worlds.duplicate(true)

func set_local_management_state(state: Dictionary) -> void:
	local_management_state = state.duplicate(true)
	if is_instance_valid(_local_start):
		_update_local_controls()

func set_native_autostart(enabled: bool) -> void:
	_autostart_enabled = enabled
	if is_instance_valid(_native_autostart):
		_native_autostart.set_pressed_no_signal(enabled)

func set_status(message: String, warning := false) -> void:
	_status_message = message
	_status_warning = warning
	if is_instance_valid(_status):
		_status.text = message
		_status.visible = not message.is_empty()
		_status.add_theme_color_override("font_color", Color("ffb74d") if warning else DeckTheme.MUTED)
		if _status.visible:
			_reveal_status.call_deferred()

func _reveal_status() -> void:
	if is_instance_valid(_status) and _status.is_inside_tree():
		var scroll := _status.find_parent("ServerContentScroll") as ScrollContainer
		if scroll:
			scroll.ensure_control_visible(_status)

func set_busy(busy: bool) -> void:
	_busy = busy
	if not is_instance_valid(_join_button):
		return
	_join_button.disabled = busy or _native_busy
	_join_host.editable = not busy and not _native_busy
	_join_database.editable = not busy and not _native_busy
	_back_button.disabled = busy
	for button in _history_join_buttons:
		button.disabled = busy or _native_busy
	_update_local_controls()

func set_native_busy(busy: bool) -> void:
	_native_busy = busy
	set_busy(_busy)

func _update_local_controls() -> void:
	_local_start.disabled = _busy or _native_busy or not bool(local_management_state.get("can_start", false))
	_local_stop.disabled = not bool(local_management_state.get("can_stop", false))
	_local_force.disabled = not bool(local_management_state.get("can_force_stop", false))
	_local_cancel.visible = _native_busy
	_native_autostart.disabled = _busy or _native_busy
	_native_note.text = str(local_management_state.get("message", "Checking native server..."))

func select_world(world_id: String, world_slug: String) -> void:
	world_selected.emit(world_id, world_slug)

func set_search(value: String) -> void:
	_search = value
	_refresh_history_list()

func visible_entries() -> Array[Dictionary]:
	return history.entries(_search) if history else []

func request_join(key: String) -> bool:
	if _busy or _native_busy:
		return false
	for entry in visible_entries():
		if entry.key == key:
			selected_key = key
			set_busy(true)
			set_status("Connecting to %s / %s ..." % [entry.endpoint, entry.database])
			join_requested.emit(entry.duplicate(true))
			return true
	return false

func _join_server() -> void:
	if _busy or _native_busy:
		return
	var host := _join_host.text.strip_edges()
	var database := _join_database.text.strip_edges()
	var validation := validate_endpoint(host, database)
	if not validation.is_empty():
		set_status(validation, true)
		return
	set_busy(true)
	set_status("Connecting to %s / %s ..." % [host, database])
	join_requested.emit({"endpoint": host, "database": database})

func set_browser_visible(value: bool) -> void:
	if probes:
		probes.set_visible(value)
	if value:
		_refresh_history_list()

func request_favorite(key: String, favorite: bool) -> bool:
	var accepted := history != null and history.set_favorite(key, favorite) == OK
	if accepted:
		favorite_requested.emit(key, favorite)
		_refresh_history_list()
	else:
		set_status("Could not save the favorite change.", true)
	return accepted

func request_history_removal(key: String) -> bool:
	var accepted := history != null and history.remove_history(key) == OK
	if accepted:
		history_remove_requested.emit(key)
		_refresh_history_list()
	else:
		set_status("Could not remove the history entry.", true)
	return accepted

func request_local_start() -> void:
	if not _busy and not _native_busy and bool(local_management_state.get("can_start", false)):
		set_native_busy(true)
		local_start_requested.emit()

func request_local_stop() -> void:
	if bool(local_management_state.get("can_stop", false)):
		local_stop_requested.emit()

func request_local_force_stop() -> void:
	if bool(local_management_state.get("can_force_stop", false)):
		local_force_stop_requested.emit()

func _process(_delta: float) -> void:
	if probes and probes.visible:
		probes.refresh(visible_entries())
		probes.process()

func _on_probe_finished(key: String, _result: Dictionary) -> void:
	# Update the sample in place so health checks cannot destroy focused buttons or rows.
	_update_probe_label(key)

func _build_ui() -> void:
	if is_instance_valid(_content):
		remove_child(_content)
		_content.queue_free()
	theme = DeckTheme.create(_metrics)
	_content = PanelContainer.new()
	_content.name = "BrowserContent"
	_content.add_theme_stylebox_override("panel", DeckTheme.box(DeckTheme.INK, DeckTheme.LINE, _metrics.px(12)))
	_content.minimum_size_changed.connect(_layout_content, CONNECT_DEFERRED)
	add_child(_content)
	var column := VBoxContainer.new()
	_content.add_child(column)
	var header := HBoxContainer.new()
	column.add_child(header)
	var heading := _label("Servers")
	heading.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	heading.add_theme_font_size_override("font_size", _metrics.font(20))
	heading.add_theme_color_override("font_color", DeckTheme.ACCENT)
	header.add_child(heading)
	_back_button = _button("Return", func() -> void: back_requested.emit())
	header.add_child(_back_button)

	# A single scrolling body also keeps every action reachable on short/narrow windows.
	var scroll := ScrollContainer.new()
	scroll.name = "ServerContentScroll"
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.follow_focus = true
	column.add_child(scroll)
	var body := VBoxContainer.new()
	body.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(body)
	_status = _label("")
	body.add_child(_status)
	set_status(_status_message, _status_warning)
	_sections = BoxContainer.new()
	_sections.add_theme_constant_override("separation", _metrics.px(16))
	body.add_child(_sections)
	var direct := _section(_sections, "Join a server")
	direct.add_child(_label("Host"))
	_join_host = LineEdit.new()
	_join_host.placeholder_text = HOST_PLACEHOLDER
	_join_host.text = _host
	_join_host.custom_minimum_size.y = _metrics.px(34)
	direct.add_child(_join_host)
	direct.add_child(_label("Database"))
	_join_database = LineEdit.new()
	_join_database.placeholder_text = "continuum"
	_join_database.text = _database
	_join_database.custom_minimum_size.y = _metrics.px(34)
	_join_database.text_submitted.connect(func(_text: String) -> void: _join_server())
	direct.add_child(_join_database)
	_join_button = _button("Join server", _join_server)
	direct.add_child(_join_button)

	var local := _section(_sections, "Local server")
	local.add_child(_label("Run a persistent server on this computer. Starting it also joins the colony."))
	var actions := HFlowContainer.new()
	local.add_child(actions)
	_local_start = _button("Start local server", request_local_start)
	actions.add_child(_local_start)
	_local_cancel = _button("Cancel startup", func() -> void: local_cancel_requested.emit())
	actions.add_child(_local_cancel)
	_local_stop = _button("Stop local", request_local_stop)
	actions.add_child(_local_stop)
	_local_force = _button("Force stop", request_local_force_stop)
	actions.add_child(_local_force)
	actions.add_child(_button("Refresh", func() -> void: local_refresh_requested.emit()))
	_native_autostart = CheckButton.new()
	_native_autostart.text = "Start at login"
	_native_autostart.tooltip_text = "Start the native server when you log into this computer."
	_native_autostart.button_pressed = _autostart_enabled
	_native_autostart.toggled.connect(func(enabled: bool) -> void: native_autostart_requested.emit(enabled))
	local.add_child(_native_autostart)
	_native_note = _label("")
	_native_note.add_theme_color_override("font_color", DeckTheme.MUTED)
	local.add_child(_native_note)

	body.add_child(_label("Saved connections"))
	var search := LineEdit.new()
	search.name = "SearchConnections"
	search.placeholder_text = "Search connections"
	search.text = _search
	search.custom_minimum_size.y = _metrics.px(34)
	search.text_changed.connect(set_search)
	body.add_child(search)
	_history_list = VBoxContainer.new()
	_history_list.name = "ConnectionHistory"
	body.add_child(_history_list)
	_refresh_history_list()
	set_busy(_busy)
	_layout_content()

func _layout_content() -> void:
	if not is_instance_valid(_content):
		return
	var margin := _metrics.px(12)
	var width := maxf(0.0, minf(size.x - margin * 2, _metrics.px(1000)))
	_sections.vertical = width < _metrics.px(720)
	_content.position = Vector2((size.x - width) / 2, margin)
	_content.size = Vector2(width, maxf(0.0, size.y - margin * 2))

func _section(parent: Node, title: String) -> VBoxContainer:
	var panel := PanelContainer.new()
	panel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	parent.add_child(panel)
	var column := VBoxContainer.new()
	panel.add_child(column)
	var heading := _label(title)
	heading.add_theme_color_override("font_color", DeckTheme.ACCENT)
	column.add_child(heading)
	return column

func _label(text: String) -> Label:
	var label := Label.new()
	label.text = text
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	label.custom_minimum_size = Vector2(1, _metrics.px(20))
	return label

func _button(text: String, action: Callable) -> Button:
	var button := Button.new()
	button.text = text
	button.custom_minimum_size.y = _metrics.px(34)
	button.pressed.connect(action)
	return button

func _refresh_history_list() -> void:
	if not is_instance_valid(_history_list):
		return
	for child in _history_list.get_children():
		_history_list.remove_child(child)
		child.queue_free()
	_probe_labels.clear()
	_history_join_buttons.clear()
	var entries := visible_entries()
	if entries.is_empty():
		_history_list.add_child(_label("No saved connections yet. Join a server to add it here." if _search.is_empty() else "No connections match your search."))
	for entry in entries:
		var title := str(entry.get("display_name", entry.database))
		var row := _section(_history_list, ("Favorite | " if entry.get("favorite", false) else "") + title)
		row.add_child(_label("%s / %s" % [entry.endpoint, entry.database]))
		var details := _label("World: %s | Last joined: %s" % [entry.world,
			Time.get_datetime_string_from_unix_time(int(entry.last_seen), true)])
		details.add_theme_color_override("font_color", DeckTheme.MUTED)
		row.add_child(details)
		var sample := _label("")
		sample.add_theme_color_override("font_color", DeckTheme.MUTED)
		row.add_child(sample)
		_probe_labels[entry.key] = sample
		_update_probe_label(entry.key)
		var controls := HFlowContainer.new()
		row.add_child(controls)
		var join := _button("Join", request_join.bind(entry.key))
		join.disabled = _busy or _native_busy
		controls.add_child(join)
		_history_join_buttons.append(join)
		controls.add_child(_button("Unfavorite" if entry.get("favorite", false) else "Favorite", request_favorite.bind(entry.key, not entry.get("favorite", false))))
		controls.add_child(_button("Remove history", request_history_removal.bind(entry.key)))

func _update_probe_label(key: String) -> void:
	if not _probe_labels.has(key):
		return
	var sample := probes.state(key) if probes else {"status": "unknown"}
	var status := str(sample.get("status", "unknown"))
	if status == "online" and not bool(sample.get("health_ok", true)) and int(sample.get("http_status", -1)) >= 0:
		status = "HTTP health failed %d" % int(sample.http_status)
	var rtt := "%.0f ms HTTP" % float(sample.rtt_ms) if float(sample.get("rtt_ms", -1)) >= 0 else "HTTP RTT unavailable"
	var freshness := "stale" if sample.get("stale", false) else "current"
	var label: Label = _probe_labels[key]
	label.text = "%s (%s) | %s" % [status, freshness, rtt]
	label.tooltip_text = "HTTP health is not database joinability.\nJoinable: %s | Auth: %s\nLast sample: %s" % [
		sample.get("joinable", "unknown"), sample.get("auth", "unknown"), sample.get("last_sample", "never")]

static func validate_endpoint(host: String, database: String) -> String:
	if not (host.begins_with("http://") or host.begins_with("https://")):
		return "Host must begin with http:// or https://."
	var authority := host.substr(7) if host.begins_with("http://") else host.substr(8)
	if authority.is_empty() or authority.contains(" ") or authority.contains("/") or authority.contains("?") or authority.contains("#"):
		return "Host must contain only a hostname and optional port."
	if authority.contains("@"):
		return "Host credentials are not supported."
	if not _valid_authority(authority):
		return "Host must be a valid hostname, IPv4 address, or bracketed IPv6 address."
	var database_pattern := RegEx.new()
	database_pattern.compile(DATABASE_PATTERN)
	if database.is_empty() or database.length() > 128 or database_pattern.search(database) == null:
		return "Database must use lowercase letters and numbers separated by dashes."
	return ""

static func _valid_authority(authority: String) -> bool:
	if authority.begins_with("["):
		var close := authority.find("]")
		if close < 0 or close == 1:
			return false
		var address := authority.substr(1, close - 1)
		var ipv6 := RegEx.new()
		ipv6.compile("^[0-9A-Fa-f:.]+$")
		if not ipv6.search(address) or not address.contains(":"):
			return false
		var suffix := authority.substr(close + 1)
		return suffix.is_empty() or (suffix.begins_with(":") and _valid_port(suffix.substr(1)))
	if authority.count(":") > 1:
		return false
	var host_part := authority
	if authority.contains(":"):
		var colon := authority.find(":")
		host_part = authority.substr(0, colon)
		if not _valid_port(authority.substr(colon + 1)):
			return false
	if host_part.is_empty() or host_part.begins_with(".") or host_part.ends_with("."):
		return false
	for label: String in host_part.split("."):
		if label.is_empty() or label.begins_with("-") or label.ends_with("-"):
			return false
	var hostname := RegEx.new()
	hostname.compile("^[A-Za-z0-9](?:[A-Za-z0-9.-]*[A-Za-z0-9])?$")
	return hostname.search(host_part) != null

static func _valid_port(value: String) -> bool:
	if value.is_empty() or not value.is_valid_int() or value != str(int(value)):
		return false
	return int(value) >= 1 and int(value) <= 65535
