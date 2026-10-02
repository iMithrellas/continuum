extends Control
## Static threshold ticks; no interpolation or animation.
var model: Dictionary = {}

func set_model(data: Dictionary) -> void:
	model = data
	custom_minimum_size = Vector2(64, 12)
	size_flags_horizontal = Control.SIZE_EXPAND_FILL
	queue_redraw()

func _draw() -> void:
	if model.is_empty():
		return
	var track = Rect2(0, (size.y - 6) / 2, size.x, 6)
	draw_style_box(_box("meter-track"), track)
	if model.value != null:
		var fill = track
		fill.size.x *= model.value / 100.0
		draw_style_box(_box(model.level if model.level in ["warn", "critical"] else "meter-fill"), fill)
	for threshold in [model.thresholds.warn, model.thresholds.critical]:
		var x = size.x * threshold / 100.0
		draw_line(Vector2(x, 0), Vector2(x, size.y), ThemeTokens.color("ink-subtle"), 1)

func _box(color_name: String) -> StyleBoxFlat:
	var box = StyleBoxFlat.new()
	box.bg_color = ThemeTokens.color(color_name)
	box.set_corner_radius_all(int(ThemeTokens.number("radius-sm")))
	return box
