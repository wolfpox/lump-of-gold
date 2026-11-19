class_name ReliefMesher
extends RefCounted
## Builds the game mesh of a card: a closed low-poly mesh whose detail is left to the
## per-pixel normals (and later, baked maps).
##
## 1. Outline: marching squares on the signed distance field, then Douglas-Peucker
##    simplification down to the outline share of the budget. Front and back share it.
## 2. Interior, per side: error-driven insertion. Triangulate, measure where the triangles
##    are furthest from the true height, add vertices there, repeat until the triangle budget
##    or the error target is reached. Flat areas therefore cost almost nothing.
## 3. Delaunay triangulation; triangles whose centre lies outside the outline are dropped.
##
## Coordinates while building: texel units (0..N). Output: column uv (0..1) and heights.

const N := ReliefDoc.N
const SAMPLE_STEP := 4          # error is measured every 4 texels
const ERROR_TARGET := 0.0006    # world units (the card is 1 unit wide)


## snapshot: {sd, phi, sculpt0, sculpt1, params: [front, back], core, budget}
## Returns {sides: [{uv: PackedVector2Array, h: PackedFloat32Array, tris: PackedInt32Array}, x2],
##          outline_count, ms}
static func build(snap: Dictionary) -> Dictionary:
	var t0 := Time.get_ticks_msec()
	var sd: PackedFloat32Array = snap.sd
	var budget: int = snap.budget
	var loops := _trace_outline(sd)
	var outline_target := clampi(int(budget * 0.3), 12, 1200)
	var outline := _simplify_loops(loops, outline_target)
	var sides: Array = []
	for s in 2:
		var sculpt: PackedFloat32Array = snap["sculpt%d" % s]
		sides.append(_build_side(sd, snap.phi, sculpt, snap.params[s], snap.core, outline, budget))
	return {sides = sides, outline_count = outline.size(), ms = Time.get_ticks_msec() - t0}


# ------------------------------------------------------------------------------ outline

static func _trace_outline(sd: PackedFloat32Array) -> Array:
	var n := N
	var ins := PackedByteArray()
	ins.resize(n * n)
	for i in n * n:
		if sd[i] >= 0.0:
			ins[i] = 1
	var pos := {}   # edge key -> Vector2 (texel coords)
	var adj := {}   # edge key -> Array[int] neighbours
	for y in n - 1:
		var row := y * n
		for x in n - 1:
			var i := row + x
			var a := ins[i]
			var b := ins[i + 1]
			var c := ins[i + n + 1]
			var d := ins[i + n]
			if a == b and b == c and c == d:
				continue
			var kt := i * 2
			var kr := (i + 1) * 2 + 1
			var kb := (i + n) * 2
			var kl := i * 2 + 1
			var cross: Array[int] = []
			if a != b:
				cross.append(kt)
				_edge_pos(pos, kt, sd, i, i + 1, x, y, x + 1, y)
			if b != c:
				cross.append(kr)
				_edge_pos(pos, kr, sd, i + 1, i + n + 1, x + 1, y, x + 1, y + 1)
			if c != d:
				cross.append(kb)
				_edge_pos(pos, kb, sd, i + n, i + n + 1, x, y + 1, x + 1, y + 1)
			if d != a:
				cross.append(kl)
				_edge_pos(pos, kl, sd, i, i + n, x, y, x, y + 1)
			if cross.size() == 2:
				_link(adj, cross[0], cross[1])
			elif cross.size() == 4:
				var centre := (sd[i] + sd[i + 1] + sd[i + n] + sd[i + n + 1]) * 0.25
				if (1 if centre >= 0.0 else 0) == a:
					_link(adj, kt, kr)
					_link(adj, kb, kl)
				else:
					_link(adj, kt, kl)
					_link(adj, kr, kb)
	var loops: Array = []
	var seen := {}
	for start in adj.keys():
		if seen.has(start):
			continue
		var loop := PackedVector2Array()
		var prev := -1
		var cur: int = start
		while not seen.has(cur):
			seen[cur] = true
			loop.append(pos[cur])
			var nb: Array = adj[cur]
			var nxt: int = nb[0] if nb[0] != prev else (nb[1] if nb.size() > 1 else nb[0])
			prev = cur
			cur = nxt
		if loop.size() >= 3:
			loops.append(loop)
	return loops


static func _edge_pos(pos: Dictionary, key: int, sd: PackedFloat32Array, i0: int, i1: int,
		x0: int, y0: int, x1: int, y1: int) -> void:
	if pos.has(key):
		return
	var s0 := sd[i0]
	var s1 := sd[i1]
	var t := clampf(s0 / (s0 - s1), 0.0, 1.0)
	pos[key] = Vector2(lerpf(x0, x1, t) + 0.5, lerpf(y0, y1, t) + 0.5)


static func _link(adj: Dictionary, a: int, b: int) -> void:
	if not adj.has(a):
		adj[a] = []
	if not adj.has(b):
		adj[b] = []
	adj[a].append(b)
	adj[b].append(a)


## Simplify all loops with one shared tolerance, found by bisection, so the total vertex
## count lands at or under `target`. Returns one flat array of outline points.
static func _simplify_loops(loops: Array, target: int) -> PackedVector2Array:
	var lo := 0.05
	var hi := 64.0
	var best := PackedVector2Array()
	for it in 18:
		var tol := sqrt(lo * hi)
		var pts := PackedVector2Array()
		for loop in loops:
			var s := _dp_closed(loop, tol)
			if s.size() >= 3 and absf(_area(s)) > 4.0:
				pts.append_array(s)
		if pts.size() > target:
			lo = tol
		else:
			hi = tol
			best = pts
	return best


static func _area(p: PackedVector2Array) -> float:
	var a := 0.0
	for i in p.size():
		var q := p[(i + 1) % p.size()]
		a += p[i].x * q.y - q.x * p[i].y
	return a * 0.5


static func _dp_closed(p: PackedVector2Array, tol: float) -> PackedVector2Array:
	var n := p.size()
	if n < 4:
		return p
	# split at the point furthest from p[0] and simplify both halves
	var far := 0
	var fd := -1.0
	for i in n:
		var d := p[i].distance_squared_to(p[0])
		if d > fd:
			fd = d
			far = i
	var keep := PackedByteArray()
	keep.resize(n)
	keep[0] = 1
	keep[far] = 1
	_dp(p, 0, far, tol, keep)
	_dp_wrap(p, far, n, tol, keep)
	var out := PackedVector2Array()
	for i in n:
		if keep[i] == 1:
			out.append(p[i])
	return out


static func _dp(p: PackedVector2Array, a: int, b: int, tol: float, keep: PackedByteArray) -> void:
	var stack: Array[Vector2i] = [Vector2i(a, b)]
	while not stack.is_empty():
		var seg: Vector2i = stack.pop_back()
		var best := -1.0
		var bi := -1
		for i in range(seg.x + 1, seg.y):
			var d := _seg_dist(p[i], p[seg.x], p[seg.y])
			if d > best:
				best = d
				bi = i
		if bi >= 0 and best > tol:
			keep[bi] = 1
			stack.append(Vector2i(seg.x, bi))
			stack.append(Vector2i(bi, seg.y))


## The wrap-around half (far .. n-1, 0) via a re-indexed copy.
static func _dp_wrap(p: PackedVector2Array, far: int, n: int, tol: float, keep: PackedByteArray) -> void:
	var q := PackedVector2Array()
	for i in range(far, n):
		q.append(p[i])
	q.append(p[0])
	var k := PackedByteArray()
	k.resize(q.size())
	_dp(q, 0, q.size() - 1, tol, k)
	for j in range(1, q.size() - 1):
		if k[j] == 1:
			keep[far + j] = 1


static func _seg_dist(p: Vector2, a: Vector2, b: Vector2) -> float:
	return p.distance_to(Geometry2D.get_closest_point_to_segment(p, a, b))


# ------------------------------------------------------------------------------ interior

static func _build_side(sd: PackedFloat32Array, phi: PackedFloat32Array,
		sculpt: PackedFloat32Array, p: Dictionary, core: float,
		outline: PackedVector2Array, budget: int) -> Dictionary:
	var inv := 1.0 / N
	var S := N / SAMPLE_STEP
	# True height on the sample grid, and where new vertices may go (not hugging the rim).
	var ht := PackedFloat32Array()
	ht.resize(S * S)
	var allowed := PackedByteArray()
	allowed.resize(S * S)
	for sy in S:
		for sx in S:
			var u := (sx + 0.5) * SAMPLE_STEP * inv
			var v := (sy + 0.5) * SAMPLE_STEP * inv
			var si := sy * S + sx
			if ReliefDoc.sample(sd, N, u, v) > 1.0:
				allowed[si] = 1
				ht[si] = ReliefDoc.height_at(sd, phi, sculpt, p, core, u, v)
	var pts := outline.duplicate()
	var hs := PackedFloat32Array()
	hs.resize(pts.size())  # outline vertices sit at height 0, where front meets back
	var max_interior := maxi(0, (budget - pts.size() + 2) / 2)
	var added := 0
	var tris := PackedInt32Array()
	for round_i in 12:
		tris = _triangulate(pts, sd)
		if added >= max_interior:
			break
		var err := _errors(pts, hs, tris, ht, S)
		# Rank samples by error (packed key sort: error in the high bits, index in the low).
		var keys := PackedFloat64Array()
		for si in S * S:
			if allowed[si] == 1 and err[si] > ERROR_TARGET:
				keys.append(-(floorf(err[si] * 1.0e6) * 65536.0 + si))
		if keys.is_empty():
			break
		keys.sort()
		var remaining := max_interior - added
		var take := mini(remaining, maxi(4, int(ceil(remaining * 0.35))))
		# Spread the new points out so one bad region doesn't swallow the whole round.
		var spacing := maxi(1, int(sqrt(float(S * S) / maxf(take * 4.0, 1.0))))
		var blocked := PackedByteArray()
		blocked.resize(S * S)
		var chosen := 0
		for key in keys:
			if chosen >= take:
				break
			var si := int(-key) % 65536
			if blocked[si] == 1:
				continue
			var sx := si % S
			var sy := si / S
			for by in range(maxi(0, sy - spacing), mini(S, sy + spacing + 1)):
				for bx in range(maxi(0, sx - spacing), mini(S, sx + spacing + 1)):
					blocked[by * S + bx] = 1
			var tp := Vector2((sx + 0.5) * SAMPLE_STEP, (sy + 0.5) * SAMPLE_STEP)
			pts.append(tp)
			hs.append(ht[si])
			chosen += 1
		added += chosen
		if chosen == 0:
			break
	tris = _triangulate(pts, sd)
	var uv := PackedVector2Array()
	uv.resize(pts.size())
	for i in pts.size():
		uv[i] = pts[i] * inv
	return {uv = uv, h = hs, tris = tris}


static func _triangulate(pts: PackedVector2Array, sd: PackedFloat32Array) -> PackedInt32Array:
	var all := Geometry2D.triangulate_delaunay(pts)
	var out := PackedInt32Array()
	var inv := 1.0 / N
	for t in range(0, all.size(), 3):
		var c := (pts[all[t]] + pts[all[t + 1]] + pts[all[t + 2]]) / 3.0
		if ReliefDoc.sample(sd, N, c.x * inv, c.y * inv) > 0.0:
			out.append(all[t])
			out.append(all[t + 1])
			out.append(all[t + 2])
	return out


## |true height - mesh height| on the sample grid, by rasterising every triangle.
static func _errors(pts: PackedVector2Array, hs: PackedFloat32Array, tris: PackedInt32Array,
		ht: PackedFloat32Array, S: int) -> PackedFloat32Array:
	var err := PackedFloat32Array()
	err.resize(S * S)
	var st := float(SAMPLE_STEP)
	for t in range(0, tris.size(), 3):
		var a := pts[tris[t]] / st - Vector2(0.5, 0.5)
		var b := pts[tris[t + 1]] / st - Vector2(0.5, 0.5)
		var c := pts[tris[t + 2]] / st - Vector2(0.5, 0.5)
		var ha := hs[tris[t]]
		var hb := hs[tris[t + 1]]
		var hc := hs[tris[t + 2]]
		var den := (b.y - c.y) * (a.x - c.x) + (c.x - b.x) * (a.y - c.y)
		if absf(den) < 1e-9:
			continue
		var x0 := maxi(0, ceili(minf(a.x, minf(b.x, c.x))))
		var x1 := mini(S - 1, floori(maxf(a.x, maxf(b.x, c.x))))
		var y0 := maxi(0, ceili(minf(a.y, minf(b.y, c.y))))
		var y1 := mini(S - 1, floori(maxf(a.y, maxf(b.y, c.y))))
		var inv_den := 1.0 / den
		for y in range(y0, y1 + 1):
			for x in range(x0, x1 + 1):
				var w0 := ((b.y - c.y) * (x - c.x) + (c.x - b.x) * (y - c.y)) * inv_den
				var w1 := ((c.y - a.y) * (x - c.x) + (a.x - c.x) * (y - c.y)) * inv_den
				var w2 := 1.0 - w0 - w1
				if w0 < -1e-4 or w1 < -1e-4 or w2 < -1e-4:
					continue
				var si := y * S + x
				err[si] = absf(ht[si] - (w0 * ha + w1 * hb + w2 * hc))
	return err


# ------------------------------------------------------------------------------ Godot mesh

## Front faces +Z, back faces -Z; both in the card's local frame (1 unit wide, centred).
static func to_array_mesh(res: Dictionary) -> ArrayMesh:
	var mesh := ArrayMesh.new()
	for s in 2:
		var side: Dictionary = res.sides[s]
		var uv: PackedVector2Array = side.uv
		var h: PackedFloat32Array = side.h
		var tris: PackedInt32Array = side.tris
		var verts := PackedVector3Array()
		var normals := PackedVector3Array()
		verts.resize(uv.size())
		normals.resize(uv.size())
		var zs := 1.0 if s == 0 else -1.0
		for i in uv.size():
			verts[i] = Vector3(uv[i].x - 0.5, 0.5 - uv[i].y, zs * h[i])
			normals[i] = Vector3(0, 0, zs)
		var idx := PackedInt32Array()
		idx.resize(tris.size())
		for t in range(0, tris.size(), 3):
			# Godot front faces are clockwise; pick the winding that faces outward.
			var a := verts[tris[t]]
			var b := verts[tris[t + 1]]
			var c := verts[tris[t + 2]]
			var facing := (b - a).cross(c - a).z * zs
			idx[t] = tris[t]
			idx[t + 1] = tris[t + 1] if facing < 0.0 else tris[t + 2]
			idx[t + 2] = tris[t + 2] if facing < 0.0 else tris[t + 1]
		var arr := []
		arr.resize(Mesh.ARRAY_MAX)
		arr[Mesh.ARRAY_VERTEX] = verts
		arr[Mesh.ARRAY_NORMAL] = normals
		arr[Mesh.ARRAY_TEX_UV] = uv
		arr[Mesh.ARRAY_INDEX] = idx
		mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arr)
	return mesh


static func to_wire_mesh(res: Dictionary) -> ArrayMesh:
	var lines := PackedVector3Array()
	for s in 2:
		var side: Dictionary = res.sides[s]
		var uv: PackedVector2Array = side.uv
		var h: PackedFloat32Array = side.h
		var tris: PackedInt32Array = side.tris
		var zs := 1.0 if s == 0 else -1.0
		var seen := {}
		for t in range(0, tris.size(), 3):
			for e in 3:
				var i0 := tris[t + e]
				var i1 := tris[t + (e + 1) % 3]
				var key := mini(i0, i1) * 100000 + maxi(i0, i1)
				if seen.has(key):
					continue
				seen[key] = true
				for i in [i0, i1]:
					lines.append(Vector3(uv[i].x - 0.5, 0.5 - uv[i].y, zs * (h[i] + 0.0015)))
	var mesh := ArrayMesh.new()
	var arr := []
	arr.resize(Mesh.ARRAY_MAX)
	arr[Mesh.ARRAY_VERTEX] = lines
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_LINES, arr)
	return mesh
