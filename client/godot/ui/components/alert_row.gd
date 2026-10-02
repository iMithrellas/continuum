class_name AlertRow
extends PanelContainer

signal acknowledge_requested(id: Variant)
signal goto_requested(id: Variant)
const Models = preload("models.gd")
const UI = preload("presentation.gd")
var model: Dictionary = {}
var reduced_motion: bool = false
var pending: bool = false
var error_copy: String = ""
var _border: StyleBoxFlat

func _init() -> void:
	set_process(false)

## Required: id, level, title OR raw message, acknowledged (shared bool).
## Optional: detail, target, time_label, ack_handle, ack_time, consequence_game_hours.
func set_model(data: Dictionary) -> void:
	var previous_id: Variant = model.get("id")
	var next_id: Variant = data.get("id")
	if not Models.same_identifier(previous_id, next_id):
		pending = false
		error_copy = ""
	model = Models.alert(data)
	if model.acknowledged == true:
		pending = false
		error_copy = ""
	_render()

## Reducer callback owns pending/error. Neither this nor a click changes shared ack.
func set_acknowledgement_state(is_pending: bool, error: String = "") -> void:
	pending = is_pending
	error_copy = error
	_render()

func set_reduced_motion(enabled: bool) -> void:
	reduced_motion = enabled
	_refresh_motion()

func _render() -> void:
	if model.is_empty():
		return
	UI.clear(self)
	_border = UI.surface("critical-soft" if model.level == "critical" else "bg-100", "critical" if model.level == "critical" else "line-100")
	add_theme_stylebox_override("panel", _border)
	var content = UI.column()
	var head = UI.row()
	head.add_child(UI.glyph(model.level if model.level in ["warn", "critical"] else "notice"))
	head.add_child(UI.wrapped((UI.status_word(model.level) + " · " if model.level in ["warn", "critical"] else "Notice · ") + model.title, "body-strong", "ink"))
	content.add_child(head)
	content.add_child(UI.wrapped(model.time_label, "log", "ink-subtle"))
	if not model.detail.is_empty():
		content.add_child(UI.wrapped(model.detail))
	var foot = UI.column()
	var actions = UI.flow()
	if model.acknowledged == true:
		var acknowledgement = UI.row()
		acknowledgement.add_child(UI.glyph("ack"))
		acknowledgement.add_child(UI.wrapped("Acknowledged", "small"))
		foot.add_child(acknowledgement)
		if not model.ack_handle.is_empty():
			foot.add_child(UI.wrapped("by " + model.ack_handle, "small", "accent"))
		if not model.ack_time.is_empty():
			foot.add_child(UI.wrapped(model.ack_time, "log", "ink-subtle"))
		if model.ack_handle.is_empty() or model.ack_time.is_empty():
			foot.tooltip_text = "Acknowledgement actor or time unavailable"
	elif model.acknowledged == false:
		var ack_copy = "Acknowledge · identifier unavailable" if not model.id_available else "Acknowledge · pending" if pending else "Acknowledge"
		var acknowledge = UI.button(ack_copy, _request_acknowledgement, "")
		acknowledge.disabled = pending or not model.id_available
		actions.add_child(acknowledge)
		foot.add_child(UI.wrapped("Unacknowledged", "small"))
	else:
		foot.add_child(UI.wrapped("Acknowledgement unavailable", "small"))
	var goto_reason = "identifier unavailable" if not model.id_available else "target unavailable" if not model.target_available else ""
	var go_to = UI.button("Go to" + (" · " + goto_reason if not goto_reason.is_empty() else ""), _request_goto)
	go_to.disabled = not goto_reason.is_empty()
	actions.add_child(go_to)
	foot.add_child(actions)
	content.add_child(foot)
	if not error_copy.is_empty():
		content.add_child(UI.wrapped(error_copy))
	add_child(content)
	_refresh_motion()

func _request_acknowledgement() -> void:
	if model.id_available and model.acknowledged == false and not pending:
		acknowledge_requested.emit(model.id)

func _request_goto() -> void:
	if model.id_available and model.target_available:
		goto_requested.emit(model.id)

func _refresh_motion() -> void:
	set_process(not model.is_empty() and model.level == "critical" and model.acknowledged == false and not reduced_motion)
	if _border != null:
		_border.border_color = ThemeTokens.color("critical" if model.get("level") == "critical" else "line-100")

func _process(_delta: float) -> void:
	if _border == null:
		return
	# Time-based shared phase; the one permitted animation, 2.4 seconds exactly.
	var phase = float(Time.get_ticks_msec() % 2400) / 2400.0
	var strength = (1.0 + cos(phase * TAU)) / 2.0
	_border.border_color = ThemeTokens.color("critical-soft").lerp(ThemeTokens.color("critical"), strength)
