class_name LumpMesher
extends RefCounted
## Extracts the zero set of a LumpField as a triangle mesh on an n^3 grid over the unit cube.
## Surface Nets, with one vertex per surface cell.  Where the field's sharp flag is set, the
## vertex is placed by a QEF (dual-contouring style) solve so creases stay crisp.  Elsewhere
## it is the mass point, which is smooth.  A coarse pre-pass limits fine evaluation to a band
## around the surface.

const PALETTE: Array[Color] = [
	Color(1.00, 0.76, 0.22), Color(0.96, 0.86, 0.48), Color(0.42, 0.27, 0.10), Color(0.86, 0.86, 0.80),
	Color(0.92, 0.52, 0.42), Color(0.40, 0.75, 0.45), Color(0.40, 0.55, 0.90), Color(0.60, 0.60, 0.62)]

const SENT := 1.0e9
const EDGES := [0, 1, 2, 3, 4, 5, 6, 7, 0, 2, 1, 3, 4, 6, 5, 7, 0, 4, 1, 5, 2, 6, 3, 7]


## opts: band (coarse step, 1 = full grid, default 4), lipschitz (band width factor, default 4),
##       sharp (honour sharp flags, default true), qef_lambda (default 0.05)
static func build(field: LumpField, n: int, opts: Dictionary = {}) -> Dictionary:
	var t0 := Time.get_ticks_usec()
	var src := field.source
	var CS := LumpField.CS
	var n1 := n + 1
	var inv := 1.0 / n
	var honour_sharp: bool = opts.get("sharp", true)
	var lam: float = opts.get("qef_lambda", 0.05)
	var central: bool = opts.get("qef_normals", "central") == "central"

	# Column caches: the field is separable per view, so each column is decoded once.
	var cf := PackedFloat32Array(); cf.resize(n1 * n1 * CS)
	var cs := PackedFloat32Array(); cs.resize(n1 * n1 * CS)
	var ct := PackedFloat32Array(); ct.resize(n1 * n1 * CS)
	for b in n1:
		for a in n1:
			var o := (b * n1 + a) * CS
			src.fill_column(0, a * inv, b * inv, cf, o)  # front: a = x, b = y
			src.fill_column(1, a * inv, b * inv, cs, o)  # side:  a = z, b = y
			src.fill_column(2, a * inv, b * inv, ct, o)  # top:   a = x, b = z
	var t_cols := Time.get_ticks_usec()

	var F := PackedFloat32Array(); F.resize(n1 * n1 * n1)
	F.fill(SENT)
	var evals := 0

	var f: int = opts.get("band", 4)
	if f < 1 or n % f != 0:
		f = 1
	var nc := n / f
	var cell_mark := PackedByteArray(); cell_mark.resize(nc * nc * nc)
	if f == 1:
		cell_mark.fill(1)
		for k in n1:
			for j in n1:
				for i in n1:
					F[(k * n1 + j) * n1 + i] = LumpField.eval_rec(cf, (j * n1 + i) * CS, cs, (j * n1 + k) * CS, ct, (k * n1 + i) * CS, Vector3(i, j, k) * inv)
		evals = n1 * n1 * n1
	else:
		var nc1 := nc + 1
		for K in nc1:
			for J in nc1:
				for I in nc1:
					var i := I * f
					var j := J * f
					var k := K * f
					F[(k * n1 + j) * n1 + i] = LumpField.eval_rec(cf, (j * n1 + i) * CS, cs, (j * n1 + k) * CS, ct, (k * n1 + i) * CS, Vector3(i, j, k) * inv)
		evals = nc1 * nc1 * nc1
		var thr: float = opts.get("lipschitz", 4.0) * f * inv * sqrt(3.0)
		var raw_mark := PackedByteArray(); raw_mark.resize(nc * nc * nc)
		for K in nc:
			for J in nc:
				for I in nc:
					var neg := false
					var pos := false
					var near := false
					for c in 8:
						var val := F[((K + ((c >> 2) & 1)) * f * n1 + (J + ((c >> 1) & 1)) * f) * n1 + (I + (c & 1)) * f]
						if val < 0.0: neg = true
						else: pos = true
						if absf(val) < thr: near = true
					if (neg and pos) or near:
						raw_mark[(K * nc + J) * nc + I] = 1
		for K in nc:
			for J in nc:
				for I in nc:
					if raw_mark[(K * nc + J) * nc + I] == 0:
						continue
					for dk in range(maxi(K - 1, 0), mini(K + 2, nc)):
						for dj in range(maxi(J - 1, 0), mini(J + 2, nc)):
							for di in range(maxi(I - 1, 0), mini(I + 2, nc)):
								cell_mark[(dk * nc + dj) * nc + di] = 1
		for K in nc:
			for J in nc:
				for I in nc:
					if cell_mark[(K * nc + J) * nc + I] == 0:
						continue
					for k in range(K * f, K * f + f + 1):
						for j in range(J * f, J * f + f + 1):
							for i in range(I * f, I * f + f + 1):
								var id := (k * n1 + j) * n1 + i
								if F[id] == SENT:
									F[id] = LumpField.eval_rec(cf, (j * n1 + i) * CS, cs, (j * n1 + k) * CS, ct, (k * n1 + i) * CS, Vector3(i, j, k) * inv)
									evals += 1
	var t_eval := Time.get_ticks_usec()
	if opts.get("occupancy_only", false):
		var occ := PackedByteArray(); occ.resize(F.size())
		for id in F.size():
			occ[id] = 1 if F[id] < 0.0 else 0
		return {n = n, occupancy = occ}

	# Pass 1: one vertex per surface cell.
	var vid := PackedInt32Array(); vid.resize(n * n * n)
	vid.fill(-1)
	var verts := PackedVector3Array()
	var normals := PackedVector3Array()
	var colors := PackedColorArray()
	var sharp_flags := PackedByteArray()
	var cells := PackedInt32Array()
	var vals := PackedFloat32Array(); vals.resize(8)
	var px := PackedVector3Array(); px.resize(12)
	var pn := PackedVector3Array(); pn.resize(12)
	var cg := PackedVector3Array(); cg.resize(8)
	for cid in nc * nc * nc:
		if cell_mark[cid] == 0:
			continue
		var I := cid % nc
		var J := (cid / nc) % nc
		var K := cid / (nc * nc)
		for k in range(K * f, K * f + f):
			for j in range(J * f, J * f + f):
				for i in range(I * f, I * f + f):
					var base := (k * n1 + j) * n1 + i
					var neg := 0
					for c in 8:
						var val := F[base + ((c >> 2) & 1) * n1 * n1 + ((c >> 1) & 1) * n1 + (c & 1)]
						vals[c] = val
						if val < 0.0:
							neg += 1
					if neg == 0 or neg == 8:
						continue
					var np := 0
					var mass := Vector3.ZERO
					for e in 12:
						var c0: int = EDGES[e * 2]
						var c1: int = EDGES[e * 2 + 1]
						var a0 := vals[c0]
						var a1 := vals[c1]
						if (a0 < 0.0) == (a1 < 0.0):
							continue
						var t := a0 / (a0 - a1)
						var p0 := Vector3(c0 & 1, (c0 >> 1) & 1, (c0 >> 2) & 1)
						var p1 := Vector3(c1 & 1, (c1 >> 1) & 1, (c1 >> 2) & 1)
						px[np] = p0.lerp(p1, t)
						pn[np] = Vector3(c0, c1, t)
						np += 1
						mass += px[np - 1]
					mass /= np
					var info := LumpField.info_rec(cf, (j * n1 + i) * CS, cs, (j * n1 + k) * CS, ct, (k * n1 + i) * CS, Vector3(i, j, k) * inv)
					var is_sharp := honour_sharp and info.y >= 0.5
					var local := mass
					if is_sharp:
						var xx := lam; var xy := 0.0; var xz := 0.0
						var yy := lam; var yz := 0.0; var zz := lam
						var rhs := Vector3.ZERO
						if central:
							for c in 8:
								cg[c] = _central_grad(F, n1, base + ((c >> 2) & 1) * n1 * n1 + ((c >> 1) & 1) * n1 + (c & 1))
						for q in np:
							var g: Vector3
							if central:
								g = cg[int(pn[q].x)].lerp(cg[int(pn[q].y)], pn[q].z).normalized()
							else:
								g = _trilinear_grad(vals, px[q]).normalized()
							xx += g.x * g.x; xy += g.x * g.y; xz += g.x * g.z
							yy += g.y * g.y; yz += g.y * g.z; zz += g.z * g.z
							rhs += g * g.dot(px[q] - mass)
						var m := Basis(Vector3(xx, xy, xz), Vector3(xy, yy, yz), Vector3(xz, yz, zz))
						if absf(m.determinant()) > 1e-9:
							local = (mass + m.inverse() * rhs).clamp(Vector3.ZERO, Vector3.ONE)
					var nrm := _trilinear_grad(vals, local)
					vid[(k * n + j) * n + i] = verts.size()
					verts.append((Vector3(i, j, k) + local) * inv)
					normals.append(nrm.normalized() if nrm.length_squared() > 0.0 else Vector3.UP)
					colors.append(PALETTE[clampi(int(info.x), 0, 7)])
					sharp_flags.append(1 if info.y >= 0.5 else 0)
					cells.append(base)
	var t_verts := Time.get_ticks_usec()

	# Pass 2: a quad for every grid edge with a sign change, joining its four cells.
	var indices := PackedInt32Array()
	var holes := 0
	var nn := n1 * n1
	for ci in cells.size():
		var base := cells[ci]
		var i := base % n1
		var j := (base / n1) % n1
		var k := base / nn
		var inside := F[base] < 0.0
		for axis in 3:
			var q := base + (1 if axis == 0 else (n1 if axis == 1 else nn))
			if (F[q] < 0.0) == inside:
				continue
			var A := -1; var B := -1; var C := -1; var D := -1
			if axis == 0:
				if j < 1 or k < 1: continue
				A = vid[((k - 1) * n + j - 1) * n + i]; B = vid[((k - 1) * n + j) * n + i]
				C = vid[(k * n + j) * n + i]; D = vid[(k * n + j - 1) * n + i]
			elif axis == 1:
				if i < 1 or k < 1: continue
				A = vid[((k - 1) * n + j) * n + i - 1]; B = vid[(k * n + j) * n + i - 1]
				C = vid[(k * n + j) * n + i]; D = vid[((k - 1) * n + j) * n + i]
			else:
				if i < 1 or j < 1: continue
				A = vid[(k * n + j - 1) * n + i - 1]; B = vid[(k * n + j - 1) * n + i]
				C = vid[(k * n + j) * n + i]; D = vid[(k * n + j) * n + i - 1]
			if A < 0 or B < 0 or C < 0 or D < 0:
				holes += 1
				continue
			# Godot treats clockwise triangles as front faces.
			if inside:
				indices.append_array([A, C, B, A, D, C])
			else:
				indices.append_array([A, B, C, A, C, D])
	var t_end := Time.get_ticks_usec()

	return {
		n = n, verts = verts, normals = normals, colors = colors, indices = indices,
		sharp = sharp_flags,
		stats = {
			verts = verts.size(), tris = indices.size() / 3, holes = holes, evals = evals,
			band = f, ms_columns = (t_cols - t0) / 1000.0, ms_eval = (t_eval - t_cols) / 1000.0,
			ms_verts = (t_verts - t_eval) / 1000.0, ms_faces = (t_end - t_verts) / 1000.0,
			ms_total = (t_end - t0) / 1000.0,
		},
	}


## Central-difference gradient of the sampled grid at point id (one-sided at band edges).
static func _central_grad(F: PackedFloat32Array, n1: int, id: int) -> Vector3:
	var g := Vector3.ZERO
	var c := F[id]
	var strides := [1, n1, n1 * n1]
	var coord := [id % n1, (id / n1) % n1, id / (n1 * n1)]
	for a in 3:
		var st: int = strides[a]
		var lo := F[id - st] if coord[a] > 0 else SENT
		var hi := F[id + st] if coord[a] < n1 - 1 else SENT
		if lo != SENT and hi != SENT:
			g[a] = (hi - lo) * 0.5
		elif hi != SENT:
			g[a] = hi - c
		elif lo != SENT:
			g[a] = c - lo
	return g


static func _trilinear_grad(v: PackedFloat32Array, p: Vector3) -> Vector3:
	var x := p.x; var y := p.y; var z := p.z
	return Vector3(
		(1 - y) * (1 - z) * (v[1] - v[0]) + y * (1 - z) * (v[3] - v[2]) + (1 - y) * z * (v[5] - v[4]) + y * z * (v[7] - v[6]),
		(1 - x) * (1 - z) * (v[2] - v[0]) + x * (1 - z) * (v[3] - v[1]) + (1 - x) * z * (v[6] - v[4]) + x * z * (v[7] - v[5]),
		(1 - x) * (1 - y) * (v[4] - v[0]) + x * (1 - y) * (v[5] - v[1]) + (1 - x) * y * (v[6] - v[2]) + x * y * (v[7] - v[3]))


## ArrayMesh centred on the origin, unit cube scaled to `scale` metres.
static func to_array_mesh(res: Dictionary, scale: float = 1.0, material: Material = null) -> ArrayMesh:
	var verts: PackedVector3Array = res.verts
	var out := PackedVector3Array(); out.resize(verts.size())
	for i in verts.size():
		out[i] = (verts[i] - Vector3(0.5, 0.5, 0.5)) * scale
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = out
	arrays[Mesh.ARRAY_NORMAL] = res.normals
	arrays[Mesh.ARRAY_COLOR] = res.colors
	arrays[Mesh.ARRAY_INDEX] = res.indices
	var mesh := ArrayMesh.new()
	if (res.indices as PackedInt32Array).size() > 0:
		mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
		if material:
			mesh.surface_set_material(0, material)
	return mesh


static func gold_material() -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.vertex_color_use_as_albedo = true
	m.vertex_color_is_srgb = true
	m.metallic = 0.85
	m.roughness = 0.32
	return m
