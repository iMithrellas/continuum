## Material appearance resolves by replicated material name, never by guessed ID.
## Geometry, exposure, fertility and production remain authoritative model data.
class_name TerrainArt
extends RefCounted

const ATLAS = preload("res://assets/world/materials.png")
static var _texture: ImageTexture

static func material_texture() -> ImageTexture:
	if _texture == null:
		var image := ATLAS.get_image()
		image.generate_mipmaps()
		_texture = ImageTexture.create_from_image(image)
	return _texture

static func style_index(material: Variant) -> int:
	var name := str(LayeredTerrainModel.field(material, "name", "")).to_lower()
	match name:
		"soil", "loam", "dirt", "earth": return 0
		"stone", "rock", "granite", "bedrock": return 1
		"sand", "sandstone": return 2
		"clay", "claystone": return 3
		"grass", "turf": return 5
	return 4

## A one-cell halo reads the MODEL beyond a camera crop. Alpha-zero is unresolved;
## it must not turn into a floor, cliff, blended material or interaction target.
static func surface_data(model: LayeredTerrainModel, region: Rect2i) -> Image:
	var image := Image.create(region.size.x + 2, region.size.y + 2, false, Image.FORMAT_RGBAF)
	var styles := {}
	for id: int in model.materials:
		styles[id] = style_index(model.materials[id])
	for y in range(-1, region.size.y + 1):
		for x in range(-1, region.size.x + 1):
			var surface: Variant = model.surface_at(region.position + Vector2i(x, y))
			if surface != null:
				image.set_pixel(x + 1, y + 1, Color(styles.get(model.material_at(surface), 4), surface.z, 0, 1))
	return image

static func blend_compatible(a: Color, b: Color) -> bool:
	return a.a > 0.0 and b.a > 0.0 and a.g == b.g

## Bounded detail/overview frame. Sample keys are logical footprint origins,
## NOT representative source points. Missing/known=false means pending. Known
## material=0 means a resolved empty ray and remains distinct from pending.
static func frame_data(frame: Dictionary, region: Rect2i, materials: Dictionary) -> Image:
	var stride := int(frame.stride)
	var extent := region.size / stride
	var image := Image.create(extent.x + 2, extent.y + 2, false, Image.FORMAT_RGBAF)
	var styles := {}
	for id: int in materials: styles[id] = style_index(materials[id])
	for y in range(-1, extent.y + 1):
		for x in range(-1, extent.x + 1):
			var sample: Dictionary = frame.samples.get(region.position + Vector2i(x, y) * stride, {})
			if not sample.get("known", false): continue
			var material := int(sample.get("material", 0))
			image.set_pixel(x + 1, y + 1, Color(styles.get(material, 4) if material != 0 else -1,
				int(sample.surface_z), 0, 1))
	return image
