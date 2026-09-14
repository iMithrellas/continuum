class_name DeckTheme
extends RefCounted

const INK := Color("292722")
const LINE := Color("716b5f")
const ACCENT := Color("b07b4f")
const MUTED := Color("9a9183")


static func box(color: Color, border := LINE, padding := 8) -> StyleBoxFlat:
	var style := StyleBoxFlat.new()
	style.bg_color = color
	style.border_color = border
	style.set_border_width_all(1)
	style.set_corner_radius_all(4)
	style.content_margin_left = padding
	style.content_margin_right = padding
	style.content_margin_top = padding
	style.content_margin_bottom = padding
	return style


static func create(metrics := UiMetrics.new()) -> Theme:
	var result := Theme.new()
	result.default_font_size = metrics.base_font_size
	result.set_color("font_color", "Label", Color("e8e1d5"))
	result.set_color("default_color", "RichTextLabel", Color("ddd5c8"))
	result.set_stylebox("panel", "PanelContainer", box(INK))
	for type: String in ["Button", "OptionButton", "MenuButton"]:
		for state: String in ["normal", "hover", "pressed", "disabled"]:
			var color: Color = {"normal": Color("1a2a36"), "hover": Color("263e4c"),
				"pressed": Color("5c493b"), "disabled": Color("332f2a")}[state]
			result.set_stylebox(state, type, box(color, ACCENT if state == "pressed" else LINE, metrics.px(6)))
		result.set_stylebox("focus", type, box(Color.TRANSPARENT, ACCENT, 0))
		result.set_color("font_color", type, Color("cbdce5"))
		result.set_color("font_hover_color", type, Color.WHITE)
		result.set_color("font_pressed_color", type, Color("98f2e4"))
		result.set_color("font_disabled_color", type, Color("627782"))
	result.set_stylebox("normal", "LineEdit", box(Color("211f1b")))
	result.set_stylebox("focus", "LineEdit", box(Color("211f1b"), ACCENT))
	result.set_stylebox("background", "ProgressBar", box(Color("211f1b"), Color("211f1b"), 0))
	result.set_stylebox("panel", "PopupMenu", box(INK))
	result.set_stylebox("panel", "AcceptDialog", box(INK))
	result.set_stylebox("panel", "TooltipPanel", box(INK, ACCENT))
	result.set_constant("separation", "VBoxContainer", metrics.px(8))
	result.set_constant("separation", "HBoxContainer", metrics.px(6))
	return result
