class_name ColonistCard
extends PanelContainer

signal selection_requested(id: Variant)
signal goto_requested(id: Variant)
signal command_requested(id: Variant, command: String)

const Models = preload("models.gd")
const UI = preload("presentation.gd")
const Meter = preload("need_meter.gd")
var model: Dictionary = {}
var _actions: HFlowContainer

## Backend need fields: hunger, fatigue, recreation, mood, productivity.
## Optional commands: [{id: String, label: String, disabled_reason: String}].
func set_model(data: Dictionary, config: Dictionary = {}) -> void:
	var focused: Control = get_viewport().gui_get_focus_owner() if is_inside_tree() else null
	var retained_actions: HFlowContainer
	if is_instance_valid(_actions) and model.get("id") == data.get("id") and model.get("target") == data.get("target") and model.get("commands") == data.get("commands"):
		retained_actions = _actions
		_actions.get_parent().remove_child(_actions)
	model = Models.colonist(data, config)
	UI.clear(self)
	add_theme_stylebox_override("panel", UI.surface("bg-200", "accent" if model.selected else "line-100"))
	var content = UI.column()
	var head = UI.column()
	head.add_child(UI.wrapped(model.name, "body-strong", "ink"))
	var state_tag = UI.tag(model.state, model.state_level)
	state_tag.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	head.add_child(state_tag)
	content.add_child(head)
	content.add_child(UI.wrapped(model.job))
	var cargo = UI.flow()
	cargo.add_child(UI.label("Cargo:", "small"))
	if Models.numeric(model.get("cargo_amount")):
		cargo.add_child(UI.label("%.1f" % model.cargo_amount, "readout"))
		cargo.add_child(UI.wrapped(Models.text(model, "cargo_kind"), "small"))
	else:
		cargo.add_child(UI.wrapped(model.cargo, "small"))
	content.add_child(cargo)
	content.add_child(UI.label("Needs · higher is better", "section", "ink-subtle"))
	var needs = UI.column()
	needs.add_theme_constant_override("separation", 0)
	for need in model.needs:
		var meter = Meter.new()
		meter.set_presentation_model(need)
		needs.add_child(meter)
	content.add_child(needs)
	if model.get("automation_rules") is Array:
		for rule in model.automation_rules:
			if rule is Dictionary and rule.get("label") is String:
				content.add_child(UI.tag(rule.label, "notice", true))
	var actions = UI.flow()
	var goto_reason = "identifier unavailable" if not model.id_available else "target unavailable" if not model.target_available else ""
	var go_to = UI.button("Go to" + (" · " + goto_reason if not goto_reason.is_empty() else ""), _request_goto)
	go_to.disabled = not goto_reason.is_empty()
	actions.add_child(go_to)
	if model.get("commands") is Array:
		for command in model.commands:
			if not command is Dictionary or not command.get("label") is String or command.label.strip_edges().is_empty():
				continue
			var command_id = Models.text(command, "id")
			var reason = Models.text(command, "disabled_reason")
			if not model.id_available:
				reason = "identifier unavailable"
			elif not Models.valid_command(command_id):
				reason = "command identifier unavailable"
			var button = UI.button(command.label + (" · " + reason if not reason.is_empty() else ""), func():
				if model.id_available and Models.valid_command(command_id) and reason.is_empty():
					command_requested.emit(model.id, command_id))
			button.disabled = not reason.is_empty()
			actions.add_child(button)
	content.add_child(actions)
	add_child(content)
	if retained_actions != null:
		content.remove_child(actions)
		actions.queue_free()
		content.add_child(retained_actions)
		_actions = retained_actions
		if is_instance_valid(focused) and retained_actions.is_ancestor_of(focused):
			focused.grab_focus()
			_reveal_action.call_deferred(focused)
	else:
		_actions = actions

func _reveal_action(control: Control, settling_frames := 2) -> void:
	if not is_instance_valid(control) or not is_inside_tree():
		return
	if settling_frames > 0:
		get_tree().create_timer(0.0).timeout.connect(_reveal_action.bind(control, settling_frames - 1), CONNECT_ONE_SHOT)
		return
	if get_viewport().gui_get_focus_owner() != control:
		return
	var parent := get_parent()
	while parent != null:
		if parent is ScrollContainer:
			parent.ensure_control_visible(control)
		parent = parent.get_parent()

func _gui_input(event: InputEvent) -> void:
	if model.get("id_available", false) and event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT and event.pressed:
		selection_requested.emit(model.get("id"))

func _request_goto() -> void:
	if model.id_available and model.target_available:
		goto_requested.emit(model.id)
