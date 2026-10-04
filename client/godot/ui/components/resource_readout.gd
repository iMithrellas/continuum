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
	queue_redraw()
	if config.get("atlas", false):
		_build_atlas(data, config)
		return
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
	stock.add_child(
		UI.label(
			"%.1f" % model.value if model.value != null else "Unavailable",
			"readout-lg",
			UI.status_color(model.level, "ink")
		)
	)
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


## Equal-share Atlas column. The parent strip should use zero separation.
## Set separator=false on the first column. Declining stock always keeps its
## horizon/availability visible in a wrapping footer, including narrow columns.
func _build_atlas(data: Dictionary, config: Dictionary) -> void:
	var surface = UI.surface("bg-100", "line-100")
	surface.set_corner_radius_all(0)
	surface.set_border_width_all(0)
	surface.set_content_margin_all(0)
	add_theme_stylebox_override("panel", surface)
	custom_minimum_size = Vector2(72, 0)
	size_flags_horizontal = Control.SIZE_EXPAND_FILL
	size_flags_vertical = Control.SIZE_FILL
	var content = UI.column()
	content.add_theme_constant_override("separation", 0)
	var stock = PanelContainer.new()
	stock.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var stock_box = surface.duplicate() as StyleBoxFlat
	stock_box.border_width_left = 1 if config.get("separator", true) else 0
	stock_box.border_color = Color("262a2f")
	stock_box.content_margin_left = 10
	stock_box.content_margin_right = 10
	stock_box.content_margin_top = 8
	stock_box.content_margin_bottom = 9
	stock.add_theme_stylebox_override("panel", stock_box)
	var column = UI.column()
	column.add_theme_constant_override("separation", 0)
	var title = _atlas_label(model.name.capitalize(), 11, false, "ink-muted")
	title.name = "ResourceName"
	column.add_child(title)
	var value = _atlas_label(_stock_copy(model.value, false).trim_suffix(".0"), 17, true, "ink")
	value.name = "ResourceValue"
	value.add_theme_font_override("font", ThemeTokens.font("readout-lg"))
	value.custom_minimum_size.y = 22
	column.add_child(value)
	var rate = Models.measurement(data, "rate_per_game_hour")
	var horizon = Models.measurement(data, "eta_game_hours")
	var rate_copy: String = Models.signed(rate) if rate != null else "No rate"
	if rate == null and Models.text(data, "availability") == "warming":
		rate_copy = "Warming"
	var observation = _atlas_label(rate_copy, 11, true, UI.status_color(model.level))
	observation.name = "ResourceRate"
	column.add_child(observation)
	stock.add_child(column)
	content.add_child(stock)
	if rate != null and rate < 0:
		var warning = PanelContainer.new()
		warning.mouse_filter = Control.MOUSE_FILTER_IGNORE
		var warning_box = stock_box.duplicate() as StyleBoxFlat
		warning_box.border_width_left = 0
		warning_box.border_width_top = 1
		warning_box.content_margin_top = 6
		warning_box.content_margin_bottom = 6
		warning.add_theme_stylebox_override("panel", warning_box)
		var row = UI.row()
		row.add_theme_constant_override("separation", 6)
		var glyph = UI.glyph(model.level if model.level in ["warn", "critical"] else "notice")
		glyph.custom_minimum_size = Vector2(10, 10)
		glyph.size_flags_vertical = Control.SIZE_SHRINK_BEGIN
		row.add_child(glyph)
		var copy := (
			"Estimate %s left" % _horizon_copy(horizon)
			if horizon != null and horizon >= 0
			else "Declining · horizon unavailable"
		)
		if model.level in ["warn", "critical"]:
			copy = UI.status_word(model.level) + " · " + copy
		var label = _atlas_label(copy, 11, false, UI.status_color(model.level))
		label.name = "ResourceWarning"
		label.clip_text = false
		label.text_overrun_behavior = TextServer.OVERRUN_NO_TRIMMING
		label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		row.add_child(label)
		warning.add_child(row)
		content.add_child(warning)
	tooltip_text = (
		"%s stored: %s\n%s"
		% [model.name, str(model.value) if model.value != null else "Unavailable", model.rate_copy]
	)
	add_child(content)


func _atlas_label(copy: String, font_size: int, mono: bool, ink: String) -> Label:
	var label = UI.label(copy, "small", ink)
	label.add_theme_font_override("font", ThemeTokens.font("log" if mono else "body"))
	label.add_theme_font_size_override("font_size", font_size)
	label.add_theme_constant_override("line_spacing", 0)
	label.custom_minimum_size.y = 15
	label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	label.clip_text = true
	label.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	return label


## Optional status-strip presentation; default panel rendering remains unchanged.
func _build_compact(data: Dictionary, config: Dictionary) -> void:
	var surface := UI.surface("bg-100", "line-100", "space-2")
	if config.get("narrow", false):
		surface.content_margin_left = 4
		surface.content_margin_right = 4
	surface.content_margin_top = 4
	surface.content_margin_bottom = 4
	add_theme_stylebox_override("panel", surface)
	custom_minimum_size.y = 44
	size_flags_vertical = Control.SIZE_SHRINK_BEGIN
	var content = UI.column()
	content.add_theme_constant_override("separation", 0)
	content.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	var row = (
		UI.column()
		if config.get("narrow", false) and model.level not in ["warn", "critical"]
		else UI.row()
	)
	row.add_theme_constant_override(
		"separation",
		(
			0
			if row is VBoxContainer
			else (4 if config.get("stack_warning", false) else int(ThemeTokens.number("space-2")))
		)
	)
	var ink = UI.status_color(model.level, "ink-subtle")
	if model.level in ["warn", "critical"]:
		row.add_child(UI.glyph(model.level))
	row.add_child(UI.label(model.name.to_upper(), "small", ink))
	row.add_child(
		UI.label(
			_stock_copy(model.value, config.get("abbreviate_stock", false)),
			"readout",
			UI.status_color(model.level, "ink")
		)
	)
	content.add_child(row)
	var rate = Models.measurement(data, "rate_per_game_hour")
	var horizon = Models.measurement(data, "eta_game_hours")
	if model.level in ["warn", "critical"]:
		var warning = UI.column() if config.get("stack_warning", false) else UI.row()
		if config.get("stack_warning", false):
			warning.add_theme_constant_override("separation", 0)
		warning.add_child(UI.label(UI.status_word(model.level), "small", ink))
		var forecast := (
			"Est " + _horizon_copy(horizon) if horizon != null else "Horizon unavailable"
		)
		if config.get("stack_warning", false):
			forecast = forecast.replace(" game h", "\ngame h").replace(
				"Horizon unavailable", "Horizon\nunavailable"
			)
		warning.add_child(
			UI.label(forecast, "log" if config.get("abbreviate_stock", false) else "readout", ink)
		)
		content.add_child(warning)
	elif rate != null and config.get("show_rate", true):
		var observed = UI.row()
		observed.add_child(UI.label(Models.signed(rate), "readout", "ink-muted"))
		observed.add_child(UI.label("/game h", "small", "ink-muted"))
		content.add_child(observed)
	elif rate == null and config.get("show_rate", true) and not config.get("narrow", false):
		content.add_child(UI.label(model.rate_copy, "small", "ink-muted"))
	tooltip_text = (
		"%s stored: %s\n%s"
		% [model.name, str(model.value) if model.value != null else "Unavailable", model.rate_copy]
	)
	if config.get("abbreviate_stock", false):
		tooltip_text += "\n~ quantities are abbreviated approximations; full stored value is above."
	if rate != null:
		tooltip_text += "\n%s /game h · observed since connection" % Models.signed(rate)
	if horizon != null:
		tooltip_text += "\nEstimate %.1f game hours · as observed" % horizon
	add_child(content)


func _draw() -> void:
	if (
		_config.get("compact", false)
		and not _config.get("atlas", false)
		and model.get("level") in ["warn", "critical"]
	):
		draw_line(
			Vector2(0, size.y - 1), Vector2(size.x, size.y - 1), ThemeTokens.color(model.level), 2
		)


static func _horizon_copy(value: float) -> String:
	return "<0.1 game h" if value > 0.0 and value < 0.1 else "%.1f game h" % value


static func _stock_copy(value: Variant, abbreviated: bool) -> String:
	if value == null:
		return "—"
	if abbreviated:
		if absf(value) >= 1e15:
			return "~%.1e" % value
		for unit: Array in [[1e12, "T"], [1e9, "B"], [1e6, "M"], [1e3, "k"]]:
			if absf(value) >= unit[0] * 10:
				return "~%.1f%s" % [value / unit[0], unit[1]]
	return "%.1f" % value
