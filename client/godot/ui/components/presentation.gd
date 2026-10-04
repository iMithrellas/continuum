extends RefCounted
## Shared construction helpers, deliberately independent of game state.


static func label(copy: String, style: String = "body", ink: String = "ink-muted") -> Label:
	var node = Label.new()
	node.mouse_filter = Control.MOUSE_FILTER_IGNORE
	node.text = copy
	ThemeTokens.apply_label(node, style)
	node.add_theme_color_override("font_color", ThemeTokens.color(ink))
	return node


static func wrapped(copy: String, style: String = "small", ink: String = "ink-muted") -> Label:
	var node = label(copy, style, ink)
	node.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	node.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	return node


static func bounded(copy: String, style: String, ink: String, width: float) -> Label:
	var node = label(copy, style, ink)
	node.clip_text = true
	node.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	node.custom_minimum_size.x = width
	node.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	node.tooltip_text = copy
	return node


static func flow() -> HFlowContainer:
	var node = HFlowContainer.new()
	node.add_theme_constant_override("h_separation", int(ThemeTokens.number("space-2")))
	node.add_theme_constant_override("v_separation", int(ThemeTokens.number("space-1")))
	return node


static func glyph(kind: String) -> TextureRect:
	var node = TextureRect.new()
	node.mouse_filter = Control.MOUSE_FILTER_IGNORE
	node.texture = ThemeTokens.glyph(kind)
	node.custom_minimum_size = Vector2(16, 16)
	node.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	node.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	node.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	node.tooltip_text = kind.capitalize()
	return node


static func status_color(level: String, nominal: String = "ink-muted") -> String:
	return level if level in ["warn", "critical"] else nominal


static func status_word(level: String) -> String:
	return "Warning" if level == "warn" else "Critical" if level == "critical" else "Nominal"


static func row() -> HBoxContainer:
	var node = HBoxContainer.new()
	node.add_theme_constant_override("separation", int(ThemeTokens.number("space-2")))
	return node


static func column() -> VBoxContainer:
	var node = VBoxContainer.new()
	node.add_theme_constant_override("separation", int(ThemeTokens.number("space-2")))
	return node


static func button(copy: String, callback: Callable, variant: String = "ButtonQuiet") -> Button:
	var node = Button.new()
	node.text = copy
	node.clip_text = true
	node.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	node.tooltip_text = copy
	var padding = ThemeTokens.number("space-3")
	var text_width = (
		ThemeTokens
		. font("body")
		. get_string_size(copy, HORIZONTAL_ALIGNMENT_LEFT, -1, ThemeTokens.font_size("body"))
		. x
	)
	node.custom_minimum_size.x = minf(
		text_width + 2 * padding, ThemeTokens.number("panel-min") - 4 * padding
	)
	node.theme_type_variation = variant
	node.custom_minimum_size.y = ThemeTokens.number("control-md")
	node.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	node.pressed.connect(callback)
	return node


static func surface(
	ground: String = "bg-100", border: String = "line-100", padding: String = "space-3"
) -> StyleBoxFlat:
	var box = StyleBoxFlat.new()
	box.bg_color = ThemeTokens.color(ground)
	box.border_color = ThemeTokens.color(border)
	box.set_border_width_all(1)
	box.set_corner_radius_all(int(ThemeTokens.number("radius-md")))
	box.set_content_margin_all(ThemeTokens.number(padding))
	return box


static func clear(node: Node) -> void:
	for child in node.get_children():
		node.remove_child(child)
		child.queue_free()


static func coverage_notice(subject: String, coverage: Dictionary) -> VBoxContainer:
	var content = column()
	var head = row()
	head.add_child(glyph("notice"))
	head.add_child(
		wrapped(subject + (" coverage partial" if coverage.status == "partial" else " unavailable"))
	)
	content.add_child(head)
	if coverage.rejected_count > 0:
		var rejected = row()
		rejected.add_child(label(str(coverage.rejected_count), "readout"))
		rejected.add_child(wrapped("Rows rejected · coverage incomplete"))
		content.add_child(rejected)
	if not coverage.copy.is_empty():
		content.add_child(wrapped(coverage.copy))
	return content


static func tag(
	copy: String, level: String = "notice", automation: bool = false, width: float = 120
) -> PanelContainer:
	var node = PanelContainer.new()
	node.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var ink = "accent" if automation else status_color(level)
	var ground = level + "-soft" if level in ["warn", "critical"] else "bg-200"
	var box = surface(
		ground, ink if automation or level in ["warn", "critical"] else "line-200", "space-1"
	)
	box.set_corner_radius_all(int(ThemeTokens.number("radius-sm")))
	box.content_margin_top = 0
	box.content_margin_bottom = 0
	node.add_theme_stylebox_override("panel", box)
	var content = row()
	content.mouse_filter = Control.MOUSE_FILTER_IGNORE
	content.add_theme_constant_override("separation", int(ThemeTokens.number("space-1")))
	var label_width = width - 2 * ThemeTokens.number("space-1")
	if level in ["warn", "critical"]:
		content.add_child(glyph(level))
		label_width -= 16 + ThemeTokens.number("space-1")
	node.tooltip_text = (status_word(level) + " · " if level in ["warn", "critical"] else "") + copy
	content.add_child(bounded(copy, "tag", ink, maxf(0, label_width)))
	node.add_child(content)
	return node
