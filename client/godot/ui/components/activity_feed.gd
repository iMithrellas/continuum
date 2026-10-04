class_name ActivityFeed
extends VBoxContainer

signal routine_visibility_changed(show_routine: bool)
const Models = preload("models.gd")
const UI = preload("presentation.gd")
const Entry = preload("log_entry.gd")
var show_routine: bool = false
var _rows: Array = []
var model: Dictionary = {}


## Ordered event dictionaries. day is an explicit in-game day, not wall-clock.
func set_model(rows: Array) -> void:
	if rows == _rows and not model.is_empty():
		return
	_rows = rows.duplicate(true)
	_render()


func set_show_routine(enabled: bool) -> void:
	show_routine = enabled
	_render()


func _render() -> void:
	model = Models.activity(_rows, show_routine)
	UI.clear(self)
	add_theme_constant_override("separation", 0)
	for group in model.groups:
		var day_heading = UI.row()
		day_heading.custom_minimum_size.y = 24
		day_heading.add_theme_constant_override("separation", 6)
		day_heading.add_child(UI.label("Day", "section", "ink-subtle"))
		day_heading.add_child(
			UI.label(
				str(group.day) if group.day != null else "Unavailable", "readout", "ink-subtle"
			)
		)
		add_child(day_heading)
		for entry_model in group.entries:
			var entry = Entry.new()
			entry.set_presentation_model(entry_model)
			add_child(entry)
	if model.hidden_count > 0:
		var hidden = UI.row()
		hidden.custom_minimum_size.y = 24
		hidden.add_child(UI.label(str(model.hidden_count), "readout", "ink-subtle"))
		hidden.add_child(_routine_button("Routine events hidden · show"))
		add_child(hidden)
	elif show_routine:
		add_child(_routine_button("Hide routine events"))


func _routine_button(copy: String) -> Button:
	var button := UI.button(copy, _toggle)
	button.custom_minimum_size.y = 24
	for state: String in ["normal", "hover", "pressed", "focus", "disabled"]:
		var surface := StyleBoxFlat.new()
		surface.bg_color = ThemeTokens.color(
			"bg-200" if state in ["hover", "pressed"] else "bg-100"
		)
		surface.content_margin_left = 6
		surface.content_margin_right = 6
		button.add_theme_stylebox_override(state, surface)
	return button


func _toggle() -> void:
	set_show_routine(not show_routine)
	routine_visibility_changed.emit(show_routine)
