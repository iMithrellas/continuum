shader_type canvas_item;
render_mode unshaded;
uniform float radius = 0.0;
uniform float darkness = 1.0;
uniform bool mask_enabled = false;
uniform bool opaque_coverage = false;
uniform sampler2D visibility_mask : filter_nearest, repeat_disable;
void fragment() {
	vec4 blurred = vec4(0.0);
	float total = 0.0;
	for (int y = -2; y <= 2; y++) {
		for (int x = -2; x <= 2; x++) {
			float weight = exp(-float(x*x + y*y) / 2.0);
			vec2 sample_uv = UV + vec2(float(x), float(y)) * TEXTURE_PIXEL_SIZE * radius;
			vec4 sample_colour = texture(TEXTURE, sample_uv);
			if (mask_enabled) { sample_colour.a *= texture(visibility_mask, sample_uv).a; }
			blurred += vec4(sample_colour.rgb * sample_colour.a, sample_colour.a) * weight;
			total += weight;
		}
	}
	COLOR = vec4(blurred.rgb / max(blurred.a, 0.0001) * darkness, blurred.a / total);
	if (mask_enabled) {
		float coverage = texture(visibility_mask, UV).a;
		COLOR.a = opaque_coverage ? coverage : COLOR.a * coverage;
	}
}
