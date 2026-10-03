## Masked, far-to-near depth compositor. Terrain is cached; complete entity icons
## are drawn once into feet-layer offscreen passes. Overlays stay on the parent.
class_name LayeredTerrainView
extends RefCounted

const SHADER = preload("res://shaders/terrain_depth.gdshader")
const SURFACE_SHADER = preload("res://shaders/terrain_surface.gdshader")
const PENDING_SHADER = preload("res://shaders/terrain_pending.gdshader")
const ENTITY_CANVAS = preload("res://scripts/terrain_entity_canvas.gd")
const PIXELS := 32
const MAX_TEXTURE_EDGE := 2048
const MAX_PASS_PIXELS := 8 * 1024 * 1024
const CAMERA_PADDING := 2
const SURFACE_PAGE_EDGE := 128
const SINGLE_PAGE_EDGE := 256
var layers: Array[TextureRect] = []
var entity_layers: Array[TextureRect] = []
var viewports: Array[SubViewport] = []
var canvases: Array[Node2D] = []
var parent_control: Control
var _ground: ColorRect
var _visible := false
var _model: LayeredTerrainModel
var _origin := Vector2.ZERO
var _extent := Vector2.ZERO
var _region := Rect2i()
var _pixels := PIXELS
var _render_revision := -1
var _entity_masks: Dictionary = {}
var _surface_texture: ImageTexture
var _surface_index_revision := -1
var _surface_buckets: Dictionary = {}
var _terrain_pages: Array[Dictionary] = []
var _active_pages: Array[Dictionary] = []
var _frame: Dictionary = {}
var _frame_key: Array = []
var _stride := 1
var pending_samples := 0
var _entities: Array = []
var _entity_regions: Array[Rect2i] = []
## Counters for backend-free cache regressions/profiling, not frame polling.
var terrain_build_count := 0
var mask_build_count := 0
var entity_update_count := 0

func attach(parent: Control) -> void:
	parent_control = parent
	_ground = ColorRect.new()
	_ground.color = ThemeTokens.color("map-ground-deep")
	_ground.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_ground.show_behind_parent = true
	_ground.z_index = -4096
	_ground.visible = false
	parent.add_child(_ground)

func _new_layer(depth: int, entity: bool) -> TextureRect:
	var layer := TextureRect.new()
	layer.mouse_filter = Control.MOUSE_FILTER_IGNORE
	layer.show_behind_parent = true
	layer.z_index = -depth * 2 - (1 if entity else 2)
	layer.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	# Compatibility GL shares sampler state between the source texture and its mask.
	layer.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR if entity else CanvasItem.TEXTURE_FILTER_NEAREST
	var effect := ShaderMaterial.new()
	effect.shader = SHADER if entity else SURFACE_SHADER
	if not entity:
		effect.set_shader_parameter("material_atlas", TerrainArt.material_texture())
	effect.set_shader_parameter("radius", depth * 0.65)
	effect.set_shader_parameter("darkness", pow(0.97, depth))
	effect.set_shader_parameter("mask_enabled", true)
	effect.set_shader_parameter("opaque_coverage", not entity)
	layer.material = effect
	parent_control.add_child(layer)
	return layer

func _ensure_bands(count: int) -> void:
	for depth in range(layers.size(), count):
		layers.append(_new_layer(depth, false))
		entity_layers.append(_new_layer(depth, true))
		var viewport := SubViewport.new()
		viewport.disable_3d = true
		viewport.transparent_bg = true
		viewport.render_target_update_mode = SubViewport.UPDATE_DISABLED
		parent_control.add_child(viewport)
		var canvas := ENTITY_CANVAS.new()
		canvas.pixels = PIXELS
		viewport.add_child(canvas)
		viewports.append(viewport)
		canvases.append(canvas)
		_entity_regions.append(Rect2i())

func rebuild(model: LayeredTerrainModel) -> void:
	if not _frame.is_empty():
		_frame = {}
		_frame_key = []
		_stride = 1
		pending_samples = 0
		_render_revision = -1
		_surface_index_revision = -1
		_ground.material = null
	_model = model
	var count := model.max_z - model.min_z + 1
	_ensure_bands(count)
	_sync_region()
	layout(_origin, _extent)

## Explicit streaming adapter. No whole-world/whole-array fallback is made for
## compact worlds. The client owns sample residency, stale-epoch rejection and
## exact decoding. Samples <=65536; overview never authorizes physical queries.
func rebuild_frame(model: LayeredTerrainModel, frame: Dictionary) -> bool:
	if not frame.has_all(["region", "stride", "cut", "revision", "mode", "samples"]): return false
	if not frame.region is Rect2i or not frame.samples is Dictionary: return false
	var stride := int(frame.stride)
	if stride < 1 or frame.samples.size() > 65536 or int(frame.cut) != model.cut: return false
	if frame.mode not in ["detail", "overview"] or (frame.mode == "detail" and stride != 1): return false
	if frame.mode == "overview" and stride not in [8, 32, 128, 512]: return false
	if posmod(frame.region.position.x, stride) != 0 or posmod(frame.region.position.y, stride) != 0: return false
	if posmod(frame.region.size.x, stride) != 0 or posmod(frame.region.size.y, stride) != 0: return false
	if not frame.region.has_area() or frame.region.get_area() / (stride * stride) > 65536: return false
	if frame.mode == "detail" and maxi(frame.region.size.x, frame.region.size.y) > MAX_TEXTURE_EDGE: return false
	var key: Array = [model.get_instance_id(), model.revision, frame.revision, frame.region, stride, frame.cut, frame.mode]
	if key == _frame_key: return true
	for xy: Variant in frame.samples:
		if not xy is Vector2i or posmod(xy.x, stride) != 0 or posmod(xy.y, stride) != 0: return false
		var sample: Variant = frame.samples[xy]
		if not sample is Dictionary: return false
		if sample.get("known", false) and not sample.has_all(["surface_z", "material"]): return false
		if sample.get("known", false) and int(sample.material) != 0 and (int(sample.surface_z) < model.min_z or int(sample.surface_z) > model.cut): return false
	_model = model
	_frame = frame
	_frame_key = key
	_stride = stride
	_render_revision = -1
	_surface_index_revision = -1
	pending_samples = frame.region.get_area() / (stride * stride)
	for xy: Vector2i in frame.samples:
		if frame.region.has_point(xy) and frame.samples[xy].get("known", false): pending_samples -= 1
	pending_samples = maxi(0, pending_samples)
	if _ground.material == null:
		var pending := ShaderMaterial.new()
		pending.shader = PENDING_SHADER
		_ground.material = pending
	_sync_region()
	_layout_layers()
	return true

func is_overview() -> bool:
	return _frame.get("mode", "detail") == "overview"

func presentation_status() -> String:
	if is_overview():
		return "Terrain overview · zoom in to inspect" + (" · loading" if pending_samples > 0 else "")
	return "Terrain loading · waiting for viewport data" if pending_samples > 0 else ""

func _sync_region() -> void:
	if _model == null:
		return
	_ensure_bands(_model.max_z - _model.min_z + 1)
	var bounds := _model.bounds()
	var region := bounds
	if _extent.x > 0 and _extent.y > 0:
		var cell := _extent / Vector2(_model.width, _model.height)
		var start := -_origin / cell
		var end := (parent_control.size - _origin) / cell
		region = Rect2i(Vector2i(floori(start.x), floori(start.y)) - Vector2i.ONE * CAMERA_PADDING,
			Vector2i(ceili(end.x), ceili(end.y)) - Vector2i(floori(start.x), floori(start.y)) + Vector2i.ONE * CAMERA_PADDING * 2).intersection(bounds)
	if not _frame.is_empty():
		var aligned_start := Vector2i((Vector2(region.position) / _stride).floor()) * _stride
		var aligned_end := Vector2i((Vector2(region.end) / _stride).ceil()) * _stride
		region = Rect2i(aligned_start, aligned_end - aligned_start).intersection(_frame.region)
	if region == _region and _render_revision == _model.revision:
		return
	_region = region
	_pixels = PIXELS
	_index_surfaces()
	_collect_pages()
	_render_revision = _model.revision
	_entity_masks.clear()
	_build_terrain()
	_apply_entities(true)

func _build_terrain() -> void:
	terrain_build_count += 1
	for index in _active_pages.size():
		_build_page(index, _active_pages[index])
	for index in range(_active_pages.size(), _terrain_pages.size()):
		for layer: TextureRect in _terrain_pages[index].layers:
			if layer != null:
				layer.texture = null
				layer.visible = false
				layer.material.set_shader_parameter("surface_data", null)
				layer.material.set_shader_parameter("visibility_mask", null)
		_terrain_pages[index].texture = null
	if _active_pages.is_empty():
		for layer in layers:
			layer.texture = null
		_surface_texture = null

## Spatial index visits replicated exposed cells only, once per model revision.
## Camera changes then visit occupied pages, not 2048² logical coordinates.
func _index_surfaces() -> void:
	if _surface_index_revision == _model.revision:
		return
	_surface_index_revision = _model.revision
	_surface_buckets.clear()
	var cells: Dictionary = _model.surfaces if _frame.is_empty() else _frame.samples
	for xy: Vector2i in cells:
		if not _frame.is_empty() and not cells[xy].get("known", false): continue
		var key := Vector2i(floori(xy.x / float(SURFACE_PAGE_EDGE * _stride)), floori(xy.y / float(SURFACE_PAGE_EDGE * _stride)))
		if not _surface_buckets.has(key):
			_surface_buckets[key] = []
		_surface_buckets[key].append(xy)

func _collect_pages() -> void:
	_active_pages.clear()
	var compact := maxi(_region.size.x, _region.size.y) <= SINGLE_PAGE_EDGE * _stride
	var compact_cells: Array = []
	var keys := _surface_buckets.keys()
	keys.sort_custom(func(a: Vector2i, b: Vector2i) -> bool: return a.y < b.y or (a.y == b.y and a.x < b.x))
	for key: Vector2i in keys:
		var page_rect := Rect2i(key * SURFACE_PAGE_EDGE * _stride, Vector2i.ONE * SURFACE_PAGE_EDGE * _stride).intersection(_region)
		if not page_rect.has_area():
			continue
		var cells: Array = []
		for xy: Vector2i in _surface_buckets[key]:
			if page_rect.has_point(xy): cells.append(xy)
		if cells.is_empty(): continue
		if compact:
			compact_cells.append_array(cells)
		else:
			_active_pages.append({"region": page_rect, "cells": cells})
	if not compact_cells.is_empty():
		_active_pages.append({"region": _region, "cells": compact_cells})

func _build_page(index: int, item: Dictionary) -> void:
	var count := _model.max_z - _model.min_z + 1
	var region: Rect2i = item.region
	while _terrain_pages.size() <= index:
		_terrain_pages.append({"layers": layers if _terrain_pages.is_empty() else [], "texture": null, "region": Rect2i()})
	var page := _terrain_pages[index]
	page.layers.resize(maxi(page.layers.size(), count))
	page.region = region
	page.texture = _upload(page.texture, TerrainArt.surface_data(_model, region) if _frame.is_empty() else TerrainArt.frame_data(_frame, region, _model.materials))
	if index == 0:
		_surface_texture = page.texture
	var images: Array[Image] = []
	images.resize(count)
	for xy: Vector2i in item.cells:
		var z: int = _model.surface_at(xy).z if _frame.is_empty() else int(_frame.samples[xy].surface_z)
		var depth: int = clampi(_model.cut - z, 0, count - 1)
		if images[depth] == null:
			images[depth] = Image.create(region.size.x / _stride, region.size.y / _stride, false, Image.FORMAT_RGBA8)
		images[depth].set_pixelv((xy - region.position) / _stride, Color.WHITE)
	for depth in page.layers.size():
		if depth >= count:
			if page.layers[depth] != null:
				page.layers[depth].texture = null
				page.layers[depth].visible = false
			continue
		if page.layers[depth] == null and images[depth] != null:
			page.layers[depth] = _new_layer(depth, false)
		var layer: TextureRect = page.layers[depth]
		if layer == null: continue
		layer.texture = _upload(layer.texture, images[depth])
		layer.material.set_shader_parameter("surface_data", page.texture)
		layer.material.set_shader_parameter("world_origin", Vector2(region.position))
		layer.material.set_shader_parameter("world_extent", Vector2(region.size) / _stride)
		layer.material.set_shader_parameter("sample_stride", float(_stride))
		layer.material.set_shader_parameter("empty_colour", ThemeTokens.color("map-ground-deep"))
		layer.material.set_shader_parameter("source_pixels", float(PIXELS))
		layer.material.set_shader_parameter("radius", depth * 0.65)
		layer.material.set_shader_parameter("visibility_mask", layer.texture)
		if layer.texture != null: mask_build_count += 1
		layer.visible = _visible and layer.texture != null

func terrain_layers() -> Array[TextureRect]:
	var result: Array[TextureRect] = []
	for page: Dictionary in _terrain_pages:
		for layer: TextureRect in page.layers:
			if layer != null: result.append(layer)
	return result if not _terrain_pages.is_empty() else layers

func _upload(previous: Texture2D, image: Image) -> Texture2D:
	if image == null:
		return null
	if previous is ImageTexture and previous.get_size() == Vector2(image.get_size()):
		previous.update(image)
		return previous
	return ImageTexture.create_from_image(image)

func _entity_mask(depth: int, region: Rect2i) -> Texture2D:
	if _entity_masks.has(depth) and _entity_masks[depth].region == region:
		return _entity_masks[depth].texture
	var image := Image.create(region.size.x, region.size.y, false, Image.FORMAT_RGBA8)
	var base := _model.cut - depth
	for item: Dictionary in _active_pages:
		for xy: Vector2i in item.cells:
			if not region.has_point(xy): continue
			var surface: Variant = _model.surface_at(xy)
			if surface != null and surface.z < base and _model.position_visible(Vector3(xy.x, xy.y, base)):
				image.set_pixelv(xy - region.position, Color.WHITE)
	var texture := ImageTexture.create_from_image(image)
	_entity_masks[depth] = {"region": region, "texture": texture}
	mask_build_count += 1
	return texture

func update_entities(entities: Array) -> void:
	_entities = entities
	_apply_entities()

func _apply_entities(force := false) -> void:
	if _model == null:
		return
	var groups := {}
	var regions := {}
	for entity: Dictionary in _entities:
		if is_overview(): break
		if _region.size == Vector2i.ZERO or not entity.rect.intersects(Rect2(_region)):
			continue
		var depth := _model.cut - int(entity.z)
		if depth < 0 or depth >= canvases.size():
			continue
		if not groups.has(depth):
			groups[depth] = []
			regions[depth] = entity.rect
		else:
			regions[depth] = regions[depth].merge(entity.rect)
		groups[depth].append(entity)
	var area := 0
	var pixels := PIXELS
	for depth: int in regions:
		var rect: Rect2 = regions[depth]
		var start := Vector2i((rect.position / 16.0).floor()) * 16 - Vector2i.ONE * CAMERA_PADDING
		var end := Vector2i((rect.end / 16.0).ceil()) * 16 + Vector2i.ONE * CAMERA_PADDING
		regions[depth] = Rect2i(start, end - start).intersection(_region)
		area += regions[depth].get_area()
		pixels = mini(pixels, MAX_TEXTURE_EDGE / maxi(1, maxi(regions[depth].size.x, regions[depth].size.y)))
	pixels = mini(pixels, maxi(1, floori(sqrt(MAX_PASS_PIXELS / float(maxi(1, area))))))
	for depth in canvases.size():
		var group: Array = groups.get(depth, [])
		var region: Rect2i = regions.get(depth, Rect2i())
		if not force and group == canvases[depth].entities and region == _entity_regions[depth] and pixels == int(canvases[depth].pixels):
			continue
		canvases[depth].entities = group
		canvases[depth].pixels = float(pixels)
		_entity_regions[depth] = region
		var active := groups.has(depth)
		if active:
			viewports[depth].size = region.size * pixels
			canvases[depth].origin = Vector2(region.position)
			canvases[depth].queue_redraw()
			entity_layers[depth].material.set_shader_parameter("visibility_mask", _entity_mask(depth, region))
			entity_layers[depth].material.set_shader_parameter("radius", depth * 0.65 * pixels / PIXELS)
			entity_update_count += 1
		else:
			viewports[depth].size = Vector2i(2, 2)
			entity_layers[depth].material.set_shader_parameter("visibility_mask", null)
			_entity_masks.erase(depth)
		viewports[depth].render_target_update_mode = SubViewport.UPDATE_ONCE if active and _visible else SubViewport.UPDATE_DISABLED
		entity_layers[depth].texture = viewports[depth].get_texture() if active else null
		entity_layers[depth].visible = active and _visible
	_layout_layers()

func layout(origin: Vector2, extent: Vector2) -> void:
	_origin = origin
	_extent = extent
	if _ground != null:
		_ground.position = origin
		_ground.size = extent
	_sync_region()
	_layout_layers()

func _layout_layers() -> void:
	if _model == null:
		return
	var cell := _extent / Vector2(_model.width, _model.height)
	if _ground != null:
		_ground.position = _origin + Vector2(_model.bounds().position) * cell
	for page: Dictionary in _terrain_pages:
		for layer: TextureRect in page.layers:
			if layer == null: continue
			layer.position = _origin + Vector2(page.region.position) * cell
			layer.size = Vector2(page.region.size) * cell
	for depth in layers.size():
		entity_layers[depth].position = _origin + Vector2(_entity_regions[depth].position) * cell
		entity_layers[depth].size = Vector2(_entity_regions[depth].size) * cell

func reset() -> void:
	_model = null
	_render_revision = -1
	_entities = []
	_entity_masks.clear()
	_surface_texture = null
	_frame = {}
	_frame_key = []
	_stride = 1
	pending_samples = 0
	if _ground != null: _ground.material = null
	_surface_index_revision = -1
	_surface_buckets.clear()
	_active_pages.clear()
	for page: Dictionary in _terrain_pages:
		page.texture = null
	for canvas in canvases:
		canvas.entities = []
	for depth in viewports.size():
		viewports[depth].size = Vector2i(2, 2)
		viewports[depth].render_target_update_mode = SubViewport.UPDATE_DISABLED
		_entity_regions[depth] = Rect2i()
	var surface_layers := terrain_layers()
	for layer in surface_layers + entity_layers:
		layer.texture = null
		layer.material.set_shader_parameter("visibility_mask", null)
		if layer in surface_layers: layer.material.set_shader_parameter("surface_data", null)
	set_visible(false)

func set_visible(value: bool) -> void:
	if _visible == value:
		return
	_visible = value
	if _ground != null:
		_ground.visible = value
	for layer in terrain_layers() + entity_layers:
		layer.visible = value and layer.texture != null
	for depth in viewports.size():
		viewports[depth].render_target_update_mode = SubViewport.UPDATE_ONCE if value and not canvases[depth].entities.is_empty() else SubViewport.UPDATE_DISABLED
