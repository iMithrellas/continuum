## Interface icons only. Status glyphs remain ThemeTokens.glyph().
class_name UiIcons
extends RefCounted

const NAMES := [
	"arrow-left",
	"camera-fit",
	"chevron-down",
	"chevron-left",
	"chevron-right",
	"chevron-up",
	"close",
	"locate",
	"menu",
	"minimize",
	"pin-off",
	"pin",
	"plus",
	"search",
	"settings",
	"box",
	"users",
	"alert",
	"activity",
	"chart",
	"overview",
	"zones",
	"hammer",
	"code",
]
const ATLAS_NAMES := [
	"box", "users", "alert", "activity", "chart", "overview", "zones", "hammer", "code"
]
const TOKENS := ["ink-muted", "ink", "accent", "on-accent"]
## Embedded geometry also survives exports, which omit arbitrary SVG source text.
const GEOMETRY := {
	"arrow-left": '<path d="m12 19-7-7 7-7"/><path d="M19 12H5"/>',
	"camera-fit":
	'<path d="M3 7V5a2 2 0 0 1 2-2h2"/><path d="M17 3h2a2 2 0 0 1 2 2v2"/><path d="M21 17v2a2 2 0 0 1-2 2h-2"/><path d="M7 21H5a2 2 0 0 1-2-2v-2"/>',
	"chevron-down": '<path d="m6 9 6 6 6-6"/>',
	"chevron-left": '<path d="m15 18-6-6 6-6"/>',
	"chevron-right": '<path d="m9 18 6-6-6-6"/>',
	"chevron-up": '<path d="m18 15-6-6-6 6"/>',
	"close": '<path d="M18 6 6 18"/><path d="m6 6 12 12"/>',
	"locate":
	'<line x1="2" x2="5" y1="12" y2="12"/><line x1="19" x2="22" y1="12" y2="12"/><line x1="12" x2="12" y1="2" y2="5"/><line x1="12" x2="12" y1="19" y2="22"/><circle cx="12" cy="12" r="7"/>',
	"menu": '<path d="M4 5h16"/><path d="M4 12h16"/><path d="M4 19h16"/>',
	"minimize":
	'<path d="M8 3v3a2 2 0 0 1-2 2H3"/><path d="M21 8h-3a2 2 0 0 1-2-2V3"/><path d="M3 16h3a2 2 0 0 1 2 2v3"/><path d="M16 21v-3a2 2 0 0 1 2-2h3"/>',
	"pin-off":
	'<path d="M12 17v5"/><path d="M15 9.34V7a1 1 0 0 1 1-1 2 2 0 0 0 0-4H7.89"/><path d="m2 2 20 20"/><path d="M9 9v1.76a2 2 0 0 1-1.11 1.79l-1.78.9A2 2 0 0 0 5 15.24V16a1 1 0 0 0 1 1h11"/>',
	"pin":
	(
		'<path d="M12 17v5"/><path d="M9 10.76a2 2 0 0 1-1.11 1.79l-1.78.9A2 2 0 0 0 5 15.24V16a1 1 0 0 0 1 1h12'
		+ "a1 1 0 0 0 1-1v-.76a2 2 0 0 0-1.11-1.79l-1.78-.9A2 2 0 0 1 15 10.76V7"
		+ 'a1 1 0 0 1 1-1 2 2 0 0 0 0-4H8a2 2 0 0 0 0 4 1 1 0 0 1 1 1z"/>'
	),
	"plus": '<path d="M5 12h14"/><path d="M12 5v14"/>',
	"search": '<path d="m21 21-4.34-4.34"/><circle cx="11" cy="11" r="8"/>',
	"settings":
	(
		'<path d="M9.671 4.136a2.34 2.34 0 0 1 4.659 0 2.34 2.34 0 0 0 3.319 1.915'
		+ " 2.34 2.34 0 0 1 2.33 4.033 2.34 2.34 0 0 0 0 3.831 2.34 2.34 0 0 1-2.33 4.033"
		+ " 2.34 2.34 0 0 0-3.319 1.915 2.34 2.34 0 0 1-4.659 0 2.34 2.34 0 0 0-3.32-1.915"
		+ " 2.34 2.34 0 0 1-2.33-4.033 2.34 2.34 0 0 0 0-3.831A2.34 2.34 0 0 1 6.35 6.051"
		+ 'a2.34 2.34 0 0 0 3.319-1.915"/><circle cx="12" cy="12" r="3"/>'
	),
	"box": '<path d="M8 2l5.5 3v6L8 14l-5.5-3V5zM2.5 5 8 8l5.5-3M8 8v6"/>',
	"users":
	'<circle cx="6" cy="5.5" r="2.2"/><path d="M2 13c.5-2.3 2-3.5 4-3.5s3.5 1.2 4 3.5M10.5 3.5a2 2 0 0 1 0 4M12 9.8c1.1.5 1.8 1.6 2 3.2"/>',
	"alert": '<path d="M8 2.5l6 10.5H2zM8 6.5v3M8 11.2h.01"/>',
	"activity": '<path d="M5.5 4h8M5.5 8h8M5.5 12h8M2.5 4h.01M2.5 8h.01M2.5 12h.01"/>',
	"chart": '<path d="M2 13.5h12M2.5 11l3.5-4 3 2.5 4.5-6"/>',
	"overview": '<circle cx="8" cy="8" r="5.5"/><path d="M10 6l-1.2 2.8L6 10l1.2-2.8z"/>',
	"zones": '<path d="M2.5 5V2.5H5M11 2.5h2.5V5M13.5 11v2.5H11M5 13.5H2.5V11M6 6h4v4H6z"/>',
	"hammer": '<path d="m9 2 4 4-2 2-1.5-1.5-6 6a1.4 1.4 0 0 1-2-2l6-6L6 3l3-1z"/>',
	"code": '<path d="m5.5 4-4 4 4 4M10.5 4l4 4-4 4M9 2.5l-2 11"/>',
}
static var _cache: Dictionary = {}


static func svg_source(name: String, token := "ink-muted") -> String:
	if name not in NAMES or token not in TOKENS:
		return ""
	var atlas := name in ATLAS_NAMES
	var extent := 16 if atlas else 24
	var source := (
		(
			'<svg xmlns="http://www.w3.org/2000/svg" width="%d" height="%d" viewBox="0 0 %d %d"'
			% [extent, extent, extent, extent]
		)
		+ (
			' fill="none" stroke="currentColor" stroke-width="%s" stroke-linecap="%s" stroke-linejoin="round">'
			% ["1.5" if atlas else "2.25", "round" if atlas else "square"]
		)
		+ str(GEOMETRY[name])
		+ "</svg>"
	)
	return source.replace("currentColor", "#" + ThemeTokens.color(token).to_html(false))


static func texture(name: String, token := "ink-muted") -> Texture2D:
	if name not in NAMES or token not in TOKENS:
		push_error("Unknown UI interface icon or chrome token")
		return null
	var key := name + ":" + token
	if _cache.has(key):
		return _cache[key]
	var svg := svg_source(name, token)
	var image := Image.new()
	if image.load_svg_from_string(svg, 1.0 if name in ATLAS_NAMES else 2.0 / 3.0) != OK:
		push_error("Cannot rasterize UI interface icon " + name)
		return null
	var result := ImageTexture.create_from_image(image)
	_cache[key] = result
	return result
