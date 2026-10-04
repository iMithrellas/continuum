## UI composition gate only: captured reducers and fixture acknowledgements are not a live backend gate.
extends Node

var failed := false
var calls: Array = []


func _ready() -> void:
	await get_tree().process_frame
	var previous := SpacetimeDB.Continuum.db
	var local := preload("res://tools/terrain_fixture.gd").database()
	local._tables["config"][0] = ContinuumConfig.create(
		0, 0, 6, 1, ContinuumHaulPolicy.create(0), ContinuumMealPolicy.create(0)
	)
	var colony := ContinuumColony.new()
	colony.food = 10
	colony.wood = 10
	colony.stone = 10
	colony.meat = 10
	local._tables["colony"][0] = colony
	local._tables["item_stack"].clear()
	for kind in 4:
		var stack := ContinuumItemStack.new()
		stack.id = kind
		stack.kind = ContinuumResourceKind.create(kind)
		stack.amount = 20
		stack.z = 15
		local._tables["item_stack"][kind] = stack
	for actor: ContinuumColonist in local._tables["colonist"].values():
		actor.carried_amount = 0
	var carrier: ContinuumColonist = local._tables["colonist"][1]
	carrier.carried_kind = ContinuumResourceKind.create_meat()
	carrier.carried_amount = 5
	preload("res://tools/terrain_fixture.gd").index_rows(local)
	var main := preload("res://tools/production_wiring_fixture_main.tscn").instantiate()
	get_tree().root.add_child(main)
	for _frame in 8:
		await get_tree().process_frame
	main._menu.hide()
	main._session_requested = true
	main._state_ready = true
	main.production_intent_override = _capture
	main._set_permissions("Operator", true, false)
	main._refresh()
	var panel: ContinuumProductionTargets = main._production_targets
	_assert(
		SpacetimeDB.Continuum.db.production_policy is ContinuumProductionPolicyTable,
		"composition reads the generated policy table, not a fixture table override"
	)
	_assert(
		panel.get_parent() == main._operations_panel._body and not panel.get_parent().visible,
		"targets mount within collapsed Overview operations"
	)
	_assert(
		panel._rows.size() == 4 and calls.is_empty(),
		"all resources activated; snapshots do not dispatch"
	)
	for kind in 4:
		var row: Dictionary = panel._rows[kind]
		_assert(
			row.heading.text.contains(str(35 if kind == 3 else 30)),
			"supply includes stores, off-layer ground, and carried items"
		)
		row.input.get_line_edit().text = str(80 + kind)
		row.input.get_line_edit().text_changed.emit(str(80 + kind))
		row.set.pressed.emit()
		_assert(
			calls.size() == kind + 1 and calls[-1].name == "set_production_policy",
			"set control dispatches expected reducer for each scope"
		)
		_assert(
			(
				calls[-1].payload[0] is ContinuumResourceKind
				and calls[-1].payload[0].value == kind
				and calls[-1].payload[1] == 80 + kind
			),
			"payload preserves typed resource and target"
		)
		_assert(row.state.text.contains("unlimited"), "dispatch is not an authoritative update")
		_reply(calls[-1].request, ReducerOutcomeEnum.create_ok_empty())
		_assert(
			row.state.text.contains("unlimited"),
			"acknowledgement alone does not mutate displayed policy"
		)
		local._tables["production_policy"][kind] = ContinuumProductionPolicy.create(
			ContinuumResourceKind.create(kind), float(80 + kind)
		)
		main._on_table_changed("production_policy")
		main._refresh()
		_assert(
			row.state.text.contains(str(80 + kind)) and row.feedback.text.contains("Confirmed"),
			"row refresh normalizes typed enums and confirms observed state"
		)
	var projection := preload("res://tools/production_wiring_operations_fixture.gd")
	main._operations_model = projection
	main._refresh_guidance()
	_assert(
		projection.policies_seen.size() == 4 and projection.policies_seen[0].resource == 0,
		"guidance receives normalized production policy rows"
	)
	_assert(
		(
			projection.context_seen.physical_world
			and (
				projection.context_seen.excavation_designations.size()
				== local._tables["excavation_designation"].size()
			)
		),
		"guidance receives physical geometry and excavation intent context"
	)
	main._operations_model = main.OperationsModel
	var stone_policy: ContinuumProductionPolicy = local._tables["production_policy"][2]
	stone_policy.target = 30
	main._on_table_changed("production_policy")
	main._refresh()
	var mining: Dictionary = _operation(main, "mining")
	_assert(
		(
			mining.state == "target_reached"
			and mining.total_supply == 30
			and mining.active_orders == 0
		),
		"real physical operations projection diagnoses target reached using generated policy and all supply scopes"
	)
	_assert(
		(
			mining.detail.contains("Physical mining extracts finite designated cells")
			and mining.active_designations > 0
		),
		"actual model receives physical context and active excavation rows through main"
	)
	_assert(
		main._operations_panel._rows["operation:1"].label.text.contains("target_reached"),
		"main composes the actual target-reached diagnosis into the visible operations row"
	)
	var designation: ContinuumExcavationDesignation = local._tables["excavation_designation"][1]
	designation.enabled = false
	main._on_table_changed("excavation_designation")
	main._refresh()
	_assert(
		_operation(main, "mining").state == "designations_paused",
		"paused finite intent takes precedence over target suspension in actual guidance"
	)
	designation.enabled = true
	stone_policy.target = 31
	main._refresh_guidance()
	_assert(
		_operation(main, "mining").state != "target_reached",
		"target suspension revokes below the strict authoritative threshold"
	)
	var food: Dictionary = panel._rows[0]
	food.input.get_line_edit().text = "123.4"
	food.input.get_line_edit().text_changed.emit("123.4")
	main._refresh_guidance()
	_assert(
		food.input.get_line_edit().text == "123.4" and calls.size() == 4,
		"draft survives ticks without dispatch"
	)
	food.set.pressed.emit()
	_reply(calls[-1].request, ReducerOutcomeEnum.create_ok_empty())
	local._tables["production_policy"][0].target = PackedFloat32Array([123.40001])[0]
	main._refresh_guidance()
	_assert(
		food.pending != null and not food.feedback.text.contains("Confirmed"),
		"nearby distinct f32 policy does not falsely confirm a decimal draft"
	)
	local._tables["production_policy"][0].target = PackedFloat32Array([123.4])[0]
	main._refresh_guidance()
	_assert(
		food.pending == null and food.feedback.text.contains("Confirmed"),
		"f32 authoritative wire rounding confirms a decimal f64 draft"
	)
	var valid_calls := calls.size()
	for invalid in ["nan", "inf", "oops", "0", "-1", "1000001"]:
		food.input.get_line_edit().text = invalid
		food.set.pressed.emit()
	panel.target_requested.emit(-1, 90)
	panel.target_requested.emit(4, 90)
	panel.target_requested.emit(0, NAN)
	panel.target_removed.emit(-1)
	_assert(
		calls.size() == valid_calls, "invalid raw inputs and direct invalid signals never dispatch"
	)
	food.input.get_line_edit().text = "90"
	food.set.pressed.emit()
	_reply(
		calls[-1].request, ReducerOutcomeEnum.create_err("0000operator required".to_utf8_buffer())
	)
	_assert(
		(
			food.feedback.text.contains("operator required")
			and main._action_error.text.contains("rejected")
		),
		"rejected acknowledgement is visible and clears pending confirmation"
	)
	food.set.pressed.emit()
	_reply(calls[-1].request, ReducerOutcomeEnum.create_internal_error("fixture failure"))
	_assert(
		food.feedback.text.contains("fixture failure"), "internal acknowledgement error is visible"
	)
	main.production_intent_override = func(
		_name: String, _payload: Array
	) -> SpacetimeDBReducerCall:
		return SpacetimeDBReducerCall.fail(ERR_UNAVAILABLE)
	food.set.pressed.emit()
	_assert(food.feedback.text.contains("could not be sent"), "transport rejection is visible")
	main.production_intent_override = _capture
	for kind in 4:
		panel._rows[kind].remove.pressed.emit()
		_assert(
			calls[-1].name == "remove_production_policy" and calls[-1].payload[0].value == kind,
			"unlimited control dispatches removal in each scope"
		)
		_reply(calls[-1].request, ReducerOutcomeEnum.create_ok_empty())
	local._tables["production_policy"].clear()
	main._refresh_guidance()
	_assert(food.state.text.contains("unlimited"), "removal follows authoritative snapshot")
	_test_permission_epochs(main, food)
	food.set.pressed.emit()
	var pending: SpacetimeDBReducerCall = calls[-1].request
	main._set_permissions("Viewer", false, false)
	var before := calls.size()
	food.set.pressed.emit()
	panel.target_requested.emit(0, 90)
	panel.target_removed.emit(0)
	_reply(pending, ReducerOutcomeEnum.create_internal_error("stale error"))
	_assert(
		(
			calls.size() == before
			and food.set.disabled
			and not main._action_error.text.contains("stale error")
		),
		"role downgrade cancels pending acknowledgement and viewer cannot dispatch"
	)
	main._set_permissions("Operator", true, false)
	main._state_ready = false
	main._refresh_guidance()
	panel.target_requested.emit(0, 90)
	_assert(
		calls.size() == before and food.set.disabled, "warming/disconnected operator fails closed"
	)
	main._state_ready = true
	main._refresh_guidance()
	main._operations_panel._expand.set_pressed(true)
	for scale in [100, 150, 200]:
		var settings: ClientSettings = main._settings.clone()
		settings.ui_scale_percent = scale
		main.apply_settings(settings, false)
		get_tree().root.size = Vector2i(360, 480)
		for _frame in 8:
			await get_tree().process_frame
		_assert(
			food.set.size.x > 0 and food.set.size.x <= main._sections.overview.size.x + 1,
			"target controls fit narrow scaled Overview scroll content"
		)
	food.input.get_line_edit().text = "91"
	food.set.pressed.emit()
	var disconnected_request: SpacetimeDBReducerCall = calls[-1].request
	var disconnected_generation: int = main._session_generation
	_assert(
		main._production_requests.get(0) == disconnected_request,
		"disconnect regression begins with an actual pending main request"
	)
	main._on_disconnected()
	_assert(
		food.set.disabled and main._production_requests.is_empty(),
		"disconnect invalidates controls and requests immediately"
	)
	_assert(
		not main._session_requested and main._session_generation > disconnected_generation,
		"manual-session disconnect invalidates the old client epoch"
	)
	main._session_requested = true
	main._state_ready = true
	main._set_permissions("Operator", true, false)
	food.set.pressed.emit()
	var lost_role_request: SpacetimeDBReducerCall = calls[-1].request
	main._set_permissions("Viewer", false, false)
	_assert(
		main._production_requests.is_empty() and food.set.disabled,
		"role loss immediately cancels pending tracking and disables controls"
	)
	main._set_permissions("Operator", true, false)
	food.set.pressed.emit()
	var regained_role_request: SpacetimeDBReducerCall = calls[-1].request
	_reply(lost_role_request, ReducerOutcomeEnum.create_internal_error("lost-role late error"))
	_assert(
		(
			main._production_requests.get(0) == regained_role_request
			and not main._action_error.text.contains("lost-role late error")
		),
		"late acknowledgement after role loss cannot erase a post-regain request"
	)
	_reply(regained_role_request, ReducerOutcomeEnum.create_ok_empty())
	main._refresh_guidance()
	food.set.pressed.emit()
	var reconnected_request: SpacetimeDBReducerCall = calls[-1].request
	_reply(
		disconnected_request, ReducerOutcomeEnum.create_internal_error("disconnected stale error")
	)
	_assert(
		(
			main._production_requests.get(0) == reconnected_request
			and not main._action_error.text.contains("disconnected stale error")
		),
		"late pre-disconnect acknowledgement cannot clear a post-reset request"
	)
	_reply(reconnected_request, ReducerOutcomeEnum.create_ok_empty())
	_assert(
		main._production_requests.is_empty(),
		"post-reset acknowledgement cleans up its matching request"
	)
	main._session_requested = false
	main.free()
	SpacetimeDB.Continuum.db = previous
	local.free()
	print("PRODUCTION_WIRING_TEST: %s" % ("FAIL" if failed else "PASS"))
	get_tree().quit(1 if failed else 0)


func _capture(name: String, payload: Array) -> SpacetimeDBReducerCall:
	var request := SpacetimeDBReducerCall.new()
	calls.append({"name": name, "payload": payload, "request": request})
	return request


## Exercise same-can_operate role epochs against actual main signals and pending calls.
func _test_permission_epochs(main: Control, food: Dictionary) -> void:
	for role in ["Admin", "Operator"]:
		food.input.get_line_edit().text = "94.5"
		food.input.get_line_edit().text_changed.emit("94.5")
		food.set.pressed.emit()
		var cancelled: SpacetimeDBReducerCall = calls[-1].request
		var revision: int = main._permission_revision
		_assert(
			main._production_requests.get(0) == cancelled,
			"role-epoch regression begins with a registered pending request"
		)
		main._set_permissions(role, true, role == "Admin")
		_assert(
			(
				main._permission_revision == revision + 1
				and main._production_requests.is_empty()
				and food.pending == null
			),
			"%s transition cancels old request tracking despite unchanged operator access" % role
		)
		_assert(
			not food.set.disabled and food.input.get_line_edit().text == "94.5",
			"authorized role change preserves enabled controls and draft"
		)
		var before := calls.size()
		food.set.pressed.emit()
		var current: SpacetimeDBReducerCall = calls[-1].request
		_assert(
			calls.size() == before + 1 and main._production_requests.get(0) == current,
			"authorized role change permits a superseding request without waiting for old acknowledgement"
		)
		main._set_permissions(role, true, role == "Admin")
		_assert(
			(
				main._permission_revision == revision + 1
				and main._production_requests.get(0) == current
			),
			"duplicate same-role snapshot does not advance the epoch or cancel current request"
		)
		_reply(cancelled, ReducerOutcomeEnum.create_internal_error("stale role-epoch error"))
		_assert(
			(
				main._production_requests.get(0) == current
				and food.pending == 94.5
				and not main._action_error.text.contains("stale role-epoch error")
			),
			"late old-role acknowledgement cannot erase or alter a newer request"
		)
		_reply(current, ReducerOutcomeEnum.create_ok_empty())
		_assert(
			main._production_requests.is_empty(),
			"matching current-role acknowledgement releases request tracking"
		)
		food.set.pressed.emit()
		var still_authorized: SpacetimeDBReducerCall = calls[-1].request
		main._set_permissions("Operator" if role == "Admin" else "Admin", true, role != "Admin")
		_reply(still_authorized, ReducerOutcomeEnum.create_ok_empty())
		_assert(
			main._production_requests.is_empty(),
			"acknowledgement after still-authorized role change cannot strand request tracking"
		)
		main._set_permissions(role, true, role == "Admin")
	main._set_permissions("Operator", true, false)


func _operation(main: Control, work: String) -> Dictionary:
	for item: Dictionary in main._operations_panel.model.operations:
		if item.work_key == work:
			return item
	return {}


func _reply(request: SpacetimeDBReducerCall, outcome: ReducerOutcomeEnum) -> void:
	var response := ReducerResultMessage.new()
	response.reducer_result = outcome
	request.on_response(response)


func _assert(value: bool, message: String) -> void:
	if not value:
		failed = true
		push_error(message)
