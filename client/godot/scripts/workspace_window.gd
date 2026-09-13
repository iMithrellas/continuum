## One reusable frame. Scrollable contents do not impose a minimum window width.
class_name WorkspaceWindow
extends Panel

signal focused
signal geometry_requested(rect: Rect2, resizing: bool, unsnapped: bool)
signal interaction_finished
signal minimize_requested
signal close_requested
signal pin_requested

var content: VBoxContainer
var titlebar: HBoxContainer
var pin_button: Button
var grip: Label
var scroll: ScrollContainer
var pinned := false
var compact := false
var _gesture := ""
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
	titlebar.offset_left = 8
	titlebar.offset_right = -8
	titlebar.offset_top = 5
	titlebar.offset_bottom = 39
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
	pin_button = _action("P", "Pin position and size", func() -> void: pin_requested.emit())
	pin_button.toggle_mode = true
	_action("_", "Minimize to dock", func() -> void: minimize_requested.emit())
	_action("x", "Remove panel from workspace (reopen with Panels)", func() -> void: close_requested.emit())
	var line := ColorRect.new()
	line.color = DeckTheme.LINE
	line.mouse_filter = Control.MOUSE_FILTER_IGNORE
	line.set_anchors_and_offsets_preset(Control.PRESET_TOP_WIDE)
	line.offset_top = 44
	line.offset_bottom = 45
	add_child(line)
	scroll = ScrollContainer.new()
	scroll.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	scroll.offset_left = 12
	scroll.offset_right = -12
	scroll.offset_top = 56
	scroll.offset_bottom = -18
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	add_child(scroll)
	content = VBoxContainer.new()
	content.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	content.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.add_child(content)
	grip = Label.new()
	grip.text = "/"
	grip.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	grip.add_theme_color_override("font_color", DeckTheme.ACCENT)
	grip.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_RIGHT)
	grip.offset_left = -26
	grip.offset_top = -24
	grip.offset_right = -3
	grip.offset_bottom = -2
	grip.mouse_filter = Control.MOUSE_FILTER_STOP
	grip.mouse_default_cursor_shape = Control.CURSOR_FDIAGSIZE
	grip.tooltip_text = "Drag to resize. Hold Alt to bypass snapping."
	grip.gui_input.connect(_resize_input)
	add_child(grip)
	gui_input.connect(func(event: InputEvent) -> void:
		if event is InputEventMouseButton and event.pressed:
			focused.emit())
	set_process_input(false)


func _action(text: String, hint: String, callback: Callable) -> Button:
	var button := Button.new()
	button.text = text
	button.tooltip_text = hint
	button.custom_minimum_size = Vector2(28, 30)
	button.pressed.connect(callback)
	titlebar.add_child(button)
	return button


func set_focused(value: bool) -> void:
	var surface := get_theme_stylebox("panel").duplicate() as StyleBoxFlat
	surface.border_color = DeckTheme.ACCENT if value else DeckTheme.LINE
	add_theme_stylebox_override("panel", surface)


func apply_state(is_pinned: bool, is_compact: bool) -> void:
	pinned = is_pinned
	compact = is_compact
	pin_button.set_pressed_no_signal(pinned)
	pin_button.visible = not compact
	grip.visible = not pinned and not compact
	titlebar.mouse_default_cursor_shape = Control.CURSOR_ARROW if pinned or compact else Control.CURSOR_MOVE


func _title_input(event: InputEvent) -> void:
	_begin(event, "move")


func _resize_input(event: InputEvent) -> void:
	_begin(event, "resize")


func _begin(event: InputEvent, gesture: String) -> void:
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT and event.pressed:
		focused.emit()
		if not pinned and not compact:
			_gesture = gesture
			var handle: Control = grip if gesture == "resize" else titlebar
			_start_pointer = handle.get_global_transform() * event.position
			_start_rect = Rect2(position, size)
			set_process_input(true)
		accept_event()


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
			rect.size += delta
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
