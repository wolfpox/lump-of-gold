class_name LumpField
extends RefCounted
## Evaluates the sculpt as a continuous scalar field (negative inside) from column records.
## A source (LumpTextureSet, or LumpNugget for the analytic ground truth) fills one record
## per view column; the field then works purely on those records, so the texture
## reconstruction and the ground truth share every line of combine and carve logic.
##
## Column record layout (CS floats):
##   0 M          1 H          2 Mc (span carve centre, w)   3 Hc (span carve half-width, w)
##   4 ct (through footprint distance)
##   5..8   carve op weights   none, subtract, smooth subtract, through
##   9      blend radius k (volume units)
##   10..13 combine weights    intersect, smooth intersect, union, ignore
##   14     slab share of the carve
##   15..18 slab corner weights   19..22 corner frame start   23..26 corner frame length
##   27..30 corner slab masks
##   31     sharp weight       32 material id (nearest texel)
##   33     n exact intervals (analytic only)   34..41 exact carve intervals a0 b0 .. a3 b3

const CS := 42

var source: Object
var _tmp := PackedFloat32Array()


func _init(src: Object) -> void:
	source = src
	_tmp.resize(CS * 3)
	if source.has_method("decode"):
		source.decode()


func eval_point(p: Vector3) -> float:
	source.fill_column(0, p.x, p.y, _tmp, 0)
	source.fill_column(1, p.z, p.y, _tmp, CS)
	source.fill_column(2, p.x, p.z, _tmp, CS * 2)
	return eval_rec(_tmp, 0, _tmp, CS, _tmp, CS * 2, p)


## Vector2(material, sharp weight) of whichever view's term is active at p.
func info_point(p: Vector3) -> Vector2:
	source.fill_column(0, p.x, p.y, _tmp, 0)
	source.fill_column(1, p.z, p.y, _tmp, CS)
	source.fill_column(2, p.x, p.z, _tmp, CS * 2)
	return info_rec(_tmp, 0, _tmp, CS, _tmp, CS * 2, p)


## Vector4(front term, side term, top term, combined) at p.
func terms_point(p: Vector3) -> Vector4:
	source.fill_column(0, p.x, p.y, _tmp, 0)
	source.fill_column(1, p.z, p.y, _tmp, CS)
	source.fill_column(2, p.x, p.z, _tmp, CS * 2)
	var a := view_term(_tmp, 0, p.z)
	var b := view_term(_tmp, CS, p.x)
	var c := view_term(_tmp, CS * 2, p.y)
	return Vector4(a, b, c, combine(combine(a, b, _tmp, CS), c, _tmp, CS * 2))


func gradient(p: Vector3, h: float) -> Vector3:
	return Vector3(
		eval_point(p + Vector3(h, 0, 0)) - eval_point(p - Vector3(h, 0, 0)),
		eval_point(p + Vector3(0, h, 0)) - eval_point(p - Vector3(0, h, 0)),
		eval_point(p + Vector3(0, 0, h)) - eval_point(p - Vector3(0, 0, h))) / (2.0 * h)


static func smax(a: float, b: float, k: float) -> float:
	if k <= 0.0:
		return maxf(a, b)
	var hh := maxf(k - absf(a - b), 0.0) / k
	return maxf(a, b) + hh * hh * k * 0.25


static func slab_field(s0: float, ln: float, mask: int, w: float) -> float:
	if mask == 0 or ln <= 0.0:
		return 1.0
	var runs := LumpEnc.slab_runs(mask)
	var c := 1.0
	var e := 0
	while e < runs.size():
		var a := s0 + runs[e] * ln
		var b := s0 + runs[e + 1] * ln
		c = minf(c, absf(w - 0.5 * (a + b)) - 0.5 * (b - a))
		e += 2
	return c


## One view's term: its span, with its carve applied.
static func view_term(r: PackedFloat32Array, o: int, w: float) -> float:
	var base := absf(w - r[o]) - r[o + 1]
	var wn := r[o + 5]
	if wn >= 0.999999:
		return base
	var c := 1.0
	var n_exact := int(r[o + 33])
	if n_exact > 0:
		for e in n_exact:
			var a := r[o + 34 + e * 2]
			var b := r[o + 35 + e * 2]
			c = minf(c, absf(w - 0.5 * (a + b)) - 0.5 * (b - a))
	else:
		var sw := r[o + 14]
		var cs := absf(w - r[o + 2]) - r[o + 3]
		if sw > 0.0:
			var cl := 0.0
			for q in 4:
				var wq := r[o + 15 + q]
				if wq > 0.0:
					cl += wq * slab_field(r[o + 19 + q], r[o + 23 + q], int(r[o + 27 + q]), w)
			c = cl if sw >= 0.999999 else lerpf(cs, cl, sw)
		else:
			c = cs
	var res := wn * base
	var w1 := r[o + 6]
	if w1 > 0.0:
		res += w1 * maxf(base, -c)
	var w2 := r[o + 7]
	if w2 > 0.0:
		res += w2 * smax(base, -c, r[o + 9])
	var w3 := r[o + 8]
	if w3 > 0.0:
		res += w3 * maxf(base, -r[o + 4])
	return res


## Joins a view term into the running result using that view's (interpolated) combine op.
static func combine(acc: float, t: float, r: PackedFloat32Array, o: int) -> float:
	var res := 0.0
	var wi := r[o + 10]
	if wi > 0.0:
		res += wi * maxf(acc, t)
	var ws := r[o + 11]
	if ws > 0.0:
		res += ws * smax(acc, t, r[o + 9])
	var wu := r[o + 12]
	if wu > 0.0:
		res += wu * minf(acc, t)
	var wg := r[o + 13]
	if wg > 0.0:
		res += wg * acc
	return res


## Front is the base; side and top are joined onto it with their own combine ops.
static func eval_rec(rf: PackedFloat32Array, of: int, rs: PackedFloat32Array, os: int, rt: PackedFloat32Array, ot: int, p: Vector3) -> float:
	var acc := view_term(rf, of, p.z)
	acc = combine(acc, view_term(rs, os, p.x), rs, os)
	return combine(acc, view_term(rt, ot, p.y), rt, ot)


static func info_rec(rf: PackedFloat32Array, of: int, rs: PackedFloat32Array, os: int, rt: PackedFloat32Array, ot: int, p: Vector3) -> Vector2:
	var a := view_term(rf, of, p.z)
	var b := view_term(rs, os, p.x)
	var c := view_term(rt, ot, p.y)
	var acc := combine(combine(a, b, rs, os), c, rt, ot)
	var da := absf(a - acc)
	var db := absf(b - acc)
	var dc := absf(c - acc)
	if da <= db and da <= dc:
		return Vector2(rf[of + 32], rf[of + 31])
	if db <= dc:
		return Vector2(rs[os + 32], rs[os + 31])
	return Vector2(rt[ot + 32], rt[ot + 31])
