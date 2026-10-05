## The persistent, searchable navigator. The deck owns reveal gestures and shortcuts.
class_name CommandCard
extends PanelContainer

signal action_requested(action: String)

const WIDTH := 272
const INSET := 8
const GROUND := Color("1a1d21")
const WELL := Color("121417")
const HOVER := Color("22262b")
const LINE := Color("30353b")
const INK := Color("e6e8eb")
const MUTED := Color("b0b6bd")
const SUBTLE := Color("8b929a")
const ACCENT := Color("5cc6bd")
const GROUPS := {
	"Colony": ["overview", "people", "policies", "status"],
	"Build": ["construction", "operations", "inspector"],
	"Supply": ["resources"],
	"Signals": ["alerts", "activity", "trends"],
	"System": ["session", "performance", "admin", "developer"],
}
const PANEL_KEYS := {
	"policies": "P", "construction": "B", "inspector": "I", "resources": "R", "performance": "F8"
}
const STATES := ["open", "collapsed", "closed"]
const ACTIONS := {
	"digest": "Since you left",
	"settings": "Settings",
	"servers": "Servers",
	"disconnect": "Disconnect",
}

var _deck: WorkspaceDeck
var _search: LineEdit
var _search_surface: PanelContainer
var _scroll: ScrollContainer
var _body: VBoxContainer
var _workspace_grid: GridContainer
var _workspace_buttons: Dictionary = {}
var _workspace_group := ButtonGroup.new()
var _management: MarginContainer
var _management_grid: GridContainer
var _delete_button: Button
var _modified: MarginContainer
var _modified_row: HBoxContainer
var _panel_count: Label
var _group_nodes: Dictionary = {}
var _panel_rows: Dictionary = {}
var _footer: PanelContainer
var _footer_row: GridContainer
var _footer_buttons: Dictionary = {}
var _digest_label: Label
var _digest_count := -1
var _preference_error: Label
var _no_results: Label
var _results: Array[Button] = []
var _query := ""
var _row_normal: StyleBoxFlat
var _row_hover: StyleBoxFlat
var _available_size := Vector2.ZERO


## Small vector glyphs keep the prototype's 10×8 state controls crisp at UI scale.
class Glyph:
	extends Control

	var kind := ""

	func _init(value: String) -> void:
		kind = value
		mouse_filter = Control.MOUSE_FILTER_IGNORE
		custom_minimum_size = Vector2(10, 8) if kind in STATES else Vector2(14, 14)
		size_flags_vertical = Control.SIZE_SHRINK_CENTER

	func _draw() -> void:
		if kind in STATES:
			draw_set_transform((size - Vector2(10, 8)) * 0.5)
			match kind:
				"open":
					draw_rect(Rect2(0.5, 0.5, 9, 7), Color.WHITE, false, 1)
					draw_rect(Rect2(0.5, 0.5, 9, 2.5), Color.WHITE)
				"collapsed":
					draw_rect(Rect2(0.5, 0.5, 9, 2.6), Color.WHITE)
				"closed":
					draw_line(Vector2(3, 1.5), Vector2(7, 6.5), Color.WHITE, 1.2, true)
					draw_line(Vector2(7, 1.5), Vector2(3, 6.5), Color.WHITE, 1.2, true)
			return
		draw_set_transform((size - Vector2(14, 14)) * 0.5, 0, Vector2.ONE * 0.875)
		match kind:
			"search":
				draw_arc(Vector2(7, 7), 4.5, 0, TAU, 24, Color.WHITE, 1.5, true)
				draw_line(Vector2(10.5, 10.5), Vector2(14, 14), Color.WHITE, 1.5, true)
			"digest":
				draw_arc(Vector2(8, 8), 5.5, -2.35, PI, 28, Color.WHITE, 1.5, true)
				_line([Vector2(2.5, 2.5), Vector2(2.5, 5), Vector2(5, 5)])
				_line([Vector2(8, 5), Vector2(8, 8), Vector2(10, 9.5)])
			"settings":
				draw_arc(Vector2(8, 8), 2.2, 0, TAU, 20, Color.WHITE, 1.5, true)
				for index in 8:
					var ray := Vector2.from_angle(index * TAU / 8)
					draw_line(
						Vector2(8, 8) + ray * 4.5, Vector2(8, 8) + ray * 6.2, Color.WHITE, 1.5, true
					)
			"servers":
				for top: float in [2.5, 9.0]:
					draw_rect(Rect2(2.5, top, 11, 4.5), Color.WHITE, false, 1.5)
					draw_circle(Vector2(5, top + 2.25), 0.8, Color.WHITE)
			"disconnect":
				draw_line(Vector2(8, 2.5), Vector2(8, 7.5), Color.WHITE, 1.5, true)
				draw_arc(Vector2(8, 8.25), 5, -0.87, PI + 0.87, 28, Color.WHITE, 1.5, true)

	func _line(points: PackedVector2Array) -> void:
		draw_polyline(points, Color.WHITE, 1.5, true)


func setup(deck: WorkspaceDeck) -> void:
	if is_instance_valid(_deck) and _deck.workspace_changed.is_connected(refresh):
		_deck.workspace_changed.disconnect(refresh)
	_deck = deck
	if _search == null:
		_build()
	if not _deck.workspace_changed.is_connected(refresh):
		_deck.workspace_changed.connect(refresh)
	refresh()


## Update existing controls in place; typing, selection and body scroll are retained.
func refresh() -> void:
	if not is_instance_valid(_deck) or _search == null:
		return
	if not _deck.model.workspaces.has(_deck.model.active):
		return
	var focused := get_viewport().gui_get_focus_owner() if is_inside_tree() else null
	var owned_focus := focused != null and is_ancestor_of(focused)
	_sync_workspaces()
	_sync_panels()
	_modified.visible = _deck.is_layout_dirty()
	var preference_error: Variant = _deck.get("preference_error")
	_preference_error.text = preference_error if preference_error is String else ""
	_preference_error.tooltip_text = _preference_error.text
	_preference_error.visible = not _preference_error.text.is_empty()
	_delete_button.disabled = _deck.model.workspaces.size() < 2
	_apply_filter()
	if owned_focus and is_visible_in_tree():
		if not is_instance_valid(focused) or not focused.is_visible_in_tree():
			_search.grab_focus()
		elif focused is BaseButton and focused.disabled:
			_search.grab_focus()


## Logical viewport size, after UI scaling. Keep the eight-pixel inset on every edge.
## Call on deck resize; the regular 272-pixel prototype layout remains unchanged.
func set_available_size(viewport: Vector2) -> void:
	_available_size = viewport
	if _search == null:
		return
	var width := clampf(viewport.x - INSET * 2, 0, WIDTH)
	var narrow := width < 260
	_management_grid.columns = 2 if narrow else 4
	_footer_row.columns = 2 if narrow else 3
	_modified_row.add_theme_constant_override("separation", 4 if narrow else 10)
	custom_minimum_size.x = width
	offset_right = INSET + width
	size = Vector2(width, maxf(0, viewport.y - INSET * 2))


func focus_search() -> void:
	if _search != null and is_visible_in_tree():
		_search.grab_focus()
		_search.select_all()


## point is in the same viewport coordinate space as get_global_rect().
func contains_point(point: Vector2) -> bool:
	return is_visible_in_tree() and get_global_rect().has_point(point)


## Negative means coverage is unavailable; zero is an explicitly supplied empty recap.
func set_recap_count(count: int) -> void:
	_digest_count = maxi(-1, count)
	if _digest_label != null:
		_digest_label.text = "—" if _digest_count < 0 else str(_digest_count)
		_footer_buttons.digest.tooltip_text = (
			"Since you left · Coverage unavailable"
			if _digest_count < 0
			else "Since you left · %d events" % _digest_count
		)


func set_digest_count(count: int) -> void:
	set_recap_count(count)


func _build() -> void:
	name = "CommandCard"
	custom_minimum_size.x = WIDTH
	set_anchors_and_offsets_preset(Control.PRESET_LEFT_WIDE)
	offset_left = INSET
	offset_top = INSET
	offset_right = INSET + WIDTH
	offset_bottom = -INSET
	clip_contents = true
	mouse_filter = Control.MOUSE_FILTER_STOP
	theme = _card_theme()
	var surface := _box(GROUND, LINE, 6, Vector4.ONE)
	surface.shadow_color = Color(0, 0, 0, 0.45)
	surface.shadow_size = 20
	surface.shadow_offset = Vector2(0, 10)
	add_theme_stylebox_override("panel", surface)
	var stack := VBoxContainer.new()
	stack.add_theme_constant_override("separation", 0)
	add_child(stack)
	_build_search(stack)
	_scroll = ScrollContainer.new()
	_scroll.name = "CommandBodyScroll"
	_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_scroll.follow_focus = true
	stack.add_child(_scroll)
	_style_scrollbar(_scroll.get_v_scroll_bar())
	_body = VBoxContainer.new()
	_body.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_body.add_theme_constant_override("separation", 0)
	_scroll.add_child(_body)
	_build_workspaces()
	_build_panel_groups()
	var empty_inset := _inset(_body, Vector4(12, 10, 12, 10))
	_no_results = _label("", 12, SUBTLE)
	_no_results.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	empty_inset.add_child(_no_results)
	var bottom := Control.new()
	bottom.custom_minimum_size.y = 8
	_body.add_child(bottom)
	_build_footer(stack)
	if _available_size != Vector2.ZERO:
		set_available_size(_available_size)


func _build_search(parent: Node) -> void:
	var margin := _inset(parent, Vector4(10, 10, 10, 2))
	_search_surface = PanelContainer.new()
	_search_surface.name = "SearchWell"
	margin.add_child(_search_surface)
	var row := _hbox(_search_surface, 8)
	var icon := Glyph.new("search")
	icon.modulate = SUBTLE
	row.add_child(icon)
	_search = LineEdit.new()
	_search.name = "CommandSearch"
	_search.placeholder_text = "Go to panel, workspace, action"
	_search.tooltip_text = "Go to panel, workspace or action · Ctrl K"
	_search.custom_minimum_size.y = 30
	_search.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_search.add_theme_font_size_override("font_size", 13)
	_search.add_theme_stylebox_override("normal", StyleBoxEmpty.new())
	_search.add_theme_stylebox_override("focus", StyleBoxEmpty.new())
	_search.add_theme_color_override("font_color", INK)
	_search.add_theme_color_override("font_placeholder_color", SUBTLE)
	_search.add_theme_color_override("caret_color", INK)
	_search.add_theme_color_override("selection_color", Color(0.36, 0.78, 0.74, 0.25))
	row.add_child(_search)
	row.add_child(_keycap("Ctrl K"))
	_search.text_changed.connect(_on_query_changed)
	_search.text_submitted.connect(_activate_first_result)
	_search.gui_input.connect(_navigate_results.bind(_search))
	_search.focus_entered.connect(_search_focus_changed)
	_search.focus_exited.connect(_search_focus_changed)
	_search_focus_changed()


func _build_workspaces() -> void:
	var heading := _heading(_body, "WORKSPACES", 8, 26)
	var hint := _hbox(heading, 5)
	hint.add_child(_keycap("Alt"))
	hint.add_child(_label("+ number", 11, SUBTLE))
	var margin := _inset(_body, Vector4(10, 0, 10, 0))
	_workspace_grid = GridContainer.new()
	_workspace_grid.name = "WorkspaceGrid"
	_workspace_grid.columns = 2
	_workspace_grid.add_theme_constant_override("h_separation", 4)
	_workspace_grid.add_theme_constant_override("v_separation", 4)
	margin.add_child(_workspace_grid)
	_management = _inset(_body, Vector4(12, 7, 12, 0))
	_management_grid = GridContainer.new()
	_management_grid.columns = 4
	_management_grid.add_theme_constant_override("h_separation", 14)
	_management_grid.add_theme_constant_override("v_separation", 4)
	_management.add_child(_management_grid)
	for entry: Array in [
		["+ New", "new"], ["Rename", "rename"], ["Duplicate", "duplicate"], ["Delete", "delete"]
	]:
		var button := _button(_management_grid, entry[0], _workspace_action.bind(entry[1]))
		button.add_theme_font_size_override("font_size", 12)
		button.add_theme_color_override("font_color", SUBTLE)
		if entry[1] == "delete":
			_delete_button = button
	_modified = _inset(_body, Vector4(10, 8, 10, 0))
	var panel := PanelContainer.new()
	panel.add_theme_stylebox_override(
		"panel", _box(HOVER, Color.TRANSPARENT, 4, Vector4(8, 0, 8, 0))
	)
	_modified.add_child(panel)
	var row := _hbox(panel, 10)
	_modified_row = row
	row.custom_minimum_size.y = 26
	row.add_child(_label("Layout changed", 12, MUTED))
	for action: String in ["save", "revert"]:
		var button := _button(row, action.capitalize(), _workspace_action.bind(action))
		button.add_theme_color_override("font_color", INK)
		button.tooltip_text = (
			"Save this workspace layout" if action == "save" else "Revert to saved layout"
		)
		button.draw.connect(_draw_underline.bind(button))


func _build_panel_groups() -> void:
	var heading := _heading(_body, "PANELS", 8, 26)
	_panel_count = _label("", 11, SUBTLE)
	heading.add_child(_panel_count)
	_row_normal = _box(Color.TRANSPARENT, Color.TRANSPARENT, 0, Vector4(4, 0, 8, 0))
	_row_hover = _box(HOVER, Color.TRANSPARENT, 0, Vector4(4, 0, 8, 0))
	for group: String in GROUPS:
		var section := VBoxContainer.new()
		section.name = group + "Panels"
		section.add_theme_constant_override("separation", 0)
		_body.add_child(section)
		var row := _heading(section, group.to_upper(), 4, 22)
		var count := _label("", 11, SUBTLE, "readout")
		row.add_child(count)
		_group_nodes[group] = {"section": section, "count": count, "keys": []}


func _build_footer(parent: Node) -> void:
	_footer = PanelContainer.new()
	_footer.name = "CommandFooter"
	var surface := _box(Color.TRANSPARENT, Color("262a2f"), 0, Vector4(8, 7, 8, 8))
	surface.set_border_width_all(0)
	surface.border_width_top = 1
	_footer.add_theme_stylebox_override("panel", surface)
	parent.add_child(_footer)
	var stack := VBoxContainer.new()
	stack.add_theme_constant_override("separation", 0)
	_footer.add_child(stack)
	var digest := _footer_button(stack, "digest")
	_digest_label = _label("", 12, INK, "readout")
	_digest_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	_digest_label.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_digest_label.offset_right = -6
	digest.add_child(_digest_label)
	set_recap_count(_digest_count)
	_footer_row = GridContainer.new()
	_footer_row.columns = 3
	_footer_row.add_theme_constant_override("h_separation", 2)
	_footer_row.add_theme_constant_override("v_separation", 0)
	stack.add_child(_footer_row)
	for action: String in ["settings", "servers", "disconnect"]:
		_footer_button(_footer_row, action)
	_preference_error = _label("", 11, Color("f26a57"))
	_preference_error.name = "PreferenceSaveError"
	_preference_error.mouse_filter = Control.MOUSE_FILTER_PASS
	_preference_error.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_preference_error.max_lines_visible = 2
	_preference_error.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	_preference_error.clip_text = true
	_preference_error.add_theme_constant_override("line_spacing", -2)
	_preference_error.custom_minimum_size.y = clampf(
		ceilf(_preference_error.get_theme_font("font").get_height(11)) * 2 - 2, 16, 32
	)
	_preference_error.hide()
	stack.add_child(_preference_error)


func _footer_button(parent: Node, action: String) -> Button:
	var button := _button(parent, ACTIONS[action], _emit_action.bind(action))
	button.name = action.capitalize() + "Action"
	button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	button.custom_minimum_size.y = 28
	button.alignment = HORIZONTAL_ALIGNMENT_LEFT
	var padding := Vector4(29 if action == "digest" else 26, 0, 6, 0)
	button.add_theme_stylebox_override(
		"normal", _box(Color.TRANSPARENT, Color.TRANSPARENT, 4, padding)
	)
	button.add_theme_stylebox_override("hover", _box(HOVER, Color.TRANSPARENT, 4, padding))
	button.add_theme_stylebox_override("pressed", _box(HOVER, Color.TRANSPARENT, 4, padding))
	var icon := Glyph.new(action)
	button.add_child(icon)
	icon.set_anchors_and_offsets_preset(Control.PRESET_CENTER_LEFT)
	icon.position = Vector2(6, 7)
	icon.size = Vector2(14, 14)
	if action == "disconnect":
		button.add_theme_color_override("font_hover_color", Color("f26a57"))
		button.add_theme_color_override("font_pressed_color", Color("f26a57"))
	_bind_icon_color(button, icon)
	_footer_buttons[action] = button
	return button


func _sync_workspaces() -> void:
	for id: String in _workspace_buttons.keys():
		if not _deck.model.workspaces.has(id):
			var removed: Button = _workspace_buttons[id].button
			_workspace_grid.remove_child(removed)
			removed.queue_free()
			_workspace_buttons.erase(id)
	var index := 0
	for id: String in _deck.model.workspaces:
		if not _workspace_buttons.has(id):
			_workspace_buttons[id] = _make_workspace_button(id)
		var nodes: Dictionary = _workspace_buttons[id]
		var button: Button = nodes.button
		if button.get_index() != index:
			_workspace_grid.move_child(button, index)
		nodes.keycap.text = str(index + 1)
		var title: String = str(_deck.model.workspaces[id].get("name", id))
		nodes.label.text = title
		button.tooltip_text = title + (" · Alt %d" % (index + 1) if index < 9 else "")
		var active: bool = _deck.model.active == id
		if nodes.active != active:
			nodes.active = active
			button.set_pressed_no_signal(active)
			nodes.label.add_theme_color_override("font_color", INK if active else MUTED)
			nodes.label.add_theme_font_override(
				"font", ThemeTokens.font("body-strong" if active else "body")
			)
			_style_keycap(nodes.keycap, active)
		index += 1


func _make_workspace_button(id: String) -> Dictionary:
	var button := _button(_workspace_grid, "", _pick_workspace.bind(id))
	button.name = "Workspace_" + id
	button.custom_minimum_size = Vector2(0, 44)
	button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	button.toggle_mode = true
	button.button_group = _workspace_group
	button.add_theme_stylebox_override("normal", _box(Color.TRANSPARENT, LINE))
	button.add_theme_stylebox_override("hover", _box(HOVER, LINE))
	button.add_theme_stylebox_override("pressed", _box(HOVER, ACCENT))
	button.add_theme_stylebox_override("hover_pressed", _box(HOVER, ACCENT))
	var margin := _inset(button, Vector4(9, 6, 9, 6))
	margin.mouse_filter = Control.MOUSE_FILTER_IGNORE
	margin.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	var row := _hbox(margin, 7)
	row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var keycap := _keycap("")
	keycap.size_flags_vertical = Control.SIZE_SHRINK_BEGIN
	row.add_child(keycap)
	var label := _label("", 12, MUTED)
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	label.max_lines_visible = 2
	label.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	label.clip_text = true
	label.add_theme_constant_override("line_spacing", -2)
	# Autowrap + clip_text reports a one-pixel minimum until layout has a width.
	# Reserve up to two font lines inside the fixed 44-pixel card instead.
	var line_height := ceilf(label.get_theme_font("font").get_height(12))
	label.custom_minimum_size = Vector2(16, clampf(line_height * 2 - 2, 16, 32))
	label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	label.size_flags_vertical = Control.SIZE_FILL
	row.add_child(label)
	return {"button": button, "label": label, "keycap": keycap, "active": null}


func _sync_panels() -> void:
	var total := 0
	var opened := 0
	for group: String in GROUPS:
		var keys: Array = GROUPS[group].duplicate()
		if group == "System":
			for key: String in _deck.windows:
				if not _known_panel(key):
					keys.append(key)
		_group_nodes[group].keys = keys
		var group_total := 0
		var group_open := 0
		for key: String in keys:
			if not _panel_available(key):
				if _panel_rows.has(key):
					_panel_rows[key].row.hide()
				continue
			if not _panel_rows.has(key):
				_panel_rows[key] = _make_panel_row(key, _group_nodes[group].section)
			var state := _panel_state(key)
			_sync_panel_row(key, state)
			group_total += 1
			if state != "closed":
				group_open += 1
		# Permission arrival can create an earlier declared row after later ones.
		# Keep retained (including hidden unauthorized) rows in registry order.
		var row_index := 1
		for key: String in keys:
			if _panel_rows.has(key):
				_group_nodes[group].section.move_child(_panel_rows[key].row, row_index)
				row_index += 1
		_group_nodes[group].count.text = "%d / %d" % [group_open, group_total]
		total += group_total
		opened += group_open
	_panel_count.text = "%d / %d in workspace" % [opened, total]


func _make_panel_row(key: String, parent: Node) -> Dictionary:
	var panel := PanelContainer.new()
	panel.name = "Panel_" + key
	panel.custom_minimum_size.y = 26
	panel.add_theme_stylebox_override("panel", _row_normal)
	parent.add_child(panel)
	var row := _hbox(panel, 8)
	var title: String = WorkspaceLayout.PANEL_NAMES.get(key, key.capitalize())
	var button := _button(row, title, _reveal_panel.bind(key))
	button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	button.alignment = HORIZONTAL_ALIGNMENT_LEFT
	button.clip_text = true
	button.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	button.add_theme_font_size_override("font_size", 13)
	for style: String in ["normal", "hover", "pressed"]:
		button.add_theme_stylebox_override(
			style, _box(Color.TRANSPARENT, Color.TRANSPARENT, 0, Vector4(8, 0, 0, 0))
		)
	if PANEL_KEYS.has(key):
		row.add_child(_keycap(PANEL_KEYS[key]))
	var segment := PanelContainer.new()
	segment.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	segment.add_theme_stylebox_override("panel", _box(WELL, LINE, 4, Vector4.ONE * 2))
	row.add_child(segment)
	var states := _hbox(segment, 1)
	var group := ButtonGroup.new()
	var buttons: Dictionary = {}
	for state: String in STATES:
		var state_button := _button(states, "", _set_panel_state.bind(key, state))
		state_button.name = state.capitalize()
		state_button.custom_minimum_size = Vector2(18, 16)
		state_button.toggle_mode = true
		state_button.button_group = group
		state_button.tooltip_text = (
			{"open": "Open %s", "collapsed": "Collapse %s to its tab", "closed": "Close %s"}[state]
			% title
		)
		state_button.set_meta("result_owner", button)
		state_button.add_theme_stylebox_override(
			"hover", _box(Color("2c3137"), Color.TRANSPARENT, 3)
		)
		state_button.add_theme_stylebox_override(
			"pressed", _box(Color("3a4047"), Color.TRANSPARENT, 3)
		)
		state_button.add_theme_stylebox_override(
			"hover_pressed", _box(Color("3a4047"), Color.TRANSPARENT, 3)
		)
		state_button.add_theme_color_override("font_color", Color("59616a"))
		state_button.add_theme_color_override("font_hover_color", MUTED)
		var icon := Glyph.new(state)
		state_button.add_child(icon)
		icon.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		_bind_icon_color(state_button, icon)
		buttons[state] = state_button
	for control: Button in [button, buttons.open, buttons.collapsed, buttons.closed]:
		control.mouse_entered.connect(_highlight_panel_row.bind(key))
		control.mouse_exited.connect(_highlight_panel_row.bind(key))
		control.focus_entered.connect(_highlight_panel_row.bind(key))
		control.focus_exited.connect(_highlight_panel_row.bind(key))
	return {"row": panel, "button": button, "buttons": buttons, "state": ""}


func _sync_panel_row(key: String, state: String) -> void:
	var nodes: Dictionary = _panel_rows[key]
	if nodes.state == state:
		return
	nodes.state = state
	var button: Button = nodes.button
	button.tooltip_text = "%s · %s · Open and focus panel" % [button.text, state]
	var ink := SUBTLE if state == "closed" else INK
	for color: String in [
		"font_color", "font_hover_color", "font_pressed_color", "font_focus_color"
	]:
		button.add_theme_color_override(color, ink)
	for value: String in STATES:
		var state_button: Button = nodes.buttons[value]
		state_button.set_pressed_no_signal(value == state)
		_update_icon_color(state_button, state_button.get_child(0))


func _apply_filter() -> void:
	_results.clear()
	for id: String in _deck.model.workspaces:
		var nodes: Dictionary = _workspace_buttons[id]
		var button: Button = nodes.button
		button.visible = _matches(str(nodes.label.text))
		if button.visible:
			_results.append(button)
	_management.visible = _query.is_empty()
	for group: String in GROUPS:
		var any_visible := false
		for key: String in _group_nodes[group].keys:
			if not _panel_rows.has(key):
				continue
			var nodes: Dictionary = _panel_rows[key]
			var matched := _panel_available(key) and _matches(str(nodes.button.text))
			nodes.row.visible = matched
			if matched:
				any_visible = true
				_results.append(nodes.button)
		_group_nodes[group].section.visible = any_visible
	var footer_visible := false
	var row_visible := false
	for action: String in ACTIONS:
		var button: Button = _footer_buttons[action]
		button.visible = _matches(ACTIONS[action])
		if button.visible:
			footer_visible = true
			row_visible = row_visible or action != "digest"
			_results.append(button)
	_footer_row.visible = row_visible
	_footer.visible = footer_visible or _preference_error.visible
	_no_results.get_parent().visible = not _query.is_empty() and _results.is_empty()
	_no_results.text = "Nothing matches “%s”." % _search.text.strip_edges()


func _on_query_changed(text: String) -> void:
	_query = text.strip_edges().to_lower()
	_apply_filter()
	_scroll.scroll_vertical = 0


func _matches(text: String) -> bool:
	return _query.is_empty() or text.to_lower().contains(_query)


func _panel_available(key: String) -> bool:
	return _deck.windows.has(key) and bool(_deck.authorized.get(key, false))


func _known_panel(key: String) -> bool:
	for keys: Array in GROUPS.values():
		if key in keys:
			return true
	return false


func _panel_state(key: String) -> String:
	var saved: Dictionary = _deck.state(key)
	if not saved.get("open", false):
		return "closed"
	return "collapsed" if saved.get("minimized", false) else "open"


func _pick_workspace(id: String) -> void:
	_deck.switch_workspace(id)
	refresh()


func _workspace_action(action: String) -> void:
	match action:
		"new":
			_deck.edit_workspace(true)
		"rename":
			_deck.edit_workspace(false)
		"duplicate":
			_deck.duplicate_workspace()
		"delete":
			_deck.delete_workspace()
		"save":
			_deck.save_workspace()
		"revert":
			_deck.revert_workspace()
	refresh()


func _reveal_panel(key: String) -> void:
	if _panel_available(key):
		_deck.reveal_panel(key)
		refresh()


func _set_panel_state(key: String, state: String) -> void:
	if _panel_available(key):
		_deck.set_panel_state(key, state)
		refresh()


func _emit_action(action: String) -> void:
	action_requested.emit(action)


func _activate_first_result(_text: String) -> void:
	if not _results.is_empty() and not _results[0].disabled:
		_results[0].pressed.emit()


func _navigate_results(event: InputEvent, source: Control) -> void:
	if not event is InputEventKey or not event.pressed:
		return
	if event.alt_pressed or event.ctrl_pressed or event.meta_pressed:
		return
	if event.keycode not in [KEY_UP, KEY_DOWN]:
		return
	var owner: Control = source.get_meta("result_owner", source)
	var index := _results.find(owner as Button) if owner is Button else -1
	var next := clampi(index + (1 if event.keycode == KEY_DOWN else -1), -1, _results.size() - 1)
	var target: Control = _search if next == -1 else _results[next]
	target.grab_focus()
	if _body.is_ancestor_of(target):
		_scroll.ensure_control_visible(target)
	source.accept_event()


func _search_focus_changed() -> void:
	var focused := _search.has_focus()
	var style := _box(WELL, ACCENT if focused else LINE, 4, Vector4(10, 1, 7, 1))
	if focused:
		style.shadow_color = Color(0.36, 0.78, 0.74, 0.16)
		style.shadow_size = 3
	_search_surface.add_theme_stylebox_override("panel", style)


func _highlight_panel_row(key: String) -> void:
	if not _panel_rows.has(key):
		return
	var nodes: Dictionary = _panel_rows[key]
	var controls: Array = [nodes.button] + nodes.buttons.values()
	var highlighted := false
	for button: Button in controls:
		highlighted = highlighted or button.is_hovered() or button.has_focus()
	nodes.row.add_theme_stylebox_override("panel", _row_hover if highlighted else _row_normal)


func _bind_icon_color(button: Button, icon: Control) -> void:
	button.mouse_entered.connect(_update_icon_color.bind(button, icon))
	button.mouse_exited.connect(_update_icon_color.bind(button, icon))
	button.focus_entered.connect(_update_icon_color.bind(button, icon))
	button.focus_exited.connect(_update_icon_color.bind(button, icon))
	_update_icon_color(button, icon)


func _update_icon_color(button: Button, icon: Control) -> void:
	var color := "font_color"
	if button.button_pressed:
		color = "font_pressed_color"
	elif button.is_hovered():
		color = "font_hover_color"
	icon.modulate = button.get_theme_color(color)


func _draw_underline(button: Button) -> void:
	var width := (
		button
		. get_theme_font("font")
		. get_string_size(
			button.text, HORIZONTAL_ALIGNMENT_LEFT, -1, button.get_theme_font_size("font_size")
		)
		. x
	)
	var start := Vector2((button.size.x - width) * 0.5, button.size.y * 0.5 + 8)
	button.draw_line(start, start + Vector2(width, 0), Color("4b525a"))


func _button(parent: Node, text: String, callback: Callable) -> Button:
	var button := Button.new()
	button.text = text
	button.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	button.pressed.connect(callback)
	button.gui_input.connect(_navigate_results.bind(button))
	parent.add_child(button)
	return button


func _heading(parent: Node, text: String, top: int, height: int) -> HBoxContainer:
	var margin := _inset(parent, Vector4(12, top, 12, 0))
	var row := _hbox(margin, 4)
	row.custom_minimum_size.y = height
	var label := _label(text, 11, SUBTLE, "section")
	label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(label)
	return row


func _label(text: String, font_size: int, color: Color, font_style := "body") -> Label:
	var label := Label.new()
	label.text = text
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	label.add_theme_font_override("font", ThemeTokens.font(font_style))
	label.add_theme_font_size_override("font_size", maxi(11, font_size))
	label.add_theme_color_override("font_color", color)
	return label


func _keycap(text: String) -> Label:
	var label := _label(text, 11, SUBTLE, "readout")
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	label.custom_minimum_size.y = 18
	label.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	_style_keycap(label, false)
	return label


func _style_keycap(label: Label, active: bool) -> void:
	var style := _box(Color.TRANSPARENT, ACCENT if active else LINE, 3, Vector4(5, 0, 5, 0))
	style.border_width_bottom = 2
	label.add_theme_stylebox_override("normal", style)
	label.add_theme_color_override("font_color", ACCENT if active else SUBTLE)


func _inset(parent: Node, margins: Vector4) -> MarginContainer:
	var margin := MarginContainer.new()
	margin.add_theme_constant_override("margin_left", int(margins.x))
	margin.add_theme_constant_override("margin_top", int(margins.y))
	margin.add_theme_constant_override("margin_right", int(margins.z))
	margin.add_theme_constant_override("margin_bottom", int(margins.w))
	parent.add_child(margin)
	return margin


func _hbox(parent: Node, separation: int) -> HBoxContainer:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", separation)
	parent.add_child(row)
	return row


func _style_scrollbar(scrollbar: VScrollBar) -> void:
	scrollbar.custom_minimum_size.x = 6
	var track := _box(Color.TRANSPARENT, Color.TRANSPARENT, 0, Vector4(3, 0, 3, 0))
	scrollbar.add_theme_stylebox_override("scroll", track)
	for state: String in ["grabber", "grabber_highlight", "grabber_pressed"]:
		scrollbar.add_theme_stylebox_override(
			state, _box(LINE, Color.TRANSPARENT, 3, Vector4(3, 3, 3, 3))
		)
	for icon: String in [
		"increment",
		"increment_highlight",
		"increment_pressed",
		"decrement",
		"decrement_highlight",
		"decrement_pressed"
	]:
		scrollbar.add_theme_icon_override(icon, ImageTexture.new())


func _card_theme() -> Theme:
	var result := Theme.new()
	result.default_font = ThemeTokens.font("body")
	result.default_font_size = 12
	for style: String in ["normal", "disabled"]:
		result.set_stylebox(style, "Button", _box(Color.TRANSPARENT))
	for style: String in ["hover", "pressed", "hover_pressed"]:
		result.set_stylebox(style, "Button", _box(HOVER))
	result.set_stylebox("focus", "Button", _box(Color.TRANSPARENT, ACCENT))
	for color: String in [
		"font_hover_color", "font_pressed_color", "font_hover_pressed_color", "font_focus_color"
	]:
		result.set_color(color, "Button", INK)
	result.set_color("font_color", "Button", MUTED)
	result.set_color("font_disabled_color", "Button", Color("59616a"))
	return result


func _box(
	fill: Color, border := Color.TRANSPARENT, radius := 4, padding := Vector4.ZERO
) -> StyleBoxFlat:
	var style := StyleBoxFlat.new()
	style.bg_color = fill
	style.border_color = border
	style.set_border_width_all(0 if border.a == 0 else 1)
	style.set_corner_radius_all(radius)
	style.content_margin_left = padding.x
	style.content_margin_top = padding.y
	style.content_margin_right = padding.z
	style.content_margin_bottom = padding.w
	return style
