## Compact, opt-in Overview guidance. Navigation is read-only; existing guarded
## map/work/policy controls own every mutation. No speculative policy bindings.
extends VBoxContainer

signal navigation_requested(panel: String, tile_id: int, colonist_id: int)

var model: Dictionary = {}
var _expand: Button
var _summary: Label
var _next: Button
var _body: VBoxContainer
var _access: Label
var _rows: Dictionary = {}
var _ready_state := false
var _can_operate := false


func _init() -> void:
	_expand = Button.new()
	_expand.text = "Stabilization & operations"
	_expand.toggle_mode = true
	_expand.clip_text = true
	_expand.tooltip_text = "Expand reversible stabilization milestones and operation reasons"
	_expand.alignment = HORIZONTAL_ALIGNMENT_LEFT
	_expand.toggled.connect(func(open: bool) -> void: _body.visible = open)
	add_child(_expand)
	_summary = _label()
	add_child(_summary)
	_next = Button.new()
	_next.text = "Waiting for colony"
	_next.clip_text = true
	_next.disabled = true
	_next.pressed.connect(func() -> void: _navigate(model.get("next", {})))
	add_child(_next)
	_body = VBoxContainer.new()
	_body.visible = false
	add_child(_body)
	_access = _label()
	_body.add_child(_access)
	set_model({}, false)


func set_model(value: Dictionary, can_operate: bool) -> void:
	model = value.duplicate(true)
	_ready_state = value.get("ready", false)
	_can_operate = can_operate
	_expand.text = "Stabilization · %s" % value.get("phase", "Observe")
	_summary.text = value.get("summary", "Waiting for a live colony snapshot.")
	_next.text = value.get("next", {}).get("action", "Waiting for colony")
	_next.tooltip_text = value.get("next", {}).get("detail", "Waiting for a live colony snapshot")
	_next.disabled = not _ready_state
	_access.text = (
		"Intervene through existing Operations controls; then observe recovery."
		if can_operate
		else "Read-only: inspect causes and map targets. An operator must change orders or policies."
	)
	var visible_keys := {}
	for item: Dictionary in value.get("milestones", []):
		var key: String = "milestone:" + item.name
		visible_keys[key] = true
		_update_row(key, item, "%s · %s\n%s" % [item.name, item.state, item.detail], item.action)
	for index in value.get("operations", []).size():
		var item: Dictionary = value.operations[index]
		var key := "operation:%s" % item.get("work", index)
		visible_keys[key] = true
		var target := {
			"panel": "inspector", "focus_tile_id": item.get("focus_tile_id", -1), "colonist_id": -1
		}
		_update_row(
			key,
			target,
			(
				"%s · %s\n%s\n%s\nNext intervention: %s"
				% [
					item.get("name", "Work"),
					item.get("state", "Unknown"),
					item.get("summary", ""),
					item.get("detail", ""),
					item.get("suggested_action", "Inspect causes before changing work")
				]
			),
			"Focus work" if int(item.get("focus_tile_id", -1)) >= 0 else "Inspect work"
		)
	for key: String in _rows:
		_rows[key].box.visible = visible_keys.has(key)


func _update_row(key: String, target: Dictionary, text: String, action: String) -> void:
	if not _rows.has(key):
		var box := VBoxContainer.new()
		var label := _label()
		var button := Button.new()
		button.clip_text = true
		box.add_child(label)
		box.add_child(button)
		_body.add_child(box)
		_rows[key] = {"box": box, "label": label, "button": button, "target": {}}
		button.pressed.connect(func() -> void: _navigate(_rows[key].target))
	_rows[key].target = target.duplicate(true)
	_rows[key].label.text = text
	_rows[key].button.text = action
	_rows[key].button.tooltip_text = action
	_rows[key].button.disabled = not _ready_state
	_rows[key].box.visible = true


func _navigate(target: Dictionary) -> void:
	if not _ready_state or target.is_empty():
		return
	var panel: String = target.get("panel", "inspector")
	if not _can_operate and panel in ["operations", "policies"]:
		panel = "inspector"
	navigation_requested.emit(
		panel, int(target.get("focus_tile_id", -1)), int(target.get("colonist_id", -1))
	)


func _label() -> Label:
	var label := Label.new()
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	ThemeTokens.apply_label(label, "small")
	return label
