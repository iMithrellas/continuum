## Headless contract tests; run with --headless --path client/godot --script this file.
extends SceneTree

const Model = preload("res://scripts/colony_operations_model.gd")
var failures: Array[String] = []


## Object fixtures exercise the same property and enum-value shape as generated rows.
class EnumRow:
	extends RefCounted
	var value: int

	func _init(ordinal: int) -> void:
		value = ordinal


class TileRow:
	extends RefCounted
	var id := 9
	var kind = EnumRow.new(2)
	var enabled := true


class PolicyRow:
	extends RefCounted
	var resource = EnumRow.new(1)
	var target := 10.0


func _initialize() -> void:
	var tiles: Array = [
		{"id": 8, "kind": "Forest", "enabled": true}, {"id": 2, "kind": 3, "enabled": true}
	]
	var orders: Array = [
		{"tile_id": 8, "work": "logging", "enabled": true},
		{"tile_id": 8, "work": "hunting", "enabled": false}
	]
	var worker := {
		"work": {"value": 1},
		"haul_role": "both",
		"activity": "working",
		"goal": "work",
		"carried_kind": "wood",
		"carried_amount": 0.0
	}
	var rows := Model.snapshot(tiles, orders, [worker], [], {"wood": 12.0})
	check(
		rows.size() == 4 and rows[0].key == "logging" and rows[2].resource == "meat",
		"stable profession/resource mapping"
	)
	check(
		rows[0].state == "producing" and rows[0].ready_workers == 1 and rows[0].active_orders == 1,
		"logging enabled independently from hunting on same Forest"
	)
	check(rows[2].state == "orders_paused", "paused hunting does not inherit logging order")
	check(
		rows[0].stored_amount == 12 and rows[1].stored_amount == null,
		"stored inventory does not invent missing totals"
	)
	check(
		Model.snapshot(tiles, [], [worker], [], {})[0].state == "missing_orders",
		"missing order stops production"
	)
	check(
		(
			(
				Model
				. snapshot(
					[{"id": 8, "kind": "forest", "enabled": false}], orders, [worker], [], {}
				)[0]
				. state
			)
			== "facility_disabled"
		),
		"facility switch stops production"
	)
	check(
		Model.snapshot([], orders, [worker], [], {})[0].state == "missing_facility",
		"missing facility"
	)
	check(
		Model.snapshot(tiles, orders, [], [], {})[0].state == "no_producers", "no trained producer"
	)
	var hauler := worker.duplicate(true)
	hauler.haul_role = "hauler"
	check(
		Model.snapshot(tiles, orders, [hauler], [], {})[0].state == "no_producers",
		"dedicated hauler is not a producer"
	)
	var hungry := worker.duplicate(true)
	hungry.activity = "travelling"
	hungry.goal = "eat"
	rows = Model.snapshot(tiles, orders, [hungry], [], {})
	check(
		(
			rows[0].state == "needs_precedence"
			and rows[0].ready_workers == 0
			and rows[0].detail.contains("does not prove a blocked route")
		),
		"need-goal travel is not production travel or blocked-route evidence"
	)
	hungry.goal = "work"
	check(
		Model.snapshot(tiles, orders, [hungry], [], {})[0].state == "travelling",
		"explicit work-goal travel"
	)
	worker["hunger"] = 100
	check(
		Model.snapshot(tiles, orders, [worker], [], {})[0].state == "producing",
		"raw need magnitude cannot override observed working activity"
	)
	var stack_rows: Array = [
		{"tile_id": 8, "kind": "wood", "amount": 7.0},
		{"tile_id": 99, "kind": {"value": 1}, "amount": 3.0},
		{"kind": "meat", "amount": 20}
	]
	var carrying := worker.duplicate(true)
	carrying.carried_amount = 4.0
	carrying.activity = "hauling"
	carrying.goal = "haul"
	rows = Model.snapshot(tiles, [], [carrying], stack_rows, {"wood": 6})
	check(
		(
			rows[0].state == "missing_orders"
			and rows[0].ground_amount == 10
			and rows[0].carried_amount == 4
			and rows[0].stored_amount == 6
		),
		"stocks, cargo, and stored totals kept separate from production stop"
	)
	check(
		rows[0].detail.contains("remain haulable") and rows[0].detail.contains("cargo"),
		"paused/missing production orders do not erase already-made goods"
	)
	var paused_orders: Array = [{"tile_id": 8, "work": "logging", "enabled": false}]
	rows = Model.snapshot(tiles, paused_orders, [carrying], stack_rows, {})
	check(
		(
			rows[0].state == "orders_paused"
			and rows[0].ground_amount == 10
			and rows[0].detail.contains("remain haulable")
		),
		"paused logging leaves wood available for hauling"
	)
	check(
		Model.snapshot([tiles[0]], orders, [carrying], stack_rows, {})[0].state == "no_storage",
		"no enabled destination observed, without asserting production stopped"
	)
	check(
		Model.snapshot(tiles, orders, [carrying], stack_rows, {})[0].state == "awaiting_haul",
		"enabled storage plus goods only establishes awaiting haul"
	)
	check(
		(
			(
				Model
				. snapshot(
					[TileRow.new()],
					[{"tile_id": 9, "work": EnumRow.new(1), "enabled": true}],
					[worker],
					[],
					{}
				)[0]
				. state
			)
			== "producing"
		),
		"object rows and SDK-shaped enums normalized"
	)
	var live_tile := ContinuumTile.new()
	live_tile.id = 8
	live_tile.kind = ContinuumTileKind.create(2)
	live_tile.enabled = true
	var live_order := ContinuumWorkOrder.new()
	live_order.tile_id = 8
	live_order.work = ContinuumWorkType.create(1)
	live_order.enabled = true
	var live_worker := ContinuumColonist.new()
	live_worker.work = ContinuumWorkType.create(1)
	live_worker.haul_role = ContinuumHaulRole.create(0)
	live_worker.activity = ContinuumActivity.create(2)
	live_worker.goal = ContinuumGoal.create(4)
	live_worker.carried_kind = ContinuumResourceKind.create(1)
	live_worker.carried_amount = 0
	check(
		Model.snapshot([live_tile], [live_order], [live_worker], [], {})[0].state == "producing",
		"actual generated replicated row adapters"
	)
	rows = Model.snapshot(
		[null, {}, {"id": 1, "kind": 999}],
		[false, {}],
		[null, {}],
		[null, {"kind": "wood", "amount": NAN}],
		{"wood": INF},
		[null, {"resource": "wood", "target": -1}]
	)
	check(
		rows[0].state == "unknown" and rows[0].ground_amount == 0 and rows[0].stored_amount == null,
		"unknown rows do not invent a negative diagnosis or invalid inventory"
	)
	check(
		rows[0].focus_tile_id == -1 and rows[0].policy_targets.is_empty(),
		"absent focus and invalid optional policy"
	)
	var policies: Array = [
		{"resource": "wood", "target": 30}, {"resource": {"value": 1}, "target": 15}
	]
	tiles.append({"id": 3, "kind": "forest", "enabled": true})
	orders.append({"tile_id": 3, "work": "logging", "enabled": true})
	var baseline := Model.snapshot(
		tiles, orders, [worker, carrying], stack_rows, {"wood": 6}, policies
	)
	check(
		baseline[0].focus_tile_id == 3 and baseline[0].active_orders == 2,
		"lowest active focus independent of input order"
	)
	check(
		(
			baseline[0].policy_targets == [15.0, 30.0]
			and baseline[0].target == null
			and baseline[0].state == "producing"
		),
		"duplicate policy keys are ambiguous, not an inferred effective target"
	)
	for iteration in range(30):
		var shuffled_tiles := tiles.duplicate(true)
		var shuffled_orders := orders.duplicate(true)
		var shuffled_workers: Array = [worker, carrying]
		var shuffled_stacks := stack_rows.duplicate(true)
		var shuffled_policies := policies.duplicate(true)
		shuffled_tiles.shuffle()
		shuffled_orders.shuffle()
		shuffled_workers.shuffle()
		shuffled_stacks.shuffle()
		shuffled_policies.shuffle()
		check(
			(
				Model.snapshot(
					shuffled_tiles,
					shuffled_orders,
					shuffled_workers,
					shuffled_stacks,
					{"wood": 6},
					shuffled_policies
				)
				== baseline
			),
			"deterministic output under row shuffles %d" % iteration
		)
	_test_physical_mining()
	_test_production_targets()
	for message in failures:
		push_error(message)
	if failures.is_empty():
		print("COLONY_OPERATIONS_MODEL_PASS")
	quit(0 if failures.is_empty() else 1)


## Live mining ignores facility/order intent; legacy callers retain the flat model.
func _test_physical_mining() -> void:
	var worker := {
		"work": "mining",
		"haul_role": "producer",
		"activity": "idle",
		"goal": "nothing",
		"carried_amount": 0,
		"carried_kind": "stone"
	}
	var active := {
		"id": 700,
		"x0": 4,
		"y0": 5,
		"bottom_z": -3,
		"total_cells": 10,
		"completed_cells": 2,
		"enabled": true
	}
	var paused := active.duplicate(true)
	paused.enabled = false
	var completed := active.duplicate(true)
	completed.completed_cells = 10
	var context := {"physical_world": true, "excavation_designations": []}
	var rows := Model.snapshot([], [], [worker], [], {}, [], context)
	check(
		(
			rows[1].state == "missing_designations"
			and rows[1].focus_tile_id == -1
			and rows[1].suggested_action.contains("Excavation")
		),
		"live empty excavation set diagnoses no designations, not missing Mine"
	)
	context.excavation_designations = [paused, completed]
	rows = Model.snapshot([], [], [worker], [], {}, [], context)
	check(
		rows[1].state == "designations_paused" and rows[1].active_designations == 0,
		"only unfinished paused designations block new extraction"
	)
	context.excavation_designations = [completed]
	rows = Model.snapshot([], [], [worker], [], {}, [], context)
	check(
		(
			rows[1].state == "designations_completed"
			and rows[1].detail.contains("undesignated deposits")
		),
		"finite designation completion is not depletion of the entire world"
	)
	completed.enabled = false
	check(
		Model.snapshot([], [], [worker], [], {}, [], context)[1].state == "designations_completed",
		"completed disabled designation is completed, not paused"
	)
	context.excavation_designations = [active, paused, completed]
	rows = Model.snapshot([], [], [worker], [], {}, [], context)
	check(
		(
			rows[1].state == "designation_active"
			and rows[1].active_designations == 1
			and rows[1].active_orders == 0
			and rows[1].focus_tile_id == -1
		),
		"enabled unfinished designation without facility/orders is available intent, not reachable production"
	)
	check(
		(
			rows[1].detail.contains("Reachability is unknown")
			and rows[1].detail.contains("not establish a reachable")
		),
		"unfinished counters do not establish mining reachability"
	)
	var tiles: Array = [
		{"id": 700, "kind": "mine", "enabled": false, "x": 9, "y": 9, "z": 0},
		{"id": 12, "kind": "empty", "enabled": true, "x": 4, "y": 5, "z": -3},
		{"id": 4, "kind": "empty", "enabled": true, "x": 4, "y": 5, "z": -3}
	]
	var legacy_orders: Array = [{"tile_id": 700, "work": "mining", "enabled": false}]
	rows = Model.snapshot(tiles, legacy_orders, [worker], [], {}, [], context)
	check(
		rows[1].state == "designation_active" and rows[1].focus_tile_id == 4,
		"focus uses lowest safely matched existing corner tile, not designation ID or synthetic work destination"
	)
	check(
		Model.snapshot(tiles, legacy_orders, [worker], [], {})[1].state == "facility_disabled",
		"context absent preserves flat legacy facility diagnosis"
	)
	check(
		(
			(
				Model
				. snapshot(
					tiles,
					legacy_orders,
					[worker],
					[],
					{},
					[],
					{"physical_world": false, "excavation_designations": [active]}
				)[1]
				. state
			)
			== "facility_disabled"
		),
		"explicit false remains legacy"
	)
	check(
		(
			Model.snapshot([], [], [worker], [], {}, [], {"physical_world": true})[1].state
			== "unknown"
		),
		"missing designation collection is unavailable, not empty"
	)
	check(
		(
			(
				Model
				. snapshot(
					[],
					[],
					[worker],
					[],
					{},
					[],
					{
						"physical_world": true,
						"excavation_designations":
						[
							null,
							{"enabled": false},
							{"total_cells": 2, "completed_cells": 3, "enabled": true}
						]
					}
				)[1]
				. state
			)
			== "unknown"
		),
		"malformed designation rows cannot prove a stop"
	)
	check(
		(
			(
				Model
				. snapshot(
					[],
					[],
					[worker],
					[],
					{},
					[],
					{"physical_world": true, "excavation_designations": [null, active]}
				)[1]
				. state
			)
			== "designation_active"
		),
		"positive enabled intent survives partial unknown coverage"
	)
	var live_designation := ContinuumExcavationDesignation.new()
	live_designation.enabled = true
	live_designation.total_cells = 8
	live_designation.completed_cells = 3
	check(
		(
			(
				Model
				. snapshot(
					[],
					[],
					[worker],
					[],
					{},
					[],
					{"physical_world": true, "excavation_designations": [live_designation]}
				)[1]
				. state
			)
			== "designation_active"
		),
		"generated live designation row counters normalized"
	)
	live_designation.x_0 = 4
	live_designation.y_0 = 5
	live_designation.bottom_z = -3
	var live_anchor := ContinuumTile.new()
	live_anchor.id = 42
	live_anchor.x = 4
	live_anchor.y = 5
	live_anchor.z = -3
	live_anchor.kind = ContinuumTileKind.create(0)
	live_anchor.enabled = true
	var live_context := {"physical_world": true, "excavation_designations": [live_designation]}
	check(
		(
			Model.snapshot([live_anchor], [], [worker], [], {}, [], live_context)[1].focus_tile_id
			== 42
		),
		"generated x_0/y_0 designation resolves exact existing generated tile at bottom elevation"
	)
	live_anchor.z = -2
	check(
		(
			Model.snapshot([live_anchor], [], [worker], [], {}, [], live_context)[1].focus_tile_id
			== -1
		),
		"generated designation must not focus a tile at wrong elevation"
	)
	var primary_corner := {
		"x_0": 4,
		"y_0": 5,
		"x0": 9,
		"y0": 9,
		"bottom_z": -3,
		"total_cells": 8,
		"completed_cells": 3,
		"enabled": true
	}
	live_anchor.z = -3
	check(
		(
			(
				Model
				. snapshot(
					[live_anchor],
					[],
					[worker],
					[],
					{},
					[],
					{"physical_world": true, "excavation_designations": [primary_corner]}
				)[1]
				. focus_tile_id
			)
			== 42
		),
		"generated coordinate spelling takes precedence over legacy dictionary aliases"
	)
	primary_corner.x_0 = null
	check(
		(
			(
				Model
				. snapshot(
					[live_anchor],
					[],
					[worker],
					[],
					{},
					[],
					{"physical_world": true, "excavation_designations": [primary_corner]}
				)[1]
				. focus_tile_id
			)
			== -1
		),
		"malformed explicit primary coordinate cannot fall back into a false focus"
	)
	worker.activity = "working"
	worker.goal = "work"
	rows = Model.snapshot([], [], [worker], [], {}, [], context)
	check(
		rows[1].state == "producing" and rows[1].suggested_action.contains("Excavation"),
		"physical mining observes working with active designation and no Mine facility"
	)
	worker.activity = "travelling"
	check(
		Model.snapshot([], [], [worker], [], {}, [], context)[1].state == "travelling",
		"physical mining observes work-goal travel"
	)
	worker.goal = "eat"
	check(
		Model.snapshot([], [], [worker], [], {}, [], context)[1].state == "needs_precedence",
		"physical mining retains need-goal precedence"
	)
	check(
		Model.snapshot([], [], [], [], {}, [], context)[1].state == "no_producers",
		"active excavation still requires trained producers"
	)
	var stacks: Array = [{"tile_id": 99, "kind": "stone", "amount": 3}]
	context.excavation_designations = []
	rows = Model.snapshot([], [], [worker], stacks, {}, [], context)
	check(
		(
			rows[1].state == "missing_designations"
			and rows[1].ground_amount == 3
			and rows[1].detail.contains("remain haulable")
			and rows[1].focus_tile_id == -1
		),
		"no live designation does not erase haulable stone; dangling stack key is not navigation"
	)
	context.excavation_designations = [completed]
	worker.carried_amount = 2
	rows = Model.snapshot([], [], [worker], stacks, {"stone": 4}, [], context)
	check(
		(
			rows[1].state == "designations_completed"
			and rows[1].carried_amount == 2
			and rows[1].ground_amount == 3
			and rows[1].stored_amount == 4
		),
		"completed finite deposits retain cargo, ground and stored inventories separately"
	)
	worker.carried_amount = 0
	context.excavation_designations = [active, paused, completed]
	var baseline := Model.snapshot(tiles, legacy_orders, [worker], stacks, {}, [], context)
	for iteration in range(10):
		tiles.shuffle()
		context.excavation_designations.shuffle()
		check(
			Model.snapshot(tiles, legacy_orders, [worker], stacks, {}, [], context) == baseline,
			"physical designation row shuffle stability %d" % iteration
		)
	var default_rows := Model.snapshot(tiles, legacy_orders, [worker], stacks, {})
	check(
		(
			baseline[0] == default_rows[0]
			and baseline[2] == default_rows[2]
			and baseline[3] == default_rows[3]
		),
		"physical mining context leaves other profession entries unchanged"
	)


## Threshold evidence includes stored stock, piles and every carrier, not just
## producers. Manual intent and finite completion always precede automation.
func _test_production_targets() -> void:
	var tiles: Array = [
		{"id": 8, "kind": "forest", "enabled": true}, {"id": 2, "kind": "storage", "enabled": true}
	]
	var orders: Array = [
		{"tile_id": 8, "work": "logging", "enabled": true},
		{"tile_id": 8, "work": "hunting", "enabled": true}
	]
	var workers: Array = [
		{
			"id": 2,
			"work": "logging",
			"haul_role": "producer",
			"activity": "working",
			"goal": "work",
			"carried_kind": "wood",
			"carried_amount": 0
		},
		{
			"id": 1,
			"work": "hunting",
			"haul_role": "hauler",
			"activity": "hauling",
			"goal": "haul",
			"carried_kind": "wood",
			"carried_amount": 3
		}
	]
	var stacks: Array = [
		{"id": 9, "tile_id": 8, "kind": "wood", "amount": 2},
		{"id": 3, "tile_id": 8, "kind": "wood", "amount": 4}
	]
	var policies: Array = [
		{"resource": {"value": 1}, "target": 10}, {"resource": "meat", "target": 20}
	]
	var resources := {"wood": 1, "meat": 0}
	var rows := Model.snapshot(tiles, orders, workers, stacks, resources, policies)
	check(
		(
			rows[0].state == "target_reached"
			and rows[0].target == 10
			and rows[0].total_supply == 10
			and rows[0].supply_complete
		),
		"stock + ground + cargo from other professions reaches exact target"
	)
	check(
		(
			rows[0].ground_amount == 6
			and rows[0].carried_amount == 3
			and rows[0].stored_amount == 1
			and rows[0].active_orders == 1
		),
		"suspension preserves goods and enabled order counts"
	)
	check(
		(
			rows[0].detail.contains("remain haulable")
			and rows[0].detail.contains("next simulation decision")
			and rows[0].suggested_action.contains("consumption")
		),
		"target suspension explains hauling and resume on consumption"
	)
	check(
		rows[2].state != "target_reached" and rows[2].target == 20 and rows[2].total_supply == 0,
		"shared Forest uses independent Wood and Meat target policies"
	)
	check(
		(
			Model.snapshot(tiles, orders, workers, stacks, resources, [PolicyRow.new()])[0].state
			== "target_reached"
		),
		"typed policy row property/enum adapter"
	)
	var other_tiles: Array = [
		{"id": 1, "kind": "farm", "enabled": true}, {"id": 2, "kind": "mine", "enabled": true}
	]
	var other_orders: Array = [
		{"tile_id": 1, "work": "farming", "enabled": true},
		{"tile_id": 2, "work": "mining", "enabled": true}
	]
	rows = Model.snapshot(
		other_tiles,
		other_orders,
		[],
		[],
		{"food": 10, "stone": 10},
		[{"resource": 0, "target": 10}, {"resource": 2, "target": 10}]
	)
	check(
		rows[1].state == "target_reached" and rows[3].state == "target_reached",
		"Food farming and flat legacy Stone mining obey independent targets"
	)
	resources.wood = 0.999999
	check(
		(
			Model.snapshot(tiles, orders, workers, stacks, resources, policies)[0].state
			!= "target_reached"
		),
		"below target has no invented comparison tolerance"
	)
	resources.wood = 2
	check(
		(
			Model.snapshot(tiles, orders, workers, stacks, resources, policies)[0].state
			== "target_reached"
		),
		"overshoot still suspends"
	)
	orders[0].enabled = false
	check(
		(
			Model.snapshot(tiles, orders, workers, stacks, resources, policies)[0].state
			== "orders_paused"
		),
		"manual order pause precedes target reached"
	)
	check(
		(
			Model.snapshot(tiles, [], workers, stacks, resources, policies)[0].state
			== "missing_orders"
		),
		"missing order precedes target reached"
	)
	orders[0].enabled = true
	tiles[0].enabled = false
	check(
		(
			Model.snapshot(tiles, orders, workers, stacks, resources, policies)[0].state
			== "facility_disabled"
		),
		"manual facility disable precedes target reached"
	)
	tiles[0].enabled = true
	for invalid_stock in [null, NAN, INF, -1, "12"]:
		var invalid_resources := {"wood": invalid_stock}
		rows = Model.snapshot(tiles, orders, workers, stacks, invalid_resources, policies)
		check(
			(
				rows[0].state != "target_reached"
				and not rows[0].supply_complete
				and rows[0].total_supply == null
			),
			"invalid/missing stored total prevents target inference"
		)
	check(
		Model.snapshot(tiles, orders, workers, stacks, {}, policies)[0].state != "target_reached",
		"absent stored total cannot imply suspension"
	)
	for invalid_amount in [null, NAN, INF, -1, "8"]:
		var invalid_stacks := stacks.duplicate(true)
		invalid_stacks.append({"id": 99, "kind": "wood", "amount": invalid_amount})
		rows = Model.snapshot(tiles, orders, workers, invalid_stacks, resources, policies)
		check(
			rows[0].state != "target_reached" and rows[0].total_supply == null,
			"incomplete or nonfinite pile cannot be silently ignored"
		)
		var invalid_workers := workers.duplicate(true)
		invalid_workers[1].carried_amount = invalid_amount
		check(
			(
				Model.snapshot(tiles, orders, invalid_workers, stacks, resources, policies)[0].state
				!= "target_reached"
			),
			"invalid cargo prevents target inference"
		)
	check(
		(
			Model.snapshot(tiles, orders, workers, stacks + [null], resources, policies)[0].state
			!= "target_reached"
		),
		"unknown stack resource/amount prevents complete supply evidence"
	)
	check(
		(
			Model.snapshot(tiles, orders, workers + [{}], stacks, resources, policies)[0].state
			!= "target_reached"
		),
		"unknown carrier resource/amount prevents complete supply evidence"
	)
	check(
		(
			(
				Model
				. snapshot(tiles, orders, workers, stacks + [stacks[0]], resources, policies)[0]
				. total_supply
			)
			== null
		),
		"duplicate durable stack IDs do not establish supply"
	)
	rows = Model.snapshot(
		tiles, orders, [], [{"id": 1, "kind": "wood", "amount": 1e308}], {"wood": 1e308}, policies
	)
	check(
		(
			not rows[0].supply_complete
			and rows[0].total_supply == null
			and rows[0].state != "target_reached"
		),
		"nonfinite accumulated total cannot establish suspension"
	)
	var f32_tenth := float(PackedFloat32Array([0.1])[0])
	check(
		(
			(
				Model
				. snapshot(
					tiles,
					orders,
					[],
					[],
					{"wood": f32_tenth},
					[{"resource": "wood", "target": f32_tenth}]
				)[0]
				. state
			)
			== "target_reached"
		),
		"promoted f32 stock and target compare at exact equality"
	)
	check(
		(
			(
				Model
				. snapshot(
					tiles,
					orders,
					[],
					[],
					{"wood": f32_tenth - 1e-12},
					[{"resource": "wood", "target": f32_tenth}]
				)[0]
				. state
			)
			!= "target_reached"
		),
		"display rounding cannot turn just-below supply into suspension"
	)
	for invalid_target in [0, -1, 1000001, NAN, INF, null, "10"]:
		rows = Model.snapshot(
			tiles,
			orders,
			workers,
			stacks,
			resources,
			[{"resource": "wood", "target": invalid_target}]
		)
		check(
			rows[0].target == null and rows[0].state != "target_reached",
			"invalid target cannot be clamped into valid enforcement"
		)
	check(
		(
			(
				Model
				. snapshot(
					tiles,
					orders,
					workers,
					stacks,
					resources,
					policies + [{"resource": "wood", "target": 10}]
				)[0]
				. target
			)
			== null
		),
		"duplicate actual policy key cannot invent an effective target"
	)
	check(
		(
			Model.snapshot(tiles, orders, workers, stacks, resources, policies + [{}])[0].target
			== null
		),
		"unknown policy resource prevents effective-target inference"
	)
	var context := {
		"physical_world": true,
		"excavation_designations": [{"total_cells": 10, "completed_cells": 2, "enabled": true}]
	}
	rows = Model.snapshot(
		[],
		[],
		[],
		[{"id": 1, "kind": "stone", "amount": 3}],
		{"stone": 7},
		[{"resource": 2, "target": 10}],
		context
	)
	check(
		(
			rows[1].state == "target_reached"
			and rows[1].active_designations == 1
			and rows[1].active_orders == 0
			and rows[1].detail.contains("haulable")
		),
		"Stone target suspends finite excavation without a Mine or work order"
	)
	context.excavation_designations[0].enabled = false
	check(
		(
			(
				Model
				. snapshot([], [], [], [], {"stone": 10}, [{"resource": 2, "target": 10}], context)[1]
				. state
			)
			== "designations_paused"
		),
		"manually paused excavation precedes Stone target"
	)
	context.excavation_designations[0].completed_cells = 10
	check(
		(
			(
				Model
				. snapshot([], [], [], [], {"stone": 10}, [{"resource": 2, "target": 10}], context)[1]
				. state
			)
			== "designations_completed"
		),
		"finite completion precedes Stone target"
	)
	context.excavation_designations = []
	check(
		(
			(
				Model
				. snapshot([], [], [], [], {"stone": 10}, [{"resource": 2, "target": 10}], context)[1]
				. state
			)
			== "missing_designations"
		),
		"missing excavation intent precedes Stone target"
	)
	var precise_stacks: Array = [
		{"id": 2, "kind": "wood", "amount": 1.0}, {"id": 1, "kind": "wood", "amount": pow(2.0, 53)}
	]
	var precise_workers: Array = [
		{"id": 2, "carried_kind": "wood", "carried_amount": 1.0},
		{"id": 1, "carried_kind": "wood", "carried_amount": 1.0}
	]
	var stable := Model.snapshot(
		tiles,
		orders,
		precise_workers,
		precise_stacks,
		{"wood": 1.0},
		[{"resource": "wood", "target": 1000000}]
	)
	check(
		stable[0].total_supply == pow(2.0, 53),
		"durable-ID accumulation matches backend f64 rounding"
	)
	for iteration in range(10):
		precise_stacks.shuffle()
		precise_workers.shuffle()
		check(
			(
				Model.snapshot(
					tiles,
					orders,
					precise_workers,
					precise_stacks,
					{"wood": 1.0},
					[{"resource": "wood", "target": 1000000}]
				)
				== stable
			),
			"durable-ID target evidence invariant under row shuffle"
		)


func check(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)
