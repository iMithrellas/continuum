shader_type canvas_item;
render_mode unshaded;

void fragment() {
	float hatch = 1.0 - smoothstep(0.0, 1.4, mod(FRAGCOORD.x + FRAGCOORD.y, 18.0));
	COLOR = vec4(mix(vec3(0.075, 0.115, 0.12), vec3(0.16, 0.22, 0.22), hatch * 0.5), 1.0);
}
