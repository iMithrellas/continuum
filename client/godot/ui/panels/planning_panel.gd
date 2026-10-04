## Responsive, keyboard-reachable planning controls. Main owns tools and authority.
class_name PlanningPanel
extends VBoxContainer

signal tool_requested(system: StringName)
signal zone_chosen(kind: int)
signal remove_requested
signal clearance_changed(value: int)

var system: StringName
var activate: Button
var inspect: Button
var remove: Button
var state: Label
var estimate: Label
var selection: Label
var feedback: Label
var clearance: SpinBox
var choices: Dictionary = {}
var _choice_grid: GridContainer


func setup(value: StringName) -> void:
	system = value
	add_theme_constant_override("separation", 8)
	var room := system == &"construction"
	var hero := PanelContainer.new()
	var box := DeckTheme.box(
		ThemeTokens.color("bg-200"), Color("9c785c") if room else Color("668e89"), 12
	)
	box.border_width_left = 3
	hero.add_theme_stylebox_override("panel", box)
	add_child(hero)
	var content := VBoxContainer.new()
	content.add_theme_constant_override("separation", 6)
	hero.add_child(content)
	_label(content, "ROOM ENVELOPE" if room else "LAND USAGE", "section")
	_label(content, "Insulated room" if room else "Give land a purpose", "title")
	_label(
		content,
		"5 wood / cell · R 2.0 m²·K/W" if room else "Free designation · 1 cell per zone",
		"readout"
	)
	_label(
		content,
		(
			"Traversable insulation envelope. Temperature and food spoilage are future mechanics."
			if room
			else "Inside or outside rooms. Productive zones use standing work orders."
		),
		"small"
	)
	if room:
		var row := HBoxContainer.new()
		add_child(row)
		var caption := _label(row, "Clearance · 0.5m layers", "small")
		caption.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		clearance = SpinBox.new()
		clearance.min_value = PlanningModel.MIN_CLEARANCE
		clearance.max_value = 256
		clearance.value = PlanningModel.MIN_CLEARANCE
		clearance.custom_minimum_size.x = 72
		clearance.tooltip_text = "At least 4 layers (2m). Requires known supported air throughout the envelope."
		clearance.value_changed.connect(
			func(number: float) -> void: clearance_changed.emit(int(number))
		)
		row.add_child(clearance)
	else:
		_choice_grid = GridContainer.new()
		_choice_grid.columns = 2
		_choice_grid.add_theme_constant_override("h_separation", 6)
		_choice_grid.add_theme_constant_override("v_separation", 6)
		add_child(_choice_grid)
		resized.connect(
			func() -> void:
				_choice_grid.columns = 4 if size.x >= 700 else (3 if size.x >= 520 else 2)
		)
		for kind: int in PlanningModel.ZONES:
			var button := _button(
				_choice_grid, PlanningModel.ZONES[kind][0], func() -> void: zone_chosen.emit(kind)
			)
			button.toggle_mode = true
			button.tooltip_text = (
				PlanningModel.ZONES[kind][1] + ". Free; does not construct a building."
			)
			choices[kind] = button
	state = _label(self, "Inspect mode", "section")
	var actions := HBoxContainer.new()
	add_child(actions)
	activate = _button(
		actions, "Draw room" if room else "Draw zone", func() -> void: tool_requested.emit(system)
	)
	activate.toggle_mode = true
	activate.theme_type_variation = "ButtonPrimary"
	inspect = _button(actions, "Inspect", func() -> void: tool_requested.emit(&""))
	inspect.tooltip_text = "Return to selection. Esc or right-click cancels the active map tool."
	_label(
		self,
		"Drag one exposed floor; release to request. Esc cancels · up to 4,096 cells.",
		"small"
	)
	estimate = _label(self, "Select an area to estimate", "readout")
	feedback = _label(self, "", "small")
	feedback.visible = false
	add_child(HSeparator.new())
	_label(self, "SELECTED ROOM" if room else "SELECTED USAGE", "section")
	selection = _label(
		self, "Select a room on the map." if room else "Select a zone cell on the map.", "body"
	)
	remove = _button(
		self,
		"Demolish room" if room else "Clear selected usage",
		func() -> void: remove_requested.emit()
	)
	remove.theme_type_variation = "ButtonQuiet"
	_label(
		self,
		(
			"Demolition leaves usage. No wood refund."
			if room
			else "Clearing usage leaves the room intact."
		),
		"small"
	)


func _label(parent: Node, copy: String, role: String) -> Label:
	var label := Label.new()
	label.text = copy
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	ThemeTokens.apply_label(label, role)
	parent.add_child(label)
	return label


func _button(parent: Node, copy: String, callback: Callable) -> Button:
	var button := Button.new()
	button.text = copy
	button.custom_minimum_size.y = 32
	button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	button.pressed.connect(callback)
	parent.add_child(button)
	return button


func present(
	active: StringName,
	kind: int,
	allowed: bool,
	ready: bool,
	pending: bool,
	selected: String,
	removable: bool,
	estimate_text: String
) -> void:
	var reason := (
		""
		if allowed and ready and not pending
		else (
			"Operator access required"
			if not allowed
			else (
				"Waiting for colony state" if not ready else "Request pending · waiting for server"
			)
		)
	)
	activate.disabled = not reason.is_empty()
	activate.tooltip_text = (
		reason
		if not reason.is_empty()
		else "Activate this map tool. In compact layouts the panel minimizes to reveal the map."
	)
	activate.set_pressed_no_signal(active == system)
	state.text = (
		reason
		if not reason.is_empty()
		else (
			(
				"ACTIVE · "
				+ (
					"Draw room"
					if system == &"construction"
					else "Draw " + str(PlanningModel.ZONES[kind][0]).to_lower()
				)
			)
			if active == system
			else ("Inspect mode" if active == &"" else "Other map tool active")
		)
	)
	state.add_theme_color_override(
		"font_color",
		ThemeTokens.color("warn" if pending else ("ink" if active == system else "ink-muted"))
	)
	selection.text = selected
	estimate.text = estimate_text
	remove.disabled = not removable or not reason.is_empty()
	remove.tooltip_text = (
		reason
		if not reason.is_empty()
		else (
			"Select exactly one room."
			if system == &"construction"
			else "Select one usage cell. Legacy facilities clear as a whole."
		)
	)
	if clearance != null:
		clearance.editable = reason.is_empty()
	for id: int in choices:
		choices[id].disabled = not reason.is_empty()
		choices[id].set_pressed_no_signal(id == kind)
		choices[id].text = ("✓ " if id == kind else "") + str(PlanningModel.ZONES[id][0])


func show_feedback(copy: String) -> void:
	feedback.text = copy
	feedback.visible = not copy.is_empty()
