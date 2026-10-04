## Real Main handlers + map release routing, with dispatch-only backend seams.
## Tests permission epochs, independent room/usage deletion, and legacy layouts.
extends "res://tools/ui_composition_fixture.gd"

var requests: Array = []
var buildings: Array = []
var thermal: Array = []
var assertions := 0


## Transport-only recorder: Main uses the genuine generated reducer methods and
## SDK argument serializer. No UI dispatch override or fake enum encoding here.
class WireClient:
	extends SpacetimeDBClient
	var calls: Array = []
	var wire_serializer: BSATNSerializer

	func call_reducer(
		reducer: String, args: Array = [], types: Array = []
	) -> SpacetimeDBReducerCall:
		var bytes := wire_serializer._serialize_arguments(args, types)
		var request := SpacetimeDBReducerCall.new()
		calls.append(
			{
				"name": reducer,
				"args": args,
				"types": types,
				"bytes": bytes,
				"error": wire_serializer.get_last_error(),
				"request": request
			}
		)
		return request


func check(value: bool, message: String) -> void:
	assertions += 1
	if not value:
		failures.append(message)
		push_error(message)


func _ready() -> void:
	call_deferred("run")


func run() -> void:
	get_window().size = Vector2i(1280, 720)
	_previous_db = SpacetimeDB.Continuum.db
	for path in ["res://tools/map_ui_test.gd", "res://tools/sidebar_access_e2e.gd"]:
		check(
			load(path).can_instantiate(),
			"connected UI fixture compiles with actual autoload context: " + path
		)
	_seed_database()
	main = MainScene.instantiate()
	add_child(main)
	main._menu.hide()
	main._server_management.hide()
	main._session_requested = true
	main._state_ready = true
	main.map.refresh()
	main._set_permissions("Operator", true, false)
	main.map_intent_override = func(reducer: String, payload: Array) -> void:
		requests.append([reducer, payload])
	for frame in 8:
		await get_tree().process_frame
	var area := Rect2i(8, 5, 3, 2)
	check(
		main.workspace.windows.has("construction") and main.workspace.windows.has("operations"),
		"two independent registered panels"
	)
	main.workspace.switch_workspace("build")
	check(
		main.workspace.state("construction").open and main.workspace.state("operations").open,
		"new planning preset opens both panels"
	)
	main._construction_panel.activate.pressed.emit()
	check(
		main._planning_system == &"construction" and main.map.interaction_mode == &"build",
		"Construction button owns generic rectangle tool"
	)
	main._on_build_rectangle_requested(area)
	check(
		requests.size() == 1 and requests.back() == ["construct_room", [8, 5, 10, 6, 0, 4]],
		"room handler dispatches inclusive xyz bounds, four clearance, new API"
	)
	check(
		"30 wood" in main._planning_preview(area) and not "20 wood" in main._planning_preview(area),
		"room preview reports exact five-wood cost"
	)
	var storage := ContinuumTile.create(
		900001, 8, 5, ContinuumTileKind.create_storage(), true, 0, 1, 1, 4
	)
	local._tables.tile[storage.id] = storage
	TerrainFixture.index_rows(local)
	main.map.refresh({"tile": true})
	main._on_build_rectangle_requested(area)
	check(
		requests.size() == 2 and requests.back()[0] == "construct_room",
		"constructing a room over existing usage is allowed locally"
	)
	buildings = [
		ContinuumBuilding.create(
			71, ContinuumBuildingKind.create_insulated_room(), 8, 5, 0, 3, 2, 4, 30.0
		)
	]
	thermal = [ContinuumBuildingThermalProperty.create(71, 2.0)]
	local._tables.building[71] = buildings[0]
	local._tables.building_thermal_property[71] = thermal[0]
	TerrainFixture.index_rows(local)
	main._zones_panel.activate.pressed.emit()
	check(
		main._planning_system == &"zones" and not main._construction_panel.activate.button_pressed,
		"Zones activation disarms Construction while both remain open"
	)
	main._on_build_rectangle_requested(area)
	check(
		(
			requests.size() == 3
			and requests.back()[0] == "designate_zone_at"
			and requests.back()[1].slice(0, 5) == [8, 5, 10, 6, 0]
		),
		"zone rectangle over room uses free designation API"
	)
	check(
		(
			requests.back()[1][5].value == ContinuumTileKind.Options.storage
			and "Free" in main._planning_preview(area)
		),
		"zone payload kind and free preview agree"
	)
	main._zones_panel.choices[ContinuumTileKind.Options.farm].pressed.emit()
	check(
		(
			"farm" in main._intent_feedback.text
			and main.map.build_kind == ContinuumTileKind.Options.farm
		),
		"changing active zone kind updates global mode and map preview together"
	)
	main._on_build_rectangle_requested(area)
	check(
		requests.size() == 3 and "Clear it" in main._zones_panel.feedback.text,
		"conflicting usage requires explicit clear first"
	)
	main._zones_panel.choices[ContinuumTileKind.Options.storage].pressed.emit()
	local._tables.colony[0].wood = 0
	main._on_build_rectangle_requested(area)
	check(requests.size() == 4, "free zone designation does not require wood")
	main._construction_panel.activate.pressed.emit()
	main._on_build_rectangle_requested(area)
	check(
		requests.size() == 4 and "Needs 30 wood" in main._construction_panel.feedback.text,
		"room cost shortage is actionable visible feedback"
	)
	local._tables.colony[0].wood = 100000
	main._on_rectangle_selected(Rect2i(8, 5, 1, 1))
	check(
		(
			not main.planning_rows_override.is_valid()
			and main._planning_rows("building")[0] is ContinuumBuilding
			and (
				main._planning_rows("building_thermal_property")[0]
				is ContinuumBuildingThermalProperty
			)
		),
		"inspection reads actual generated building tables, not dictionary row overrides"
	)
	check(
		"Insulation R 2.0" in main._room_selection.text and "Storage" in main._room_selection.text,
		"selection shows independent insulation and storage usage"
	)
	check(
		(
			(
				SpacetimeDB
				. Continuum
				. db
				. building_thermal_property
				. building_id
				. find(71)
				. thermal_resistance_m_2_k_per_w
			)
			== 2.0
		),
		"R 2.0 display follows the canonical generated thermal_resistance_m_2_k_per_w field"
	)
	check(
		"no spoilage simulation" in main._room_selection.text,
		"storage overlap does not promise simulated preservation"
	)
	main._construction_panel.remove.pressed.emit()
	check(
		requests.back() == ["demolish_building", [71]],
		"demolition addresses building identity only"
	)
	main._zones_panel.remove.pressed.emit()
	check(requests.back() == ["clear_zone", [900001]], "usage clear addresses tile identity only")
	check(
		buildings.size() == 1 and local._tables.tile.has(900001),
		"UI never optimistically removes authoritative rows"
	)
	main.workspace.toggle_map_only()
	main._zones_panel.activate.pressed.emit()
	for frame in 8:
		await get_tree().process_frame
	var first: Vector2 = main.map.world_to_screen(Vector2(12.5, 7.5))
	var last: Vector2 = main.map.world_to_screen(Vector2(11.5, 6.5))
	var before := requests.size()
	main.map._gui_input(mouse(true, first))
	main.map._input(mouse(false, main.map.get_global_transform() * last))
	check(
		requests.size() == before + 1 and requests.back()[1].slice(0, 5) == [11, 6, 12, 7, 0],
		"real release signal routes reversed drag through active Zones system"
	)
	var escape := InputEventKey.new()
	escape.keycode = KEY_ESCAPE
	escape.pressed = true
	main.map._input(escape)
	check(
		main._planning_system == &"" and main.map.interaction_mode == &"select",
		"Escape cancels tool and synchronized panel state"
	)
	main._activate_planning(&"construction")
	main._construction_panel.activate.grab_focus()
	main._input(escape)
	check(
		main._planning_system == &"", "Escape also cancels when a panel action owns keyboard focus"
	)
	main._activate_planning(&"construction")
	var pending := SpacetimeDBReducerCall.new()
	main._track_intent(pending, "Construct insulated room")
	check(
		(
			main._construction_panel.activate.disabled
			and main._zones_panel.activate.disabled
			and "pending" in main._planning_preview(area)
		),
		"pending request blocks both tools and describes busy hover"
	)
	before = requests.size()
	main._on_build_rectangle_requested(area)
	main._remove_planning_selection(&"construction")
	check(requests.size() == before, "real handlers cannot duplicate pending requests")
	var failure := ReducerResultMessage.new()
	failure.reducer_result = ReducerOutcomeEnum.create_internal_error("fixture server failure")
	pending.response.emit(failure)
	check(
		(
			main._intent_request == null
			and "fixture server failure" in main._construction_panel.feedback.text
		),
		"server failure is visible in planning panel and releases busy state"
	)
	pending = SpacetimeDBReducerCall.new()
	main._track_intent(pending, "Construct insulated room")
	main._process(11.0)
	check(
		main._intent_request == null and "Outcome unknown" in main._zones_panel.feedback.text,
		"timeout never claims success and explains unknown outcome"
	)
	pending = SpacetimeDBReducerCall.new()
	main._track_intent(pending, "Construct insulated room")
	main._set_permissions("Viewer", false, false)
	var response := ReducerResultMessage.new()
	response.reducer_result = ReducerOutcomeEnum.create_err("stale rejection".to_utf8_buffer())
	pending.response.emit(response)
	check(
		(
			main._intent_request == null
			and main.map.interaction_mode == &"select"
			and not "stale rejection" in main._intent_feedback.tooltip_text
		),
		"revocation cancels active tool and fences late pending response"
	)
	for role: String in ["Viewer", "Unknown"]:
		main._set_permissions(role, false, false)
		main._activate_planning(&"construction")
		main._on_build_rectangle_requested(area)
		main._remove_planning_selection(&"construction")
		main._remove_planning_selection(&"zones")
		check(requests.size() == before, role + " cannot dispatch any planning mutation")
	main._set_permissions("Operator", true, false)
	main._activate_planning(&"construction")
	var live := SpacetimeDB.Continuum.db
	SpacetimeDB.Continuum.db = null
	main._on_build_rectangle_requested(area)
	main._remove_planning_selection(&"zones")
	main._refresh_controls()
	check(
		requests.size() == before and main._construction_panel.activate.disabled,
		"detached provider denies Operator and disables panels"
	)
	check(
		main._mode_buttons[&"excavate"].disabled,
		"detachment disables Construction terrain work too"
	)
	for role: String in ["Viewer", "Unknown"]:
		main._set_permissions(role, false, false)
		main._activate_planning(&"zones")
		main._on_build_rectangle_requested(area)
		main._remove_planning_selection(&"construction")
		main._remove_planning_selection(&"zones")
		check(requests.size() == before, "detached " + role + " cannot dispatch")
	SpacetimeDB.Continuum.db = live
	main.map.refresh()
	main._state_ready = true
	main._set_permissions("Operator", true, false)
	main._activate_planning(&"construction")
	main._on_build_rectangle_requested(Rect2i(0, 0, 65, 65))
	check(requests.size() == before, "out-of-bounds and oversized rectangle never dispatches")
	check(
		not PlanningModel.rectangle_error(Rect2i(0, 0, 65, 65), Rect2i(0, 0, 256, 256)).is_empty(),
		"4096-cell limit holds in the new 256 world"
	)
	check(
		PlanningModel.rectangle_error(Rect2i(0, 0, 64, 64), Rect2i(0, 0, 256, 256)).is_empty(),
		"exact 4096-cell bound is accepted"
	)
	test_generated_dispatch()
	test_layout_migration()
	remove_child(main)
	main._dispatch_vertical("construct_room", [8, 5, 10, 6, 0, 4], "Detached scene")
	check(
		requests.size() == before,
		"detached Main scene cannot dispatch despite cached Operator state"
	)
	main._state_ready = false
	main._return_key = ""
	main.free()
	SpacetimeDB.Continuum.db = _previous_db
	local.free()
	print("PLANNING_TEST ", assertions, " assertions, ", failures.size(), " failures")
	get_tree().quit(0 if failures.is_empty() else 1)


func mouse(pressed: bool, point: Vector2) -> InputEventMouseButton:
	var event := InputEventMouseButton.new()
	event.pressed = pressed
	event.button_index = MOUSE_BUTTON_LEFT
	event.position = point
	return event


func reply(call: SpacetimeDBReducerCall) -> void:
	var response := ReducerResultMessage.new()
	response.reducer_result = ReducerOutcomeEnum.create_ok_empty()
	call.response.emit(response)


## Verify exact signed coordinates, clearance width, enum tag, and ID widths at
## Main -> generated reducer -> SDK BSATN boundary, including denied roles.
func test_generated_dispatch() -> void:
	var client := WireClient.new()
	client.wire_serializer = BSATNSerializer.new(
		SpacetimeDBSchema.new("Continuum", "res://spacetime_bindings/schema", false)
	)
	var original_reducers := SpacetimeDB.Continuum.reducers
	var original_override: Callable = main.map_intent_override
	main.map_intent_override = Callable()
	SpacetimeDB.Continuum.reducers = ContinuumModuleReducers.new(client)
	var area := Rect2i(16, 15, 2, 3)
	main._activate_planning(&"construction")
	main.map.build_rectangle_requested.emit(area)
	check(
		client.calls.size() == 1,
		"room signal reaches real generated reducer with UI override disabled"
	)
	if client.calls.size() != 1:
		SpacetimeDB.Continuum.reducers = original_reducers
		main.map_intent_override = original_override
		client.free()
		return
	var room: Dictionary = client.calls.back()
	check(
		(
			room.name == "construct_room"
			and room.args == [16, 15, 17, 17, -8, 4]
			and room.types == [&"I32", &"I32", &"I32", &"I32", &"I32", &"U16"]
		),
		"generated room call carries exact reducer, inclusive bounds and field types"
	)
	var expected := StreamPeerBuffer.new()
	expected.big_endian = false
	for coordinate in [16, 15, 17, 17, -8]:
		expected.put_32(coordinate)
	expected.put_u16(4)
	check(
		room.error.is_empty() and room.bytes == expected.data_array and room.bytes.size() == 22,
		"room SDK bytes encode five signed i32 values then u16 clearance exactly"
	)
	check(
		main._intent_request == room.request and main._construction_panel.activate.disabled,
		"real generated dispatch enters pending state"
	)
	main.map.build_rectangle_requested.emit(area)
	check(client.calls.size() == 1, "pending guard prevents a second generated reducer invocation")
	reply(room.request)
	main._activate_planning(&"zones")
	main._choose_zone(ContinuumTileKind.Options.storage)
	main.map.build_rectangle_requested.emit(area)
	var zone: Dictionary = client.calls.back()
	check(
		(
			client.calls.size() == 2
			and zone.name == "designate_zone_at"
			and zone.args.slice(0, 5) == [16, 15, 17, 17, -8]
			and zone.args[5] is ContinuumTileKind
			and zone.args[5].value == ContinuumTileKind.Options.storage
		),
		"actual Zones handler reaches generated designation with the typed Storage enum"
	)
	check(
		zone.types == [&"I32", &"I32", &"I32", &"I32", &"I32", &"ContinuumTileKind"],
		"generated designation preserves enum and signed coordinate types"
	)
	expected.resize(20)
	expected.seek(20)
	expected.put_u8(3)  # Stable backend TileKind::Storage ordinal, not an inferred field.
	check(
		zone.error.is_empty() and zone.bytes == expected.data_array and zone.bytes.size() == 21,
		"designation SDK bytes encode the stable Storage tag after exact signed bounds"
	)
	reply(zone.request)
	var building_id := 4294967367
	local._tables.building[building_id] = ContinuumBuilding.create(
		building_id, ContinuumBuildingKind.create_insulated_room(), 16, 15, -8, 2, 3, 4, 30.0
	)
	local._tables.building_thermal_property[building_id] = ContinuumBuildingThermalProperty.create(
		building_id, 2.0
	)
	local._tables.tile[900002] = ContinuumTile.create(
		900002, 16, 15, ContinuumTileKind.create_storage(), true, -8, 1, 1, 4
	)
	TerrainFixture.index_rows(local)
	main.map.refresh({"tile": true, "building": true, "building_thermal_property": true})
	main._on_rectangle_selected(Rect2i(16, 15, 1, 1))
	main._construction_panel.remove.pressed.emit()
	var demolition: Dictionary = client.calls.back()
	expected.resize(0)
	expected.seek(0)
	expected.put_u64(building_id)
	check(
		(
			client.calls.size() == 3
			and demolition.name == "demolish_building"
			and demolition.args == [building_id]
			and demolition.types == [&"U64"]
			and demolition.bytes == expected.data_array
			and demolition.error.is_empty()
		),
		"selected-room demolition retains full u64 identity through SDK serialization"
	)
	reply(demolition.request)
	main._zones_panel.remove.pressed.emit()
	var clear: Dictionary = client.calls.back()
	expected.resize(0)
	expected.seek(0)
	expected.put_u32(900002)
	check(
		(
			client.calls.size() == 4
			and clear.name == "clear_zone"
			and clear.args == [900002]
			and clear.types == [&"U32"]
			and clear.bytes == expected.data_array
			and clear.error.is_empty()
		),
		"selected usage clear serializes only its durable u32 Tile identity"
	)
	reply(clear.request)
	for role: String in ["Viewer", "Unknown"]:
		main._set_permissions(role, false, false)
		main._construction_panel.activate.pressed.emit()
		main._zones_panel.activate.pressed.emit()
		main.map.build_rectangle_requested.emit(area)
		main._construction_panel.remove.pressed.emit()
		main._zones_panel.remove.pressed.emit()
		main._dispatch_vertical("construct_room", [16, 15, 17, 17, -8, 4], "Denied direct dispatch")
		check(
			client.calls.size() == 4,
			role + " cannot reach any generated mutation, including direct dispatch"
		)
	main._set_permissions("Operator", true, false)
	var db := SpacetimeDB.Continuum.db
	SpacetimeDB.Continuum.db = null
	main._construction_panel.activate.pressed.emit()
	main._construction_panel.remove.pressed.emit()
	main._zones_panel.remove.pressed.emit()
	main._dispatch_vertical(
		"designate_zone_at",
		[16, 15, 17, 17, -8, ContinuumTileKind.create_storage()],
		"Detached dispatch"
	)
	check(
		client.calls.size() == 4,
		"detached Operator cannot reach generated reducers or serialization"
	)
	SpacetimeDB.Continuum.db = db
	main.map.refresh()
	main._state_ready = true
	main._set_mode(&"select")
	SpacetimeDB.Continuum.reducers = original_reducers
	main.map_intent_override = original_override
	client.free()


func test_layout_migration() -> void:
	var model := WorkspaceLayout.new()
	var saved := model.workspaces.duplicate(true)
	for id in saved:
		saved[id].panels.erase("construction")
	saved.build.panels.operations = {
		"rect": [0.12, 0.2, 0.3, 0.6], "open": true, "minimized": true, "pinned": true, "z": 15
	}
	var path := "user://planning_migration_test.json"
	var file := FileAccess.open(path, FileAccess.WRITE)
	file.store_string(
		JSON.stringify(
			{"version": 3, "active": "build", "workspaces": saved, "show_panel_headers": false}
		)
	)
	file.close()
	check(model.load_from(path), "legacy workspace loads")
	check(
		(
			model.workspaces.build.panels.operations == saved.build.panels.operations
			and not model.show_panel_headers
		),
		"Zones preserves old Build & work orders geometry flags z and headers"
	)
	check(
		not model.workspaces.build.panels.construction.open,
		"new Construction panel does not cover a migrated arrangement"
	)
	for id in saved:
		for panel in saved[id].panels:
			check(
				model.workspaces[id].panels[panel] == saved[id].panels[panel],
				"all other saved panel state survives: " + id + "/" + panel
			)
	DirAccess.remove_absolute(path)
