class_name NeedMeter
extends HBoxContainer

const Models = preload("models.gd")
const UI = preload("presentation.gd")
const Track = preload("meter_track.gd")
var model: Dictionary = {}

## label, value; optional trend rising/flat/falling PLUS trend_horizon.
func set_model(data: Dictionary, config: Dictionary = {}) -> void:
	set_presentation_model(Models.need(data, config))

func set_presentation_model(data: Dictionary) -> void:
	model = data.duplicate(true)
	UI.clear(self)
	add_theme_constant_override("separation", int(ThemeTokens.number("space-1")))
	custom_minimum_size.y = ThemeTokens.number("control-sm")
	var ink = UI.status_color(model.level, "ink")
	var name_label = UI.bounded(model.label, "small", "ink-muted", 48)
	name_label.size_flags_horizontal = Control.SIZE_FILL
	add_child(name_label)
	var track = Track.new()
	track.name = "Track"
	track.set_model(model)
	add_child(track)
	var value = UI.label("%.1f" % model.value if model.value != null else "—", "readout", ink)
	value.name = "Value"
	value.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	value.custom_minimum_size.x = ThemeTokens.font("readout").get_string_size("100.0", HORIZONTAL_ALIGNMENT_LEFT, -1, ThemeTokens.font_size("readout")).x
	add_child(value)
	var status = UI.row()
	status.custom_minimum_size.x = 68
	status.add_theme_constant_override("separation", int(ThemeTokens.number("space-1")))
	if model.level in ["warn", "critical"]:
		status.add_child(UI.glyph(model.level))
		status.add_child(UI.label(UI.status_word(model.level), "tag", ink))
	elif model.value == null:
		status.add_child(UI.label("Unavailable", "small", "ink-subtle"))
	add_child(status)
	tooltip_text = "%s: %s / 100 · higher is better\nLocal need band: %s\nWarning below %s · critical below %s" % [model.label, str(model.value) if model.value != null else "Unavailable", UI.status_word(model.level) if model.value != null else "Unavailable", model.thresholds.warn, model.thresholds.critical]
	var trend = UI.label("", "readout", "ink-subtle")
	trend.custom_minimum_size.x = 12
	add_child(trend)
	if not model.trend.is_empty():
		var arrows = {"rising": "↗", "flat": "→", "falling": "↘"}
		trend.text = arrows[model.trend]
		tooltip_text += "\n%s over %s" % [model.trend.capitalize(), model.trend_horizon]
	else:
		tooltip_text += "\n" + ("Trend warming up" if model.availability == "warming" else "Trend unavailable")
	queue_redraw()

func _draw() -> void:
	draw_rect(Rect2(Vector2.ZERO, size), ThemeTokens.color("bg-200"))
