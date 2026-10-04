## R2–R4 regressions from the independent art review, against real render passes.
## Headless: validation/lifetime/budgets. Private GL: pixels and external rooms.
extends Node

const Fixture = preload("res://tools/world_art_fixture.gd")
const OUT := "res://build/art-review-fixes"
var failures := 0
var assertions := 0


class OverviewModel:
	extends LayeredTerrainModel
	var physical_queries := 0

	func surface_at(_xy: Vector2i) -> Variant:
		physical_queries += 1
		return null

	func material_at(_cell: Vector3i) -> int:
		physical_queries += 1
		return -1

	func position_visible(_position: Vector3, _width := 1, _depth := 1) -> bool:
		physical_queries += 1
		return false


func check(ok: bool, message: String) -> void:
	assertions += 1
	if not ok:
		failures += 1
		push_error(message)


func model() -> OverviewModel:
	var result := OverviewModel.new()
	result.width = 64
	result.height = 64
	result.materials = {
		0: {"name": "air", "opaque": false},
		1: {"name": "soil", "opaque": true},
		2: {"name": "stone", "opaque": true},
		3: {"name": "glass", "opaque": false}
	}
	return result


func frame(revision := 1) -> Dictionary:
	return {
		"region": Rect2i(0, 0, 64, 64),
		"stride": 8,
		"cut": 0,
		"revision": revision,
		"mode": "overview",
		"samples": {Vector2i.ZERO: {"known": true, "surface_z": -1, "material": 1}}
	}


func new_view(parent: Control) -> LayeredTerrainView:
	var view := LayeredTerrainView.new()
	view.attach(parent)
	view.layout(Vector2.ZERO, parent.size)
	view.set_visible(true)
	return view


func counters(view: LayeredTerrainView) -> Vector3i:
	return Vector3i(view.terrain_build_count, view.mask_build_count, view.entity_update_count)


func released(view: LayeredTerrainView) -> bool:
	if (
		view._surface_texture != null
		or not view._active_pages.is_empty()
		or not view._entity_masks.is_empty()
	):
		return false
	for page: Dictionary in view._terrain_pages:
		if page.texture != null:
			return false
	for layer: TextureRect in view.terrain_layers():
		if (
			layer.texture != null
			or layer.visible
			or layer.material.get_shader_parameter("surface_data") != null
			or layer.material.get_shader_parameter("visibility_mask") != null
		):
			return false
	for layer: TextureRect in view.entity_layers:
		if (
			layer.texture != null
			or layer.visible
			or layer.material.get_shader_parameter("visibility_mask") != null
		):
			return false
	for canvas: Node2D in view.canvases:
		if not canvas.entities.is_empty():
			return false
	for viewport: SubViewport in view.viewports:
		if (
			viewport.size != Vector2i(2, 2)
			or viewport.render_target_update_mode != SubViewport.UPDATE_DISABLED
		):
			return false
	return true


func test_validation() -> void:
	var exact := model()
	var parent := Control.new()
	parent.size = Vector2(512, 512)
	add_child(parent)
	var view := new_view(parent)
	var accepted := frame()
	check(view.rebuild_frame(exact, accepted), "valid registered opaque sample installs")
	var stable := counters(view)
	var texture := view._surface_texture.get_instance_id()
	var bad_samples: Array = [
		null,
		[],
		{},
		{"known": 1},
		{"known": "true"},
		{"known": true, "material": 1},
		{"known": true, "surface_z": -1},
		{"known": true, "surface_z": -1.0, "material": 1},
		{"known": true, "surface_z": "-1", "material": 1},
		{"known": true, "surface_z": null, "material": 1},
		{"known": true, "surface_z": -1, "material": 1.0},
		{"known": true, "surface_z": -1, "material": "1"},
		{"known": true, "surface_z": -1, "material": true},
		{"known": true, "surface_z": -1, "material": -1},
		{"known": true, "surface_z": -1, "material": 999},
		{"known": true, "surface_z": -1, "material": 3},
		{"known": true, "surface_z": 1, "material": 1},
		{"known": true, "surface_z": -17, "material": 1},
		{"known": true, "surface_z": 999, "material": 0},
		{"known": true, "surface_z": -16, "material": 0},
		{"known": false, "surface_z": -1, "material": 1},
		{"known": false, "surface_z": "pending", "material": 0},
		{"known": false, "material": 0}
	]
	for revision in [1, 2]:
		for bad: Variant in bad_samples:
			var candidate := frame(revision)
			candidate.samples[Vector2i.ZERO] = bad
			check(
				not view.rebuild_frame(exact, candidate),
				"reject invalid sample at revision %s: %s" % [revision, bad]
			)
	for candidate: Variant in [null, [], "frame", true, 1, Rect2i()]:
		check(
			not view.rebuild_frame(exact, candidate),
			"reject malformed top-level frame without exception"
		)
	for key in ["region", "stride", "cut", "revision", "mode", "samples"]:
		var candidate := frame()
		candidate.erase(key)
		check(not view.rebuild_frame(exact, candidate), "reject missing required header " + key)
		for bad: Variant in [null, true, 1.0, [], {}]:
			candidate = frame()
			candidate[key] = bad
			check(not view.rebuild_frame(exact, candidate), "reject mistyped header " + key)
	var changed := frame()
	for extent in [
		Vector2i(65536, 65536), Vector2i(1073741824, 1073741824), Vector2i(64, -64), Vector2i.ZERO
	]:
		var candidate := frame()
		candidate.region.size = extent
		check(
			not view.rebuild_frame(exact, candidate),
			"malformed or overflowing coverage cannot bypass the sample-position budget"
		)
	changed.samples[Vector2i.ZERO].material = 2
	check(
		not view.rebuild_frame(exact, changed),
		"reused revision cannot silently substitute different valid samples"
	)
	check(
		counters(view) == stable and view._surface_texture.get_instance_id() == texture,
		"invalid candidates preserve the compatible accepted cache without rebuilding"
	)
	accepted.samples[Vector2i.ZERO].erase("surface_z")
	check(
		(
			view._frame.samples[Vector2i.ZERO].surface_z == -1
			and not view.rebuild_frame(exact, accepted)
		),
		"caller mutation cannot corrupt the immutable accepted snapshot"
	)
	check(
		(
			view._frame.is_read_only()
			and view._frame.samples.is_read_only()
			and view._frame.samples[Vector2i.ZERO].is_read_only()
		),
		"accepted rendering dictionaries are recursively read-only"
	)
	check(
		view.rebuild_frame(exact, frame()) and counters(view) == stable,
		"fresh but identical caller frame reuses accepted textures"
	)
	check(
		exact.physical_queries == 0,
		"validation and cached overview reuse never query exact geometry"
	)
	exact.materials[1].opaque = false
	check(
		not view.rebuild_frame(exact, frame()) and view.is_frame_suspended() and released(view),
		"changed transparent metadata suspends the formerly opaque accepted frame"
	)
	exact.materials[1].opaque = 1
	check(
		not view.rebuild_frame(exact, frame()),
		"truthy numeric opacity is not registered boolean opacity"
	)
	for invalid: Variant in [null, true, [], {"name": "soil"}, {"name": "soil", "opaque": "true"}]:
		exact.materials[1] = invalid
		check(
			not view.rebuild_frame(exact, frame()),
			"malformed registered material metadata is rejected without an exception"
		)
	exact.materials[1] = {"name": "soil", "opaque": true}
	check(
		view.rebuild_frame(exact, frame()) and not view.is_frame_suspended(),
		"current valid material context restores rendering"
	)
	var empty := frame(3)
	empty.samples[Vector2i.ZERO] = {"known": true, "surface_z": -17, "material": 0}
	check(
		view.rebuild_frame(exact, empty),
		"registered air with exact min_z-1 sentinel is a resolved empty ray"
	)
	exact.materials[0].opaque = true
	check(
		not view.rebuild_frame(exact, empty) and released(view),
		"opaque material zero cannot pretend to be a resolved empty ray"
	)
	parent.free()


## Count unique images through ALL page fields AND shader bindings: an inactive
## TextureRect can otherwise retain metadata that a page-only sum would miss.
func allocation(view: LayeredTerrainView) -> Vector2i:
	var masks := {}
	var metadata := {}
	for page: Dictionary in view._terrain_pages:
		if page.texture != null:
			metadata[page.texture.get_instance_id()] = page.texture
	for layer: TextureRect in view.terrain_layers():
		if layer.texture != null:
			masks[layer.texture.get_instance_id()] = layer.texture
		var mask: Texture2D = layer.material.get_shader_parameter("visibility_mask")
		var data: Texture2D = layer.material.get_shader_parameter("surface_data")
		if mask != null:
			masks[mask.get_instance_id()] = mask
		if data != null:
			metadata[data.get_instance_id()] = data
	var bytes := Vector2i.ZERO
	for texture: Texture2D in masks.values():
		bytes.x += texture.get_image().get_data().size()
	for texture: Texture2D in metadata.values():
		bytes.y += texture.get_image().get_data().size()
	return bytes


func test_budget_and_suspension() -> void:
	var exact := model()
	exact.width = 512
	exact.height = 128
	exact.min_z = -31
	exact.max_z = 0
	var parent := Control.new()
	parent.size = Vector2(1280, 720)
	add_child(parent)
	var view := new_view(parent)
	view.layout(Vector2.ZERO, Vector2(1280, 320))
	var maximum := {
		"region": exact.bounds(),
		"stride": 1,
		"cut": 0,
		"revision": 7,
		"mode": "detail",
		"samples": {}
	}
	for y in 128:
		for x in 512:
			maximum.samples[Vector2i(x, y)] = {
				"known": true, "surface_z": -((x + y) % 32), "material": 1
			}
	check(view.rebuild_frame(exact, maximum), "all 65536 samples over four 32-depth pages install")
	var bytes := allocation(view)
	check(
		view._active_pages.size() == 4 and bytes == Vector2i(8388608, 1081600),
		"all masks and retained RGBAF metadata match the real four-page budget: %s" % bytes
	)
	var stable := counters(view)
	for index in 8:
		check(
			view.rebuild_frame(exact, maximum), "fully validated maximum cache hit remains accepted"
		)
		view.layout(Vector2.ZERO, Vector2(1280, 320))
	check(
		counters(view) == stable and allocation(view) == bytes,
		"maximum-frame idle validation allocates no new render images or masks"
	)
	view.layout(Vector2.ZERO, Vector2(20480, 5120))
	check(
		view._active_pages.size() == 1 and allocation(view).y < bytes.y,
		"narrow camera releases inactive metadata including every shader binding"
	)
	exact.set_cut(-4)
	check(
		not view.rebuild_frame(exact, maximum), "old-cut frame is rejected after exact cut changes"
	)
	check(
		(
			view.is_frame_suspended()
			and view._frame.is_empty()
			and view.pending_samples > 0
			and released(view)
		),
		"rejection clears every page, mask, entity pass and stale frame before presenting pending"
	)
	check(allocation(view) == Vector2i.ZERO, "suspension leaves no hidden terrain TextureRefs")
	stable = counters(view)
	for index in 4:
		view.layout(Vector2.ZERO, Vector2(1280, 320))
		view.set_visible(true)
		view.update_entities([{"z": -4, "rect": Rect2(0, 0, 1, 1), "type": "facility"}])
	check(
		counters(view) == stable and released(view),
		"layout/show/actor updates cannot revive a suspended frame or query physical data"
	)
	check(
		exact.physical_queries == 0,
		"pending pages do not fall back to exact or whole-world geometry"
	)
	var current := frame(8)
	current.cut = -4
	current.samples[Vector2i.ZERO].surface_z = -5
	check(
		view.rebuild_frame(exact, current) and not view.is_frame_suspended(),
		"a valid current-cut frame resumes the same renderer"
	)
	var replacement := model()
	check(
		not view.rebuild_frame(replacement, current) and released(view),
		"different exact-model identity invalidates old visuals even when its revision matches"
	)
	view.reset()
	check(
		not view.is_frame_suspended() and view.pending_samples == 0 and released(view),
		"reset clears suspended/pending state and retained image references"
	)
	parent.free()


func capture(viewport: SubViewport, name: String) -> Image:
	for tick in 3:
		await RenderingServer.frame_post_draw
	var image := viewport.get_texture().get_image()
	image.save_png(OUT + "/" + name + ".png")
	return image


func changes(a: Image, b: Image) -> int:
	var count := 0
	for y in a.get_height():
		for x in a.get_width():
			var p := a.get_pixel(x, y)
			var q := b.get_pixel(x, y)
			if absf(p.r - q.r) + absf(p.g - q.g) + absf(p.b - q.b) > 0.01:
				count += 1
	return count


func test_stale_pixels() -> void:
	var viewport := SubViewport.new()
	viewport.size = Vector2i(256, 128)
	viewport.disable_3d = true
	viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	add_child(viewport)
	var parent := Control.new()
	parent.size = Vector2(viewport.size)
	viewport.add_child(parent)
	var exact := model()
	exact.width = 16
	exact.height = 8
	var view := new_view(parent)
	var current := frame()
	current.region = exact.bounds()
	current.samples = {}
	check(view.rebuild_frame(exact, current), "GPU pending baseline installs")
	var pending := await capture(viewport, "pending-baseline")
	current.revision = 2
	current.samples[Vector2i.ZERO] = {"known": true, "surface_z": 0, "material": 1}
	current.samples[Vector2i(8, 0)] = {"known": true, "surface_z": -17, "material": 0}
	check(view.rebuild_frame(exact, current), "GPU old-cut surface and known empty install")
	var old := await capture(viewport, "old-cut")
	check(
		changes(pending, old) > 16000,
		"old frame genuinely contributes terrain and resolved-empty pixels"
	)
	var malformed := current.duplicate(true)
	malformed.samples[Vector2i.ZERO].material = 3
	check(
		not view.rebuild_frame(exact, malformed),
		"GPU rejects transparent sample even on same cache key"
	)
	check(
		changes(old, await capture(viewport, "rejected-transparent")) == 0,
		"invalid same-context input leaves the compatible accepted image unchanged"
	)
	exact.set_cut(-4)
	check(not view.rebuild_frame(exact, current), "GPU old-cut rejection returns false")
	check(
		changes(pending, await capture(viewport, "stale-immediate-pending")) == 0,
		"wrong-cut terrain pixels disappear immediately upon rejection, before layout"
	)
	view.layout(Vector2.ZERO, Vector2(viewport.size))
	view.set_visible(false)
	view.set_visible(true)
	check(
		changes(pending, await capture(viewport, "stale-after-layout")) == 0,
		"layout and visibility toggles leave only pending pixels"
	)
	current.cut = -4
	current.revision = 3
	current.samples[Vector2i.ZERO] = {"known": true, "surface_z": -5, "material": 2}
	check(view.rebuild_frame(exact, current), "new-cut GPU frame installs")
	var restored := await capture(viewport, "valid-new-cut")
	check(
		changes(pending, restored) > 16000 and changes(old, restored) > 8000,
		"valid new-cut stone restores actual new pixels instead of old soil"
	)
	exact.set_cut(-8)
	view.layout(Vector2.ZERO, Vector2(viewport.size))
	check(
		changes(pending, await capture(viewport, "layout-only-cut-pending")) == 0,
		"layout itself catches an incompatible active frame without a replacement call"
	)
	check(
		exact.physical_queries == 0,
		"entire overview GPU transition makes zero exact-geometry queries"
	)
	viewport.free()


func test_room_pixels(resolution: Vector2i) -> void:
	var previous := SpacetimeDB.Continuum.db
	var local: LocalDatabase = Fixture.database(128)
	var viewport := SubViewport.new()
	viewport.size = resolution
	viewport.disable_3d = true
	viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	add_child(viewport)
	var map := ColonyMap.new()
	map.size = Vector2(resolution)
	viewport.add_child(map)
	map.set_process(false)
	map.refresh()
	map.zoom_at(16.0 / map._cell_size(), map.size * 0.5)
	var room := ContinuumBuilding.create(
		71, ContinuumBuildingKind.create(0), 60, 60, 0, 7, 5, 4, 175.0
	)
	var overlay := preload("res://ui/components/room_overlay.gd").new()
	overlay.map = map
	overlay.rooms = [room]
	map.add_child(overlay)
	var prefix := "room-%dx%d-" % [resolution.x, resolution.y]
	var detail := await capture(viewport, prefix + "detail")
	overlay.hide()
	var without := await capture(viewport, prefix + "detail-hidden")
	var detail_pixels := changes(detail, without)
	check(
		detail_pixels > 100,
		"actual typed room draws its property envelope in detail at " + str(resolution)
	)
	overlay.show()
	await capture(viewport, prefix + "detail-cached")
	var overview: Dictionary = Fixture.overview_frame(map.terrain_model)
	var queries := Vector2i(map.terrain_model.query_count, map.terrain_model.voxel_query_count)
	check(map.set_terrain_frame(overview), "map accepts authored overview for the room transition")
	var overview_visible := await capture(viewport, prefix + "overview")
	overlay.hide()
	var overview_hidden := await capture(viewport, prefix + "overview-hidden")
	var leaked := changes(overview_visible, overview_hidden)
	check(leaked == 0, "external room leaks zero overview pixels at %s: %d" % [resolution, leaked])
	check(
		queries == Vector2i(map.terrain_model.query_count, map.terrain_model.voxel_query_count),
		"overview room guard does not query exact room exposure"
	)
	overlay.show()
	await capture(viewport, prefix + "overview-cached")
	var detail_frame: Dictionary = map.terrain_model.render_frame(map.visible_grid_rect(2))
	check(
		map.set_terrain_frame(detail_frame),
		"current detail frame restores the same external room control"
	)
	var restored := await capture(viewport, prefix + "restored")
	overlay.hide()
	var restored_hidden := await capture(viewport, prefix + "restored-hidden")
	var restored_pixels := changes(restored, restored_hidden)
	check(
		restored_pixels == detail_pixels,
		"returning detail restores exactly the room envelope pixels at " + str(resolution)
	)
	overlay.show()
	await capture(viewport, prefix + "restored-cached")
	map.streamed_terrain = true
	map.set_cut(-4)
	check(
		map.terrain_view.is_frame_suspended() and not map.set_terrain_frame(detail_frame),
		"streamed map cut suspends its physical presentation and rejects old detail"
	)
	var suspended := await capture(viewport, prefix + "cut-pending")
	overlay.hide()
	check(
		changes(suspended, await capture(viewport, prefix + "cut-pending-hidden")) == 0,
		"external room has no cached physical pixels while current cut data is pending"
	)
	print(
		(
			"ROOM_OVERVIEW_PIXELS resolution=%s detail=%d overview=%d restored=%d"
			% [resolution, detail_pixels, leaked, restored_pixels]
		)
	)
	viewport.free()
	SpacetimeDB.Continuum.db = previous
	local.free()


func test_entity_suspension_pixels() -> void:
	var previous := SpacetimeDB.Continuum.db
	var local := preload("res://tools/terrain_fixture.gd").database()
	var exact := LayeredTerrainModel.new()
	exact.sync(
		local._tables["world_geometry"][0],
		local._tables["terrain_chunk"].values(),
		local._tables["terrain_material"].values()
	)
	var viewport := SubViewport.new()
	viewport.size = Vector2i(512, 256)
	viewport.disable_3d = true
	viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	add_child(viewport)
	var parent := Control.new()
	parent.size = Vector2(viewport.size)
	viewport.add_child(parent)
	var view := new_view(parent)
	var old := exact.render_frame(exact.bounds())
	check(
		view.rebuild_frame(exact, old),
		"real generated-row detail frame installs for entity suspension"
	)
	var entities := [
		{
			"type": "facility",
			"rect": Rect2(3, 0, 2, 1),
			"z": -8,
			"kind": ContinuumTileKind.Options.dining,
			"enabled": true
		}
	]
	var bare := await capture(viewport, "entity-detail-bare")
	view.update_entities(entities)
	var occupied := await capture(viewport, "entity-detail-occupied")
	check(
		changes(bare, occupied) > 100 and not view._entity_masks.is_empty(),
		"whole deep entity actually has visible pixels and an allocated mask before suspension"
	)
	exact.set_cut(-4)
	check(
		not view.rebuild_frame(exact, old) and released(view),
		"stale detail rejection releases formerly active whole-entity images, masks and descriptors"
	)
	var suspended := await capture(viewport, "entity-detail-suspended")
	var pending := {
		"region": exact.bounds(),
		"stride": 1,
		"cut": -4,
		"revision": 99,
		"mode": "detail",
		"samples": {}
	}
	check(view.rebuild_frame(exact, pending), "current pending detail frame is accepted")
	check(
		changes(suspended, await capture(viewport, "entity-detail-pending-reference")) == 0,
		"stale entity/terrain pixels equal a clean current pending frame"
	)
	check(
		view.rebuild_frame(exact, exact.render_frame(exact.bounds())),
		"current exact detail frame restores after suspension"
	)
	bare = await capture(viewport, "entity-new-cut-bare")
	view.update_entities(entities)
	check(
		changes(bare, await capture(viewport, "entity-new-cut-restored")) > 100,
		"fresh whole-entity descriptors restore valid depth-masked pixels after the new cut"
	)
	viewport.free()
	SpacetimeDB.Continuum.db = previous
	local.free()


func _ready() -> void:
	DirAccess.make_dir_recursive_absolute(OUT)
	test_validation()
	test_budget_and_suspension()
	if DisplayServer.get_name() != "headless":
		await test_stale_pixels()
		await test_entity_suspension_pixels()
		for resolution in [Vector2i(1280, 720), Vector2i(1920, 1080)]:
			await test_room_pixels(resolution)
	print(
		(
			"WORLD_ART_REVIEW_%s assertions=%d gpu=%s"
			% [
				"PASS" if failures == 0 else "FAIL",
				assertions,
				DisplayServer.get_name() != "headless"
			]
		)
	)
	get_tree().quit(1 if failures else 0)
