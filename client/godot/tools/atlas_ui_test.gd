## Backend-free contracts against actual main, not a substitute mock UI.
## Missing redesign APIs are failures. Run after integrating deck/card/main workers.
extends "res://tools/atlas_ui_fixture.gd"

const REQUIRED_METHODS := [
	"is_command_open",
	"open_command",
	"close_command",
	"set_panel_state",
	"reveal_panel",
	"duplicate_workspace",
	"delete_workspace",
	"save_workspace",
	"revert_workspace",
	"is_layout_dirty"
]
const MICRO_PANELS := ["status", "session", "performance"]
const NORMALIZED_RECT_EPSILON := 0.000001
const LEGACY_PANELS := [
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


func pass_marker() -> String:
	return "ATLAS_UI_TEST_PASS"


func run_contracts() -> void:
	var deck: Variant = main.workspace
	var ready := true
	for method: String in REQUIRED_METHODS:
		check(deck.has_method(method), "required Atlas deck API: " + method)
		ready = ready and deck.has_method(method)
	for key: String in ["resources", "status", "session", "performance"]:
		check(WorkspaceLayout.PANEL_NAMES.has(key), "panel registry includes " + key)
		ready = ready and WorkspaceLayout.PANEL_NAMES.has(key)
	if not ready:
		return
	await _readonly_contracts(deck)
	await _geometry_contracts(deck)
	await _command_contracts(deck)
	await _state_contracts(deck)
	await _keyboard_contracts(deck)
	await _workspace_contracts(deck)
	await _save_failure_contracts(deck)
	await _restart_performance_contracts(deck)
	await _settings_contracts(deck)
	await _diagnostics_shortcut_contracts(deck)
	await _footer_contracts(deck)
	_migration_contracts()
	# Restore the requested composition so captures show no test side effects.
	deck.switch_workspace(_workspace)
	deck.revert_workspace()
	deck.close_command()
	main.configure_diagnostics(_workspace == "diagnostics", false, false)
	if _command and not _settings:
		deck.open_command(true)
	_park_pointer()
	await settle()


## Test only built-in designs. User-positioned overlapping windows are legal.
func _readonly_contracts(deck: Variant) -> void:
	var original_workspaces: Dictionary = deck.model.workspaces.duplicate(true)
	var original_saved: Dictionary = deck.model.saved_workspaces.duplicate(true)
	var original_active: String = deck.model.active
	var original_compact_panel: String = deck._compact_panel
	var original_scale: float = get_window().content_scale_factor
	for preset: String in ["daily", "diagnostics"]:
		deck.model.workspaces = WorkspaceLayout.defaults()
		deck.model.saved_workspaces = deck.model.workspaces.duplicate(true)
		deck.model.active = preset
		deck._compact_panel = ""
		deck.close_command()
		deck._rebuild_navigation()
		deck._apply_layout()
		_park_pointer(true)
		await settle()
		_readonly_painted_checks(deck, preset + "/default")
		if deck.compact:
			# Every authorized regular body can occupy the compact slot. Keep the
			# defaults' micro panels, but isolate each subject from other bodies.
			for key: String in deck.windows:
				if key in MICRO_PANELS or not deck.authorized.get(key, false):
					continue
				for other: String in deck.windows:
					if other not in MICRO_PANELS:
						deck.set_panel_state(other, "closed")
				deck.open_command(true)
				deck.reveal_panel(key)
				deck.close_command()
				await settle()
				check(
					deck.windows[key].is_visible_in_tree(),
					preset + ": compact reveal reaches " + key
				)
				_readonly_painted_checks(deck, preset + "/reveal/" + key)
				deck.set_panel_state(key, "collapsed")
				deck.focus_panel(key)
				await settle()
				check(
					deck.windows[key].is_visible_in_tree() and deck.windows[key].collapsed,
					preset + ": compact selected collapsed tab reachable: " + key
				)
				_readonly_painted_checks(deck, preset + "/collapsed/" + key)
		# Pure viewport/scale adaptation must not write responsive geometry back
		# into either normalized rectangles or their default design anchors.
		var geometry: Dictionary = deck.model.workspaces.duplicate(true)
		for budget: Array in [
			[Vector2i(1440, 900), 1.0], [Vector2i(360, 480), 1.5], [_screen, original_scale]
		]:
			get_window().size = budget[0]
			get_window().content_scale_factor = budget[1]
			await settle()
			check(
				main.map.get_global_rect().is_equal_approx(deck.area.get_global_rect()),
				preset + ": viewport/scale adaptation retains full map"
			)
			for id: String in geometry:
				for key: String in geometry[id].panels:
					var before: Dictionary = geometry[id].panels[key]
					var after: Dictionary = deck.model.workspaces[id].panels[key]
					check(
						after.rect == before.rect and after.get("design") == before.get("design"),
						(
							preset
							+ ": responsive adaptation preserves normalized/design geometry: "
							+ id
							+ "/"
							+ key
						)
					)
	deck.model.workspaces = original_workspaces
	deck.model.saved_workspaces = original_saved
	deck.model.active = original_active
	deck._compact_panel = original_compact_panel
	deck._rebuild_navigation()
	deck._apply_layout()
	await settle()


func _painted_rects(window: Variant) -> Array[Rect2]:
	var painted: Array[Rect2] = []
	if not window.is_visible_in_tree():
		return painted
	# A tab does not paint the empty full-width frame beside it. Include the
	# separate hovered control ground only when it is actually painted.
	for ground: Control in [window.header_ground, window._body_ground, window._control_ground]:
		if ground.is_visible_in_tree():
			var rect := _unclipped_rect(ground)
			if rect.has_area():
				painted.append(rect)
	return painted


func _unclipped_rect(control: Control) -> Rect2:
	var rect := control.get_global_rect().intersection(get_viewport().get_visible_rect())
	var parent := control.get_parent()
	while parent != null:
		if parent is Control and parent.clip_contents:
			rect = rect.intersection(parent.get_global_rect())
		parent = parent.get_parent()
	return rect


func _readonly_painted_checks(deck: Variant, context: String) -> void:
	check(
		not deck.is_command_open(),
		context + ": readonly check excludes intentional Command overlay"
	)
	var keys: Array[String] = []
	var regular := 0
	for key: String in deck.windows:
		if deck.windows[key].is_visible_in_tree():
			keys.append(key)
			if key not in MICRO_PANELS:
				regular += 1
	if deck.compact:
		check(regular == 1, context + ": exactly one reachable compact regular slot")
	for index in keys.size():
		for other_index in range(index + 1, keys.size()):
			for a: Rect2 in _painted_rects(deck.windows[keys[index]]):
				for b: Rect2 in _painted_rects(deck.windows[keys[other_index]]):
					var overlap := a.intersection(b)
					check(
						overlap.size.x <= 0.01 or overlap.size.y <= 0.01,
						(
							"%s: default painted panels disjoint %s/%s overlap=%s"
							% [context, keys[index], keys[other_index], overlap]
						)
					)
	for label: Label in [main._clock, main._population]:
		check(
			(
				not label.text.strip_edges().is_empty()
				and label.is_visible_in_tree()
				and label.get_visible_line_count() > 0
			),
			context + ": meaningful clock/crew text visible"
		)
		_check_readonly_field(deck, "status", label, context + "/clock-crew")
	for key: String in keys:
		if key in MICRO_PANELS:
			continue
		var window: Variant = deck.windows[key]
		for label: Label in window.titlebar.find_children("*", "Label", true, false):
			if label.is_visible_in_tree() and not label.text.strip_edges().is_empty():
				check(
					label.get_visible_line_count() > 0,
					context + ": regular heading has visible text: " + key
				)
				_check_readonly_field(deck, key, label, context + "/heading")
		if window.collapsed:
			continue
		if key == "trends":
			# HistoryChart paints its observed rows directly, not with Labels.
			check(
				(
					main._history_chart.is_visible_in_tree()
					and not main._history_chart._points.is_empty()
				),
				context + ": real observed Trends data reachable"
			)
			_check_readonly_field(
				deck, key, main._history_chart, context + "/first-chart-row", 36.0
			)
			continue
		var first: Label = null
		for label: Label in window.content.find_children("*", "Label", true, false):
			if (
				label.is_visible_in_tree()
				and not label.text.strip_edges().is_empty()
				and _unclipped_rect(label).has_area()
			):
				if first == null or label.global_position.y < first.global_position.y:
					first = label
		check(first != null, context + ": first data field reachable in " + key)
		if first != null:
			_check_readonly_field(deck, key, first, context + "/first-row")


func _check_readonly_field(
	deck: Variant, key: String, field: Control, context: String, first_row_height := 0.0
) -> void:
	var rect := field.get_global_rect()
	if first_row_height > 0:
		rect.size.y = minf(rect.size.y, first_row_height)
	check(
		rect.has_area() and _unclipped_rect(field).grow(1).encloses(rect),
		context + ": field is not clipped in " + key
	)
	var owned := false
	for painted: Rect2 in _painted_rects(deck.windows[key]):
		owned = owned or painted.grow(1).encloses(rect)
	check(owned, context + ": field enclosed by owned painted surface: " + key)
	for other: String in deck.windows:
		if other == key:
			continue
		for painted: Rect2 in _painted_rects(deck.windows[other]):
			var overlap := rect.intersection(painted)
			check(
				overlap.size.x <= 0.01 or overlap.size.y <= 0.01,
				"%s: %s field unobscured by %s overlap=%s" % [context, key, other, overlap]
			)


func _geometry_contracts(deck: Variant) -> void:
	check(
		main.map.get_global_rect() == deck.area.get_global_rect(),
		"map equals complete overlay area"
	)
	var viewport := get_viewport().get_visible_rect()
	var map_rect: Rect2 = main.map.get_global_rect()
	check(
		(
			map_rect.position.distance_to(viewport.position) <= 1.0
			and map_rect.size.distance_to(viewport.size) <= 1.0
		),
		"map fills viewport: no header reservation (within one logical pixel of layout rounding)"
	)
	check(
		is_equal_approx(get_window().content_scale_factor, _scale / 100.0), "single viewport scale"
	)
	deck.switch_workspace("diagnostics")
	await settle()
	var bounds: Rect2 = deck.area.get_global_rect()
	for key: String in deck.windows:
		var window: Variant = deck.windows[key]
		if window.is_visible_in_tree():
			check(
				bounds.grow(1).encloses(window.get_global_rect()),
				"bounded overlay at current scale: " + key
			)
	for key: String in MICRO_PANELS:
		check(deck.windows.has(key), "actual-main micro window: " + key)
		if not deck.windows.has(key):
			continue
		deck.reveal_panel(key)
		await settle()
		var window: Variant = deck.windows[key]
		if not deck.compact:
			var expected_y := 52.0 if key == "session" else 12.0
			check(
				is_equal_approx(window.position.y, expected_y),
				"diagnostics micro panel top position: " + key
			)
		check(
			is_equal_approx(window.size.y, 30),
			"micro window remains 30 logical pixels, including compact: " + key
		)
	deck.reveal_panel("people")
	await settle()
	var regular: Variant = deck.windows.people
	check(is_equal_approx(regular.chrome_height(), 26), "regular title tab is 26 logical pixels")
	check(regular.size.y > regular.chrome_height(), "regular open panel retains body")
	var allowed := 0
	for key: String in WorkspaceLayout.PANEL_NAMES:
		if deck.authorized.get(key, false):
			allowed += 1
	check(allowed == 13, "operator has 13 authorized panels (15 minus admin/developer)")
	check(not deck.authorized.get("admin", true), "operator cannot see Admin")
	check(not deck.authorized.get("developer", true), "operator cannot see Developer")


func _command_contracts(deck: Variant) -> void:
	deck.open_command(true)
	await settle()
	var card: Variant = deck.get("command_card")
	check(card != null and card is Control, "actual CommandCard is a control")
	if card == null or not card is Control:
		return
	var rect: Rect2 = card.get_global_rect()
	var bounds: Rect2 = deck.area.get_global_rect()
	check(bounds.grow(1).encloses(rect), "Command card stays inside narrow/scaled map")
	check(
		absf(rect.size.x - minf(272, bounds.size.x - 16)) <= 1,
		"Command card width is 272 or bounded"
	)
	check(
		rect.position.distance_to(bounds.position + Vector2(8, 8)) <= 1, "Command card inset is 8"
	)
	var search := _line_edit(card)
	check(search != null, "Command card exposes actual search field")
	if search != null:
		check(get_viewport().gui_get_focus_owner() == search, "keyboard opening focuses search")
		search.text = "colonist"
		search.text_changed.emit(search.text)
		await settle()
		var filtered := _visible_copy(card).to_lower()
		check("colonist" in filtered, "panel filter retains matching roster")
		check(not "tile inspector" in filtered, "panel filter removes nonmatching inspector")
		search.text = ""
		search.text_changed.emit("")
		await settle()
	var copy := _visible_copy(card).to_lower()
	check(
		"workspace" in copy and "diagnostics" in copy,
		"Command card lists workspaces and active diagnostics"
	)
	check("13" in copy, "Command card footer reports authorized panel total")
	for id: String in deck.model.workspaces:
		var workspace_button := card.find_child("Workspace_" + id, true, false) as Button
		check(workspace_button != null, "Command exposes workspace navigation: " + id)
		if workspace_button == null:
			continue
		var title: String = deck.model.workspaces[id].name
		var title_found := false
		for label: Label in workspace_button.find_children("*", "Label", true, false):
			if label.text == title:
				title_found = true
				check(
					label.size.x >= 16 and label.get_visible_line_count() > 0,
					(
						"workspace title has readable rendered geometry: %s size=%s visible_lines=%d"
						% [id, label.size, label.get_visible_line_count()]
					)
				)
				check(
					workspace_button.get_global_rect().grow(1).encloses(label.get_global_rect()),
					"workspace title fits its navigation button: " + id
				)
		check(title_found, "workspace navigation contains its actual title: " + id)
	check(
		not "developer" in copy and not "admin" in copy, "Command card omits unauthorized entries"
	)
	for action: String in ["Since you left", "Settings", "Servers", "Disconnect"]:
		var button := find_button(card, action)
		check(button != null, "Command footer exposes " + action)
		if button != null:
			check(
				(
					rect.grow(1).encloses(button.get_global_rect())
					and bounds.grow(1).encloses(button.get_global_rect())
				),
				"Command footer route remains bounded and reachable: " + action
			)
	check(main._map_input_blocked(rect.get_center()), "Command card hit area blocks map input")
	var selections := [0]
	var selected := func(_rect: Rect2i) -> void: selections[0] += 1
	main.map.rectangle_selected.connect(selected)
	await _click(rect.position + Vector2(20, 12))
	check(
		selections[0] == 0 and not main.map._dragging, "native Command click does not leak to map"
	)
	main.map.rectangle_selected.disconnect(selected)
	deck.close_command()
	await settle()
	check(not deck.is_command_open(), "Command close hides card")


func _state_contracts(deck: Variant) -> void:
	deck.switch_workspace("daily")
	deck.save_workspace()
	check(not deck.is_layout_dirty(), "explicit save establishes clean baseline")
	var before: Dictionary = deck.state("people").duplicate(true)
	if deck.compact:
		# Compact has one regular-panel slot and prioritizes expanded panels. Isolate
		# this ternary-state subject; independent micro panels remain available.
		for key: String in deck.windows:
			if key != "people" and key not in MICRO_PANELS:
				deck.set_panel_state(key, "closed")
	deck.set_panel_state("people", "closed")
	await settle()
	check(not deck.windows.people.visible, "closed state removes window")
	deck.set_panel_state("people", "collapsed")
	await settle()
	check(
		deck.windows.people.visible and deck.windows.people.collapsed,
		"collapsed state keeps title tab"
	)
	check(
		is_equal_approx(deck.windows.people.size.y, 26),
		"collapsed regular panel has only its 26px tab"
	)
	var dimensions: Array = deck.state("people").rect.slice(2)
	var window: Variant = deck.windows.people
	deck.state("people").pinned = false
	deck._apply_layout()
	await settle()
	var origin: Vector2 = window.position
	if not deck.compact:
		await _drag(window.titlebar.global_position + Vector2(50, 12), Vector2(20, 30))
		check(window.position.distance_to(origin) > 1, "collapsed header really drags")
	check(
		deck.state("people").rect.slice(2) == dimensions,
		"collapsed drag preserves expanded dimensions"
	)
	deck.state("people").pinned = true
	deck._apply_layout()
	await settle()
	origin = window.position
	await _drag(window.titlebar.global_position + Vector2(50, 12), Vector2(20, 20))
	check(window.position == origin and not window.grip.visible, "pin locks dragging and resizing")
	deck._changed()
	check(deck.is_layout_dirty(), "rect/state/pin edits are dirty")
	check(deck.model.load_from(deck._save_path), "autosaved current workspace reloads")
	deck._apply_layout()
	await settle()
	check(deck.is_layout_dirty(), "saved baseline stays distinct from autosaved edits after reload")
	deck.revert_workspace()
	await settle()
	check(
		_normalized_rect_equal(deck.state("people").rect, before.rect, "revert/people"),
		"revert restores saved rectangle"
	)
	check(deck.state("people").open == before.open, "revert restores saved open state")
	check(
		deck.state("people").get("minimized", false) == before.get("minimized", false),
		"revert restores saved collapsed state"
	)
	check(deck.state("people").pinned == before.pinned, "revert restores saved pin")
	check(not deck.is_layout_dirty(), "revert clears layout dirty state")
	deck.reveal_panel("people")
	deck.save_workspace()
	deck.focus_panel("people")
	deck.windows.people.move_to_front()
	check(not deck.is_layout_dirty(), "focus and transient z-order are not layout edits")
	for key: String in MICRO_PANELS:
		deck.reveal_panel(key)
		await settle()
		var micro: Variant = deck.windows[key]
		var dimensions_before: Array = deck.state(key).rect.slice(2)
		deck.set_panel_state(key, "collapsed")
		await settle()
		deck.set_panel_state(key, "open")
		await settle()
		check(
			micro.size.is_equal_approx(micro.micro_size().min(deck.area.size)),
			(
				"micro reopen uses current natural content dimensions, not viewport: %s actual=%s expected=%s"
				% [key, micro.size, micro.micro_size().min(deck.area.size)]
			)
		)
		check(
			deck.state(key).rect.slice(2) == dimensions_before,
			"micro reopen preserves expanded saved dimensions: " + key
		)
	deck.revert_workspace()


func _keyboard_contracts(deck: Variant) -> void:
	deck.close_command()
	await _key(KEY_K, true)
	check(deck.is_command_open(), "Ctrl+K opens Command card")
	var card: Variant = deck.get("command_card")
	var search: LineEdit = _line_edit(card) if card != null else null
	if search != null:
		search.grab_focus()
		await _key(KEY_K, true)
		check(
			not deck.is_command_open(), "Ctrl+K closes Command while its LineEdit already has focus"
		)
		await _key(KEY_K, true)
		check(deck.is_command_open(), "Ctrl+K reopens Command and focuses search")
		search.grab_focus()
		var mode: StringName = main.map.interaction_mode
		await _key(KEY_B)
		await _key(KEY_E)
		check(main.map.interaction_mode == mode, "letter map shortcuts are ignored while typing")
	main._set_mode(&"excavate")
	await _key(KEY_ESCAPE)
	check(not deck.is_command_open(), "Esc dismisses Command before map/menu actions")
	check(not main._menu.visible, "Command Escape does not simultaneously open menu")
	check(
		main.map.interaction_mode == &"excavate", "first Escape leaves underlying map intent intact"
	)
	await _key(KEY_ESCAPE)
	check(main.map.interaction_mode == &"select", "next Escape cancels map intent")
	for index in 4:
		await _key(KEY_1 + index, false, true)
		check(
			deck.model.active == ["daily", "build", "welfare", "diagnostics"][index],
			"Alt+%d selects preset" % (index + 1)
		)
	main._set_permissions("admin", true, true)
	var profile: String = main._profile
	main._profile = ContinuumClientProfile.DEVELOPER
	main._refresh_permissions()
	deck.set_panel_state("admin", "closed")
	deck.set_panel_state("developer", "closed")
	await _key(KEY_F9)
	check(
		deck.windows.admin.visible and not deck.windows.developer.visible,
		"legacy F9 targets Admin, not new panels"
	)
	await _key(KEY_F10)
	check(deck.windows.developer.visible, "legacy F10 targets Developer")
	main._profile = profile
	main._set_permissions("operator", true, false)
	await _key(KEY_F9)
	await _key(KEY_F10)
	check(
		not deck.windows.admin.visible and not deck.windows.developer.visible,
		"legacy shortcuts respect authorization"
	)


func _workspace_contracts(deck: Variant) -> void:
	var backup := "user://atlas_fixture_before_workspace_tests.json"
	deck.model.save_to(backup)
	deck.switch_workspace("daily")
	deck.edit_workspace(false)
	await settle()
	var dialog: Variant = deck.get("_dialog")
	var editor: LineEdit = _line_edit(dialog) if dialog != null else null
	check(editor != null and editor.editable, "built-in workspace Rename has editable name")
	if editor != null and editor.editable:
		editor.text = "Renamed fixture daily"
		dialog.confirmed.emit()
		await settle()
		check(
			deck.model.workspaces.daily.name == "Renamed fixture daily",
			"actual Rename updates built-in workspace"
		)
	if dialog != null:
		dialog.hide()
	var renamed: String = deck.model.workspaces.daily.name
	var saved_panels: Dictionary = deck.model.saved_workspaces.daily.panels.duplicate(true)
	deck.set_panel_state("resources", "closed" if deck.state("resources").open else "open")
	await settle()
	check(deck.is_layout_dirty(), "panel edit after Rename is dirty")
	deck.revert_workspace()
	await settle()
	check(deck.model.workspaces.daily.name == renamed, "Rename survives panel edit and Revert")
	check(
		_json_layout_equal(
			deck.model.workspaces.daily.panels, saved_panels, "rename/revert/panels"
		),
		"Revert after Rename restores saved panels"
	)
	check(not deck.is_layout_dirty(), "Revert after Rename restores clean panel baseline")
	var count: int = deck.model.workspaces.size()
	deck.duplicate_workspace()
	await settle()
	check(deck.model.workspaces.size() == count + 1, "Duplicate creates a workspace")
	deck.switch_workspace("daily")
	deck.delete_workspace()
	await settle()
	var confirmation: Variant = deck.get("_confirmation")
	if is_instance_valid(confirmation) and confirmation.visible:
		confirmation.confirmed.emit()
		await settle()
	check(not deck.model.workspaces.has("daily"), "Delete permits removal of a built-in preset")
	var deleted_path := "user://atlas_fixture_deleted_preset.json"
	deck.model.save_to(deleted_path)
	var reload := WorkspaceLayout.new()
	check(reload.load_from(deleted_path), "v4 layout with deleted preset reloads")
	check(
		not reload.workspaces.has("daily"),
		"deleted built-in preset does not resurrect on v4 reload"
	)
	# Exercise the last-workspace guard on the isolated model, then the real card.
	for id: String in reload.workspaces.keys():
		if reload.workspaces.size() > 1:
			check(
				reload.remove_workspace(id),
				"model permits removing any preset while another survives"
			)
	var last: String = reload.workspaces.keys()[0]
	check(not reload.remove_workspace(last), "model rejects deleting the last workspace")
	deck.model.workspaces = reload.workspaces.duplicate(true)
	deck.model.active = last
	deck._rebuild_navigation()
	deck._apply_layout()
	deck.open_command(false)
	await settle()
	var card: Variant = deck.get("command_card")
	card.refresh()
	var delete := find_button(card, "Delete")
	check(delete != null and delete.disabled, "Command Delete is disabled for the last workspace")
	deck.delete_workspace()
	await settle()
	check(deck.model.workspaces.size() == 1, "deck refuses last-workspace deletion")
	deck.close_command()
	deck.model.load_from(backup)
	deck._rebuild_navigation()
	deck._apply_layout()
	await settle()


func _save_failure_contracts(deck: Variant) -> void:
	var backup := "user://atlas_before_io_failure.json"
	check(deck.model.save_to(backup) == OK, "save failure test backs up preferences")
	var original_path: String = deck._save_path
	var collision := "user://atlas_save_collision_%d.json" % Time.get_ticks_usec()
	# Collision at the atomic temporary-file path forces real FileAccess failure,
	# without permissions assumptions, production seams, or expected engine errors.
	var directory := ProjectSettings.globalize_path(collision + ".tmp")
	check(DirAccess.make_dir_absolute(directory) == OK, "create isolated Save I/O collision")
	deck.save_workspace()
	var active: String = deck.model.active
	var baseline: Dictionary = deck.model.saved_workspaces[active].duplicate(true)
	deck._save_path = collision
	var opened: bool = deck.state("resources").open
	deck.set_panel_state("resources", "closed" if opened else "open")
	await settle()
	check(deck.is_layout_dirty(), "I/O failure panel edit starts dirty")
	deck.save_workspace()
	await settle()
	check(
		_json_layout_equal(deck.model.saved_workspaces[active], baseline, "failed-save/baseline"),
		"failed Save I/O preserves previous baseline"
	)
	check(deck.is_layout_dirty(), "failed Save I/O leaves edited layout dirty")
	var preference_error: Variant = deck.get("preference_error")
	check(
		preference_error is String and not preference_error.is_empty(),
		"failed Save I/O exposes preference_error"
	)
	deck.open_command(true)
	await settle()
	var copy := _visible_copy(deck.command_card).to_lower()
	check(
		"fail" in copy or "error" in copy or "could not" in copy,
		"failed Save I/O is visible in Command footer"
	)
	deck.close_command()
	deck._save_path = original_path
	check(DirAccess.remove_absolute(directory) == OK, "remove isolated Save I/O collision")
	check(deck.model.load_from(backup), "restore preferences after failed Save")
	deck._rebuild_navigation()
	deck._apply_layout()
	deck.save_layout()
	DirAccess.remove_absolute(ProjectSettings.globalize_path(backup))
	await settle()


func _restart_performance_contracts(deck: Variant) -> void:
	var backup := "user://atlas_before_restart.json"
	check(deck.model.save_to(backup) == OK, "restart test backs up preferences")
	var original_path: String = deck._save_path
	var path := "user://atlas_restart_%d.json" % Time.get_ticks_usec()
	var settings_path := path + ".cfg"
	deck._save_path = path
	deck.set_panel_state("performance", "open")
	deck.save_workspace()
	await settle()
	check(
		deck.state("performance").open and not deck.is_layout_dirty(),
		"saved Performance starts open and clean"
	)
	var settings: ClientSettings = main._settings.clone()
	settings.diagnostics_enabled = false
	settings.diagnostics_graph_enabled = false
	check(
		settings.save_to(settings_path) == OK,
		"restart persists global diagnostics false independently"
	)
	var persisted := ClientSettings.new()
	check(
		persisted.load_from(settings_path) == "loaded" and not persisted.diagnostics_enabled,
		"restart input file contains global diagnostics false"
	)
	var restarted: Variant = MainScene.instantiate()
	restarted.fixture_workspace_path = path
	restarted.fixture_settings_path = settings_path
	main.hide()
	add_child(restarted)
	restarted._server_management.probes.transport = _fixture_probe
	await settle()
	check(
		restarted._settings.diagnostics_enabled == restarted.workspace.state("performance").open,
		"actual main restart reconciles diagnostics to authoritative saved Performance state"
	)
	check(
		restarted.workspace.state("performance").open,
		"actual main startup preserves saved Performance Open with diagnostics false"
	)
	check(
		not restarted.workspace.is_layout_dirty(),
		"actual main startup preserves clean saved Performance baseline"
	)
	check(restarted.forbidden_connections == 0, "restart fixture requests no SDK connection")
	restarted.queue_free()
	await settle()
	main.show()
	deck._save_path = original_path
	check(deck.model.load_from(backup), "restore preferences after restart")
	deck._rebuild_navigation()
	deck._apply_layout()
	deck.save_layout()
	for file: String in [backup, path, settings_path]:
		DirAccess.remove_absolute(ProjectSettings.globalize_path(file))
	await settle()


func _migration_contracts() -> void:
	var path := "user://atlas_fixture_v3.json"
	var legacy := {}
	for key: String in LEGACY_PANELS:
		legacy[key] = {
			"rect": [0.12, 0.23, 0.34, 0.45],
			"open": true,
			"minimized": true,
			"pinned": true,
			"z": 7
		}
	var file := FileAccess.open(path, FileAccess.WRITE)
	file.store_string(
		JSON.stringify(
			{
				"version": 3,
				"active": "custom_legacy",
				"show_panel_headers": false,
				"workspaces": {"custom_legacy": {"name": "Legacy custom", "panels": legacy}}
			}
		)
	)
	file.close()
	var model := WorkspaceLayout.new()
	check(model.load_from(path), "v3 layout migration succeeds")
	check(
		model.active == "custom_legacy" and model.workspaces.has("custom_legacy"),
		"v3 custom workspace survives"
	)
	if not model.workspaces.has("custom_legacy"):
		return
	for key: String in LEGACY_PANELS:
		var state: Dictionary = model.workspaces.custom_legacy.panels[key]
		check(
			state.rect == legacy[key].rect and state.open and state.pinned,
			"v3 preserves rect/open/pin: " + key
		)
		check(
			state.get("collapsed", state.get("minimized", false)),
			"v3 preserves collapsed state: " + key
		)
	for key: String in ["resources", "status", "session", "performance"]:
		check(model.workspaces.custom_legacy.panels.has(key), "v3 adds new panel default: " + key)
	check(not model.show_panel_headers, "v3 retains personal header preference")
	check(model.save_to(path) == OK, "migrated layout saves")
	var saved: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
	check(saved is Dictionary and saved.get("version") == 4, "migrated layout writes v4")
	var reload := WorkspaceLayout.new()
	check(reload.load_from(path), "v4 round-trip loads")
	check(
		_json_layout_equal(
			reload.workspaces.custom_legacy, model.workspaces.custom_legacy, "v4/custom_legacy"
		),
		"v4 round-trip loses no panel preferences"
	)


## JSON may move a normalized coordinate by machine epsilon. A 1e-6 tolerance
## is under 0.003 physical px at the tested budgets, not a layout-error allowance.
func _normalized_rect_equal(actual: Array, expected: Array, context: String) -> bool:
	if actual.size() != expected.size():
		return false
	var equal := true
	for axis in actual.size():
		var delta := absf(float(actual[axis]) - float(expected[axis]))
		if delta > 0:
			print(
				(
					"ATLAS_JSON_RECT_DELTA %s axis=%d actual=%.17f expected=%.17f delta_x1e18=%.6f tolerance=%.7f"
					% [
						context,
						axis,
						float(actual[axis]),
						float(expected[axis]),
						delta * 1e18,
						NORMALIZED_RECT_EPSILON
					]
				)
			)
		equal = equal and delta <= NORMALIZED_RECT_EPSILON
	return equal


func _json_layout_equal(actual: Variant, expected: Variant, context: String) -> bool:
	if actual is Dictionary and expected is Dictionary:
		if actual.size() != expected.size():
			return false
		var equal := true
		for key: String in expected:
			if not actual.has(key):
				return false
			equal = _json_layout_equal(actual[key], expected[key], context + "/" + key) and equal
		return equal
	if actual is Array and expected is Array and context.ends_with("/rect"):
		return _normalized_rect_equal(actual, expected, context)
	return actual == expected


func _settings_contracts(deck: Variant) -> void:
	await show_settings()
	var copy := _visible_copy(main).to_lower()
	check("ui scale" in copy, "Settings opens actual preference controls")
	var center: Vector2 = main.map.get_global_rect().get_center()
	check(main._map_input_blocked(center), "Settings modal blocks background map input")
	var mode: StringName = main.map.interaction_mode
	await _key(KEY_B)
	check(main.map.interaction_mode == mode, "Settings keyboard input cannot trigger map letters")
	await _key(KEY_ESCAPE)
	check(
		not "ui scale" in _visible_copy(main).to_lower(),
		"Escape dismisses Settings before background actions"
	)
	deck.close_command()
	await settle()


func _diagnostics_shortcut_contracts(deck: Variant) -> void:
	var now := Time.get_ticks_usec()
	main._diagnostics_stats.reset()
	main._diagnostics_stats.observe_tick(now)
	main._diagnostics_stats.observe_tick(now + 16000)
	check(
		main._diagnostics_stats.refresh(now + 16000, true).count == 1,
		"actual main diagnostics retain monotonic frame samples"
	)
	main._notification(NOTIFICATION_APPLICATION_FOCUS_OUT)
	check(
		main._diagnostics_stats.refresh(now + 16000, true).count == 0,
		"actual main focus loss resets diagnostic samples"
	)
	main._notification(NOTIFICATION_APPLICATION_FOCUS_IN)
	main.configure_diagnostics(false, false, false)
	deck.close_command()
	await _key(KEY_F8)
	check(main._settings.diagnostics_enabled, "F8 toggles Performance when colony input is active")
	main.configure_diagnostics(false, false, false)
	for context: String in ["text", "menu", "servers", "digest"]:
		if context == "text":
			deck.open_command(true)
		elif context == "menu":
			main._menu.show_menu()
		elif context == "servers":
			main._show_server_management()
		else:
			main._show_away_digest()
		main._sync_menu_input()
		await settle()
		await _key(KEY_F8)
		check(not main._settings.diagnostics_enabled, "F8 has no effect with " + context + " input")
		main.configure_diagnostics(false, false, false)
		if context == "text":
			deck.close_command()
		elif context == "menu":
			main._on_menu_resume_requested()
		elif context == "servers":
			main._hide_server_management()
			main._on_menu_resume_requested()
		else:
			main._hide_away_digest()
		main._sync_menu_input()
		await settle()
	deck.open_command(false)
	await _card_panel_click(deck, "performance", "Open")
	check(
		main._settings.diagnostics_enabled,
		"Command Performance Open enables diagnostics preference"
	)
	check(
		main._menu._diagnostics_toggle.button_pressed,
		"Command Performance Open updates Settings checkbox"
	)
	await _card_panel_click(deck, "performance", "Closed")
	check(
		not main._settings.diagnostics_enabled,
		"Command Performance Close disables diagnostics preference"
	)
	check(
		not main._menu._diagnostics_toggle.button_pressed,
		"Command Performance Close updates Settings checkbox"
	)
	await show_settings()
	main._menu._diagnostics_toggle.set_pressed(true)
	await settle()
	check(deck.state("performance").open, "Settings diagnostics checkbox opens Performance panel")
	main._menu._diagnostics_toggle.set_pressed(false)
	await settle()
	check(
		not deck.state("performance").open, "Settings diagnostics checkbox closes Performance panel"
	)
	await _key(KEY_ESCAPE)
	main._sync_menu_input()
	deck.close_command()


func _card_panel_click(deck: Variant, key: String, state: String) -> void:
	var card: Control = deck.command_card
	var row := card.find_child("Panel_" + key, true, false)
	check(row != null, "Command has actual panel row: " + key)
	if row == null:
		return
	var button := row.find_child(state, true, false) as Button
	check(button != null, "Command exposes actual state segment: " + state)
	if button == null:
		return
	var scroll := card.find_child("CommandBodyScroll", true, false) as ScrollContainer
	scroll.ensure_control_visible(button)
	await settle()
	check(
		scroll.get_global_rect().grow(1).encloses(button.get_global_rect()),
		"panel segment is reachable through Command scroll"
	)
	await _click(button.get_global_rect().get_center())
	await settle()


func _footer_contracts(deck: Variant) -> void:
	for action: String in ["Since you left", "Settings", "Servers"]:
		deck.open_command(false)
		await settle()
		var button := find_button(deck.command_card, action)
		check(button != null, "actual footer action available: " + action)
		if button == null:
			continue
		await _click(button.get_global_rect().get_center())
		await settle()
		check(not deck.is_command_open(), "footer route closes Command: " + action)
		if action == "Since you left":
			check(main._digest_overlay.visible, "footer reaches actual away digest")
			main._hide_away_digest()
		elif action == "Settings":
			check(
				main._menu.visible and main._menu._settings_panel.visible,
				"footer reaches actual Settings modal"
			)
			await _key(KEY_ESCAPE)
		else:
			check(
				main._server_management.visible,
				"footer reaches actual server browser with disabled probe transport"
			)
			main._hide_server_management()
			main._on_menu_resume_requested()
		main._sync_menu_input()
		await settle()
	# Disconnect is reachable but not dispatched: the fixture keeps its typed world.
	deck.open_command(false)
	await settle()
	var disconnect := find_button(deck.command_card, "Disconnect")
	if disconnect != null:
		disconnect.grab_focus()
		check(
			get_viewport().gui_get_focus_owner() == disconnect,
			"Disconnect route remains keyboard reachable at narrow scale"
		)
	deck.close_command()


func _line_edit(node: Node) -> LineEdit:
	if node is LineEdit:
		return node
	for child: Node in node.get_children():
		var found := _line_edit(child)
		if found != null:
			return found
	return null


func _visible_copy(node: Node) -> String:
	if node is Control and not node.is_visible_in_tree():
		return ""
	var result := ""
	if node is Label or node is Button:
		result = node.text + "\n"
	for child: Node in node.get_children():
		result += _visible_copy(child)
	return result


func _key(code: int, ctrl := false, alt := false) -> void:
	for pressed: bool in [true, false]:
		var event := InputEventKey.new()
		event.keycode = code
		event.physical_keycode = code
		event.pressed = pressed
		event.ctrl_pressed = ctrl
		event.alt_pressed = alt
		Input.parse_input_event(event)
		await get_tree().process_frame
	await settle()


func _click(point: Vector2) -> void:
	await _pointer(true, point)
	await _pointer(false, point)


func _drag(point: Vector2, delta: Vector2) -> void:
	await _pointer(true, point)
	var motion := InputEventMouseMotion.new()
	motion.position = get_viewport().get_final_transform() * (point + delta)
	motion.global_position = motion.position
	motion.relative = get_viewport().get_final_transform().basis_xform(delta)
	motion.button_mask = MOUSE_BUTTON_MASK_LEFT
	motion.alt_pressed = true
	Input.parse_input_event(motion)
	await get_tree().process_frame
	await _pointer(false, point + delta)
	await settle()


func _pointer(pressed: bool, point: Vector2) -> void:
	var event := InputEventMouseButton.new()
	event.button_index = MOUSE_BUTTON_LEFT
	event.pressed = pressed
	event.position = get_viewport().get_final_transform() * point
	event.global_position = event.position
	Input.parse_input_event(event)
	await get_tree().process_frame
	await get_tree().process_frame
