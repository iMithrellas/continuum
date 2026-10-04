## Pure safety/regression tests plus the real main → panel → map/workspace path.
extends Node

const Guidance = preload("res://scripts/colony_guidance_model.gd")
var failed := false


func _ready() -> void:
	await get_tree().process_frame
	_test_model()
	_test_productive_capacity()
	await _test_integration()
	print("COLONY_GUIDANCE_TEST: %s" % ("FAIL" if failed else "PASS"))
	get_tree().quit(1 if failed else 0)


func _test_model() -> void:
	var model := Guidance.new()
	var tiles: Array = []
	for index in Guidance.ESSENTIALS.size():
		tiles.append({"id": index, "kind": Guidance.ESSENTIALS[index], "enabled": true})
	var people: Array = [
		{
			"id": 0,
			"work": "farming",
			"haul_role": "producer",
			"hunger": 20,
			"fatigue": 20,
			"recreation": 20,
			"mood": 80,
			"productivity": 80
		}
	]
	var orders: Array = [{"tile_id": 0, "work": "farming", "enabled": true}]
	var result := model.snapshot(0, 1, tiles, orders, people, [], {"food": 10})
	_assert(result.milestones[4].state == "Observing", "one safe frame is not sustained safety")
	for _index in 10:
		result = model.snapshot(0, 1, tiles, orders, people, [], {"food": 10})
	_assert(result.observed_seconds == 0, "paused and duplicate frames cannot establish recovery")
	for seconds in [900, 1800, 2700, 3600]:
		result = model.snapshot(seconds, 1, tiles, orders, people, [], {"food": 10})
	_assert(
		result.milestones[4].state == "Observed recovery",
		"contiguous safe samples establish bounded session recovery"
	)
	people[0].hunger = 90
	result = model.snapshot(3606, 1, tiles, orders, people, [], {"food": 100})
	_assert(
		result.milestones[2].state == "At risk" and result.observed_seconds == 0,
		"abundant stocks cannot hide an unfed colonist; milestone revokes"
	)
	people[0].hunger = 20
	result = model.snapshot(
		3612, 1, tiles, orders, people, [{"kind": "food", "amount": 100}], {"food": 0}
	)
	_assert(
		result.milestones[0].state == "At risk" and result.next.name == "Food delivered to stores",
		"ground food is not delivered stock"
	)
	tiles[0].enabled = false
	result = model.snapshot(3618, 1, tiles, orders, people, [], {"food": 10})
	_assert(
		result.milestones[1].state == "At risk" and result.milestones[3].state == "At risk",
		"disabled facilities invalidate productive orders"
	)
	tiles[0].enabled = true
	orders[0].tile_id = 999
	result = model.snapshot(3624, 1, tiles, orders, people, [], {"food": 10})
	_assert(result.milestones[3].state == "At risk", "orphan orders are not productive")
	orders[0].tile_id = 0
	for seconds in [4000, 4900, 5800, 6700, 7600]:
		result = model.snapshot(seconds, 1, tiles, orders, people, [], {"food": 10})
	_assert(result.milestones[4].state == "Observed recovery", "recovery can be re-established")
	result = model.snapshot(7606, 1, tiles, orders, people, [], {"food": 9})
	_assert(
		result.observed_seconds == 0 and result.milestones[4].state == "Observing",
		"food imbalance revokes recovery even above reserve"
	)
	result = model.snapshot(20000, 1, tiles, orders, people, [], {"food": 10})
	_assert(result.observed_seconds == 0, "sample gaps discard evidence")
	result = model.snapshot(0, 2, tiles, orders, people, [], {"food": 10})
	_assert(result.observed_seconds == 0, "generation reset and clock rollback discard evidence")
	people[0].mood = NAN
	result = model.snapshot(1, 2, tiles, orders, people, [], {"food": 10})
	_assert(result.milestones[2].state == "At risk", "nonfinite need data cannot be safe")
	result = model.snapshot(9000, 2, tiles, orders, people, [], {"food": 10}, [], false)
	_assert(
		not result.ready and result.milestones.is_empty(),
		"disconnected and warming snapshots fail closed"
	)


func _test_productive_capacity() -> void:
	var model := Guidance.new()
	var tiles: Array = []
	for index in Guidance.ESSENTIALS.size():
		tiles.append({"id": index, "kind": Guidance.ESSENTIALS[index], "enabled": true})
	tiles.append({"id": 100, "kind": ContinuumTileKind.create_forest(), "enabled": true})
	tiles.append({"id": 101, "kind": ContinuumTileKind.create_empty(), "enabled": true})
	var hunter := {
		"id": 0,
		"work": ContinuumWorkType.create_hunting(),
		"haul_role": ContinuumHaulRole.create_producer(),
		"hunger": 20,
		"fatigue": 20,
		"recreation": 20,
		"mood": 80,
		"productivity": 80
	}
	var hunting := {"tile_id": 100, "work": ContinuumWorkType.create_hunting(), "enabled": true}
	var orders: Array = [hunting]
	var people: Array = [hunter]
	var result := _capacity(model, tiles, orders, people)
	_assert(
		result.milestones[3].state == "Present now" and result.milestones[3].focus_tile_id == 100,
		"hunting producers use Forest facilities"
	)
	hunting.tile_id = 101
	result = _capacity(model, tiles, orders, people)
	_assert(result.milestones[3].state == "At risk", "Empty facilities cannot support hunting")
	hunting.tile_id = 100
	for role in [
		ContinuumHaulRole.create_producer(),
		ContinuumHaulRole.Options.producer,
		"producer",
		ContinuumHaulRole.create_both(),
		ContinuumHaulRole.Options.both,
		"Both"
	]:
		hunter.haul_role = role
		result = _capacity(model, tiles, orders, people)
		_assert(
			result.milestones[3].state == "Present now",
			"explicit producer-capable generated, ordinal and named roles prove capacity"
		)
	for role in [
		ContinuumHaulRole.create_hauler(),
		ContinuumHaulRole.Options.hauler,
		"hauler",
		null,
		"unknown",
		-1,
		999,
		true
	]:
		hunter.haul_role = role
		result = _capacity(model, tiles, orders, people)
		_assert(
			result.milestones[3].state == "At risk",
			"hauler-only and unknown roles cannot prove production"
		)
	hunter.erase("haul_role")
	result = _capacity(model, tiles, orders, people)
	_assert(result.milestones[3].state == "At risk", "missing haul role is not implicitly Both")
	hunter.haul_role = ContinuumHaulRole.create_hauler()
	model.reset()
	for seconds in [0, 900, 1800, 2700, 3600, 4500]:
		result = _capacity(model, tiles, orders, people, seconds)
	_assert(
		result.milestones[4].state == "At risk" and result.observed_seconds == 0,
		"wellbeing, facilities and abundant food cannot establish recovery with only haulers"
	)
	hunter.haul_role = ContinuumHaulRole.create_producer()
	hunting.tile_id = 101
	model.reset()
	for seconds in [0, 900, 1800, 2700, 3600]:
		result = _capacity(model, tiles, orders, people, seconds)
	_assert(
		result.milestones[4].state == "At risk" and result.observed_seconds == 0,
		"hunting on Empty cannot establish recovery without actual productive capacity"
	)
	hunting.tile_id = 100
	var logger := hunter.duplicate(true)
	logger.id = 1
	logger.work = ContinuumWorkType.create_logging()
	var logging := {"tile_id": 100, "work": ContinuumWorkType.create_logging(), "enabled": true}
	orders.append(logging)
	people.append(logger)
	result = _capacity(model, tiles, orders, people)
	_assert(
		result.milestones[3].detail.begins_with("2 enabled"),
		"shared Forest supports independent hunting and logging jobs"
	)
	hunting.enabled = false
	result = _capacity(model, tiles, orders, people)
	_assert(
		result.milestones[3].detail.begins_with("1 enabled"),
		"disabling hunting leaves logging capacity on the shared Forest"
	)
	hunting.enabled = true
	logging.enabled = false
	result = _capacity(model, tiles, orders, people)
	_assert(
		result.milestones[3].detail.begins_with("1 enabled"),
		"disabling logging leaves hunting capacity on the shared Forest"
	)
	hunter.haul_role = ContinuumHaulRole.create_hauler()
	result = _capacity(model, tiles, orders, people)
	_assert(
		result.milestones[3].state == "At risk",
		"a logging producer cannot fill the independent hunting order"
	)
	hunter.haul_role = ContinuumHaulRole.create_producer()
	model.reset()
	for seconds in [0, 900, 1800, 2700, 3600]:
		result = _capacity(model, tiles, orders, people, seconds)
	_assert(
		result.milestones[4].state == "Observed recovery",
		"valid hunting capacity can establish bounded recovery"
	)
	hunter.haul_role = ContinuumHaulRole.create_hauler()
	result = _capacity(model, tiles, orders, people, 3606)
	_assert(
		result.milestones[4].state == "At risk" and result.observed_seconds == 0,
		"loss of the last actual producer immediately revokes recovery"
	)


func _capacity(
	model: RefCounted, tiles: Array, orders: Array, people: Array, seconds := 0
) -> Dictionary:
	return model.snapshot(seconds, 1, tiles, orders, people, [], {"food": 100})


func _test_integration() -> void:
	get_tree().root.size = Vector2i(1440, 900)
	var previous := SpacetimeDB.Continuum.db
	var local := preload("res://tools/terrain_fixture.gd").database()
	local._tables["config"][0] = ContinuumConfig.create(
		0, 0, 6, 1, ContinuumHaulPolicy.create(0), ContinuumMealPolicy.create(0)
	)
	var colony := ContinuumColony.new()
	colony.food = 0
	colony.wood = 100
	local._tables["colony"][0] = colony
	local._tables["tile"][3] = ContinuumTile.create(
		3, 1, 1, ContinuumTileKind.create_farm(), true, -8, 1, 1, 6
	)
	local._tables["work_order"][1] = ContinuumWorkOrder.create(
		1, 3, ContinuumWorkType.create_farming(), 1, true
	)
	for row: ContinuumColonist in local._tables["colonist"].values():
		row.hunger = 20
		row.fatigue = 20
		row.recreation = 20
		row.mood = 80
		row.productivity = 80
		row.work = ContinuumWorkType.create_farming()
		row.haul_role = ContinuumHaulRole.create_producer()
	preload("res://tools/terrain_fixture.gd").index_rows(local)
	var main := preload("res://tools/guidance_fixture_main.tscn").instantiate()
	get_tree().root.add_child(main)
	for _frame in 8:
		await get_tree().process_frame
	main._menu.hide()
	main._state_ready = true
	main.map.refresh()
	main._set_permissions("Viewer", false, false)
	main._refresh()
	var panel = main._operations_panel
	_assert(
		panel.model.milestones[3].state == "Present now",
		"actual main snapshot recognizes generated producer roles"
	)
	for row: ContinuumColonist in local._tables["colonist"].values():
		row.haul_role = ContinuumHaulRole.create_hauler()
	main._refresh_guidance()
	_assert(
		panel.model.milestones[3].state == "At risk",
		"actual main panel revokes capacity when generated workers become dedicated haulers"
	)
	for row: ContinuumColonist in local._tables["colonist"].values():
		row.haul_role = ContinuumHaulRole.create_producer()
	main._refresh_guidance()
	_assert(
		panel.get_parent() == main._sections.overview and not panel._body.visible,
		"production Overview integrates a collapsed panel without workspace migration"
	)
	_assert(
		panel.model.ready and panel._summary.text.contains("Food delivered"),
		"actual refresh updates contextual guidance"
	)
	panel._next.pressed.emit()
	_assert(
		main._selected_tile_id == 3 and main.map.selected_rect() == Rect2i(1, 1, 1, 1),
		"viewer next intervention focuses the authoritative farm on map"
	)
	_assert(main.workspace.windows.inspector.visible, "viewer navigation opens existing inspector")
	main._operations_model = preload("res://tools/guidance_operations_fixture.gd")
	main._refresh_guidance()
	_assert(
		panel._rows["operation:0"].label.text.contains("Inspect farm access"),
		"operation snapshot contract supplies reasons and suggested action"
	)
	panel._rows["operation:0"].button.pressed.emit()
	_assert(main._selected_tile_id == 3, "operation focus uses production navigation")
	panel._rows["milestone:Colonist wellbeing"].button.pressed.emit()
	_assert(
		main._selected_colonist >= 0 and main.workspace.windows.people.visible,
		"people milestone uses existing colonist focus and panel"
	)
	main._set_permissions("Operator", true, false)
	main._refresh_guidance()
	panel._rows["milestone:Productive orders"].button.pressed.emit()
	_assert(
		main.workspace.windows.operations.visible,
		"operator intervention routes to existing guarded controls"
	)
	main._set_permissions("Viewer", false, false)
	panel._rows["milestone:Productive orders"].button.pressed.emit()
	_assert(
		not main.workspace.windows.operations.visible and main.workspace.windows.inspector.visible,
		"role loss reroutes an existing intervention button to read-only inspection"
	)
	_assert(
		main._intent_request == null and local._tables["tile"][3].enabled,
		"guidance navigation never bypasses guarded dispatch or changes colony state"
	)
	main._state_ready = false
	main._refresh_guidance()
	var selected: int = main._selected_tile_id
	panel._next.pressed.emit()
	main._navigate_guidance("inspector", 1, -1)
	_assert(
		panel._next.disabled and main._selected_tile_id == selected,
		"warmup fails closed even if signals are emitted programmatically"
	)
	main._state_ready = true
	main._refresh_guidance()
	main._on_disconnected()
	_assert(
		not panel.model.ready and panel._next.disabled,
		"session teardown immediately invalidates navigation and recovery"
	)
	main._state_ready = true
	main._refresh_guidance()
	panel._expand.set_pressed(true)
	for scale in [100, 200]:
		var settings: ClientSettings = main._settings.clone()
		settings.ui_scale_percent = scale
		main.apply_settings(settings, false)
		get_tree().root.size = Vector2i(360, 480)
		for _frame in 8:
			await get_tree().process_frame
		_assert(
			panel._next.size.x > 0 and panel._next.size.x <= main._sections.overview.size.x + 1,
			"narrow scaled panel navigation fits its scrollable workspace content"
		)
	main._state_ready = false
	main.free()
	SpacetimeDB.Continuum.db = previous
	local.free()


func _assert(value: bool, message: String) -> void:
	if not value:
		failed = true
		push_error(message)
