## Shared UI measurements derived from the original 13px design.
class_name UiMetrics
extends RefCounted

const REFERENCE_FONT_SIZE := 13.0
var base_font_size: int
var scale: float

func _init(font_size: int = ClientSettings.DEFAULT_FONT_SIZE) -> void:
	base_font_size = clampi(int(font_size), ClientSettings.MIN_FONT_SIZE, ClientSettings.MAX_FONT_SIZE)
	scale = float(base_font_size) / REFERENCE_FONT_SIZE

func font(reference: float) -> int:
	return maxi(1, roundi(reference * scale))

func px(reference: float) -> float:
	return reference * scale

func min_size(width: float, height: float) -> Vector2:
	return Vector2(px(width), px(height))
