class_name DeckTheme
extends RefCounted

const PANEL_GROUND := Color("1a1d21")
const LINE := Color("30353b")
const ACCENT := Color("5cc6bd")
const MUTED := Color("b0b6bd")

static func box(color: Color, border := LINE, padding := 8) -> StyleBoxFlat:
	var style := StyleBoxFlat.new()
	style.bg_color = color
	style.border_color = border
	style.set_border_width_all(1)
	style.set_corner_radius_all(int(ThemeTokens.number("radius-md")))
	style.content_margin_left = padding
	style.content_margin_right = padding
	style.content_margin_top = padding
	style.content_margin_bottom = padding
	return style

static func create(_metrics := UiMetrics.new()) -> Theme:
	return load(ThemeTokens.ROOT + "theme.tres").duplicate(true) as Theme
