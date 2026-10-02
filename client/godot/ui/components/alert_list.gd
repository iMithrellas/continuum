class_name AlertList
extends VBoxContainer

signal acknowledge_requested(id: Variant)
signal goto_requested(id: Variant)
const Models = preload("models.gd")
const UI = preload("presentation.gd")
const Row = preload("alert_row.gd")
var reduced_motion: bool = false
var _ack_states: Dictionary = {}
var model: Dictionary = {}

## null/missing means unavailable. coverage.status optionally marks partial or
## unavailable query coverage; it can never upgrade rejected input to complete.
func set_model(rows: Variant = null, coverage: Dictionary = {}) -> void:
	var next := Models.alert_collection(rows, coverage)
	if next == model:
		return
	var retained: Dictionary = {}
	for child in get_children():
		if child is AlertRow and Models.valid_identifier(child.model.get("id")):
			retained[child.model.id] = child
		else:
			remove_child(child)
			child.queue_free()
	add_theme_constant_override("separation", 0)
	model = next
	var ordered: Array = model.rows
	if model.status != "complete":
		add_child(UI.coverage_notice("Alerts", model))
	elif ordered.is_empty():
		var nominal = UI.row()
		nominal.add_child(UI.glyph("notice"))
		nominal.add_child(UI.label("Nominal · no active alerts"))
		add_child(nominal)
	for model in ordered:
		var row = retained[model.id] if retained.has(model.get("id")) else Row.new()
		retained.erase(model.get("id"))
		row.set_reduced_motion(reduced_motion)
		row.set_model(model)
		var row_id: Variant = model.get("id")
		if Models.valid_identifier(row_id):
			if _ack_states.has(row_id) and model.acknowledged != true:
				var state: Dictionary = _ack_states[row_id]
				row.set_acknowledgement_state(state.pending, state.error)
			elif model.acknowledged == true:
				_ack_states.erase(row_id)
		if not row.has_meta("list_connected"):
			row.acknowledge_requested.connect(func(id): acknowledge_requested.emit(id))
			row.goto_requested.connect(func(id): goto_requested.emit(id))
			row.set_meta("list_connected", true)
		if row.get_parent() == null:
			add_child(row)
		move_child(row, -1)
	for row in retained.values():
		remove_child(row)
		row.queue_free()

func set_reduced_motion(enabled: bool) -> void:
	reduced_motion = enabled
	for child in get_children():
		if child.has_method("set_reduced_motion"):
			child.set_reduced_motion(enabled)

func set_acknowledgement_state(id: Variant, pending: bool, error: String = "") -> void:
	if not Models.valid_identifier(id):
		return
	_ack_states[id] = {"pending": pending, "error": error}
	for child in get_children():
		if child is AlertRow and Models.same_identifier(child.model.get("id"), id):
			child.set_acknowledgement_state(pending, error)
