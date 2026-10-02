class_name ThemeTokens
extends RefCounted
## Logical 100% units. The viewport owns UI scaling; tokens never do.

const ROOT := "res://ui/theme/"
const VARIANTS := {"title": "LabelTitle", "body-strong": "LabelBodyStrong", "body": "LabelBody", "small": "LabelSmall", "display": "LabelDisplay", "section": "LabelSection", "tag": "LabelTag", "readout-lg": "LabelReadoutLarge", "readout": "LabelReadout", "log": "LabelLog"}
## Required names are the public contract; their values still come only from JSON.
const REQUIRED_TOKENS := {
	"color": ["bg-000", "bg-100", "bg-200", "bg-300", "bg-400", "line-100", "line-200", "ink", "ink-muted", "ink-subtle", "meter-track", "meter-fill", "accent", "accent-soft", "on-accent", "warn", "warn-soft", "on-warn", "critical", "critical-soft", "on-critical", "map-ground", "map-ground-deep", "map-grid", "map-ink", "map-paper", "map-plan", "zone-farm", "zone-forest", "zone-mine", "zone-storage", "zone-sleep", "zone-dining", "zone-rec"],
	"spacing": ["space-1", "space-2", "space-3", "space-4", "space-6", "space-8"],
	"size": ["control-sm", "control-md", "panel-header", "topbar", "tile", "panel-min"],
	"radius": ["radius-0", "radius-sm", "radius-md"],
	"shadow": ["shadow-float", "focus-ring"],
}
static var _values: Dictionary = {}
static var _families: Dictionary = {}
static var _styles: Dictionary = {}
static var _fonts: Dictionary = {}
static var _style_fonts: Dictionary = {}
static var _loaded := false

## Pure resolver: error is explicit and malformed/missing/cyclic aliases never hang.
static func resolve(values: Dictionary, token: String) -> Dictionary:
	var seen := {}
	var key := token
	while true:
		if seen.has(key):
			return {"error": "Cyclic token alias: " + key}
		if not values.has(key):
			return {"error": "Unknown token: " + key}
		seen[key] = true
		var value: Variant = values[key]
		if not value is String:
			return {"error": "Token must be a string: " + key}
		if value.begins_with("{") and value.ends_with("}"):
			key = value.substr(1, value.length() - 2)
			continue
		if "{" in value or "}" in value:
			return {"error": "Malformed alias: " + key}
		return {"value": value}
	return {}

static func parse_number(value: String) -> Dictionary:
	var raw := value.trim_suffix("px")
	if not raw.is_valid_float() or not is_finite(raw.to_float()) or raw.to_float() < 0:
		return {"error": "Invalid nonnegative pixel value: " + value}
	return {"value": raw.to_float()}

static func parse_shadow(value: String) -> Dictionary:
	var layers: Array[Dictionary] = []
	for part: String in value.split(","):
		var fields := part.strip_edges().split(" ", false)
		if fields.size() not in [4, 5] or not Color.html_is_valid(fields[-1]):
			return {"error": "Invalid shadow layer"}
		var dimensions: Array[float] = []
		for index in range(fields.size() - 1):
			var parsed := parse_number(fields[index])
			if parsed.has("error"):
				return parsed
			dimensions.append(parsed.value)
		layers.append({"offset": Vector2(dimensions[0], dimensions[1]), "blur": dimensions[2], "spread": dimensions[3] if dimensions.size() == 4 else 0.0, "color": Color.html(fields[-1])})
	return {"value": layers}

static func shadow(token: String) -> Array:
	if not _ensure() or _families.get(token) != "shadow":
		push_error("Unknown shadow token " + token)
		return []
	return parse_shadow(resolve(_values, token).value).value

static func validate(data: Variant) -> Array[String]:
	var errors: Array[String] = []
	if not data is Dictionary:
		return ["Token root must be an object"]
	var values := {}
	var families := {}
	for family: String in ["color", "spacing", "size", "radius", "shadow"]:
		if not data.get(family) is Dictionary or not data[family].get("tokens") is Array:
			errors.append("Missing token family: " + family)
			continue
		for token: Variant in data[family].tokens:
			if not token is Dictionary or not token.get("name") is String or not token.get("value") is String:
				errors.append("Invalid token in " + family)
				continue
			if values.has(token.name):
				errors.append("Duplicate token: " + token.name)
			values[token.name] = token.value
			families[token.name] = family
	for family: String in REQUIRED_TOKENS:
		for name: String in REQUIRED_TOKENS[family]:
			if families.get(name) != family:
				errors.append("Missing required " + family + " token: " + name)
	for key: String in values:
		var result := resolve(values, key)
		if result.has("error"):
			errors.append(result.error)
			continue
		if families[key] == "color" and not Color.html_is_valid(result.value):
			errors.append("Invalid color: " + key)
		elif families[key] == "shadow":
			var shadow_result := parse_shadow(result.value)
			if shadow_result.has("error") or shadow_result.get("value", []).is_empty():
				errors.append("Invalid shadow: " + key)
			elif key in ["shadow-float", "focus-ring"] and shadow_result.value.size() != 2:
				errors.append("Required shadow must have two layers: " + key)
		elif families[key] in ["spacing", "size", "radius"]:
			var parsed := parse_number(result.value)
			if parsed.has("error"):
				errors.append(parsed.error)
			elif families[key] == "radius" and not parsed.value in [0.0, 2.0, 4.0]:
				errors.append("Unsupported radius: " + key)
	if not data.get("type") is Dictionary or not data.type.get("groups") is Array or not data.type.get("fonts") is Array:
		errors.append("Missing typography")
		return errors
	var available := {}
	for entry: Variant in data.type.fonts:
		if not entry is Dictionary or not entry.get("family") is String or not entry.get("weight") is String or not entry.get("file") is String:
			errors.append("Invalid font entry")
			continue
		if not entry.file.begins_with("fonts/") or ".." in entry.file or not entry.file.ends_with(".woff2"):
			errors.append("Unsafe font path")
		available[entry.family + ":" + entry.weight] = true
	var styles := {}
	for group: Variant in data.type.groups:
		if not group is Dictionary or not group.get("family") in ["sans", "cond", "mono"] or not group.get("styles") is Array:
			errors.append("Invalid type group")
			continue
		for style: Variant in group.styles:
			if not style is Dictionary or not style.get("name") is String or not style.get("fontSize") is String or not style.get("lineHeight") is String:
				errors.append("Invalid type style")
				continue
			if styles.has(style.name):
				errors.append("Duplicate type style")
			styles[style.name] = true
			var weight: Variant = style.get("fontWeight")
			if not (weight is int or weight is float):
				errors.append("Invalid font weight: " + style.name)
				continue
			var numeric_weight := float(weight)
			if not is_finite(numeric_weight) or numeric_weight != floor(numeric_weight) or numeric_weight < 1 or numeric_weight > 1000:
				errors.append("Font weight must be a finite integer from 1 to 1000: " + style.name)
				continue
			var size := parse_number(style.fontSize)
			var height := parse_number(style.lineHeight)
			if size.has("error") or height.has("error") or size.get("value", 0) < 11 or height.get("value", 0) < size.get("value", 0):
				errors.append("Invalid type dimensions: " + style.name)
			var family: String = {"sans": "IBM Plex Sans", "cond": "IBM Plex Sans Condensed", "mono": "IBM Plex Mono"}[group.family]
			if not available.has(family + ":" + str(int(style.fontWeight))):
				errors.append("Missing font for " + style.name)
			if style.has("letterSpacing") and (not style.letterSpacing is String or not style.letterSpacing.ends_with("em") or not style.letterSpacing.trim_suffix("em").is_valid_float()):
				errors.append("Invalid tracking")
	for style: String in VARIANTS:
		if not styles.has(style):
			errors.append("Missing type style: " + style)
	return errors

static func _ensure() -> bool:
	if _loaded:
		return true
	var parser := JSON.new()
	var source: String
	if FileAccess.file_exists(ROOT + "tokens.json"):
		source = FileAccess.get_file_as_string(ROOT + "tokens.json")
	else:
		# Godot exports imported resources, not arbitrary JSON/TXT by default.
		# The generated Theme embeds the exact source and OFL for packaged builds.
		var packaged: Theme = load(ROOT + "theme.tres")
		if packaged == null:
			push_error("UI theme missing")
			return false
		source = packaged.get_meta("theme_tokens_json", "")
	var parse_error := parser.parse(source)
	if parse_error != OK:
		push_error("Invalid UI JSON: " + parser.get_error_message())
		return false
	var errors := validate(parser.data)
	if not errors.is_empty():
		push_error("Invalid UI tokens: " + str(errors))
		return false
	var data: Dictionary = parser.data
	for family: String in ["color", "spacing", "size", "radius", "shadow"]:
		for token: Dictionary in data[family]["tokens"]:
			assert(not _values.has(token.name), "Duplicate token " + token.name)
			_values[token.name] = token.value
			_families[token.name] = family
	for key: String in _values:
		var resolved := resolve(_values, key)
		assert(not resolved.has("error"), str(resolved))
		if _families[key] == "color":
			assert(Color.html_is_valid(resolved.value), "Invalid color " + key)
		elif _families[key] in ["size", "spacing", "radius"]:
			assert(not parse_number(resolved.value).has("error"), "Invalid number " + key)
			if _families[key] == "radius":
				assert(parse_number(resolved.value).value in [0.0, 2.0, 4.0], "Unsupported radius")
	for group: Dictionary in data.type.groups:
		for style: Dictionary in group.styles:
			var spec := style.duplicate()
			spec.family = group.family
			assert(not _styles.has(style.name), "Duplicate type style")
			_styles[style.name] = spec
	for entry: Dictionary in data.type.fonts:
		if not ResourceLoader.exists(ROOT + entry.file, "FontFile"):
			push_error("UI font import missing: " + entry.file)
			return false
		_fonts[entry.family + ":" + str(entry.weight)] = ROOT + entry.file
	_loaded = true
	return true

static func color(token: String) -> Color:
	if not _ensure():
		return Color.TRANSPARENT
	var result := resolve(_values, token)
	if result.has("error") or _families.get(token) != "color":
		push_error("UI color: " + token + " " + str(result))
		return Color.TRANSPARENT
	return Color.html(result.value)

static func number(token: String) -> float:
	if not _ensure():
		return 0.0
	var result := resolve(_values, token)
	if result.has("error") or not _families.get(token) in ["size", "spacing", "radius"]:
		push_error("UI number: " + token + " " + str(result))
		return 0.0
	return parse_number(result.value).get("value", 0.0)

static func font_size(style: String) -> int:
	if not _ensure() or not _styles.has(style):
		push_error("Unknown type style " + style)
		return 11
	return int(parse_number(_styles[style].fontSize).value)

static func line_height(style: String) -> int:
	if not _ensure() or not _styles.has(style):
		push_error("Unknown type style " + style)
		return 14
	return int(parse_number(_styles[style].lineHeight).value)

static func font(style: String) -> Font:
	if not _ensure() or not _styles.has(style):
		push_error("Unknown type style " + style)
		return null
	if _style_fonts.has(style):
		return _style_fonts[style]
	var spec: Dictionary = _styles[style]
	var family: String = {"sans": "IBM Plex Sans", "cond": "IBM Plex Sans Condensed", "mono": "IBM Plex Mono"}[spec.family]
	var base: Font = load(_fonts[family + ":" + str(int(spec.fontWeight))])
	assert(base != null, "Font import missing")
	# Godot glyph spacing is integer pixels: round em tracking at logical size.
	if spec.has("letterSpacing"):
		var variation := FontVariation.new()
		variation.base_font = base
		variation.spacing_glyph = roundi(float(spec.letterSpacing.trim_suffix("em")) * font_size(style))
		_style_fonts[style] = variation
		return variation
	_style_fonts[style] = base
	return base

static func glyph(name: String) -> Texture2D:
	if not name in ["notice", "warn", "critical", "ack", "auto", "player"]:
		push_error("Unknown UI glyph: " + name)
		return null
	return load(ROOT + "glyphs/" + name + ".svg") as Texture2D

static func apply_label(label: Label, style: String) -> void:
	if not _ensure() or not VARIANTS.has(style):
		push_error("Unknown type style " + style)
		return
	label.theme_type_variation = VARIANTS[style]
	label.add_theme_font_override("font", font(style))
	label.add_theme_font_size_override("font_size", font_size(style))
	label.add_theme_color_override("font_color", color("ink-subtle" if style in ["section", "log"] else "ink-muted" if style in ["small", "tag"] else "ink"))
	label.uppercase = style in ["section", "tag"]
	label.add_theme_constant_override("line_spacing", line_height(style) - ceili(font(style).get_height(font_size(style))))
	label.custom_minimum_size.y = line_height(style)
