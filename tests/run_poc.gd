extends SceneTree
## Lump of Gold proof-of-concept test run.
##   flatpak run org.godotengine.Godot --headless --path . --script res://tests/run_poc.gd
## Writes out/report.md, the textures (DDS + PNG previews) and GLB meshes into out/.
## Pass thresholds were fixed before the first run and are not tuned to the results.

const T := 64
const OUT := "res://out"
const SAMPLES := 2500

# Pre-registered pass thresholds (texels).
const ACC_MEAN_4X := 0.30
const ACC_P95_4X := 1.00
const DRIFT_CENTROID := 0.25
const DRIFT_BBOX := 0.50
const CARVE_P95 := 1.00
const REGION_P95 := 1.00
const WINDING_MIN := 0.99

var lines: PackedStringArray = []
var passes := 0
var fails := 0


func _init() -> void:
	DirAccess.make_dir_recursive_absolute(OUT)
	var t_start := Time.get_ticks_msec()
	_h("# Lump of Gold: proof-of-concept report")
	_l("Texture size %d², 3 views × RGBA16 = %d KB of texture data. Volume = unit cube, 1 texel = 1/%d." % [T, 3 * T * T * 8 / 1024, T])
	_l("Godot %s" % Engine.get_version_info().string)

	var shape := LumpNugget.new(T)
	var tex := LumpBaker.bake(shape)
	var truth := LumpField.new(shape)
	var field := LumpField.new(tex)
	var tx := 1.0 / T

	# ---------------------------------------------------------------- T1 storage
	_h("## T1: Lossless storage through Godot's resource loader")
	tex.save_dds(OUT.path_join("textures"))
	for v in 3:
		tex.make_preview(v).save_png(OUT.path_join("textures/preview_%s.png" % LumpEnc.VIEW_NAMES[v]))
	var back := LumpTextureSet.load_dds(OUT.path_join("textures"), "lump", true)
	_check("DDS RGBA16 round trip via ResourceLoader is bit-exact", back != null and back.equals(tex), "")

	# ---------------------------------------------------------------- T2 representability
	_h("## T2: The shape is not a heightfield along any axis")
	var occ := LumpMetrics.occupancy(field, T)
	var ms := LumpMetrics.multi_span_columns(occ, T + 1)
	_check("Columns with ≥2 separate solid runs exist along x, y and z", ms.x > 0 and ms.y > 0 and ms.z > 0,
		"x: %d, y: %d, z: %d columns (of %d per axis)" % [ms.x, ms.y, ms.z, (T + 1) * (T + 1)])

	# ---------------------------------------------------------------- T3 accuracy
	_h("## T3: Reconstruction accuracy vs analytic ground truth")
	_l("Distance from mesh vertices to the true surface, in texels (%d samples per mesh)." % SAMPLES)
	_l("")
	_l("| Mesh grid | verts | tris | build s | mean | p95 | max | unresolved |")
	_l("|---|---|---|---|---|---|---|---|")
	var meshes := {}
	var acc := {}
	for mult in [1, 2, 4]:
		var res := LumpMesher.build(field, T * mult)
		meshes[mult] = res
		var sd := LumpMetrics.surface_distances(res.verts, truth, SAMPLES, tx * 0.25)
		var st := LumpMetrics.summarize(sd.d, tx)
		acc[mult] = st
		_l("| %d× (%d³) | %d | %d | %.1f | %.3f | %.3f | %.3f | %d |" % [mult, T * mult, res.stats.verts, res.stats.tris, res.stats.ms_total / 1000.0, st.mean, st.p95, st.max, sd.unresolved])
	_l("")
	_check("4× mesh: mean < %.2f and p95 < %.2f texel" % [ACC_MEAN_4X, ACC_P95_4X],
		acc[4].mean < ACC_MEAN_4X and acc[4].p95 < ACC_P95_4X, "mean %.3f, p95 %.3f" % [acc[4].mean, acc[4].p95])
	_check("No holes at any resolution", meshes[1].stats.holes == 0 and meshes[2].stats.holes == 0 and meshes[4].stats.holes == 0,
		"holes: %d / %d / %d" % [meshes[1].stats.holes, meshes[2].stats.holes, meshes[4].stats.holes])
	_check("Winding: ≥%.0f%% of triangles face outward (clockwise front faces)" % (WINDING_MIN * 100),
		LumpMetrics.winding_agreement(meshes[4]) >= WINDING_MIN, "%.2f%%" % (LumpMetrics.winding_agreement(meshes[4]) * 100))

	# ---------------------------------------------------------------- T4 drift
	_h("## T4: Coordinates stay put under subdivision")
	var vc := {}
	var bb := {}
	for mult in [1, 2, 4]:
		vc[mult] = LumpMetrics.volume_centroid(meshes[mult])
		bb[mult] = LumpMetrics.bbox(meshes[mult].verts)
		_l("- %d×: volume %.5f, centroid %s, bbox %s → %s" % [mult, vc[mult].volume, _v(vc[mult].centroid / tx), _v(bb[mult].position / tx), _v(bb[mult].end / tx)])
	var dc := maxf((vc[1].centroid - vc[4].centroid).length(), (vc[2].centroid - vc[4].centroid).length()) / tx
	var db := 0.0
	for mult in [1, 2]:
		db = maxf(db, _max3((bb[mult].position - bb[4].position).abs()) / tx)
		db = maxf(db, _max3((bb[mult].end - bb[4].end).abs()) / tx)
	_check("Centroids of 1×/2× within %.2f texel of 4×" % DRIFT_CENTROID, dc < DRIFT_CENTROID, "max %.3f texel" % dc)
	_check("Bounding boxes of 1×/2× within %.2f texel of 4×" % DRIFT_BBOX, db < DRIFT_BBOX, "max %.3f texel" % db)

	# ---------------------------------------------------------------- T5 carve by channel edits
	_h("## T5: Carving again by editing channels only")
	var carved := tex.duplicate_set()
	var p3 := {view = LumpEnc.VIEW_SIDE, cu = 0.44, cv = 0.62, r = 0.06, tc = 0.82, th = 0.06, op = LumpEnc.CARVE_SUB, mat = 4}
	var p4 := {view = LumpEnc.VIEW_FRONT, cu = 0.44, cv = 0.60, r = 0.06, tc = 0.35, th = 0.13, op = LumpEnc.CARVE_SMOOTH, mat = 2}
	var s3 := LumpCarver.carve_pocket(carved, p3.view, p3.cu, p3.cv, p3.r, p3.tc, p3.th, p3.op, p3.mat)
	var s4 := LumpCarver.carve_pocket(carved, p4.view, p4.cu, p4.cv, p4.r, p4.tc, p4.th, p4.op, p4.mat)
	_l("- Side pocket (absolute frame, sharp subtract): %d texels changed." % s3.changed)
	_l("- Front hidden void overlapping the undercut pocket: %d texels changed, %d promoted SPAN→SLAB." % [s4.changed, s4.promoted])
	var shape2 := shape.duplicate_shape()
	shape2.pockets.append(p3)
	shape2.pockets.append(p4)
	var rebaked := LumpBaker.bake(shape2)
	_check("Channel edits are byte-identical to a full re-bake with the carves added", carved.equals(rebaked),
		"differing texels per view: %s" % str(carved.diff_count(rebaked)))
	var dcount := carved.diff_count(tex)
	_check("Only the two carved views changed", dcount[2] == 0 and dcount[0] > 0 and dcount[1] > 0, "per view: %s" % str(dcount))
	_check("Overlapping carves promoted texels to slab mode", s4.promoted > 0, "%d texels" % s4.promoted)
	var cfield := LumpField.new(carved)
	var ctruth := LumpField.new(shape2)
	var cres := LumpMesher.build(cfield, T * 2)
	var cvol := LumpMetrics.volume_centroid(cres)
	_check("Volume decreased", cvol.volume < vc[2].volume, "%.5f → %.5f" % [vc[2].volume, cvol.volume])
	var cst := LumpMetrics.summarize(LumpMetrics.surface_distances(cres.verts, ctruth, SAMPLES, tx * 0.25).d, tx)
	_check("Carved 2× mesh p95 < %.2f texel vs updated truth" % CARVE_P95, cst.p95 < CARVE_P95, "mean %.3f, p95 %.3f, max %.3f" % [cst.mean, cst.p95, cst.max])
	var cocc := LumpMetrics.occupancy(cfield, T)
	var cms := LumpMetrics.multi_span_columns(cocc, T + 1)
	_l("- Multi-run columns after carving: x %d, y %d, z %d (before: %d, %d, %d)." % [cms.x, cms.y, cms.z, ms.x, ms.y, ms.z])
	carved.save_dds(OUT.path_join("textures"), "lump_carved")
	for v in 3:
		carved.make_preview(v).save_png(OUT.path_join("textures/preview_carved_%s.png" % LumpEnc.VIEW_NAMES[v]))
	var cback := LumpTextureSet.load_dds(OUT.path_join("textures"), "lump_carved", true)
	var cres2 := LumpMesher.build(LumpField.new(cback), T * 2)
	_check("Carved textures survive save → load → rebuild", cback.equals(carved) and cres2.stats.verts == cres.stats.verts,
		"%d vs %d verts" % [cres2.stats.verts, cres.stats.verts])
	# Carve again on the reloaded textures: the loop really is repeatable.
	var p5 := {view = LumpEnc.VIEW_FRONT, cu = 0.44, cv = 0.60, r = 0.03, tc = 0.95, th = 0.2, op = LumpEnc.CARVE_SMOOTH, mat = 2}
	var s5 := LumpCarver.carve_pocket(cback, p5.view, p5.cu, p5.cv, p5.r, p5.tc, p5.th, p5.op, p5.mat)
	var shape3 := shape2.duplicate_shape()
	shape3.pockets.append(p5)
	_check("Third carve into slab texels (bitwise OR) still matches a full re-bake", cback.equals(LumpBaker.bake(shape3)),
		"%d texels changed, %d slab ORs" % [s5.changed, s5.slab_added])

	# ---------------------------------------------------------------- T6 sharp flag
	_h("## T6: Sharp-crease flag")
	_l("Crease vertices = where the sharp side view and another view are both within 0.5 texel of the surface (from the ground truth).")
	_l("The first run of this test measured every vertex on the side view's faces (mostly flat), and showed no difference either way.")
	_l("")
	var crease := func(res: Dictionary) -> PackedByteArray:
		var mask := PackedByteArray()
		for p in res.verts:
			var t := truth.terms_point(p)
			mask.append(1 if absf(t.y - t.w) < 0.5 * tx and (absf(t.x - t.w) < 0.5 * tx or absf(t.z - t.w) < 0.5 * tx) else 0)
		return mask
	var res_soft := LumpMesher.build(field, T * 2, {sharp = false})
	var sh_on := LumpMetrics.summarize(LumpMetrics.surface_distances(meshes[2].verts, truth, SAMPLES, tx * 0.25, crease.call(meshes[2])).d, tx)
	var sh_off := LumpMetrics.summarize(LumpMetrics.surface_distances(res_soft.verts, truth, SAMPLES, tx * 0.25, crease.call(res_soft)).d, tx)
	var a_on := LumpMesher.build(truth, T * 2)
	var a_off := LumpMesher.build(truth, T * 2, {sharp = false})
	var ash_on := LumpMetrics.summarize(LumpMetrics.surface_distances(a_on.verts, truth, SAMPLES, tx * 0.25, crease.call(a_on)).d, tx)
	var ash_off := LumpMetrics.summarize(LumpMetrics.surface_distances(a_off.verts, truth, SAMPLES, tx * 0.25, crease.call(a_off)).d, tx)
	_l("| 2× mesh, crease vertices | n | mean | p95 | max |")
	_l("|---|---|---|---|---|")
	_l("| from textures, flag honoured (QEF) | %d | %.3f | %.3f | %.3f |" % [sh_on.n, sh_on.mean, sh_on.p95, sh_on.max])
	_l("| from textures, flag ignored | %d | %.3f | %.3f | %.3f |" % [sh_off.n, sh_off.mean, sh_off.p95, sh_off.max])
	_l("| from exact analytic field, honoured | %d | %.3f | %.3f | %.3f |" % [ash_on.n, ash_on.mean, ash_on.p95, ash_on.max])
	_l("| from exact analytic field, ignored | %d | %.3f | %.3f | %.3f |" % [ash_off.n, ash_off.mean, ash_off.p95, ash_off.max])
	_l("")
	_check("Honouring the flag reduces crease error (p95)", sh_on.p95 < sh_off.p95, "%.3f vs %.3f" % [sh_on.p95, sh_off.p95])
	_check("Textures are not the crease bottleneck (within 0.05 texel of the exact field, mean)", absf(sh_on.mean - ash_on.mean) < 0.05, "%.3f vs %.3f" % [sh_on.mean, ash_on.mean])

	# ---------------------------------------------------------------- T7 slab vs span
	_h("## T7: Two carves in one column (SLAB bits vs SPAN only)")
	var span_only := LumpBaker.bake(shape, true)
	var res_span := LumpMesher.build(LumpField.new(span_only), T * 2)
	var region := func(res: Dictionary) -> PackedByteArray:
		var m := PackedByteArray()
		for p in res.verts:
			m.append(1 if Vector2(p.x - 0.60, p.y - 0.42).length() < 0.055 + 2.0 * tx else 0)
		return m
	var r_mix := LumpMetrics.summarize(LumpMetrics.surface_distances(meshes[2].verts, truth, SAMPLES, tx * 0.25, region.call(meshes[2])).d, tx)
	var r_span := LumpMetrics.summarize(LumpMetrics.surface_distances(res_span.verts, truth, SAMPLES, tx * 0.25, region.call(res_span)).d, tx)
	_l("Double-pocket region, 2× mesh: mixed SPAN/SLAB mean %.3f / p95 %.3f / max %.3f; SPAN only mean %.3f / p95 %.3f / max %.3f texel." % [r_mix.mean, r_mix.p95, r_mix.max, r_span.mean, r_span.p95, r_span.max])
	_check("Slab bits hold both pockets (region p95 < %.2f texel)" % REGION_P95, r_mix.p95 < REGION_P95, "%.3f" % r_mix.p95)
	_l("- SPAN-only keeps one pocket per column, so the region error is %.1f× larger." % (r_span.p95 / maxf(r_mix.p95, 1e-6)))

	# ---------------------------------------------------------------- T8 H curve
	_h("## T8: Squared H curve on the rounded front view")
	var shape_lin := shape.duplicate_shape()
	shape_lin.hsq[0] = 0
	var res_lin := LumpMesher.build(LumpField.new(LumpBaker.bake(shape_lin)), T * 2)
	var lin := LumpMetrics.summarize(LumpMetrics.surface_distances(res_lin.verts, truth, SAMPLES, tx * 0.25).d, tx)
	_l("2× mesh: squared curve mean %.3f / p95 %.3f / max %.3f; linear H mean %.3f / p95 %.3f / max %.3f texel." % [acc[2].mean, acc[2].p95, acc[2].max, lin.mean, lin.p95, lin.max])
	_check("Squared curve is at least as accurate (p95)", acc[2].p95 <= lin.p95, "%.3f vs %.3f" % [acc[2].p95, lin.p95])

	# ---------------------------------------------------------------- T9 narrow band
	_h("## T9: Narrow-band evaluation matches the full grid")
	var full := LumpMesher.build(field, T, {band = 1})
	var same: bool = full.stats.verts == meshes[1].stats.verts and full.stats.tris == meshes[1].stats.tris
	var maxd := 0.0
	if same:
		var a: PackedVector3Array = full.verts.duplicate()
		var b: PackedVector3Array = meshes[1].verts.duplicate()
		var key := func(p: Vector3) -> String: return "%.6f,%.6f,%.6f" % [p.x, p.y, p.z]
		var setb := {}
		for p in b:
			setb[key.call(p)] = true
		for p in a:
			if not setb.has(key.call(p)):
				same = false
				break
	_check("Identical mesh with and without the band", same, "%d/%d verts, %d/%d tris; full grid %.1fs vs band %.1fs" % [full.stats.verts, meshes[1].stats.verts, full.stats.tris, meshes[1].stats.tris, full.stats.ms_total / 1000.0, meshes[1].stats.ms_total / 1000.0])

	# ---------------------------------------------------------------- T10 export
	_h("## T10: Export for Godot")
	var mat := LumpMesher.gold_material()
	var ok_all := true
	var detail := []
	for mult in [1, 4]:
		var am := LumpMesher.to_array_mesh(meshes[mult], 1.0, mat)
		var path := OUT.path_join("lump_%dx.glb" % mult)
		var err := LumpExport.export_glb(am, path)
		var rs := LumpExport.reimport_stats(path)
		var ok: bool = err == OK and not rs.is_empty() and rs.tris == meshes[mult].stats.tris and rs.aabb.position.is_equal_approx(am.get_aabb().position) and rs.aabb.size.is_equal_approx(am.get_aabb().size)
		ok_all = ok_all and ok
		detail.append("%s: %d tris, %s" % [path.get_file(), rs.get("tris", -1), "ok" if ok else "MISMATCH"])
	var cam := LumpMesher.to_array_mesh(cres, 1.0, mat)
	LumpExport.export_glb(cam, OUT.path_join("lump_carved_2x.glb"))
	_check("GLB export re-imports with identical triangle count and bounds", ok_all, ", ".join(detail))

	_h("## Summary")
	_l("**%d passed, %d failed** in %.0f s." % [passes, fails, (Time.get_ticks_msec() - t_start) / 1000.0])
	var f := FileAccess.open(OUT.path_join("report.md"), FileAccess.WRITE)
	f.store_string("\n".join(lines) + "\n")
	f.close()
	print("\n".join(lines))
	quit(0 if fails == 0 else 1)


func _h(s: String) -> void:
	lines.append("")
	lines.append(s)
	lines.append("")


func _l(s: String) -> void:
	lines.append(s)


func _check(name: String, ok: bool, detail: String) -> void:
	if ok:
		passes += 1
	else:
		fails += 1
	lines.append("- **%s** %s%s" % ["PASS" if ok else "FAIL", name, (": " + detail) if detail != "" else ""])


func _v(p: Vector3) -> String:
	return "(%.2f, %.2f, %.2f)" % [p.x, p.y, p.z]


func _max3(v: Vector3) -> float:
	return maxf(v.x, maxf(v.y, v.z))
