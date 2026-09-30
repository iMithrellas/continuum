## Masked, far-to-near depth compositor. Terrain is cached; complete entity icons
## are drawn once into feet-layer offscreen passes. Overlays stay on the parent.
class_name LayeredTerrainView
extends RefCounted

const SHADER = preload("res://shaders/terrain_depth.gdshader")
const ENTITY_CANVAS = preload("res://scripts/terrain_entity_canvas.gd")
const PIXELS := 32
const MAX_TEXTURE_EDGE := 2048
const MAX_PASS_PIXELS := 8 * 1024 * 1024
const CAMERA_PADDING := 2
var layers: Array[TextureRect] = []
var entity_layers: Array[TextureRect] = []
var viewports: Array[SubViewport] = []
var canvases: Array[Node2D] = []
var parent_control: Control
var _visible := false
var _model: LayeredTerrainModel
var _origin := Vector2.ZERO
var _extent := Vector2.ZERO
var _region := Rect2i()
var _pixels := PIXELS
var _render_revision := -1
var _entity_masks: Dictionary = {}
var _entities: Array = []
var _entity_regions: Array[Rect2i] = []
## Counters for backend-free cache regressions/profiling, not frame polling.
var terrain_build_count := 0
var mask_build_count := 0
var entity_update_count := 0

func attach(parent: Control) -> void:
	parent_control = parent

func _new_layer(depth: int, entity: bool) -> TextureRect:
	var layer := TextureRect.new()
	layer.mouse_filter = Control.MOUSE_FILTER_IGNORE
	layer.show_behind_parent = true
	layer.z_index = -depth * 2 - (1 if entity else 2)
	layer.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	layer.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR
	var effect := ShaderMaterial.new()
	effect.shader = SHADER
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
	_model = model
	var count := model.max_z - model.min_z + 1
	_ensure_bands(count)
	_sync_region()
	layout(_origin, _extent)

func _sync_region() -> void:
	if _model == null:
		return
	_ensure_bands(_model.max_z - _model.min_z + 1)
	var bounds := Rect2i(0, 0, _model.width, _model.height)
	var region := bounds
	if _extent.x > 0 and _extent.y > 0:
		var cell := _extent / Vector2(_model.width, _model.height)
		var start := -_origin / cell
		var end := (parent_control.size - _origin) / cell
		region = Rect2i(Vector2i(floori(start.x), floori(start.y)) - Vector2i.ONE * CAMERA_PADDING,
			Vector2i(ceili(end.x), ceili(end.y)) - Vector2i(floori(start.x), floori(start.y)) + Vector2i.ONE * CAMERA_PADDING * 2).intersection(bounds)
	if region == _region and _render_revision == _model.revision:
		return
	var pixels := clampi(MAX_TEXTURE_EDGE / maxi(1, maxi(region.size.x, region.size.y)), 1, PIXELS)
	var occupied_depths := {}
	for y in range(region.position.y, region.end.y):
		for x in range(region.position.x, region.end.x):
			var surface: Variant = _model.surface_at(Vector2i(x, y))
			if surface != null:
				occupied_depths[surface.z] = true
	pixels = mini(pixels, maxi(1, floori(sqrt(MAX_PASS_PIXELS / float(maxi(1, region.get_area() * occupied_depths.size()))))))
	_region = region
	_pixels = pixels
	_render_revision = _model.revision
	_entity_masks.clear()
	_build_terrain()
	_apply_entities(true)

func _build_terrain() -> void:
	terrain_build_count += 1
	var count := _model.max_z - _model.min_z + 1
	var images: Array[Image] = []
	images.resize(count)
	var masks: Array[Image] = []
	masks.resize(count)
	for y in range(_region.position.y, _region.end.y):
		for x in range(_region.position.x, _region.end.x):
			var xy := Vector2i(x, y)
			var surface: Variant = _model.surface_at(xy)
			if surface == null:
				continue
			var depth: int = _model.cut - surface.z
			if images[depth] == null:
				images[depth] = _image()
				masks[depth] = Image.create(_region.size.x, _region.size.y, false, Image.FORMAT_RGBA8)
			var at := xy - _region.position
			var colour := Color("887047") if _model.material_at(surface) == 1 else Color("737d8b")
			images[depth].fill_rect(Rect2i(at * _pixels, Vector2i.ONE * _pixels), colour)
			images[depth].fill_rect(Rect2i(at * _pixels, Vector2i(_pixels, maxi(1, roundi(2.0 * _pixels / PIXELS)))), colour.lightened(0.18))
			images[depth].fill_rect(Rect2i(at * _pixels + Vector2i(12, 16) * _pixels / PIXELS, Vector2i.ONE * maxi(1, _pixels / 8)), colour.darkened(0.25))
			masks[depth].set_pixelv(at, Color.WHITE)
	for depth in count:
		layers[depth].texture = _upload(layers[depth].texture, images[depth])
		if masks[depth] != null:
			layers[depth].material.set_shader_parameter("visibility_mask", _upload(layers[depth].material.get_shader_parameter("visibility_mask"), masks[depth]))
			mask_build_count += 1
		for layer in [layers[depth], entity_layers[depth]]:
			layer.material.set_shader_parameter("radius", depth * 0.65 * _pixels / PIXELS)
			layer.visible = _visible and layer.texture != null
	for depth in range(count, layers.size()):
		layers[depth].texture = null
		entity_layers[depth].texture = null

func _image() -> Image:
	return Image.create(_region.size.x * _pixels, _region.size.y * _pixels, false, Image.FORMAT_RGBA8)

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
	for y in range(region.position.y, region.end.y):
		for x in range(region.position.x, region.end.x):
			var xy := Vector2i(x, y)
			var surface: Variant = _model.surface_at(xy)
			if surface != null and surface.z < base and _model.position_visible(Vector3(x, y, base)):
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
		viewports[depth].render_target_update_mode = SubViewport.UPDATE_ONCE if active and _visible else SubViewport.UPDATE_DISABLED
		entity_layers[depth].texture = viewports[depth].get_texture() if active else null
		entity_layers[depth].visible = active and _visible
	_layout_layers()

func layout(origin: Vector2, extent: Vector2) -> void:
	_origin = origin
	_extent = extent
	_sync_region()
	_layout_layers()

func _layout_layers() -> void:
	if _model == null:
		return
	var cell := _extent / Vector2(_model.width, _model.height)
	for depth in layers.size():
		layers[depth].position = _origin + Vector2(_region.position) * cell
		layers[depth].size = Vector2(_region.size) * cell
		entity_layers[depth].position = _origin + Vector2(_entity_regions[depth].position) * cell
		entity_layers[depth].size = Vector2(_entity_regions[depth].size) * cell

func reset() -> void:
	_model = null
	_render_revision = -1
	_entities = []
	_entity_masks.clear()
	for canvas in canvases:
		canvas.entities = []
	for depth in viewports.size():
		viewports[depth].size = Vector2i(2, 2)
		viewports[depth].render_target_update_mode = SubViewport.UPDATE_DISABLED
		_entity_regions[depth] = Rect2i()
	for layer in layers + entity_layers:
		layer.texture = null
	set_visible(false)

func set_visible(value: bool) -> void:
	if _visible == value:
		return
	_visible = value
	for layer in layers + entity_layers:
		layer.visible = value and layer.texture != null
	for depth in viewports.size():
		viewports[depth].render_target_update_mode = SubViewport.UPDATE_ONCE if value and not canvases[depth].entities.is_empty() else SubViewport.UPDATE_DISABLED
