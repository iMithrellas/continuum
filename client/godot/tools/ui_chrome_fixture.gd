## Backend-free chrome fixture. Never instantiate main or connect an SDK client.
## Component/map composition will be added after their announced commits land.
extends Control

const Icons = preload("res://ui/theme/icons.gd")
var _failures: Array[String] = []
var _capture := ""
var _problem := false
var _reduced_motion := false
var _focus := false
var _bar: DiagnosticsBar
var _focus_control: Button


func _ready() -> void:
	var screen := Vector2i(1440, 900)
	var scale := 1.0
	for argument: String in OS.get_cmdline_user_args():
		if argument.begins_with("--screen="):
			var parts := argument.trim_prefix("--screen=").split("x")
			screen = Vector2i(int(parts[0]), int(parts[1]))
		elif argument.begins_with("--scale="):
			scale = float(argument.trim_prefix("--scale=")) / 100.0
		elif argument == "--status=problem":
			_problem = true
		elif argument == "--reduced-motion":
			_reduced_motion = true
		elif argument == "--focus":
			_focus = true
		elif argument.begins_with("--capture="):
			_capture = argument.trim_prefix("--capture=")
	get_window().size = screen
	get_window().content_scale_mode = Window.CONTENT_SCALE_MODE_CANVAS_ITEMS
	get_window().content_scale_size = Vector2i.ZERO
	get_window().content_scale_factor = scale
	theme = DeckTheme.create()
	_build_chrome()
	await get_tree().process_frame
	await get_tree().process_frame
	_check_typography(self)
	_check(_bar.mouse_filter == Control.MOUSE_FILTER_IGNORE, "inline diagnostics stays input transparent")
	_check(_bar.session_rtt_text() == "TCP RTT N/A", "HTTP/reducer sample cannot become TCP RTT")
	if _focus:
		_check(get_viewport().gui_get_focus_owner() == _focus_control, "focus case actually owns keyboard focus")
	_check(_contrast(ThemeTokens.color("critical"), ThemeTokens.color("critical-soft")) >= 4.5, "selected critical text retains contrast on its status ground")
	for name: String in Icons.NAMES:
		for token: String in Icons.TOKENS:
			var texture: Texture2D = Icons.texture(name, token)
			_check(texture != null and texture.get_size() == Vector2(16, 16), "16 logical pixel interface icon " + name)
			_check(_icon_uses_token(texture, token), "interface icon uses token, not black currentColor fallback " + name)
	if not _capture.is_empty() and DisplayServer.get_name() != "headless":
		await RenderingServer.frame_post_draw
		var image := get_viewport().get_texture().get_image()
		_check(image.get_size() == screen, "capture matches actual requested viewport")
		_check(image.save_png(_capture) == OK, "viewport capture saves")
	if _failures.is_empty():
		print("UI_INTEGRATION_FIXTURE_PASS screen=%s scale=%.2f status=%s reduced_motion=%s focus=%s phase=chrome" % [screen, scale, "problem" if _problem else "nominal", _reduced_motion, _focus])
	else:
		for failure: String in _failures:
			push_error(failure)
	get_tree().quit(0 if _failures.is_empty() else 1)


func _build_chrome() -> void:
	var background := ColorRect.new()
	background.color = ThemeTokens.color("bg-000")
	background.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(background)
	background.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	var column := VBoxContainer.new()
	column.add_theme_constant_override("separation", 0)
	add_child(column)
	column.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	var top := HBoxContainer.new()
	top.custom_minimum_size.y = ThemeTokens.number("topbar")
	column.add_child(top)
	var title := _label("Chrome fixture · synthetic observations", "body-strong")
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	top.add_child(title)
	_bar = DiagnosticsBar.new()
	_bar.custom_minimum_size = Vector2(280, 40)
	top.add_child(_bar)
	_bar.configure(true, true)
	_bar.set_snapshots({"ready": true, "mean_fps": 60.0, "p95_frame_ms": 16.7, "frame_graph": [{"tick": 0, "value": 16.0}, {"tick": 1, "value": null}, {"tick": 2, "value": 17.0}]}, {"source": "http", "rtt_ms": 7.0})
	var tabs := HBoxContainer.new()
	tabs.custom_minimum_size.y = ThemeTokens.number("panel-header")
	column.add_child(tabs)
	var selected := Button.new()
	selected.text = "Owned chrome"
	selected.theme_type_variation = "ButtonQuiet"
	tabs.add_child(selected)
	var settings := Button.new()
	settings.icon = Icons.texture("settings")
	settings.tooltip_text = "Settings icon fixture"
	tabs.add_child(settings)
	var margin := MarginContainer.new()
	for side: String in ["left", "right", "top", "bottom"]:
		margin.add_theme_constant_override("margin_" + side, int(ThemeTokens.number("space-4")))
	margin.size_flags_vertical = Control.SIZE_EXPAND_FILL
	column.add_child(margin)
	var panel := PanelContainer.new()
	margin.add_child(panel)
	var body := VBoxContainer.new()
	panel.add_child(body)
	body.add_child(_label("Session history · locally observed · synthetic fixture", "body-strong"))
	var chart := HistoryChart.new()
	chart.size_flags_vertical = Control.SIZE_EXPAND_FILL
	body.add_child(chart)
	chart.set_points([{"seconds": 0.0, "values": {"mood": 70.0, "productivity": 65.0}}, {"seconds": 60.0, "values": {"mood": 68.0}}, {"seconds": 120.0, "values": {"mood": 69.0, "productivity": 63.0}}, {"seconds": 3600.0, "values": {"mood": 72.0, "productivity": 64.0}}])
	var row := PanelContainer.new()
	var style := DeckTheme.box(ThemeTokens.color("critical-soft" if _problem else "bg-200"), ThemeTokens.color("accent" if _focus else "line-100"), 12)
	row.add_theme_stylebox_override("panel", style)
	body.add_child(row)
	var actions := HBoxContainer.new()
	row.add_child(actions)
	var glyph := TextureRect.new()
	glyph.custom_minimum_size = Vector2(16, 16)
	glyph.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	glyph.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	glyph.texture = ThemeTokens.glyph("critical" if _problem else "notice")
	actions.add_child(glyph)
	var status := _label("Critical · selected contrast fixture" if _problem else "Nominal · no active alerts", "body")
	status.add_theme_color_override("font_color", ThemeTokens.color("critical" if _problem else "ink-muted"))
	status.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	actions.add_child(status)
	var command := Button.new()
	_focus_control = command
	command.text = "Inspect fixture"
	command.icon = Icons.texture("locate")
	actions.add_child(command)
	if _focus:
		command.grab_focus.call_deferred()
	body.add_child(_label("Phase 2 chrome only · component pulse and colony composition await dependency handoffs", "small"))


func _label(text: String, style: String) -> Label:
	var label := Label.new()
	label.text = text
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	ThemeTokens.apply_label(label, style)
	return label


func _check_typography(node: Node) -> void:
	if node is Label or node is Button:
		_check(node.get_theme_font_size("font_size") >= 11, "no text below 11 logical pixels")
	for child: Node in node.get_children():
		_check_typography(child)


func _check(condition: bool, message: String) -> void:
	if not condition:
		_failures.append(message)


func _icon_uses_token(texture: Texture2D, token: String) -> bool:
	if texture == null:
		return false
	var image := texture.get_image()
	var expected := ThemeTokens.color(token)
	var opaque_pixels := 0
	for y in image.get_height():
		for x in image.get_width():
			var pixel := image.get_pixel(x, y)
			if pixel.a > 0.9:
				opaque_pixels += 1
				if absf(pixel.r - expected.r) > 0.01 or absf(pixel.g - expected.g) > 0.01 or absf(pixel.b - expected.b) > 0.01:
					return false
	return opaque_pixels > 0


func _contrast(a: Color, b: Color) -> float:
	var first := _luminance(a)
	var second := _luminance(b)
	return (maxf(first, second) + 0.05) / (minf(first, second) + 0.05)


func _luminance(color: Color) -> float:
	var linear := color.srgb_to_linear()
	return linear.r * 0.2126 + linear.g * 0.7152 + linear.b * 0.0722
