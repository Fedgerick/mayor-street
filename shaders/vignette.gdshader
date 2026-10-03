// Darkens the screen corners a little, drawn over the 3D view and under the HUD.
shader_type canvas_item;
render_mode unshaded;

uniform float strength = 0.28;

void fragment() {
	float r = length(UV - 0.5) * 1.414;
	COLOR = vec4(0.0, 0.0, 0.0, smoothstep(0.42, 1.05, r) * strength);
}
