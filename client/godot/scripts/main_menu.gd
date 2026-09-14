class_name ContinuumMainMenu
extends Control

signal join_requested(host: String, database: String)
signal local_server_requested
signal server_management_requested
signal settings_changed(settings: ClientSettings)
signal exit_requested

const HOST_PLACEHOLDER := "http://127.0.0.1:3000"
const DATABASE_PATTERN := "^[a-z0-9]+(-[a-z0-9]+)*$"

var main: Control
var settings := ClientSettings.new()
var metrics := UiMetrics.new()
var _runner: RefCounted
var runner_factory: Callable
var _status: Label
var _join_host: LineEdit
var _join_database: LineEdit
var _join_button: Button
var _last_button: Button
var _local_button: Button
var _cancel_local_button: Button
var _settings_panel: VBoxContainer
var _font_size: SpinBox
var _diagnostics_toggle: CheckButton
var _graph_toggle: CheckButton
var _error: Label
var _runner_epoch := 0

func setup(owner: Control, loaded_settings: ClientSettings, ui_metrics: UiMetrics) -> void:
	main = owner
	settings = loaded_settings
	metrics = ui_metrics
	theme = DeckTheme.create(metrics)
	_build()
	_refresh_last_button()

func _build() -> void:
	mouse_filter = Control.MOUSE_FILTER_STOP
	var background := ColorRect.new()
	background.color = Color("17191b")
	background.mouse_filter = Control.MOUSE_FILTER_STOP
	background.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(background)
	var margin := MarginContainer.new()
	margin.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	margin.add_theme_constant_override("margin_left", metrics.px(48))
	margin.add_theme_constant_override("margin_right", metrics.px(48))
	margin.add_theme_constant_override("margin_top", metrics.px(36))
	margin.add_theme_constant_override("margin_bottom", metrics.px(36))
	add_child(margin)
	var column := VBoxContainer.new()
	column.custom_minimum_size.x = metrics.px(420)
	column.add_theme_constant_override("separation", metrics.px(12))
	margin.add_child(column)

	var title := Label.new()
	title.text = "CONTINUUM"
	title.add_theme_font_size_override("font_size", metrics.font(24))
	title.add_theme_color_override("font_color", DeckTheme.ACCENT)
	column.add_child(title)
	var subtitle := Label.new()
	subtitle.text = "A quiet place to build a life."
	subtitle.add_theme_color_override("font_color", DeckTheme.MUTED)
	column.add_child(subtitle)
	_status = Label.new()
	_status.text = "Offline"
	_status.add_theme_color_override("font_color", DeckTheme.MUTED)
	column.add_child(_status)

	_last_button = _button("Join last server", _join_last)
	column.add_child(_last_button)
	column.add_child(_label("JOIN SERVER"))
	_join_host = _line("Host", settings.server_host)
	column.add_child(_join_host)
	_join_database = _line("Database", settings.database)
	column.add_child(_join_database)
	_join_button = _button("Join server", _join_server)
	column.add_child(_join_button)

	_local_button = _button("Start local server", func() -> void:
		local_server_requested.emit()
		_start_local_server())
	column.add_child(_local_button)
	_cancel_local_button = _button("Cancel local setup", _cancel_local_server)
	_cancel_local_button.visible = false
	column.add_child(_cancel_local_button)

	var settings_button := _button("Settings", _toggle_settings)
	column.add_child(settings_button)
	var servers_button := _button("Servers", _open_server_management)
	column.add_child(servers_button)
	var exit_button := _button("Exit", func() -> void: exit_requested.emit())
	column.add_child(exit_button)

	_error = Label.new()
	_error.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_error.add_theme_color_override("font_color", Color("ffb74d"))
	column.add_child(_error)
	_settings_panel = VBoxContainer.new()
	_settings_panel.visible = false
	_settings_panel.add_theme_constant_override("separation", metrics.px(6))
	column.add_child(_settings_panel)
	_settings_panel.add_child(_label("DISPLAY"))
	_font_size = SpinBox.new()
	_font_size.name = "BaseFontSize"
	_font_size.min_value = ClientSettings.MIN_FONT_SIZE
	_font_size.max_value = ClientSettings.MAX_FONT_SIZE
	_font_size.step = 1
	_font_size.value = settings.font_size
	_font_size.value_changed.connect(_font_size_changed)
	_settings_panel.add_child(_font_size)
	_diagnostics_toggle = CheckButton.new()
	_diagnostics_toggle.text = "Show diagnostics"
	_diagnostics_toggle.button_pressed = settings.diagnostics_enabled
	_diagnostics_toggle.toggled.connect(_diagnostics_changed)
	_settings_panel.add_child(_diagnostics_toggle)
	_graph_toggle = CheckButton.new()
	_graph_toggle.text = "Show frame/RTT graph"
	_graph_toggle.button_pressed = settings.diagnostics_graph_enabled
	_graph_toggle.disabled = not settings.diagnostics_enabled
	_graph_toggle.toggled.connect(_graph_changed)
	_settings_panel.add_child(_graph_toggle)

func set_status(message: String, warning := false) -> void:
	_status.text = message
	_status.add_theme_color_override("font_color", Color("ffb74d") if warning else DeckTheme.MUTED)

func set_busy(busy: bool) -> void:
	_join_button.disabled = busy
	_last_button.disabled = busy or not _has_last_server()
	_local_button.disabled = busy
	_cancel_local_button.visible = busy and _runner != null and _runner.is_running()

func _process(_delta: float) -> void:
	# The runner reports cancellation as progress and intentionally has no extra
	# completion signal. Poll its authoritative lifecycle so the menu cannot stay
	# disabled after the child process has cleaned up.
	if _runner != null and _cancel_local_button.visible and not _runner.is_running():
		set_busy(false)

func show_menu() -> void:
	visible = true
	set_busy(false)
	_refresh_last_button()

func _join_last() -> void:
	if not _has_last_server():
		return
	_join_host.text = settings.server_host
	_join_database.text = settings.database
	_join_server()

func _join_server() -> void:
	var host := _join_host.text.strip_edges()
	var database := _join_database.text.strip_edges()
	var validation := validate_endpoint(host, database)
	if not validation.is_empty():
		_error.text = validation
		return
	_error.text = ""
	set_busy(true)
	set_status("Connecting to %s / %s ..." % [host, database])
	join_requested.emit(host, database)

func _start_local_server() -> void:
	if _runner != null and _runner.is_running():
		return
	_runner = runner_factory.call() if runner_factory.is_valid() else ContinuumLocalServerRunner.new()
	_runner_epoch += 1
	var epoch := _runner_epoch
	_runner.progress.connect(_on_runner_progress.bind(epoch))
	_runner.ready.connect(_on_local_ready.bind(epoch))
	_runner.failed.connect(_on_local_failed.bind(epoch))
	set_busy(true)
	if not _runner.start():
		set_busy(false)
	else:
		# start() publishes the running state synchronously; expose cancellation now.
		set_busy(true)

func _cancel_local_server() -> void:
	if _runner != null:
		_runner_epoch += 1
		_runner.cancel()
		set_status("Cancelling local server setup...", true)
		if not _runner.is_running():
			set_busy(false)

func _on_runner_progress(message: String, epoch: int) -> void:
	if epoch == _runner_epoch:
		set_status(message)

func _on_local_ready(host: String, database: String, epoch: int) -> void:
	if epoch != _runner_epoch:
		return
	_join_host.text = host
	_join_database.text = database
	set_status("Local server ready. Joining...")
	join_requested.emit(host, database)

func _on_local_failed(message: String, epoch: int) -> void:
	if epoch != _runner_epoch:
		return
	set_busy(false)
	set_status(message, true)

func join_failed(message: String) -> void:
	set_busy(false)
	set_status(message, true)

func _toggle_settings() -> void:
	_settings_panel.visible = not _settings_panel.visible

func _open_server_management() -> void:
	server_management_requested.emit()

func _font_size_changed(value: float) -> void:
	settings.font_size = clampi(roundi(value), ClientSettings.MIN_FONT_SIZE, ClientSettings.MAX_FONT_SIZE)
	if main != null and main.has_method("apply_settings"):
		main.apply_settings(settings)
	settings_changed.emit(settings)

func _diagnostics_changed(value: bool) -> void:
	settings.diagnostics_enabled = value
	_graph_toggle.disabled = not value
	if not value:
		settings.diagnostics_graph_enabled = false
		_graph_toggle.button_pressed = false
	_apply_settings()

func _graph_changed(value: bool) -> void:
	settings.diagnostics_graph_enabled = value if settings.diagnostics_enabled else false
	_apply_settings()

func _apply_settings() -> void:
	if main != null and main.has_method("apply_settings"):
		main.apply_settings(settings)
	settings_changed.emit(settings)

func apply_metrics(next_metrics: UiMetrics) -> void:
	metrics = next_metrics
	theme = DeckTheme.create(metrics)

func _refresh_last_button() -> void:
	_last_button.disabled = not _has_last_server()
	_last_button.tooltip_text = "No successfully joined server yet." if _last_button.disabled else settings.server_host + " / " + settings.database

func _has_last_server() -> bool:
	return not settings.server_host.is_empty() and not settings.database.is_empty()

func _button(text: String, action: Callable) -> Button:
	var result := Button.new()
	result.text = text
	result.custom_minimum_size.y = metrics.px(34)
	result.pressed.connect(action)
	return result

func _line(placeholder: String, value: String) -> LineEdit:
	var result := LineEdit.new()
	result.placeholder_text = placeholder
	result.text = value
	result.custom_minimum_size.y = metrics.px(32)
	return result

func _label(text: String) -> Label:
	var result := Label.new()
	result.text = text
	result.add_theme_color_override("font_color", DeckTheme.MUTED)
	return result

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
		return suffix.is_empty() or _valid_port(suffix.trim_prefix(":"))
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

func _exit_tree() -> void:
	if _runner != null:
		_runner.dispose()
