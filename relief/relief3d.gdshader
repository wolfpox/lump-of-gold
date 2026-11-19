shader_type spatial;
// One side of the relief: a 512x512 grid plane displaced along its local +Z.
// The back side uses the same shader on a mesh rotated 180 degrees about Y.
#include "res://relief/relief_common.gdshaderinc"

uniform bool is_back = false;
uniform vec3 albedo_col : source_color = vec3(0.80, 0.76, 0.70);
uniform float metal = 0.0;
uniform float rough = 0.62;
uniform float guide_amount = 0.0;
uniform float contour_step = 0.0;

varying vec2 cuv;

void vertex() {
	cuv = vec2(is_back ? 0.5 - VERTEX.x : VERTEX.x + 0.5, 0.5 - VERTEX.y);
	// Grid vertices just outside the silhouette are slid onto the zero contour of the signed
	// distance, so the outline is a smooth curve instead of following the texel grid.
	float sdv = textureLod(sd_tex, cuv, 0.0).r;
	if (sdv < 0.0 && sdv > -2.5) {
		float e = 1.0 / TEX_N;
		vec2 g = vec2(textureLod(sd_tex, cuv + vec2(e, 0.0), 0.0).r - textureLod(sd_tex, cuv - vec2(e, 0.0), 0.0).r,
				textureLod(sd_tex, cuv + vec2(0.0, e), 0.0).r - textureLod(sd_tex, cuv - vec2(0.0, e), 0.0).r);
		if (dot(g, g) > 1e-6) {
			cuv += normalize(g) * (-sdv) * e;
			VERTEX.x = is_back ? 0.5 - cuv.x : cuv.x - 0.5;
			VERTEX.y = 0.5 - cuv.y;
		}
	}
	VERTEX.z = surf(cuv);
}

void fragment() {
	if (textureLod(sd_tex, cuv, 0.0).r < -0.6) {
		discard;
	}
	vec2 g = surf_grad(cuv);
	vec3 n = normalize(vec3(is_back ? g.x : -g.x, g.y, 1.0));
	NORMAL = normalize((VIEW_MATRIX * (MODEL_MATRIX * vec4(n, 0.0))).xyz);
	vec3 col = albedo_col;
	if (contour_step > 0.0) {
		float c = surf(cuv) / contour_step;
		float w = fwidth(c);
		float l = 1.0 - smoothstep(0.0, w * 1.5, abs(fract(c - 0.5) - 0.5));
		col = mix(col, vec3(0.55, 0.22, 0.12), l * 0.7);
	}
	float ink = texture(guide_tex, cuv).r * guide_amount;
	col = mix(col, vec3(0.04, 0.04, 0.06), ink);
	ALBEDO = col * ao_at(cuv);
	METALLIC = metal;
	ROUGHNESS = rough;
}
