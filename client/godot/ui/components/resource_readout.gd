class_name ResourceReadout
extends PanelContainer

const Models = preload("models.gd")
const UI = preload("presentation.gd")
var model: Dictionary = {}
var _input: Dictionary = {}
var _config: Dictionary = {}

## name, value; optional rate_per_game_hour, eta_game_hours, availability.
## config: warn/critical in game hours. No forecast is calculated here.
func set_model(data: Dictionary, config: Dictionary = {}) -> void:
	if data == _input and config == _config and not model.is_empty():
		return
	_input = data.duplicate(true)
	_config = config.duplicate(true)
	model = Models.resource(data, config)
	UI.clear(self)
	if config.get("compact", false):
		_build_compact(data, config)
		return
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

## Optional status-strip presentation; default panel rendering remains unchanged.
func _build_compact(data: Dictionary, config: Dictionary) -> void:
	add_theme_stylebox_override("panel", StyleBoxEmpty.new())
	custom_minimum_size.y = ThemeTokens.number("topbar")
	var content = UI.column()
	content.add_theme_constant_override("separation", 0)
	content.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	var row = UI.column() if config.get("narrow", false) and model.level not in ["warn", "critical"] else UI.row()
	row.add_theme_constant_override("separation", 0 if row is VBoxContainer else int(ThemeTokens.number("space-2")))
	var ink = UI.status_color(model.level, "ink-subtle")
	if model.level in ["warn", "critical"]:
		row.add_child(UI.glyph(model.level))
	row.add_child(UI.label(model.name.to_upper(), "small", ink))
	row.add_child(UI.label(_stock_copy(model.value, config.get("abbreviate_stock", false)), "readout", UI.status_color(model.level, "ink")))
	content.add_child(row)
	var rate = Models.measurement(data, "rate_per_game_hour")
	var horizon = Models.measurement(data, "eta_game_hours")
	if model.level in ["warn", "critical"]:
		var warning = UI.row()
		warning.add_child(UI.label(UI.status_word(model.level), "small", ink))
		warning.add_child(UI.label("Est " + _horizon_copy(horizon) if horizon != null else "Horizon unavailable", "log" if config.get("abbreviate_stock", false) else "readout", ink))
		content.add_child(warning)
	elif rate != null and config.get("show_rate", true):
		var observed = UI.row()
		observed.add_child(UI.label(Models.signed(rate), "readout", "ink-muted"))
		observed.add_child(UI.label("/game h observed", "small", "ink-muted"))
		content.add_child(observed)
	tooltip_text = "%s stored: %s\n%s" % [model.name, str(model.value) if model.value != null else "Unavailable", model.rate_copy]
	if config.get("abbreviate_stock", false): tooltip_text += "\n~ quantities are abbreviated approximations; full stored value is above."
	if rate != null:
		tooltip_text += "\n%s /game h · observed since connection" % Models.signed(rate)
	if horizon != null:
		tooltip_text += "\nEstimate %.1f game hours · as observed" % horizon
	add_child(content)

static func _horizon_copy(value: float) -> String:
	return "<0.1 game h" if value > 0.0 and value < 0.1 else "%.1f game h" % value

static func _stock_copy(value: Variant, abbreviated: bool) -> String:
	if value == null: return "—"
	if abbreviated:
		if absf(value) >= 1e15: return "~%.1e" % value
		for unit: Array in [[1e12, "T"], [1e9, "B"], [1e6, "M"], [1e3, "k"]]:
			if absf(value) >= unit[0] * 10:
				return "~%.1f%s" % [value / unit[0], unit[1]]
	return "%.1f" % value
