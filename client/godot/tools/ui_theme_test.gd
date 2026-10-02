extends SceneTree
const Tokens = preload("res://ui/theme/theme_tokens.gd")
const Generator = preload("res://ui/theme/generate_theme.gd")
var failures := 0

func check(ok: bool, message: String) -> void:
	if not ok:
		failures += 1
		push_error(message)

func luminance(c: Color) -> float:
	return c.srgb_to_linear().r * 0.2126 + c.srgb_to_linear().g * 0.7152 + c.srgb_to_linear().b * 0.0722

func contrast(a: Color, b: Color) -> float:
	return (maxf(luminance(a), luminance(b)) + 0.05) / (minf(luminance(a), luminance(b)) + 0.05)

func _initialize() -> void:
	if "--packaged" in OS.get_cmdline_user_args():
		check(not FileAccess.file_exists(Tokens.ROOT + "tokens.json"), "Packaged fixture omits raw JSON")
		check(Tokens.number("space-3") == 12 and Tokens.font_size("body") == 13, "Packaged token fallback")
		check(Tokens.color("meter-track") == Tokens.color("bg-300"), "Packaged alias")
		check(Tokens.font("body").get_font_name().begins_with("IBM Plex"), "Packaged font")
		print("UI packaged fallback tests: ", failures, " failures")
		quit(1 if failures else 0)
		return
	check(Tokens.resolve({"a": "{b}", "b": "{c}", "c": "12px"}, "a").get("value") == "12px", "Chained alias")
	for values: Dictionary in [{"a": "{a}"}, {"a": "{b}", "b": "{a}"}, {"a": "{missing}"}, {"a": "{broken"}, {"a": 12}]:
		check(Tokens.resolve(values, "a").has("error"), "Invalid alias must fail: " + str(values))
	for raw: String in ["-1px", "NaN", "12em", "12pxpx", "no"]:
		check(Tokens.parse_number(raw).has("error"), "Invalid numeric token " + raw)
	check(Tokens.number("radius-0") == 0 and Tokens.number("space-3") == 12, "Numbers")
	check(Tokens.color("meter-track") == Tokens.color("bg-300"), "Canonical alias")
	var data: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(Tokens.ROOT + "tokens.json"))
	check(Tokens.validate(data).is_empty(), "Full token validation")
	check(not Tokens.validate(null).is_empty(), "Reject non-object tokens")
	# Exercise every required name, not just the first token in a family.
	for family: String in Tokens.REQUIRED_TOKENS:
		for name: String in Tokens.REQUIRED_TOKENS[family]:
			var missing := data.duplicate(true)
			for index in range(missing[family].tokens.size() - 1, -1, -1):
				if missing[family].tokens[index].name == name:
					missing[family].tokens.remove_at(index)
			check(not Tokens.validate(missing).is_empty(), "Reject missing required " + name)
	var no_shadows := data.duplicate(true)
	no_shadows.shadow.tokens.clear()
	check(not Tokens.validate(no_shadows).is_empty(), "Reject empty shadow family")
	for name: String in Tokens.VARIANTS:
		var missing_style := data.duplicate(true)
		for group: Dictionary in missing_style.type.groups:
			for index in range(group.styles.size() - 1, -1, -1):
				if group.styles[index].name == name:
					group.styles.remove_at(index)
		check(not Tokens.validate(missing_style).is_empty(), "Reject missing style " + name)
	for weight: Variant in [600, 600.0]:
		var valid_weight := data.duplicate(true)
		valid_weight.type.groups[0].styles[0].fontWeight = weight
		check(Tokens.validate(valid_weight).is_empty(), "Accept integral weight " + str(weight))
	for weight: Variant in [600.5, NAN, INF, -INF, "600", null, true, 0, 1001]:
		var bad_weight := data.duplicate(true)
		bad_weight.type.groups[0].styles[0].fontWeight = weight
		check(not Tokens.validate(bad_weight).is_empty(), "Reject corrupt weight " + str(weight))
	for change: String in ["alias", "radius", "size", "font", "tracking", "duplicate"]:
		var bad := data.duplicate(true)
		match change:
			"alias": bad.color.tokens[0].value = "{missing}"
			"radius": bad.radius.tokens[0].value = "3px"
			"size": bad.type.groups[0].styles[0].fontSize = "10px"
			"font": bad.type.fonts[0].file = "../outside.woff2"
			"tracking": bad.type.groups[1].styles[0].letterSpacing = "NaNem"
			"duplicate": bad.color.tokens.append(bad.color.tokens[0])
		check(not Tokens.validate(bad).is_empty(), "Reject " + change)
	var theme: Theme = load(Tokens.ROOT + "theme.tres")
	check(theme.get_meta("theme_tokens_json") == FileAccess.get_file_as_string(Tokens.ROOT + "tokens.json"), "Packaged token source is exact")
	check(theme.get_meta("theme_font_license") == FileAccess.get_file_as_string(Tokens.ROOT + "fonts/OFL.txt"), "Packaged OFL retained")
	check(str(theme.get_meta("theme_font_license")).sha256_text() == "7e6b2818edbd8f6a01ae80641cc8f16a51080d08fb4e532be3a0b6f74adb07da", "Packaged OFL canonical byte hash")
	check(theme.default_font_size == 13, "Base 13px")
	check(Tokens.font("section") is FontVariation and Tokens.font("section").spacing_glyph == 1, "Section token tracking")
	check(Tokens.font("tag") is FontVariation and Tokens.font("display") is FontVariation, "Condensed tracking variations")
	for style: String in Tokens.VARIANTS:
		var variant: String = Tokens.VARIANTS[style]
		check(theme.get_type_variation_base(variant) == "Label", variant + " base")
		check(theme.get_font_size("font_size", variant) == Tokens.font_size(style) and Tokens.font_size(style) >= 11, variant + " size")
		check(theme.get_font("font", variant).get_font_name().begins_with("IBM Plex"), variant + " actual font import")
		check(theme.get_font("font", variant).has_char(0x2212), variant + " true minus")
		check(contrast(theme.get_color("font_color", variant), Tokens.color("bg-100")) >= 4.5, variant + " contrast")
		var label := Label.new()
		Tokens.apply_label(label, style)
		check(label.uppercase == (style in ["section", "tag"]), "Case " + style)
		check(label.custom_minimum_size.y == Tokens.line_height(style), "Line height " + style)
		label.free()
	for type: String in ["Button", "ButtonPrimary", "ButtonQuiet", "ButtonCritical", "ButtonIcon"]:
		for state: String in ["normal", "hover", "pressed", "disabled"]:
			var box: StyleBoxFlat = theme.get_stylebox(state, type)
			var text: String = {"normal": "font_color", "hover": "font_hover_color", "pressed": "font_pressed_color", "disabled": "font_disabled_color"}[state]
			check(contrast(theme.get_color(text, type), box.bg_color if box.bg_color.a > 0 else Tokens.color("bg-100")) >= 4.5, type + " " + state + " text contrast")
			check(box.corner_radius_top_left in [0, 2, 4], type + " radius")
			check(box.shadow_size == 0, type + " no shadow")
			if type == "ButtonPrimary" and state != "disabled":
				check(box.bg_color == Tokens.color("accent"), "Primary fill in " + state)
			if type == "ButtonCritical" and state != "disabled":
				check(box.bg_color != Tokens.color("critical"), "Critical never solid")
		var focus: StyleBox = theme.get_stylebox("focus", type)
		check(focus.casing.border_color == Tokens.color("bg-000") and focus.casing.border_width_left == 1, "Desk focus gap")
		check(focus.ring.border_color == Tokens.color("accent") and focus.ring.border_width_left == 2 and focus.ring.expand_margin_left == 3, "Accent focus ring")
	for type: String in ["ProgressBar", "MeterWarn", "MeterCritical"]:
		check(theme.get_stylebox("background", type).bg_color == Tokens.color("meter-track"), "Meter track")
		check(theme.get_stylebox("fill", type).bg_color == Tokens.color("warn" if type == "MeterWarn" else "critical" if type == "MeterCritical" else "meter-fill"), "Meter fill")
	check(theme.get_stylebox("panel", "PanelHeader").bg_color == Tokens.color("bg-200"), "Header ground")
	check(theme.get_stylebox("panel", "PanelContainer").shadow_size == 0, "Docked panels have no shadow")
	var canvas := RenderingServer.canvas_item_create()
	for type: String in ["PanelFloating", "PopupMenu", "AcceptDialog", "TooltipPanel"]:
		var panel: StyleBox = theme.get_stylebox("panel", type)
		check(panel.shadows.size() == 2 and panel.shadows[0].shadow_size == 6 and panel.shadows[1].shadow_size == 28, "Both floating shadows " + type)
		panel.draw(canvas, Rect2(0, 0, 280, 100))
	theme.get_stylebox("focus", "ButtonPrimary").draw(canvas, Rect2(0, 0, 120, 28))
	RenderingServer.free_rid(canvas)
	for ground: String in ["bg-000", "bg-100", "bg-200", "bg-300", "bg-400", "accent-soft", "warn-soft", "critical-soft"]:
		for ink: String in ["ink", "ink-muted", "ink-subtle", "accent", "warn", "critical"]:
			var allowed := not (ink == "ink-subtle" and ground == "bg-400") and not (ink == "critical" and ground in ["bg-300", "bg-400", "accent-soft"])
			check((contrast(Tokens.color(ink), Tokens.color(ground)) >= 4.5) == allowed, ink + "/" + ground + " contrast restriction")
	for name: String in ["notice", "warn", "critical", "ack", "auto", "player"]:
		check(Tokens.glyph(name).get_size() == Vector2(16, 16), "Glyph " + name)
	check(DeckTheme.create().default_font_size == 13, "Legacy create logical units")
	print("UI theme tests: ", failures, " failures")
	quit(1 if failures else 0)
