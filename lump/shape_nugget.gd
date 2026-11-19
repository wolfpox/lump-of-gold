class_name LumpNugget
extends RefCounted
## Analytic ground truth for the proof of concept: a lumpy gold nugget defined directly in the
## texture domain (per-view 2D functions and carve lists), so it can be evaluated exactly.
## The baker samples it at texel centres into a LumpTextureSet. Comparing the mesh rebuilt
## from the textures with this exact version measures the encoding's error and nothing else.
##
## Features, chosen so that no heightmap along x, y or z can hold the result:
##   front  rounded "mushroom" silhouette (cap overhangs the stem), dome thickness profile,
##          an undercut pocket (opening narrower than its interior) and a double pocket
##          (one from each face at the same footprint: two carves in one column).
##   side   faceted silhouette (sharp creases) and a through tunnel.
##   top    rotated rounded-rectangle silhouette joined with a smooth intersect.

var size: int
var texel: float
## {view, cu, cv, r, tc, th, op, mat}: tc/th in the view's frame (see LumpEnc).
var pockets: Array[Dictionary] = []
## {view, cu, cv, r, mat}
var throughs: Array[Dictionary] = []
## Per-view H curve used by the baker (1 = squared).  Ground truth does not depend on it.
var hsq := PackedInt32Array([1, 0, 0])

const SIDE_POLY: Array[Vector2] = [
	Vector2(0.50, 0.84), Vector2(0.73, 0.71), Vector2(0.76, 0.45), Vector2(0.66, 0.18),
	Vector2(0.34, 0.18), Vector2(0.24, 0.45), Vector2(0.27, 0.71)]
const SIL_SLOPE := 32.0  # H ramp for the silhouette-only views (H = -sd * SIL_SLOPE)


func _init(texture_size: int = 64) -> void:
	size = texture_size
	texel = 1.0 / size
	pockets = [
		{view = LumpEnc.VIEW_FRONT, cu = 0.38, cv = 0.62, r = 0.075, tc = 0.85, th = 0.30, op = LumpEnc.CARVE_SMOOTH, mat = 2},
		{view = LumpEnc.VIEW_FRONT, cu = 0.60, cv = 0.42, r = 0.055, tc = 0.90, th = 0.28, op = LumpEnc.CARVE_SMOOTH, mat = 2},
		{view = LumpEnc.VIEW_FRONT, cu = 0.60, cv = 0.42, r = 0.055, tc = 0.10, th = 0.28, op = LumpEnc.CARVE_SMOOTH, mat = 2},
	]
	throughs = [
		{view = LumpEnc.VIEW_SIDE, cu = 0.50, cv = 0.26, r = 0.04, mat = 3},
	]


func duplicate_shape() -> LumpNugget:
	var s := LumpNugget.new(size)
	s.pockets = pockets.duplicate(true)
	s.throughs = throughs.duplicate(true)
	s.hsq = hsq.duplicate()
	return s


# ------------------------------------------------------------------------------ 2D helpers

static func sd_ellipse(p: Vector2, r: Vector2) -> float:
	var k := Vector2(p.x / r.x, p.y / r.y).length()
	return (k - 1.0) * minf(r.x, r.y)

static func smin(a: float, b: float, k: float) -> float:
	var h := maxf(k - absf(a - b), 0.0) / k
	return minf(a, b) - h * h * k * 0.25

static func sd_polygon(p: Vector2, pts: Array[Vector2]) -> float:
	var d := (p - pts[0]).length_squared()
	var s := 1.0
	var n := pts.size()
	var j := n - 1
	for i in n:
		var e := pts[j] - pts[i]
		var w := p - pts[i]
		var b := w - e * clampf(w.dot(e) / e.dot(e), 0.0, 1.0)
		d = minf(d, b.length_squared())
		var c1 := p.y >= pts[i].y
		var c2 := p.y < pts[j].y
		var c3 := e.x * w.y > e.y * w.x
		if (c1 and c2 and c3) or (not c1 and not c2 and not c3):
			s = -s
		j = i
	return s * sqrt(d)

static func sd_superellipse(p: Vector2, r: Vector2, n: float) -> float:
	var q := Vector2(absf(p.x) / r.x, absf(p.y) / r.y)
	var k := pow(pow(q.x, n) + pow(q.y, n), 1.0 / n)
	return (k - 1.0) * minf(r.x, r.y)

static func dome(sd: float, depth: float) -> float:
	if sd >= 0.0:
		return -sd
	if sd > -depth:
		return sqrt(-sd * (2.0 * depth + sd))
	return depth


# ---------------------------------------------------------------------------- view bases

func base_mh(view: int, u: float, v: float) -> Vector2:
	match view:
		LumpEnc.VIEW_FRONT:
			var cap := sd_ellipse(Vector2(u - 0.5, v - 0.60), Vector2(0.34, 0.17))
			var stem := sd_ellipse(Vector2(u - 0.5, v - 0.36), Vector2(0.17, 0.20))
			var sd := smin(cap, stem, 0.05)
			sd += 0.010 * sin(31.0 * u + 1.3) * sin(27.0 * v + 0.4) + 0.006 * sin(53.0 * u + 2.1) * cos(47.0 * v + 0.7)
			var m := 0.5 + 0.02 * sin(9.0 * u + 1.0) * cos(7.0 * v)
			return Vector2(m, dome(sd, 0.20))
		LumpEnc.VIEW_SIDE:
			var sd := sd_polygon(Vector2(u, v), SIDE_POLY)
			return Vector2(0.5, clampf(-sd * SIL_SLOPE, -1.0, 1.0))
		_:
			var a := deg_to_rad(25.0)
			var p := Vector2(u - 0.5, v - 0.5).rotated(-a)
			var sd := sd_superellipse(p, Vector2(0.36, 0.23), 4.0)
			return Vector2(0.5, clampf(-sd * SIL_SLOPE, -1.0, 1.0))


## Per-view constants: combine op, blend class, sharp flag, base material, carve frame.
static func view_props(view: int) -> Dictionary:
	match view:
		LumpEnc.VIEW_FRONT:
			return {comb = LumpEnc.COMB_ISECT, blend = 1, sharp = 0, mat = 0, frame = LumpEnc.FRAME_REL}
		LumpEnc.VIEW_SIDE:
			return {comb = LumpEnc.COMB_ISECT, blend = 0, sharp = 1, mat = 1, frame = LumpEnc.FRAME_ABS}
		_:
			return {comb = LumpEnc.COMB_SMOOTH_ISECT, blend = 2, sharp = 0, mat = 0, frame = LumpEnc.FRAME_ABS}


## Everything the encoding needs to know about one view column at (u, v), exactly.
## pockets: [{tc, th_eff, op, mat}] in list order, th_eff from the shared footprint ramp.
func describe(view: int, u: float, v: float) -> Dictionary:
	var mh := base_mh(view, u, v)
	var props := view_props(view)
	var ps: Array[Dictionary] = []
	for p in pockets:
		if p.view != view:
			continue
		var sd: float = Vector2(u - p.cu, v - p.cv).length() - p.r
		ps.append({tc = p.tc, th_eff = LumpEnc.ramp_th(p.th, sd, texel), op = p.op, mat = p.mat})
	var tsd := INF
	var tmat := 0
	for t in throughs:
		if t.view != view:
			continue
		var sd: float = Vector2(u - t.cu, v - t.cv).length() - t.r
		if sd < tsd:
			tsd = sd
			tmat = t.mat
	return {m = mh.x, h = mh.y, pockets = ps, through_sd = tsd, through_mat = tmat,
		comb = props.comb, blend = props.blend, sharp = props.sharp, mat = props.mat, frame = props.frame}


## Exact column record (same layout as LumpTextureSet.fill_column, see LumpField).
func fill_column(view: int, u: float, v: float, r: PackedFloat32Array, o: int) -> void:
	var d := describe(view, u, v)
	var m: float = d.m
	var h: float = d.h
	r[o] = m
	r[o + 1] = h
	r[o + 2] = 0.5
	r[o + 3] = -1.0
	r[o + 4] = d.through_sd if d.through_sd < INF else 1.0
	for q in 9:
		r[o + 5 + q] = 0.0
	r[o + 9] = LumpEnc.BLEND_TEXELS[d.blend] * texel
	r[o + 10 + int(d.comb)] = 1.0
	r[o + 14] = 0.0
	for q in 16:
		r[o + 15 + q] = 0.0
	r[o + 31] = d.sharp
	r[o + 32] = d.mat
	var fl := LumpEnc.frame_s0_len(d.frame, m, h, texel)
	var n := 0
	var op := LumpEnc.CARVE_NONE
	var best := -INF
	for p in d.pockets:
		if p.th_eff > 0.0 and n < 4:
			r[o + 34 + n * 2] = fl.x + (p.tc - p.th_eff) * fl.y
			r[o + 35 + n * 2] = fl.x + (p.tc + p.th_eff) * fl.y
			n += 1
			if p.th_eff > best:
				best = p.th_eff
				op = p.op
				r[o + 32] = p.mat
	r[o + 33] = n
	if d.through_sd < LumpEnc.THROUGH_TEXELS * texel:
		op = LumpEnc.CARVE_THROUGH
		if d.through_sd < 0.0:
			r[o + 32] = d.through_mat
	r[o + 5 + op] = 1.0
