## One reusable frame. Scrollable contents do not impose a minimum window width.
class_name WorkspaceWindow
extends Panel

signal focused
signal geometry_requested(rect: Rect2, resizing: bool, unsnapped: bool)
signal interaction_finished
signal minimize_requested
signal close_requested
signal pin_requested
signal dock_requested

const Icons = preload("res://ui/theme/icons.gd")
const RESIZE_DIRECTIONS := {
	"left": Vector2i(-1, 0), "right": Vector2i(1, 0),
	"top": Vector2i(0, -1), "bottom": Vector2i(0, 1),
	"top_left": Vector2i(-1, -1), "top_right": Vector2i(1, -1),
	"bottom_left": Vector2i(-1, 1), "bottom_right": Vector2i(1, 1),
}

var content: VBoxContainer
var titlebar: HBoxContainer
var pin_button: Button
var grip: Control
var resize_handles: Dictionary = {}
var divider: ColorRect
var scroll: ScrollContainer
var pinned := false
var docked := false
var collapsed := false
var dock_button: Button
var live_count: Label
var header_ground: ColorRect
var compact := false
var header_visible := true
var metrics := UiMetrics.new()
var _gesture := ""
var _resize_edges := Vector2i.ZERO
var _start_pointer := Vector2.ZERO
var _start_rect := Rect2()


func setup(title: String) -> void:
	mouse_filter = Control.MOUSE_FILTER_STOP
	clip_contents = true
	var surface := DeckTheme.box(ThemeTokens.color("bg-100"), ThemeTokens.color("line-100"), 0)
	add_theme_stylebox_override("panel", surface)
	header_ground = ColorRect.new()
	header_ground.color = ThemeTokens.color("bg-200")
	header_ground.mouse_filter = Control.MOUSE_FILTER_IGNORE
	header_ground.set_anchors_and_offsets_preset(Control.PRESET_TOP_WIDE)
	header_ground.offset_bottom = ThemeTokens.number("panel-header")
	add_child(header_ground)
	titlebar = HBoxContainer.new()
	titlebar.set_anchors_and_offsets_preset(Control.PRESET_TOP_WIDE)
	titlebar.mouse_filter = Control.MOUSE_FILTER_STOP
	titlebar.mouse_default_cursor_shape = Control.CURSOR_MOVE
	titlebar.gui_input.connect(_title_input)
	add_child(titlebar)
	var title_label := Label.new()
	title_label.text = title
	ThemeTokens.apply_label(title_label, "body-strong")
	title_label.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	title_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	title_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	titlebar.add_child(title_label)
	live_count = Label.new()
	ThemeTokens.apply_label(live_count, "readout")
	live_count.visible = false
	titlebar.add_child(live_count)
	dock_button = Button.new()
	dock_button.theme_type_variation = "ButtonQuiet"
	dock_button.text = "Float"
	dock_button.pressed.connect(func() -> void: dock_requested.emit())
	titlebar.add_child(dock_button)
	pin_button = _action("pin", "Pin position and size", func() -> void: pin_requested.emit())
	pin_button.toggle_mode = true
	_action("minimize", "Collapse to header / restore", func() -> void: minimize_requested.emit())
	_action("close", "Remove panel from workspace (reopen with Panels)", func() -> void: close_requested.emit())
	divider = ColorRect.new()
	divider.color = DeckTheme.LINE
	divider.mouse_filter = Control.MOUSE_FILTER_IGNORE
	divider.set_anchors_and_offsets_preset(Control.PRESET_TOP_WIDE)
	add_child(divider)
	scroll = ScrollContainer.new()
	scroll.follow_focus = true
	scroll.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	add_child(scroll)
	content = VBoxContainer.new()
	content.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	content.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.add_child(content)
	for key: String in RESIZE_DIRECTIONS:
		var edges: Vector2i = RESIZE_DIRECTIONS[key]
		var handle := Control.new()
		handle.name = "Resize_" + key
		handle.mouse_filter = Control.MOUSE_FILTER_STOP
		handle.mouse_default_cursor_shape = Control.CURSOR_HSIZE if edges.y == 0 else (
			Control.CURSOR_VSIZE if edges.x == 0 else (
				Control.CURSOR_FDIAGSIZE if edges.x == edges.y else Control.CURSOR_BDIAGSIZE))
		handle.tooltip_text = "Drag to resize. Hold Alt to bypass snapping."
		handle.gui_input.connect(_resize_input.bind(handle, edges))
		add_child(handle)
		resize_handles[key] = handle
	grip = resize_handles.bottom_right
	refresh_metrics()
	gui_input.connect(func(event: InputEvent) -> void:
		if event is InputEventMouseButton and event.pressed:
			focused.emit())
	set_process_input(false)


func _action(icon: String, hint: String, callback: Callable) -> Button:
	var button := Button.new()
	button.icon = Icons.texture(icon)
	for state: String in ["normal", "hover", "pressed", "focus", "disabled"]:
		button.add_theme_color_override("icon_" + state + "_color", Color.WHITE)
	button.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	button.mouse_entered.connect(func() -> void: button.icon = Icons.texture("pin-off" if icon == "pin" and pinned else icon, "ink"))
	button.mouse_exited.connect(func() -> void: button.icon = Icons.texture("pin-off" if icon == "pin" and pinned else icon))
	button.theme_type_variation = "ButtonIcon"
	button.expand_icon = true
	button.tooltip_text = hint
	button.pressed.connect(callback)
	titlebar.add_child(button)
	return button


func set_focused(value: bool) -> void:
	var surface: StyleBox = get_theme_stylebox("panel").duplicate(true)
	if surface is StyleBoxFlat:
		surface.border_color = DeckTheme.ACCENT if value else DeckTheme.LINE
	else:
		surface.body.border_color = DeckTheme.ACCENT if value else ThemeTokens.color("line-200")
	add_theme_stylebox_override("panel", surface)

## Integration supplies a real count; chrome never guesses backend ownership.
func set_live_count(count: int = -1) -> void:
	live_count.visible = count >= 0
	live_count.text = str(maxi(0, count))

func set_docked(value: bool, is_collapsed: bool) -> void:
	docked = value
	if docked:
		var surface := DeckTheme.box(ThemeTokens.color("bg-100"), ThemeTokens.color("line-100"), 0)
		surface.set_corner_radius_all(0)
		add_theme_stylebox_override("panel", surface)
	else:
		add_theme_stylebox_override("panel", DeckTheme.create().get_stylebox("panel", "PanelFloating"))
	collapsed = is_collapsed
	dock_button.text = "Float" if docked else "Dock"
	dock_button.tooltip_text = "Float over the map" if docked else "Reserve a dock beside the map"
	scroll.visible = not collapsed
	apply_state(pinned, compact)

func refresh_metrics() -> void:
	if not is_instance_valid(titlebar):
		return
	titlebar.offset_left = ThemeTokens.number("space-3")
	titlebar.offset_right = -ThemeTokens.number("space-4")
	titlebar.offset_top = ThemeTokens.number("space-1")
	titlebar.offset_bottom = ThemeTokens.number("panel-header") - ThemeTokens.number("space-1")
	divider.offset_top = ThemeTokens.number("panel-header") - 1
	divider.offset_bottom = ThemeTokens.number("panel-header")
	scroll.offset_left = ThemeTokens.number("space-3")
	scroll.offset_right = -ThemeTokens.number("space-3")
	scroll.offset_top = ThemeTokens.number("panel-header") + ThemeTokens.number("space-3") if header_visible else ThemeTokens.number("space-3")
	scroll.offset_bottom = -ThemeTokens.number("space-3")
	for child: Node in titlebar.get_children():
		if child is Button:
			child.custom_minimum_size = Vector2(ThemeTokens.number("control-sm"), ThemeTokens.number("control-sm"))
			child.add_theme_constant_override("icon_max_width", metrics.px(16))
	var corner := metrics.px(14)
	var border := ThemeTokens.number("space-1")
	for key: String in resize_handles:
		var handle: Control = resize_handles[key]
		var edges: Vector2i = RESIZE_DIRECTIONS[key]
		for axis in 2:
			var leading := 0.0 if edges[axis] <= 0 else 1.0
			var trailing := 1.0 if edges[axis] >= 0 else 0.0
			var extent := border if edges.x == 0 or edges.y == 0 else corner
			handle.set_anchor(axis, leading)
			handle.set_anchor(axis + 2, trailing)
			handle.set_offset(axis, corner if edges[axis] == 0 else (-extent if edges[axis] > 0 else 0.0))
			handle.set_offset(axis + 2, -corner if edges[axis] == 0 else (extent if edges[axis] < 0 else 0.0))


func set_header_visible(value: bool) -> void:
	header_visible = value
	header_ground.visible = value
	titlebar.visible = value
	divider.visible = value
	tooltip_text = "" if value else "Alt-drag to move. Restore panel headers from Layout or Ctrl+Shift+H."
	refresh_metrics()


func apply_state(is_pinned: bool, is_compact: bool) -> void:
	pinned = is_pinned
	compact = is_compact
	pin_button.set_pressed_no_signal(pinned)
	pin_button.icon = Icons.texture("pin-off" if pinned else "pin")
	pin_button.tooltip_text = "Unpin position and size" if pinned else "Pin position and size"
	pin_button.visible = not compact
	for handle: Control in resize_handles.values():
		handle.visible = not pinned and not compact and not docked and not collapsed
	dock_button.visible = not compact
	titlebar.mouse_default_cursor_shape = Control.CURSOR_ARROW if pinned or compact or docked or collapsed else Control.CURSOR_MOVE


func _title_input(event: InputEvent) -> void:
	_begin(event, "move", titlebar)


func _resize_input(event: InputEvent, handle: Control, edges: Vector2i) -> void:
	_begin(event, "resize", handle, edges)


func _begin(event: InputEvent, gesture: String, handle: Control, edges := Vector2i.ZERO) -> void:
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT and event.pressed:
		focused.emit()
		if not pinned and not compact and not docked and not collapsed:
			_start_gesture(gesture, handle.get_global_transform() * event.position, edges)
		accept_event()


func begin_move_from_global(pointer: Vector2) -> void:
	if not pinned and not compact and not docked and not collapsed:
		_start_gesture("move", pointer)


func _start_gesture(gesture: String, pointer: Vector2, edges := Vector2i.ZERO) -> void:
	_gesture = gesture
	_resize_edges = edges
	_start_pointer = pointer
	_start_rect = Rect2(position, size)
	set_process_input(true)


func cancel_interaction() -> void:
	if _gesture.is_empty():
		return
	position = _start_rect.position
	size = _start_rect.size
	_gesture = ""
	set_process_input(false)
	interaction_finished.emit()


func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_WINDOW_FOCUS_OUT:
		cancel_interaction()


func _input(event: InputEvent) -> void:
	if _gesture.is_empty():
		return
	if (event is InputEventKey and event.pressed and event.keycode == KEY_ESCAPE) or (
		event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_RIGHT and event.pressed):
		cancel_interaction()
	elif event is InputEventMouseMotion:
		var delta: Vector2 = event.position - _start_pointer
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
	elif event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT and not event.pressed:
		_gesture = ""
		set_process_input(false)
		interaction_finished.emit()
	else:
		return
	get_viewport().set_input_as_handled()
