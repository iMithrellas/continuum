class_name RosterRow
extends PanelContainer

signal selection_requested(id: Variant)
const Models = preload("models.gd")
const UI = preload("presentation.gd")
var model: Dictionary = {}
var _hovered := false
var _surface: StyleBoxFlat


func _init() -> void:
	mouse_entered.connect(_set_hovered.bind(true))
	mouse_exited.connect(_set_hovered.bind(false))


func set_model(data: Dictionary, config: Dictionary = {}) -> void:
	model = Models.colonist(data, config)
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


func _set_hovered(hovered: bool) -> void:
	_hovered = hovered
	_refresh_surface()


func _refresh_surface() -> void:
	if _surface != null:
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
