extends SceneTree
## Run headlessly after import. Never hand-edit theme.tres.
const Tokens = preload("res://ui/theme/theme_tokens.gd")
const FocusRing = preload("res://ui/theme/focus_ring.gd")
const FloatingBox = preload("res://ui/theme/floating_box.gd")


static func box(bg: String, border := "", radius := "radius-sm", pad := 0.0) -> StyleBoxFlat:
	var s := StyleBoxFlat.new()
	s.bg_color = Tokens.color(bg) if bg != "" else Color.TRANSPARENT
	if border != "":
		s.border_color = Tokens.color(border)
		s.set_border_width_all(1)
	s.set_corner_radius_all(int(Tokens.number(radius)))
	s.content_margin_left = pad
	s.content_margin_right = pad
	s.content_margin_top = Tokens.number("space-1")
	s.content_margin_bottom = Tokens.number("space-1")
	return s


static func focus() -> StyleBox:
	var result := FocusRing.new()
	var layers := Tokens.shadow("focus-ring")
	result.casing = box("", "bg-000")
	result.casing.draw_center = false
	result.casing.border_color = layers[0].color
	result.casing.set_border_width_all(int(layers[0].spread))
	result.casing.set_expand_margin_all(layers[0].spread)
	result.ring = box("", "accent")
	result.ring.draw_center = false
	result.ring.border_color = layers[1].color
	result.ring.set_border_width_all(int(layers[1].spread - layers[0].spread))
	result.ring.set_expand_margin_all(layers[1].spread)
	return result


static func floating() -> StyleBox:
	var result := FloatingBox.new()
	result.body = box("bg-100", "line-200", "radius-md", Tokens.number("space-3"))
	for spec: Dictionary in Tokens.shadow("shadow-float"):
		var layer := box("bg-100", "", "radius-md")
		layer.shadow_color = spec.color
		layer.shadow_offset = spec.offset
		layer.shadow_size = int(spec.blur)
		result.shadows.append(layer)
	result.content_margin_left = Tokens.number("space-3")
	result.content_margin_right = Tokens.number("space-3")
	result.content_margin_top = Tokens.number("space-3")
	result.content_margin_bottom = Tokens.number("space-3")
	return result


static func build() -> Theme:
	var th := Theme.new()
	th.set_meta("theme_tokens_json", FileAccess.get_file_as_string(Tokens.ROOT + "tokens.json"))
	th.set_meta("theme_font_license", FileAccess.get_file_as_string(Tokens.ROOT + "fonts/OFL.txt"))
	th.default_font = Tokens.font("body")
	th.default_font_size = Tokens.font_size("body")
	for style: String in Tokens.VARIANTS:
		var variant: String = Tokens.VARIANTS[style]
		th.set_type_variation(variant, "Label")
		th.set_font("font", variant, Tokens.font(style))
		th.set_font_size("font_size", variant, Tokens.font_size(style))
		th.set_color(
			"font_color",
			variant,
			Tokens.color(
				(
					"ink-subtle"
					if style in ["section", "log"]
					else "ink-muted" if style in ["small", "tag"] else "ink"
				)
			)
		)
		th.set_constant(
			"line_spacing",
			variant,
			(
				Tokens.line_height(style)
				- ceili(Tokens.font(style).get_height(Tokens.font_size(style)))
			)
		)
	th.set_color("font_color", "Label", Tokens.color("ink"))
	th.set_color("default_color", "RichTextLabel", Tokens.color("ink"))
	th.set_stylebox(
		"panel", "PanelContainer", box("bg-100", "line-100", "radius-md", Tokens.number("space-3"))
	)
	th.set_type_variation("PanelHeader", "PanelContainer")
	th.set_stylebox("panel", "PanelHeader", box("bg-200", "", "radius-0", Tokens.number("space-3")))
	th.set_type_variation("PanelFloating", "PanelContainer")
	th.set_stylebox("panel", "PanelFloating", floating())
	for type: String in [
		"Button",
		"OptionButton",
		"MenuButton",
		"ButtonPrimary",
		"ButtonQuiet",
		"ButtonCritical",
		"ButtonIcon"
	]:
		if type.begins_with("Button") and type != "Button":
			th.set_type_variation(type, "Button")
		th.set_font("font", type, Tokens.font("body"))
		th.set_font_size("font_size", type, Tokens.font_size("body"))
		for state: String in ["normal", "hover", "pressed", "disabled"]:
			var bg: String = {
				"normal": "bg-300", "hover": "bg-400", "pressed": "bg-200", "disabled": "bg-200"
			}[state]
			var ink := "ink-subtle" if state == "disabled" else "ink"
			var border := "line-100" if state == "disabled" else "line-200"
			if type == "ButtonPrimary" and state != "disabled":
				bg = "accent"
				ink = "on-accent"
				border = "accent"
			elif type == "ButtonCritical" and state != "disabled":
				bg = "critical-soft" if state != "normal" else "bg-100"
				ink = "critical"
				border = "critical"
			elif type in ["ButtonQuiet", "ButtonIcon"] and state != "disabled":
				bg = "" if state == "normal" else "bg-300" if state == "hover" else "bg-200"
				ink = "accent" if state == "pressed" else "ink" if state == "hover" else "ink-muted"
				border = "" if state == "normal" else "accent" if state == "pressed" else "line-200"
			th.set_stylebox(
				state,
				type,
				box(
					bg,
					border,
					"radius-sm",
					Tokens.number("space-1" if type == "ButtonIcon" else "space-3")
				)
			)
			th.set_color(
				{
					"normal": "font_color",
					"hover": "font_hover_color",
					"pressed": "font_pressed_color",
					"disabled": "font_disabled_color"
				}[state],
				type,
				Tokens.color(ink)
			)
		th.set_color("font_focus_color", type, th.get_color("font_color", type))
		th.set_stylebox("focus", type, focus())
	for type: String in ["ProgressBar", "MeterWarn", "MeterCritical"]:
		if type != "ProgressBar":
			th.set_type_variation(type, "ProgressBar")
		th.set_font("font", type, Tokens.font("readout"))
		th.set_font_size("font_size", type, Tokens.font_size("readout"))
		th.set_color("font_color", type, Tokens.color("ink"))
		th.set_stylebox("background", type, box("meter-track"))
		th.set_stylebox(
			"fill",
			type,
			box(
				(
					"warn"
					if type == "MeterWarn"
					else "critical" if type == "MeterCritical" else "meter-fill"
				)
			)
		)
	th.set_stylebox(
		"normal", "LineEdit", box("bg-300", "line-200", "radius-sm", Tokens.number("space-2"))
	)
	th.set_stylebox("focus", "LineEdit", focus())
	th.set_color("font_color", "LineEdit", Tokens.color("ink"))
	th.set_color("font_placeholder_color", "LineEdit", Tokens.color("ink-subtle"))
	for type: String in ["PopupMenu", "AcceptDialog", "TooltipPanel"]:
		th.set_stylebox("panel", type, floating())
	for type: String in ["HBoxContainer", "VBoxContainer"]:
		th.set_constant("separation", type, int(Tokens.number("space-2")))
	return th


func _initialize() -> void:
	if not Tokens._ensure():
		quit(1)
		return
	var error := ResourceSaver.save(build(), Tokens.ROOT + "theme.tres")
	if error == OK:
		# ResourceSaver invents random IDs. Canonicalize headers and references
		# in first-appearance order so separate processes produce identical bytes.
		var text := FileAccess.get_file_as_string(Tokens.ROOT + "theme.tres")
		var pattern := RegEx.new()
		pattern.compile('id="([^"]+)"')
		var index := 0
		for match_result: RegExMatch in pattern.search_all(text):
			index += 1
			text = text.replace('"' + match_result.get_string(1) + '"', '"theme_%03d"' % index)
		var file := FileAccess.open(Tokens.ROOT + "theme.tres", FileAccess.WRITE)
		file.store_string(text)
	print("UI theme generation: ", error_string(error))
	quit(error)
