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
	tooltip_text = ""
	UI.clear(self)
	add_theme_constant_override("separation", int(ThemeTokens.number("space-2")))
	var ink = UI.status_color(model.level)
	var name_row = UI.row()
	name_row.custom_minimum_size.x = 72
	name_row.add_child(UI.bounded(model.label, "small", ink, 48 if model.level in ["warn", "critical"] else 72))
	if model.level in ["warn", "critical"]:
		name_row.add_child(UI.glyph(model.level))
		name_row.tooltip_text = UI.status_word(model.level)
	add_child(name_row)
	var track = Track.new()
	track.set_model(model)
	add_child(track)
	var value = UI.label(str(model.value) if model.value != null else "Unavailable", "readout", ink)
	value.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	value.custom_minimum_size.x = 24
	add_child(value)
	if not model.trend.is_empty():
		var arrows = {"rising": "↗", "flat": "→", "falling": "↘"}
		var trend = UI.label(arrows[model.trend], "readout", "ink-subtle")
		trend.tooltip_text = "Over " + model.trend_horizon
		add_child(trend)
	else:
		tooltip_text = "Trend warming up" if model.availability == "warming" else "Trend unavailable"
	queue_redraw()

func _draw() -> void:
	# Guarantee a legal ground even when the caller selects/raises the host row.
	draw_rect(Rect2(Vector2.ZERO, size), ThemeTokens.color("bg-200"))
