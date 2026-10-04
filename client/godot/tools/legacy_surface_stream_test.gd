## Standalone legacy API regression, including actual private-Xvfb GPU pixels.
extends Node

var assertions := 0
var failures := 0
var gpu := false


func check(value: bool, message: String) -> void:
	assertions += 1
	if not value:
		failures += 1
		push_error(message)


func _ready() -> void:
	gpu = DisplayServer.get_name() != "headless"
	call_deferred("run")


func floor_model(logical_edge: int, resident_edge: int, offset: Vector2i) -> LayeredTerrainModel:
	var lower := PackedByteArray()
	lower.resize(4096)
	lower.fill(1)
	var upper := PackedByteArray()
	upper.resize(4096)
	var rows: Array = []
	for cy in range(offset.y / 16, (offset.y + resident_edge) / 16):
		for cx in range(offset.x / 16, (offset.x + resident_edge) / 16):
			for cz in [-1, 0]:
				rows.append(
					{
						"chunk_x": cx,
						"chunk_y": cy,
						"chunk_z": cz,
						"revision": 1,
						"materials": lower if cz == -1 else upper
					}
				)
	var model := LayeredTerrainModel.new()
	model.sync(
		{"width": logical_edge, "height": logical_edge, "min_z": -16, "max_z": 15},
		rows,
		[{"id": 0, "name": "air", "opaque": false}, {"id": 1, "name": "soil", "opaque": true}]
	)
	return model


func texture_count(view: LayeredTerrainView) -> int:
	var count := 0
	for layer: TextureRect in view.terrain_layers():
		if layer.texture != null:
			count += 1
	return count


func check_pixels(viewport: SubViewport, context: String) -> void:
	if not gpu:
		return
	for frame in 3:
		await RenderingServer.frame_post_draw
	var image := viewport.get_texture().get_image()
	var at := viewport.size / 2
	var pixel := image.get_pixelv(at)
	var backing := ThemeTokens.color("map-ground-deep")
	var difference := (
		absf(pixel.r - backing.r) + absf(pixel.g - backing.g) + absf(pixel.b - backing.b)
	)
	check(
		pixel.a > 0.99 and difference > 0.02,
		context + " GPU known floor is opaque material, not blank backing"
	)


func standalone(logical_edge: int, resident_edge: int, offset: Vector2i) -> void:
	var model := floor_model(logical_edge, resident_edge, offset)
	var context := "legacy %d bounds/%d resident" % [logical_edge, resident_edge]
	check(
		model.surfaces.size() == resident_edge * resident_edge and model.query_count <= 65536,
		context + " sync resolves only capped replicated columns"
	)
	var viewport := SubViewport.new()
	viewport.size = Vector2i(320, 240)
	viewport.disable_3d = true
	viewport.transparent_bg = true
	viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	add_child(viewport)
	var parent := Control.new()
	parent.size = Vector2(viewport.size)
	viewport.add_child(parent)
	var view := LayeredTerrainView.new()
	view.attach(parent)
	var focus := Vector2(offset) + Vector2.ONE * resident_edge / 2.0 + Vector2.ONE * 0.5
	var pixels := 16.0 if logical_edge == 16 else 4.0
	var origin := Vector2(viewport.size) * 0.5 - focus * pixels
	var extent := Vector2.ONE * logical_edge * pixels
	view.layout(origin, extent)
	view.rebuild(model)
	view.set_visible(true)
	check(texture_count(view) > 0, context + " standalone rebuild has terrain textures immediately")
	await check_pixels(viewport, context)
	check(
		model.query_count < 65536 + 65536,
		context + " GPU metadata/crop work remains bounded, not logical-world scan"
	)
	model.set_cut(1)
	view.rebuild(model)
	check(
		(
			texture_count(view) > 0
			and model.surface_at(Vector2i(focus)) == Vector3i(int(focus.x), int(focus.y), -1)
		),
		context + " cut rebuild re-resolves real floor without a controller seam"
	)
	await check_pixels(viewport, context + " after cut")
	var baseline := Vector2i(view.terrain_build_count, view.mask_build_count)
	for tick in 8:
		view.rebuild(model)
		view.layout(origin, extent)
	check(
		baseline == Vector2i(view.terrain_build_count, view.mask_build_count),
		context + " idle legacy API does not rebuild textures/masks"
	)
	viewport.free()


func cache_growth() -> void:
	var model := floor_model(2048, 16, Vector2i.ZERO)
	var known := model.capture_selection(Rect2i(8, 8, 1, 1))
	var pending := model.capture_selection(Rect2i(32, 32, 1, 1))
	var authority := model.revision
	var exposure := model.exposure_revision
	model.clear_exposure_cache()
	check(
		(
			model.surfaces.is_empty()
			and model.revision == authority
			and model.exposure_revision > exposure
		),
		"derived cache eviction does not change authority or erase replicated voxels"
	)
	var parent := Control.new()
	parent.size = Vector2(320, 240)
	add_child(parent)
	var view := LayeredTerrainView.new()
	view.attach(parent)
	view.layout(Vector2.ZERO, Vector2.ONE * 2048 * 16)
	view.rebuild(model)
	check(texture_count(view) > 0, "cold derived cache resolves before legacy surface indexing")
	check(
		(
			model.selection_valid(known)
			and model.selection_valid(pending)
			and model.revision == authority
		),
		"camera warming preserves both exact and pending physical selections"
	)
	var before := view.terrain_build_count
	model.clear_exposure_cache()
	check(
		model.surface_at(Vector2i(8, 8)) == Vector3i(8, 8, -1),
		"direct lazy query resolves an actual floor"
	)
	view.rebuild(model)
	check(
		view.terrain_build_count > before and texture_count(view) > 0,
		"lazy cache growth refreshes a previously indexed legacy renderer"
	)
	check(
		model.revision == authority and model.selection_valid(pending),
		"index coherence does not invalidate selection authority"
	)
	parent.free()


func run() -> void:
	for edge in [16, 128, 256]:
		await standalone(edge, edge, Vector2i.ZERO)
	await standalone(2048, 16, Vector2i(1008, 1008))
	cache_growth()
	print(
		(
			"LEGACY_SURFACE_STREAM_%s assertions=%d gpu=%s"
			% ["PASS" if failures == 0 else "FAIL", assertions, gpu]
		)
	)
	get_tree().quit(0 if failures == 0 else 1)
