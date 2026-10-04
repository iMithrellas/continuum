## Screen-cell thresholds are independent of world extent and fit zoom percent.
## Focused inspection and critical/selected actor intent bypass routine-label LOD.
class_name MapLabelLod
extends RefCounted

const REGION_CELL := 22.0
const WORK_CELL := 36.0
const NAME_CELL := 28.0


static func region(cell: float, ui_scale: float, focused := false) -> bool:
	return focused or cell >= REGION_CELL * ui_scale


static func work(cell: float, ui_scale: float, focused := false) -> bool:
	return focused or cell >= WORK_CELL * ui_scale


static func nameplate(cell: float, ui_scale: float, focused := false) -> bool:
	return focused or cell >= NAME_CELL * ui_scale
