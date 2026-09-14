## A map-first desktop. Only the frames intercept input; empty deck space is map.
class_name WorkspaceDeck
extends Control

signal workspace_changed

var model := WorkspaceLayout.new()
var windows: Dictionary = {}
var authorized: Dictionary = {}
var telemetry: HBoxContainer
var area: Control
var compact := false
var map_only := false
var _compact_panel := "people"
var _tabs: HBoxContainer
var _dock: HBoxContainer
var _ready_layout := false
var metrics := UiMetrics.new()
var _save_path := WorkspaceLayout.SAVE_PATH
var _dialog: AcceptDialog
var _name_input: LineEdit
var _checks: Dictionary = {}
var _copy: CheckBox
var _dialog_new := false
var _menu: MenuButton
var _map: Control
var _confirmation: ConfirmationDialog
var _status: Label
var _rows: Array[ScrollContainer] = []


func setup(map_control: Control, save_path := WorkspaceLayout.SAVE_PATH, ui_metrics := UiMetrics.new()) -> void:
	_save_path = save_path
	metrics = ui_metrics
	_map = map_control
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	var stack := VBoxContainer.new()
	stack.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	stack.add_theme_constant_override("separation", 0)
	stack.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(stack)
	var header := PanelContainer.new()
	stack.add_child(header)
	var rows := VBoxContainer.new()
	header.add_child(rows)
	telemetry = _scroll_row(rows, metrics.px(38))
	var workspace_row := _scroll_row(rows, metrics.px(34))
	var label := Label.new()
	label.text = "WORKSPACE"
	label.add_theme_font_size_override("font_size", metrics.font(10))
	label.add_theme_color_override("font_color", DeckTheme.MUTED)
	workspace_row.add_child(label)
	_tabs = HBoxContainer.new()
	workspace_row.add_child(_tabs)
	_button(workspace_row, "+ New", "Create a personal workspace", func() -> void: edit_workspace(true))
	_button(workspace_row, "Panels", "Choose panels / rename workspace (Ctrl+F)", func() -> void: edit_workspace(false))
	_button(workspace_row, "Save", "Save this device's layouts", save_layout)
	_status = Label.new()
	_status.add_theme_color_override("font_color", DeckTheme.MUTED)
	workspace_row.add_child(_status)
	_menu = MenuButton.new()
	_menu.text = "Layout"
	workspace_row.add_child(_menu)
	_menu.get_popup().add_item("Reset current layout", 0)
	_menu.get_popup().add_item("Delete custom workspace", 1)
	_menu.get_popup().id_pressed.connect(_layout_action)
	area = Control.new()
	area.name = "WindowArea"
	area.size_flags_vertical = Control.SIZE_EXPAND_FILL
	area.mouse_filter = Control.MOUSE_FILTER_IGNORE
	area.clip_contents = true
	stack.add_child(area)
	map_control.reparent(area)
	map_control.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	area.resized.connect(_apply_layout)
	_button(workspace_row, "Map", "Show or hide panels (Ctrl+\\)", toggle_map_only)
	_dock = HBoxContainer.new()
	workspace_row.add_child(_dock)
	_build_dialog()

func apply_metrics(ui_metrics: UiMetrics) -> void:
	_scale_control_tree(self, ui_metrics)
	metrics = ui_metrics
	for window: WorkspaceWindow in windows.values():
		window.metrics = metrics
		window.refresh_metrics()
	if is_instance_valid(_dialog):
		_dialog.min_size = Vector2i(metrics.px(300), 0)
	_apply_layout()

func _scale_control_tree(root: Node, target_metrics: UiMetrics) -> void:
	for child: Node in root.get_children():
		if child is Control:
			var control := child as Control
			if not control.has_meta("ui_font_reference"):
				var observed_font := control.get_theme_font_size("font_size")
				var current_font := observed_font if control.has_theme_font_override("font_size") or observed_font > metrics.base_font_size else metrics.base_font_size
				control.set_meta("ui_font_reference", float(current_font) / metrics.scale)
			control.add_theme_font_size_override("font_size", target_metrics.font(float(control.get_meta("ui_font_reference"))))
			if not control.has_meta("ui_minimum_reference"):
				control.set_meta("ui_minimum_reference", control.custom_minimum_size / metrics.scale)
			control.custom_minimum_size = control.get_meta("ui_minimum_reference") * target_metrics.scale
			if control is Container:
				var container := control as Container
				if not container.has_meta("ui_separation_reference"):
					container.set_meta("ui_separation_reference", float(container.get_theme_constant("separation")) / metrics.scale)
				container.add_theme_constant_override("separation", target_metrics.px(float(container.get_meta("ui_separation_reference"))))
		_scale_control_tree(child, target_metrics)


func _scroll_row(parent: Node, height: float) -> HBoxContainer:
	var scroll := ScrollContainer.new()
	scroll.custom_minimum_size.y = height
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_AUTO
	scroll.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	parent.add_child(scroll)
	_rows.append(scroll)
	var row := HBoxContainer.new()
	row.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.add_child(row)
	return row


func _button(parent: Node, text: String, hint: String, callback: Callable) -> Button:
	var button := Button.new()
	button.text = text
	button.tooltip_text = hint
	button.pressed.connect(callback)
	parent.add_child(button)
	return button


func add_panel(key: String) -> VBoxContainer:
	var window := WorkspaceWindow.new()
	window.name = key
	area.add_child(window)
	window.metrics = metrics
	window.setup(WorkspaceLayout.PANEL_NAMES[key])
	windows[key] = window
	authorized[key] = true
	window.focused.connect(focus_panel.bind(key))
	window.geometry_requested.connect(func(rect: Rect2, resizing: bool, unsnapped: bool) -> void:
		var others: Array[Rect2] = []
		for other: WorkspaceWindow in windows.values():
			if other != window and other.visible:
				others.append(Rect2(other.position, other.size))
		var snapped := WorkspaceLayout.clamp_rect(rect, area.size, metrics) if unsnapped else WorkspaceLayout.snap_rect(rect, area.size, others, resizing, metrics)
		window.position = snapped.position
		window.size = snapped.size)
	window.interaction_finished.connect(func() -> void:
		if not compact:
			state(key).rect = WorkspaceLayout.to_normalized(Rect2(window.position, window.size), area.size)
		save_layout())
	window.minimize_requested.connect(toggle_panel.bind(key))
	window.close_requested.connect(func() -> void:
		state(key).open = false
		_changed())
	window.pin_requested.connect(func() -> void:
		state(key).pinned = not state(key).pinned
		_changed())
	return window.content


func finish_setup() -> void:
	model.load_from(_save_path)
	_ready_layout = true
	_rebuild_navigation()
	_apply_layout()
	_status.text = "Layout defaults" if model.last_load_status != "loaded" else ""
	_status.tooltip_text = "Saved layout could not be read; defaults loaded (%s)." % model.last_load_status if model.last_load_status != "loaded" else ""


func state(key: String) -> Dictionary:
	return model.workspaces[model.active].panels[key]


func blocks_map_input(point: Vector2) -> bool:
	if _dialog.visible or (is_instance_valid(_confirmation) and _confirmation.visible) or not area.get_global_rect().has_point(point):
		return true
	for window: WorkspaceWindow in windows.values():
		if window.visible and (not window._gesture.is_empty() or window.get_global_rect().has_point(point)):
			return true
	return false


func set_panel_authorized(key: String, allowed: bool) -> void:
	if authorized.get(key) == allowed:
		return
	authorized[key] = allowed
	if _ready_layout:
		_rebuild_navigation()
		_apply_layout()
		if _dialog.visible:
			_sync_checks()


func switch_workspace(id: String) -> void:
	if not model.workspaces.has(id):
		return
	_cancel_gestures()
	model.active = id
	map_only = false
	_compact_panel = ""
	workspace_changed.emit()
	_changed()


func focus_panel(key: String) -> void:
	if not authorized.get(key, false):
		return
	if _compact_panel == key and area.get_child(-1) == windows[key]:
		return
	_compact_panel = key
	var order: Array = windows.keys()
	order.sort_custom(func(a: String, b: String) -> bool: return int(state(a).z) < int(state(b).z))
	order.erase(key)
	order.append(key)
	for index in order.size():
		state(order[index]).z = index
		windows[order[index]].set_focused(order[index] == key)
	area.move_child(windows[key], -1)
	if _ready_layout:
		save_layout()


func _input(event: InputEvent) -> void:
	if not _ready_layout or not event is InputEventMouseButton or not event.pressed or event.button_index != MOUSE_BUTTON_LEFT:
		return
	# Child scroll containers consume GUI events, so raise their frame before GUI dispatch.
	for index in range(area.get_child_count() - 1, -1, -1):
		var child := area.get_child(index)
		if child is WorkspaceWindow and child.visible and child.get_global_rect().has_point(event.position):
			focus_panel(child.name)
			break


func toggle_panel(key: String) -> void:
	if not authorized.get(key, false):
		return
	_cancel_gestures()
	if map_only or not state(key).open or state(key).minimized or (compact and _compact_panel != key):
		state(key).open = true
		state(key).minimized = false
		map_only = false
		focus_panel(key)
	else:
		state(key).minimized = true
	_changed()


func toggle_map_only() -> void:
	_cancel_gestures()
	map_only = not map_only
	_apply_layout()
	_rebuild_navigation()


func _cancel_gestures() -> void:
	for window: WorkspaceWindow in windows.values():
		window.cancel_interaction()


func _changed() -> void:
	_rebuild_navigation()
	_apply_layout()
	save_layout()


func save_layout() -> void:
	if not _ready_layout:
		return
	var error := model.save_to(_save_path)
	_status.text = "Layout saved" if error == OK else "Layout save failed"
	_status.tooltip_text = "" if error == OK else "Could not save local layout: %s" % error_string(error)


func _apply_layout() -> void:
	if not _ready_layout or area.size.x <= 0 or area.size.y <= 0:
		return
	compact = area.size.x < metrics.px(760) or area.size.y < metrics.px(400)
	var order: Array = windows.keys()
	order.sort_custom(func(a: String, b: String) -> bool: return int(state(a).z) < int(state(b).z))
	if compact and (_compact_panel.is_empty() or not authorized.get(_compact_panel, false) or not state(_compact_panel).open or state(_compact_panel).minimized):
		_compact_panel = ""
		for key: String in order:
			if authorized[key] and state(key).open and not state(key).minimized:
				_compact_panel = key
	for key: String in order:
		var window: WorkspaceWindow = windows[key]
		var saved := state(key)
		window.visible = authorized[key] and saved.open and not saved.minimized and not map_only and (not compact or key == _compact_panel)
		window.apply_state(saved.pinned, compact)
		var rect := Rect2(Vector2.ZERO, area.size) if compact else WorkspaceLayout.to_pixels(saved.rect, area.size, metrics)
		window.position = rect.position
		window.size = rect.size
		area.move_child(window, -1)
		window.set_focused(key == _compact_panel)
	_map.queue_redraw()


func _rebuild_navigation() -> void:
	for parent: HBoxContainer in [_tabs, _dock]:
		for child: Node in parent.get_children():
			parent.remove_child(child)
			child.queue_free()
	for id: String in model.workspaces:
		var button := _button(_tabs, model.workspaces[id].name, "Switch workspace", switch_workspace.bind(id))
		button.toggle_mode = true
		button.set_pressed_no_signal(model.active == id)
	var index := 0
	for key: String in windows:
		index += 1
		if not authorized[key] or not state(key).open:
			continue
		var button := _button(_dock, "%s %s" % ["+" if state(key).minimized or map_only else "-", WorkspaceLayout.PANEL_NAMES[key]],
			"Show/minimize panel (F%d)" % index, toggle_panel.bind(key))
		button.toggle_mode = true
		button.set_pressed_no_signal(not state(key).minimized and not map_only)
	_menu.get_popup().set_item_disabled(1, WorkspaceLayout.defaults().has(model.active))


func _build_dialog() -> void:
	_dialog = AcceptDialog.new()
	_dialog.title = "Workspace setup"
	_dialog.ok_button_text = "Apply"
	_dialog.min_size = Vector2i(metrics.px(300), 0)
	add_child(_dialog)
	var body := VBoxContainer.new()
	_dialog.add_child(body)
	_name_input = LineEdit.new()
	_name_input.placeholder_text = "Workspace name"
	_name_input.max_length = 40
	_name_input.text_changed.connect(func(text: String) -> void:
		_dialog.get_ok_button().disabled = text.strip_edges().is_empty())
	body.add_child(_name_input)
	_copy = CheckBox.new()
	_copy.text = "Copy current positions and sizes"
	_copy.button_pressed = true
	body.add_child(_copy)
	for key: String in WorkspaceLayout.PANEL_NAMES:
		var check := CheckBox.new()
		check.text = WorkspaceLayout.PANEL_NAMES[key]
		body.add_child(check)
		_checks[key] = check
	var note := Label.new()
	note.text = "Drag panel headers and resize their corners.\nEdges snap together; hold Alt for free placement.\nChanges save on this device, separately from the colony."
	note.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	note.add_theme_font_size_override("font_size", metrics.font(11))
	note.add_theme_color_override("font_color", DeckTheme.MUTED)
	body.add_child(note)
	_dialog.confirmed.connect(_confirm_workspace)


func _sync_checks() -> void:
	for key: String in _checks:
		_checks[key].visible = authorized.get(key, false)
		_checks[key].set_pressed_no_signal(state(key).open)


func edit_workspace(create: bool) -> void:
	_cancel_gestures()
	_dialog_new = create
	_name_input.text = "My workspace" if create else model.workspaces[model.active].name
	_name_input.editable = create or not WorkspaceLayout.defaults().has(model.active)
	_copy.visible = create
	_sync_checks()
	_dialog.title = "New workspace" if create else "Choose panels"
	_dialog.get_ok_button().disabled = false
	_dialog.popup_centered(Vector2i(mini(metrics.px(380), int(size.x - metrics.px(20))), 0))
	_name_input.grab_focus()
	_name_input.select_all()


func _confirm_workspace() -> void:
	var selected: Array[String] = []
	for key: String in _checks:
		# Permission downgrades must not overwrite a player's hidden panel preference.
		if (_checks[key].button_pressed and authorized[key]) or (not authorized[key] and state(key).open):
			selected.append(key)
	if _dialog_new:
		if model.create_workspace(_name_input.text, selected, _copy.button_pressed).is_empty():
			return
	else:
		if _name_input.editable and not _name_input.text.strip_edges().is_empty():
			model.workspaces[model.active].name = _name_input.text.strip_edges()
		for key: String in windows:
			state(key).open = key in selected
	map_only = false
	workspace_changed.emit()
	_changed()


func _layout_action(id: int) -> void:
	var confirmation := ConfirmationDialog.new()
	_confirmation = confirmation
	confirmation.title = "Reset layout" if id == 0 else "Delete workspace"
	confirmation.dialog_text = "Reset positions for this workspace?" if id == 0 else "Delete '%s'? Colony state is not affected." % model.workspaces[model.active].name
	add_child(confirmation)
	confirmation.confirmed.connect(func() -> void:
		_cancel_gestures()
		if id == 0:
			model.reset_active()
		else:
			model.remove_workspace(model.active)
		map_only = false
		workspace_changed.emit()
		_changed()
		confirmation.queue_free())
	confirmation.canceled.connect(confirmation.queue_free)
	confirmation.popup_centered()


func _unhandled_key_input(event: InputEvent) -> void:
	if not event is InputEventKey or not event.pressed or event.echo:
		return
	if event.ctrl_pressed and event.keycode == KEY_F:
		edit_workspace(false)
	elif event.ctrl_pressed and event.keycode == KEY_BACKSLASH:
		toggle_map_only()
	elif event.keycode >= KEY_F1 and event.keycode <= KEY_F8:
		toggle_panel(windows.keys()[event.keycode - KEY_F1])
	else:
		return
	get_viewport().set_input_as_handled()
