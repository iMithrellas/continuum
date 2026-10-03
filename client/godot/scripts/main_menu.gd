class_name ContinuumMainMenu
extends Control

signal join_requested(host: String, database: String)
signal resume_requested
signal disconnect_requested
signal server_management_requested
signal settings_changed(settings: ClientSettings)
signal exit_requested

var main: Control
var settings := ClientSettings.new()
var metrics := UiMetrics.new()
var _status: Label
var _last_button: Button
var _settings_panel: VBoxContainer
var _ui_scale: OptionButton
var _reduced_motion: CheckButton
var _diagnostics_toggle: CheckButton
var _graph_toggle: CheckButton
var _error: Label
var _status_glyph: TextureRect
var _error_glyph: TextureRect
var resume_available: Callable
var _busy := false
var _disconnect_button: Button

func setup(owner: Control, loaded_settings: ClientSettings, ui_metrics: UiMetrics) -> void:
	main = owner
	settings = loaded_settings
	metrics = UiMetrics.new()
	theme = DeckTheme.create(metrics)
	_build()
	_refresh_last_button()

func _build() -> void:
	mouse_filter = Control.MOUSE_FILTER_STOP
	var background := ColorRect.new()
	background.color = ThemeTokens.color("bg-000")
	background.mouse_filter = Control.MOUSE_FILTER_STOP
	background.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(background)
	var margin := MarginContainer.new()
	margin.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	for edge: String in ["left", "right", "top", "bottom"]:
		margin.add_theme_constant_override("margin_" + edge, ThemeTokens.number("space-8"))
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

	var title := _label("Continuum")
	ThemeTokens.apply_label(title, "display")
	column.add_child(title)
	var subtitle := _label("A quiet place to build a life.")
	column.add_child(subtitle)
	_status = _label("Offline")
	var status_row := HBoxContainer.new()
	column.add_child(status_row)
	_status_glyph = _glyph(status_row, "notice")
	_status.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	status_row.add_child(_status)

	_last_button = _button("Join last server", _join_last)
	_last_button.theme_type_variation = "ButtonPrimary"
	column.add_child(_last_button)
	_disconnect_button = _button("Disconnect", func() -> void: disconnect_requested.emit())
	column.add_child(_disconnect_button)
	var servers_button := _button("Servers", _open_server_management)
	column.add_child(servers_button)
	var settings_button := _button("Settings", _toggle_settings)
	column.add_child(settings_button)
	var exit_button := _button("Exit", func() -> void: exit_requested.emit())
	exit_button.theme_type_variation = "ButtonQuiet"
	column.add_child(exit_button)

	_error = _label("")
	_error.add_theme_color_override("font_color", ThemeTokens.color("warn"))
	var error_row := HBoxContainer.new()
	column.add_child(error_row)
	_error_glyph = _glyph(error_row, "warn")
	_error_glyph.visible = false
	_error.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	error_row.add_child(_error)
	_settings_panel = VBoxContainer.new()
	_settings_panel.visible = false
	_settings_panel.add_theme_constant_override("separation", ThemeTokens.number("space-2"))
	column.add_child(_settings_panel)
	var section := _label("Display")
	ThemeTokens.apply_label(section, "section")
	_settings_panel.add_child(section)
	_settings_panel.add_child(_label("UI scale"))
	_ui_scale = OptionButton.new()
	_ui_scale.name = "UiScale"
	for value: int in ClientSettings.UI_SCALES:
		_ui_scale.add_item("%d%%" % value, value)
	_ui_scale.select(ClientSettings.UI_SCALES.find(ClientSettings.normalize_ui_scale(settings.ui_scale_percent)))
	_ui_scale.item_selected.connect(func(index: int) -> void:
		settings.ui_scale_percent = _ui_scale.get_item_id(index)
		settings.font_size = ClientSettings.DEFAULT_FONT_SIZE
		_apply_settings())
	_settings_panel.add_child(_ui_scale)
	_reduced_motion = CheckButton.new()
	_reduced_motion.name = "ReducedMotion"
	_reduced_motion.text = "Reduce motion"
	_reduced_motion.tooltip_text = "Keep critical alert borders steady rather than pulsing."
	_reduced_motion.button_pressed = settings.reduced_motion
	_reduced_motion.toggled.connect(func(value: bool) -> void:
		settings.reduced_motion = value
		_apply_settings())
	_settings_panel.add_child(_reduced_motion)
	_diagnostics_toggle = CheckButton.new()
	_diagnostics_toggle.text = "Show diagnostics"
	_diagnostics_toggle.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_diagnostics_toggle.custom_minimum_size = Vector2(1, ThemeTokens.number("control-md"))
	_diagnostics_toggle.button_pressed = settings.diagnostics_enabled
	_diagnostics_toggle.toggled.connect(_diagnostics_changed)
	_settings_panel.add_child(_diagnostics_toggle)
	_graph_toggle = CheckButton.new()
	_graph_toggle.text = "Show frame/RTT graph"
	_graph_toggle.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_graph_toggle.custom_minimum_size = Vector2(1, ThemeTokens.number("control-md"))
	_graph_toggle.button_pressed = settings.diagnostics_graph_enabled
	_graph_toggle.disabled = not settings.diagnostics_enabled
	_graph_toggle.toggled.connect(_graph_changed)
	_settings_panel.add_child(_graph_toggle)

func set_status(message: String, warning := false) -> void:
	_status.text = "Warning · " + message if warning else message
	_status_glyph.texture = ThemeTokens.glyph("warn" if warning else "notice")
	_status.add_theme_color_override("font_color", ThemeTokens.color("warn") if warning else ThemeTokens.color("ink-muted"))

func set_busy(busy: bool) -> void:
	_busy = busy
	_refresh_last_button()

func _process(_delta: float) -> void:
	if visible:
		_refresh_last_button()

func show_menu() -> void:
	visible = true
	set_busy(false)
	_refresh_last_button()

func _join_last() -> void:
	var offered_resume := _last_button.text == "Resume colony"
	_refresh_last_button()
	if offered_resume or _can_resume():
		if not _last_button.disabled and _can_resume():
			resume_requested.emit()
		return
	if _last_button.disabled or not _has_last_server():
		return
	var host := settings.server_host.strip_edges()
	var database := settings.database.strip_edges()
	var validation := ContinuumServerManagement.validate_endpoint(host, database)
	if not validation.is_empty():
		_error.text = validation
		_error_glyph.visible = true
		return
	_error.text = ""
	_error_glyph.visible = false
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
	metrics = UiMetrics.new()
	theme = DeckTheme.create(metrics)

func _refresh_last_button() -> void:
	var resumable := _can_resume()
	_disconnect_button.visible = resumable
	_last_button.text = "Resume colony" if resumable else "Join last server"
	_last_button.disabled = _busy or not (resumable or _has_last_server())
	_last_button.tooltip_text = "No successfully joined server yet." if _last_button.disabled else settings.server_host + " / " + settings.database

func _can_resume() -> bool:
	return resume_available.is_valid() and bool(resume_available.call())

func _has_last_server() -> bool:
	return not settings.server_host.is_empty() and not settings.database.is_empty()

func _button(text: String, action: Callable) -> Button:
	var result := Button.new()
	result.text = text
	result.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	result.custom_minimum_size = Vector2(1, ThemeTokens.number("control-md"))
	result.pressed.connect(action)
	return result

func _label(text: String) -> Label:
	var result := Label.new()
	result.text = text
	ThemeTokens.apply_label(result, "body")
	result.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	result.custom_minimum_size = Vector2(1, 0)
	result.add_theme_color_override("font_color", DeckTheme.MUTED)
	return result

func _glyph(parent: Node, name: String) -> TextureRect:
	var icon := TextureRect.new()
	icon.texture = ThemeTokens.glyph(name)
	icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	icon.custom_minimum_size = Vector2(16, 16)
	parent.add_child(icon)
	return icon
