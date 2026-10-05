## A map-first desktop. Only the frames intercept input; empty deck space is map.
class_name WorkspaceDeck
extends Control

signal workspace_changed
signal header_layout_changed
signal layout_changed
signal command_action_requested(action: String)
signal save_failed(message: String)

var model := WorkspaceLayout.new()
var preference_error := ""
var windows: Dictionary = {}
var authorized: Dictionary = {}
var telemetry: HBoxContainer
var status_content: VBoxContainer
var area: Control
var compact := false
var map_only := false
var _compact_panel := "people"
var _tabs: HBoxContainer
var _panel_nav: HBoxContainer
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
var diagnostics_host: Control
var _telemetry_header: HBoxContainer
var _alert_summaries: Dictionary = {}
var _tab_buttons: Dictionary = {}
var _tab_alert_nodes: Dictionary = {}
var _panel_buttons: Dictionary = {}
var _drag_origins: Dictionary = {}
var _body_focus_reveal_pending := false
var _body_focus_reveal_epoch := 0
var _body_focus_reveal_callback := Callable()
var header: PanelContainer
var utility_row: HBoxContainer
var _header_rows: VBoxContainer
var _utilities: PanelContainer
var _status_viewport: ScrollContainer
var _diagnostics_graph := false
var command_card: CommandCard
var _command_keyboard := false
var _edge_elapsed := 0.0
var _close_elapsed := 0.0
var _edge_armed := false
var _edge_suppressed := false
var _pointer_down := false
var _command_key_event_id := 0
var _command_key_frame := -1


func setup(
	map_control: Control, save_path := WorkspaceLayout.SAVE_PATH, _ui_metrics := UiMetrics.new()
) -> void:
	_save_path = save_path
	metrics = UiMetrics.new()
	_map = map_control
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	var stack := VBoxContainer.new()
	stack.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	stack.add_theme_constant_override("separation", 0)
	stack.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(stack)
	header = PanelContainer.new()
	header.name = "GlobalHeader"
	header.hide()
	var surface := DeckTheme.box(ThemeTokens.color("bg-000"), ThemeTokens.color("line-100"), 12)
	surface.content_margin_top = 8
	surface.content_margin_bottom = 4
	surface.set_corner_radius_all(0)
	surface.set_border_width_all(0)
	surface.border_width_bottom = 1
	header.add_theme_stylebox_override("panel", surface)
	stack.add_child(header)
	_header_rows = VBoxContainer.new()
	_header_rows.add_theme_constant_override("separation", 8)
	header.add_child(_header_rows)
	_telemetry_header = HBoxContainer.new()
	_telemetry_header.add_theme_constant_override("separation", 12)
	_header_rows.add_child(_telemetry_header)
	telemetry = _scroll_row(_telemetry_header, ThemeTokens.number("topbar"))
	telemetry.add_theme_constant_override("separation", 12)
	status_content = VBoxContainer.new()
	status_content.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	status_content.add_theme_constant_override("separation", 8)
	status_content.custom_minimum_size.y = ThemeTokens.number("topbar")
	_status_viewport = telemetry.get_parent()
	_status_viewport.remove_child(telemetry)
	_status_viewport.add_child(status_content)
	status_content.add_child(telemetry)
	telemetry.custom_minimum_size.y = ThemeTokens.number("topbar")
	_utilities = PanelContainer.new()
	_utilities.name = "ViewLayoutUtilities"
	_utilities.custom_minimum_size.y = 44
	_utilities.size_flags_vertical = Control.SIZE_SHRINK_BEGIN
	var utility_surface := DeckTheme.box(
		ThemeTokens.color("bg-100"), ThemeTokens.color("line-100"), 8
	)
	utility_surface.content_margin_top = 4
	utility_surface.content_margin_bottom = 4
	_utilities.add_theme_stylebox_override("panel", utility_surface)
	_telemetry_header.add_child(_utilities)
	utility_row = HBoxContainer.new()
	utility_row.custom_minimum_size.y = 32
	utility_row.add_theme_constant_override("separation", 8)
	_utilities.add_child(utility_row)
	diagnostics_host = Control.new()
	diagnostics_host.name = "DiagnosticsHost"
	diagnostics_host.mouse_filter = Control.MOUSE_FILTER_IGNORE
	diagnostics_host.clip_contents = true
	diagnostics_host.visible = false
	add_child(diagnostics_host)
	_telemetry_header.resized.connect(_resize_diagnostics_host)
	_status_viewport.resized.connect(func() -> void: header_layout_changed.emit())
	var workspace_row := _scroll_row(_header_rows, ThemeTokens.number("panel-header"))
	workspace_row.add_theme_constant_override("separation", 12)
	var views := Label.new()
	views.text = "VIEWS"
	ThemeTokens.apply_label(views, "section")
	views.tooltip_text = "Personal view presets. Switching views only changes the panels on this device."
	workspace_row.add_child(views)
	_tabs = HBoxContainer.new()
	workspace_row.add_child(_tabs)
	_status = Label.new()
	add_child(_status)
	_status.hide()
	_menu = MenuButton.new()
	_menu.focus_mode = Control.FOCUS_ALL
	_menu.text = "Panels"
	_menu.icon = UiIcons.texture("chevron-down")
	_menu.custom_minimum_size.y = 32
	_menu.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	utility_row.add_child(_menu)
	_menu.get_popup().id_pressed.connect(_layout_action)
	_menu.about_to_popup.connect(_build_management_menu)
	workspace_row.resized.connect(_fit_navigation)
	area = Control.new()
	area.name = "WindowArea"
	area.size_flags_vertical = Control.SIZE_EXPAND_FILL
	area.mouse_filter = Control.MOUSE_FILTER_IGNORE
	area.clip_contents = true
	stack.add_child(area)
	map_control.reparent(area)
	map_control.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	area.resized.connect(_apply_layout)
	area.resized.connect(_fit_command)
	area.resized.connect(_fit_navigation)
	resized.connect(_fit_header)
	_fit_header.call_deferred()
	_panel_nav = HBoxContainer.new()
	add_child(_panel_nav)
	_panel_nav.hide()
	_build_dialog()
	command_card = CommandCard.new()
	command_card.name = "CommandCard"
	command_card.z_index = 100
	add_child(command_card)
	command_card.setup(self)
	command_card.action_requested.connect(
		func(action: String) -> void: command_action_requested.emit(action)
	)
	command_card.hide()
	resized.connect(_fit_command)
	_fit_command()


func apply_metrics(_ui_metrics: UiMetrics) -> void:
	metrics = UiMetrics.new()
	_resize_diagnostics_host()
	for window: WorkspaceWindow in windows.values():
		window.metrics = metrics
		window.refresh_metrics()
	if is_instance_valid(_dialog):
		_dialog.min_size = Vector2i(metrics.px(300), 0)
	_apply_layout()


func set_diagnostics_visible(enabled: bool, graph := false) -> void:
	diagnostics_host.visible = enabled
	_diagnostics_graph = enabled and graph
	_resize_diagnostics_host()
	if _ready_layout and windows.has("performance"):
		var value := "collapsed" if state("performance").minimized else "open"
		set_panel_state("performance", value if enabled else "closed")


func _resize_diagnostics_host() -> void:
	if not is_instance_valid(diagnostics_host):
		return
	var collapsed: bool = (
		_ready_layout and windows.has("performance") and state("performance").minimized
	)
	diagnostics_host.custom_minimum_size = (
		Vector2(80 if collapsed else (400 if _diagnostics_graph else 320), 22)
		if diagnostics_host.visible
		else Vector2.ZERO
	)


func status_width() -> float:
	return maxf(1, status_content.size.x if status_content.is_visible_in_tree() else area.size.x)


func _fit_header() -> void:
	if not is_instance_valid(_utilities):
		return
	var stacked := size.x < 550
	var parent: Container = _header_rows if stacked else _telemetry_header
	if _utilities.get_parent() != parent:
		_utilities.reparent(parent)
		if stacked:
			_header_rows.move_child(_utilities, 0)
	_utilities.size_flags_horizontal = Control.SIZE_SHRINK_END if stacked else Control.SIZE_FILL
	_resize_diagnostics_host()
	header_layout_changed.emit()


func _scroll_row(parent: Node, height: float) -> HBoxContainer:
	var scroll := ScrollContainer.new()
	scroll.custom_minimum_size.y = height
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_SHOW_NEVER
	scroll.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	parent.add_child(scroll)
	_rows.append(scroll)
	var row := HBoxContainer.new()
	row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.add_child(row)
	return row


func _button(parent: Node, text: String, hint: String, callback: Callable) -> Button:
	var button := Button.new()
	button.text = text
	button.theme_type_variation = "ButtonQuiet"
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
	if key in ["status", "session", "performance"]:
		window.set_micro_mode(true)
		window.micro_content.minimum_size_changed.connect(
			func() -> void: _apply_layout.call_deferred()
		)
	window.scroll.resized.connect(_queue_body_focus_reveal)
	windows[key] = window
	authorized[key] = true
	window.focused.connect(focus_panel.bind(key))
	window.interaction_started.connect(
		func() -> void:
			_drag_origins[key] = state(key).duplicate(true)
			var remembered := _floating_rect(key)
			remembered.position = remembered.position.round()
			remembered.size = remembered.size.round()
			if (
				window.position.distance_to(remembered.position) > 0.01
				or window.size.distance_to(remembered.size) > 0.01
			):
				_drag_origins[key].rect = _remembered_geometry(key)
	)
	window.headers_requested.connect(
		func() -> void:
			if not model.show_panel_headers:
				toggle_panel_headers()
	)
	window.interaction_cancelled.connect(
		func() -> void:
			if _drag_origins.has(key):
				model.workspaces[model.active].panels[key] = _drag_origins[key]
				_drag_origins.erase(key)
				_apply_layout()
			else:
				if not compact:
					state(key).rect = _remembered_geometry(key)
			save_layout()
	)
	window.geometry_requested.connect(
		func(rect: Rect2, resizing: bool, unsnapped: bool) -> void:
			var others: Array[Rect2] = []
			for other: WorkspaceWindow in windows.values():
				if other != window and other.is_visible_in_tree():
					var visible_rect := _visible_control_rect(other)
					if visible_rect.has_area():
						others.append(
							Rect2(
								(
									area.get_global_transform().affine_inverse()
									* visible_rect.position
								),
								visible_rect.size
							)
						)
			var snapped: Rect2
			var minimum := (
				window.micro_size()
				if key in ["status", "session", "performance"]
				else (
					Vector2(window.tab_width(), window.chrome_height())
					if window.collapsed
					else Vector2.ZERO
				)
			)
			if unsnapped:
				snapped = (
					WorkspaceLayout.clamp_resize_rect(
						rect, area.size, window._resize_edges, metrics
					)
					if resizing
					else WorkspaceLayout.clamp_rect(rect, area.size, metrics, minimum)
				)
			else:
				snapped = WorkspaceLayout.snap_rect(
					rect, area.size, others, resizing, metrics, window._resize_edges, minimum
				)
			snapped.position = snapped.position.round()
			snapped.size = snapped.size.round()
			window.position = snapped.position
			window.size = snapped.size
	)
	window.interaction_finished.connect(
		func() -> void:
			var original := _floating_rect(key)
			var moved := window.position.distance_to(original.position.round()) > 0.01
			var resized := window.size.distance_to(original.size.round()) > 0.01
			if not compact and (moved or resized):
				state(key).rect = _remembered_geometry(key)
				state(key).erase("design")
			_drag_origins.erase(key)
			save_layout()
			_refresh_command()
			layout_changed.emit()
	)
	window.minimize_requested.connect(toggle_panel.bind(key))
	window.close_requested.connect(
		func() -> void:
			state(key).open = false
			_changed()
	)
	window.pin_requested.connect(
		func() -> void:
			state(key).pinned = not state(key).pinned
			_changed()
	)
	return window.content


## Collapsed gestures persist position only; the body dimensions remain intact.
## Copy normalized dimensions verbatim to avoid rounding drift over collapse cycles.
func _remembered_geometry(key: String) -> Array:
	var window: WorkspaceWindow = windows[key]
	var rect := WorkspaceLayout.to_normalized(Rect2(window.position, window.size), area.size)
	if window.collapsed or key in ["status", "session", "performance"]:
		rect[2] = state(key).rect[2]
		rect[3] = state(key).rect[3]
	return rect


## Saved dimensions describe the body; collapsed bounds describe only the header.
## Read the saved anchor before expanded clamping, including after viewport changes.
func _floating_rect(key: String) -> Rect2:
	var saved := state(key)
	var window: WorkspaceWindow = windows[key]
	var rect := WorkspaceLayout.to_pixels(saved.rect, area.size, metrics)
	var micro := key in ["status", "session", "performance"]
	if saved.has("design"):
		rect = WorkspaceLayout.design_rect(saved.design, area.size)
	if micro or saved.minimized:
		var minimum := (
			window.micro_size() if micro else Vector2(window.tab_width(), window.chrome_height())
		)
		rect.position = Vector2(saved.rect[0], saved.rect[1]) * area.size
		rect.size = minimum
		if saved.has("design"):
			rect = WorkspaceLayout.design_rect(saved.design, area.size, minimum)
		rect = WorkspaceLayout.clamp_rect(rect, area.size, metrics, minimum)
	if key == "performance" and saved.has("design"):
		rect = _responsive_performance_rect(rect)
	return rect


## Stack only design-anchored telemetry; user-positioned rectangles stay untouched.
func _responsive_performance_rect(rect: Rect2) -> Rect2:
	var result := rect
	var anchor: Dictionary = state("performance").design
	if anchor.y == "top":
		var stack := compact
		var bottom := result.position.y
		for key: String in ["status", "session"]:
			if not _designed_micro_open(key) or state(key).design.y != "top":
				continue
			var other := _floating_rect(key)
			stack = stack or result.intersects(other)
			bottom = maxf(bottom, other.end.y + 10)
		if stack:
			result.position.y = bottom
	elif anchor.y == "bottom" and _designed_micro_open("session"):
		var session_rect := _floating_rect("session")
		if state("session").design.y == "bottom" and (compact or result.intersects(session_rect)):
			result.position.y = session_rect.position.y - result.size.y - 10
	return WorkspaceLayout.clamp_rect(result, area.size, metrics, result.size)


func _designed_micro_open(key: String) -> bool:
	return (
		windows.has(key)
		and authorized.get(key, false)
		and state(key).open
		and state(key).has("design")
	)


## Alert ownership and aggregation belong to integration, not local preferences.
func set_workspace_alert_summary(id: String, level: String, count: int) -> void:
	if not model.workspaces.has(id):
		return
	var summary := (
		{"level": level, "count": count} if count > 0 and level in ["warn", "critical"] else {}
	)
	if _alert_summaries.get(id, {}) == summary:
		return
	if count <= 0 or level not in ["warn", "critical"]:
		_alert_summaries.erase(id)
	else:
		_alert_summaries[id] = summary
	if _ready_layout:
		_update_tab_alert(id)


func set_panel_live_count(key: String, count: int = -1) -> void:
	if windows.has(key):
		windows[key].set_live_count(count)


func finish_setup() -> void:
	model.load_from(_save_path)
	_ready_layout = true
	_rebuild_navigation()
	_apply_layout()
	_status.text = "Layout defaults" if model.last_load_status != "loaded" else ""
	_status.tooltip_text = (
		"Saved layout could not be read; defaults loaded (%s)." % model.last_load_status
		if model.last_load_status != "loaded"
		else ""
	)


func state(key: String) -> Dictionary:
	return model.workspaces[model.active].panels[key]


func blocks_map_input(point: Vector2) -> bool:
	if is_command_open() and command_card.get_global_rect().has_point(point):
		return true
	if (
		_dialog.visible
		or _menu.get_popup().visible
		or (is_instance_valid(_confirmation) and _confirmation.visible)
		or not _map.get_global_rect().has_point(point)
	):
		return true
	for window: WorkspaceWindow in windows.values():
		if (
			window.visible
			and (not window._gesture.is_empty() or window.contains_global_point(point))
		):
			return true
	return false


func set_panel_authorized(key: String, allowed: bool) -> void:
	if authorized.get(key) == allowed:
		return
	authorized[key] = allowed
	if not allowed and windows.has(key):
		_alert_summaries.clear()
		if is_instance_valid(_map) and _map.has_method("cancel_gestures"):
			_map.call("cancel_gestures")
		windows[key].cancel_interaction()
		windows[key].visible = false
		var viewport := get_viewport() if is_inside_tree() else null
		var focus := viewport.gui_get_focus_owner() if viewport != null else null
		if focus != null and windows[key].is_ancestor_of(focus):
			focus.release_focus()
	if _ready_layout and is_inside_tree():
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
	if (
		_compact_panel == key
		and windows[key].get_parent() == area
		and area.get_child(-1) == windows[key]
	):
		return
	_compact_panel = key
	var order: Array = windows.keys()
	order.sort_custom(func(a: String, b: String) -> bool: return int(state(a).z) < int(state(b).z))
	order.erase(key)
	order.append(key)
	for index in order.size():
		state(order[index]).z = index
		windows[order[index]].set_focused(order[index] == key)
	if windows[key].get_parent() == area:
		area.move_child(windows[key], -1)
	if _ready_layout:
		save_layout()


func _input(event: InputEvent) -> void:
	if event is InputEventMouseMotion:
		_pointer_down = (event.button_mask & MOUSE_BUTTON_MASK_LEFT) != 0
		var point: Vector2 = get_global_transform_with_canvas().affine_inverse() * event.position
		var at_edge: bool = point.x >= 0 and point.x <= 6 and point.y >= 0 and point.y <= size.y
		if not at_edge:
			_edge_suppressed = false
			_edge_elapsed = 0
		_edge_armed = (
			at_edge
			and not _edge_suppressed
			and not _pointer_down
			and not Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT)
		)
	elif event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		_pointer_down = event.pressed
		_edge_armed = false
		_edge_elapsed = 0
	if _ready_layout and event is InputEventKey and event.pressed and not event.echo:
		if event.ctrl_pressed and event.keycode in [KEY_K, KEY_P]:
			if (
				_command_key_event_id == event.get_instance_id()
				and _command_key_frame == Engine.get_process_frames()
			):
				return
			_command_key_event_id = event.get_instance_id()
			_command_key_frame = Engine.get_process_frames()
			if is_command_open():
				close_command()
			else:
				open_command(true)
			get_viewport().set_input_as_handled()
			return
	if (
		is_command_open()
		and event is InputEventMouseButton
		and command_card.get_global_rect().has_point(event.position)
	):
		return
	if (
		not _ready_layout
		or not event is InputEventMouseButton
		or not event.pressed
		or event.button_index != MOUSE_BUTTON_LEFT
	):
		return
	var order: Array = windows.keys()
	order.sort_custom(
		func(a: String, b: String) -> bool:
			var a_float: bool = windows[a].get_parent() == area
			var b_float: bool = windows[b].get_parent() == area
			return int(state(a).z) > int(state(b).z) if a_float == b_float else a_float
	)
	for key: String in order:
		var child: WorkspaceWindow = windows[key]
		if child.is_visible_in_tree() and child.contains_global_point(event.position):
			focus_panel(child.name)
			if (
				event.alt_pressed
				and not child.header_visible
				and not child.pinned
				and not child.compact
			):
				var on_handle := false
				for handle: Control in child.resize_handles.values():
					if handle.visible and handle.get_global_rect().has_point(event.position):
						on_handle = true
						break
				if not on_handle:
					child.begin_move_from_global(event.position)
					get_viewport().set_input_as_handled()
			break


func toggle_panel(key: String) -> void:
	if not authorized.get(key, false):
		return
	_cancel_gestures()
	if (
		map_only
		or not state(key).open
		or state(key).minimized
		or (compact and _compact_panel != key)
	):
		if (
			state(key).minimized
			and not compact
			and not state(key).has("design")
			and key not in ["status", "session", "performance"]
		):
			var restored := WorkspaceLayout.to_pixels(state(key).rect, area.size, metrics)
			var saved_anchor := Vector2(state(key).rect[0], state(key).rect[1]) * area.size
			if restored.position.distance_to(saved_anchor) > 0.01:
				var anchor := WorkspaceLayout.to_normalized(restored, area.size)
				state(key).rect[0] = anchor[0]
				state(key).rect[1] = anchor[1]
		state(key).open = true
		state(key).minimized = false
		map_only = false
		focus_panel(key)
	else:
		state(key).minimized = true
	_changed()


func _visible_control_rect(control: Control) -> Rect2:
	if control is WorkspaceWindow:
		return control.get_visible_global_rect()
	var rect := control.get_global_rect()
	var parent := control.get_parent()
	while parent != null:
		if parent is Control and parent.clip_contents:
			rect = rect.intersection(parent.get_global_rect())
		parent = parent.get_parent()
	return rect


func toggle_map_only() -> void:
	_cancel_gestures()
	map_only = not map_only
	_apply_layout()
	_rebuild_navigation()


func toggle_panel_headers() -> void:
	_cancel_gestures()
	model.show_panel_headers = not model.show_panel_headers
	_changed()


func _cancel_gestures() -> void:
	if is_instance_valid(_map) and _map.has_method("cancel_gestures"):
		_map.call("cancel_gestures")
	for window: WorkspaceWindow in windows.values():
		window.cancel_interaction()


func _changed() -> void:
	_rebuild_navigation()
	_apply_layout()
	save_layout()


func save_layout() -> Error:
	if not _ready_layout:
		return ERR_UNCONFIGURED
	var error := _save_preferences()
	_report_preference_save(error)
	return error


func _save_preferences() -> Error:
	return model.save_to(_save_path)


func _report_preference_save(error: Error) -> void:
	var previous_error := preference_error
	preference_error = (
		"" if error == OK else "Could not save local layout: %s" % error_string(error)
	)
	_status.text = "Layout saved" if error == OK else "Layout save failed"
	_status.tooltip_text = preference_error
	if error != OK:
		save_failed.emit(preference_error)
	if preference_error != previous_error:
		_refresh_command()


func _apply_layout() -> void:
	if not _ready_layout or area.size.x <= 0 or area.size.y <= 0:
		return
	var was_compact := compact
	var minimum := _floating_minimum()
	compact = area.size.x < minimum.x or area.size.y < minimum.y
	if compact != was_compact:
		_cancel_gestures()
	var order: Array = windows.keys()
	order.sort_custom(func(a: String, b: String) -> bool: return int(state(a).z) < int(state(b).z))
	var expanded_standard := false
	for key: String in order:
		if (
			key not in ["status", "session", "performance"]
			and authorized[key]
			and state(key).open
			and not state(key).minimized
		):
			expanded_standard = true
	if (
		compact
		and (
			_compact_panel.is_empty()
			or not authorized.get(_compact_panel, false)
			or not state(_compact_panel).open
			or _compact_panel in ["status", "session", "performance"]
			or (state(_compact_panel).minimized and expanded_standard)
		)
	):
		_compact_panel = ""
		for key: String in order:
			if (
				key not in ["status", "session", "performance"]
				and authorized[key]
				and state(key).open
				and not state(key).minimized
			):
				_compact_panel = key
		if _compact_panel.is_empty():
			for key: String in order:
				if (
					key not in ["status", "session", "performance"]
					and authorized[key]
					and state(key).open
				):
					_compact_panel = key
	for key: String in order:
		var window: WorkspaceWindow = windows[key]
		var saved := state(key)
		var micro := key in ["status", "session", "performance"]
		window.visible = (
			authorized[key]
			and saved.open
			and not map_only
			and (not compact or micro or key == _compact_panel)
		)
		window.apply_state(saved.pinned, compact and not micro)
		window.set_collapsed(saved.minimized)
		window.set_header_visible(model.show_panel_headers or saved.minimized)
	# Measure telemetry only after every window has applied its current presentation.
	var standard_rect := _compact_standard_rect() if compact else Rect2()
	for key: String in order:
		var window: WorkspaceWindow = windows[key]
		var saved := state(key)
		var micro := key in ["status", "session", "performance"]
		var rect := _floating_rect(key)
		if compact and not micro:
			rect = standard_rect
			if saved.minimized:
				rect.size = Vector2(minf(window.tab_width(), rect.size.x), window.chrome_height())
		if not compact:
			rect.position = rect.position.round()
			rect.size = rect.size.round()
		window.position = rect.position
		window.size = rect.size
		if window.get_parent() == area:
			area.move_child(window, -1)
		window.set_focused(key == _compact_panel)
	if compact:
		for key: String in ["status", "session", "performance"]:
			if windows.has(key) and windows[key].get_parent() == area:
				area.move_child(windows[key], -1)
	_map.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_map.queue_redraw()
	_queue_body_focus_reveal()
	_resize_diagnostics_host()
	layout_changed.emit()


## Anchor-based budgets also protect copied presets, without constraining user geometry.
func _floating_minimum() -> Vector2:
	var minimum := Vector2(640, 400)
	var bodies: Array[Dictionary] = []
	for key: String in windows:
		if key in ["status", "session", "performance"] or not _designed_micro_open(key):
			continue
		minimum.x = maxf(minimum.x, 960)
		if state(key).minimized:
			continue
		var anchor: Dictionary = state(key).design
		bodies.append(anchor)
		# Welfare's wide top-right roster must leave the centered clock readable.
		if (
			anchor.x == "right"
			and anchor.y == "top"
			and anchor.width >= 380
			and _designed_micro_open("status")
		):
			var clock: WorkspaceWindow = windows["status"]
			# Reserve inline controls without depending on transient hover visibility.
			var clock_width := clock.micro_content.get_combined_minimum_size().x + 86
			minimum.x = maxf(
				minimum.x, maxf(1040, 2 * (anchor.width + anchor.dx + 12) + clock_width)
			)
		# Reserve the possible three-row top telemetry stack for bottom-right bodies.
		if (
			anchor.x == "right"
			and anchor.y == "bottom"
			and _designed_micro_open("performance")
			and state("performance").design.y == "top"
		):
			minimum.y = maxf(minimum.y, anchor.height + anchor.dy + 130)
	for top: Dictionary in bodies:
		if top.y != "top":
			continue
		for bottom: Dictionary in bodies:
			if bottom.y != "bottom" or bottom.x != top.x:
				continue
			if top.dx + top.width <= bottom.dx or bottom.dx + bottom.width <= top.dx:
				continue
			minimum.y = maxf(minimum.y, top.dy + top.height + bottom.dy + bottom.height + 12)
	return minimum


## Only the selected body uses this free band. The map still fills the entire deck.
## Reserve telemetry's painted vertical spans, not a permanent global header.
func _compact_standard_rect() -> Rect2:
	var inset := minf(8, minf(area.size.x, area.size.y) / 2)
	var spans: Array[Vector2] = []
	for key: String in ["status", "session", "performance"]:
		if (
			not windows.has(key)
			or not authorized.get(key, false)
			or not state(key).open
			or map_only
		):
			continue
		var painted := _floating_rect(key).intersection(Rect2(Vector2.ZERO, area.size))
		if painted.has_area():
			spans.append(
				Vector2(
					maxf(inset, painted.position.y - 8),
					minf(area.size.y - inset, painted.end.y + 8)
				)
			)
	spans.sort_custom(func(a: Vector2, b: Vector2) -> bool: return a.x < b.x)
	var cursor := inset
	var best := Vector2(inset, inset)
	for span: Vector2 in spans:
		if span.x - cursor > best.y - best.x:
			best = Vector2(cursor, span.x)
		cursor = maxf(cursor, span.y)
	if area.size.y - inset - cursor > best.y - best.x:
		best = Vector2(cursor, area.size.y - inset)
	# Extremely short viewports cannot fit all telemetry plus a tab; keep the tab usable.
	var height := maxf(best.y - best.x, minf(26, area.size.y - inset * 2))
	var top := clampf(best.x, inset, maxf(inset, area.size.y - inset - height))
	return Rect2(Vector2(inset, top), Vector2(maxf(1, area.size.x - inset * 2), height))


func _queue_body_focus_reveal() -> void:
	if _body_focus_reveal_pending or not is_inside_tree():
		return
	var control := get_viewport().gui_get_focus_owner()
	if control == null:
		return
	_body_focus_reveal_pending = true
	# A freed, typed Control fails argument conversion before the callback can clear its latch.
	_schedule_body_focus_reveal(weakref(control), 2, _body_focus_reveal_epoch)


func _schedule_body_focus_reveal(control_ref: WeakRef, settling_frames: int, epoch: int) -> void:
	_body_focus_reveal_callback = _reveal_retained_body_focus.bind(
		control_ref, settling_frames, epoch
	)
	get_tree().process_frame.connect(_body_focus_reveal_callback, CONNECT_ONE_SHOT)


## Leaving the tree invalidates callbacks even if this same deck is later reattached.
func _exit_tree() -> void:
	if (
		_body_focus_reveal_callback.is_valid()
		and get_tree().process_frame.is_connected(_body_focus_reveal_callback)
	):
		get_tree().process_frame.disconnect(_body_focus_reveal_callback)
	_body_focus_reveal_callback = Callable()
	_body_focus_reveal_epoch += 1
	_body_focus_reveal_pending = false


func _reveal_retained_body_focus(control_ref: WeakRef, settling_frames: int, epoch: int) -> void:
	if epoch != _body_focus_reveal_epoch:
		return
	_body_focus_reveal_callback = Callable()
	var control := control_ref.get_ref() as Control
	if (
		not is_inside_tree()
		or not is_instance_valid(control)
		or not control.is_visible_in_tree()
		or get_viewport().gui_get_focus_owner() != control
	):
		_body_focus_reveal_pending = false
		return
	if settling_frames > 0:
		_schedule_body_focus_reveal(control_ref, settling_frames - 1, epoch)
		return
	_body_focus_reveal_pending = false
	if _dialog.visible or (is_instance_valid(_confirmation) and _confirmation.visible):
		return
	for window: WorkspaceWindow in windows.values():
		if not window._gesture.is_empty():
			return
	for key: String in windows:
		var window: WorkspaceWindow = windows[key]
		if (
			not authorized.get(key, false)
			or not window.is_visible_in_tree()
			or not window.scroll.is_ancestor_of(control)
		):
			continue
		var parent := control.get_parent()
		while parent != window and parent != null:
			if (
				parent is ScrollContainer
				and not parent.get_global_rect().encloses(control.get_global_rect())
			):
				parent.ensure_control_visible(control)
			parent = parent.get_parent()
		return


func _rebuild_navigation() -> void:
	_refresh_command()


func _refresh_command() -> void:
	if is_instance_valid(command_card) and command_card.has_method("refresh"):
		command_card.call("refresh")


func _fit_command() -> void:
	if not is_instance_valid(command_card):
		return
	command_card.set_anchors_and_offsets_preset(Control.PRESET_TOP_LEFT)
	var width := minf(272, maxf(1, area.size.x - 16))
	if command_card.has_method("set_available_size"):
		command_card.call("set_available_size", area.size)
	command_card.position = Vector2(8, 8)
	command_card.custom_minimum_size.x = width
	command_card.size = Vector2(width, maxf(1, area.size.y - 16))


func is_command_open() -> bool:
	return is_instance_valid(command_card) and command_card.visible


func open_command(keyboard := true) -> void:
	_cancel_gestures()
	_command_keyboard = keyboard
	_edge_elapsed = 0
	_close_elapsed = 0
	command_card.show()
	_fit_command()
	_refresh_command()
	if keyboard and command_card.has_method("focus_search"):
		command_card.call("focus_search")


func close_command() -> void:
	if not is_command_open():
		return
	var focus := get_viewport().gui_get_focus_owner()
	if focus != null and command_card.is_ancestor_of(focus):
		focus.release_focus()
	command_card.hide()
	_command_keyboard = false
	_edge_elapsed = 0
	_close_elapsed = 0
	_edge_armed = false
	_edge_suppressed = true


func _process(delta: float) -> void:
	if (
		not _ready_layout
		or _dialog.visible
		or (is_instance_valid(_confirmation) and _confirmation.visible)
	):
		_edge_armed = false
		_edge_elapsed = 0
		return
	var point := get_local_mouse_position()
	if not is_command_open():
		if _edge_reveal_blocked():
			_edge_armed = false
			_edge_elapsed = 0
			return
		_edge_elapsed = (
			_edge_elapsed + delta
			if (
				_edge_armed
				and not _pointer_down
				and not Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT)
			)
			else 0.0
		)
		if _edge_elapsed >= 0.12:
			open_command(false)
		return
	var focus := get_viewport().gui_get_focus_owner()
	var retained_focus := focus != null and command_card.is_ancestor_of(focus)
	if (
		_command_keyboard
		or retained_focus
		or point.x <= command_card.position.x + command_card.size.x + 24
	):
		_close_elapsed = 0
	else:
		_close_elapsed += delta
		if _close_elapsed >= 0.28:
			close_command()


func _edge_reveal_blocked() -> bool:
	var focus := get_viewport().gui_get_focus_owner()
	if focus is LineEdit or focus is TextEdit:
		return true
	for window: WorkspaceWindow in windows.values():
		if not window._gesture.is_empty():
			return true
	return false


func set_panel_state(key: String, value: String) -> void:
	if (
		not windows.has(key)
		or not authorized.get(key, false)
		or value not in ["open", "collapsed", "closed"]
	):
		return
	if (
		state(key).open == (value != "closed")
		and state(key).minimized == (value == "collapsed")
		and not map_only
	):
		return
	_cancel_gestures()
	state(key).open = value != "closed"
	state(key).minimized = value == "collapsed"
	if value != "closed":
		map_only = false
	_changed()


func reveal_panel(key: String) -> void:
	set_panel_state(key, "open")
	if windows.has(key) and authorized.get(key, false):
		focus_panel(key)


func duplicate_workspace() -> void:
	var selected: Array[String] = []
	for key: String in model.workspaces[model.active].panels:
		if state(key).open:
			selected.append(key)
	var source: Dictionary = model.workspaces[model.active].panels.duplicate(true)
	if model.create_workspace(model.workspaces[model.active].name + " copy", selected).is_empty():
		return
	model.workspaces[model.active].panels = source
	model.save_active()
	workspace_changed.emit()
	_changed()


func delete_workspace() -> void:
	_layout_action(1)


func save_workspace() -> void:
	if not _ready_layout:
		return
	var id := model.active
	var had_baseline := model.saved_workspaces.has(id)
	var previous_baseline: Dictionary = model.saved_workspaces.get(id, {}).duplicate(true)
	model.save_active()
	var error := _save_preferences()
	if error != OK:
		if had_baseline:
			model.saved_workspaces[id] = previous_baseline
		else:
			model.saved_workspaces.erase(id)
	_report_preference_save(error)
	_refresh_command()


func revert_workspace() -> void:
	_cancel_gestures()
	model.revert_active()
	_changed()


func is_layout_dirty() -> bool:
	return model.is_active_dirty()


func _build_management_menu() -> void:
	var popup := _menu.get_popup()
	popup.clear()
	for key: String in windows:
		if not authorized.get(key, false):
			continue
		var index := windows.keys().find(key)
		popup.add_check_item(
			(
				"%s%s (F%d)"
				% [
					WorkspaceLayout.PANEL_NAMES[key],
					" · pinned" if state(key).pinned else "",
					index + 1
				]
			),
			100 + index
		)
		popup.set_item_checked(
			popup.item_count - 1, state(key).open and not state(key).minimized and not map_only
		)
	popup.add_separator()
	popup.add_item("New workspace…", 3)
	popup.add_item("Choose panels / rename…", 4)
	popup.add_item("Save layout", 5)
	popup.set_item_tooltip(popup.item_count - 1, _status.text)
	popup.add_item("Reset current layout…", 0)
	popup.add_item("Delete custom workspace…", 1)
	popup.set_item_disabled(popup.item_count - 1, model.workspaces.size() <= 1)
	popup.add_check_item("Show panel headers (Ctrl+Shift+H)", 2)
	popup.set_item_checked(popup.item_count - 1, model.show_panel_headers)
	popup.add_check_item("Map view · hide panels (Ctrl+\\)", 6)
	popup.set_item_checked(popup.item_count - 1, map_only)
	popup.add_separator("Workspaces")
	for id: String in model.workspaces:
		popup.add_radio_check_item(
			model.workspaces[id].name, 200 + model.workspaces.keys().find(id)
		)
		popup.set_item_checked(popup.item_count - 1, model.active == id)
	_menu.tooltip_text = (
		"View & layout · show panels or choose a personal view preset. Ctrl+P opens Panels; Ctrl+F edits this layout. "
		+ _status.text
	)


func _fit_navigation() -> void:
	if not is_instance_valid(_tabs) or not is_instance_valid(_menu):
		return
	for tab in _tabs.get_children():
		tab.show()
	for id: String in _tab_buttons:
		var title: String = model.workspaces[id].name
		_tab_buttons[id].text = title if title.length() <= 28 else title.left(27) + "…"
		_tab_buttons[id].custom_minimum_size.x = 0
		_tab_buttons[id].text_overrun_behavior = TextServer.OVERRUN_NO_TRIMMING
	var available := size.x - 84
	var needed := _tabs.get_combined_minimum_size().x
	if size.x < 1000 or needed > available:
		for id: String in _tab_buttons:
			_tab_buttons[id].get_parent().get_parent().visible = id == model.active
		var active_button: Button = _tab_buttons.get(model.active)
		if active_button != null:
			if size.x < 350 and model.active in ["daily", "build", "welfare"]:
				active_button.text = {"daily": "Daily", "build": "Build", "welfare": "Welfare"}[
					model.active
				]
			active_button.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
			active_button.custom_minimum_size.x = minf(200, maxf(80, available - 32))
			active_button.tooltip_text = (
				model.workspaces[model.active].name
				+ " · personal view preset; choose views in Panels"
			)


func _update_tab_alert(id: String) -> void:
	if not _tab_alert_nodes.has(id):
		return
	var nodes: Dictionary = _tab_alert_nodes[id]
	var present := _alert_summaries.has(id)
	nodes.glyph.visible = present
	nodes.count.visible = present
	if present:
		var summary: Dictionary = _alert_summaries[id]
		nodes.glyph.texture = ThemeTokens.glyph(summary.level)
		nodes.glyph.tooltip_text = "%s alerts" % summary.level.capitalize()
		nodes.count.text = str(summary.count)
		nodes.count.add_theme_color_override("font_color", ThemeTokens.color(summary.level))


func _build_dialog() -> void:
	_dialog = AcceptDialog.new()
	_dialog.title = "Workspace setup"
	_dialog.ok_button_text = "Apply"
	_dialog.min_size = Vector2i(metrics.px(300), 0)
	add_child(_dialog)
	var scroll := ScrollContainer.new()
	scroll.name = "WorkspaceChooserScroll"
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	scroll.follow_focus = true
	_dialog.add_child(scroll)
	var body := VBoxContainer.new()
	body.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(body)
	_name_input = LineEdit.new()
	_name_input.placeholder_text = "Workspace name"
	_name_input.max_length = 40
	_name_input.text_changed.connect(
		func(text: String) -> void: _dialog.get_ok_button().disabled = text.strip_edges().is_empty()
	)
	body.add_child(_name_input)
	_copy = CheckBox.new()
	_copy.text = "Copy current positions and sizes"
	_copy.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_copy.custom_minimum_size.x = 1
	_copy.button_pressed = true
	body.add_child(_copy)
	for key: String in WorkspaceLayout.PANEL_NAMES:
		var check := CheckBox.new()
		check.text = WorkspaceLayout.PANEL_NAMES[key]
		body.add_child(check)
		_checks[key] = check
	var note := Label.new()
	note.text = (
		"Panels overlay the full map; pin locks position and size only.\n"
		+ "Collapse keeps a tab; Ctrl+K opens commands.\n"
		+ "Drag unpinned headers to move and edges or corners to resize.\n"
		+ "Alt bypasses snapping. Escape restores starting geometry.\n"
		+ "Ctrl+Shift+H toggles headers. Changes save on this device."
	)
	note.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	ThemeTokens.apply_label(note, "small")
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
	_name_input.editable = true
	_copy.visible = create
	_sync_checks()
	_dialog.title = "New workspace" if create else "Choose panels"
	_dialog.get_ok_button().disabled = false
	var available := (size - Vector2.ONE * ThemeTokens.number("space-8")).max(Vector2.ONE)
	_dialog.min_size = Vector2i(minf(300, available.x), 0)
	_dialog.popup_centered(Vector2i(minf(380, available.x), minf(520, available.y)))
	_name_input.grab_focus()
	_name_input.select_all()


func _confirm_workspace() -> void:
	var selected: Array[String] = []
	for key: String in _checks:
		if (
			(_checks[key].button_pressed and authorized[key])
			or (not authorized[key] and state(key).open)
		):
			selected.append(key)
	if _dialog_new:
		if model.create_workspace(_name_input.text, selected, _copy.button_pressed).is_empty():
			return
	else:
		if _name_input.editable and not _name_input.text.strip_edges().is_empty():
			model.rename_active(_name_input.text)
		for key: String in windows:
			state(key).open = key in selected
	map_only = false
	workspace_changed.emit()
	_changed()


func _layout_action(id: int) -> void:
	if id >= 200:
		var index := id - 200
		if index < model.workspaces.size():
			switch_workspace(model.workspaces.keys()[index])
		return
	if id >= 100:
		var index := id - 100
		if index < windows.size() and authorized.get(windows.keys()[index], false):
			toggle_panel(windows.keys()[index])
		return
	match id:
		3:
			edit_workspace(true)
			return
		4:
			edit_workspace(false)
			return
		5:
			save_workspace()
			_build_management_menu()
			return
		6:
			toggle_map_only()
			return
	if id == 2:
		toggle_panel_headers()
		return
	if id == 1 and model.workspaces.size() <= 1:
		return
	var confirmation := ConfirmationDialog.new()
	_confirmation = confirmation
	confirmation.title = "Reset layout" if id == 0 else "Delete workspace"
	confirmation.dialog_text = (
		"Reset positions for this workspace?"
		if id == 0
		else "Delete '%s'? Colony state is not affected." % model.workspaces[model.active].name
	)
	add_child(confirmation)
	confirmation.confirmed.connect(
		func() -> void:
			_cancel_gestures()
			if id == 0:
				model.reset_active()
			else:
				model.remove_workspace(model.active)
			map_only = false
			workspace_changed.emit()
			_changed()
			confirmation.queue_free()
	)
	confirmation.canceled.connect(confirmation.queue_free)
	confirmation.popup_centered()


func _unhandled_key_input(event: InputEvent) -> void:
	if not event is InputEventKey or not event.pressed or event.echo:
		return
	if not _ready_layout:
		return
	if (
		_command_key_event_id == event.get_instance_id()
		and _command_key_frame == Engine.get_process_frames()
	):
		return
	if event.keycode == KEY_ESCAPE and is_command_open():
		close_command()
	elif event.ctrl_pressed and event.keycode in [KEY_K, KEY_P]:
		if is_command_open():
			close_command()
		else:
			open_command(true)
	elif event.ctrl_pressed and event.keycode == KEY_F:
		edit_workspace(false)
	elif event.ctrl_pressed and event.shift_pressed and event.keycode == KEY_H:
		toggle_panel_headers()
	elif event.ctrl_pressed and event.keycode == KEY_BACKSLASH:
		toggle_map_only()
	elif event.alt_pressed and event.keycode >= KEY_1 and event.keycode <= KEY_9:
		var index: int = event.keycode - KEY_1
		if index >= model.workspaces.size():
			return
		switch_workspace(model.workspaces.keys()[index])
	elif (
		not event.ctrl_pressed
		and not event.alt_pressed
		and not event.shift_pressed
		and not event.meta_pressed
	):
		var focus := get_viewport().gui_get_focus_owner()
		if focus is LineEdit or focus is TextEdit:
			return
		var shortcuts := {
			KEY_R: "resources",
			KEY_P: "policies",
			KEY_B: "construction",
			KEY_I: "inspector",
			KEY_A: "alerts",
			KEY_Z: "operations",
			KEY_F8: "performance"
		}
		var original := [
			"overview",
			"people",
			"inspector",
			"operations",
			"policies",
			"alerts",
			"activity",
			"trends",
			"admin",
			"developer",
			"construction"
		]
		var key: String = shortcuts.get(event.keycode, "")
		if key.is_empty() and event.keycode >= KEY_F1 and event.keycode <= KEY_F11:
			key = original[event.keycode - KEY_F1]
		if key.is_empty() or not windows.has(key):
			return
		toggle_panel(key)
	else:
		return
	get_viewport().set_input_as_handled()
