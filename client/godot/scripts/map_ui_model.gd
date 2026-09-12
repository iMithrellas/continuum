## Pure geometry helpers shared by the map UI and headless tests.
class_name MapUiModel
extends RefCounted


static func normalize_rect(start: Vector2i, finish: Vector2i) -> Rect2i:
	return Rect2i(
		Vector2i(mini(start.x, finish.x), mini(start.y, finish.y)),
		Vector2i(absi(finish.x - start.x) + 1, absi(finish.y - start.y) + 1))


static func clamp_cell(cell: Vector2i, grid: Vector2i) -> Vector2i:
	return Vector2i(clampi(cell.x, 0, maxi(0, grid.x - 1)), clampi(cell.y, 0, maxi(0, grid.y - 1)))


static func cells(rect: Rect2i) -> int:
	return rect.size.x * rect.size.y
