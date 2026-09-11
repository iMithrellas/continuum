## Small chart for values observed during this client connection only.
class_name HistoryChart
extends Control

const AXIS_COLOR := Color("5c6675")
const GRID_COLOR := Color("29313b")
const MOOD_COLOR := Color("6fcf7f")
const PRODUCTIVITY_COLOR := Color("ffb74d")
const PADDING := Vector2(42, 18)

var _points: Array[Dictionary] = []


func set_points(points: Array[Dictionary]) -> void:
	_points = points
	queue_redraw()


func _ready() -> void:
	custom_minimum_size = Vector2(0, 190)


func _draw() -> void:
	var font := ThemeDB.fallback_font
	var plot := Rect2(PADDING.x, PADDING.y, size.x - PADDING.x - 8.0,
			size.y - PADDING.y - 30.0)
	if plot.size.x <= 20.0 or plot.size.y <= 20.0:
		return
	for value: int in [0, 50, 100]:
		var y := plot.position.y + plot.size.y * (1.0 - value / 100.0)
		draw_line(Vector2(plot.position.x, y), Vector2(plot.end.x, y), GRID_COLOR)
		draw_string(font, Vector2(4, y + 4), "%d%%" % value, HORIZONTAL_ALIGNMENT_LEFT, -1, 10, AXIS_COLOR)
	draw_line(plot.position, Vector2(plot.position.x, plot.end.y), AXIS_COLOR)
	draw_line(Vector2(plot.position.x, plot.end.y), plot.end, AXIS_COLOR)
	if _points.is_empty():
		draw_string(font, Vector2(plot.position.x + 8, plot.position.y + plot.size.y / 2.0),
			"Waiting for replicated colony clock...", HORIZONTAL_ALIGNMENT_LEFT, -1, 12, AXIS_COLOR)
		return

	var first_seconds: float = _points[0]["seconds"]
	var last_seconds: float = _points[-1]["seconds"]
	var span := maxf(last_seconds - first_seconds, 1.0)
	var mood_line := PackedVector2Array()
	var productivity_line := PackedVector2Array()
	for point: Dictionary in _points:
		var x := plot.position.x + (float(point["seconds"]) - first_seconds) / span * plot.size.x
		var values: Dictionary = point["values"]
		mood_line.append(Vector2(x, plot.position.y + plot.size.y * (1.0 - clampf(float(values.get("mood", 0.0)) / 100.0, 0.0, 1.0))))
		productivity_line.append(Vector2(x, plot.position.y + plot.size.y * (1.0 - clampf(float(values.get("productivity", 0.0)) / 100.0, 0.0, 1.0))))
	if mood_line.size() > 1:
		draw_polyline(mood_line, MOOD_COLOR, 2.0, true)
		draw_polyline(productivity_line, PRODUCTIVITY_COLOR, 2.0, true)
	else:
		draw_circle(mood_line[0], 3.0, MOOD_COLOR)
		draw_circle(productivity_line[0], 3.0, PRODUCTIVITY_COLOR)
	var span_minutes := (last_seconds - first_seconds) / 60.0
	draw_string(font, Vector2(plot.position.x, size.y - 8), "0m", HORIZONTAL_ALIGNMENT_LEFT, -1, 10, AXIS_COLOR)
	draw_string(font, Vector2(plot.end.x - 42, size.y - 8), "%.0fm" % span_minutes, HORIZONTAL_ALIGNMENT_LEFT, -1, 10, AXIS_COLOR)
	draw_string(font, Vector2(plot.position.x + 8, plot.position.y - 4), "mood", HORIZONTAL_ALIGNMENT_LEFT, -1, 10, MOOD_COLOR)
	draw_string(font, Vector2(plot.position.x + 48, plot.position.y - 4), "productivity", HORIZONTAL_ALIGNMENT_LEFT, -1, 10, PRODUCTIVITY_COLOR)
