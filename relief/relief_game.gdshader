shader_type spatial;
// Game view: the low-poly mesh exactly as built, lit with full-resolution normals and AO
// from the heightfield. This is what a baked normal map + AO map will look like in Godot.
#include "res://relief/relief_common.gdshaderinc"

uniform bool is_back = false;
uniform vec3 albedo_col : source_color = vec3(0.80, 0.76, 0.70);
uniform float metal = 0.0;
uniform float rough = 0.62;
uniform float guide_amount = 0.0;
uniform float contour_step = 0.0;
uniform bool flat_normals = false;

void fragment() {
	vec2 uv = UV;
	if (!flat_normals) {
		vec2 g = surf_grad(uv);
		vec3 n = normalize(vec3(-g.x, g.y, is_back ? -1.0 : 1.0));
		NORMAL = normalize((VIEW_MATRIX * (MODEL_MATRIX * vec4(n, 0.0))).xyz);
	} else {
		NORMAL = normalize(cross(dFdy(VERTEX), dFdx(VERTEX)));
	}
	vec3 col = albedo_col;
	if (contour_step > 0.0) {
		float c = surf(uv) / contour_step;
		float w = fwidth(c);
		float l = 1.0 - smoothstep(0.0, w * 1.5, abs(fract(c - 0.5) - 0.5));
		col = mix(col, vec3(0.55, 0.22, 0.12), l * 0.7);
	}
	col = mix(col, vec3(0.04, 0.04, 0.06), texture(guide_tex, uv).r * guide_amount);
	ALBEDO = col * ao_at(uv);
	METALLIC = metal;
	ROUGHNESS = rough;
}
