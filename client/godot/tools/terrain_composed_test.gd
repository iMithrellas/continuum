## Real ColonyMap compositor + generated rows, not an isolated shader swatch.
## godot --path client/godot --display-driver x11 --rendering-method gl_compatibility --scene res://tools/terrain_composed_test.tscn
extends Node

var failed := false
func check(condition: bool, message: String) -> void:
	if not condition:
		failed = true
		push_error(message)

func capture(viewport: SubViewport) -> Image:
	await RenderingServer.frame_post_draw
	await RenderingServer.frame_post_draw
	await RenderingServer.frame_post_draw
	return viewport.get_texture().get_image()

func stats(image: Image, rect: Rect2i) -> Vector2:
	var brightness := 0.0
	var detail := 0.0
	for y in range(rect.position.y, rect.end.y - 1):
		for x in range(rect.position.x, rect.end.x - 1):
			var colour := image.get_pixel(x, y)
			var luminance := (colour.r + colour.g + colour.b) / 3.0
			brightness += luminance
			var right := image.get_pixel(x + 1, y)
			var down := image.get_pixel(x, y + 1)
			detail += absf(luminance - (right.r + right.g + right.b) / 3.0)
			detail += absf(luminance - (down.r + down.g + down.b) / 3.0)
	return Vector2(brightness, detail / maxf(brightness, 0.001))

func _ready() -> void:
	if DisplayServer.get_name() == "headless":
		push_error("Composed pixel regression requires a real GPU driver")
		get_tree().quit(1)
		return
	var previous := SpacetimeDB.Continuum.db
	var local := preload("res://tools/terrain_fixture.gd").database()
	var viewport := SubViewport.new()
	viewport.size = Vector2i(512, 256)
	viewport.disable_3d = true
	viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	add_child(viewport)
	var map := ColonyMap.new()
	map.size = Vector2(512, 256)
	viewport.add_child(map)
	map.refresh()
	map.set_selected_rect(Rect2i(3, 0, 2, 1))
	var descriptors := map.entity_descriptors()
	check(descriptors.size() == 4, "whole tall facility, stack, and two exposed actors each get one pass; buried entities get none")
	var count := 0
	for canvas in map.terrain_view.canvases:
		count += canvas.entities.size()
	check(count == 4, "entity compositor does not duplicate tall actors/facilities per occupied vertical layer")
	for depth in map.terrain_view.layers.size():
		for layer in [map.terrain_view.layers[depth], map.terrain_view.entity_layers[depth]]:
			layer.material.set_shader_parameter("radius", 0.0)
			layer.material.set_shader_parameter("darkness", 1.0)
	var sharp := await capture(viewport)
	for depth in map.terrain_view.layers.size():
		for layer in [map.terrain_view.layers[depth], map.terrain_view.entity_layers[depth]]:
			layer.material.set_shader_parameter("radius", depth * 0.65)
	var blur_only := await capture(viewport)
	for depth in map.terrain_view.entity_layers.size():
		map.terrain_view.entity_layers[depth].material.set_shader_parameter("darkness", pow(0.97, depth))
	var entity_darkened := await capture(viewport)
	for depth in map.terrain_view.layers.size():
		for layer in [map.terrain_view.layers[depth], map.terrain_view.entity_layers[depth]]:
			layer.material.set_shader_parameter("darkness", pow(0.97, depth))
	var composed := await capture(viewport)
	var regions := {"facility": Rect2i(202, 8, 108, 48), "colonist": Rect2i(330, 134, 44, 48), "stack": Rect2i(388, 170, 23, 19)}
	for kind in regions:
		var before := stats(sharp, regions[kind])
		var filtered := stats(blur_only, regions[kind])
		var entity_only := stats(entity_darkened, regions[kind])
		var after := stats(composed, regions[kind])
		print("COMPOSED %s brightness/detail sharp=%s deep=%s" % [kind, before, after])
		check(entity_only.x < filtered.x, "%s whole icon is depth-darkened with terrain/background held constant and blur fixed" % kind)
		check(after.y < before.y, "%s detail is actually blurred independently of darkness" % kind)
	# Remove deep shaft passes only. Every near-floor pixel must remain identical
	# even right against the shaft: deep blur alpha must not cover intact floors.
	map.terrain_view.layers[9].visible = false
	map.terrain_view.entity_layers[8].visible = false
	var near_only := await capture(viewport)
	var max_difference := 0.0
	for y in range(4, 252):
		for x in range(128, 192):
			var a := composed.get_pixel(x, y)
			var b := near_only.get_pixel(x, y)
			max_difference = maxf(max_difference, absf(a.r - b.r) + absf(a.g - b.g) + absf(a.b - b.b))
	check(max_difference < 0.001, "composed deep shaft terrain and blurred whole entities never bleed over adjacent intact near floor")
	var selection := composed.get_pixel(193, 20)
	check(selection.g > 0.75 and selection.b > 0.65, "actual map selection stays sharp above depth-blurred entities")
	var designation := composed.get_pixel(450, 213)
	check(designation.r > 0.9 and designation.g > 0.55, "actual generated-row excavation overlay remains sharp")
	# Source integer xyz is still exposed in the shaft, but the real next hop
	# crosses an intact floor. It must not be drawn at an exposed-source proxy.
	map.terrain_view.layers[9].visible = true
	var moving: ContinuumColonist = local._tables["colonist"][2]
	moving.next_x = 2
	moving.move_progress = 0.8
	map._process(0.25)
	check(not map.row_visible(moving), "actual next-hop rendered xyz, not exposed source integer xyz, gates movement visibility")
	map.terrain_view.update_entities(map.entity_descriptors())
	check(map.entity_descriptors().size() == 3, "boundary-crossing actor is omitted as a whole rather than painted over a floor")
	var moving_image := await capture(viewport)
	var movement_bleed := 0.0
	for y in range(128, 192):
		for x in range(128, 192):
			var a := composed.get_pixel(x, y)
			var b := moving_image.get_pixel(x, y)
			movement_bleed = maxf(movement_bleed, absf(a.r - b.r) + absf(a.g - b.g) + absf(a.b - b.b))
	check(movement_bleed < 0.001, "actual composed moving sprite/correction cannot paint over occluding floor")
	# Legitimate four-cell-body ledge hops stay visible throughout both legs,
	# including the partial tall sprite crossing an inclusive cut at z=2.
	map.set_process(false)
	moving.next_x = moving.x
	moving.move_progress = 0
	var upper: ContinuumTerrainChunk = local._tables["terrain_chunk"][2]
	upper.materials[1 + 16] = 2 # raised destination support (1,1,0)
	upper.revision += 1
	var hopping: ContinuumColonist = local._tables["colonist"][1].duplicate(true)
	hopping.id = 4
	hopping.y = 1
	hopping.next_y = 1
	hopping.clearance_height = 4
	local._tables["colonist"][4] = hopping
	map.set_cut(2)
	map.refresh()
	for ascending in [true, false]:
		hopping.x = 0 if ascending else 1
		hopping.z = 0 if ascending else 1
		hopping.next_x = 1 if ascending else 0
		hopping.next_z = 1 if ascending else 0
		for progress in [0.1, 0.5, 0.9]:
			hopping.move_progress = progress
			map._process(0.25)
			check(map.row_visible(hopping), "actual rendered four-cell actor remains exposed on %s step p=%s" % ["up" if ascending else "down", progress])
			var entities := map.entity_descriptors()
			var remaining: Array = []
			var actor: Dictionary = {}
			for entity: Dictionary in entities:
				if entity.type == "colonist" and entity.rect.position.y < 2:
					actor = entity
				else:
					remaining.append(entity)
			check(not actor.is_empty(), "whole step sprite is assigned exactly once to its actual feet pass")
			map.terrain_view.update_entities(entities)
			var with_actor := await capture(viewport)
			map.terrain_view.update_entities(remaining)
			var without_actor := await capture(viewport)
			var changed_pixels := 0
			if not actor.is_empty():
				var region := Rect2i(actor.rect.position * 64, actor.rect.size * 64)
				for y in range(region.position.y, region.end.y):
					for x in range(region.position.x, region.end.x):
						var a := with_actor.get_pixel(x, y)
						var b := without_actor.get_pixel(x, y)
						if absf(a.r - b.r) + absf(a.g - b.g) + absf(a.b - b.b) > 0.015:
							changed_pixels += 1
			check(changed_pixels > 200, "composed whole sprite remains visibly rendered on %s step p=%s, changed pixels=%d" % ["up" if ascending else "down", progress, changed_pixels])
	print("TERRAIN_COMPOSED_%s near_floor_difference=%f" % ["FAIL" if failed else "PASS", max_difference])
	SpacetimeDB.Continuum.db = previous
	viewport.free()
	local.free()
	get_tree().quit(1 if failed else 0)
