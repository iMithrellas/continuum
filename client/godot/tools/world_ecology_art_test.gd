## Fresh-world ecology/hatch regressions. Typed compact rows, no server/transport.
extends Node

const OUT := "res://build/ecology-art"
const XY := Vector2i(512, 512)
var assertions := 0
var failures := 0


class TrackedModel:
	extends LayeredTerrainModel
	var requests: Array = []

	func frame_samples(rect: Rect2i, stride := 1, budget := MAX_FRAME_SAMPLES) -> Dictionary:
		requests.append([rect, stride, budget])
		return super.frame_samples(rect, stride, budget)


class HatchCanvas:
	extends Node2D
	var dense := true

	func _draw() -> void:
		for index in 10:
			var side: float = [0.0, 0.01, 0.25, 0.5, 1.0, 2.0, 4.0, 8.0, 16.0, 32.0][index]
			var rect := Rect2(8 + index * 45, 16, side, side)
			if dense:
				for direction in [-1.0, 1.0]:
					MapPaint.hatch(
						self,
						rect,
						Vector2(1234.125, -512.5),
						side * 0.1875,
						Color.WHITE,
						1,
						direction
					)
			MapPaint.selection(
				self, Rect2(rect.position + Vector2(0, 48), Vector2.ONE * maxf(1, side))
			)
			MapPaint.plan_edge(
				self, rect.position + Vector2(0, 100), rect.position + Vector2(12, 100)
			)
		if dense:
			for offset in 24:
				MapPaint.hatch(
					self,
					Rect2(8 + offset * 18, 164, 16, 32),
					Vector2(offset * 0.125, -offset * 0.25),
					3,
					Color.WHITE,
					1
				)


func check(ok: bool, message: String) -> void:
	assertions += 1
	if not ok:
		failures += 1
		push_error(message)


func materials() -> Array:
	var rows: Array = []
	for id in 3:
		var row := ContinuumTerrainMaterial.new()
		row.id = id
		row.name = ["air", "soil", "stone"][id]
		row.opaque = id != 0
		rows.append(row)
	return rows


func source() -> ContinuumTerrainColumnChunk:
	var row := ContinuumTerrainColumnChunk.new()
	row.id = 17
	row.chunk_x = 16
	row.chunk_y = 16
	row.generation_id = 9
	row.revision = 1
	row.base_z.resize(1024)
	row.base_z.fill(13)
	for field in ["soil_depth", "soil_fertility", "forest_density", "moisture"]:
		var values := PackedByteArray()
		values.resize(1024)
		values.fill(
			{"soil_depth": 3, "soil_fertility": 100, "forest_density": 128, "moisture": 159}[field]
		)
		row.set(field, values)
	row.soil_fertility[1] = 255
	return row


func test_typed_tooltip() -> void:
	var previous := SpacetimeDB.Continuum.db
	var fixture = preload("res://tools/terrain_fixture.gd")
	var local: LocalDatabase = fixture.database(false)
	var geometry := ContinuumWorldGeometry.new()
	geometry.width = 2048
	geometry.height = 2048
	geometry.min_z = -16
	geometry.max_z = 15
	local._tables["world_geometry"][0] = geometry
	var exact := TrackedModel.new()
	exact.set_geometry(geometry)
	exact.set_materials(materials())
	exact.configure_sources(32, CompactTerrainAdapter.read_material)
	exact.set_cut(15)
	var row := source()
	check(
		CompactTerrainAdapter.valid_source(row, 9),
		"real generated compact binding carries all five 1024-value arrays"
	)
	exact.apply_source_chunk(Vector2i(16, 16), row, row.revision)
	var map := ColonyMap.new()
	map.size = Vector2(1280, 720)
	map.streamed_terrain = true
	add_child(map)
	map.set_process(false)
	map.bind_world_source(SpacetimeDB.Continuum.db)
	map.terrain_model = exact
	map.refresh()
	map.prepare_stream_camera(XY)
	check(
		map._ecology_fields(null, XY).is_empty(), "unacknowledged compact payload remains unknown"
	)
	exact.set_chunk_complete(Vector2i(16, 16), true)
	exact.requests.clear()
	var fields := map._ecology_fields(null, XY)
	check(
		(
			fields
			== {
				"soil_fertility": 100.0 / 255.0,
				"forest_density": 128.0 / 255.0,
				"moisture": 159.0 / 255.0
			}
		),
		"remote loaded ecology uses exact normalized 100/128/159 values"
	)
	check(
		exact.requests == [[Rect2i(XY, Vector2i.ONE), 1, 1]],
		"fallback requests one exact point with a one-sample budget"
	)
	var tooltip := map._get_tooltip(map.world_to_screen(Vector2(XY) + Vector2.ONE * 0.5))
	check(
		tooltip.contains("fertility 0.39  moisture 0.62") and tooltip.contains("density 0.50"),
		"remote tooltip includes authored soil and cover potential without a Tile row"
	)
	check(
		(
			tooltip.contains("Farming: 74%")
			and tooltip.contains("Logging: 100%")
			and tooltip.contains("Hunting: 100%")
			and not tooltip.contains("unavailable")
		),
		"reported remote point presents terrain-only production potential"
	)
	check(
		map._potential_yield(XY, ContinuumTileKind.Options.farm) == "potential 74%",
		"placement anchor uses the same exact ecology"
	)
	check(
		map._ecology_fields(null, XY + Vector2i.RIGHT).soil_fertility == 1.0,
		"distinct neighbour retains its own value"
	)
	check(
		map._ecology_fields(null, XY - Vector2i.RIGHT).is_empty(),
		"adjacent unloaded point never borrows acknowledged ecology"
	)
	var tile := ContinuumTile.create(
		9917, 512, 512, ContinuumTileKind.create_empty(), true, 13, 1, 1, 1
	)
	var ecology := ContinuumTerrain.new()
	ecology.tile_id = tile.id
	ecology.soil_fertility = 0.8
	ecology.moisture = 0.5
	ecology.forest_density = 0.2
	local._tables["tile"][tile.id] = tile
	local._tables["terrain"][tile.id] = ecology
	fixture.index_rows(local)
	map.refresh({"tile": true})
	exact.requests.clear()
	check(
		map._ecology_fields(tile, XY).soil_fertility == 0.8 and exact.requests.is_empty(),
		"durable operational Tile ecology wins without a compact query"
	)
	check(
		map._potential_yield(XY, ContinuumTileKind.Options.farm) == "potential 90%",
		"existing Tile-linked suitability stays authoritative"
	)
	exact.presentation_mode = &"overview"
	var before := Vector2i(exact.query_count, exact.voxel_query_count)
	check(
		(
			map._get_tooltip(map.size * 0.5).contains("zoom in to inspect")
			and map._potential_yield(XY, ContinuumTileKind.Options.forest) == "potential unknown"
		),
		"overview exposes neither precise ecology inspection nor physical potential"
	)
	check(
		(
			map._ecology_fields(tile, XY).is_empty()
			and exact.requests.is_empty()
			and before == Vector2i(exact.query_count, exact.voxel_query_count)
		),
		"overview tooltip/potential has zero exact or representative fallback queries"
	)
	var overview := {
		"region": Rect2i(XY, Vector2i.ONE * 32),
		"stride": 8,
		"cut": 15,
		"revision": 8,
		"mode": "overview",
		"samples":
		{
			XY:
			{
				"known": true,
				"surface_z": 12,
				"material": 1,
				"soil_fertility": 1.0,
				"forest_density": 1.0,
				"moisture": 1.0
			}
		}
	}
	check(
		map.set_terrain_frame(overview),
		"typed compact map accepts representative ecology without authorizing physical detail"
	)
	var picks := [0]
	map.cell_selected.connect(func(_cell: Vector3i) -> void: picks[0] += 1)
	var click := InputEventMouseButton.new()
	click.button_index = MOUSE_BUTTON_LEFT
	click.pressed = true
	click.position = map.size * 0.5
	map._gui_input(click)
	check(
		(
			picks[0] == 0
			and not map.selected_rect().has_area()
			and exact.presentation_mode == &"detail"
		),
		"overview click requests detail without selecting a representative or its ecological potential"
	)
	check(
		map.set_terrain_frame(exact.render_frame(Rect2i(XY, Vector2i.ONE))),
		"exact detail resumes after overview"
	)
	exact.evict_source_chunk(Vector2i(16, 16))
	check(map._ecology_fields(null, XY).is_empty(), "evicted exact ecology returns to unknown")
	map.free()
	SpacetimeDB.Continuum.db = previous
	local.free()


func render_model(width := 32, height := 16) -> LayeredTerrainModel:
	var model := LayeredTerrainModel.new()
	model.width = width
	model.height = height
	model.set_materials(materials())
	return model


func frame(region := Rect2i(0, 0, 32, 16)) -> Dictionary:
	var samples := {}
	for y in range(region.position.y, region.end.y):
		for x in range(region.position.x, region.end.x):
			samples[Vector2i(x, y)] = {"known": true, "surface_z": 0, "material": 1}
	return {
		"region": region, "stride": 1, "cut": 0, "revision": 1, "mode": "detail", "samples": samples
	}


func new_view(parent: Control) -> LayeredTerrainView:
	var view := LayeredTerrainView.new()
	view.attach(parent)
	view.layout(Vector2.ZERO, parent.size)
	view.set_visible(true)
	return view


func add_ecology(data: Dictionary) -> void:
	for xy: Vector2i in data.samples:
		data.samples[xy].merge(
			{
				"soil_fertility": 100.0 / 255.0,
				"forest_density": 128.0 / 255.0,
				"moisture": 159.0 / 255.0
			},
			true
		)


func test_validation_and_budget() -> void:
	var model := render_model(512, 128)
	model.min_z = -31
	model.max_z = 0
	var parent := Control.new()
	parent.size = Vector2(1280, 320)
	add_child(parent)
	var view := new_view(parent)
	var data := frame(Rect2i(0, 0, 512, 128))
	add_ecology(data)
	for xy: Vector2i in data.samples:
		data.samples[xy].surface_z = -posmod(xy.x + xy.y, 32)
	var begin := Time.get_ticks_usec()
	check(view.rebuild_frame(model, data), "maximum optional-ecology frame installs")
	var install_ms := (Time.get_ticks_usec() - begin) / 1000.0
	var images := {}
	for page: Dictionary in view._terrain_pages:
		if page.texture != null:
			images[page.texture.get_instance_id()] = page.texture
	for layer: TextureRect in view.terrain_layers():
		for texture: Texture2D in [
			layer.texture,
			layer.material.get_shader_parameter("surface_data"),
			layer.material.get_shader_parameter("visibility_mask")
		]:
			if texture != null:
				images[texture.get_instance_id()] = texture
	var bytes := 0
	for texture: Texture2D in images.values():
		bytes += texture.get_image().get_data().size()
	check(
		bytes == 9470208 and view._active_pages.size() == 4,
		"ecology uses the existing blue channel: all masks/metadata/TextureRefs still total 9470208 bytes"
	)
	var stable := Vector2i(view.terrain_build_count, view.mask_build_count)
	begin = Time.get_ticks_usec()
	for tick in 3:
		check(view.rebuild_frame(model, data), "identical ecological frame reuses image cache")
		view.layout(Vector2.ZERO, parent.size)
	check(
		stable == Vector2i(view.terrain_build_count, view.mask_build_count),
		"optional ecology causes zero idle terrain/mask rebuilds"
	)
	print(
		(
			"ECOLOGY_BUDGET samples=65536 pages=4 bytes=%d install_ms=%.3f cache_ms=%.3f idle_rebuilds=0"
			% [bytes, install_ms, (Time.get_ticks_usec() - begin) / 3000.0]
		)
	)
	for field in TerrainArt.ECOLOGY_FIELDS:
		for invalid: Variant in [null, true, "0.5", [], {}, NAN, INF, -0.01, 1.01]:
			for revision in [1, 2]:
				var candidate := frame(Rect2i(0, 0, 1, 1))
				candidate.region = data.region
				candidate.revision = revision
				candidate.samples[Vector2i.ZERO][field] = invalid
				check(
					not view.rebuild_frame(model, candidate),
					"invalid optional %s rejected: %s" % [field, invalid]
				)
		var mutated: float = data.samples[Vector2i.ZERO][field]
		data.samples[Vector2i.ZERO][field] = 0.0
		check(
			not view.rebuild_frame(model, data),
			"changed valid ecology cannot reuse an immutable frame key"
		)
		check(
			view._frame.samples[Vector2i.ZERO][field] == mutated,
			"caller ecology mutation cannot modify the retained snapshot"
		)
		data.samples[Vector2i.ZERO][field] = mutated
	for field in TerrainArt.ECOLOGY_FIELDS:
		for raw in 256:
			var sample := {field: raw / 255.0}
			var packed := int(TerrainArt.ecology_code(sample))
			var index := TerrainArt.ECOLOGY_FIELDS.find(field)
			var decoded := (((packed >> (index * 8)) & 255) - 1) / 254.0
			check(
				absf(decoded - sample[field]) <= 1.0 / 508.0 + 0.000001,
				"present u8 ecology survives pigment quantization with bounded error"
			)
	check(
		TerrainArt.ecology_code({}) == 0 and TerrainArt.ecology_code({"soil_fertility": 0.0}) == 1,
		"missing ecology and measured zero have different texture codes"
	)
	var partial := frame(Rect2i(0, 0, 3, 1))
	partial.revision = 3
	partial.samples[Vector2i.ZERO].soil_fertility = 0
	partial.samples[Vector2i.RIGHT] = {"known": false, "forest_density": 1.0}
	partial.samples[Vector2i(2, 0)] = {
		"known": true, "material": 0, "surface_z": -32, "moisture": 0.5
	}
	check(
		view.rebuild_frame(model, partial),
		"independently optional normalized fields allow measured zero and column data without a floor"
	)
	check(
		(
			not view._frame.samples[Vector2i.ZERO].has("forest_density")
			and view._frame.samples[Vector2i.RIGHT].forest_density == 1.0
			and view._frame.samples[Vector2i(2, 0)].moisture == 0.5
		),
		"snapshots preserve partial, pending and empty column ecology without filling absent fields"
	)
	partial.samples[Vector2i.RIGHT].forest_density = NAN
	check(
		not view.rebuild_frame(model, partial),
		"pending samples cannot bypass optional-value validation on a reused cache key"
	)
	parent.free()


func capture(viewport: SubViewport, name: String) -> Image:
	for tick in 3:
		await RenderingServer.frame_post_draw
	var image := viewport.get_texture().get_image()
	image.save_png(OUT + "/" + name + ".png")
	return image


func difference(
	a: Image, b: Image, region: Rect2i, shift := Vector2i.ZERO, ignore := Rect2i()
) -> float:
	var result := 0.0
	for y in range(region.position.y, region.end.y):
		for x in range(region.position.x, region.end.x):
			if ignore.has_point(Vector2i(x, y)):
				continue
			var p := a.get_pixel(x, y)
			var q := b.get_pixelv(Vector2i(x, y) + shift)
			result = maxf(
				result, absf(p.r - q.r) + absf(p.g - q.g) + absf(p.b - q.b) + absf(p.a - q.a)
			)
	return result


func test_gpu() -> void:
	var viewport := SubViewport.new()
	viewport.size = Vector2i(512, 256)
	viewport.disable_3d = true
	viewport.transparent_bg = true
	viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	add_child(viewport)
	var parent := Control.new()
	parent.size = Vector2(viewport.size)
	viewport.add_child(parent)
	var model := render_model()
	var view := new_view(parent)
	var data := frame()
	for xy: Vector2i in data.samples:
		if xy.x >= 16:
			data.samples[xy].material = 2
	data.samples[Vector2i(4, 4)] = {"known": false}
	data.samples[Vector2i(5, 4)] = {"known": true, "material": 0, "surface_z": -17}
	check(view.rebuild_frame(model, data), "GPU absent-ecology baseline installs")
	var baseline := await capture(viewport, "detail-absent")
	add_ecology(data)
	for field in TerrainArt.ECOLOGY_FIELDS:
		data.samples[Vector2i(6, 4)].erase(field)
	data.revision += 1
	check(view.rebuild_frame(model, data), "GPU reported remote ecology installs")
	var ecology := await capture(viewport, "detail-remote-ecology")
	check(
		difference(baseline, ecology, Rect2i(0, 0, 256, 256)) > 0.10,
		"authoritative soil/cover values produce visible pigment cues"
	)
	check(
		difference(baseline, ecology, Rect2i(256, 0, 256, 256)) == 0,
		"ecology never colours stone, including its soil-blended edge"
	)
	check(
		difference(baseline, ecology, Rect2i(64, 64, 32, 16)) == 0,
		"pending and known-empty pixels remain byte-identical with optional ecology"
	)
	check(
		difference(baseline, ecology, Rect2i(96, 64, 16, 16)) == 0,
		"known soil lacking ecology never borrows its neighbours' measured cover or moisture"
	)
	# Rebuild the same samples into explicit pages, then move the camera: ecology
	# must share the material artwork's world/crop continuity and exact masks.
	view._active_pages = []
	for region in [Rect2i(0, 0, 8, 16), Rect2i(8, 0, 24, 16)]:
		var cells: Array = []
		for xy: Vector2i in data.samples:
			if region.has_point(xy) and data.samples[xy].known:
				cells.append(xy)
		view._active_pages.append({"region": region, "cells": cells})
	view._build_terrain()
	view._layout_layers()
	check(
		(
			difference(ecology, await capture(viewport, "detail-paged"), Rect2i(0, 0, 512, 256))
			< 0.015
		),
		"ecology pigment is identical across spatial page seams"
	)
	view.layout(Vector2(-64, 0), parent.size)
	# Pending hatch is intentionally screen-anchored; all resolved pixels (including
	# known-empty backing) must remain world-identical under the camera translation.
	check(
		(
			difference(
				ecology,
				await capture(viewport, "detail-cropped"),
				Rect2i(64, 0, 448, 256),
				Vector2i(-64, 0),
				Rect2i(64, 64, 16, 16)
			)
			< 0.015
		),
		"ecology pigment is world-identical after camera recrop"
	)
	view.layout(Vector2.ZERO, parent.size)
	var overview := {
		"region": Rect2i(0, 0, 32, 16),
		"stride": 8,
		"cut": 0,
		"mode": "overview",
		"revision": 20,
		"samples": {Vector2i.ZERO: {"known": true, "surface_z": 0, "material": 1}}
	}
	var queries := Vector2i(model.query_count, model.voxel_query_count)
	check(view.rebuild_frame(model, overview), "representative overview installs")
	var representative := await capture(viewport, "overview-absent")
	add_ecology(overview)
	overview.revision += 1
	check(
		view.rebuild_frame(model, overview),
		"representative optional ecology validates without becoming physical detail"
	)
	check(
		(
			(
				difference(
					representative,
					await capture(viewport, "overview-with-ecology"),
					Rect2i(0, 0, 512, 256)
				)
				== 0
			)
			and queries == Vector2i(model.query_count, model.voxel_query_count)
		),
		"overview optional data claims no exact ecological texture or physical query"
	)
	viewport.free()
	viewport = SubViewport.new()
	viewport.size = Vector2i(480, 224)
	viewport.disable_3d = true
	viewport.transparent_bg = true
	viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	add_child(viewport)
	var hatches := HatchCanvas.new()
	viewport.add_child(hatches)
	var hatch := await capture(viewport, "hatch-lod")
	hatches.dense = false
	hatches.queue_redraw()
	var outline := await capture(viewport, "hatch-cues-only")
	check(
		difference(hatch, outline, Rect2i(0, 0, 6 * 45, 48)) == 0,
		"degenerate/subpixel distant hatch fill is omitted"
	)
	check(
		(
			difference(hatch, outline, Rect2i(0, 48, 480, 96)) == 0
			and outline.get_pixel(10, 115).a > 0
		),
		"useful selection and plan-perimeter cues survive hatch LOD"
	)
	check(
		difference(hatch, outline, Rect2i(0, 160, 480, 48)) > 0.1,
		"near hatch remains visible through clipped sliver stress cases"
	)
	viewport.free()


func _ready() -> void:
	DirAccess.make_dir_recursive_absolute(OUT)
	test_typed_tooltip()
	test_validation_and_budget()
	if DisplayServer.get_name() != "headless":
		await test_gpu()
	print(
		(
			"WORLD_ECOLOGY_ART_%s assertions=%d gpu=%s"
			% [
				"PASS" if failures == 0 else "FAIL",
				assertions,
				DisplayServer.get_name() != "headless"
			]
		)
	)
	get_tree().quit(1 if failures else 0)
