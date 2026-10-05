class_name AwayDigest
extends PanelContainer

signal review_requested(ids: Array)
signal dismiss_requested
signal goto_requested(id: Variant)
const Models = preload("models.gd")
const UI = preload("presentation.gd")
const Entry = preload("log_entry.gd")
var model: Dictionary = {}
var _actions: BoxContainer
var _delta_cells: Array[PanelContainer] = []


func _init() -> void:
	resized.connect(_adapt_layout)


## span/coverage copy; deltas [{name,baseline,current,level}]; provided event groups.
## No baselines, events, handles or coverage are manufactured from current state.
func set_model(data: Dictionary) -> void:
	var next := Models.digest(data)
	if next == model:
		return
	var focus_key := ""
	var scroll_value := 0
	if is_inside_tree():
		var focused := get_viewport().gui_get_focus_owner()
		if focused != null and is_ancestor_of(focused):
			focus_key = str(focused.get_meta("digest_focus_key", "back"))
		if get_parent() is ScrollContainer:
			scroll_value = get_parent().scroll_vertical
	model = next
	UI.clear(self)
	_delta_cells.clear()
	theme_type_variation = "PanelFloating"
	# The owning modal controls width, including sub-280px logical viewports.
	custom_minimum_size.x = 0
	var content = UI.column()
	content.add_theme_constant_override("separation", int(ThemeTokens.number("space-6")))
	content.add_child(UI.label("Since you left", "display", "ink"))
	content.add_child(UI.wrapped(model.span, "log"))
	content.add_child(UI.wrapped(model.coverage))
	if model.group_coverage.deltas.status != "complete":
		content.add_child(UI.coverage_notice("Resource baselines", model.group_coverage.deltas))
	if not model.deltas.is_empty():
		var deltas = UI.flow()
		for delta in model.deltas:
			var cell = PanelContainer.new()
			cell.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			_delta_cells.append(cell)
			cell.add_theme_stylebox_override("panel", UI.surface("bg-200"))
			var values = UI.column()
			if delta.level in ["warn", "critical"]:
				values.add_child(UI.glyph(delta.level))
				values.add_child(UI.label(UI.status_word(delta.level), "tag", delta.level))
			values.add_child(
				UI.bounded(delta.name, "section", UI.status_color(delta.level, "ink-subtle"), 64)
			)
			values.add_child(
				UI.wrapped(
					Models.signed(delta.delta), "readout", UI.status_color(delta.level, "ink")
				)
			)
			cell.add_child(values)
			deltas.add_child(cell)
		content.add_child(deltas)
	var needs = UI.column()
	needs.add_child(UI.label("Needs you now · live alerts", "section", "ink-subtle"))
	if model.group_coverage.needs_you.status != "complete":
		needs.add_child(UI.coverage_notice("Needs-you", model.group_coverage.needs_you))
	elif model.needs_you.is_empty():
		needs.add_child(UI.label("Nothing needs you"))
	var ids: Array = []
	for item in model.needs_you:
		var row = UI.row()
		row.add_child(UI.glyph(item.level if item.level in ["warn", "critical"] else "notice"))
		var details = UI.column()
		details.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		details.add_child(
			UI.wrapped(UI.status_word(item.level) + " · " + item.title, "body-strong", "ink")
		)
		if not item.detail.is_empty():
			details.add_child(UI.wrapped(item.detail))
		if item.acknowledged == true:
			var ack = UI.column()
			ack.add_child(UI.glyph("ack"))
			ack.add_child(UI.label("Acknowledged", "small"))
			if not item.ack_handle.is_empty():
				ack.add_child(UI.wrapped(item.ack_handle, "small", "accent"))
			if not item.ack_time.is_empty():
				ack.add_child(UI.wrapped(item.ack_time, "log", "ink-subtle"))
			details.add_child(ack)
		row.add_child(details)
		if item.id_available:
			ids.append(item.id)
		var item_id: Variant = item.get("id")
		var target_available: bool = item.target_available
		var goto_reason = (
			"identifier unavailable"
			if not item.id_available
			else "target unavailable" if not target_available else ""
		)
		var go_to = UI.button(
			"Go to" + (" · " + goto_reason if not goto_reason.is_empty() else ""),
			func():
				if Models.valid_identifier(item_id) and target_available:
					goto_requested.emit(item_id)
		)
		go_to.disabled = not goto_reason.is_empty()
		go_to.set_meta("digest_focus_key", "goto:%s:%s" % [typeof(item_id), item_id])
		details.add_child(go_to)
		needs.add_child(row)
	content.add_child(needs)
	for descriptor in [
		["changed_by_others", "Changed by others"], ["handled", "The colony handled"]
	]:
		var group_coverage: Dictionary = model.group_coverage[descriptor[0]]
		if model[descriptor[0]].is_empty() and group_coverage.status == "complete":
			continue
		var group = UI.column()
		group.add_child(UI.label(descriptor[1], "section", "ink-subtle"))
		if group_coverage.status != "complete":
			group.add_child(UI.coverage_notice(descriptor[1], group_coverage))
		for item in model[descriptor[0]]:
			var entry = Entry.new()
			entry.set_model(item)
			group.add_child(entry)
			if item.get("count") is int and item.count >= 0:
				group.add_child(UI.label(str(item.count) + " events", "readout"))
		content.add_child(group)
	var actions := BoxContainer.new()
	_actions = actions
	actions.add_theme_constant_override("separation", int(ThemeTokens.number("space-2")))
	if not ids.is_empty():
		var review = UI.button(
			"Review available alerts" if ids.size() < model.needs_you.size() else "Review alerts",
			func(): review_requested.emit(ids),
			"ButtonPrimary"
		)
		review.set_meta("digest_focus_key", "review")
		actions.add_child(review)
		actions.add_child(UI.label(str(ids.size()), "readout"))
	elif not model.needs_you.is_empty():
		var review = UI.button(
			"Review alerts · identifiers unavailable", func(): pass, "ButtonPrimary"
		)
		review.disabled = true
		actions.add_child(review)
	var back = UI.button("Back to the colony", func(): dismiss_requested.emit())
	back.set_meta("digest_focus_key", "back")
	actions.add_child(back)
	content.add_child(actions)
	_wrap_content(content)
	add_child(content)
	_adapt_layout()
	if is_inside_tree():
		_restore_view.call_deferred(focus_key, scroll_value)


func _wrap_content(node: Node) -> void:
	# Includes embedded event timestamps, section headings, counts, and localized
	# commands. SMART wrapping breaks oversized tokens rather than widening chrome.
	if node is Label:
		node.custom_minimum_size.x = 0
		node.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		node.clip_text = false
		node.text_overrun_behavior = TextServer.OVERRUN_NO_TRIMMING
		node.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	elif node is Button:
		node.custom_minimum_size.x = 0
		node.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		node.clip_text = false
		node.text_overrun_behavior = TextServer.OVERRUN_NO_TRIMMING
		node.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	for child in node.get_children():
		_wrap_content(child)


func _adapt_layout() -> void:
	if not is_instance_valid(_actions):
		return
	var body_width := size.x - get_theme_stylebox("panel").get_minimum_size().x
	_actions.vertical = body_width < 384
	for cell in _delta_cells:
		# Prefer readable cards, but never impose that width on the owning modal.
		cell.custom_minimum_size.x = minf(96, maxf(0, body_width))


func _find_focus(key: String, node: Node) -> Control:
	if node is Button and node.get_meta("digest_focus_key", "") == key and not node.disabled:
		return node
	for child in node.get_children():
		var found := _find_focus(key, child)
		if found != null:
			return found
	return null


func _restore_view(key: String, value: int, settling_frames := 2) -> void:
	if not is_inside_tree() or not is_visible_in_tree():
		return
	if settling_frames > 0:
		get_tree().create_timer(0.0).timeout.connect(
			_restore_view.bind(key, value, settling_frames - 1), CONNECT_ONE_SHOT
		)
		return
	if not key.is_empty():
		var target := _find_focus(key, self)
		if target == null:
			target = _find_focus("back", self)
		if target != null:
			target.grab_focus()
	if get_parent() is ScrollContainer:
		get_parent().scroll_vertical = value
