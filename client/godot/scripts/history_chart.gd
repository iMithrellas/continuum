## Small chart for values observed during this client connection only.
class_name HistoryChart
extends Control

const Models = preload("res://ui/components/models.gd")
const COMPACT_SERIES := [["food", "Food"], ["wood", "Wood"], ["stone", "Stone"]]
const FALLBACK_SERIES := [["mood", "Mood"], ["productivity", "Output"]]

var metrics := UiMetrics.new()
var compact := false:
	set(value):
		compact = value
		_refresh_minimum()
		queue_redraw()

var _points: Array[Dictionary] = []


func set_points(points: Array[Dictionary]) -> void:
	_points = points
	_refresh_minimum()
	queue_redraw()


func set_compact(value: bool = true) -> void:
	compact = value


func _ready() -> void:
	_refresh_minimum()


func _refresh_minimum() -> void:
	custom_minimum_size = (
		Vector2(0, maxi(108, _compact_series().size() * 36))
		if compact
		else metrics.min_size(0, 190)
	)


func _draw() -> void:
	if compact:
		_draw_compact()
		return
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


## Samples keep the existing {seconds, values: {key: number|null}} API.
## Optional per-series severity is explicit: meta: {food: {level: "warn"}}.
## No stock thresholds or estimates are inferred by this chart.
func _compact_series() -> Array:
	var resources: Array = []
	var fallback: Array = []
	for descriptor: Array in COMPACT_SERIES + FALLBACK_SERIES:
		for sample: Dictionary in _points:
			if _compact_value(sample, descriptor[0]) != null:
				if descriptor in COMPACT_SERIES:
					resources.append(descriptor)
				else:
					fallback.append(descriptor)
				break
	return resources if not resources.is_empty() else fallback


func _compact_value(sample: Dictionary, key: String) -> Variant:
	if not Models.numeric(sample.get("seconds")) or not sample.get("values") is Dictionary:
		return null
	return Models.measurement(sample.values, key)


func _compact_level(sample: Dictionary, key: String) -> String:
	if _compact_value(sample, key) == null or not sample.get("meta") is Dictionary:
		return "nominal"
	var metadata: Variant = sample.meta.get(key)
	return Models.level(metadata.get("level")) if metadata is Dictionary else "nominal"


func _draw_compact() -> void:
	var series := _compact_series()
	var ink := ThemeTokens.color("ink-muted")
	if series.is_empty():
		tooltip_text = "Waiting for observed history · no numeric samples available"
		draw_string(
			ThemeTokens.font("body"),
			Vector2(10, 22),
			"Waiting for observed history…",
			HORIZONTAL_ALIGNMENT_LEFT,
			maxf(0, size.x - 20),
			12,
			ink
		)
		return
	var first_seconds := INF
	var last_seconds := -INF
	for sample: Dictionary in _points:
		if Models.numeric(sample.get("seconds")):
			first_seconds = minf(first_seconds, sample.seconds)
			last_seconds = maxf(last_seconds, sample.seconds)
	tooltip_text = "Observed since connection · each sparkline uses its local value range"
	tooltip_text += "\nMissing observations and clock gaps are not connected."
	for index in series.size():
		var key: String = series[index][0]
		var label: String = series[index][1]
		var y := float(index * 36)
		if index > 0:
			draw_line(Vector2(10, y), Vector2(maxf(10, size.x - 10), y), Color("262a2f"))
		var level := _compact_level(_points[-1], key)
		var color := ThemeTokens.color(level) if level in ["warn", "critical"] else ink
		var value: Variant = _compact_value(_points[-1], key)
		var value_copy := "Unavailable" if value == null else str(value)
		tooltip_text += "\n%s: %s" % [label, value_copy]
		if level in ["warn", "critical"]:
			tooltip_text += " · " + ("Warning" if level == "warn" else "Critical")
		var font := ThemeTokens.font("body")
		var baseline := y + (36 - font.get_height(12)) / 2 + font.get_ascent(12)
		draw_string(font, Vector2(10, baseline), label, HORIZONTAL_ALIGNMENT_LEFT, 48, 12, ink)
		font = ThemeTokens.font("log")
		baseline = y + (36 - font.get_height(12)) / 2 + font.get_ascent(12)
		draw_string(
			font,
			Vector2(maxf(68, size.x - 50), baseline),
			_compact_value_copy(value),
			HORIZONTAL_ALIGNMENT_RIGHT,
			40,
			12,
			color
		)
		var plot := Rect2(68, y + 6, maxf(0, size.x - 128), 24)
		if plot.size.x > 0:
			_draw_compact_series(
				plot, key, first_seconds, maxf(1, last_seconds - first_seconds), color
			)


func _draw_compact_series(
	plot: Rect2, key: String, first_seconds: float, span: float, color: Color
) -> void:
	var low := INF
	var high := -INF
	for sample: Dictionary in _points:
		var value: Variant = _compact_value(sample, key)
		if value != null:
			low = minf(low, value)
			high = maxf(high, value)
	var previous: Variant = null
	var previous_seconds := -INF
	for sample: Dictionary in _points:
		var value: Variant = _compact_value(sample, key)
		if value == null:
			previous = null
			continue
		var seconds := float(sample.seconds)
		var fraction := (float(value) - low) / (high - low) if high > low else 0.5
		var point := Vector2(
			plot.position.x + (seconds - first_seconds) / span * plot.size.x,
			plot.position.y + 2 + (1 - fraction) * (plot.size.y - 4)
		)
		if (
			previous != null
			and seconds > previous_seconds
			and seconds - previous_seconds <= SessionHistory.SAMPLE_INTERVAL_SECONDS * 2.0
		):
			draw_line(previous, point, color, 1.5, true)
		else:
			draw_circle(point, 1, color)
		previous = point
		previous_seconds = seconds


func _compact_value_copy(value: Variant) -> String:
	if value == null:
		return "—"
	var copy := ("%.1f" % value).trim_suffix(".0")
	if copy.length() <= 5:
		return copy
	var exponent := floori(log(absf(float(value))) / log(10))
	var mantissa := roundi(float(value) / pow(10, exponent))
	if absi(mantissa) == 10:
		mantissa = 1 if mantissa > 0 else -1
		exponent += 1
	return "~%de%d" % [mantissa, exponent]
