class_name ContinuumMainMenu
extends Control

signal join_requested(host: String, database: String)
signal server_management_requested
signal settings_changed(settings: ClientSettings)
signal exit_requested

var main: Control
var settings := ClientSettings.new()
var metrics := UiMetrics.new()
var _status: Label
var _last_button: Button
var _settings_panel: VBoxContainer
var _font_size: SpinBox
var _diagnostics_toggle: CheckButton
var _graph_toggle: CheckButton
var _error: Label

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
	margin.add_theme_constant_override("margin_left", metrics.px(24))
	margin.add_theme_constant_override("margin_right", metrics.px(24))
	margin.add_theme_constant_override("margin_top", metrics.px(36))
	margin.add_theme_constant_override("margin_bottom", metrics.px(36))
	add_child(margin)
	var scroll := ScrollContainer.new()
	scroll.name = "MenuScroll"
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	scroll.follow_focus = true
	margin.add_child(scroll)
	var column := VBoxContainer.new()
	column.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	column.add_theme_constant_override("separation", metrics.px(12))
	scroll.add_child(column)

	var title := _label("CONTINUUM")
	title.add_theme_font_size_override("font_size", metrics.font(24))
	title.add_theme_color_override("font_color", DeckTheme.ACCENT)
	column.add_child(title)
	var subtitle := _label("A quiet place to build a life.")
	column.add_child(subtitle)
	_status = _label("Offline")
	column.add_child(_status)

	_last_button = _button("Join last server", _join_last)
	column.add_child(_last_button)
	var servers_button := _button("Servers", _open_server_management)
	column.add_child(servers_button)
	var settings_button := _button("Settings", _toggle_settings)
	column.add_child(settings_button)
	var exit_button := _button("Exit", func() -> void: exit_requested.emit())
	column.add_child(exit_button)

	_error = _label("")
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
	_diagnostics_toggle.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_diagnostics_toggle.custom_minimum_size = Vector2(1, metrics.px(34))
	_diagnostics_toggle.button_pressed = settings.diagnostics_enabled
	_diagnostics_toggle.toggled.connect(_diagnostics_changed)
	_settings_panel.add_child(_diagnostics_toggle)
	_graph_toggle = CheckButton.new()
	_graph_toggle.text = "Show frame/RTT graph"
	_graph_toggle.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_graph_toggle.custom_minimum_size = Vector2(1, metrics.px(34))
	_graph_toggle.button_pressed = settings.diagnostics_graph_enabled
	_graph_toggle.disabled = not settings.diagnostics_enabled
	_graph_toggle.toggled.connect(_graph_changed)
	_settings_panel.add_child(_graph_toggle)

func set_status(message: String, warning := false) -> void:
	_status.text = message
	_status.add_theme_color_override("font_color", Color("ffb74d") if warning else DeckTheme.MUTED)

func set_busy(busy: bool) -> void:
	_last_button.disabled = busy or not _has_last_server()

func show_menu() -> void:
	visible = true
	set_busy(false)
	_refresh_last_button()

func _join_last() -> void:
	if _last_button.disabled or not _has_last_server():
		return
	var host := settings.server_host.strip_edges()
	var database := settings.database.strip_edges()
	var validation := ContinuumServerManagement.validate_endpoint(host, database)
	if not validation.is_empty():
		_error.text = validation
		return
	_error.text = ""
	set_busy(true)
	set_status("Connecting to %s / %s ..." % [host, database])
	join_requested.emit(host, database)

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
	result.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	result.custom_minimum_size = Vector2(1, metrics.px(34))
	result.pressed.connect(action)
	return result

func _label(text: String) -> Label:
	var result := Label.new()
	result.text = text
	result.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	result.custom_minimum_size = Vector2(1, 0)
	result.add_theme_color_override("font_color", DeckTheme.MUTED)
	return result
