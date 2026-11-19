class_name LumpMetrics
extends RefCounted
## Measurements for the proof of concept: distance to the analytic ground truth, mesh
## volume and centroid, heightfield representability, winding, GLB round trip.


## Distance from each sampled vertex to the truth field's zero set (Newton projection), in
## volume units.  Returns {d: PackedFloat32Array, idx: PackedInt32Array} for the samples.
static func surface_distances(verts: PackedVector3Array, truth: LumpField, max_samples: int, h: float, mask: PackedByteArray = PackedByteArray()) -> Dictionary:
	var pool := PackedInt32Array()
	for i in verts.size():
		if mask.is_empty() or mask[i] != 0:
			pool.append(i)
	var stride := maxi(1, ceili(float(pool.size()) / max_samples))
	var d := PackedFloat32Array()
	var idx := PackedInt32Array()
	var unresolved := 0
	var s := 0
	while s < pool.size():
		var p := verts[pool[s]]
		var dist := project(truth, p, h)
		if dist < 0.0:
			unresolved += 1
			dist = -dist
		d.append(dist)
		idx.append(pool[s])
		s += stride
	return {d = d, idx = idx, unresolved = unresolved}


## Distance from p to the zero set.  Damped Newton first; if it does not converge, bracket a
## sign change along the gradient line and bisect.  Returns a negative value (minus the search
## radius) if neither finds the surface, so failures are counted instead of hidden.
static func project(truth: LumpField, p: Vector3, h: float) -> float:
	var max_step := h * 8.0
	var x := p
	var f := truth.eval_point(x)
	for it in 12:
		if absf(f) < 1e-6:
			return (x - p).length()
		var g := truth.gradient(x, h)
		var gl2 := g.length_squared()
		if gl2 < 1e-12:
			break
		var step := g * (f / gl2)
		if step.length() > max_step:
			step = step.normalized() * max_step
		x -= step
		f = truth.eval_point(x)
	if absf(f) < 1e-6:
		return (x - p).length()
	# Fallback: along the gradient direction at p, nearest sign change within +-radius.
	var g0 := truth.gradient(p, h)
	if g0.length_squared() < 1e-12:
		return -h * 32.0
	var dir := g0.normalized()
	var f0 := truth.eval_point(p)
	var radius := h * 32.0
	var dt := h * 0.5
	var t := dt
	while t <= radius:
		for sgn: float in [1.0, -1.0]:
			var q: Vector3 = p + dir * (t * sgn)
			if (truth.eval_point(q) < 0.0) != (f0 < 0.0):
				var lo := (t - dt) * sgn
				var hi := t * sgn
				for b in 20:
					var mid := 0.5 * (lo + hi)
					if (truth.eval_point(p + dir * mid) < 0.0) == (f0 < 0.0):
						lo = mid
					else:
						hi = mid
				return absf(0.5 * (lo + hi))
		t += dt
	return -radius


static func summarize(d: PackedFloat32Array, unit: float) -> Dictionary:
	if d.is_empty():
		return {n = 0, mean = 0.0, p95 = 0.0, max = 0.0}
	var sorted := d.duplicate()
	sorted.sort()
	var total := 0.0
	for x in sorted:
		total += x
	return {
		n = sorted.size(),
		mean = total / sorted.size() / unit,
		p95 = sorted[mini(sorted.size() - 1, int(sorted.size() * 0.95))] / unit,
		max = sorted[sorted.size() - 1] / unit,
	}


## Volume and centroid of a closed triangle mesh (divergence theorem), unit-cube coordinates.
static func volume_centroid(res: Dictionary) -> Dictionary:
	var v: PackedVector3Array = res.verts
	var ix: PackedInt32Array = res.indices
	var vol := 0.0
	var cen := Vector3.ZERO
	var t := 0
	while t < ix.size():
		var a := v[ix[t]] - Vector3(0.5, 0.5, 0.5)
		var b := v[ix[t + 1]] - Vector3(0.5, 0.5, 0.5)
		var c := v[ix[t + 2]] - Vector3(0.5, 0.5, 0.5)
		var sv := a.dot(b.cross(c)) / 6.0
		vol += sv
		cen += (a + b + c) * (sv / 4.0)
		t += 3
	# Clockwise winding flips the sign of the standard formula.
	vol = -vol
	cen = -cen
	return {volume = vol, centroid = cen / vol + Vector3(0.5, 0.5, 0.5) if absf(vol) > 1e-12 else Vector3.ZERO}


static func bbox(verts: PackedVector3Array) -> AABB:
	if verts.is_empty():
		return AABB()
	var box := AABB(verts[0], Vector3.ZERO)
	for p in verts:
		box = box.expand(p)
	return box


## Fraction of triangles whose clockwise winding agrees with the outward field normal.
static func winding_agreement(res: Dictionary) -> float:
	var v: PackedVector3Array = res.verts
	var nrm: PackedVector3Array = res.normals
	var ix: PackedInt32Array = res.indices
	var good := 0
	var total := 0
	var t := 0
	while t < ix.size():
		var a := v[ix[t]]
		var geo := (v[ix[t + 1]] - a).cross(v[ix[t + 2]] - a)
		var avg := nrm[ix[t]] + nrm[ix[t + 1]] + nrm[ix[t + 2]]
		if geo.dot(avg) < 0.0:
			good += 1
		total += 1
		t += 3
	return float(good) / maxi(total, 1)


## Full-grid sample of a field at n^3 resolution; returns inside flags (1 = solid).
static func occupancy(field: LumpField, n: int) -> PackedByteArray:
	var res := LumpMesher.build(field, n, {band = 1, occupancy_only = true})
	return res.get("occupancy", PackedByteArray())


## Columns (along x, y, z) that cross more than one solid run: a single heightmap, even a
## two-sided one, cannot represent those columns.
static func multi_span_columns(occ: PackedByteArray, n1: int) -> Vector3i:
	var out := Vector3i.ZERO
	for axis in 3:
		var count := 0
		for b in n1:
			for a in n1:
				var runs := 0
				var prev := 0
				for s in n1:
					var i: int; var j: int; var k: int
					if axis == 0: i = s; j = a; k = b
					elif axis == 1: i = a; j = s; k = b
					else: i = a; j = b; k = s
					var cur := occ[(k * n1 + j) * n1 + i]
					if cur == 1 and prev == 0:
						runs += 1
					prev = cur
				if runs >= 2:
					count += 1
		out[axis] = count
	return out
