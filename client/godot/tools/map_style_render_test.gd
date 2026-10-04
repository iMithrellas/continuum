## Real GPU pattern continuity across facility seams and camera crops.
## Run with map_client_x11.py, never on the shared desktop.
extends Node


class PatternCanvas:
	extends Node2D
	var kind := 0
	var mode := 0

	func _draw() -> void:
		if mode == 1:
			MapPaint.zone(self, Rect2(0, 0, 64, 96), kind, Vector2(15, 3), 32)
			MapPaint.zone(self, Rect2(64, 0, 64, 96), kind, Vector2(15, 3), 32)
		elif mode == 2:
			MapPaint.zone(self, Rect2(32, 0, 128, 96), kind, Vector2(14, 3), 32)
		else:
			MapPaint.zone(self, Rect2(0, 0, 128, 96), kind, Vector2(15, 3), 32)


func _ready() -> void:
	if DisplayServer.get_name() == "headless":
		push_error("Pattern continuity requires an isolated real rendering driver")
		get_tree().quit(1)
		return
	var failed := false
	var evidence := Image.create(384, 7 * 96, false, Image.FORMAT_RGBA8)
	var kinds := [
		ContinuumTileKind.Options.farm,
		ContinuumTileKind.Options.forest,
		ContinuumTileKind.Options.mine,
		ContinuumTileKind.Options.storage,
		ContinuumTileKind.Options.sleep,
		ContinuumTileKind.Options.dining,
		ContinuumTileKind.Options.recreation
	]
	for index in kinds.size():
		var views: Array[SubViewport] = []
		for mode in 3:
			var view := SubViewport.new()
			view.size = Vector2i(192, 96)
			view.disable_3d = true
			view.render_target_update_mode = SubViewport.UPDATE_ALWAYS
			add_child(view)
			var canvas := PatternCanvas.new()
			canvas.kind = kinds[index]
			canvas.mode = mode
			view.add_child(canvas)
			views.append(view)
		for frame in 3:
			await RenderingServer.frame_post_draw
		var reference := views[0].get_texture().get_image().get_region(Rect2i(0, 0, 128, 96))
		for mode in 3:
			var pixels := views[mode].get_texture().get_image().get_region(
				Rect2i(32 if mode == 2 else 0, 0, 128, 96)
			)
			evidence.blit_rect(pixels, Rect2i(0, 0, 128, 96), Vector2i(mode * 128, index * 96))
			var difference := 0.0
			for y in 96:
				for x in 128:
					var a := reference.get_pixel(x, y)
					var b := pixels.get_pixel(x, y)
					difference = maxf(
						difference, absf(a.r - b.r) + absf(a.g - b.g) + absf(a.b - b.b)
					)
			if difference > 0.005:
				failed = true
				push_error(
					(
						"World-anchored %s mode %d has a seam/crop difference %f"
						% [MapPaint.zone_token(kinds[index]), mode, difference]
					)
				)
		for view in views:
			view.free()
	DirAccess.make_dir_recursive_absolute("res://build/map-client")
	evidence.save_png("res://build/map-client/map-pattern-continuity.png")
	print(
		(
			"UI_MAP_RENDER_%s seven_patterns=7 split_and_crop_identical=%s"
			% ["FAIL" if failed else "PASS", not failed]
		)
	)
	get_tree().quit(1 if failed else 0)
