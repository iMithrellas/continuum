## Reversible stabilization evidence, never a score or persisted achievement.
## A safe snapshot is not proof of a safe colony. Recovery requires contiguous
## game-clock observations; disconnects, resets, gaps and regressions revoke it.
extends RefCounted

const OBSERVATION_SECONDS := 3600.0
const MAX_SAMPLE_GAP := 900.0
const ESSENTIALS := ["farm", "storage", "dining", "sleep", "recreation"]

var _generation := -1
var _last_seconds := -1.0
var _safe_since := -1.0
var _food_baseline := 0.0
var _samples := 0


func reset() -> void:
	_generation = -1
	_last_seconds = -1.0
	_safe_since = -1.0
	_samples = 0


## Accepts generated rows or dictionaries. Operation rows are explanatory only;
## automation authority belongs to the separate replicated policy model.
func snapshot(
	game_seconds: float,
	generation: int,
	tiles: Array,
	orders: Array,
	colonists: Array,
	stacks: Array,
	resources: Dictionary,
	operation_rows: Array = [],
	ready := true
) -> Dictionary:
	if not ready or not is_finite(game_seconds) or game_seconds < 0:
		reset()
		return {
			"phase": "Observe",
			"summary": "Waiting for a live colony snapshot. Stale state cannot establish recovery.",
			"ready": false,
			"milestones": [],
			"operations": []
		}
	if (
		generation != _generation
		or game_seconds < _last_seconds
		or (_last_seconds >= 0 and game_seconds - _last_seconds > MAX_SAMPLE_GAP)
	):
		reset()
	_generation = generation
	var enabled := {}
	var tile_by_id := {}
	for tile in tiles:
		tile_by_id[field(tile, "id", -1)] = tile
		if field(tile, "enabled", false):
			enabled[kind_name(field(tile, "kind"), "tile")] = tile
	var missing: Array[String] = []
	for kind: String in ESSENTIALS:
		if not enabled.has(kind):
			missing.append(kind.capitalize())
	var ground_food := 0.0
	for stack in stacks:
		if (
			kind_name(field(stack, "kind"), "resource") == "food"
			and numeric(field(stack, "amount"))
		):
			ground_food += maxf(0.0, float(field(stack, "amount")))
	var food_known := numeric(resources.get("food"))
	var food := float(resources.get("food", 0.0)) if food_known else 0.0
	var reserve := maxf(2.0, colonists.size() * 2.0)
	var food_ok := food_known and food >= reserve and not colonists.is_empty()
	var wellbeing_ok := not colonists.is_empty()
	var worst_id := -1
	var worst_value := 101.0
	var unknown_needs := false
	for colonist in colonists:
		for need: String in ["hunger", "fatigue", "recreation", "mood"]:
			var value: Variant = field(colonist, need)
			if not numeric(value) or float(value) < 0.0 or float(value) > 100.0:
				unknown_needs = true
				wellbeing_ok = false
				continue
			var satisfaction := float(value) if need == "mood" else 100.0 - float(value)
			if satisfaction < 65.0:
				wellbeing_ok = false
			if satisfaction < worst_value:
				worst_value = satisfaction
				worst_id = int(field(colonist, "id", -1))
	var productive_orders := 0
	var order_tile := -1
	for order in orders:
		var tile: Variant = tile_by_id.get(field(order, "tile_id", -1))
		var work := kind_name(field(order, "work"), "work")
		var kind := kind_name(field(tile, "kind"), "tile")
		var compatible := (
			(work == "farming" and kind == "farm")
			or (work in ["logging", "hunting"] and kind == "forest")
			or (work == "mining" and kind == "mine")
		)
		if (
			not field(order, "enabled", false)
			or not field(tile, "enabled", false)
			or not compatible
		):
			continue
		for colonist in colonists:
			var role := kind_name(field(colonist, "haul_role"), "haul_role")
			if (
				role in ["both", "producer"]
				and kind_name(field(colonist, "work"), "work") == work
				and numeric(field(colonist, "productivity"))
				and float(field(colonist, "productivity")) > 0
			):
				productive_orders += 1
				order_tile = int(field(order, "tile_id", -1))
				break
	var foundations_ok := food_ok and missing.is_empty() and wellbeing_ok and productive_orders > 0
	if not foundations_ok or (_safe_since >= 0 and food < _food_baseline):
		_safe_since = -1.0
		_samples = 0
	if foundations_ok and _safe_since < 0:
		_safe_since = game_seconds
		_food_baseline = food
	if foundations_ok and game_seconds != _last_seconds:
		_samples += 1
	_last_seconds = game_seconds
	var observed_seconds := maxf(0.0, game_seconds - _safe_since) if _safe_since >= 0 else 0.0
	var recovered := foundations_ok and observed_seconds >= OBSERVATION_SECONDS and _samples >= 5
	var milestones: Array[Dictionary] = []
	(
		milestones
		. append(
			milestone(
				"Food delivered to stores",
				food_ok,
				(
					(
						"%.1f stored / %.1f ground food. Local reserve target: %.0f (2 per colonist); ground and carried food are not meals in store."
						% [food, ground_food, reserve]
					)
					if food_known
					else "Stored food is unknown; do not infer meals from ground stacks."
				),
				"Inspect delivery" if ground_food > 0 else "Inspect food production",
				"inspector",
				int(field(enabled.get("storage" if ground_food > 0 else "farm"), "id", -1))
			)
		)
	)
	(
		milestones
		. append(
			milestone(
				"Essential facilities",
				missing.is_empty(),
				(
					"Enabled farm, storage, dining, sleep and recreation exist. Access and capacity still need inspection."
					if missing.is_empty()
					else (
						"Missing or disabled: "
						+ ", ".join(missing)
						+ ". Inspect placement and access before adding work."
					)
				),
				"Inspect facilities",
				"inspector"
			)
		)
	)
	(
		milestones
		. append(
			milestone(
				"Colonist wellbeing",
				wellbeing_ok,
				(
					"Every observed need satisfaction is at least 65/100; averages cannot hide a struggling colonist."
					if wellbeing_ok
					else (
						"Need data unavailable."
						if unknown_needs or colonists.is_empty()
						else (
							"Lowest observed need satisfaction: %.0f/100. Restore meals, rest and leisure before increasing workload."
							% worst_value
						)
					)
				),
				"Inspect people",
				"people",
				-1,
				worst_id
			)
		)
	)
	(
		milestones
		. append(
			milestone(
				"Productive orders",
				productive_orders > 0,
				(
					"%d enabled, compatible orders have assigned producers with nonzero output. This is capacity, not proof of delivery."
					% productive_orders
				),
				"Inspect work",
				"operations",
				order_tile
			)
		)
	)
	(
		milestones
		. append(
			{
				"name": "Sustainable operations",
				"state":
				(
					"Observed recovery"
					if recovered
					else ("Observing" if foundations_ok else "At risk")
				),
				"detail":
				(
					"%.0f / %.0f game minutes of sampled current foundations with no net stored-food loss. Session evidence only, not a forecast or proof of unattended safety. Automation status is not established here."
					% [observed_seconds / 60.0, OBSERVATION_SECONDS / 60.0]
				),
				"action": "Review trends",
				"panel": "trends",
				"focus_tile_id": -1,
				"colonist_id": -1
			}
		)
	)
	var next: Dictionary = milestones[4]
	for item in milestones:
		if item.state == "At risk":
			next = item
			break
	return {
		"phase": "Recover" if foundations_ok else "Diagnose",
		"summary":
		(
			"Recovery observed this session; keep watching for regressions."
			if recovered
			else (
				"Foundations present now. Observe food balance; unattended safety is not established."
				if foundations_ok
				else "Next: " + next.name + ". Diagnose causes, intervene, then observe recovery."
			)
		),
		"ready": true,
		"milestones": milestones,
		"next": next.duplicate(true),
		"operations": operation_rows.duplicate(true),
		"observed_seconds": observed_seconds
	}


static func milestone(
	title: String,
	ok: bool,
	detail: String,
	action: String,
	panel: String,
	tile_id := -1,
	colonist_id := -1
) -> Dictionary:
	return {
		"name": title,
		"state": "Present now" if ok else "At risk",
		"detail": detail,
		"action": action,
		"panel": panel,
		"focus_tile_id": tile_id,
		"colonist_id": colonist_id
	}


static func field(row: Variant, key: String, fallback: Variant = null) -> Variant:
	if row is Dictionary:
		return row.get(key, fallback)
	if row is Object:
		var value: Variant = row.get(key)
		return fallback if value == null else value
	return fallback


static func numeric(value: Variant) -> bool:
	return (value is float or value is int) and is_finite(float(value))


static func kind_name(value: Variant, domain: String) -> String:
	if value is String:
		return value.to_lower()
	var ordinal: Variant = value if value is int else field(value, "value")
	if not ordinal is int:
		return ""
	match domain:
		"tile":
			return ContinuumTileKind.parse_enum_name(ordinal).to_lower()
		"work":
			return ContinuumWorkType.parse_enum_name(ordinal).to_lower()
		"resource":
			return ContinuumResourceKind.parse_enum_name(ordinal).to_lower()
		"haul_role":
			if ordinal in ContinuumHaulRole.Options.values():
				return ContinuumHaulRole.parse_enum_name(ordinal).to_lower()
	return ""
