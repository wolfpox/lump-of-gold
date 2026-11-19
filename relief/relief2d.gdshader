shader_type canvas_item;
// The flat canvas: the current side seen straight on, hill-shaded, with line art on top.
#include "res://relief/relief_common.gdshaderinc"

uniform sampler2D mask_tex : filter_linear, repeat_disable;
uniform bool mirror = false;
uniform float guide_opacity = 0.85;
uniform float contour_step = 0.0;
uniform float shade_gain = 1.0;

void fragment() {
	vec2 uv = mirror ? vec2(1.0 - UV.x, UV.y) : UV;
	float m = texture(mask_tex, uv).r;
	float h = surf(uv);
	vec2 g = surf_grad(uv) * shade_gain;
	if (mirror) {
		g.x = -g.x;
	}
	vec3 n = normalize(vec3(-g.x, -g.y, 1.0));      // x right, y down, z toward viewer
	vec3 L = normalize(vec3(-0.55, -0.7, 0.75));    // light from the upper left
	float lit = clamp(dot(n, L), 0.0, 1.0);
	vec3 surf_col = vec3(0.88, 0.85, 0.80) * (0.22 + 0.85 * lit) * ao_at(uv);

	vec2 cell = floor(UV * 32.0);
	float chk = mod(cell.x + cell.y, 2.0);
	vec3 bg = mix(vec3(0.14, 0.145, 0.16), vec3(0.17, 0.175, 0.19), chk);
	float inside = smoothstep(0.4, 0.6, m);
	vec3 col = mix(bg, surf_col, inside);

	// thin outline on the silhouette edge
	float fw = fwidth(m);
	float edge = 1.0 - smoothstep(0.0, fw * 1.5, abs(m - 0.5));
	col = mix(col, vec3(0.95, 0.75, 0.3), edge * 0.8);

	if (contour_step > 0.0) {
		float c = h / contour_step;
		float w = fwidth(c);
		float l = 1.0 - smoothstep(0.0, w * 1.5, abs(fract(c - 0.5) - 0.5));
		col = mix(col, vec3(0.75, 0.3, 0.15), l * 0.6 * inside);
	}
	float ink = texture(guide_tex, uv).r * guide_opacity;
	col = mix(col, vec3(0.03, 0.03, 0.05), ink);
	COLOR = vec4(col, 1.0);
}
