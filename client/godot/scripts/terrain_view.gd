## Masked, far-to-near depth compositor. Terrain is cached; complete entity icons
## are drawn once into feet-layer offscreen passes. Overlays stay on the parent.
class_name LayeredTerrainView
extends RefCounted

const SHADER = preload("res://shaders/terrain_depth.gdshader")
const ENTITY_CANVAS = preload("res://scripts/terrain_entity_canvas.gd")
const PIXELS := 32
var layers: Array[TextureRect] = []
var entity_layers: Array[TextureRect] = []
var viewports: Array[SubViewport] = []
var canvases: Array[Node2D] = []
var parent_control: Control
var _visible := false
var _model: LayeredTerrainModel
var _origin := Vector2.ZERO
var _extent := Vector2.ZERO

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

func rebuild(model: LayeredTerrainModel) -> void:
	_model = model
	var count := model.max_z - model.min_z + 1
	_ensure_bands(count)
	var images: Array[Image] = []
	images.resize(count)
	for xy: Vector2i in model.surfaces:
		var surface: Vector3i = model.surfaces[xy]
		var depth := model.cut - surface.z
		if images[depth] == null:
			images[depth] = _image()
		var colour := Color("887047") if model.material_at(surface) == 1 else Color("737d8b")
		images[depth].fill_rect(Rect2i(xy * PIXELS, Vector2i.ONE * PIXELS), colour)
		images[depth].fill_rect(Rect2i(xy * PIXELS, Vector2i(PIXELS, 2)), colour.lightened(0.18))
		images[depth].fill_rect(Rect2i(xy * PIXELS + Vector2i(12, 16), Vector2i(4, 4)), colour.darkened(0.25))
	for depth in count:
		layers[depth].texture = ImageTexture.create_from_image(images[depth]) if images[depth] != null else null
		layers[depth].material.set_shader_parameter("visibility_mask", _mask(depth, false))
		entity_layers[depth].material.set_shader_parameter("visibility_mask", _mask(depth, true))
	for depth in range(count, layers.size()):
		layers[depth].texture = null
		entity_layers[depth].texture = null
	layout(_origin, _extent)
	set_visible(_visible)

func _image() -> Image:
	return Image.create(_model.width * PIXELS, _model.height * PIXELS, false, Image.FORMAT_RGBA8)

func _mask(depth: int, entity: bool) -> Texture2D:
	var image := Image.create(_model.width, _model.height, false, Image.FORMAT_RGBA8)
	var base := _model.cut - depth
	for xy: Vector2i in _model.surfaces:
		var surface: Vector3i = _model.surfaces[xy]
		var allowed := _model.depth_at(xy) == depth
		if entity:
			allowed = surface.z < base and _model.entity_visible({"x": xy.x, "y": xy.y, "z": base})
		if allowed:
			image.set_pixelv(xy, Color.WHITE)
	return ImageTexture.create_from_image(image)

func update_entities(entities: Array) -> void:
	if _model == null:
		return
	var groups := {}
	for entity: Dictionary in entities:
		var depth := _model.cut - int(entity.z)
		if depth < 0 or depth >= canvases.size():
			continue
		if not groups.has(depth):
			groups[depth] = []
		groups[depth].append(entity)
	for depth in canvases.size():
		canvases[depth].entities = groups.get(depth, [])
		canvases[depth].queue_redraw()
		var active := groups.has(depth)
		if active:
			viewports[depth].size = Vector2i(_model.width, _model.height) * PIXELS
		viewports[depth].render_target_update_mode = SubViewport.UPDATE_ALWAYS if active and _visible else SubViewport.UPDATE_DISABLED
		entity_layers[depth].texture = viewports[depth].get_texture() if active else null
		entity_layers[depth].visible = active and _visible

func layout(origin: Vector2, extent: Vector2) -> void:
	_origin = origin
	_extent = extent
	for layer in layers + entity_layers:
		layer.position = origin
		layer.size = extent

func reset() -> void:
	_model = null
	for canvas in canvases:
		canvas.entities = []
	for layer in layers + entity_layers:
		layer.texture = null
	set_visible(false)

func set_visible(value: bool) -> void:
	_visible = value
	for layer in layers + entity_layers:
		layer.visible = value and layer.texture != null
	for depth in viewports.size():
		viewports[depth].render_target_update_mode = SubViewport.UPDATE_ALWAYS if value and not canvases[depth].entities.is_empty() else SubViewport.UPDATE_DISABLED
