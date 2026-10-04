## Small chart for values observed during this client connection only.
class_name HistoryChart
extends Control

var metrics := UiMetrics.new()

var _points: Array[Dictionary] = []


func set_points(points: Array[Dictionary]) -> void:
	_points = points
	queue_redraw()


func _ready() -> void:
	custom_minimum_size = metrics.min_size(0, 190)


func _draw() -> void:
	var font := ThemeTokens.font("readout")
	var axis_color := ThemeTokens.color("ink-subtle")
	var grid_color := ThemeTokens.color("line-100")
	var padding := Vector2(metrics.px(42), metrics.px(18))
	var plot := Rect2(
		padding.x,
		padding.y,
		size.x - padding.x - metrics.px(8.0),
		size.y - padding.y - metrics.px(30.0)
	)
	if plot.size.x <= 20.0 or plot.size.y <= 20.0:
		return
	for value: int in [0, 50, 100]:
		var y := plot.position.y + plot.size.y * (1.0 - value / 100.0)
		draw_line(Vector2(plot.position.x, y), Vector2(plot.end.x, y), grid_color)
		draw_string(
			font,
			Vector2(metrics.px(4), y + metrics.px(4)),
			"%d%%" % value,
			HORIZONTAL_ALIGNMENT_LEFT,
			-1,
			ThemeTokens.font_size("readout"),
			axis_color
		)
	draw_line(plot.position, Vector2(plot.position.x, plot.end.y), axis_color)
	draw_line(Vector2(plot.position.x, plot.end.y), plot.end, axis_color)
	if _points.is_empty():
		draw_string(
			font,
			Vector2(plot.position.x + metrics.px(8), plot.position.y + plot.size.y / 2.0),
			"Waiting for replicated colony clock…",
			HORIZONTAL_ALIGNMENT_LEFT,
			plot.size.x - metrics.px(8),
			ThemeTokens.font_size("small"),
			axis_color
		)
		return

	var first_seconds: float = _points[0]["seconds"]
	var last_seconds: float = _points[-1]["seconds"]
	var span := maxf(last_seconds - first_seconds, 1.0)
	_draw_observed_series(plot, "mood", first_seconds, span, ThemeTokens.color("ink-muted"), false)
	_draw_observed_series(
		plot, "productivity", first_seconds, span, ThemeTokens.color("meter-fill"), true
	)
	var span_minutes := (last_seconds - first_seconds) / 60.0
	draw_string(
		font,
		Vector2(plot.position.x, size.y - metrics.px(8)),
		"0 game min",
		HORIZONTAL_ALIGNMENT_LEFT,
		-1,
		ThemeTokens.font_size("readout"),
		axis_color
	)
	var end_label := "%.0f game min" % span_minutes
	draw_string(
		font,
		Vector2(
			(
				plot.end.x
				- (
					font
					. get_string_size(
						end_label, HORIZONTAL_ALIGNMENT_LEFT, -1, ThemeTokens.font_size("readout")
					)
					. x
				)
			),
			size.y - metrics.px(8)
		),
		end_label,
		HORIZONTAL_ALIGNMENT_LEFT,
		-1,
		ThemeTokens.font_size("readout"),
		axis_color
	)
	draw_string(
		ThemeTokens.font("small"),
		Vector2(plot.position.x + metrics.px(8), plot.position.y - metrics.px(4)),
		"Mood — · Output - -",
		HORIZONTAL_ALIGNMENT_LEFT,
		-1,
		ThemeTokens.font_size("small"),
		ThemeTokens.color("ink-muted")
	)


func _draw_observed_series(
	plot: Rect2, key: String, first_seconds: float, span: float, color: Color, dashed: bool
) -> void:
	var previous: Variant = null
	var previous_seconds := -1.0
	for sample: Dictionary in _points:
		var value: Variant = sample.get("values", {}).get(key)
		var seconds := float(sample.seconds)
		if value == null or not (value is int or value is float) or not is_finite(float(value)):
			previous = null
			continue
		var point := Vector2(
			plot.position.x + (seconds - first_seconds) / span * plot.size.x,
			plot.position.y + plot.size.y * (1.0 - clampf(float(value) / 100.0, 0.0, 1.0))
		)
		if (
			previous != null
			and seconds > previous_seconds
			and seconds - previous_seconds <= SessionHistory.SAMPLE_INTERVAL_SECONDS * 2.0
		):
			if dashed:
				draw_dashed_line(previous, point, color, 2.0, 4.0, true)
			else:
				draw_line(previous, point, color, 2.0, true)
		else:
			draw_rect(Rect2(point - Vector2.ONE, Vector2(2, 2)), color)
		previous = point
		previous_seconds = seconds
