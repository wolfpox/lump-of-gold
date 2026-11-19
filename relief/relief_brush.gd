class_name ReliefBrush
extends RefCounted
## Painting-program style brush working on one float layer.
##
## Flow vs opacity (same idea as Photoshop/Krita):
##   - Every dab adds `flow * falloff` of coverage to a per-stroke coverage buffer
##     (cov += a * (1 - cov)), so overlapping dabs build up gradually.
##   - The stroke's effect is `opacity * cov` applied to the layer as it was when the stroke
##     began. One stroke can never go past `opacity` (times depth), however much you scrub;
##     lift the pen and stroke again to build further.
## Smooth works in place instead (each dab relaxes the layer a little towards the local
## average), since "smooth up to a cap" has no useful meaning.

enum Op { RAISE, SMOOTH, FLATTEN, RESET, PAINT, ERASE }

const N := ReliefDoc.N
const LUT_N := 1024

var buf := PackedFloat32Array()
var pre := PackedFloat32Array()
var cov := PackedFloat32Array()
var op := Op.RAISE
var radius := 24.0
var hardness := 0.0
var opacity := 1.0
var flow := 0.25
var depth := 0.03  ## signed for RAISE (negative = lower/carve)
var flat_target := 0.0
var lut := PackedFloat32Array()


func _init() -> void:
	cov.resize(N * N)
	lut.resize(LUT_N)


func begin(layer: PackedFloat32Array, operation: int, start: Vector2) -> void:
	buf = layer
	pre = layer.duplicate()
	cov.fill(0.0)
	op = operation
	_build_lut()
	if op == Op.FLATTEN:
		var ix := clampi(int(start.x), 0, N - 1)
		var iy := clampi(int(start.y), 0, N - 1)
		flat_target = pre[iy * N + ix]


## Falloff by squared normalised distance. Fully on inside `hardness`, then a smootherstep
## (C2 continuous) ramp to zero at the rim, which avoids visible rings in the relief.
func _build_lut() -> void:
	var h := clampf(hardness, 0.0, 0.99)
	for k in LUT_N:
		var t := sqrt(k / float(LUT_N - 1))
		var f := 1.0
		if t > h:
			var x := (t - h) / (1.0 - h)
			f = 1.0 - x * x * x * (x * (x * 6.0 - 15.0) + 10.0)
		lut[k] = f


func dab(cx: float, cy: float, pressure: float) -> void:
	if op == Op.SMOOTH:
		_smooth_dab(cx, cy, pressure)
		return
	var r := radius
	var x0 := maxi(0, floori(cx - r))
	var x1 := mini(N - 1, ceili(cx + r))
	var y0 := maxi(0, floori(cy - r))
	var y1 := mini(N - 1, ceili(cy + r))
	var r2 := r * r
	var lk := (LUT_N - 1) / r2
	var fl := flow * pressure
	var b := buf
	buf = PackedFloat32Array()
	var c := cov
	cov = PackedFloat32Array()
	var p := pre
	var l := lut
	var o := op
	var amt := depth * opacity
	var opa := opacity
	var tgt := flat_target
	for y in range(y0, y1 + 1):
		var dy := y + 0.5 - cy
		var dy2 := dy * dy
		if dy2 >= r2:
			continue
		var row := y * N
		for x in range(x0, x1 + 1):
			var dx := x + 0.5 - cx
			var d2 := dx * dx + dy2
			if d2 >= r2:
				continue
			var a := fl * l[int(d2 * lk)]
			if a <= 0.0:
				continue
			var i := row + x
			var cv := c[i]
			cv += a * (1.0 - cv)
			c[i] = cv
			if o == Op.RAISE:
				b[i] = p[i] + amt * cv
			elif o == Op.FLATTEN:
				b[i] = p[i] + (tgt - p[i]) * opa * cv
			elif o == Op.RESET:
				b[i] = p[i] * (1.0 - opa * cv)
			elif o == Op.PAINT:
				b[i] = maxf(p[i], opa * cv)
			else:
				b[i] = minf(p[i], 1.0 - opa * cv)
	buf = b
	cov = c


func _smooth_dab(cx: float, cy: float, pressure: float) -> void:
	var r := radius
	var s := maxi(1, int(r * 0.12))  # wider kernel for bigger brushes
	var x0 := maxi(s, floori(cx - r))
	var x1 := mini(N - 1 - s, ceili(cx + r))
	var y0 := maxi(s, floori(cy - r))
	var y1 := mini(N - 1 - s, ceili(cy + r))
	var r2 := r * r
	var lk := (LUT_N - 1) / r2
	var k := flow * opacity * pressure
	var b := buf
	buf = PackedFloat32Array()
	var l := lut
	var sn := s * N
	for y in range(y0, y1 + 1):
		var dy := y + 0.5 - cy
		var dy2 := dy * dy
		if dy2 >= r2:
			continue
		var row := y * N
		for x in range(x0, x1 + 1):
			var dx := x + 0.5 - cx
			var d2 := dx * dx + dy2
			if d2 >= r2:
				continue
			var a := k * l[int(d2 * lk)]
			if a <= 0.0:
				continue
			var i := row + x
			var avg := ((b[i - s] + b[i + s] + b[i - sn] + b[i + sn]) * 2.0
				+ b[i - sn - s] + b[i - sn + s] + b[i + sn - s] + b[i + sn + s]) / 12.0
			b[i] += (avg - b[i]) * a
	buf = b
