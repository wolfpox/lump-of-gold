class_name LumpBaker
extends RefCounted
## Samples an analytic LumpNugget at texel centres and packs it into a LumpTextureSet.
## Decisions are made on quantized values (what the texel can actually store), so that
## incremental channel edits by LumpCarver give byte-identical results to a full re-bake.

## span_only: never use SLAB mode.  Columns with two pockets then keep only the strongest,
## which shows what the per-texel mode bit buys.
static func bake(shape: LumpNugget, span_only: bool = false) -> LumpTextureSet:
	var T := shape.size
	var tex := LumpTextureSet.new(T)
	for view in 3:
		for iv in T:
			for iu in T:
				var u := (iu + 0.5) / T
				var v := (iv + 0.5) / T
				tex.set_texel(view, iu, iv, encode_texel(shape, view, u, v, span_only))
	return tex


static func encode_texel(shape: LumpNugget, view: int, u: float, v: float, span_only: bool) -> PackedInt32Array:
	var d := shape.describe(view, u, v)
	var frame: int = d.frame
	var hsq: int = shape.hsq[view]
	var R := LumpEnc.q_unorm16(d.m)
	var G := LumpEnc.q_snorm16(LumpEnc.encode_h(d.h, hsq))
	var B := LumpEnc.pack_b_span(0.5, -1.0 if frame == LumpEnc.FRAME_REL else -LumpEnc.ABS_TH_RANGE, frame)
	var op := LumpEnc.CARVE_NONE
	var mode := LumpEnc.MODE_SPAN
	var mat: int = d.mat

	var ramp := -1.0
	if d.through_sd < INF:
		ramp = clampf(-d.through_sd / (LumpEnc.THROUGH_TEXELS * shape.texel), -1.0, 1.0)
	if LumpEnc.q_snorm8(ramp) > 1:
		op = LumpEnc.CARVE_THROUGH
		B = LumpEnc.pack_b_through(ramp)
		if d.through_sd < 0.0:
			mat = d.through_mat
	else:
		var active: Array[Dictionary] = []
		var best: Dictionary = {}
		var best_code := 1
		for p in d.pockets:
			var code := LumpEnc.pocket_code(p.th_eff, frame)
			if code > 128:
				active.append(p)
			if code > best_code:
				best_code = code
				best = p
		if active.size() >= 2 and not span_only:
			# Oldest pocket owns op and material in slab mode (history-independent rule).
			mode = LumpEnc.MODE_SLAB
			var mask := 0
			for p in active:
				var q := LumpEnc.quant_pocket(p.tc, p.th_eff, frame)
				mask |= LumpEnc.rasterize_slabs(q.x, q.y)
			B = mask
			op = active[0].op
			mat = active[0].mat
		elif not best.is_empty():
			B = LumpEnc.pack_b_span(best.tc, best.th_eff, frame)
			op = best.op
			if best_code > 128:
				mat = best.mat
	var A := LumpEnc.pack_a(op, d.comb, mode, frame, d.blend, d.sharp, mat, hsq)
	return PackedInt32Array([R, G, B, A])
