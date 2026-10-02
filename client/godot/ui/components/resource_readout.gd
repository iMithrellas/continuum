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
	var content = UI.row() if config.get("single_line", false) == true else UI.flow()
	var stock = UI.column()
	stock.add_theme_constant_override("separation", 0)
	var head = UI.row()
	var ink = UI.status_color(model.level, "ink-subtle")
	if model.level in ["warn", "critical"]:
		head.add_child(UI.glyph(model.level))
	head.add_child(UI.bounded(model.name, "section", ink, 80))
	stock.add_child(head)
	stock.add_child(UI.label("%.1f" % model.value if model.value != null else "Unavailable", "readout-lg", UI.status_color(model.level, "ink")))
	content.add_child(stock)
	var observation = UI.column()
	observation.add_theme_constant_override("separation", 0)
	observation.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	var rate_value = Models.measurement(data, "rate_per_game_hour")
	if rate_value != null:
		var rate = UI.row()
		if model.level in ["warn", "critical"]:
			rate.add_child(UI.label(UI.status_word(model.level), "small", ink))
		rate.add_child(UI.label(Models.signed(rate_value), "readout", ink))
		rate.add_child(UI.label("/game h", "small", ink))
		observation.add_child(rate)
		var horizon = Models.measurement(data, "eta_game_hours")
		if rate_value < 0 and horizon != null and horizon >= 0:
			var eta = UI.row()
			eta.add_child(UI.label("Estimate", "small", ink))
			eta.add_child(UI.label("%.1f" % horizon, "readout", ink))
			eta.add_child(UI.label("game h · as observed", "small", ink))
			observation.add_child(eta)
		elif rate_value < 0:
			observation.add_child(UI.label("Horizon unavailable", "small", ink))
	else:
		observation.add_child(UI.label(model.rate_copy, "small", ink))
	content.add_child(observation)
	tooltip_text = model.rate_copy
	add_child(content)
