## One reusable frame. Scrollable contents do not impose a minimum window width.
class_name WorkspaceWindow
extends Panel

signal focused
signal geometry_requested(rect: Rect2, resizing: bool, unsnapped: bool)
signal interaction_finished
signal minimize_requested
signal close_requested
signal pin_requested
signal interaction_cancelled
signal interaction_started
signal headers_requested

const Icons = preload("res://ui/theme/icons.gd")
const TITLE_FONT = preload("res://ui/theme/fonts/IBMPlexSans-Medium.woff2")
const TAB_HEIGHT := 26.0
const MICRO_HEIGHT := 30.0
const BODY_TOP := 25.0
const PANEL_ICONS := {
	"Resources": "box",
	"Colony overview": "overview",
	"Colonist roster": "users",
	"Tile inspector": "locate",
	"Zones": "zones",
	"Colony policies": "settings",
	"Alerts": "alert",
	"Activity feed": "activity",
	"Session trends": "chart",
	"Admin": "settings",
	"Developer": "code",
	"Construction": "hammer",
}
const RESIZE_DIRECTIONS := {
	"left": Vector2i(-1, 0),
	"right": Vector2i(1, 0),
	"top": Vector2i(0, -1),
	"bottom": Vector2i(0, 1),
	"top_left": Vector2i(-1, -1),
	"top_right": Vector2i(1, -1),
	"bottom_left": Vector2i(-1, 1),
	"bottom_right": Vector2i(1, 1),
}

var content: VBoxContainer
var titlebar: HBoxContainer
var pin_button: Button
var collapse_button: Button
var close_button: Button
var grip: Control
var resize_handles: Dictionary = {}
var divider: ColorRect
var scroll: ScrollContainer
var pinned := false
var collapsed := false
var live_count: Label
var header_ground: Panel
var compact := false
var header_visible := true
var micro_mode := false
var micro_content: HBoxContainer
var body_padding := 10.0
var metrics := UiMetrics.new()
var drag_strip: HBoxContainer
var _gesture := ""
var _resize_edges := Vector2i.ZERO
var _start_pointer := Vector2.ZERO
var _start_rect := Rect2()
var _focused := false
var _scroll_padding: MarginContainer
var _body_ground: Panel
var _control_ground: Panel
var _controls: HBoxContainer
var _pin_mark: TextureRect
var _body_style: StyleBoxFlat
var _tab_style: StyleBoxFlat
var _shadow_style: StyleBoxFlat
var _focus_style: StyleBoxFlat
var _hovered := false
var _focus_within := false
var _size_notification_queued := false
var _reported_chrome_size := Vector2.ZERO


func setup(title: String) -> void:
	mouse_filter = Control.MOUSE_FILTER_STOP
	# Only the body scroll clips; the transparent frame allows the tab's natural width.
	clip_contents = false
	add_theme_stylebox_override("panel", StyleBoxEmpty.new())
	_build_surfaces()
	_build_title(title)
	_build_controls()
	_build_drag_strip()
	_build_body()
	_build_resize_handles()
	resized.connect(refresh_metrics)
	gui_input.connect(_frame_input)
	set_process_input(false)
	apply_state(pinned, compact)
	_focus_changed(get_viewport().gui_get_focus_owner())
	refresh_metrics()


func _surface() -> StyleBoxFlat:
	var style := DeckTheme.box(ThemeTokens.color("bg-100"), ThemeTokens.color("line-100"), 0)
	style.set_corner_radius_all(5)
	return style


func _ground(style: StyleBoxFlat) -> Panel:
	var panel := Panel.new()
	panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	panel.add_theme_stylebox_override("panel", style)
	add_child(panel)
	return panel


func _build_surfaces() -> void:
	_body_style = _surface()
	_body_style.corner_radius_top_left = 0
	_body_ground = _ground(_body_style)
	_tab_style = _surface()
	header_ground = _ground(_tab_style)
	var controls_style := _surface()
	controls_style.corner_radius_bottom_left = 0
	controls_style.corner_radius_bottom_right = 0
	controls_style.border_width_bottom = 0
	_control_ground = _ground(controls_style)
	_shadow_style = _surface()
	_shadow_style.draw_center = false
	_shadow_style.set_border_width_all(0)
	_shadow_style.shadow_color = Color(0, 0, 0, 0.42)
	_shadow_style.shadow_size = 14
	_shadow_style.shadow_offset = Vector2(0, 8)
	_focus_style = _surface()
	_focus_style.draw_center = false
	_focus_style.border_color = ThemeTokens.color("accent")
	_focus_style.set_border_width_all(2)
	# Compatibility field: Atlas has no full-width header divider.
	divider = ColorRect.new()
	divider.mouse_filter = Control.MOUSE_FILTER_IGNORE
	divider.hide()
	add_child(divider)


func _drag_row(gap: int) -> HBoxContainer:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", gap)
	row.mouse_filter = Control.MOUSE_FILTER_STOP
	row.focus_mode = Control.FOCUS_ALL
	row.gui_input.connect(_header_input.bind(row))
	row.minimum_size_changed.connect(refresh_metrics)
	add_child(row)
	return row


func _build_title(title: String) -> void:
	titlebar = _drag_row(7)
	var icon_name: String = PANEL_ICONS.get(title, "menu")
	titlebar.add_child(_icon(icon_name if icon_name in Icons.NAMES else "menu"))
	var title_label := Label.new()
	title_label.text = title
	title_label.add_theme_font_override("font", TITLE_FONT)
	title_label.add_theme_font_size_override("font_size", 12)
	title_label.add_theme_color_override("font_color", ThemeTokens.color("ink"))
	title_label.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	title_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	titlebar.add_child(title_label)
	live_count = Label.new()
	live_count.add_theme_font_override("font", ThemeTokens.font("log"))
	live_count.add_theme_font_size_override("font_size", 11)
	live_count.add_theme_color_override("font_color", ThemeTokens.color("ink"))
	var chip := DeckTheme.box(ThemeTokens.color("bg-300"), ThemeTokens.color("bg-300"), 0)
	chip.set_border_width_all(0)
	chip.set_corner_radius_all(3)
	chip.content_margin_left = 5
	chip.content_margin_right = 5
	live_count.add_theme_stylebox_override("normal", chip)
	live_count.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	live_count.mouse_filter = Control.MOUSE_FILTER_IGNORE
	live_count.visible = false
	titlebar.add_child(live_count)
	_pin_mark = _icon("pin")
	add_child(_pin_mark)
	micro_content = _drag_row(9)
	micro_content.child_entered_tree.connect(
		func(_child: Node) -> void: _sync_micro_children.call_deferred()
	)


func _icon(icon_name: String) -> TextureRect:
	var icon := TextureRect.new()
	icon.texture = Icons.texture(icon_name)
	icon.custom_minimum_size = Vector2(14, 14)
	icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	icon.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	icon.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return icon


func _build_controls() -> void:
	_controls = HBoxContainer.new()
	_controls.add_theme_constant_override("separation", 1)
	_controls.mouse_filter = Control.MOUSE_FILTER_PASS
	_controls.minimum_size_changed.connect(refresh_metrics)
	add_child(_controls)
	pin_button = _action("pin", "Pin position and size", func() -> void: pin_requested.emit())
	pin_button.toggle_mode = true
	collapse_button = _action(
		"chevron-up", "Collapse to tab / restore", func() -> void: minimize_requested.emit()
	)
	close_button = _action(
		"close",
		"Remove panel from workspace (reopen with Panels)",
		func() -> void: close_requested.emit()
	)


func _build_drag_strip() -> void:
	drag_strip = _drag_row(7)
	var strip_label := Label.new()
	strip_label.text = "Drag panel"
	ThemeTokens.apply_label(strip_label, "small")
	strip_label.add_theme_font_size_override("font_size", 11)
	strip_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	drag_strip.add_child(strip_label)
	var restore := Button.new()
	restore.text = "Headers"
	restore.theme_type_variation = "ButtonQuiet"
	restore.add_theme_font_size_override("font_size", 11)
	for state: String in ["normal", "hover", "pressed", "disabled"]:
		restore.add_theme_stylebox_override(state, StyleBoxEmpty.new())
	restore.custom_minimum_size.y = 22
	restore.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	restore.tooltip_text = "Show panel headers (Layout / Ctrl+Shift+H)"
	restore.pressed.connect(func() -> void: headers_requested.emit())
	drag_strip.add_child(restore)


func _build_body() -> void:
	scroll = ScrollContainer.new()
	scroll.follow_focus = true
	scroll.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	add_child(scroll)
	_scroll_padding = MarginContainer.new()
	_scroll_padding.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_scroll_padding.size_flags_vertical = Control.SIZE_EXPAND_FILL
	for side: String in ["left", "top", "right", "bottom"]:
		_scroll_padding.add_theme_constant_override("margin_" + side, 0)
	scroll.add_child(_scroll_padding)
	content = VBoxContainer.new()
	content.add_theme_constant_override("separation", 8)
	content.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	content.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_scroll_padding.add_child(content)
	scroll.get_v_scroll_bar().visibility_changed.connect(_refresh_scroll_padding)


func _build_resize_handles() -> void:
	for key: String in RESIZE_DIRECTIONS:
		var edges: Vector2i = RESIZE_DIRECTIONS[key]
		var handle := Control.new()
		handle.name = "Resize_" + key
		handle.mouse_filter = Control.MOUSE_FILTER_STOP
		handle.mouse_default_cursor_shape = (
			Control.CURSOR_HSIZE
			if edges.y == 0
			else (
				Control.CURSOR_VSIZE
				if edges.x == 0
				else (Control.CURSOR_FDIAGSIZE if edges.x == edges.y else Control.CURSOR_BDIAGSIZE)
			)
		)
		handle.tooltip_text = "Drag to resize. Hold Alt to bypass snapping."
		handle.gui_input.connect(_resize_input.bind(handle, edges))
		add_child(handle)
		resize_handles[key] = handle
	grip = resize_handles.bottom_right
	grip.draw.connect(_draw_grip)


func _action(icon: String, hint: String, callback: Callable) -> Button:
	var button := Button.new()
	button.set_meta("atlas_icon", icon)
	button.icon = Icons.texture(icon)
	button.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	button.mouse_entered.connect(_update_action_icon.bind(button, true))
	button.mouse_exited.connect(_update_action_icon.bind(button, false))
	button.theme_type_variation = "ButtonIcon"
	button.expand_icon = true
	button.add_theme_constant_override("icon_max_width", 14)
	button.custom_minimum_size = Vector2(22, 22)
	button.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	var hover := _surface()
	hover.bg_color = ThemeTokens.color("bg-300")
	hover.set_corner_radius_all(3)
	hover.set_border_width_all(0)
	for state: String in ["normal", "disabled", "pressed"]:
		button.add_theme_stylebox_override(state, StyleBoxEmpty.new())
	button.add_theme_stylebox_override("hover", hover)
	button.add_theme_stylebox_override("hover_pressed", hover)
	var ring := hover.duplicate() as StyleBoxFlat
	ring.draw_center = false
	ring.border_color = ThemeTokens.color("accent")
	ring.set_border_width_all(1)
	button.add_theme_stylebox_override("focus", ring)
	button.tooltip_text = hint
	button.pressed.connect(callback)
	_controls.add_child(button)
	return button


func _update_action_icon(button: Button, hovering: bool) -> void:
	var icon: String = button.get_meta("atlas_icon")
	if button == pin_button:
		icon = "pin-off" if pinned else "pin"
	elif button == collapse_button:
		icon = (
			("chevron-right" if collapsed else "chevron-left")
			if micro_mode
			else ("chevron-down" if collapsed else "chevron-up")
		)
	button.icon = Icons.texture(icon, "ink" if hovering or button.button_pressed else "ink-muted")


func set_focused(value: bool) -> void:
	_focused = value
	queue_redraw()


## Integration supplies a real count; chrome never guesses backend ownership.
func set_live_count(count: int = -1) -> void:
	live_count.visible = count >= 0
	live_count.text = str(maxi(0, count))
	refresh_metrics()


func set_collapsed(is_collapsed: bool) -> void:
	if is_collapsed and _gesture == "resize":
		cancel_interaction()
	var owner := get_viewport().gui_get_focus_owner() if is_inside_tree() else null
	var hiding_focus := is_collapsed and owner != null and scroll.is_ancestor_of(owner)
	collapsed = is_collapsed
	_sync_micro_children()
	apply_state(pinned, compact)
	if hiding_focus:
		_active_header().grab_focus()


## Content-owned width; the deck retains micro position and remembered geometry.
func set_micro_mode(enabled: bool = true) -> void:
	var owner := get_viewport().gui_get_focus_owner() if is_inside_tree() else null
	var transfer_focus := (
		owner != null
		and is_instance_valid(titlebar)
		and (owner == _active_header() or (enabled and scroll.is_ancestor_of(owner)))
	)
	if enabled and _gesture == "resize":
		cancel_interaction()
	micro_mode = enabled
	if not is_instance_valid(micro_content):
		return
	_sync_micro_children()
	apply_state(pinned, compact)
	if transfer_focus:
		_active_header().grab_focus()


func _sync_micro_children() -> void:
	for child: Node in micro_content.get_children():
		if not child is Control or not child.get_meta("expanded_only", false):
			continue
		if micro_mode and collapsed:
			if not child.has_meta("atlas_expanded_visible"):
				child.set_meta("atlas_expanded_visible", child.visible)
			var owner := get_viewport().gui_get_focus_owner()
			if owner == child or (owner != null and child.is_ancestor_of(owner)):
				micro_content.grab_focus()
			child.hide()
		elif child.has_meta("atlas_expanded_visible"):
			child.visible = child.get_meta("atlas_expanded_visible")
			child.remove_meta("atlas_expanded_visible")
	refresh_metrics()


func _active_header() -> HBoxContainer:
	return micro_content if micro_mode else titlebar if header_visible else drag_strip


func _header_content_width() -> float:
	return _active_header().get_combined_minimum_size().x + (21.0 if pinned else 0.0)


## Natural painted width, including inline controls only while revealed.
func tab_width() -> float:
	if not is_instance_valid(_controls):
		return 0.0
	var padding := 22.0 if micro_mode else 20.0
	var inline_width := 0.0
	if (collapsed or micro_mode) and _controls.visible:
		inline_width = _controls.get_combined_minimum_size().x + 2.0
	return ceilf(_header_content_width() + padding + inline_width)


func micro_size() -> Vector2:
	return Vector2(tab_width(), MICRO_HEIGHT)


func refresh_metrics() -> void:
	if not is_instance_valid(scroll) or not is_instance_valid(grip):
		return
	var only := collapsed or micro_mode
	var reveal := (_hovered or _focus_within) and (header_visible or micro_mode)
	_controls.visible = reveal
	_control_ground.visible = reveal and not only
	_body_ground.visible = not only
	scroll.visible = not only
	titlebar.visible = not micro_mode and header_visible
	drag_strip.visible = not micro_mode and not header_visible
	micro_content.visible = micro_mode
	_pin_mark.visible = pinned
	var row := _active_header()
	var inset := 11.0 if micro_mode else 9.0
	row.position = Vector2(inset, 1)
	row.size = Vector2(row.get_combined_minimum_size().x, chrome_height() - 2)
	_pin_mark.position = Vector2(inset + row.size.x + 7, (chrome_height() - 14) / 2)
	_pin_mark.size = Vector2(14, 14)
	header_ground.position = Vector2.ZERO
	header_ground.size = Vector2(tab_width(), chrome_height())
	_layout_controls(only, inset)
	_body_ground.position = Vector2(0, BODY_TOP)
	_body_ground.size = Vector2(size.x, maxf(0, size.y - BODY_TOP))
	scroll.offset_left = body_padding + 1
	scroll.offset_right = -scroll.offset_left
	scroll.offset_top = BODY_TOP + body_padding + 1
	scroll.offset_bottom = -body_padding - 1
	_refresh_scroll_padding()
	_layout_resize_handles()
	_tab_style.bg_color = ThemeTokens.color("bg-200" if _hovered else "bg-100")
	_tab_style.border_width_bottom = 1 if only else 0
	_tab_style.corner_radius_bottom_left = 5 if only else 0
	_tab_style.corner_radius_bottom_right = 5 if only else 0
	_body_style.corner_radius_top_right = 0 if _control_ground.visible else 5
	queue_redraw()
	grip.queue_redraw()
	if not _size_notification_queued:
		_size_notification_queued = true
		_notify_chrome_size.call_deferred()


func _layout_controls(only: bool, inset: float) -> void:
	var width := _controls.get_combined_minimum_size().x
	var control_x := inset + _header_content_width() + 2 if only else size.x - width - 4
	_controls.position = Vector2(control_x, (chrome_height() - 22) / 2)
	_controls.size = Vector2(width, 22)
	_control_ground.position = Vector2(control_x - 4, 0)
	_control_ground.size = Vector2(width + 8, TAB_HEIGHT)


func _layout_resize_handles() -> void:
	var corner := 14.0
	var border := 4.0
	var body_size := Vector2(size.x, maxf(0, size.y - BODY_TOP))
	for key: String in resize_handles:
		var handle: Control = resize_handles[key]
		var edges: Vector2i = RESIZE_DIRECTIONS[key]
		handle.visible = not pinned and not compact and not collapsed and not micro_mode
		var start := Vector2(0, BODY_TOP)
		var extent := Vector2.ZERO
		for axis in 2:
			if edges[axis] == 0:
				start[axis] += corner
				extent[axis] = maxf(0, body_size[axis] - corner * 2)
			else:
				extent[axis] = border if edges.x == 0 or edges.y == 0 else corner
				if edges[axis] > 0:
					start[axis] += body_size[axis] - extent[axis]
		handle.position = start
		handle.size = extent


func _notify_chrome_size() -> void:
	_size_notification_queued = false
	var desired := Vector2(tab_width(), chrome_height())
	if desired != _reported_chrome_size:
		_reported_chrome_size = desired
		# Preferred chrome changes without imposing body content minimums.
		minimum_size_changed.emit()


func _refresh_scroll_padding() -> void:
	# ScrollContainer already reserves the bar's themed width, but no inner gap.
	# Keep that gap inside its content so hidden bars retain the full body width.
	var gutter := int(ThemeTokens.number("space-2")) if scroll.get_v_scroll_bar().visible else 0
	if _scroll_padding.get_theme_constant("margin_right") != gutter:
		_scroll_padding.add_theme_constant_override("margin_right", gutter)


func chrome_height() -> float:
	return MICRO_HEIGHT if micro_mode else TAB_HEIGHT


func set_header_visible(value: bool) -> void:
	var owner := get_viewport().gui_get_focus_owner() if is_inside_tree() else null
	var had_focus := (
		_active_header().has_focus()
		or (not value and not micro_mode and owner != null and _controls.is_ancestor_of(owner))
	)
	header_visible = value
	tooltip_text = (
		""
		if value
		else "Drag the strip to move. Headers restores controls; Layout / Ctrl+Shift+H toggles headers."
	)
	refresh_metrics()
	if had_focus:
		_active_header().grab_focus()


func apply_state(is_pinned: bool, is_compact: bool) -> void:
	pinned = is_pinned
	compact = is_compact
	pin_button.set_pressed_no_signal(pinned)
	_update_action_icon(pin_button, pin_button.is_hovered())
	_update_action_icon(collapse_button, collapse_button.is_hovered())
	collapse_button.tooltip_text = "Restore panel" if collapsed else "Collapse to tab"
	pin_button.tooltip_text = (
		"Unpin to move or resize; pin locks geometry only"
		if pinned
		else "Pin position and size only (does not restrict access)"
	)
	pin_button.visible = not compact
	titlebar.mouse_default_cursor_shape = (
		Control.CURSOR_ARROW if pinned or compact else Control.CURSOR_MOVE
	)
	drag_strip.mouse_default_cursor_shape = titlebar.mouse_default_cursor_shape
	micro_content.mouse_default_cursor_shape = titlebar.mouse_default_cursor_shape
	titlebar.tooltip_text = (
		"Unpin to move or resize (geometry only)"
		if pinned
		else "Drag to move. Drag edges to resize; Alt bypasses snapping. Escape cancels."
	)
	if collapsed and not pinned and not compact:
		titlebar.tooltip_text = "Drag to move. Restore to resize; Alt bypasses snapping. Escape cancels."
	drag_strip.tooltip_text = titlebar.tooltip_text + " Show controls with Headers or Ctrl+Shift+H."
	micro_content.tooltip_text = titlebar.tooltip_text
	if pinned or compact:
		cancel_interaction()
	refresh_metrics()


func _header_input(event: InputEvent, row: Control) -> void:
	if event.is_action_pressed("ui_accept") and not event.is_echo():
		minimize_requested.emit()
		accept_event()
	else:
		_begin(event, "move", row)


func _frame_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.pressed:
		if header_ground.get_rect().has_point(event.position):
			_begin(event, "move", self)
		else:
			focused.emit()


func _enter_tree() -> void:
	get_viewport().gui_focus_changed.connect(_focus_changed)


func _exit_tree() -> void:
	get_viewport().gui_focus_changed.disconnect(_focus_changed)


func _focus_changed(control: Control) -> void:
	_focus_within = control != null and (control == self or is_ancestor_of(control))
	refresh_metrics()


func _process(_delta: float) -> void:
	if not is_instance_valid(_controls):
		return
	# Actual GUI target respects sibling occlusion, unlike rectangle polling.
	var target := get_viewport().gui_get_hovered_control()
	var hovering := is_visible_in_tree() and target != null
	hovering = hovering and (target == self or is_ancestor_of(target))
	# gui_focus_changed announces acquired focus, but release_focus need not emit it.
	var owner := get_viewport().gui_get_focus_owner()
	var within := owner != null and (owner == self or is_ancestor_of(owner))
	if hovering != _hovered or within != _focus_within:
		_hovered = hovering
		_focus_within = within
		refresh_metrics()


func _draw() -> void:
	if not is_instance_valid(header_ground):
		return
	var only := collapsed or micro_mode
	var tab_rect := header_ground.get_rect()
	if not only:
		draw_style_box(_shadow_style, _body_ground.get_rect())
	draw_style_box(_shadow_style, tab_rect)
	if _focused or _focus_within:
		var rect := tab_rect if only else _body_ground.get_rect()
		draw_style_box(_focus_style, rect.grow(3))


func _draw_grip() -> void:
	if not _hovered:
		return
	var color := ThemeTokens.color("ink-subtle")
	grip.draw_line(Vector2(4, 12), Vector2(12, 4), color, 1)
	grip.draw_line(Vector2(8, 12), Vector2(12, 8), color, 1)


func _has_point(point: Vector2) -> bool:
	if not is_instance_valid(header_ground):
		return false
	return (
		header_ground.get_rect().has_point(point)
		or (_control_ground.visible and _control_ground.get_rect().has_point(point))
		or (_body_ground.visible and _body_ground.get_rect().has_point(point))
	)


## Canvas-global input hit test, excluding shadows and the gap between the tabs.
func contains_global_point(point: Vector2) -> bool:
	return (
		is_visible_in_tree()
		and get_visible_global_rect().has_point(point)
		and _has_point(get_global_transform_with_canvas().affine_inverse() * point)
	)


## Tight painted canvas-global bounds, clipped by deck ancestors.
## Expanded bounds include the tab gap; contains_global_point excludes it for input.
func get_visible_global_rect() -> Rect2:
	if not is_visible_in_tree() or not is_instance_valid(header_ground):
		return Rect2()
	var rect := header_ground.get_rect()
	if _body_ground.visible:
		rect = rect.merge(_body_ground.get_rect())
	if _control_ground.visible:
		rect = rect.merge(_control_ground.get_rect())
	rect = get_global_transform_with_canvas() * rect
	var ancestor := get_parent()
	while ancestor != null:
		if ancestor is Control and ancestor.clip_contents:
			var clip: Rect2 = (
				ancestor.get_global_transform_with_canvas() * Rect2(Vector2.ZERO, ancestor.size)
			)
			rect = rect.intersection(clip)
		ancestor = ancestor.get_parent()
	return rect


func get_visible_rect() -> Rect2:
	return get_visible_global_rect()


func _resize_input(event: InputEvent, handle: Control, edges: Vector2i) -> void:
	_begin(event, "resize", handle, edges)


func _begin(event: InputEvent, gesture: String, handle: Control, edges := Vector2i.ZERO) -> void:
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT and event.pressed:
		focused.emit()
		if not pinned and not compact and (gesture == "move" or (not collapsed and not micro_mode)):
			_start_gesture(
				gesture, handle.get_global_transform_with_canvas() * event.position, edges
			)
		accept_event()


## Alternate deck drag entry point shares the header's position-only collapse policy.
func begin_move_from_global(pointer: Vector2) -> void:
	if not pinned and not compact:
		_start_gesture("move", pointer)


func _start_gesture(gesture: String, pointer: Vector2, edges := Vector2i.ZERO) -> void:
	_gesture = gesture
	_resize_edges = edges
	_start_pointer = pointer
	_start_rect = Rect2(position, size)
	interaction_started.emit()
	set_process_input(true)


func cancel_interaction() -> void:
	if _gesture.is_empty():
		return
	position = _start_rect.position
	size = _start_rect.size
	_gesture = ""
	set_process_input(false)
	interaction_cancelled.emit()


func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_WINDOW_FOCUS_OUT:
		cancel_interaction()


func _input(event: InputEvent) -> void:
	if _gesture.is_empty():
		return
	if (
		(event is InputEventKey and event.pressed and event.keycode == KEY_ESCAPE)
		or (
			event is InputEventMouseButton
			and event.button_index == MOUSE_BUTTON_RIGHT
			and event.pressed
		)
	):
		cancel_interaction()
	elif event is InputEventMouseMotion:
		var transform: Transform2D = (
			get_parent().get_global_transform_with_canvas().affine_inverse()
		)
		var delta: Vector2 = transform * event.position - transform * _start_pointer
		var rect := _start_rect
		if _gesture == "resize":
			for axis in 2:
				if _resize_edges[axis] < 0:
					rect.position[axis] += delta[axis]
					rect.size[axis] -= delta[axis]
				elif _resize_edges[axis] > 0:
					rect.size[axis] += delta[axis]
		else:
			rect.position += delta
		geometry_requested.emit(rect, _gesture == "resize", event.alt_pressed)
	elif (
		event is InputEventMouseButton
		and event.button_index == MOUSE_BUTTON_LEFT
		and not event.pressed
	):
		_gesture = ""
		set_process_input(false)
		interaction_finished.emit()
	else:
		return
	get_viewport().set_input_as_handled()
