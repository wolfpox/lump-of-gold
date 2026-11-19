shader_type canvas_item;
// Bakes ambient occlusion for one side into a 512x512 texture (rendered in a SubViewport).
// Horizon-based: for each of 8 directions, march outward and find the steepest rise of the
// heightfield; a high horizon means less sky is visible from this texel.
#include "res://relief/relief_common.gdshaderinc"

uniform float radius_texels = 40.0;

float hash(vec2 p) {
	return fract(sin(dot(p, vec2(12.9898, 78.233))) * 43758.5453);
}

void fragment() {
	vec2 uv = UV;
	float h0 = surf_lin(uv);
	float occ = 0.0;
	const int DIRS = 8;
	const int STEPS = 12;
	float jitter = hash(uv * 512.0);
	for (int d = 0; d < DIRS; d++) {
		float a = (float(d) + jitter * 0.5) * 6.2831853 / float(DIRS);
		vec2 dir = vec2(cos(a), sin(a));
		// Elevation of the surface itself in this direction (its tangent). Measuring the
		// horizon above the tangent, not above flat, keeps steep walls from reading as
		// deeply occluded (the HBAO formulation).
		float e = 1.5 / TEX_N;
		float tan_t = (surf_lin(uv + dir * e) - surf_lin(uv - dir * e)) / (2.0 * e);
		float sin_t = tan_t / sqrt(1.0 + tan_t * tan_t);
		float horizon = sin_t;
		for (int k = 1; k <= STEPS; k++) {
			float t = (float(k) - 0.5 + jitter * 0.5) / float(STEPS);
			float r = max(1.5, radius_texels * t * t);
			vec2 p = uv + dir * r / TEX_N;
			if (p.x < 0.0 || p.y < 0.0 || p.x > 1.0 || p.y > 1.0) {
				break;
			}
			float dh = surf_lin(p) - h0;
			float dist = r / TEX_N;
			float s = dh / sqrt(dh * dh + dist * dist);   // sine of the elevation angle
			// far rises count for less
			horizon = max(horizon, mix(sin_t, s, 1.0 - t * t));
		}
		occ += max(horizon - sin_t, 0.0);
	}
	float ao = clamp(1.0 - occ / float(DIRS) * 1.4, 0.0, 1.0);
	COLOR = vec4(ao, ao, ao, 1.0);
}
