class_name ColonistCard
extends PanelContainer

signal selection_requested(id: Variant)
signal goto_requested(id: Variant)
signal command_requested(id: Variant, command: String)

const Models = preload("models.gd")
const UI = preload("presentation.gd")
const Meter = preload("need_meter.gd")
var model: Dictionary = {}

## Backend need fields: hunger, fatigue, recreation, mood, productivity.
## Optional commands: [{id: String, label: String, disabled_reason: String}].
func set_model(data: Dictionary, config: Dictionary = {}) -> void:
	model = Models.colonist(data, config)
	UI.clear(self)
	add_theme_stylebox_override("panel", UI.surface("bg-200", "accent" if model.selected else "line-100"))
	var content = UI.column()
	var head = UI.column()
	head.add_child(UI.wrapped(model.name, "body-strong", "ink"))
	head.add_child(UI.tag(model.state, model.state_level))
	content.add_child(head)
	content.add_child(UI.wrapped(model.job))
	content.add_child(UI.wrapped("Cargo: " + model.cargo, "readout"))
	for need in model.needs:
		var meter = Meter.new()
		meter.set_presentation_model(need)
		content.add_child(meter)
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

func _gui_input(event: InputEvent) -> void:
	if model.get("id_available", false) and event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT and event.pressed:
		selection_requested.emit(model.get("id"))

func _request_goto() -> void:
	if model.id_available and model.target_available:
		goto_requested.emit(model.id)
