## Material metadata, zoom LOD, cache budgets, continuity and real GPU masks.
extends Node

var failures := 0
var assertions := 0

class OverviewOnlyModel extends LayeredTerrainModel:
	var physical_queries := 0
	func surface_at(_xy: Vector2i) -> Variant:
		physical_queries += 1
		return null
	func material_at(_cell: Vector3i) -> int:
		physical_queries += 1
		return -1

func check(ok: bool, message: String) -> void:
	assertions += 1
	if not ok:
		failures += 1
		push_error(message)

func model_fixture() -> LayeredTerrainModel:
	var chunks: Array = []
	for cx in range(-1, 2):
		for cz in [-1, 0]:
			var values := PackedByteArray()
			values.resize(4096)
			for y in 16:
				for x in 16:
					var wx := cx * 16 + x
					if wx == 8 and y >= 8: continue # known ray without a floor
					var z := 0 if wx < 16 else -4
					if floori(z / 16.0) == cz:
						values[x + 16 * (y + 16 * posmod(z, 16))] = 7 if wx < 0 else 9
			chunks.append({"chunk_x": cx, "chunk_y": 0, "chunk_z": cz, "revision": 1, "materials": values})
	var model := LayeredTerrainModel.new()
	model.sync({"width": 48, "height": 16, "min_x": -16, "min_y": 0, "min_z": -16, "max_z": 15}, chunks,
		[{"id": 0, "name": "air", "opaque": false}, {"id": 7, "name": "soil", "opaque": true}, {"id": 9, "name": "stone", "opaque": true}])
	return model

func test_metadata() -> void:
	var model := model_fixture()
	var full := TerrainArt.surface_data(model, model.bounds())
	var crop_rect := Rect2i(-2, 3, 22, 8)
	var crop := TerrainArt.surface_data(model, crop_rect)
	var identical := true
	var faithful := true
	for y in range(-1, crop_rect.size.y + 1):
		for x in range(-1, crop_rect.size.x + 1):
			var world := crop_rect.position + Vector2i(x, y)
			var a := crop.get_pixel(x + 1, y + 1)
			var b := full.get_pixelv(world - model.bounds().position + Vector2i.ONE)
			identical = identical and a == b
			var surface: Variant = model.surface_at(world)
			faithful = faithful and (a.a == 0 if surface == null else a.g == surface.z and a.a == 1)
	check(identical, "metadata and its halo are world-identical across negative coordinates, chunk edges and camera crops")
	check(faithful, "every metadata height/alpha agrees with the authoritative surface, including missing floors")
	check(TerrainArt.style_index({"id": 9, "name": "soil"}) == 0 and TerrainArt.style_index({"id": 7, "name": "stone"}) == 1, "material names, never ordinal IDs, determine artwork")
	check(TerrainArt.style_index({"name": "new material"}) == 4, "unknown material has a stable neutral fallback")
	check(TerrainArt.blend_compatible(Color(0, -1, 0, 1), Color(1, -1, 0, 1)), "different materials can blend on the same exposed plane")
	check(not TerrainArt.blend_compatible(Color(0, -1, 0, 1), Color(1, -2, 0, 1)), "cliff/cut elevations cannot blend")
	check(not TerrainArt.blend_compatible(Color(0, -1, 0, 1), Color(1, -1, 0, 0)), "unknown and empty rays cannot supply pigment")
	var image := TerrainArt.material_texture().get_image()
	check(image.has_mipmaps(), "material detail has real low-pass texture levels for distance and depth")
	var averages: Array[Color] = []
	for style in 6:
		var average := Color(0, 0, 0, 0)
		for y in range(0, 256, 8):
			for x in range(0, 256, 8):
				average += image.get_pixel(style * 256 + x, y) / 1024.0
		averages.append(average)
	var distinct := true
	for a in 6:
		for b in range(a + 1, 6):
			var delta := Vector3(averages[a].r - averages[b].r, averages[a].g - averages[b].g, averages[a].b - averages[b].b).length()
			distinct = distinct and delta > 0.055
	check(distinct, "all six material families remain distinguishable after detail is averaged away")

func test_lod_and_budget(edge: int) -> void:
	var previous := SpacetimeDB.Continuum.db
	var fixture = preload("res://tools/world_art_fixture.gd")
	var local: LocalDatabase = fixture.database(128 if edge > 256 else edge)
	var map := ColonyMap.new()
	map.size = Vector2(1280, 720)
	add_child(map)
	map.set_process(false)
	map.refresh()
	if edge > 256: fixture.expand_sparse_snapshot(map, local, edge)
	for cell in ([0.5, 4.0, 16.0, 40.0] if edge > 256 else [4.0, 16.0, 40.0]):
		map.zoom_at(cell / map._cell_size(), map.size * 0.5)
		if edge > 256: check(fixture.install_camera_frame(map), "2048 camera installs bounded detail/overview frame")
		var terrain_pixels := 0
		var entity_pixels := 0
		for layer in map.terrain_view.terrain_layers():
			if layer.texture != null:
				terrain_pixels += layer.texture.get_width() * layer.texture.get_height()
		for pass_view in map.terrain_view.viewports:
			entity_pixels += pass_view.size.x * pass_view.size.y
			check(pass_view.size.x <= 2048 and pass_view.size.y <= 2048, "entity edge remains bounded at %d/%s" % [edge, cell])
		check(terrain_pixels <= LayeredTerrainView.MAX_PASS_PIXELS and entity_pixels <= LayeredTerrainView.MAX_PASS_PIXELS + 128, "independent terrain and whole-entity budgets hold at %d/%s" % [edge, cell])
		if edge > 256:
			check(map.terrain_model.surfaces.size() == 128 * 128, "2048 logical world only requires the replicated central patch")
			check(map.terrain_view._active_pages.size() <= 4, "far overview allocates occupied pages, never all logical-world pages")
			for page: Dictionary in map.terrain_view._terrain_pages:
				if page.texture != null:
					check(page.texture.get_width() <= 258 and page.texture.get_height() <= 258, "surface metadata remains page-bounded under extreme zoom-out")
		var baseline := Vector3i(map.terrain_view.terrain_build_count, map.terrain_view.mask_build_count, map.terrain_view.entity_update_count)
		var metadata_id := map.terrain_view._surface_texture.get_instance_id()
		for tick in 8:
			map.refresh({"colony": true, "config": true})
			map._process(1.0 / 60.0)
		check(baseline == Vector3i(map.terrain_view.terrain_build_count, map.terrain_view.mask_build_count, map.terrain_view.entity_update_count), "idle camera/ticks do not rebuild artwork or depth masks")
		check(map.terrain_view._surface_texture.get_instance_id() == metadata_id, "unchanged metadata retains its resource identity")
		for region: Dictionary in map._visible_regions:
			if cell < 22:
				check(not map.region_label_visible(region, cell), "routine region labels are absent below meaningful screen-cell size")
	var region: Dictionary = map._visible_regions[0]
	map._hover_cell = region.anchor
	check(map.region_label_visible(region, 4), "hovered region stays inspectable at distant zoom")
	map._hover_cell = null
	map.set_selected_rect(Rect2i(region.anchor, Vector2i.ONE))
	check(map.region_label_visible(region, 4), "selected region stays readable at distant zoom")
	if region.count > 1:
		map.set_selected_rect(Rect2i(region.cells.keys().back(), Vector2i.ONE))
		check(map.region_label_visible(region, 4), "selection touching a non-anchor cell also preserves the region label")
	check(not MapLabelLod.work(35, 1) and MapLabelLod.work(36, 1) and MapLabelLod.work(4, 1, true), "work text has a separate screen-cell threshold and focus override")
	check(not MapLabelLod.region(32, 2) and MapLabelLod.region(44, 2), "large-font UI uses proportionally larger label thresholds")
	check(MapLabelLod.nameplate(4, 1, true) and not MapLabelLod.nameplate(16, 1), "selected/critical nameplates survive routine-name LOD")
	map.set_selected_colonist(0)
	check(map._get_tooltip(map.world_to_screen(Vector2(edge / 2, edge / 2))).contains("material"), "sparse-world inspection still reports actual replicated material")
	map.free()
	SpacetimeDB.Continuum.db = previous
	local.free()

func test_frame_contract() -> void:
	var model := OverviewOnlyModel.new()
	model.width = 2048
	model.height = 2048
	model.materials = {0: {"name": "air", "opaque": false}, 1: {"name": "soil", "opaque": true}, 2: {"name": "stone", "opaque": true}}
	var parent := Control.new()
	parent.size = Vector2(1280, 720)
	add_child(parent)
	var view := LayeredTerrainView.new()
	view.attach(parent)
	view.layout(Vector2.ZERO, Vector2.ONE * 720)
	for lod in [3, 5, 7, 9]:
		var stride: int = 1 << lod
		var frame := {"region": model.bounds(), "stride": stride, "cut": 0, "revision": lod,
			"mode": "overview", "samples": {
				Vector2i.ZERO: {"known": true, "surface_z": -1, "material": 1},
				Vector2i(stride, 0): {"known": true, "surface_z": -17, "material": 0},
				Vector2i(0, stride): {"known": false},
				Vector2i(stride, stride): {"known": true, "surface_z": -8, "material": 2}}}
		check(view.rebuild_frame(model, frame), "locked overview LOD %d is accepted" % lod)
		check(view.is_overview() and view.pending_samples == model.bounds().get_area() / (stride * stride) - 3, "known empty samples differ from pending at LOD %d" % lod)
		check(model.physical_queries == 0, "overview rendering never asks detail geometry to infer physical surfaces")
		view.update_entities([{"type": "facility", "z": 0, "rect": Rect2(0, 0, 1, 1), "kind": ContinuumTileKind.Options.farm, "enabled": true}])
		check(view.canvases.all(func(canvas: Node2D) -> bool: return canvas.entities.is_empty()), "overview representatives never authorize entity visibility")
		var before := view.terrain_build_count
		check(view.rebuild_frame(model, frame) and view.terrain_build_count == before, "unchanged frame keys do not rebuild cached material pages")
		var data := TerrainArt.frame_data(frame, Rect2i(0, 0, stride * 2, stride * 2), model.materials)
		check(data.get_pixel(2, 1).a == 1 and data.get_pixel(2, 1).r == -1 and data.get_pixel(1, 2).a == 0, "frame metadata preserves resolved-empty versus pending semantics")
	var stale := {"region": model.bounds(), "stride": 8, "cut": 1, "revision": 99, "mode": "overview", "samples": {}}
	check(not view.rebuild_frame(model, stale), "a different cut's overview cannot silently replace this frame")
	stale.cut = 0
	stale.stride = 2
	check(not view.rebuild_frame(model, stale), "unsupported overview stride is rejected rather than guessed")
	stale.stride = 1
	stale.mode = "detail"
	check(not view.rebuild_frame(model, stale), "4M-cell detail frame is rejected even when its dictionary is sparse; caller must choose overview")
	parent.free()

func capture(viewport: SubViewport) -> Image:
	for frame in 3: await RenderingServer.frame_post_draw
	return viewport.get_texture().get_image()

func difference(a: Image, b: Image, rect: Rect2i, offset := Vector2i.ZERO) -> float:
	var maximum := 0.0
	for y in range(rect.position.y, rect.end.y):
		for x in range(rect.position.x, rect.end.x):
			var ca := a.get_pixel(x, y)
			var cb := b.get_pixel(x + offset.x, y + offset.y)
			maximum = maxf(maximum, absf(ca.r - cb.r) + absf(ca.g - cb.g) + absf(ca.b - cb.b) + absf(ca.a - cb.a))
	return maximum

func test_gpu() -> void:
	var model := model_fixture()
	var viewport := SubViewport.new()
	viewport.size = Vector2i(512, 256)
	viewport.disable_3d = true
	viewport.transparent_bg = true
	viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	add_child(viewport)
	var parent := Control.new()
	parent.size = Vector2(viewport.size)
	viewport.add_child(parent)
	var view := LayeredTerrainView.new()
	view.attach(parent)
	view.layout(Vector2(128, 0), Vector2(48, 16) * 16)
	view.rebuild(model)
	view.set_visible(true)
	var reference := await capture(viewport)
	var opaque := true
	var backing := ThemeTokens.color("map-ground-deep")
	for y in 256:
		for x in range(2, 510):
			var world := Vector2i(floori((x - 128) / 16.0), floori(y / 16.0))
			if model.surface_at(world) != null and reference.get_pixel(x, y).is_equal_approx(backing):
				opaque = false
	check(opaque, "every known surface pixel including cliff corners has exact opaque coverage, without linear-mask holes")
	# Force a spatial-page boundary through the visible material seam, holding
	# camera/world geometry fixed. Page allocation must not change a single mark.
	var split: Array[Dictionary] = []
	for area in [Rect2i(-10, 0, 10, 16), Rect2i(0, 0, 26, 16)]:
		var cells: Array = []
		for xy: Vector2i in model.surfaces:
			if area.has_point(xy): cells.append(xy)
		split.append({"region": area, "cells": cells})
	view._active_pages = split
	view._build_terrain()
	view._layout_layers()
	var paged := await capture(viewport)
	check(difference(reference, paged, Rect2i(4, 4, 504, 244)) < 0.015, "GPU fixed-size terrain pages reconstruct the same world texture and masks without seams")
	view.layout(Vector2.ZERO, Vector2(48, 16) * 16)
	var shifted := await capture(viewport)
	var seam := difference(reference, shifted, Rect2i(130, 4, 376, 244), Vector2i(-128, 0))
	check(seam < 0.015, "actual GPU material pixels stay continuous across camera recrops and chunk boundaries; error=%f" % seam)
	# Soil/stone share z=0 at world x=0. A softened material seam must have much
	# less jump than the interior colour separation at the same y.
	view.layout(Vector2(128, 0), Vector2(48, 16) * 16)
	var boundary := await capture(viewport)
	var edge_delta := (Vector3(boundary.get_pixel(127, 64).r, boundary.get_pixel(127, 64).g, boundary.get_pixel(127, 64).b) - Vector3(boundary.get_pixel(128, 64).r, boundary.get_pixel(128, 64).g, boundary.get_pixel(128, 64).b)).length()
	var interior_delta := (Vector3(boundary.get_pixel(118, 64).r, boundary.get_pixel(118, 64).g, boundary.get_pixel(118, 64).b) - Vector3(boundary.get_pixel(137, 64).r, boundary.get_pixel(137, 64).g, boundary.get_pixel(137, 64).b)).length()
	check(interior_delta > 0.06 and edge_delta < interior_delta * 0.6, "GPU same-plane material edge is soft while interiors stay distinct")
	# Change every material on the lower ledge; intact near-floor pixels including
	# their exact shared edge must remain identical, not merely nearly similar.
	model.materials[9] = {"name": "clay", "opaque": true}
	for xy: Vector2i in model.surfaces:
		var surface: Vector3i = model.surfaces[xy]
		if surface.x < 16 and surface.x >= 0:
			var ck := Vector3i(floori(surface.x / 16.0), 0, 0)
			model.chunks[ck][posmod(surface.x, 16) + 16 * surface.y] = 7
	model.revision += 1
	view.rebuild(model)
	var cliff_before := await capture(viewport)
	model.materials[9] = {"name": "sand", "opaque": true}
	model.revision += 1
	view.rebuild(model)
	var cliff_after := await capture(viewport)
	check(difference(cliff_before, cliff_after, Rect2i(368, 8, 16, 232)) < 0.001, "lower-cliff pigment never bleeds into intact upper-plane pixels")
	# A floorless cell is entirely the deep ground backing, never neighbouring art.
	var hole_colour := cliff_after.get_pixel(128 + 8 * 16 + 8, 10 * 16 + 8)
	check(hole_colour.is_equal_approx(ThemeTokens.color("map-ground-deep")), "floorless rays retain the exact unknown/deep backing through material blending")
	var count := view.terrain_build_count
	view.layout(Vector2(128, 0), Vector2(48, 16) * 16)
	check(view.terrain_build_count == count, "repeat GPU camera state reuses material metadata")
	var overview := OverviewOnlyModel.new()
	overview.width = 2048
	overview.height = 2048
	overview.materials = {0: {"name": "air", "opaque": false}, 1: {"name": "soil", "opaque": true}}
	var frame := {"region": overview.bounds(), "stride": 512, "cut": 0, "revision": 1, "mode": "overview", "samples": {
		Vector2i.ZERO: {"known": true, "surface_z": -1, "material": 1},
		Vector2i(512, 0): {"known": true, "surface_z": -17, "material": 0}}}
	view.layout(Vector2.ZERO, Vector2(512, 256))
	check(view.rebuild_frame(overview, frame), "2048 representative-only GPU frame loads without exact terrain")
	var overview_pixels := await capture(viewport)
	check(overview.physical_queries == 0, "GPU overview remains independent of physical picking and decoding")
	check(overview_pixels.get_pixel(160, 32).is_equal_approx(ThemeTokens.color("map-ground-deep")), "known-empty overview rays draw their resolved deep backing")
	check(not overview_pixels.get_pixel(32, 96).is_equal_approx(ThemeTokens.color("map-ground-deep")) and overview_pixels.get_pixel(32, 96).r < 0.2, "missing overview samples are visibly pending, never invented earth")
	viewport.free()

func _ready() -> void:
	test_metadata()
	test_frame_contract()
	for edge in [128, 256, 2048]: test_lod_and_budget(edge)
	if DisplayServer.get_name() != "headless": await test_gpu()
	print("WORLD_ART_TEST_%s assertions=%d gpu=%s" % ["PASS" if failures == 0 else "FAIL", assertions, DisplayServer.get_name() != "headless"])
	get_tree().quit(1 if failures else 0)
