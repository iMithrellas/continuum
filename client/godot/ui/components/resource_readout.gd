class_name ResourceReadout
extends PanelContainer

const Models = preload("models.gd")
const UI = preload("presentation.gd")
var model: Dictionary = {}

## name, value; optional rate_per_game_hour, eta_game_hours, availability.
## config: warn/critical in game hours. No forecast is calculated here.
func set_model(data: Dictionary, config: Dictionary = {}) -> void:
	model = Models.resource(data, config)
	UI.clear(self)
	var box = UI.surface("bg-000", "line-100")
	box.set_corner_radius_all(0)
	box.content_margin_top = 0
	box.content_margin_bottom = 0
	add_theme_stylebox_override("panel", box)
	custom_minimum_size.y = ThemeTokens.number("topbar")
	var content = UI.column()
	content.add_theme_constant_override("separation", 0)
	var head = UI.row()
	var ink = UI.status_color(model.level, "ink-subtle")
	if model.level in ["warn", "critical"]:
		head.add_child(UI.glyph(model.level))
	head.add_child(UI.wrapped(model.name, "section", ink))
	content.add_child(head)
	var values = UI.flow()
	values.add_child(UI.label(str(model.value) if model.value != null else "Unavailable", "readout-lg", UI.status_color(model.level, "ink")))
	var rate = UI.wrapped((UI.status_word(model.level) + " · " if model.level != "nominal" else "") + model.rate_copy, "readout", UI.status_color(model.level))
	rate.custom_minimum_size.x = 120
	values.add_child(rate)
	content.add_child(values)
	add_child(content)
