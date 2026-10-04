class_name RosterRow
extends PanelContainer

signal selection_requested(id: Variant)
const Models = preload("models.gd")
const UI = preload("presentation.gd")
const ATLAS_NAME_FONT = preload("res://ui/theme/fonts/IBMPlexSans-Medium.woff2")
var model: Dictionary = {}
var _hovered := false
var _surface: StyleBoxFlat
var _atlas := false


func _init() -> void:
	mouse_entered.connect(_set_hovered.bind(true))
	mouse_exited.connect(_set_hovered.bind(false))


## config.atlas opts into the 24px table presentation; default cards are unchanged.
func set_model(data: Dictionary, config: Dictionary = {}) -> void:
	model = Models.colonist(data, config)
	_atlas = config.get("atlas", false) == true
	mouse_default_cursor_shape = (
		Control.CURSOR_POINTING_HAND if model.id_available else Control.CURSOR_ARROW
	)
	_render()


func _render() -> void:
	tooltip_text = "%s · %s\n%s" % [model.name, model.state, model.job]
	if not model.id_available:
		tooltip_text += "\nSelection unavailable · identifier unavailable"
	UI.clear(self)
	focus_mode = Control.FOCUS_ALL
	if _atlas:
		_render_atlas()
		return
	custom_minimum_size.y = ThemeTokens.number("control-md")
	_surface = UI.surface("bg-100", "line-100")
	_surface.set_corner_radius_all(0)
	_surface.content_margin_top = ThemeTokens.number("space-1")
	_surface.content_margin_bottom = _surface.content_margin_top
	if model.selected:
		_surface.border_color = ThemeTokens.color("accent")
		_surface.border_width_left = 2
	add_theme_stylebox_override("panel", _surface)
	_refresh_surface()
	var row = UI.row()
	row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.custom_minimum_size.x = 192
	row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var colonist_name = UI.bounded(model.name, "body-strong", "ink", 40)
	colonist_name.name = "ColonistName"
	row.add_child(colonist_name)
	var state_tag = UI.tag(model.state, model.state_level, false, 76)
	state_tag.name = "StateTag"
	row.add_child(state_tag)
	var job = UI.bounded(model.job, "small", "ink-muted", 0)
	job.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	job.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	var detail = UI.row()
	detail.mouse_filter = Control.MOUSE_FILTER_IGNORE
	detail.custom_minimum_size.x = 192
	detail.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	detail.add_child(job)
	if model.worst.is_empty():
		detail.add_child(
			UI.bounded("Needs unavailable" if _missing_needs() else "—", "small", "ink-subtle", 88)
		)
	else:
		var worst = PanelContainer.new()
		worst.name = "WorstNeed"
		worst.mouse_filter = Control.MOUSE_FILTER_IGNORE
		var worst_box = UI.surface("bg-100", "line-100", "space-1")
		worst_box.content_margin_top = 0
		worst_box.content_margin_bottom = 0
		worst.add_theme_stylebox_override("panel", worst_box)
		var status = UI.row()
		status.mouse_filter = Control.MOUSE_FILTER_IGNORE
		status.add_theme_constant_override("separation", int(ThemeTokens.number("space-1")))
		status.add_child(UI.glyph(model.worst.level))
		status.add_child(UI.label(UI.status_word(model.worst.level), "tag", model.worst.level))
		status.add_child(
			UI.bounded(
				model.worst.label + " %.1f" % model.worst.value, "readout", model.worst.level, 88
			)
		)
		worst.tooltip_text = (
			"%s · %s: %s / 100 · local need band"
			% [UI.status_word(model.worst.level), model.worst.label, model.worst.value]
		)
		tooltip_text += "\n" + worst.tooltip_text
		worst.add_child(status)
		detail.add_child(worst)
	var content = UI.flow()
	content.mouse_filter = Control.MOUSE_FILTER_IGNORE
	content.add_theme_constant_override("v_separation", 0)
	content.add_child(row)
	content.add_child(detail)
	add_child(content)
	queue_redraw()


## One contiguous table row. Unbounded severity copy takes priority over the job.
func _render_atlas() -> void:
	custom_minimum_size.y = 24
	_surface = UI.surface("bg-100", "line-100")
	_surface.set_corner_radius_all(0)
	_surface.set_border_width_all(0)
	_surface.border_width_top = 1
	_surface.border_color = Color("23272c")
	_surface.content_margin_left = 10
	_surface.content_margin_right = 10
	_surface.content_margin_top = 0
	_surface.content_margin_bottom = 0
	add_theme_stylebox_override("panel", _surface)
	_refresh_surface()
	var row = UI.row()
	row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	var colonist_name = _atlas_label(model.name, "accent" if model.selected else "ink")
	colonist_name.name = "ColonistName"
	colonist_name.add_theme_font_override("font", ATLAS_NAME_FONT)
	colonist_name.custom_minimum_size.x = 104
	colonist_name.clip_text = true
	colonist_name.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	colonist_name.tooltip_text = model.name
	row.add_child(colonist_name)
	var detail: String = model.job if model.job == model.state else model.state + " · " + model.job
	var job = _atlas_label(detail, UI.status_color(model.state_level))
	job.name = "StateTag"
	job.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	job.clip_text = true
	job.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	job.tooltip_text = detail
	row.add_child(job)
	if not model.worst.is_empty():
		var worst = UI.row()
		worst.name = "WorstNeed"
		worst.mouse_filter = Control.MOUSE_FILTER_IGNORE
		worst.add_theme_constant_override("separation", 4)
		var glyph = UI.glyph(model.worst.level)
		glyph.custom_minimum_size = Vector2(14, 14)
		worst.add_child(glyph)
		var word = _atlas_label(UI.status_word(model.worst.level), model.worst.level)
		word.add_theme_font_size_override("font_size", 11)
		worst.add_child(word)
		var value = _atlas_label(
			"%s %.1f" % [model.worst.label, model.worst.value], model.worst.level
		)
		value.add_theme_font_override("font", ThemeTokens.font("log"))
		value.add_theme_font_size_override("font_size", 11)
		worst.add_child(value)
		worst.tooltip_text = (
			"%s · %s: %s / 100 · local need band"
			% [UI.status_word(model.worst.level), model.worst.label, model.worst.value]
		)
		tooltip_text += "\n" + worst.tooltip_text
		row.add_child(worst)
	else:
		var mood: Variant = null
		for need: Dictionary in model.needs:
			if need.label == "Mood":
				mood = need.value
		var value = _atlas_label("%.0f" % mood if mood != null else "—", "ink")
		value.name = "MoodValue"
		value.add_theme_font_override("font", ThemeTokens.font("log"))
		value.custom_minimum_size.x = 26
		value.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
		value.tooltip_text = "Mood: %s / 100" % mood if mood != null else "Mood unavailable"
		tooltip_text += "\n" + value.tooltip_text
		row.add_child(value)
	if _missing_needs():
		tooltip_text += "\nSome needs unavailable"
	add_child(row)
	queue_redraw()


func _atlas_label(copy: String, ink: String) -> Label:
	var label = UI.label(copy, "small", ink)
	label.add_theme_font_override("font", ThemeTokens.font("body"))
	label.add_theme_font_size_override("font_size", 12)
	label.add_theme_constant_override("line_spacing", 0)
	return label


func _set_hovered(hovered: bool) -> void:
	_hovered = hovered
	_refresh_surface()


func _refresh_surface() -> void:
	if _surface != null:
		if _atlas:
			_surface.bg_color = ThemeTokens.color(
				"bg-200" if _hovered and model.id_available else "bg-100"
			)
			return
		_surface.bg_color = ThemeTokens.color(
			(
				"accent-soft"
				if model.selected
				else "bg-300" if _hovered and model.id_available else "bg-100"
			)
		)


func _missing_needs() -> bool:
	for need in model.needs:
		if need.value == null:
			return true
	return false


func _gui_input(event: InputEvent) -> void:
	if (
		model.get("id_available", false)
		and (
			(
				event is InputEventMouseButton
				and event.button_index == MOUSE_BUTTON_LEFT
				and event.pressed
			)
			or event.is_action_pressed("ui_accept")
		)
	):
		grab_focus()
		selection_requested.emit(model.get("id"))
		accept_event()


func _notification(what: int) -> void:
	if what in [NOTIFICATION_FOCUS_ENTER, NOTIFICATION_FOCUS_EXIT]:
		queue_redraw()


func _draw() -> void:
	if has_focus():
		draw_rect(
			Rect2(Vector2(-1, -1), size + Vector2(2, 2)), ThemeTokens.color("bg-000"), false, 1
		)
		draw_rect(
			Rect2(Vector2(-3, -3), size + Vector2(6, 6)), ThemeTokens.color("accent"), false, 2
		)
