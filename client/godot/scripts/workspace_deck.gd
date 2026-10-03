## A map-first desktop. Only the frames intercept input; empty deck space is map.
class_name WorkspaceDeck
extends Control

signal workspace_changed
signal header_layout_changed

var model := WorkspaceLayout.new()
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


func setup(map_control: Control, save_path := WorkspaceLayout.SAVE_PATH, ui_metrics := UiMetrics.new()) -> void:
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
	var utility_surface := DeckTheme.box(ThemeTokens.color("bg-100"), ThemeTokens.color("line-100"), 8)
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
	utility_row.add_child(diagnostics_host)
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
	area.resized.connect(_fit_navigation)
	resized.connect(_fit_header)
	_fit_header.call_deferred()
	_panel_nav = HBoxContainer.new()
	add_child(_panel_nav)
	_panel_nav.hide()
	_build_dialog()

func apply_metrics(ui_metrics: UiMetrics) -> void:
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


func _resize_diagnostics_host() -> void:
	if not is_instance_valid(diagnostics_host):
		return
	diagnostics_host.custom_minimum_size = Vector2(
		((360 if _diagnostics_graph else 224) if size.x >= 1280 else (112 if size.x >= 900 else 0)) if diagnostics_host.visible else 0,
		0)


func status_width() -> float:
	return maxf(1, _status_viewport.size.x)

func _fit_header() -> void:
	if not is_instance_valid(_utilities): return
	var stacked := size.x < 550
	var parent: Container = _header_rows if stacked else _telemetry_header
	if _utilities.get_parent() != parent:
		_utilities.reparent(parent)
		if stacked: _header_rows.move_child(_utilities, 0)
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
	window.scroll.resized.connect(_queue_body_focus_reveal)
	windows[key] = window
	authorized[key] = true
	window.focused.connect(focus_panel.bind(key))
	window.interaction_started.connect(func() -> void:
		_drag_origins[key] = state(key).duplicate(true)
		var remembered := _floating_rect(key)
		remembered.position = remembered.position.round()
		remembered.size = remembered.size.round()
		if window.position.distance_to(remembered.position) > 0.01 or window.size.distance_to(remembered.size) > 0.01:
			_drag_origins[key].rect = _remembered_geometry(key))
	window.headers_requested.connect(func() -> void:
		if not model.show_panel_headers:
			toggle_panel_headers())
	window.interaction_cancelled.connect(func() -> void:
		if _drag_origins.has(key):
			model.workspaces[model.active].panels[key] = _drag_origins[key]
			_drag_origins.erase(key)
			_apply_layout()
		else:
			if not compact:
				state(key).rect = _remembered_geometry(key)
		save_layout())
	window.geometry_requested.connect(func(rect: Rect2, resizing: bool, unsnapped: bool) -> void:
		var others: Array[Rect2] = []
		for other: WorkspaceWindow in windows.values():
			if other != window and other.is_visible_in_tree():
				var visible_rect := _visible_control_rect(other)
				if visible_rect.has_area():
					others.append(Rect2(area.get_global_transform().affine_inverse() * visible_rect.position, visible_rect.size))
		var snapped: Rect2
		var minimum := Vector2(WorkspaceLayout.minimum_size(metrics).x, window.chrome_height()) if window.collapsed else Vector2.ZERO
		if unsnapped:
			snapped = WorkspaceLayout.clamp_resize_rect(rect, area.size, window._resize_edges, metrics) if resizing else WorkspaceLayout.clamp_rect(rect, area.size, metrics, minimum)
		else:
			snapped = WorkspaceLayout.snap_rect(rect, area.size, others, resizing, metrics, window._resize_edges, minimum)
		snapped.position = snapped.position.round()
		snapped.size = snapped.size.round()
		window.position = snapped.position
		window.size = snapped.size)
	window.interaction_finished.connect(func() -> void:
		_drag_origins.erase(key)
		if not compact:
			state(key).rect = _remembered_geometry(key)
		save_layout())
	window.minimize_requested.connect(toggle_panel.bind(key))
	window.close_requested.connect(func() -> void:
		state(key).open = false
		_changed())
	window.pin_requested.connect(func() -> void:
		state(key).pinned = not state(key).pinned
		_changed())
	return window.content


## Collapsed gestures persist position only; the body dimensions remain intact.
## Copy normalized dimensions verbatim to avoid rounding drift over collapse cycles.
func _remembered_geometry(key: String) -> Array:
	var window: WorkspaceWindow = windows[key]
	var rect := WorkspaceLayout.to_normalized(Rect2(window.position, window.size), area.size)
	if window.collapsed:
		rect[2] = state(key).rect[2]
		rect[3] = state(key).rect[3]
	return rect


## Saved dimensions describe the body; collapsed bounds describe only the header.
## Read the saved anchor before expanded clamping, including after viewport changes.
func _floating_rect(key: String) -> Rect2:
	var saved := state(key)
	var rect := WorkspaceLayout.to_pixels(saved.rect, area.size, metrics)
	if saved.minimized:
		var minimum := Vector2(WorkspaceLayout.minimum_size(metrics).x, windows[key].chrome_height())
		rect.position = Vector2(saved.rect[0], saved.rect[1]) * area.size
		rect.size.y = minimum.y
		rect = WorkspaceLayout.clamp_rect(rect, area.size, metrics, minimum)
	return rect

## Alert ownership and aggregation belong to integration, not local preferences.
func set_workspace_alert_summary(id: String, level: String, count: int) -> void:
	if not model.workspaces.has(id):
		return
	var summary := {"level": level, "count": count} if count > 0 and level in ["warn", "critical"] else {}
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
	_status.tooltip_text = "Saved layout could not be read; defaults loaded (%s)." % model.last_load_status if model.last_load_status != "loaded" else ""


func state(key: String) -> Dictionary:
	return model.workspaces[model.active].panels[key]


func blocks_map_input(point: Vector2) -> bool:
	if _dialog.visible or _menu.get_popup().visible or (is_instance_valid(_confirmation) and _confirmation.visible) or not _map.get_global_rect().has_point(point):
		return true
	for window: WorkspaceWindow in windows.values():
		if window.visible and (not window._gesture.is_empty() or window.get_global_rect().has_point(point)):
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
	if _compact_panel == key and windows[key].get_parent() == area and area.get_child(-1) == windows[key]:
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
	if not _ready_layout or not event is InputEventMouseButton or not event.pressed or event.button_index != MOUSE_BUTTON_LEFT:
		return
	var order: Array = windows.keys()
	order.sort_custom(func(a: String, b: String) -> bool:
		var a_float: bool = windows[a].get_parent() == area
		var b_float: bool = windows[b].get_parent() == area
		return int(state(a).z) > int(state(b).z) if a_float == b_float else a_float)
	for key: String in order:
		var child: WorkspaceWindow = windows[key]
		if child.is_visible_in_tree() and _visible_control_rect(child).has_point(event.position):
			focus_panel(child.name)
			if event.alt_pressed and not child.header_visible and not child.pinned and not child.compact:
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
	if map_only or not state(key).open or state(key).minimized or (compact and _compact_panel != key):
		if state(key).minimized and not compact:
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


func save_layout() -> void:
	if not _ready_layout:
		return
	var error := model.save_to(_save_path)
	_status.text = "Layout saved" if error == OK else "Layout save failed"
	_status.tooltip_text = "" if error == OK else "Could not save local layout: %s" % error_string(error)


func _apply_layout() -> void:
	if not _ready_layout or area.size.x <= 0 or area.size.y <= 0:
		return
	var was_compact := compact
	compact = area.size.x < 640 or area.size.y < 400
	if compact != was_compact:
		_cancel_gestures()
	var order: Array = windows.keys()
	order.sort_custom(func(a: String, b: String) -> bool: return int(state(a).z) < int(state(b).z))
	if compact and (_compact_panel.is_empty() or not authorized.get(_compact_panel, false) or not state(_compact_panel).open):
		_compact_panel = ""
		for key: String in order:
			if authorized[key] and state(key).open and not state(key).minimized:
				_compact_panel = key
		if _compact_panel.is_empty():
			for key: String in order:
				if authorized[key] and state(key).open:
					_compact_panel = key
	for key: String in order:
		var window: WorkspaceWindow = windows[key]
		var saved := state(key)
		window.visible = authorized[key] and saved.open and not map_only and (not compact or key == _compact_panel)
		window.apply_state(saved.pinned, compact)
		window.set_collapsed(saved.minimized)
		window.set_header_visible(model.show_panel_headers or saved.minimized)
		var rect := Rect2(Vector2.ZERO, area.size) if compact else _floating_rect(key)
		if saved.minimized:
			rect.size.y = window.chrome_height()
		if not compact:
			rect.position = rect.position.round()
			rect.size = rect.size.round()
		window.position = rect.position
		window.size = rect.size
		if window.get_parent() == area:
			area.move_child(window, -1)
		window.set_focused(key == _compact_panel)
	_map.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_map.queue_redraw()
	_queue_body_focus_reveal()


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
	_body_focus_reveal_callback = _reveal_retained_body_focus.bind(control_ref, settling_frames, epoch)
	get_tree().process_frame.connect(_body_focus_reveal_callback, CONNECT_ONE_SHOT)


## Leaving the tree invalidates callbacks even if this same deck is later reattached.
func _exit_tree() -> void:
	if _body_focus_reveal_callback.is_valid() and get_tree().process_frame.is_connected(_body_focus_reveal_callback):
		get_tree().process_frame.disconnect(_body_focus_reveal_callback)
	_body_focus_reveal_callback = Callable()
	_body_focus_reveal_epoch += 1
	_body_focus_reveal_pending = false


func _reveal_retained_body_focus(control_ref: WeakRef, settling_frames: int, epoch: int) -> void:
	if epoch != _body_focus_reveal_epoch:
		return
	_body_focus_reveal_callback = Callable()
	var control := control_ref.get_ref() as Control
	if not is_inside_tree() or not is_instance_valid(control) or not control.is_visible_in_tree() or get_viewport().gui_get_focus_owner() != control:
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
		if not authorized.get(key, false) or not window.is_visible_in_tree() or not window.scroll.is_ancestor_of(control):
			continue
		var parent := control.get_parent()
		while parent != window and parent != null:
			if parent is ScrollContainer and not parent.get_global_rect().encloses(control.get_global_rect()):
				parent.ensure_control_visible(control)
			parent = parent.get_parent()
		return


func _rebuild_navigation() -> void:
	var focused := get_viewport().gui_get_focus_owner()
	var workspace_focus := str(focused.get_meta("workspace_id", "")) if focused != null else ""
	var panel_focus := str(focused.get_meta("panel_id", "")) if focused != null else ""
	_tab_buttons.clear()
	_tab_alert_nodes.clear()
	_panel_buttons.clear()
	for parent: HBoxContainer in [_tabs, _panel_nav]:
		for child: Node in parent.get_children():
			parent.remove_child(child)
			child.queue_free()
	for id: String in model.workspaces:
		var tab := VBoxContainer.new()
		tab.add_theme_constant_override("separation", 0)
		_tabs.add_child(tab)
		var row := HBoxContainer.new()
		tab.add_child(row)
		var name: String = model.workspaces[id].name
		var button := _button(row, name if name.length() <= 28 else name.left(27) + "…", name + " · personal view preset; colony state is unchanged", switch_workspace.bind(id))
		button.custom_minimum_size.y = 32
		button.set_meta("workspace_id", id)
		_tab_buttons[id] = button
		button.add_theme_color_override("font_color", ThemeTokens.color("ink" if model.active == id else "ink-muted"))
		var glyph := TextureRect.new()
		glyph.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		glyph.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		glyph.custom_minimum_size = Vector2(16, 16)
		row.add_child(glyph)
		var count := Label.new()
		ThemeTokens.apply_label(count, "readout")
		row.add_child(count)
		_tab_alert_nodes[id] = {"glyph": glyph, "count": count}
		_update_tab_alert(id)
		var underline := ColorRect.new()
		underline.custom_minimum_size.y = 2
		underline.color = ThemeTokens.color("accent") if model.active == id else Color.TRANSPARENT
		tab.add_child(underline)
	_build_management_menu()
	_fit_navigation.call_deferred()
	if _tab_buttons.has(workspace_focus):
		_tab_buttons[workspace_focus].grab_focus()
	elif _panel_buttons.has(panel_focus):
		_panel_buttons[panel_focus].grab_focus()

func _build_management_menu() -> void:
	var popup := _menu.get_popup()
	popup.clear()
	for key: String in windows:
		if not authorized.get(key, false): continue
		var index := windows.keys().find(key)
		popup.add_check_item("%s%s (F%d)" % [WorkspaceLayout.PANEL_NAMES[key], " · pinned" if state(key).pinned else "", index + 1], 100 + index)
		popup.set_item_checked(popup.item_count - 1, state(key).open and not state(key).minimized and not map_only)
	popup.add_separator()
	popup.add_item("New workspace…", 3)
	popup.add_item("Choose panels / rename…", 4)
	popup.add_item("Save layout", 5)
	popup.set_item_tooltip(popup.item_count - 1, _status.text)
	popup.add_item("Reset current layout…", 0)
	popup.add_item("Delete custom workspace…", 1)
	popup.set_item_disabled(popup.item_count - 1, WorkspaceLayout.defaults().has(model.active))
	popup.add_check_item("Show panel headers (Ctrl+Shift+H)", 2)
	popup.set_item_checked(popup.item_count - 1, model.show_panel_headers)
	popup.add_check_item("Map view · hide panels (Ctrl+\\)", 6)
	popup.set_item_checked(popup.item_count - 1, map_only)
	popup.add_separator("Workspaces")
	for id: String in model.workspaces:
		popup.add_radio_check_item(model.workspaces[id].name, 200 + model.workspaces.keys().find(id))
		popup.set_item_checked(popup.item_count - 1, model.active == id)
	_menu.tooltip_text = "View & layout · show panels or choose a personal view preset. Ctrl+P opens Panels; Ctrl+F edits this layout. " + _status.text

func _fit_navigation() -> void:
	if not is_instance_valid(_tabs) or not is_instance_valid(_menu): return
	for tab in _tabs.get_children(): tab.show()
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
				active_button.text = {"daily": "Daily", "build": "Build", "welfare": "Welfare"}[model.active]
			active_button.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
			active_button.custom_minimum_size.x = minf(200, maxf(80, available - 32))
			active_button.tooltip_text = model.workspaces[model.active].name + " · personal view preset; choose views in Panels"

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
	_name_input.text_changed.connect(func(text: String) -> void:
		_dialog.get_ok_button().disabled = text.strip_edges().is_empty())
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
	note.text = "Panels overlay the full map; pin locks position and size only.\nCollapse keeps the header; F1–F11 restores panels. Map gives immediate map access.\nDrag unpinned headers to move and edges or corners to resize.\nAlt bypasses snapping. Escape cancels and restores starting geometry.\nHidden headers keep a drag strip with Headers access. Layout / Ctrl+Shift+H toggles headers. Changes save on this device."
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
	_name_input.editable = create or not WorkspaceLayout.defaults().has(model.active)
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
	if id >= 200:
		var index := id - 200
		if index < model.workspaces.size(): switch_workspace(model.workspaces.keys()[index])
		return
	if id >= 100:
		var index := id - 100
		if index < windows.size() and authorized.get(windows.keys()[index], false): toggle_panel(windows.keys()[index])
		return
	match id:
		3: edit_workspace(true); return
		4: edit_workspace(false); return
		5: save_layout(); _build_management_menu(); return
		6: toggle_map_only(); return
	if id == 2:
		toggle_panel_headers()
		return
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
	if event.ctrl_pressed and event.keycode == KEY_P:
		_menu.grab_focus()
		_menu.show_popup()
	elif event.ctrl_pressed and event.keycode == KEY_F:
		edit_workspace(false)
	elif event.ctrl_pressed and event.shift_pressed and event.keycode == KEY_H:
		toggle_panel_headers()
	elif event.ctrl_pressed and event.keycode == KEY_BACKSLASH:
		toggle_map_only()
	elif event.keycode >= KEY_F1 and event.keycode <= KEY_F11:
		var index: int = event.keycode - KEY_F1
		if index >= windows.size():
			return
		toggle_panel(windows.keys()[index])
	else:
		return
	get_viewport().set_input_as_handled()
