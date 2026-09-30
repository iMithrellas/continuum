## Real 24/128/256 GPU composition at camera zoom, with whole-entity passes.
## Use map_client_x11.py for an isolated GL driver without desktop focus.
extends Node

var failed := false

func check(value: bool, message: String) -> void:
	if not value:
		failed = true
		push_error(message)

func capture(viewport: SubViewport) -> Image:
	for frame in 4:
		await RenderingServer.frame_post_draw
	return viewport.get_texture().get_image()

func rendered_facilities(map: ColonyMap) -> Array:
	var entities: Array = []
	for canvas in map.terrain_view.canvases:
		for entity: Dictionary in canvas.entities:
			if entity.type == "facility":
				entities.append(entity)
	return entities

func image_difference(a: Image, b: Image) -> float:
	var difference := 0.0
	for y in a.get_height():
		for x in a.get_width():
			var left := a.get_pixel(x, y)
			var right := b.get_pixel(x, y)
			difference = maxf(difference, absf(left.r - right.r) + absf(left.g - right.g) + absf(left.b - right.b))
	return difference

func check_resize_budgets(map: ColonyMap) -> void:
	var terrain_pixels := 0
	var entity_pixels := 0
	for depth in map.terrain_view.layers.size():
		var texture: Texture2D = map.terrain_view.layers[depth].texture
		if texture != null:
			check(texture.get_width() <= 2048 and texture.get_height() <= 2048, "resized GL terrain textures remain edge-bounded")
			terrain_pixels += texture.get_width() * texture.get_height()
		var pass_view: SubViewport = map.terrain_view.viewports[depth]
		check(pass_view.size.x <= 2048 and pass_view.size.y <= 2048, "resized GL entity passes remain edge-bounded")
		if map.terrain_view.entity_layers[depth].texture != null:
			entity_pixels += pass_view.size.x * pass_view.size.y
	check(terrain_pixels <= LayeredTerrainView.MAX_PASS_PIXELS and entity_pixels <= LayeredTerrainView.MAX_PASS_PIXELS, "resized GL passes retain independent aggregate budgets")

func click_viewport(viewport: SubViewport, point: Vector2) -> void:
	for pressed in [true, false]:
		var event := InputEventMouseButton.new()
		event.button_index = MOUSE_BUTTON_LEFT
		event.pressed = pressed
		event.position = point
		viewport.push_input(event, true)

func test_resize_render() -> void:
	var previous := SpacetimeDB.Continuum.db
	var fixture := preload("res://tools/map_client_profile.gd").new()
	fixture.edge = 128
	var local: LocalDatabase = fixture.database(false)
	local._tables["tile"][500001] = ContinuumTile.create(500001, 78, 64, ContinuumTileKind.create_dining(), true, -8, 1, 1, 6)
	preload("res://tools/terrain_fixture.gd").index_rows(local)
	var viewport := SubViewport.new()
	viewport.size = Vector2i(256, 256)
	viewport.disable_3d = true
	viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	add_child(viewport)
	var map := ColonyMap.new()
	viewport.add_child(map)
	map.size = Vector2(viewport.size)
	map.refresh()
	map.reset_camera()
	# Leave normal processing enabled: idle actors must not conceal a resize bug.
	var narrow := await capture(viewport)
	check(rendered_facilities(map).is_empty(), "native narrow GL camera initially culls the far facility")
	var tile_revision := map._tile_revision
	var model_revision := map.terrain_model.revision
	viewport.size = Vector2i(1024, 256)
	map.size = Vector2(viewport.size)
	check(rendered_facilities(map).size() == 1, "resize supplies the newly visible facility to actual GL canvases immediately")
	var point := map.world_to_screen(Vector2(78.5, 64.5))
	check(map._cell_at(point) == Vector2i(78, 64) and map.tile_at(Vector2i(78, 64)).id == 500001, "resized GL frustum and durable facility picking agree")
	var selections: Array[int] = []
	var rectangles: Array[Rect2i] = []
	map.tile_selected.connect(func(id: int) -> void: selections.append(id))
	map.rectangle_selected.connect(func(rect: Rect2i) -> void: rectangles.append(rect))
	click_viewport(viewport, point)
	check(selections == [500001] and rectangles == [Rect2i(78, 64, 1, 1)], "actual resized GL viewport routes GUI/global input to durable facility id and xyz footprint")
	map.clear_selection()
	check_resize_budgets(map)
	for frame in 60:
		await RenderingServer.frame_post_draw
	var wide := await capture(viewport)
	wide.save_png("res://build/map-client/resize-wide-before-tick.png")
	var region := Rect2i(map.world_to_screen(Vector2(78, 64)), Vector2.ONE * map._cell_size())
	# A normal tick must not be needed to repair resize pixels.
	map.refresh({"config": true})
	var after_tick := await capture(viewport)
	var config_difference := image_difference(wide, after_tick)
	check(config_difference < 0.001, "a later config tick does not restore a previously missing resize sprite")
	map.terrain_view.update_entities(map.entity_descriptors().filter(func(entity: Dictionary) -> bool: return entity.type != "facility"))
	var without := await capture(viewport)
	var changed_pixels := 0
	for y in range(region.position.y, region.end.y):
		for x in range(region.position.x, region.end.x):
			var a := wide.get_pixel(x, y)
			var b := without.get_pixel(x, y)
			if absf(a.r - b.r) + absf(a.g - b.g) + absf(a.b - b.b) > 0.015:
				changed_pixels += 1
	check(changed_pixels > 100, "newly visible whole facility actually appears in GL pixels before any tick")
	map.terrain_view.update_entities(map.entity_descriptors())
	await capture(viewport)
	var stable := Vector3i(map.terrain_view.terrain_build_count, map.terrain_view.mask_build_count, map.terrain_view.entity_update_count)
	for frame in 60:
		await RenderingServer.frame_post_draw
	check(Vector3i(map.terrain_view.terrain_build_count, map.terrain_view.mask_build_count, map.terrain_view.entity_update_count) == stable and map._tile_revision == tile_revision and map.terrain_model.revision == model_revision, "resized idle GL frames do not poll/rebuild terrain, masks, entity passes, or resnapshot the world")
	viewport.size = Vector2i(256, 256)
	map.size = Vector2(viewport.size)
	var shrunk := await capture(viewport)
	check(rendered_facilities(map).is_empty() and map._cell_at(map.world_to_screen(Vector2(78.5, 64.5))) == null, "shrinking the GL viewport removes out-of-view facilities and clips picking")
	click_viewport(viewport, map.world_to_screen(Vector2(78.5, 64.5)))
	check(selections == [500001] and rectangles == [Rect2i(78, 64, 1, 1)], "shrunk GL viewport does not route an out-of-view facility click through its clip rectangle")
	var shrink_difference := image_difference(narrow, shrunk)
	check(shrink_difference < 0.001, "shrunk GL pixels return to the original narrow camera without ghost sprites")
	check_resize_budgets(map)
	print("MAP_CLIENT_RENDER resize_facility_pixels=%d resize_config_difference=%f shrink_difference=%f" % [changed_pixels, config_difference, shrink_difference])
	viewport.free()
	SpacetimeDB.Continuum.db = previous
	local.free()
	fixture.free()

func _ready() -> void:
	if DisplayServer.get_name() == "headless":
		push_error("Map camera pixel regression requires a rendering driver")
		get_tree().quit(1)
		return
	var previous := SpacetimeDB.Continuum.db
	var fixture := preload("res://tools/map_client_profile.gd").new()
	var edge := 128
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--edge="):
			edge = int(arg.trim_prefix("--edge="))
	fixture.edge = edge
	var base := edge / 2
	var local: LocalDatabase = fixture.database()
	fixture.free()
	var actor: ContinuumColonist = local._tables["colonist"][0]
	actor.x = base + 6
	actor.y = base + 4
	actor.next_x = actor.x
	actor.next_y = actor.y
	local._tables["colonist"].clear()
	local._tables["colonist"][actor.id] = actor
	local._tables["tile"][50000] = ContinuumTile.create(50000, base + 3, base + 2, ContinuumTileKind.create_dining(), true, -8, 2, 2, 12)
	preload("res://tools/terrain_fixture.gd").index_rows(local)
	var viewport := SubViewport.new()
	viewport.size = Vector2i(512, 256)
	viewport.disable_3d = true
	viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	add_child(viewport)
	var map := ColonyMap.new()
	map.size = Vector2(viewport.size)
	viewport.add_child(map)
	map.refresh()
	map.set_process(false)
	var centre := Vector2(base + 4.5, base + 4.5)
	map.zoom_at(32.0 / map._cell_size(), map.world_to_screen(centre))
	map.pan_by(map.size * 0.5 - map.world_to_screen(centre))
	map.set_selected_rect(Rect2i(base + 3, base + 2, 2, 2))
	var descriptors := map.entity_descriptors()
	check(descriptors.size() == 2, "large-world culling draws exactly one complete facility and one whole actor")
	var complete := await capture(viewport)
	complete.save_png("res://build/map-client/camera-%d.png" % edge)
	var selection := map.world_to_screen(Vector2(base + 3, base + 2)) + Vector2(1, 20)
	var colour := complete.get_pixelv(Vector2i(selection))
	check(colour.g > 0.75 and colour.b > 0.65, "selection is sharp above cropped deep entity/terrain passes at zoom")
	check(map._cell_at(map.world_to_screen(centre)) == Vector2i(base + 4, base + 4), "GPU camera and exact world-coordinate picking agree")
	check(map.tile_at(Vector2i(base + 4, base + 2)).id == 50000, "zoomed picking finds the complete facility rather than an underlying empty row")
	map.terrain_view.layers[9].visible = false
	map.terrain_view.entity_layers[8].visible = false
	var near_only := await capture(viewport)
	var difference := 0.0
	for y in range(32, 200):
		for x in range(4, 108):
			var world := map.screen_to_world(Vector2(x, y))
			if world.x >= base or world.y < base:
				continue
			var a := complete.get_pixel(x, y)
			var b := near_only.get_pixel(x, y)
			difference = maxf(difference, absf(a.r - b.r) + absf(a.g - b.g) + absf(a.b - b.b))
	check(difference < 0.001, "camera-cropped source/output masks prevent deep blur from bleeding over intact near floors")
	map.terrain_view.layers[9].visible = true
	map.terrain_view.entity_layers[8].visible = true
	var facilities := descriptors.filter(func(entity: Dictionary) -> bool: return entity.type != "colonist")
	map.terrain_view.update_entities(facilities)
	var without_actor := await capture(viewport)
	var changed_pixels := 0
	var region := Rect2i(map.world_to_screen(Vector2(base + 6, base + 4)), Vector2.ONE * map._cell_size())
	for y in range(region.position.y, region.end.y):
		for x in range(region.position.x, region.end.x):
			var a := complete.get_pixel(x, y)
			var b := without_actor.get_pixel(x, y)
			if absf(a.r - b.r) + absf(a.g - b.g) + absf(a.b - b.b) > 0.015:
				changed_pixels += 1
	check(changed_pixels > 100, "whole actor is visibly rendered, not merely present in a culled descriptor list")
	map.terrain_view.update_entities(descriptors)
	await capture(viewport)
	var builds := map.terrain_view.entity_update_count
	var terrain_builds := map.terrain_view.terrain_build_count
	for i in 60:
		map._process(1.0 / 60.0)
		await RenderingServer.frame_post_draw
	check(map.terrain_view.entity_update_count == builds and map.terrain_view.terrain_build_count == terrain_builds, "real rendered idle scene neither redraws entity buffers nor rebuilds terrain")
	var idle_calls := RenderingServer.get_rendering_info(RenderingServer.RENDERING_INFO_TOTAL_DRAW_CALLS_IN_FRAME)
	for pass_view in map.terrain_view.viewports:
		check(pass_view.render_target_update_mode != SubViewport.UPDATE_ALWAYS, "entity buffer keeps its on-demand update mode")
		if pass_view.render_target_update_mode == SubViewport.UPDATE_ONCE:
			pass_view.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	await capture(viewport)
	var always_calls := RenderingServer.get_rendering_info(RenderingServer.RENDERING_INFO_TOTAL_DRAW_CALLS_IN_FRAME)
	check(always_calls > idle_calls, "on-demand entity passes actually stop rendering on the GPU, verified against UPDATE_ALWAYS draw calls")
	print("MAP_CLIENT_RENDER idle_draw_calls=%d forced_always_draw_calls=%d" % [idle_calls, always_calls])
	map.fit_camera()
	var fit := await capture(viewport)
	fit.save_png("res://build/map-client/fit-%d.png" % edge)
	var terrain_pixels := 0
	var entity_pixels := 0
	var maximum_terrain := Vector2i.ZERO
	for layer in map.terrain_view.layers:
		if layer.texture != null:
			var dimensions := Vector2i(layer.texture.get_size())
			maximum_terrain.x = maxi(maximum_terrain.x, dimensions.x)
			maximum_terrain.y = maxi(maximum_terrain.y, dimensions.y)
			terrain_pixels += dimensions.x * dimensions.y
			check(dimensions.x <= 2048 and dimensions.y <= 2048, "actual fit-view terrain textures remain edge-bounded")
	for depth in map.terrain_view.viewports.size():
		var pass_view: SubViewport = map.terrain_view.viewports[depth]
		check(pass_view.size.x <= 2048 and pass_view.size.y <= 2048, "actual fit-view entity buffers remain edge-bounded")
		if map.terrain_view.entity_layers[depth].texture != null:
			entity_pixels += pass_view.size.x * pass_view.size.y
	check(terrain_pixels <= LayeredTerrainView.MAX_PASS_PIXELS and entity_pixels <= LayeredTerrainView.MAX_PASS_PIXELS, "actual GL fit view obeys independent terrain/entity aggregate budgets")
	print("MAP_CLIENT_RENDER edge=%d max_terrain_texture=%s terrain_pixels=%d entity_pixels=%d" % [edge, maximum_terrain, terrain_pixels, entity_pixels])
	var source := SpacetimeDB.Continuum.db
	var floor_pixel := Vector2i(map.world_to_screen(Vector2(2.5, 2.5)))
	SpacetimeDB.Continuum.db = null
	map.queue_redraw() # draw must detect detachment without process/refresh/hover
	var detached := await capture(viewport)
	check(not map._has_state and map._source_db == null and map.terrain_view.layers[1].texture == null and map.entity_descriptors().is_empty(), "actual GL draw invalidates detached provider terrain and sprites before ordinary refresh")
	var before_detach := fit.get_pixelv(floor_pixel)
	var after_detach := detached.get_pixelv(floor_pixel)
	check(absf(before_detach.r - after_detach.r) + absf(before_detach.g - after_detach.g) + absf(before_detach.b - after_detach.b) > 0.1, "actual detached GL pixels no longer display old terrain")
	SpacetimeDB.Continuum.db = source
	map.refresh({"config": true})
	var restored := await capture(viewport)
	var after_restore := restored.get_pixelv(floor_pixel)
	check(absf(before_detach.r - after_restore.r) + absf(before_detach.g - after_restore.g) + absf(before_detach.b - after_restore.b) < 0.005, "actual GL composition recovers after a selective refresh on restored provider")
	print("MAP_CLIENT_RENDER provider_detachment=true source_restoration=true")
	if edge == 128:
		await test_resize_render()
	print("MAP_CLIENT_RENDER_%s edge=%d near_floor_difference=%f actor_pixels=%d" % ["FAIL" if failed else "PASS", edge, difference, changed_pixels])
	SpacetimeDB.Continuum.db = previous
	viewport.free()
	local.free()
	get_tree().quit(1 if failed else 0)
