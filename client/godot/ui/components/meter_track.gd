extends Control
## Static threshold ticks; no interpolation or animation.
var model: Dictionary = {}

func set_model(data: Dictionary) -> void:
	model = data
	custom_minimum_size = Vector2(32, 12)
	size_flags_horizontal = Control.SIZE_EXPAND_FILL
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	queue_redraw()

func _draw() -> void:
	if model.is_empty():
		return
	var track = Rect2(0, (size.y - 6) / 2, size.x, 6)
	draw_style_box(_box("meter-track"), track)
	if model.value != null and model.value > 0:
		var fill = track
		fill.size.x *= model.value / 100.0
		draw_style_box(_box(model.level if model.level in ["warn", "critical"] else "meter-fill"), fill)
	for threshold in [model.thresholds.warn, model.thresholds.critical]:
		var x = size.x * threshold / 100.0
		draw_line(Vector2(x, size.y / 2 - 6), Vector2(x, size.y / 2 + 6), ThemeTokens.color("ink-subtle"), 1)

func _box(color_name: String) -> StyleBoxFlat:
	var box = StyleBoxFlat.new()
	box.bg_color = ThemeTokens.color(color_name)
	box.set_corner_radius_all(int(ThemeTokens.number("radius-sm")))
	return box
