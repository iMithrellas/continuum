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
	custom_minimum_size.y = ThemeTokens.number("control-md")
	add_theme_constant_override("separation", int(ThemeTokens.number("space-2")))
	var time_copy: String = model.time_label
	if model.get("count", 1) > 1 and model.get("last_time_label", time_copy) != time_copy:
		time_copy += "–" + model.last_time_label
	add_child(UI.bounded(time_copy, "log", "ink-subtle", 80))
	var kind: String = (
		model.level
		if model.level in ["warn", "critical"]
		else (
			"player" if model.source == "player" else "auto" if model.source == "automation" else ""
		)
	)
	if not kind.is_empty():
		add_child(UI.glyph(kind))
	var sentence = UI.column()
	sentence.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	if not model.actor.is_empty() and not model.verb.is_empty() and not model.subject.is_empty():
		var words = UI.column()
		words.add_child(
			UI.wrapped(model.actor, "body-strong", "accent" if model.source == "player" else "ink")
		)
		words.add_child(
			UI.wrapped(model.verb + " " + model.subject, "small", UI.status_color(model.level))
		)
		sentence.add_child(words)
	else:
		sentence.add_child(UI.wrapped(model.message, "small", UI.status_color(model.level)))
	if model.level in ["warn", "critical"]:
		sentence.add_child(UI.label(UI.status_word(model.level), "tag", model.level))
	add_child(sentence)
	if model.get("count", 1) > 1:
		add_child(UI.label("×" + str(model.count), "readout", "ink-subtle"))
	queue_redraw()


func _draw() -> void:
	draw_rect(Rect2(Vector2.ZERO, size), ThemeTokens.color("bg-100"))
