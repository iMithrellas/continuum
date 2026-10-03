## Attach to the parent's full-screen UI layer. No fabricated progress or timers.
class_name WorldLoadingOverlay
extends PanelContainer

var state: WorldLoadingState
var _phase := Label.new()
var _counts := Label.new()
var _progress := ProgressBar.new()
var _cancel := Button.new()

func attach(parent: Control, loading: WorldLoadingState) -> void:
	state = loading
	parent.add_child(self)
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_STOP
	var style := StyleBoxFlat.new()
	style.bg_color = ThemeTokens.color("bg-100")
	add_theme_stylebox_override("panel", style)
	var centre := CenterContainer.new()
	add_child(centre)
	var column := VBoxContainer.new()
	column.custom_minimum_size.x = 320
	column.add_theme_constant_override("separation", int(ThemeTokens.number("space-4")))
	centre.add_child(column)
	for control in [_phase, _counts, _progress, _cancel]:
		column.add_child(control)
	_phase.add_theme_color_override("font_color", ThemeTokens.color("ink"))
	_counts.add_theme_color_override("font_color", ThemeTokens.color("ink-muted"))
	_progress.show_percentage = false
	_cancel.text = "Disconnect"
	_cancel.pressed.connect(state.disconnect_current)
	state.changed.connect(refresh)
	refresh()

func refresh() -> void:
	var was_visible := visible
	visible = not state.playable and state.client != null
	if visible and not was_visible:
		_cancel.grab_focus()
	_phase.text = state.error if not state.error.is_empty() else state.phase
	var fraction := state.progress_fraction()
	_progress.visible = fraction >= 0.0 and state.phase not in ["Loading nearby terrain", "Ready"] and state.error.is_empty()
	_progress.value = fraction * 100.0
	_counts.text = "%d / %d server work units" % [state.completed, state.total] if _progress.visible else ""
