## Pure advisory projection of replicated rows, not an authoritative job-reason table.
class_name ColonyOperationsModel
extends RefCounted

const WORK = ["none", "logging", "mining", "hunting", "farming"]
const KINDS = ["empty", "sleep", "forest", "storage", "farm", "mine", "dining", "recreation"]
const RESOURCE = ["food", "wood", "stone", "meat"]
const ACTIVITIES = ["idle", "travelling", "working", "hauling", "eating", "sleeping", "recreating"]
const GOALS = ["nothing", "eat", "sleep", "recreate", "work", "haul"]
const ROLES = ["both", "producer", "hauler"]
const DEFINITIONS = [["logging", "forest", "wood"], ["mining", "mine", "stone"], ["hunting", "forest", "meat"], ["farming", "farm", "food"]]

static func _field(row: Variant, key: String, fallback: Variant = null) -> Variant:
	if row is Dictionary:
		return row.get(key, fallback)
	if row is Object and is_instance_valid(row) and key in row:
		return row.get(key)
	return fallback

## SDK enums expose value; fixtures may use ordinals or case-insensitive names.
## Unknown enum values remain unknown rather than being clamped to a known variant.
static func _enum(value: Variant, names: Array) -> String:
	if value is Dictionary or value is Object:
		value = _field(value, "value")
	if value is int and value >= 0 and value < names.size():
		return names[value]
	if value is String and value.to_lower() in names:
		return value.to_lower()
	return ""

static func _number(value: Variant) -> bool:
	return (value is int or value is float) and is_finite(float(value)) and value >= 0

static func _id(row: Variant, key: String = "id") -> int:
	var value: Variant = _field(row, key)
	return value if value is int and value >= 0 else -1

## Match backend f64 accumulation: stored, stacks by durable ID, then colonist
## cargo by durable ID. ID-less fixtures use an amount-sorted deterministic fallback.
static func _ordered_amounts(rows: Array) -> Array:
	rows.sort_custom(func(a, b):
		if a[0] != b[0]:
			return a[0] >= 0 and (b[0] < 0 or a[0] < b[0])
		return a[1] < b[1])
	var amounts: Array = []
	for row in rows:
		amounts.append(row[1])
	return amounts

static func _sum(values: Array) -> float:
	var total := 0.0
	for value in values:
		total += float(value)
	return total

## Unknown relevant quantities invalidate threshold evidence; they are never
## silently zeroed. A known other resource is irrelevant; explicit zero cargo
## with unknown kind contributes zero safely. Duplicate durable IDs are malformed.
static func _supply_component(rows: Array, resource: String, kind_field: String, amount_field: String) -> Dictionary:
	var quantities: Array = []
	var complete := true
	var ids: Dictionary = {}
	for row in rows:
		var kind := _enum(_field(row, kind_field), RESOURCE)
		var amount: Variant = _field(row, amount_field)
		if not kind.is_empty() and kind != resource:
			continue
		if not _number(amount) or (kind.is_empty() and amount != 0):
			complete = false
			continue
		var id := _id(row)
		if id >= 0:
			if ids.has(id):
				complete = false
			ids[id] = true
		quantities.append([id, float(amount)])
	var amounts := _ordered_amounts(quantities)
	var total := _sum(amounts)
	return {"complete": complete and is_finite(total), "amounts": amounts, "total": total}

## Invalid or duplicate policy rows leave the target unknown.
static func _policy(policies: Array, resource: String) -> Dictionary:
	var targets: Array = []
	var complete := true
	var matching := 0
	for policy in policies:
		var kind := _enum(_field(policy, "resource"), RESOURCE)
		if kind.is_empty():
			complete = false
		elif kind == resource:
			matching += 1
			var value: Variant = _field(policy, "target")
			if _number(value) and value > 0 and value <= 1000000:
				targets.append(float(value))
			else:
				complete = false
	targets.sort()
	return {"targets": targets, "target": targets[0] if complete and matching == 1 else null}

## Arrays must represent the caller's current subscription snapshot. Empty means known
## empty; malformed relevant rows downgrade negative diagnoses to unknown where possible.
## resources contains stored colony totals keyed by food/wood/stone/meat (not rates).
## context.physical_world=true selects finite mining intent from the complete public
## context.excavation_designations array; absent context preserves flat legacy work.
static func snapshot(tiles: Array, orders: Array, colonists: Array, stacks: Array, resources: Dictionary, policies: Array = [], context: Dictionary = {}) -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	for definition in DEFINITIONS:
		result.append(_entry(definition, tiles, orders, colonists, stacks, resources, policies, context))
	return result

static func _entry(definition: Array, tiles: Array, orders: Array, colonists: Array, stacks: Array, resources: Dictionary, policies: Array, context: Dictionary) -> Dictionary:
	var work: String = definition[0]
	var physical_mining: bool = work == "mining" and context.get("physical_world") is bool and context.get("physical_world") == true
	var facility: String = definition[1]
	var resource: String = definition[2]
	var sites: Array[int] = []
	var enabled_sites: Array[int] = []
	var active_sites: Array[int] = []
	var storage := 0
	var unknown_tiles := false
	var unknown_orders := false
	var unknown_workers := false
	for tile in tiles:
		var kind := _enum(_field(tile, "kind"), KINDS)
		var enabled: Variant = _field(tile, "enabled")
		if kind.is_empty() or _id(tile) < 0 or not enabled is bool:
			unknown_tiles = true
		if kind == "storage" and enabled is bool and enabled:
			storage += 1
		if kind == facility and _id(tile) >= 0:
			sites.append(_id(tile))
			if enabled is bool and enabled:
				enabled_sites.append(_id(tile))
	var matching_orders := 0
	var enabled_orders := 0
	for order in orders:
		var order_work := _enum(_field(order, "work"), WORK)
		var enabled: Variant = _field(order, "enabled")
		if order_work.is_empty() or (order_work == work and (_id(order, "tile_id") < 0 or not enabled is bool)):
			unknown_orders = true
		if order_work == work and _id(order, "tile_id") in enabled_sites:
			matching_orders += 1
			if enabled is bool and enabled:
				enabled_orders += 1
				active_sites.append(_id(order, "tile_id"))
	var producers := 0
	var ready := 0
	var needs := 0
	var working := 0
	var travelling := 0
	for worker in colonists:
		var worker_work := _enum(_field(worker, "work"), WORK)
		var role := _enum(_field(worker, "haul_role"), ROLES)
		var activity := _enum(_field(worker, "activity"), ACTIVITIES)
		var goal := _enum(_field(worker, "goal"), GOALS)
		var amount: Variant = _field(worker, "carried_amount")
		if worker_work.is_empty() or (worker_work == work and role.is_empty()):
			unknown_workers = true
		if worker_work != work or role not in ["both", "producer"]:
			continue
		producers += 1
		if activity in ["eating", "sleeping", "recreating"] or goal in ["eat", "sleep", "recreate"]:
			needs += 1
		elif not activity.is_empty() and _number(amount) and amount == 0 and activity != "hauling" and goal != "haul":
			ready += 1
			if activity == "working":
				working += 1
			elif activity == "travelling" and goal == "work":
				travelling += 1
	var ground_sites: Array[int] = []
	for stack in stacks:
		var amount: Variant = _field(stack, "amount")
		if _enum(_field(stack, "kind"), RESOURCE) == resource and _number(amount):
			if amount > 0 and _id(stack, "tile_id") >= 0:
				ground_sites.append(_id(stack, "tile_id"))
	var stored: Variant = resources.get(resource)
	var ground_supply := _supply_component(stacks, resource, "kind", "amount")
	var cargo_supply := _supply_component(colonists, resource, "carried_kind", "carried_amount")
	var supply_complete: bool = _number(stored) and ground_supply.complete and cargo_supply.complete
	var total_supply := 0.0
	if supply_complete:
		total_supply = float(stored)
		for amount in ground_supply.amounts:
			total_supply += amount
		for amount in cargo_supply.amounts:
			total_supply += amount
		supply_complete = is_finite(total_supply)
	var policy := _policy(policies, resource)
	var out := {"key": work, "name": work.capitalize(), "work_key": work, "work_name": work.capitalize(), "resource": resource, "state": "unknown", "summary": "Work status not established", "detail": "This is an advisory snapshot; reachability and server job reasons are unknown.", "suggested_action": "Inspect workers and work sites.", "focus_tile_id": -1, "ready_workers": ready, "active_orders": enabled_orders, "ground_amount": ground_supply.total, "stored_amount": float(stored) if _number(stored) else null, "carried_amount": cargo_supply.total, "total_supply": total_supply if supply_complete else null, "supply_complete": supply_complete, "target": policy.target, "policy_targets": policy.targets}
	var focus: Array[int] = active_sites if not active_sites.is_empty() else enabled_sites if not enabled_sites.is_empty() else sites
	if not focus.is_empty():
		focus.sort()
		out.focus_tile_id = focus[0]
	var excavation: Dictionary = _excavation(context.get("excavation_designations"), tiles) if physical_mining else {}
	if physical_mining:
		out.active_orders = 0
		out.focus_tile_id = excavation.focus_tile_id
		out["active_designations"] = excavation.active_designations
	if physical_mining and excavation.state != "designation_active":
		_status(out, excavation.state, excavation.summary, excavation.detail, excavation.suggested_action)
	elif not physical_mining and sites.is_empty() and not unknown_tiles:
		_status(out, "missing_facility", "Production stopped: no %s facility" % facility, "There is no facility for this profession.", "Inspect colony facilities.")
	elif not physical_mining and enabled_sites.is_empty() and not unknown_tiles:
		_status(out, "facility_disabled", "Production stopped: facilities switched off", "All matching facilities are disabled.", "Enable a %s facility." % facility)
	elif not physical_mining and enabled_orders == 0 and not unknown_orders and not unknown_tiles:
		if matching_orders > 0:
			_status(out, "orders_paused", "Production stopped: orders paused", "Orders on enabled facilities are switched off.", "Enable a %s order." % work)
		else:
			_status(out, "missing_orders", "Production stopped: no active site order", "No matching order exists on an enabled facility; orders at other facilities cannot enable this work.", "Create a %s order on an enabled %s." % [work, facility])
	elif supply_complete and policy.target != null and total_supply >= policy.target and (enabled_orders > 0 or physical_mining):
		_status(out, "target_reached", "Output suspended: %s target reached" % resource, "Expected standing-target suspension: %s total %s / %s target (stored + ground + carried). Manual intent is unchanged; already-made goods remain haulable. Output becomes eligible again after consumption or construction expenditure lowers total supply below the target, on the next simulation decision. A bounded action can overshoot the target." % [str(total_supply), resource, str(policy.target)], "Allow consumption or construction expenditure to reduce supply; inspect the production target. Hauling remains eligible and only moves supply between locations.")
	elif producers == 0 and not unknown_workers:
		_status(out, "no_producers", "Production stopped: no trained producers", "No colonist has this profession with a producing role. Dedicated haulers do not produce.", "Inspect profession and hauling roles.")
	elif producers > 0 and needs == producers and not unknown_workers:
		_status(out, "needs_precedence", "Needs currently take precedence", "All observed producers are attending to eating, sleep, or recreation (including travel toward those goals). This does not prove a blocked route.", "Inspect producers' needs and need facilities.")
	elif working > 0:
		_status(out, "producing", "Producers observed working", "Working activity is observed; output rate is not measured by this snapshot.", "Inspect active work sites.")
	elif travelling > 0:
		_status(out, "travelling", "Producers travelling to work", "Travel with a work goal is observed; arrival and route reachability are not guaranteed.", "Inspect travelling producers.")
	elif storage == 0 and not unknown_tiles and out.ground_amount + out.carried_amount > 0:
		_status(out, "no_storage", "Delivery has no enabled storage", "Already-made goods await delivery. This is a logistics observation, not proof that production is stopped.", "Enable storage and inspect haulers.")
	elif out.ground_amount + out.carried_amount > 0:
		_status(out, "awaiting_haul", "Already-made goods await hauling", "Ground goods or cargo are observed, not new production. A haul route is not established by this snapshot.", "Inspect storage and hauling roles.")
	elif physical_mining:
		_status(out, excavation.state, excavation.summary, excavation.detail, excavation.suggested_action)
	if physical_mining:
		out.detail += " Physical mining extracts finite designated cells, not Mine facility work orders."
		if excavation.state == "designation_active" and out.state != "designation_active":
			out.detail += " Enabled unfinished designation intent is present; reachable work faces remain unestablished."
		if not out.suggested_action.contains("Excavation"):
			out.suggested_action += " Inspect Excavation on the map."
	if out.ground_amount > 0:
		out.detail += " Already-made ground goods remain haulable independently of production orders; actual collection still needs a hauler and an enabled, reachable destination."
		if physical_mining:
			ground_sites = ground_sites.filter(func(id): return tiles.any(func(tile): return _id(tile) == id))
		if out.focus_tile_id < 0 and not ground_sites.is_empty():
			ground_sites.sort()
			out.focus_tile_id = ground_sites[0]
	if out.carried_amount > 0:
		out.detail += " %.1f %s is already in colonist cargo." % [out.carried_amount, resource]
	if storage == 0 and not unknown_tiles:
		out.detail += " No enabled storage is present; this does not by itself stop producer-only work."
	if policy.target != null and out.state != "target_reached":
		out.detail += " Standing %s target: %s." % [resource, str(policy.target)]
		if not supply_complete:
			out.detail += " Total supply is unavailable/incomplete; target suspension cannot be established."
	return out

## Public designation counters describe finite progress, not exposed work faces,
## reachable jobs, or material yield. Missing/malformed coverage is not known empty.
## A tile at a designation corner is a navigation anchor, not reachability evidence.
static func _excavation(rows: Variant, tiles: Array) -> Dictionary:
	var out := {"state": "unknown", "summary": "Excavation status not established", "detail": "Excavation designation data is unavailable or incomplete.", "suggested_action": "Inspect Excavation on the map.", "focus_tile_id": -1, "active_designations": 0}
	if not rows is Array:
		return out
	var unknown := false
	var unfinished := 0
	var focus_active: Array[int] = []
	var focus_unfinished: Array[int] = []
	var focus_all: Array[int] = []
	for row in rows:
		var total: Variant = _field(row, "total_cells")
		var completed: Variant = _field(row, "completed_cells")
		var enabled: Variant = _field(row, "enabled")
		if not total is int or total < 0 or not completed is int or completed < 0 or completed > total or not enabled is bool:
			unknown = true
			continue
		var pending: bool = completed < total
		if pending:
			unfinished += 1
			if enabled:
				out.active_designations += 1
		var x: Variant = _field(row, "x_0", _field(row, "x0"))
		var y: Variant = _field(row, "y_0", _field(row, "y0"))
		var z: Variant = _field(row, "bottom_z")
		if x is int and y is int and z is int:
			for tile in tiles:
				if _id(tile) >= 0 and _field(tile, "x") is int and _field(tile, "y") is int and _field(tile, "z") is int and _field(tile, "x") == x and _field(tile, "y") == y and _field(tile, "z") == z:
					focus_all.append(_id(tile))
					if pending:
						focus_unfinished.append(_id(tile))
						if enabled:
							focus_active.append(_id(tile))
	var focus: Array[int] = focus_active if not focus_active.is_empty() else focus_unfinished if not focus_unfinished.is_empty() else focus_all
	if not focus.is_empty():
		focus.sort()
		out.focus_tile_id = focus[0]
	if out.active_designations > 0:
		out.state = "designation_active"
		out.summary = "Enabled unfinished excavation work designated"
		out.detail = "Finite designated cells remain. This does not establish a reachable, unprotected work face or current extraction."
	elif not unknown:
		if rows.is_empty():
			out.state = "missing_designations"
			out.summary = "Mining stopped: no excavation designations"
			out.detail = "No finite excavation work is designated."
			out.suggested_action = "Designate excavation on the map."
		elif unfinished > 0:
			out.state = "designations_paused"
			out.summary = "Mining stopped: unfinished designations paused"
			out.detail = "All unfinished excavation designations are disabled."
			out.suggested_action = "Enable an unfinished designation in Excavation."
		else:
			out.state = "designations_completed"
			out.summary = "Mining stopped: designated finite deposits completed"
			out.detail = "Every replicated designation reports all cells completed; this says nothing about undesignated deposits elsewhere."
			out.suggested_action = "Designate additional excavation on the map."
	return out

static func _status(out: Dictionary, state: String, summary: String, detail: String, action: String) -> void:
	out.state = state
	out.summary = summary
	out.detail = detail + " Reachability is unknown."
	out.suggested_action = action
