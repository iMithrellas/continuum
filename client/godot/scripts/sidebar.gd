## Reusable sidebar shell: section state, filtering, and narrow-rail collapse.
class_name ContinuumSidebar
extends PanelContainer

signal filter_changed(query: String)
signal width_changed(width: float)

const MIN_WIDTH := 300.0
const MAX_WIDTH := 560.0
const MAP_MIN_WIDTH := 280.0
const OPEN_WIDTH := 430.0
const CLOSED_WIDTH := 48.0

var search: LineEdit
var clear_button: Button
var toggle_button: Button
var section_list: VBoxContainer
var _body: VBoxContainer
var _header_title: Label
var _search_row: HBoxContainer
var _sections_scroll: ScrollContainer
var sections: Dictionary = {}
var section_order: Array[String] = []
var _collapsed := false
var _pre_search_expanded: Dictionary = {}
var _no_matches: Label
var _splitter: Control
var _dragging_splitter := false
var _preferred_width := 430.0
var _last_viewport_width := -1.0
var _font_size := 13
var _button_height := 40.0
var _spacing := 8
var _padding := 10


func setup() -> void:
	set_sidebar_width(_preferred_width)
	var margin := MarginContainer.new()
	margin.name = "Margin"
	margin.add_theme_constant_override("margin_left", 12)
	margin.add_theme_constant_override("margin_top", 10)
	margin.add_theme_constant_override("margin_right", 10)
	margin.add_theme_constant_override("margin_bottom", 10)
	add_child(margin)
	_body = VBoxContainer.new()
	_body.add_theme_constant_override("separation", _spacing)
	margin.add_child(_body)
	var header := HBoxContainer.new()
	_body.add_child(header)
	_header_title = Label.new()
	_header_title.text = "CONTINUUM"
	_header_title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_header_title.add_theme_font_size_override("font_size", 16)
	header.add_child(_header_title)
	toggle_button = Button.new()
	toggle_button.text = "<"
	toggle_button.tooltip_text = "Collapse sidebar (Ctrl+\\)"
	toggle_button.custom_minimum_size = Vector2(40, 40)
	toggle_button.pressed.connect(toggle)
	header.add_child(toggle_button)
	_splitter = Control.new()
	_splitter.name = "WidthGrip"
	_splitter.custom_minimum_size = Vector2(36, 40)
	_splitter.mouse_default_cursor_shape = Control.CURSOR_HSIZE
	_splitter.tooltip_text = "Drag to resize sidebar"
	_splitter.mouse_filter = Control.MOUSE_FILTER_STOP
	_splitter.gui_input.connect(_on_splitter_input)
	var grip := Label.new()
	grip.text = "|||"
	grip.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	grip.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	grip.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	grip.mouse_filter = Control.MOUSE_FILTER_IGNORE
	grip.tooltip_text = "Drag to resize sidebar"
	_splitter.add_child(grip)
	header.add_child(_splitter)
	_search_row = HBoxContainer.new()
	_body.add_child(_search_row)
	search = LineEdit.new()
	search.placeholder_text = "Search sections and controls"
	search.tooltip_text = "Filter by section, label, or alias (Ctrl+F)"
	search.clear_button_enabled = true
	search.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	search.text_changed.connect(_on_search_changed)
	_search_row.add_child(search)
	clear_button = Button.new()
	clear_button.text = "Clear"
	clear_button.tooltip_text = "Clear search without changing pending actions"
	clear_button.pressed.connect(func() -> void: search.clear())
	_search_row.add_child(clear_button)
	_sections_scroll = ScrollContainer.new()
	_sections_scroll.name = "Sections"
	_sections_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_sections_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_AUTO
	_body.add_child(_sections_scroll)
	section_list = VBoxContainer.new()
	section_list.name = "SectionList"
	section_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	section_list.add_theme_constant_override("separation", _spacing)
	_sections_scroll.add_child(section_list)
	_no_matches = Label.new()
	_no_matches.text = "No matching sidebar controls."
	_no_matches.visible = false
	_no_matches.add_theme_color_override("font_color", Color("ffb74d"))
	section_list.add_child(_no_matches)


func add_section(key: String, label_text: String, aliases: PackedStringArray = []) -> VBoxContainer:
	var list: VBoxContainer = section_list
	var wrapper := VBoxContainer.new()
	wrapper.name = key
	wrapper.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var header := Button.new()
	header.text = "v  " + label_text
	header.alignment = HORIZONTAL_ALIGNMENT_LEFT
	header.tooltip_text = "Expand or collapse %s" % label_text
	header.pressed.connect(_toggle_section.bind(key))
	_apply_button_style(header)
	wrapper.add_child(header)
	var content := VBoxContainer.new()
	content.name = "Content"
	content.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	content.add_theme_constant_override("separation", _spacing - 2)
	wrapper.add_child(content)
	list.add_child(wrapper)
	sections[key] = {"label": label_text, "aliases": aliases, "wrapper": wrapper,
		"header": header, "content": content, "expanded": true, "authorized": true,
		"entries": []}
	section_order.append(key)
	return content


func register_entry(section_key: String, node: Control, label_text: String, aliases: PackedStringArray = []) -> void:
	if not sections.has(section_key):
		return
	sections[section_key].entries.append({"node": node, "label": label_text, "aliases": aliases,
			"visible": true})


func set_section_authorized(section_key: String, authorized: bool) -> void:
	if sections.has(section_key):
		sections[section_key].authorized = authorized
		sections[section_key].wrapper.visible = authorized


func _toggle_section(key: String) -> void:
	if not sections.has(key):
		return
	var section: Dictionary = sections[key]
	section.expanded = not section.expanded
	section.header.text = ("v  " if section.expanded else ">  ") + section.label
	section.content.visible = section.expanded


func _on_search_changed(query: String) -> void:
	var normalized := query.strip_edges().to_lower()
	if normalized.is_empty():
		for key: String in section_order:
			var section: Dictionary = sections[key]
			if _pre_search_expanded.has(key):
				section.expanded = _pre_search_expanded[key]
			section.content.visible = section.expanded
			section.header.text = ("v  " if section.expanded else ">  ") + section.label
			for entry: Dictionary in section.entries:
				entry.node.visible = entry.visible
		_pre_search_expanded.clear()
		_no_matches.visible = false
		filter_changed.emit("")
		return
	if _pre_search_expanded.is_empty():
		for key: String in section_order:
			_pre_search_expanded[key] = sections[key].expanded
	for key: String in section_order:
		var section: Dictionary = sections[key]
		var section_match := _matches(normalized, section.label, section.aliases)
		var any_match := section_match
		for entry: Dictionary in section.entries:
			var matches := section_match or _matches(normalized, entry.label, entry.aliases)
			entry.node.visible = entry.visible and matches
			any_match = any_match or matches
		section.wrapper.visible = section.authorized and any_match
		section.content.visible = any_match
		section.header.text = "v  " + section.label
	_no_matches.visible = true
	for key: String in section_order:
		if sections[key].wrapper.visible:
			_no_matches.visible = false
			break
	filter_changed.emit(normalized)


func _matches(query: String, label_text: String, aliases: PackedStringArray) -> bool:
	if label_text.to_lower().contains(query):
		return true
	for alias: String in aliases:
		if alias.to_lower().contains(query):
			return true
	return false


func toggle() -> void:
	_collapsed = not _collapsed
	custom_minimum_size.x = CLOSED_WIDTH if _collapsed else _preferred_width
	_header_title.visible = not _collapsed
	_search_row.visible = not _collapsed
	_sections_scroll.visible = not _collapsed
	toggle_button.text = ">" if _collapsed else "<"
	toggle_button.tooltip_text = "Reopen sidebar" if _collapsed else "Collapse sidebar (Ctrl+\\)"
	queue_redraw()


func set_sidebar_width(width: float) -> void:
	var viewport_width := get_viewport_rect().size.x
	var available := maxf(140.0, viewport_width - MAP_MIN_WIDTH)
	var maximum := minf(MAX_WIDTH, available)
	var minimum := minf(MIN_WIDTH, maximum)
	_preferred_width = clampf(width, minimum, maximum)
	if not _collapsed:
		custom_minimum_size.x = _preferred_width
	_apply_responsive_theme()
	width_changed.emit(_preferred_width)


func _on_splitter_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		_dragging_splitter = event.pressed
		if event.pressed:
			get_viewport().set_input_as_handled()
	elif event is InputEventMouseMotion and _dragging_splitter:
		set_sidebar_width(get_global_mouse_position().x - global_position.x)
		get_viewport().set_input_as_handled()


func _process(_delta: float) -> void:
	var viewport_width := get_viewport_rect().size.x
	if not is_equal_approx(viewport_width, _last_viewport_width):
		_last_viewport_width = viewport_width
		set_sidebar_width(_preferred_width)


func _apply_responsive_theme() -> void:
	var scale := clampf(inverse_lerp(MIN_WIDTH, MAX_WIDTH, _preferred_width), 0.0, 1.0)
	_font_size = int(round(lerpf(11.0, 15.0, scale)))
	_button_height = lerpf(36.0, 48.0, scale)
	_spacing = int(round(lerpf(4.0, 10.0, scale)))
	_padding = int(round(lerpf(8.0, 14.0, scale)))
	if not is_instance_valid(_body):
		return
	_body.add_theme_constant_override("separation", _spacing)
	var margin: MarginContainer = get_node("Margin")
	margin.add_theme_constant_override("margin_left", _padding)
	margin.add_theme_constant_override("margin_top", _padding)
	margin.add_theme_constant_override("margin_right", _padding)
	margin.add_theme_constant_override("margin_bottom", _padding)
	section_list.add_theme_constant_override("separation", _spacing)
	for section: Dictionary in sections.values():
		section.content.add_theme_constant_override("separation", maxi(2, _spacing - 2))
	_apply_control_theme(self)


func _apply_control_theme(node: Node) -> void:
	for child: Node in node.get_children():
		if child is Control:
			var control := child as Control
			control.add_theme_font_size_override("font_size", _font_size)
			if control is Button or control is LineEdit:
				control.custom_minimum_size.y = _button_height
		_apply_control_theme(child)


func _apply_button_style(button: Button) -> void:
	for state: String in ["normal", "hover", "pressed", "focus", "disabled"]:
		var style := StyleBoxFlat.new()
		style.bg_color = {"normal": Color("263142"), "hover": Color("344866"),
			"pressed": Color("1d8a82"), "focus": Color("2d536d"),
			"disabled": Color("202631")}.get(state, Color("263142"))
		style.border_color = Color("4b637c")
		style.set_border_width_all(1)
		style.set_corner_radius_all(4)
		button.add_theme_stylebox_override("%s" % state, style)
