class_name LumpCarver
extends RefCounted
## Carves by editing texture channels only.  No mesh or volume is touched: the next
## rebuild picks the change up.  A brush writes a pocket into B and A of every texel under
## its footprint (plus the ramp just outside, which keeps the edge sub-texel).
##   - Empty or weaker SPAN texel  -> overwritten with the new pocket.
##   - SPAN texel that already has a different active pocket -> promoted to SLAB mode: both
##     pockets are rasterized to slab bits and OR-ed together.
##   - SLAB texel -> new pocket OR-ed into its bits.
## Uses the same quantized rules as LumpBaker, so carving == re-baking with the pocket added.

## tc / th are in the frame of the view's texels (RELATIVE fraction or ABSOLUTE units).
static func carve_pocket(tex: LumpTextureSet, view: int, cu: float, cv: float, radius: float,
		tc: float, th: float, op: int, mat: int) -> Dictionary:
	var T := tex.size
	var texel := tex.texel
	var stats := {changed = 0, promoted = 0, slab_added = 0}
	if th <= 0.0:
		return stats
	var reach := radius + LumpEnc.RAMP_TEXELS * texel / th + 2.0 * texel
	var iu0 := clampi(floori((cu - reach) * T), 0, T - 1)
	var iu1 := clampi(ceili((cu + reach) * T), 0, T - 1)
	var iv0 := clampi(floori((cv - reach) * T), 0, T - 1)
	var iv1 := clampi(ceili((cv + reach) * T), 0, T - 1)
	for iv in range(iv0, iv1 + 1):
		for iu in range(iu0, iu1 + 1):
			var u := (iu + 0.5) / T
			var v := (iv + 0.5) / T
			var sd := Vector2(u - cu, v - cv).length() - radius
			var px := tex.get_texel(view, iu, iv)
			var a := px[3]
			var b := px[2]
			var frame := LumpEnc.a_frame(a)
			var th_eff := LumpEnc.ramp_th(th, sd, texel)
			var code := LumpEnc.pocket_code(th_eff, frame)
			if code <= 1:
				continue
			var cop := LumpEnc.a_carve_op(a)
			if cop == LumpEnc.CARVE_THROUGH:
				continue
			var mode := LumpEnc.a_mode(a)
			var new_a := a
			var new_b := b
			if mode == LumpEnc.MODE_SLAB:
				if code > 128:
					var q := LumpEnc.quant_pocket(tc, th_eff, frame)
					new_b = b | LumpEnc.rasterize_slabs(q.x, q.y)
					stats.slab_added += 1
			else:
				var cur_code := 1 if cop == LumpEnc.CARVE_NONE else (b & 255)
				if code > 128 and cur_code > 128:
					# Two pockets in one column: switch this texel to slab bits (oldest keeps op/mat).
					var qa := LumpEnc.quant_pocket(LumpEnc.b_span_tc(b), LumpEnc.b_span_th(b, frame), frame)
					var qb := LumpEnc.quant_pocket(tc, th_eff, frame)
					new_b = LumpEnc.rasterize_slabs(qa.x, qa.y) | LumpEnc.rasterize_slabs(qb.x, qb.y)
					new_a = _with(a, cop, LumpEnc.MODE_SLAB, LumpEnc.a_mat(a))
					stats.promoted += 1
				elif code > cur_code:
					new_b = LumpEnc.pack_b_span(tc, th_eff, frame)
					new_a = _with(a, op, LumpEnc.MODE_SPAN, mat if code > 128 else LumpEnc.a_mat(a))
			if new_a != a or new_b != b:
				px[2] = new_b
				px[3] = new_a
				tex.set_texel(view, iu, iv, px)
				stats.changed += 1
	return stats


static func _with(a: int, carve_op: int, mode: int, mat: int) -> int:
	return LumpEnc.pack_a(carve_op, LumpEnc.a_comb_op(a), mode, LumpEnc.a_frame(a),
		LumpEnc.a_blend(a), LumpEnc.a_sharp(a), mat, LumpEnc.a_hsq(a))
