## Backend-free production component checks for compact live status and input.
extends SceneTree

const UI = preload("res://ui/components/presentation.gd")
var failures: Array[String] = []
var checks := 0

func _initialize() -> void:
	call_deferred("run")

func check(condition: bool, message: String) -> void:
	checks += 1
	if not condition:
		failures.append(message)
		push_error(message)

func settle() -> void:
	for frame in 4:
		await process_frame

func visible_copy(node: Node) -> String:
	var copy := ""
	for child in node.find_children("*", "Label", true, false):
		copy += child.text + "\n"
	return copy

func pointer(control: Control, press := false) -> void:
	var point := control.get_global_rect().get_center()
	var motion := InputEventMouseMotion.new()
	motion.position = point
	motion.global_position = point
	Input.parse_input_event(motion)
	if press:
		for down in [true, false]:
			var event := InputEventMouseButton.new()
			event.button_index = MOUSE_BUTTON_LEFT
			event.pressed = down
			event.position = point
			event.global_position = point
			Input.parse_input_event(event)
			await process_frame
	await settle()

func run() -> void:
	root.size = Vector2i(800, 600)
	var host := PanelContainer.new()
	host.theme = load("res://ui/theme/theme.tres")
	host.position = Vector2(24, 24)
	host.size = Vector2(280, 1)
	root.add_child(host)
	var meter := NeedMeter.new()
	host.add_child(meter)
	var value_width := 0.0
	var track_width := 0.0
	for value: Variant in [8.123456, 28.75, 100.0, 0.0, null]:
		meter.set_model({"label": "Leisure", "value": value, "trend": "falling", "trend_horizon": "1 game h"})
		await settle()
		check(host.size.x == 280, "fractional, zero and unavailable needs fit the padded minimum panel")
		check(meter.model.value == value, "display precision preserves the original measurement")
		var label: Label = meter.find_child("Value", true, false)
		if value_width == 0.0:
			value_width = label.size.x
			track_width = meter.find_child("Track", true, false).size.x
		check(is_equal_approx(label.size.x, value_width), "live need values retain a stable numeric column")
		check(is_equal_approx(meter.find_child("Track", true, false).size.x, track_width), "severity changes retain a comparable gauge length")
		check(meter.tooltip_text.contains("higher is better") and meter.tooltip_text.contains("1 game h"), "need meaning and provided trend horizon remain discoverable")
		if value == null:
			check(visible_copy(meter).contains("Unavailable") and not visible_copy(meter).contains("Nominal"), "missing needs remain explicitly unavailable")
		elif value < 35:
			check(visible_copy(meter).contains("Critical" if value < 15 else "Warning"), "need bands include a visible word as well as color and glyph")
		for child in meter.find_children("*", "Control", true, false):
			check(host.get_global_rect().encloses(child.get_global_rect()), "need descendants fit without horizontal clipping")
	host.remove_child(meter)
	meter.free()
	var row := RosterRow.new()
	host.add_child(row)
	var data := {"id": 0, "name": "Alexandria", "state": "Working", "job": "Farming", "hunger": 92.0, "fatigue": 20.0, "recreation": 20.0, "mood": 70.0, "productivity": 80.0}
	row.set_model(data)
	var selected: Array = []
	row.selection_requested.connect(func(id): selected.append(id))
	await settle()
	check(row.find_child("ColonistName", true, false).size.x >= 100, "narrow roster gives the name a useful reading width")
	check(row.size.y >= ThemeTokens.number("control-md"), "roster has at least the standard control hit height")
	check(visible_copy(row).contains("Critical"), "compact worst need communicates severity without hovering")
	await pointer(row)
	check(row.get_theme_stylebox("panel").bg_color == ThemeTokens.color("bg-300"), "available roster visibly responds to real pointer hover")
	await pointer(row.find_child("WorstNeed", true, false), true)
	check(selected == [0] and row.has_focus(), "decorative need click selects once and establishes keyboard focus")
	data.hunger = 80.0
	row.set_model(data)
	await settle()
	check(row.has_focus() and visible_copy(row).contains("Warning"), "live severity update keeps roster focus")
	host.size.x = 600
	await settle()
	check(row.has_focus() and row.get_child(0).get_child(0).position.y == row.get_child(0).get_child(1).position.y, "wide roster uses one line without changing focus owner")
	host.size.x = 280
	await settle()
	check(row.has_focus() and row.size.x <= 256, "return to narrow layout preserves focus and fit")
	host.remove_child(row)
	row.free()
	var resource := ResourceReadout.new()
	host.add_child(resource)
	resource.set_model({"name": "Food", "value": 40, "availability": "warming"}, {"compact": true})
	await settle()
	check(visible_copy(resource).contains("Rate warming up"), "compact resources visibly distinguish rate warm-up")
	root.content_scale_size = Vector2i.ZERO
	var warmup_baseline := 0.0
	for scale in [1.0, 1.25, 1.5]:
		root.content_scale_factor = scale
		await settle()
		check(resource.get_combined_minimum_size().y == 44 and resource.size.y == 44, "warm-up resource stays within the intended padded 44px logical budget")
		var bounds := resource.get_global_rect()
		var surface := resource.get_theme_stylebox("panel")
		var insets := Vector2(surface.get_content_margin(SIDE_LEFT), surface.get_content_margin(SIDE_TOP))
		var trailing := Vector2(surface.get_content_margin(SIDE_RIGHT), surface.get_content_margin(SIDE_BOTTOM))
		var content_bounds := Rect2(bounds.position + insets, bounds.size - insets - trailing)
		check(insets.x >= 8 and insets.y >= 4 and trailing.x >= 8 and trailing.y >= 4, "resource readability includes real padding, not just a taller minimum")
		for label: Label in resource.find_children("*", "Label", true, false):
			check(content_bounds.encloses(label.get_global_rect()) and label.get_combined_minimum_size().x <= label.size.x, "resource text fits inside padded content at every UI scale")
		var head: HBoxContainer = resource.get_child(0).get_child(0)
		var rate: Label = resource.get_child(0).get_child(1)
		var stock: Label = head.get_child(1)
		var font := stock.get_theme_font("font")
		var font_size := stock.get_theme_font_size("font_size")
		var baseline := stock.global_position.y - bounds.position.y + (stock.size.y - font.get_height(font_size)) * 0.5 + font.get_ascent(font_size)
		if scale == 1.0: warmup_baseline = baseline
		check(is_equal_approx(baseline, warmup_baseline) and head.get_global_rect().end.y <= rate.global_position.y, "numeric baseline stays stable and warm-up occupies a separate secondary line")
		check(rate.get_theme_color("font_color") != stock.get_theme_color("font_color"), "warm-up remains visually secondary to the stored value")
		var native_rect: Rect2 = root.get_final_transform() * bounds
		check(is_equal_approx(native_rect.size.y, 44 * scale), "native card height applies whole-UI scaling exactly once")
	root.content_scale_factor = 1.0
	resource.set_model({"name": "Food", "value": 40}, {"compact": true, "narrow": true, "show_rate": false})
	await settle()
	check(resource.tooltip_text.contains("Rate unavailable"), "narrow rate suppression retains honest tooltip context")
	host.remove_child(resource)
	resource.free()
	var alert := AlertRow.new()
	host.add_child(alert)
	alert.set_reduced_motion(true)
	alert.set_model({"id": 0, "title": "Food reserves low", "level": "critical", "acknowledged": false})
	await settle()
	var action: Button = alert.find_children("*", "Button", true, false)[0]
	action.grab_focus()
	alert.set_acknowledgement_state(true)
	await settle()
	check(alert.has_focus(), "pending acknowledgement transfers focus to the visibly focusable alert")
	check(not alert.is_processing() and not alert.model.acknowledged, "focus feedback preserves reduced motion and shared acknowledgement")
	var theme := host.theme
	for type in ["ButtonQuiet", "ButtonIcon"]:
		check(theme.get_stylebox("hover", type).bg_color != ThemeTokens.color("bg-200"), "quiet hover remains visible on raised cards")
		check(theme.get_stylebox("pressed", type).border_color == ThemeTokens.color("accent"), "pressed quiet actions have a distinct border")
	host.queue_free()
	await settle()
	print("UX_PANELS_%s checks=%d failures=%d" % ["PASS" if failures.is_empty() else "FAIL", checks, failures.size()])
	quit(0 if failures.is_empty() else 1)
