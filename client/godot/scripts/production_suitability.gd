## Pure presentation helpers for the ecological production multiplier.
##
## This describes potential terrain yield relative to baseline. It is not actual
## productivity, a work-availability/stoppage diagnosis, nor delivered stock:
## colonist productivity, enabled facilities/orders, and hauling remain separate.
## Missing terrain preserves the backend's neutral multiplier but is described as
## unknown, so the UI does not mistake fallback behavior for observed suitability.
class_name ProductionSuitability
extends RefCounted

const WorkType = preload("res://spacetime_bindings/schema/types/continuum_work_type.gd")


static func multiplier(work: int, terrain: Dictionary) -> float:
	if terrain.is_empty():
		return 1.0
	match work:
		WorkType.Options.farming:
			return 0.5 + _field(terrain, "soil_fertility") * _field(terrain, "moisture")
		WorkType.Options.logging, WorkType.Options.hunting:
			return 0.5 + _field(terrain, "forest_density")
		_:
			return 1.0


## Short context for terrain-only potential, not actual production or delivery.
static func description(work: int, terrain: Dictionary) -> String:
	return "Terrain potential; actual output depends on current worker productivity and orders. Goods must still be hauled."


## A compact work-specific line suitable for a selected tile's inspector/tooltip.
static func work_line(work: int, terrain: Dictionary) -> String:
	var work_name := _work_name(work)
	if work == WorkType.Options.none:
		return "Terrain potential · No production work"
	if not _ecology_affects(work):
		return "Terrain potential · %s: unaffected (100%% of baseline)" % work_name
	if terrain.is_empty():
		return "Terrain potential · %s: terrain data unavailable" % work_name
	var percent := multiplier(work, terrain) * 100.0
	return "Terrain potential · %s: %.0f%% of baseline" % [work_name, percent]


static func _ecology_affects(work: int) -> bool:
	return work in [WorkType.Options.farming, WorkType.Options.logging, WorkType.Options.hunting]


static func _work_name(work: int) -> String:
	match work:
		WorkType.Options.farming:
			return "Farming"
		WorkType.Options.logging:
			return "Logging"
		WorkType.Options.mining:
			return "Mining"
		WorkType.Options.hunting:
			return "Hunting"
		_:
			return "Unknown work"


static func _field(terrain: Dictionary, key: String) -> float:
	var value: Variant = terrain.get(key)
	if not (value is int or value is float) or not is_finite(float(value)):
		return 0.0
	return clampf(float(value), 0.0, 1.0)
