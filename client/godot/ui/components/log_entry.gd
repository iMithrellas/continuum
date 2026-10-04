class_name LogEntry
extends HBoxContainer

const Models = preload("models.gd")
const UI = preload("presentation.gd")
var model: Dictionary = {}


func set_model(data: Dictionary) -> void:
	set_presentation_model(Models.event(data))


func set_presentation_model(data: Dictionary) -> void:
	model = data.duplicate(true)
	UI.clear(self)
	custom_minimum_size.y = 24
	add_theme_constant_override("separation", 8)
	var time_copy: String = model.time_label
	if model.get("count", 1) > 1 and model.get("last_time_label", time_copy) != time_copy:
		time_copy += "–" + model.last_time_label
	var time := UI.label(time_copy, "log", "ink-subtle")
	time.custom_minimum_size.x = 38
	time.tooltip_text = time_copy
	add_child(time)
	var copy: String = model.message
	if not model.actor.is_empty() and not model.verb.is_empty() and not model.subject.is_empty():
		copy = " ".join([model.actor, model.verb, model.subject])
	var sentence := UI.bounded(copy, "small", UI.status_color(model.level, "ink"), 1)
	add_child(sentence)
	if model.get("count", 1) > 1:
		add_child(UI.label("×" + str(model.count), "readout", "ink-subtle"))
	tooltip_text = (
		"Day %s · %s\n%s\nSource: %s · %s"
		% [
			str(model.day) if model.day != null else "unavailable",
			time_copy,
			model.message,
			model.source,
			model.level
		]
	)
	queue_redraw()


func _draw() -> void:
	draw_rect(Rect2(Vector2.ZERO, size), ThemeTokens.color("bg-100"))
	draw_line(Vector2.ZERO, Vector2(size.x, 0), ThemeTokens.color("line-100"), 1)
