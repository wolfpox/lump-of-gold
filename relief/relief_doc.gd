class_name ReliefDoc
extends RefCounted
## A two-sided relief stored as a handful of 512x512 float layers.
##
##   mask     shared silhouette (0..1). Both sides use it, so the outline is always the same.
##   sculpt0  front brush layer (height added on top of the front's base shape)
##   sculpt1  back brush layer  (stored in the same texel grid as the front, so texel i is the
##            same column through the piece; the back canvas just displays it mirrored)
##   guide0/1 line art per side (ink 0..1). Only for planning; it never changes the height.
##
## Derived from the mask (recomputed in a background thread when the silhouette changes):
##   sd   signed distance to the silhouette edge, in texels (positive inside)
##   phi  "inflation" field: solution of a Poisson equation inside the silhouette, normalised
##        to 0..1. sqrt(phi) gives round cross-sections, like blowing up a balloon shaped like
##        the outline.
##
## The visible surface of each side is computed in the shader, never baked:
##   z = edge_profile(sd) * max(core/2 + plate + inflate * phi^roundness + sculpt, 0)
## so every shape-modifier slider is non-destructive and instant.

const N := 512
const PHI_N := 256
const BIG := 1.0e10

var mask := PackedFloat32Array()
var sculpt0 := PackedFloat32Array()
var sculpt1 := PackedFloat32Array()
var guide0 := PackedFloat32Array()
var guide1 := PackedFloat32Array()
var sd := PackedFloat32Array()
var phi := PackedFloat32Array()

var core := 0.02
var params: Array[Dictionary] = [
	{plate = 0.0, inflate = 0.12, roundness = 0.5, edge_r = 5.0, edge_shape = 0},
	{plate = 0.0, inflate = 0.0, roundness = 0.5, edge_r = 5.0, edge_shape = 0},
]


func _init() -> void:
	for a in ["mask", "sculpt0", "sculpt1", "guide0", "guide1", "sd"]:
		var arr := PackedFloat32Array()
		arr.resize(N * N)
		set(a, arr)
	phi.resize(PHI_N * PHI_N)


func get_layer(key: String) -> PackedFloat32Array:
	return get(key)


func set_layer(key: String, arr: PackedFloat32Array) -> void:
	set(key, arr)


func make_default() -> void:
	# A soft-edged ellipse so there is something to sculpt immediately.
	var m := PackedFloat32Array()
	m.resize(N * N)
	var c := Vector2(N * 0.5, N * 0.5)
	var rad := Vector2(N * 0.34, N * 0.42)
	for y in N:
		for x in N:
			var p := (Vector2(x + 0.5, y + 0.5) - c) / rad
			var d := (p.length() - 1.0) * minf(rad.x, rad.y)  # ~texels
			m[y * N + x] = clampf(0.5 - d * 0.5, 0.0, 1.0)
	mask = m


func save(path: String) -> Error:
	var f := FileAccess.open_compressed(path, FileAccess.WRITE, FileAccess.COMPRESSION_ZSTD)
	if f == null:
		return FileAccess.get_open_error()
	f.store_var({
		version = 1, n = N, core = core, params = params,
		mask = mask, sculpt0 = sculpt0, sculpt1 = sculpt1, guide0 = guide0, guide1 = guide1,
	})
	return OK


func load_from(path: String) -> Error:
	var f := FileAccess.open_compressed(path, FileAccess.READ, FileAccess.COMPRESSION_ZSTD)
	if f == null:
		return FileAccess.get_open_error()
	var d: Variant = f.get_var()
	if not d is Dictionary or int(d.get("n", 0)) != N:
		return ERR_FILE_CORRUPT
	core = d.core
	params.clear()
	for p in d.params:
		params.append(p)
	for k in ["mask", "sculpt0", "sculpt1", "guide0", "guide1"]:
		set(k, d[k])
	return OK


# ---------------------------------------------------------------------- derived fields

## Signed distance (texels, + inside) to the silhouette's 0.5 contour, at sub-pixel accuracy.
## 1. Lightly blur the mask so even a hard-edged mask has a usable gradient.
## 2. Edge pixels (the 0.5 level passes between them and a neighbour) each get the exact point
##    where the contour crosses, by one Newton step along the mask gradient.
## 3. A Euclidean feature transform finds every pixel's nearest edge pixel; the distance is
##    taken to that pixel's sub-pixel contour point, so long stair-step runs leave no ripples.
static func compute_sd(m: PackedFloat32Array) -> PackedFloat32Array:
	var n := N
	var mb := _box_blur(_box_blur(m, n, 1, true), n, 1, false)
	for k in n:  # the image border is always outside, so the shape is closed
		mb[k] = 0.0
		mb[(n - 1) * n + k] = 0.0
		mb[k * n] = 0.0
		mb[k * n + n - 1] = 0.0
	var ex := PackedFloat32Array()
	var ey := PackedFloat32Array()
	ex.resize(n * n)
	ey.resize(n * n)
	var f := PackedFloat64Array()
	f.resize(n * n)
	f.fill(BIG)
	var any_edge := false
	for y in range(1, n - 1):
		for x in range(1, n - 1):
			var i := y * n + x
			var ins := mb[i] >= 0.5
			if ins == (mb[i - 1] >= 0.5) and ins == (mb[i + 1] >= 0.5) \
					and ins == (mb[i - n] >= 0.5) and ins == (mb[i + n] >= 0.5):
				continue
			var gx := (mb[i + 1] - mb[i - 1]) * 0.5
			var gy := (mb[i + n] - mb[i - n]) * 0.5
			var g2 := gx * gx + gy * gy
			var ox := 0.0
			var oy := 0.0
			if g2 > 1e-8:
				var t := (0.5 - mb[i]) / g2
				ox = clampf(t * gx, -1.0, 1.0)
				oy = clampf(t * gy, -1.0, 1.0)
			ex[i] = x + 0.5 + ox
			ey[i] = y + 0.5 + oy
			f[i] = 0.0
			any_edge = true
	var out := PackedFloat32Array()
	out.resize(n * n)
	if not any_edge:
		out.fill(-1000.0)
		return out
	var feat := _feature_transform(f.duplicate(), n)
	for y in n:
		for x in n:
			var i := y * n + x
			# Nearest contour point among the nearest edge pixel and its 8 neighbours: the min
			# of distances to dense points on the curve is continuous, so no creases.
			var q := feat[i]
			var qx := q % n
			var qy := q / n
			var px := x + 0.5
			var py := y + 0.5
			var best := BIG
			for oy in range(maxi(qy - 1, 0), mini(qy + 2, n)):
				for ox in range(maxi(qx - 1, 0), mini(qx + 2, n)):
					var j := oy * n + ox
					if f[j] != 0.0 and j != q:
						continue
					var dx := px - ex[j]
					var dy := py - ey[j]
					best = minf(best, dx * dx + dy * dy)
			var d := sqrt(best)
			out[i] = d if mb[i] >= 0.5 else -d
	# The contour points carry ~0.1 px of noise. A distance field is linear almost
	# everywhere and blurring leaves linear functions unchanged, so a blur removes the noise
	# without moving the slopes (box radius 2, two passes per axis ~ Gaussian sigma 2).
	for pass_i in 2:
		out = _box_blur(_box_blur(out, n, 2, true), n, 2, false)
	return out


## For every pixel, the index of the nearest pixel with f == 0 (Felzenszwalb, with argmin).
static func _feature_transform(f: PackedFloat64Array, n: int) -> PackedInt32Array:
	var g := PackedFloat64Array()
	var d := PackedFloat64Array()
	var z := PackedFloat64Array()
	var v := PackedInt32Array()
	var arg := PackedInt32Array()
	g.resize(n)
	d.resize(n)
	z.resize(n + 1)
	v.resize(n)
	arg.resize(n)
	var fy := PackedInt32Array()  # nearest feature row within the column, after pass 1
	fy.resize(n * n)
	for x in n:
		for y in n:
			g[y] = f[y * n + x]
		_edt1d(g, d, v, z, n, arg)
		for y in n:
			f[y * n + x] = d[y]
			fy[y * n + x] = arg[y]
	var feat := PackedInt32Array()
	feat.resize(n * n)
	for y in n:
		var row := y * n
		for x in n:
			g[x] = f[row + x]
		_edt1d(g, d, v, z, n, arg)
		for x in n:
			var cx := arg[x]
			feat[row + x] = fy[row + cx] * n + cx
	return feat


static func _box_blur(a: PackedFloat32Array, n: int, r: int, horizontal: bool) -> PackedFloat32Array:
	var out := PackedFloat32Array()
	out.resize(n * n)
	var inv := 1.0 / (2 * r + 1)
	var step := 1 if horizontal else n
	for line in n:
		var base := line * n if horizontal else line
		var acc := 0.0
		for k in range(-r, r + 1):
			acc += a[base + clampi(k, 0, n - 1) * step]
		for k in n:
			out[base + k * step] = acc * inv
			acc += a[base + mini(k + r + 1, n - 1) * step] - a[base + maxi(k - r, 0) * step]
	return out


## Felzenszwalb & Huttenlocher 1D squared distance transform (lower envelope of parabolas).
static func _edt1d(f: PackedFloat64Array, d: PackedFloat64Array, v: PackedInt32Array,
		z: PackedFloat64Array, n: int, arg: PackedInt32Array) -> void:
	var k := 0
	v[0] = 0
	z[0] = -BIG
	z[1] = BIG
	for q in range(1, n):
		var fq := f[q] + q * q
		var vk := v[k]
		var s := (fq - (f[vk] + vk * vk)) / (2.0 * (q - vk))
		while s <= z[k]:
			k -= 1
			vk = v[k]
			s = (fq - (f[vk] + vk * vk)) / (2.0 * (q - vk))
		k += 1
		v[k] = q
		z[k] = s
		z[k + 1] = BIG
	k = 0
	for q in n:
		while z[k + 1] < q:
			k += 1
		var vk := v[k]
		d[q] = (q - vk) * (q - vk) + f[vk]
		arg[q] = vk


## Poisson "inflation": solve laplacian(phi) = -1 inside the silhouette with phi = 0 on the
## edge, coarse-to-fine with red-black SOR, then normalise so the highest point is 1.
static func compute_phi(m: PackedFloat32Array) -> PackedFloat32Array:
	var M := PHI_N
	var step := N / M
	# Coverage at PHI_N resolution.
	var cov := PackedFloat32Array()
	cov.resize(M * M)
	var inv := 1.0 / float(step * step)
	for y in M:
		for x in M:
			var s := 0.0
			for yy in step:
				var row := (y * step + yy) * N + x * step
				for xx in step:
					s += m[row + xx]
			cov[y * M + x] = s * inv
	var covs: Array[PackedFloat32Array] = [cov]
	var sizes: Array[int] = [M]
	while sizes[0] > 32:
		var L: int = sizes[0] / 2
		var src: PackedFloat32Array = covs[0]
		var dst := PackedFloat32Array()
		dst.resize(L * L)
		var S := L * 2
		for y in L:
			for x in L:
				var i := (y * 2) * S + x * 2
				dst[y * L + x] = (src[i] + src[i + 1] + src[i + S] + src[i + S + 1]) * 0.25
		covs.push_front(dst)
		sizes.push_front(L)
	var p := PackedFloat32Array()
	var prev_L := 0
	for lvl in sizes.size():
		var L: int = sizes[lvl]
		var c: PackedFloat32Array = covs[lvl]
		var ins := PackedByteArray()
		ins.resize(L * L)
		for y in range(1, L - 1):
			for x in range(1, L - 1):
				if c[y * L + x] >= 0.5:
					ins[y * L + x] = 1
		var q := PackedFloat32Array()
		q.resize(L * L)
		if prev_L > 0:  # bilinear upsample of the coarser solution as the starting guess
			for y in L:
				var fy := clampf((y + 0.5) * 0.5 - 0.5, 0.0, prev_L - 1.0)
				var y0 := int(fy)
				var y1 := mini(y0 + 1, prev_L - 1)
				var ty := fy - y0
				for x in L:
					if ins[y * L + x] == 0:
						continue
					var fx := clampf((x + 0.5) * 0.5 - 0.5, 0.0, prev_L - 1.0)
					var x0 := int(fx)
					var x1 := mini(x0 + 1, prev_L - 1)
					var tx := fx - x0
					var a := lerpf(p[y0 * prev_L + x0], p[y0 * prev_L + x1], tx)
					var b := lerpf(p[y1 * prev_L + x0], p[y1 * prev_L + x1], tx)
					q[y * L + x] = lerpf(a, b, ty)
		var h2 := 1.0 / float(L * L)
		var omega := minf(2.0 / (1.0 + sin(PI / L)), 1.96)
		var iters := 160 if lvl == 0 else 50
		for it in iters:
			# Over-relaxation converges fast but leaves checkerboard noise; finish each level
			# with plain Gauss-Seidel sweeps, which damp exactly that high-frequency error.
			var w := omega if it < iters - 8 else 1.0
			for parity in 2:
				for y in range(1, L - 1):
					var row := y * L
					var x := 1 + ((y + parity) & 1)
					while x < L - 1:
						var i := row + x
						if ins[i] == 1:
							var g := (q[i - 1] + q[i + 1] + q[i - L] + q[i + L] + h2) * 0.25
							q[i] += w * (g - q[i])
						x += 2
		p = q
		prev_L = L
	var mx := 0.0
	for v in p:
		mx = maxf(mx, v)
	if mx > 0.0:
		var k := 1.0 / mx
		for i in p.size():
			p[i] = maxf(p[i] * k, 0.0)
	return p


# ---------------------------------------------------------------------- CPU height (mirrors shader)

static func sample(arr: PackedFloat32Array, n: int, u: float, v: float) -> float:
	var x := clampf(u * n - 0.5, 0.0, n - 1.001)
	var y := clampf(v * n - 0.5, 0.0, n - 1.001)
	var x0 := int(x)
	var y0 := int(y)
	var tx := x - x0
	var ty := y - y0
	var i := y0 * n + x0
	var a := lerpf(arr[i], arr[i + 1], tx)
	var b := lerpf(arr[i + n], arr[i + n + 1], tx)
	return lerpf(a, b, ty)


static func edge_profile(sd_v: float, edge_r: float, shape: int) -> float:
	if edge_r < 0.75:
		return clampf(sd_v + 0.5, 0.0, 1.0)
	var x := clampf(sd_v / edge_r, 0.0, 1.0)
	match shape:
		0:
			var y := 1.0 - x
			return sqrt(maxf(1.0 - y * y, 0.0))
		1:
			return x * x * (3.0 - 2.0 * x)
		2:
			return x
	return 1.0 - sqrt(maxf(1.0 - x * x, 0.0))


## Height of one side at (u, v), same formula as surf() in relief_common.gdshaderinc.
static func height_at(sd_a: PackedFloat32Array, phi_a: PackedFloat32Array,
		sculpt_a: PackedFloat32Array, p: Dictionary, core_v: float, u: float, v: float) -> float:
	var s := sample(sd_a, N, u, v)
	var ph := maxf(sample(phi_a, PHI_N, u, v), 0.0)
	var b := float(p.plate) + float(p.inflate) * pow(ph, float(p.roundness))
	var sc := sample(sculpt_a, N, u, v)
	return edge_profile(s, float(p.edge_r), int(p.edge_shape)) * maxf(core_v * 0.5 + b + sc, 0.0)
