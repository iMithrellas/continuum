class_name RosterRow
extends PanelContainer

signal selection_requested(id: Variant)
const Models = preload("models.gd")
const UI = preload("presentation.gd")
var model: Dictionary = {}

func set_model(data: Dictionary, config: Dictionary = {}) -> void:
	model = Models.colonist(data, config)
	tooltip_text = "" if model.id_available else "Selection unavailable · identifier unavailable"
	UI.clear(self)
	focus_mode = Control.FOCUS_ALL
	custom_minimum_size.y = ThemeTokens.number("control-sm")
	# Critical text must never sit on accent-soft: worst deviation has its own ground.
	var box = UI.surface("accent-soft" if model.selected else "bg-100", "line-100")
	box.set_corner_radius_all(0)
	box.content_margin_top = 0
	box.content_margin_bottom = 0
	if model.selected:
		box.border_color = ThemeTokens.color("accent")
		box.border_width_left = 2
	add_theme_stylebox_override("panel", box)
	var row = UI.row()
	row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var colonist_name = UI.bounded(model.name, "body-strong", "ink", 40)
	colonist_name.name = "ColonistName"
	row.add_child(colonist_name)
	var state_tag = UI.tag(model.state, model.state_level, false, 76)
	state_tag.name = "StateTag"
	row.add_child(state_tag)
	var job = UI.bounded(model.job, "small", "ink-muted", 0)
	job.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	job.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	row.add_child(job)
	if model.worst.is_empty():
		row.add_child(UI.bounded("Needs unavailable" if _missing_needs() else "—", "readout", "ink-subtle", 88))
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
		status.add_child(UI.glyph(model.worst.level))
		var value_copy = str(int(model.worst.value)) if model.worst.value == floor(model.worst.value) else str(model.worst.value)
		status.add_child(UI.bounded(model.worst.label + " " + value_copy, "readout", model.worst.level, 56))
		worst.tooltip_text = UI.status_word(model.worst.level) + " · local need band"
		worst.add_child(status)
		row.add_child(worst)
	add_child(row)
	queue_redraw()

func _missing_needs() -> bool:
	for need in model.needs:
		if need.value == null:
			return true
	return false

func _gui_input(event: InputEvent) -> void:
	if model.get("id_available", false) and ((event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT and event.pressed) or event.is_action_pressed("ui_accept")):
		selection_requested.emit(model.get("id"))
		accept_event()

func _notification(what: int) -> void:
	if what in [NOTIFICATION_FOCUS_ENTER, NOTIFICATION_FOCUS_EXIT]:
		queue_redraw()

func _draw() -> void:
	if has_focus():
		draw_rect(Rect2(Vector2(-1, -1), size + Vector2(2, 2)), ThemeTokens.color("bg-000"), false, 1)
		draw_rect(Rect2(Vector2(-3, -3), size + Vector2(6, 6)), ThemeTokens.color("accent"), false, 2)
