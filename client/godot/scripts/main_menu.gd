class_name ContinuumMainMenu
extends Control

signal join_requested(host: String, database: String)
signal resume_requested
signal disconnect_requested
signal server_management_requested
signal settings_changed(settings: ClientSettings)
signal exit_requested

const MODAL_WIDTH := 760.0
const SIDEBAR_WIDTH := 240.0
const SUBTLE := Color("8b929a")
const DIVIDER := Color("262a2f")
const MEDIUM_FONT = preload("res://ui/theme/fonts/IBMPlexSans-Medium.woff2")
const PRIMARY_UI_SCALES := [100, 125, 150, 175]

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
var _modal: PanelContainer
var _columns: BoxContainer
var _sidebar: PanelContainer
var _sidebar_style: StyleBoxFlat
var _content: MarginContainer
var _settings_button: Button
var _error_row: HBoxContainer
var _live_hint: Label
var _resume_hint: Label
var _close_button: TextureButton
var _scale_row: BoxContainer
var _scale_controls: BoxContainer
var _scale_segments: GridContainer
var _scale_buttons: Dictionary = {}
var _scale_more: MenuButton
var _scale_settings_value := -1

# Legacy metrics stay in the public API, but viewport scaling owns all dimensions.
# gdlint: disable=unused-argument
@warning_ignore("unused_parameter")
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
	background.name = "MenuScrim"
	background.color = Color(10.0 / 255.0, 12.0 / 255.0, 14.0 / 255.0, 0.5)
	background.mouse_filter = Control.MOUSE_FILTER_STOP
	background.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	background.gui_input.connect(_scrim_input)
	add_child(background)
	_modal = PanelContainer.new()
	_modal.name = "SystemMenu"
	var surface := _box(ThemeTokens.color("bg-100"), ThemeTokens.color("line-100"), 6)
	surface.set_content_margin_all(1)
	surface.shadow_color = Color(0, 0, 0, 0.8)
	surface.shadow_size = 48
	surface.shadow_offset = Vector2(0, 24)
	_modal.add_theme_stylebox_override("panel", surface)
	add_child(_modal)
	var scroll := ScrollContainer.new()
	scroll.name = "MenuScroll"
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	scroll.follow_focus = true
	_style_scrollbar(scroll.get_v_scroll_bar())
	_modal.add_child(scroll)
	_columns = BoxContainer.new()
	_columns.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_columns.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_columns.add_theme_constant_override("separation", 0)
	scroll.add_child(_columns)
	_build_sidebar()
	_build_settings()
	resized.connect(_layout_modal)
	_columns.minimum_size_changed.connect(_layout_modal.call_deferred)
	_layout_modal()


func _build_sidebar() -> void:
	_sidebar = PanelContainer.new()
	_sidebar.name = "MenuSidebar"
	_sidebar_style = _box(Color("16181b"), DIVIDER, 0)
	_sidebar_style.set_border_width_all(0)
	_sidebar_style.content_margin_left = 16
	_sidebar_style.content_margin_right = 16
	_sidebar_style.content_margin_top = 22
	_sidebar_style.content_margin_bottom = 14
	_sidebar.add_theme_stylebox_override("panel", _sidebar_style)
	_columns.add_child(_sidebar)
	var column := VBoxContainer.new()
	column.add_theme_constant_override("separation", 0)
	_sidebar.add_child(column)

	var title := _label("Continuum")
	title.add_theme_font_override("font", ThemeTokens.font("body-strong"))
	title.add_theme_font_size_override("font_size", 22)
	title.add_theme_color_override("font_color", ThemeTokens.color("ink"))
	title.custom_minimum_size.y = 27
	column.add_child(title)
	_space(column, 4)
	var subtitle := _label("A quiet place to build a life.")
	column.add_child(subtitle)
	_space(column, 22)
	_last_button = _button("Join last server", _join_last)
	_last_button.theme_type_variation = "ButtonPrimary"
	_last_button.custom_minimum_size.y = 36
	_style_primary(_last_button)
	column.add_child(_last_button)
	_space(column, 7)
	_status = _label("Offline")
	_status.add_theme_font_size_override("font_size", 12)
	_status.add_theme_color_override("font_color", SUBTLE)
	_status.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	var status_row := HBoxContainer.new()
	status_row.add_theme_constant_override("separation", 6)
	column.add_child(status_row)
	_status_glyph = _glyph(status_row, "notice")
	_status.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	status_row.add_child(_status)

	_error = _label("")
	_error.add_theme_font_size_override("font_size", 12)
	_error.add_theme_color_override("font_color", ThemeTokens.color("warn"))
	_error_row = HBoxContainer.new()
	_error_row.add_theme_constant_override("separation", 6)
	column.add_child(_error_row)
	_error_glyph = _glyph(_error_row, "warn")
	_error_glyph.visible = false
	_error.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_error_row.add_child(_error)
	_error_row.visible = false
	_space(column, 22)
	var navigation := VBoxContainer.new()
	navigation.add_theme_constant_override("separation", 2)
	column.add_child(navigation)
	_settings_button = _button("Settings", _toggle_settings)
	_style_navigation(_settings_button, "settings", true)
	navigation.add_child(_settings_button)
	var servers_button := _button("Servers", _open_server_management)
	_style_navigation(servers_button, "servers")
	servers_button.tooltip_text = "Browse saved connections and manage local servers."
	navigation.add_child(servers_button)
	var spring := Control.new()
	spring.size_flags_vertical = Control.SIZE_EXPAND_FILL
	column.add_child(spring)
	var footer := PanelContainer.new()
	var footer_style := _box(Color.TRANSPARENT, DIVIDER, 0)
	footer_style.set_border_width_all(0)
	footer_style.border_width_top = 1
	footer_style.content_margin_top = 12
	footer.add_theme_stylebox_override("panel", footer_style)
	column.add_child(footer)
	var actions := VBoxContainer.new()
	actions.add_theme_constant_override("separation", 2)
	footer.add_child(actions)
	_disconnect_button = _button("Disconnect", func() -> void: disconnect_requested.emit())
	_style_navigation(_disconnect_button, "disconnect")
	_disconnect_button.add_theme_color_override("font_hover_color", ThemeTokens.color("critical"))
	_disconnect_button.add_theme_color_override("icon_hover_color", ThemeTokens.color("critical"))
	actions.add_child(_disconnect_button)
	var exit_button := _button("Exit", func() -> void: exit_requested.emit())
	exit_button.tooltip_text = "Exit to desktop"
	_style_navigation(exit_button, "exit")
	actions.add_child(exit_button)


func _build_settings() -> void:
	_content = MarginContainer.new()
	_content.name = "MenuContent"
	_content.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_content.add_theme_constant_override("margin_top", 16)
	_content.add_theme_constant_override("margin_bottom", 18)
	_columns.add_child(_content)
	_settings_panel = VBoxContainer.new()
	_settings_panel.name = "SettingsPanel"
	_settings_panel.add_theme_constant_override("separation", 0)
	_content.add_child(_settings_panel)
	var header := HBoxContainer.new()
	header.custom_minimum_size.y = 28
	header.add_theme_constant_override("separation", 8)
	_settings_panel.add_child(header)
	var title := _label("Settings")
	title.add_theme_font_override("font", MEDIUM_FONT)
	title.add_theme_font_size_override("font_size", 15)
	title.add_theme_color_override("font_color", ThemeTokens.color("ink"))
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	header.add_child(title)
	_resume_hint = _label("Esc")
	_resume_hint.add_theme_font_override("font", ThemeTokens.font("log"))
	_resume_hint.add_theme_font_size_override("font_size", 10)
	_resume_hint.add_theme_color_override("font_color", SUBTLE)
	_resume_hint.tooltip_text = "Resume colony"
	_resume_hint.autowrap_mode = TextServer.AUTOWRAP_OFF
	var keycap := PanelContainer.new()
	var keycap_style := _box(Color.TRANSPARENT, ThemeTokens.color("line-100"), 3)
	keycap_style.border_width_bottom = 2
	keycap_style.content_margin_left = 4
	keycap_style.content_margin_right = 4
	keycap.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	keycap.add_theme_stylebox_override("panel", keycap_style)
	keycap.add_child(_resume_hint)
	header.add_child(keycap)
	_close_button = TextureButton.new()
	_close_button.name = "CloseMenu"
	_close_button.custom_minimum_size = Vector2(22, 22)
	_close_button.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	_close_button.stretch_mode = TextureButton.STRETCH_KEEP_CENTERED
	_close_button.texture_normal = _svg_texture(
		'<svg xmlns="http://www.w3.org/2000/svg" width="16" height="16"><path d="M4.5 4.5l7 7M11.5 4.5l-7 7" stroke="#8b929a" stroke-width="1.3" stroke-linecap="round"/></svg>'
	)
	_close_button.texture_hover = _svg_texture(
		(
			'<svg xmlns="http://www.w3.org/2000/svg" width="22" height="22"><rect width="22" height="22" rx="3" fill="#2c3137"/>'
			+ '<path d="M7.5 7.5l7 7M14.5 7.5l-7 7" stroke="#e6e8eb" stroke-width="1.3" stroke-linecap="round"/></svg>'
		)
	)
	_close_button.texture_focused = _svg_texture(
		'<svg xmlns="http://www.w3.org/2000/svg" width="22" height="22"><rect x="1" y="1" width="20" height="20" rx="3" fill="none" stroke="#5cc6bd" stroke-width="2"/></svg>'
	)
	_close_button.tooltip_text = "Close menu · Resume colony"
	_close_button.pressed.connect(
		func() -> void:
			if _can_resume() and not _busy:
				resume_requested.emit()
	)
	header.add_child(_close_button)
	_space(_settings_panel, 16)
	var section := _label("Display")
	section.uppercase = true
	section.add_theme_font_override("font", ThemeTokens.font("body-strong"))
	section.add_theme_font_size_override("font_size", 11)
	section.add_theme_color_override("font_color", SUBTLE)
	_settings_panel.add_child(section)
	_space(_settings_panel, 2)
	_build_scale_control()
	_reduced_motion = CheckButton.new()
	_reduced_motion.name = "ReducedMotion"
	_reduced_motion.text = "Reduce motion"
	_reduced_motion.tooltip_text = "Keep critical alert borders steady rather than pulsing."
	_reduced_motion.button_pressed = settings.reduced_motion
	_reduced_motion.toggled.connect(
		func(value: bool) -> void:
			settings.reduced_motion = value
			_apply_settings()
	)
	_toggle_row(_reduced_motion, "Keep critical alert borders steady")
	_diagnostics_toggle = CheckButton.new()
	_diagnostics_toggle.name = "Diagnostics"
	_diagnostics_toggle.text = "Show diagnostics"
	_diagnostics_toggle.tooltip_text = "Show frame rate, frame time and network diagnostics."
	_diagnostics_toggle.button_pressed = settings.diagnostics_enabled
	_diagnostics_toggle.toggled.connect(_diagnostics_changed)
	_toggle_row(_diagnostics_toggle, "Frame rate, frame time and ping on the map")
	_graph_toggle = CheckButton.new()
	_graph_toggle.name = "DiagnosticsGraph"
	_graph_toggle.text = "Show frame/RTT graph"
	_graph_toggle.button_pressed = settings.diagnostics_graph_enabled
	_graph_toggle.disabled = not settings.diagnostics_enabled
	_graph_toggle.toggled.connect(_graph_changed)
	_toggle_row(_graph_toggle, "A short history beside the diagnostics")
	_space(_settings_panel, 18)
	_live_hint = _description("The world continues while this menu is open.")
	_settings_panel.add_child(_live_hint)
	_refresh_graph_reason()


func _layout_modal() -> void:
	if _modal == null or _content == null:
		return
	var available := Vector2(maxf(1, size.x - 32), maxf(1, size.y - 32))
	var width := minf(MODAL_WIDTH, available.x)
	var stacked := width < 640
	_columns.vertical = stacked
	_columns.custom_minimum_size.y = 0 if stacked else 418
	_sidebar.custom_minimum_size.x = 0 if stacked else SIDEBAR_WIDTH
	_sidebar_style.border_width_right = 0 if stacked else 1
	_sidebar_style.border_width_bottom = 1 if stacked else 0
	_sidebar_style.corner_radius_top_left = 5
	_sidebar_style.corner_radius_top_right = 5 if stacked else 0
	_sidebar_style.corner_radius_bottom_left = 0 if stacked else 5
	for edge: String in ["left", "right"]:
		_content.add_theme_constant_override("margin_" + edge, 16 if stacked else 20)
	_layout_scale_control(stacked)
	var height := minf(available.y, maxf(420, _columns.get_combined_minimum_size().y + 2))
	_modal.size = Vector2(width, height)
	_modal.position = ((size - _modal.size) * 0.5).floor()


func _build_scale_control() -> void:
	_scale_row = BoxContainer.new()
	_scale_row.name = "UiScaleRow"
	_scale_row.add_theme_constant_override("separation", 16)
	_settings_row().add_child(_scale_row)
	var caption := VBoxContainer.new()
	caption.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	caption.add_theme_constant_override("separation", 2)
	_scale_row.add_child(caption)
	var title := _label("UI scale")
	title.add_theme_color_override("font_color", ThemeTokens.color("ink"))
	caption.add_child(title)
	caption.add_child(_description("Panels, menus and text"))
	_scale_controls = BoxContainer.new()
	_scale_controls.name = "UiScaleControls"
	_scale_controls.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	_scale_controls.add_theme_constant_override("separation", 4)
	_scale_row.add_child(_scale_controls)
	var well := PanelContainer.new()
	well.name = "UiScaleWell"
	var well_style := _box(ThemeTokens.color("bg-000"), ThemeTokens.color("line-100"), 4)
	well_style.set_content_margin_all(3)  # 1px border plus the prototype's 2px padding.
	well.add_theme_stylebox_override("panel", well_style)
	_scale_controls.add_child(well)
	_scale_segments = GridContainer.new()
	_scale_segments.name = "UiScaleSegments"
	_scale_segments.columns = 4
	_scale_segments.add_theme_constant_override("h_separation", 2)
	_scale_segments.add_theme_constant_override("v_separation", 2)
	well.add_child(_scale_segments)
	for value: int in PRIMARY_UI_SCALES:
		var button := Button.new()
		button.name = "UiScale%d" % value
		button.text = "%d%%" % value
		button.toggle_mode = true
		button.custom_minimum_size.y = 24
		button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		button.tooltip_text = "Scale panels, menus and text to %d%%." % value
		button.add_theme_font_override("font", ThemeTokens.font("log"))
		button.add_theme_font_size_override("font_size", 12)
		button.add_theme_color_override("font_color", DeckTheme.MUTED)
		for state: String in ["font_hover_color", "font_pressed_color", "font_focus_color"]:
			button.add_theme_color_override(state, ThemeTokens.color("ink"))
		_style_scale_segment(button, 9)
		button.pressed.connect(_pick_ui_scale.bind(value))
		_scale_buttons[value] = button
		_scale_segments.add_child(button)
	_scale_more = MenuButton.new()
	_scale_more.name = "UiScaleMore"
	_scale_more.text = "More…"
	_scale_more.custom_minimum_size.y = 24
	_scale_more.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	_scale_more.tooltip_text = "Additional supported UI scales."
	_scale_more.add_theme_font_override("font", ThemeTokens.font("log"))
	_scale_more.add_theme_font_size_override("font_size", 12)
	_scale_more.add_theme_color_override("font_color", DeckTheme.MUTED)
	_style_scale_segment(_scale_more, 6)
	_scale_controls.add_child(_scale_more)
	# Preserve the OptionButton data/signals without an invisible keyboard stop.
	_ui_scale = OptionButton.new()
	_ui_scale.name = "UiScale"
	_ui_scale.focus_mode = Control.FOCUS_NONE
	_ui_scale.visible = false
	_scale_controls.add_child(_ui_scale)
	for value: int in ClientSettings.UI_SCALES:
		_ui_scale.add_item("%d%%" % value, value)
		if not PRIMARY_UI_SCALES.has(value):
			_scale_more.get_popup().add_radio_check_item("%d%%" % value, value)
	_ui_scale.item_selected.connect(
		func(index: int) -> void:
			if index >= 0 and index < _ui_scale.item_count:
				_pick_ui_scale(_ui_scale.get_item_id(index))
	)
	_scale_more.get_popup().id_pressed.connect(_pick_ui_scale)
	_sync_ui_scale_controls()


func _style_scale_segment(button: Button, padding: int) -> void:
	for state: String in ["normal", "hover", "pressed", "hover_pressed", "disabled"]:
		var active := state in ["pressed", "hover_pressed"]
		var style := _box(Color("3a4047") if active else Color.TRANSPARENT, Color.TRANSPARENT, 3)
		style.set_border_width_all(0)
		style.content_margin_left = padding
		style.content_margin_right = padding
		button.add_theme_stylebox_override(state, style)
	var focus := _box(Color.TRANSPARENT, ThemeTokens.color("accent"), 3)
	focus.draw_center = false
	button.add_theme_stylebox_override("focus", focus)


func _layout_scale_control(stacked: bool) -> void:
	if _scale_row == null:
		return
	if _scale_row.vertical == stacked and _scale_segments.columns == (2 if stacked else 4):
		return
	_scale_row.vertical = stacked
	_scale_row.add_theme_constant_override("separation", 8 if stacked else 16)
	_scale_controls.vertical = stacked
	_scale_segments.columns = 2 if stacked else 4
	for button: Button in _scale_buttons.values():
		_style_scale_segment(button, 4 if stacked else 9)


func _pick_ui_scale(value: int) -> void:
	if not ClientSettings.UI_SCALES.has(value):
		return
	settings.ui_scale_percent = value
	settings.font_size = ClientSettings.DEFAULT_FONT_SIZE
	_apply_settings()


func _sync_ui_scale_controls(prefer_settings := false) -> void:
	if _ui_scale == null:
		return
	var value := settings.ui_scale_percent
	if prefer_settings or value != _scale_settings_value:
		for index in _ui_scale.item_count:
			if _ui_scale.get_item_id(index) == value:
				_ui_scale.select(index)
				break
		_scale_settings_value = value
	elif _ui_scale.selected >= 0:
		# OptionButton.select() is a silent visual update, just as before the redesign.
		value = _ui_scale.get_selected_id()
	for scale: int in _scale_buttons:
		var button: Button = _scale_buttons[scale]
		button.set_pressed_no_signal(scale == value)
		button.disabled = _ui_scale.disabled
	var popup := _scale_more.get_popup()
	_scale_more.visible = popup.item_count > 0
	_scale_more.focus_mode = Control.FOCUS_ALL if _scale_more.visible else Control.FOCUS_NONE
	for index in popup.item_count:
		popup.set_item_checked(index, popup.get_item_id(index) == value)
	_scale_more.text = "More…" if PRIMARY_UI_SCALES.has(value) else "%d%%…" % value
	_scale_more.disabled = _ui_scale.disabled


func _settings_row() -> PanelContainer:
	var row := PanelContainer.new()
	row.custom_minimum_size = Vector2(1, 54)
	var style := _box(Color.TRANSPARENT, DIVIDER, 0)
	style.set_border_width_all(0)
	style.border_width_top = 1
	style.content_margin_top = 8
	style.content_margin_bottom = 8
	row.add_theme_stylebox_override("panel", style)
	_settings_panel.add_child(row)
	return row


func _toggle_row(control: CheckButton, description: String) -> void:
	var column := VBoxContainer.new()
	column.add_theme_constant_override("separation", 2)
	_settings_row().add_child(column)
	control.custom_minimum_size = Vector2(1, 18)
	control.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	control.alignment = HORIZONTAL_ALIGNMENT_LEFT
	control.add_theme_font_override("font", ThemeTokens.font("body"))
	control.add_theme_font_size_override("font_size", 13)
	control.add_theme_constant_override("h_separation", 16)
	control.add_theme_constant_override("check_v_offset", 0)
	for state: String in ["normal", "hover", "pressed", "hover_pressed", "disabled"]:
		control.add_theme_stylebox_override(state, _box(Color.TRANSPARENT, Color.TRANSPARENT, 0))
	control.add_theme_color_override("font_color", ThemeTokens.color("ink"))
	control.add_theme_color_override("font_disabled_color", SUBTLE)
	for enabled: bool in [false, true]:
		var state := "checked" if enabled else "unchecked"
		control.add_theme_icon_override(state, _switch_texture(enabled))
		control.add_theme_icon_override(state + "_disabled", _switch_texture(enabled, true))
	column.add_child(control)
	var inset := MarginContainer.new()
	inset.add_theme_constant_override("margin_right", 46)
	column.add_child(inset)
	inset.add_child(_description(description))


func set_status(message: String, warning := false) -> void:
	_status.text = "Warning · " + message if warning else message
	_status_glyph.texture = ThemeTokens.glyph("warn" if warning else "notice")
	_status.add_theme_color_override(
		"font_color", ThemeTokens.color("warn") if warning else ThemeTokens.color("ink-muted")
	)


func set_busy(busy: bool) -> void:
	_busy = busy
	_refresh_last_button()


func _process(_delta: float) -> void:
	if visible:
		_refresh_last_button()
		_sync_ui_scale_controls()
		_error_row.visible = not _error.text.is_empty()
		_error_glyph.visible = _error_row.visible


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
	# Navigation selects a page; repeated activation must not hide its controls.
	_settings_panel.visible = true


func _scrim_input(event: InputEvent) -> void:
	if (
		event is InputEventMouseButton
		and event.button_index == MOUSE_BUTTON_LEFT
		and event.pressed
		and _can_resume()
		and not _busy
	):
		resume_requested.emit()


func _open_server_management() -> void:
	server_management_requested.emit()


func _diagnostics_changed(value: bool) -> void:
	settings.diagnostics_enabled = value
	_graph_toggle.disabled = not value
	if not value:
		settings.diagnostics_graph_enabled = false
		_graph_toggle.set_pressed_no_signal(false)
	_refresh_graph_reason()
	_apply_settings()


func _graph_changed(value: bool) -> void:
	settings.diagnostics_graph_enabled = value if settings.diagnostics_enabled else false
	_apply_settings()


func _apply_settings() -> void:
	if main != null and main.has_method("apply_settings"):
		main.apply_settings(settings)
	_sync_ui_scale_controls(true)
	settings_changed.emit(settings)


@warning_ignore("unused_parameter")
func apply_metrics(next_metrics: UiMetrics) -> void:
	metrics = UiMetrics.new()
	theme = DeckTheme.create(metrics)
	_sync_ui_scale_controls(true)
	_layout_modal.call_deferred()


func _refresh_last_button() -> void:
	var resumable := _can_resume()
	_disconnect_button.visible = resumable
	_live_hint.visible = resumable
	_resume_hint.visible = resumable
	_resume_hint.get_parent().visible = resumable
	_close_button.visible = resumable
	_close_button.disabled = _busy
	_last_button.text = "Resume colony" if resumable else "Join last server"
	_last_button.disabled = _busy or not (resumable or _has_last_server())
	if _busy:
		_last_button.tooltip_text = "A connection attempt is already in progress."
	elif not resumable and not _has_last_server():
		_last_button.tooltip_text = "No successfully joined server yet. Choose Servers to connect."
	elif resumable:
		_last_button.tooltip_text = "Return to the connected colony without reconnecting."
	else:
		_last_button.tooltip_text = settings.server_host + " / " + settings.database


func _can_resume() -> bool:
	return resume_available.is_valid() and bool(resume_available.call())


func _has_last_server() -> bool:
	return not settings.server_host.is_empty() and not settings.database.is_empty()


func _refresh_graph_reason() -> void:
	_graph_toggle.tooltip_text = (
		"A short history of frame time and network round trips."
		if settings.diagnostics_enabled
		else "Enable Show diagnostics first."
	)


func _box(fill: Color, border: Color, radius: int) -> StyleBoxFlat:
	var style := StyleBoxFlat.new()
	style.bg_color = fill
	style.border_color = border
	style.set_border_width_all(1)
	style.set_corner_radius_all(radius)
	style.set_content_margin_all(0)
	return style


func _style_scrollbar(scrollbar: VScrollBar) -> void:
	var track := _box(Color.TRANSPARENT, Color.TRANSPARENT, 0)
	track.set_border_width_all(0)
	track.content_margin_left = 6
	scrollbar.add_theme_stylebox_override("scroll", track)
	for state: String in ["grabber", "grabber_highlight", "grabber_pressed"]:
		var fill := ThemeTokens.color("line-100" if state == "grabber" else "bg-400")
		var grabber := _box(fill, Color.TRANSPARENT, 3)
		grabber.set_border_width_all(0)
		grabber.content_margin_left = 6
		grabber.content_margin_top = 12
		scrollbar.add_theme_stylebox_override(state, grabber)


func _style_primary(button: Button) -> void:
	button.add_theme_font_override("font", MEDIUM_FONT)
	for state: String in ["normal", "hover", "pressed", "disabled"]:
		var fill := Color("74d2ca") if state == "hover" else ThemeTokens.color("accent")
		if state == "disabled":
			fill = ThemeTokens.color("bg-200")
		var style := _box(fill, Color.TRANSPARENT, 4)
		style.content_margin_left = 10
		style.content_margin_right = 10
		button.add_theme_stylebox_override(state, style)
	for state: String in [
		"font_color", "font_hover_color", "font_pressed_color", "font_focus_color"
	]:
		button.add_theme_color_override(state, Color("0f1a19"))
	button.add_theme_color_override("font_disabled_color", SUBTLE)


func _style_navigation(button: Button, icon_name: String, selected := false) -> void:
	button.custom_minimum_size.y = 32
	button.alignment = HORIZONTAL_ALIGNMENT_LEFT
	button.icon = _navigation_icon(icon_name)
	button.add_theme_constant_override("h_separation", 10)
	button.add_theme_color_override("icon_normal_color", DeckTheme.MUTED)
	button.add_theme_color_override("icon_hover_color", ThemeTokens.color("ink"))
	button.add_theme_color_override(
		"font_color", ThemeTokens.color("ink") if selected else DeckTheme.MUTED
	)
	for state: String in ["normal", "hover", "pressed"]:
		var raised := selected or state != "normal"
		var style := _box(
			ThemeTokens.color("bg-200") if raised else Color.TRANSPARENT,
			ThemeTokens.color("line-100") if selected else Color.TRANSPARENT,
			4
		)
		style.content_margin_left = 10
		style.content_margin_right = 10
		button.add_theme_stylebox_override(state, style)


func _navigation_icon(icon_name: String) -> Texture2D:
	var paths: Dictionary = {
		"settings":
		'<circle cx="8" cy="8" r="2.2"/><path d="M8 1.8v1.7M8 12.5v1.7M1.8 8h1.7M12.5 8h1.7M3.6 3.6l1.2 1.2M11.2 11.2l1.2 1.2M3.6 12.4l1.2-1.2M11.2 4.8l1.2-1.2"/>',
		"servers":
		'<rect x="2.5" y="2.5" width="11" height="4.5" rx="1"/><rect x="2.5" y="9" width="11" height="4.5" rx="1"/><path d="M5 4.75h.01M5 11.25h.01"/>',
		"disconnect": '<path d="M8 2.5v5M4.8 4.4a5 5 0 1 0 6.4 0"/>',
		"exit": '<path d="M6.5 2.5h-3v11h3M10 5l3 3-3 3M13 8H6"/>'
	}
	return _svg_texture(
		(
			'<svg xmlns="http://www.w3.org/2000/svg" width="16" height="16" viewBox="0 0 16 16"><g fill="none" stroke="white" stroke-width="1.3" stroke-linecap="round" stroke-linejoin="round">%s</g></svg>'
			% paths[icon_name]
		)
	)


func _switch_texture(enabled: bool, disabled := false) -> Texture2D:
	var track := "#5cc6bd" if enabled else "#30353b"
	var knob := "#121417" if enabled else "#b0b6bd"
	return _svg_texture(
		(
			'<svg xmlns="http://www.w3.org/2000/svg" width="30" height="16"><g opacity="%s"><rect width="30" height="16" rx="8" fill="%s"/><circle cx="%d" cy="8" r="6" fill="%s"/></g></svg>'
			% ["0.45" if disabled else "1", track, 22 if enabled else 8, knob]
		)
	)


func _svg_texture(svg: String) -> Texture2D:
	var image := Image.new()
	image.load_svg_from_string(svg)
	return ImageTexture.create_from_image(image)


func _space(parent: Node, height: float) -> void:
	var spacer := Control.new()
	spacer.custom_minimum_size.y = height
	spacer.mouse_filter = Control.MOUSE_FILTER_IGNORE
	parent.add_child(spacer)


func _description(text: String) -> Label:
	var label := _label(text)
	label.add_theme_font_size_override("font_size", 12)
	label.add_theme_color_override("font_color", SUBTLE)
	return label


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
