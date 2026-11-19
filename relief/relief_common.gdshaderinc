// Shared by the 3D and 2D relief shaders. Computes one side's surface height from the
// layers, so every shape-modifier uniform is live and non-destructive.
uniform sampler2D sd_tex : filter_linear, repeat_disable;
uniform sampler2D phi_tex : filter_linear, repeat_disable;
uniform sampler2D sculpt_tex : filter_linear, repeat_disable;
uniform sampler2D guide_tex : filter_linear, repeat_disable;
uniform float core = 0.02;
uniform float plate = 0.0;
uniform float inflate = 0.12;
uniform float roundness = 0.5;
uniform float edge_r = 5.0;
uniform int edge_shape = 0;
uniform sampler2D ao_tex : filter_linear, repeat_disable;
uniform float ao_strength = 0.0;

const float TEX_N = 512.0;

// 0..1 multiplier that brings the surface down to the silhouette.
float edge_profile(float sd) {
	if (edge_r < 0.75) {
		return clamp(sd + 0.5, 0.0, 1.0);
	}
	float x = clamp(sd / edge_r, 0.0, 1.0);
	if (edge_shape == 0) {          // round (quarter circle)
		float y = 1.0 - x;
		return sqrt(max(1.0 - y * y, 0.0));
	} else if (edge_shape == 1) {   // soft (S-curve)
		return x * x * (3.0 - 2.0 * x);
	} else if (edge_shape == 2) {   // chamfer
		return x;
	}
	return 1.0 - sqrt(max(1.0 - x * x, 0.0));  // cove (concave)
}

// Cubic B-spline filtering from 4 bilinear taps (Sigg & Hadwiger). Bilinear filtering makes
// the slope jump at every texel boundary, which shows up as facets in the lighting; the
// B-spline keeps slope and curvature continuous.
float tex_bspline(sampler2D t, vec2 uv) {
	vec2 n = vec2(textureSize(t, 0));
	vec2 p = uv * n - 0.5;
	vec2 f = fract(p);
	vec2 i = p - f;
	vec2 f2 = f * f;
	vec2 f3 = f2 * f;
	vec2 w0 = (1.0 - 3.0 * f + 3.0 * f2 - f3) / 6.0;
	vec2 w1 = (4.0 - 6.0 * f2 + 3.0 * f3) / 6.0;
	vec2 w2 = (1.0 + 3.0 * f + 3.0 * f2 - 3.0 * f3) / 6.0;
	vec2 w3 = f3 / 6.0;
	vec2 g0 = w0 + w1;
	vec2 g1 = w2 + w3;
	vec2 h0 = (i - 0.5 + w1 / g0) / n;   // i - 1 + w1/g0, shifted to texel centres
	vec2 h1 = (i + 1.5 + w3 / g1) / n;
	float a = textureLod(t, vec2(h0.x, h0.y), 0.0).r;
	float b = textureLod(t, vec2(h1.x, h0.y), 0.0).r;
	float c = textureLod(t, vec2(h0.x, h1.y), 0.0).r;
	float d = textureLod(t, vec2(h1.x, h1.y), 0.0).r;
	return mix(mix(a, b, g1.x), mix(c, d, g1.x), g1.y);
}

float surf(vec2 uv) {
	float sd = textureLod(sd_tex, uv, 0.0).r;
	float ph = max(tex_bspline(phi_tex, uv), 0.0);
	float s = tex_bspline(sculpt_tex, uv);
	float b = plate + inflate * pow(ph, roundness);
	return edge_profile(sd) * max(core * 0.5 + b + s, 0.0);
}

// d(height)/du, d(height)/dv in world units per uv unit (the piece is 1 unit wide).
vec2 surf_grad(vec2 uv) {
	float e = 1.0 / TEX_N;
	return vec2(surf(uv + vec2(e, 0.0)) - surf(uv - vec2(e, 0.0)),
			surf(uv + vec2(0.0, e)) - surf(uv - vec2(0.0, e))) / (2.0 * e);
}

// Cheaper bilinear version for passes that sample the surface many times (AO bake).
float surf_lin(vec2 uv) {
	float sd = textureLod(sd_tex, uv, 0.0).r;
	float ph = max(textureLod(phi_tex, uv, 0.0).r, 0.0);
	float s = textureLod(sculpt_tex, uv, 0.0).r;
	float b = plate + inflate * pow(ph, roundness);
	return edge_profile(sd) * max(core * 0.5 + b + s, 0.0);
}

float ao_at(vec2 uv) {
	return mix(1.0, texture(ao_tex, uv).r, ao_strength);
}
