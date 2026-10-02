## One reusable frame. Scrollable contents do not impose a minimum window width.
class_name WorkspaceWindow
extends Panel

signal focused
signal geometry_requested(rect: Rect2, resizing: bool, unsnapped: bool)
signal interaction_finished
signal minimize_requested
signal close_requested
signal pin_requested

const PIN_ICON := preload("res://assets/ui/panel-pin.svg")
const PINNED_ICON := preload("res://assets/ui/panel-pinned.svg")
const MINIMIZE_ICON := preload("res://assets/ui/panel-minimize.svg")
const CLOSE_ICON := preload("res://assets/ui/panel-close.svg")
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
	var surface := DeckTheme.box(DeckTheme.INK, DeckTheme.LINE, 0)
	surface.shadow_color = Color(0, 0, 0, 0.28)
	surface.shadow_size = 12
	add_theme_stylebox_override("panel", surface)
	titlebar = HBoxContainer.new()
	titlebar.set_anchors_and_offsets_preset(Control.PRESET_TOP_WIDE)
	titlebar.mouse_filter = Control.MOUSE_FILTER_STOP
	titlebar.mouse_default_cursor_shape = Control.CURSOR_MOVE
	titlebar.gui_input.connect(_title_input)
	add_child(titlebar)
	var title_label := Label.new()
	title_label.text = title
	title_label.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	title_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	title_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	titlebar.add_child(title_label)
	pin_button = _action(PIN_ICON, "Pin position and size", func() -> void: pin_requested.emit())
	pin_button.toggle_mode = true
	_action(MINIMIZE_ICON, "Minimize to dock", func() -> void: minimize_requested.emit())
	_action(CLOSE_ICON, "Remove panel from workspace (reopen with Panels)", func() -> void: close_requested.emit())
	divider = ColorRect.new()
	divider.color = DeckTheme.LINE
	divider.mouse_filter = Control.MOUSE_FILTER_IGNORE
	divider.set_anchors_and_offsets_preset(Control.PRESET_TOP_WIDE)
	add_child(divider)
	scroll = ScrollContainer.new()
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


func _action(icon: Texture2D, hint: String, callback: Callable) -> Button:
	var button := Button.new()
	button.icon = icon
	button.expand_icon = true
	button.tooltip_text = hint
	button.pressed.connect(callback)
	titlebar.add_child(button)
	return button


func set_focused(value: bool) -> void:
	var surface := get_theme_stylebox("panel").duplicate() as StyleBoxFlat
	surface.border_color = DeckTheme.ACCENT if value else DeckTheme.LINE
	add_theme_stylebox_override("panel", surface)

func refresh_metrics() -> void:
	if not is_instance_valid(titlebar):
		return
	titlebar.offset_left = metrics.px(14)
	titlebar.offset_right = -metrics.px(14)
	titlebar.offset_top = metrics.px(8)
	titlebar.offset_bottom = metrics.px(42)
	divider.offset_top = metrics.px(46)
	divider.offset_bottom = metrics.px(47)
	scroll.offset_left = metrics.px(12)
	scroll.offset_right = -metrics.px(12)
	scroll.offset_top = metrics.px(56 if header_visible else 12)
	scroll.offset_bottom = -metrics.px(12)
	for child: Node in titlebar.get_children():
		if child is Button:
			child.custom_minimum_size = metrics.min_size(30, 30)
			child.add_theme_constant_override("icon_max_width", metrics.px(16))
	var corner := metrics.px(14)
	var border := metrics.px(6)
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
	titlebar.visible = value
	divider.visible = value
	tooltip_text = "" if value else "Alt-drag to move. Restore panel headers from Layout or Ctrl+Shift+H."
	refresh_metrics()


func apply_state(is_pinned: bool, is_compact: bool) -> void:
	pinned = is_pinned
	compact = is_compact
	pin_button.set_pressed_no_signal(pinned)
	pin_button.icon = PINNED_ICON if pinned else PIN_ICON
	pin_button.tooltip_text = "Unpin position and size" if pinned else "Pin position and size"
	pin_button.visible = not compact
	for handle: Control in resize_handles.values():
		handle.visible = not pinned and not compact
	titlebar.mouse_default_cursor_shape = Control.CURSOR_ARROW if pinned or compact else Control.CURSOR_MOVE


func _title_input(event: InputEvent) -> void:
	_begin(event, "move", titlebar)


func _resize_input(event: InputEvent, handle: Control, edges: Vector2i) -> void:
	_begin(event, "resize", handle, edges)


func _begin(event: InputEvent, gesture: String, handle: Control, edges := Vector2i.ZERO) -> void:
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT and event.pressed:
		focused.emit()
		if not pinned and not compact:
			_start_gesture(gesture, handle.get_global_transform() * event.position, edges)
		accept_event()


func begin_move_from_global(pointer: Vector2) -> void:
	if not pinned and not compact:
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
