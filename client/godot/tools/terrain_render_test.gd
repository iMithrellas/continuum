## GPU regression: blur must reduce texture detail, not just interpolate colour.
## godot --path client/godot --rendering-method gl_compatibility --scene res://tools/terrain_render_test.tscn
extends Node


func _ready() -> void:
	if DisplayServer.get_name() == "headless":
		push_error(
			"This pixel test requires a real rendering driver; use terrain_test.tscn for backend-free headless tests."
		)
		get_tree().quit(1)
		return
	var source := Image.create(64, 64, false, Image.FORMAT_RGBA8)
	for y in 64:
		for x in 64:
			source.set_pixel(x, y, Color.WHITE if (x / 4) % 2 == 0 else Color("202020"))
	var texture := ImageTexture.create_from_image(source)
	var views: Array[SubViewport] = []
	for radius in [0.0, 1.0, 2.0]:
		var viewport := SubViewport.new()
		viewport.size = Vector2i(64, 64)
		viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
		viewport.disable_3d = true
		add_child(viewport)
		var rect := TextureRect.new()
		rect.texture = texture
		rect.size = Vector2(64, 64)
		rect.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR
		var effect := ShaderMaterial.new()
		effect.shader = preload("res://shaders/terrain_depth.gdshader")
		effect.set_shader_parameter("radius", radius)
		effect.set_shader_parameter("darkness", 1.0 - radius * 0.15)
		rect.material = effect
		viewport.add_child(rect)
		var sharp := Line2D.new()
		sharp.points = PackedVector2Array([Vector2(8, 48), Vector2(56, 48)])
		sharp.width = 2
		sharp.default_color = ThemeTokens.color("accent")
		viewport.add_child(sharp)
		views.append(viewport)
	await RenderingServer.frame_post_draw
	await RenderingServer.frame_post_draw
	var details: Array[float] = []
	var brightness: Array[float] = []
	var overlays_sharp := true
	for viewport in views:
		var pixels := viewport.get_texture().get_image()
		var detail := 0.0
		var mean := 0.0
		for x in range(8, 55):
			detail += absf(pixels.get_pixel(x, 24).r - pixels.get_pixel(x + 1, 24).r)
			mean += pixels.get_pixel(x, 24).r
		details.append(detail)
		brightness.append(mean)
		var overlay := pixels.get_pixel(32, 48)
		overlays_sharp = overlays_sharp and overlay.is_equal_approx(ThemeTokens.color("accent"))
	var passed := (
		details[0] > details[1]
		and details[1] > details[2]
		and brightness[0] > brightness[1]
		and brightness[1] > brightness[2]
		and overlays_sharp
	)
	print(
		(
			"TERRAIN_RENDER_%s detail=%s brightness=%s sharp_overlay=%s"
			% ["PASS" if passed else "FAIL", details, brightness, overlays_sharp]
		)
	)
	get_tree().quit(0 if passed else 1)
