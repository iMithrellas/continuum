## Reducer-free stock-target editor. Supply is stored + ground + carried, not storage alone.
## Integrators must configure supported resources, then pass authoritative dictionary rows
## with `resource` (or `kind`) and `target`. No generated bindings are required here.
## Place inside a vertically scrolling panel with horizontal scrolling disabled and
## horizontal expand/fill enabled. Stacked controls fit a 320px panel at 150% scale.
## Connect requests to your permission-guarded reducer adapter; never treat a signal
## as success. "Confirmed" means the requested state was observed in a ready snapshot.
class_name ContinuumProductionTargets
extends VBoxContainer

signal target_requested(resource: int, target: float)
signal target_removed(resource: int)

const RESOURCE_NAMES := ["Food", "Wood", "Stone", "Meat"]
const MIN_TARGET := 0.1
const MAX_TARGET := 1000000.0

var _supported: Array[int] = []
var _rows: Dictionary = {}
var _policies: Dictionary = {}
var _supply: Dictionary = {}
var _can_manage := false
var _snapshot_ready := false
var _built := false
var _access: Label


func _ready() -> void:
	_build()


## Explicit opt-in: empty by default until the backend's supported work types are known.
## Ordinals: Food=0, Wood=1, Stone=2, Meat=3. Reconfiguration discards drafts.
func set_supported_resources(resources: Array) -> void:
	var normalized: Array[int] = []
	for value: Variant in resources:
		var resource := _resource(value)
		if resource >= 0 and not normalized.has(resource):
			normalized.append(resource)
	if normalized == _supported:
		return
	_supported = normalized
	if _built:
		_build()


## A snapshot never dispatches requests. Missing supply is unknown; missing policy is unlimited.
## Invalid/duplicate policy rows with a recognized resource display unknown, not unlimited.
## Drafts survive ticks and permission loss. Disconnect revokes all mutation immediately.
func set_snapshot(policies: Array, supply: Dictionary, can_manage: bool, ready: bool) -> void:
	_policies.clear()
	for policy: Variant in policies:
		if not policy is Dictionary:
			continue
		var resource := _resource(policy.get("resource", policy.get("kind", null)))
		if resource < 0:
			continue
		var target := _number(policy.get("target", null))
		if _policies.has(resource) or not is_finite(target) or target <= 0.0:
			_policies[resource] = NAN
		else:
			_policies[resource] = target
	_supply.clear()
	for key: Variant in supply:
		var resource := _resource(key)
		if resource >= 0:
			_supply[resource] = _number(supply[key])
	_can_manage = can_manage
	_snapshot_ready = ready
	if _built:
		_refresh()


func _build() -> void:
	for child in get_children():
		remove_child(child)
		child.queue_free()
	_rows.clear()
	_built = true
	add_theme_constant_override("separation", 8)
	_label("Production targets")
	_label(
		"Produce until total supply reaches the target. Suspended work still permits hauling. Consumption resumes production. Manually paused orders remain paused."
	)
	_access = _label("")
	if _supported.is_empty():
		_label("No supported production resources configured.")
	for resource: int in _supported:
		var box := VBoxContainer.new()
		box.name = RESOURCE_NAMES[resource]
		box.add_theme_constant_override("separation", 4)
		add_child(box)
		var heading := _label(RESOURCE_NAMES[resource], box)
		var state := _label("", box)
		var input := SpinBox.new()
		input.name = "TargetInput"
		input.min_value = MIN_TARGET
		input.max_value = MAX_TARGET
		input.step = 0.1
		input.value = 100.0
		input.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		input.tooltip_text = (
			"%s target: %.1f to %.0f total supply"
			% [RESOURCE_NAMES[resource], MIN_TARGET, MAX_TARGET]
		)
		box.add_child(input)
		var set_button := Button.new()
		set_button.name = "SetTarget"
		set_button.text = "Set target"
		set_button.tooltip_text = "Request a %s production target" % RESOURCE_NAMES[resource]
		box.add_child(set_button)
		var remove_button := Button.new()
		remove_button.name = "Unlimited"
		remove_button.text = "Unlimited"
		remove_button.tooltip_text = (
			"Remove the %s target; manual pauses are unchanged" % RESOURCE_NAMES[resource]
		)
		box.add_child(remove_button)
		var feedback := _label("", box)
		_rows[resource] = {
			"heading": heading,
			"state": state,
			"input": input,
			"set": set_button,
			"remove": remove_button,
			"feedback": feedback,
			"dirty": false,
			"pending": null
		}
		input.value_changed.connect(func(_value: float) -> void: _draft_changed(resource))
		input.get_line_edit().text_changed.connect(
			func(_text: String) -> void: _draft_changed(resource)
		)
		set_button.pressed.connect(_request_target.bind(resource))
		remove_button.pressed.connect(_request_removal.bind(resource))
	_refresh()


func _label(text: String, parent: Node = self) -> Label:
	var label := Label.new()
	label.text = text
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	parent.add_child(label)
	return label


func _draft_changed(resource: int) -> void:
	_rows[resource]["dirty"] = true


## A failed acknowledgement must not later appear confirmed by an unrelated tick.
func request_failed(resource: int, message: String) -> void:
	if not _rows.has(resource):
		return
	_rows[resource].pending = null
	_rows[resource].feedback.text = message


## Role/session changes cancel requests without discarding the user's draft.
func cancel_pending() -> void:
	for row: Dictionary in _rows.values():
		if row.pending != null:
			row.pending = null
			row.feedback.text = "Request tracking cancelled; inspect server state before retrying."


func _refresh() -> void:
	_access.text = (
		"Disconnected — controls disabled."
		if not _snapshot_ready
		else ("" if _can_manage else "Read-only — operator access required.")
	)
	for resource: int in _rows:
		var row: Dictionary = _rows[resource]
		var total: float = _supply.get(resource, NAN)
		row.heading.text = (
			"%s · total supply: %s"
			% [
				RESOURCE_NAMES[resource],
				("%.1f" % total) if is_finite(total) and total >= 0.0 else "unknown"
			]
		)
		row.heading.tooltip_text = (
			"Stored + ground + carried: %s" % _format(total)
			if is_finite(total) and total >= 0.0
			else "Total supply unavailable"
		)
		var target: float = _policies.get(resource, NAN)
		var has_policy := _policies.has(resource)
		row.state.text = (
			"Target: %s" % _format(target)
			if is_finite(target)
			else ("Target: unknown (invalid policy)" if has_policy else "Target: unlimited")
		)
		if not _snapshot_ready:
			row.state.text += " (last snapshot)"
		var pending: Variant = row.pending
		if (
			_snapshot_ready
			and pending != null
			and (
				(pending == -1.0 and not has_policy)
				or (is_finite(target) and _same_target(target, pending))
			)
		):
			if pending != -1.0 and _number(row.input.get_line_edit().text) == pending:
				row.dirty = false
			row.pending = null
			row.feedback.text = "Confirmed by server snapshot."
		if (
			not row.dirty
			and not row.input.get_line_edit().has_focus()
			and is_finite(target)
			and target >= MIN_TARGET
			and target <= MAX_TARGET
		):
			row.input.set_value_no_signal(target)
		var enabled := _snapshot_ready and _can_manage
		row.input.editable = enabled
		row.input.get_line_edit().editable = enabled
		row.set.disabled = not enabled
		row.remove.disabled = not enabled or not has_policy


func _request_target(resource: int) -> void:
	if not _snapshot_ready or not _can_manage or not _rows.has(resource):
		return
	var row: Dictionary = _rows[resource]
	# SpinBox clamps values; validate the user's raw text before that can hide invalid input.
	var target := _number(row.input.get_line_edit().text)
	if not is_finite(target) or target < MIN_TARGET or target > MAX_TARGET:
		row.feedback.text = "Enter a target from %.1f to %.0f." % [MIN_TARGET, MAX_TARGET]
		return
	row.dirty = true
	row.pending = target
	row.feedback.text = "Request sent; awaiting server snapshot."
	target_requested.emit(resource, target)


func _request_removal(resource: int) -> void:
	if (
		not _snapshot_ready
		or not _can_manage
		or not _rows.has(resource)
		or not _policies.has(resource)
	):
		return
	_rows[resource].pending = -1.0
	_rows[resource].feedback.text = "Removal requested; awaiting server snapshot."
	target_removed.emit(resource)


func _format(value: float) -> String:
	return str(value)


## Backend targets are f32; decimal drafts are Godot f64. Match exact wire rounding,
## not a broad tolerance that could confirm a different operator's nearby target.
func _same_target(observed: float, requested: float) -> bool:
	return observed == requested or observed == PackedFloat32Array([requested])[0]


func _number(value: Variant) -> float:
	if value is int or value is float:
		return float(value)
	if value is String and value.strip_edges().is_valid_float():
		return value.strip_edges().to_float()
	return NAN


func _resource(value: Variant) -> int:
	if value is String:
		for index in RESOURCE_NAMES.size():
			if value.to_lower() == RESOURCE_NAMES[index].to_lower():
				return index
	var number := _number(value)
	if (
		is_finite(number)
		and number >= 0
		and number < RESOURCE_NAMES.size()
		and number == floor(number)
	):
		return int(number)
	return -1
