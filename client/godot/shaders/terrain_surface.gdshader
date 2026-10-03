shader_type canvas_item;
render_mode unshaded;

uniform sampler2D visibility_mask : filter_nearest, repeat_disable;
uniform sampler2D surface_data : filter_nearest, repeat_disable;
uniform sampler2D material_atlas : source_color, filter_linear_mipmap, repeat_disable;
uniform vec2 world_origin = vec2(0.0);
uniform vec2 world_extent = vec2(1.0);
uniform float sample_stride = 1.0;
uniform vec4 empty_colour : source_color = vec4(0.1, 0.12, 0.13, 1.0);
uniform float radius = 0.0;
uniform float source_pixels = 32.0;
uniform float darkness = 1.0;
uniform bool mask_enabled = true;
uniform bool opaque_coverage = true;

float hash21(vec2 p) {
	p = fract(p * vec2(0.1031, 0.1030));
	p += dot(p, p.yx + 33.33);
	return fract((p.x + p.y) * p.x);
}
float field(vec2 p) {
	vec2 i = floor(p);
	vec2 f = fract(p);
	f = f * f * (3.0 - 2.0 * f);
	return mix(mix(hash21(i), hash21(i + vec2(1, 0)), f.x),
		mix(hash21(i + vec2(0, 1)), hash21(i + vec2(1, 1)), f.x), f.y);
}
vec4 surface(vec2 cell) {
	return texture(surface_data, (cell + vec2(1.5)) / (world_extent + vec2(2.0)));
}
vec3 pigment(float style, vec2 world, float lod) {
	vec2 uv = fract(world / 8.0);
	float inset = exp2(lod) * 0.5 / 256.0;
	uv = clamp(uv, vec2(inset), vec2(1.0 - inset));
	vec3 colour = textureLod(material_atlas, vec2((style + uv.x) / 6.0, uv.y), lod).rgb;
	float mottling = field(world * 0.113) * 0.13 + field(world * 0.037 + 41.0) * 0.1 - 0.105;
	return colour * (1.0 + mottling);
}
void fragment() {
	float coverage = texture(visibility_mask, UV).a;
	if (coverage < 0.5) {
		COLOR = vec4(0.0);
	} else {
		vec2 p = UV * world_extent;
		vec2 cell = floor(p);
		vec2 world = p * sample_stride + world_origin;
		vec2 f = fract(p);
		vec4 centre = surface(cell);
		float footprint = max(length(dFdx(world)), length(dFdy(world))) * 32.0;
		float lod = clamp(log2(max(1.0, max(footprint, 1.0 + radius * 32.0 / source_pixels))), 0.0, 4.0);
		vec3 colour = pigment(centre.r, world, lod);
		vec2 direction = vec2(f.x < 0.5 ? -1.0 : 1.0, f.y < 0.5 ? -1.0 : 1.0);
		vec4 nx = surface(cell + vec2(direction.x, 0.0));
		vec4 ny = surface(cell + vec2(0.0, direction.y));
		vec2 distance_to_edge = min(f, 1.0 - f);
		float breakup = (field(world * 3.7) - 0.5) * 0.11;
		vec2 weights = (1.0 - smoothstep(vec2(0.0), vec2(0.36 + breakup), distance_to_edge)) * 0.48;
		if (nx.a > 0.5 && nx.r >= 0.0 && nx.g == centre.g && nx.r != centre.r) {
			colour = mix(colour, pigment(nx.r, world, lod), weights.x);
		}
		if (ny.a > 0.5 && ny.r >= 0.0 && ny.g == centre.g && ny.r != centre.r) {
			colour = mix(colour, pigment(ny.r, world, lod), weights.y);
		}
		float shade = 1.0;
		if (sample_stride == 1.0 && nx.a > 0.5 && nx.r >= 0.0 && nx.g != centre.g) {
			shade += (nx.g > centre.g ? -0.24 : 0.11) * (1.0 - smoothstep(0.0, 0.20, distance_to_edge.x));
		}
		if (sample_stride == 1.0 && ny.a > 0.5 && ny.r >= 0.0 && ny.g != centre.g) {
			shade += (ny.g > centre.g ? -0.29 : 0.14) * (1.0 - smoothstep(0.0, 0.23, distance_to_edge.y));
		}
		COLOR = centre.r < 0.0 ? empty_colour : vec4(colour * shade * darkness, coverage);
	}
}
