class_name LumpTextureSet
extends RefCounted
## Three RGBA16 view textures (front, side, top) that together define a sculpt.
## Layout of the channels: see LumpEnc.  This class stores the raw u16 channels, saves and
## loads them losslessly, and reconstructs field columns from them by decoding each corner
## texel and then interpolating (see fill_column).

var size: int
var texel: float
## raw[view][channel] = PackedInt32Array of size*size u16 values, index = iv * size + iu
## (iv grows with v, so images are flipped vertically on save to look upright).
var raw: Array = []

# Decoded per-texel caches, rebuilt by decode().  [view] -> packed array.
var _m: Array = []
var _h: Array = []
var _g: Array = []
var _hsq: Array = []
var _cop: Array = []
var _comb: Array = []
var _mode: Array = []
var _k: Array = []
var _sharp: Array = []
var _mat: Array = []
var _mc: Array = []
var _hc: Array = []
var _ct: Array = []
var _s0: Array = []
var _len: Array = []
var _mask: Array = []
var _dirty := true

var _ids := PackedInt32Array([0, 0, 0, 0])
var _ws := PackedFloat32Array([0.0, 0.0, 0.0, 0.0])


func _init(texture_size: int = 64) -> void:
	size = texture_size
	texel = 1.0 / size
	raw.clear()
	for v in 3:
		var chans: Array = []
		for c in 4:
			var a := PackedInt32Array()
			a.resize(size * size)
			chans.append(a)
		raw.append(chans)


func duplicate_set() -> LumpTextureSet:
	var t := LumpTextureSet.new(size)
	for v in 3:
		for c in 4:
			t.raw[v][c] = (raw[v][c] as PackedInt32Array).duplicate()
	t._dirty = true
	return t


func get_texel(view: int, iu: int, iv: int) -> PackedInt32Array:
	var i := iv * size + iu
	return PackedInt32Array([raw[view][0][i], raw[view][1][i], raw[view][2][i], raw[view][3][i]])


func set_texel(view: int, iu: int, iv: int, rgba: PackedInt32Array) -> void:
	var i := iv * size + iu
	for c in 4:
		var arr: PackedInt32Array = raw[view][c]
		arr[i] = rgba[c]
		raw[view][c] = arr
	_dirty = true


func mark_dirty() -> void:
	_dirty = true


func equals(other: LumpTextureSet) -> bool:
	if other.size != size:
		return false
	for v in 3:
		for c in 4:
			if raw[v][c] != other.raw[v][c]:
				return false
	return true


## Number of texels that differ from another set, per view.
func diff_count(other: LumpTextureSet) -> PackedInt32Array:
	var out := PackedInt32Array([0, 0, 0])
	for v in 3:
		for i in size * size:
			for c in 4:
				if raw[v][c][i] != other.raw[v][c][i]:
					out[v] += 1
					break
	return out


# --------------------------------------------------------------------------------- image io

func to_image(view: int) -> Image:
	var bytes := PackedByteArray()
	bytes.resize(size * size * 8)
	for iv in size:
		var row := size - 1 - iv
		for iu in size:
			var i := iv * size + iu
			var p := (row * size + iu) * 8
			for c in 4:
				bytes.encode_u16(p + c * 2, raw[view][c][i])
	return Image.create_from_data(size, size, false, Image.FORMAT_RGBA16, bytes)


func from_image(view: int, img: Image) -> void:
	assert(img.get_format() == Image.FORMAT_RGBA16, "Lump textures must be RGBA16")
	assert(img.get_width() == size and img.get_height() == size)
	var bytes := img.get_data()
	for c in 4:
		var arr: PackedInt32Array = raw[view][c]
		for iv in size:
			var row := size - 1 - iv
			for iu in size:
				arr[iv * size + iu] = bytes.decode_u16((row * size + iu) * 8 + c * 2)
		raw[view][c] = arr
	_dirty = true


func save_dds(dir: String, prefix: String = "lump") -> Error:
	DirAccess.make_dir_recursive_absolute(dir)
	for v in 3:
		var err := to_image(v).save_dds(dir.path_join("%s_%s.dds" % [prefix, LumpEnc.VIEW_NAMES[v]]))
		if err != OK:
			return err
	return OK


## Loads through Godot's resource loader (what a game or tool using these files would do) when
## use_resource_loader is set, otherwise straight from the bytes on disk.
static func load_dds(dir: String, prefix: String = "lump", use_resource_loader: bool = true) -> LumpTextureSet:
	var imgs: Array[Image] = []
	for v in 3:
		var path := dir.path_join("%s_%s.dds" % [prefix, LumpEnc.VIEW_NAMES[v]])
		var img: Image
		if use_resource_loader:
			var tex: Texture2D = ResourceLoader.load(path, "", ResourceLoader.CACHE_MODE_IGNORE)
			if tex == null:
				return null
			img = tex.get_image()
		else:
			img = Image.new()
			if img.load_dds_from_buffer(FileAccess.get_file_as_bytes(path)) != OK:
				return null
		if img.get_format() != Image.FORMAT_RGBA16:
			push_error("%s loaded as format %d, not RGBA16" % [path, img.get_format()])
			return null
		imgs.append(img)
	var t := LumpTextureSet.new(imgs[0].get_width())
	for v in 3:
		t.from_image(v, imgs[v])
	return t


## Human-readable 2x2 channel panel per view: M | H over carve (B) | ops/material (A).
func make_preview(view: int) -> Image:
	var s := size
	var img := Image.create_empty(s * 2, s * 2, false, Image.FORMAT_RGBA8)
	for iv in s:
		var row := s - 1 - iv
		for iu in s:
			var i := iv * s + iu
			var m := LumpEnc.d_unorm16(raw[view][0][i])
			var h := LumpEnc.d_snorm16(raw[view][1][i])
			var b: int = raw[view][2][i]
			var a: int = raw[view][3][i]
			var inside := h > 0.0
			# R: mid-depth, only meaningful inside the silhouette
			img.set_pixel(iu, row, Color(m, m, m) if inside else Color(0.08, 0.08, 0.1))
			# G: signed half-thickness, warm inside, cool outside
			var hv := clampf(absf(h) * 2.0, 0.0, 1.0)
			img.set_pixel(s + iu, row, Color(hv, hv * 0.7, 0.1) if inside else Color(0.05, 0.1, hv * 0.8 + 0.1))
			# B: carve payload, colour by how A says to read it
			var cop := LumpEnc.a_carve_op(a)
			var cb := Color(0.08, 0.08, 0.1)
			if cop == LumpEnc.CARVE_THROUGH:
				var rmp := LumpEnc.b_through_ramp(b)
				cb = Color(0.1, rmp, rmp) if rmp > 0.0 else Color(0.05, 0.12, 0.12)
			elif cop != LumpEnc.CARVE_NONE and LumpEnc.a_mode(a) == LumpEnc.MODE_SLAB:
				var pc := LumpEnc.popcount16(b) / 16.0
				cb = Color(0.2, 0.4 + 0.6 * pc, 0.2)
			elif cop != LumpEnc.CARVE_NONE:
				var th := LumpEnc.d_snorm8(b & 255)
				cb = Color(1.0, 0.5, 0.1) * clampf(th * 3.0, 0.0, 1.0) if th > 0.0 else Color(0.25, 0.12, 0.05)
			img.set_pixel(iu, s + row, cb)
			# A: hue per carve op, brightness per material, white dot when sharp
			var hue := [0.6, 0.05, 0.12, 0.5][cop] as float
			var mat := LumpEnc.a_mat(a)
			var ca := Color.from_hsv(hue, 0.6, 0.35 + mat * 0.09)
			if LumpEnc.a_sharp(a) == 1:
				ca = ca.lightened(0.25)
			if LumpEnc.a_mode(a) == LumpEnc.MODE_SLAB:
				ca = Color(0.3, 1.0, 0.3)
			img.set_pixel(s + iu, s + row, ca)
	return img


# ------------------------------------------------------------------------- reconstruction

func decode() -> void:
	if not _dirty:
		return
	var n := size * size
	_m.clear(); _h.clear(); _g.clear(); _hsq.clear(); _cop.clear(); _comb.clear(); _mode.clear(); _k.clear()
	_sharp.clear(); _mat.clear(); _mc.clear(); _hc.clear(); _ct.clear()
	_s0.clear(); _len.clear(); _mask.clear()
	for v in 3:
		var R: PackedInt32Array = raw[v][0]
		var G: PackedInt32Array = raw[v][1]
		var B: PackedInt32Array = raw[v][2]
		var A: PackedInt32Array = raw[v][3]
		var m := PackedFloat32Array(); m.resize(n)
		var h := PackedFloat32Array(); h.resize(n)
		var g := PackedFloat32Array(); g.resize(n)
		var hsq := PackedFloat32Array(); hsq.resize(n)
		var cop := PackedInt32Array(); cop.resize(n)
		var comb := PackedInt32Array(); comb.resize(n)
		var mode := PackedInt32Array(); mode.resize(n)
		var k := PackedFloat32Array(); k.resize(n)
		var sharp := PackedFloat32Array(); sharp.resize(n)
		var mat := PackedInt32Array(); mat.resize(n)
		var mc := PackedFloat32Array(); mc.resize(n)
		var hc := PackedFloat32Array(); hc.resize(n)
		var ct := PackedFloat32Array(); ct.resize(n)
		var s0 := PackedFloat32Array(); s0.resize(n)
		var ln := PackedFloat32Array(); ln.resize(n)
		var mask := PackedInt32Array(); mask.resize(n)
		for i in n:
			var a := A[i]
			var b := B[i]
			m[i] = LumpEnc.d_unorm16(R[i])
			g[i] = LumpEnc.d_snorm16(G[i])
			hsq[i] = LumpEnc.a_hsq(a)
			h[i] = LumpEnc.decode_h(g[i], LumpEnc.a_hsq(a))
			cop[i] = LumpEnc.a_carve_op(a)
			comb[i] = LumpEnc.a_comb_op(a)
			mode[i] = LumpEnc.a_mode(a)
			k[i] = LumpEnc.BLEND_TEXELS[LumpEnc.a_blend(a)] * texel
			sharp[i] = LumpEnc.a_sharp(a)
			mat[i] = LumpEnc.a_mat(a)
			var frame := LumpEnc.a_frame(a)
			var fl := LumpEnc.frame_s0_len(frame, m[i], h[i], texel)
			s0[i] = fl.x
			ln[i] = fl.y
			ct[i] = 1.0
			mc[i] = 0.5
			hc[i] = -1.0
			if cop[i] == LumpEnc.CARVE_THROUGH:
				ct[i] = -LumpEnc.b_through_ramp(b) * LumpEnc.THROUGH_TEXELS * texel
			elif mode[i] == LumpEnc.MODE_SPAN:
				mc[i] = fl.x + LumpEnc.b_span_tc(b) * fl.y
				hc[i] = LumpEnc.b_span_th(b, frame) * fl.y
			else:
				mask[i] = b
		_m.append(m); _h.append(h); _g.append(g); _hsq.append(hsq); _cop.append(cop); _comb.append(comb); _mode.append(mode)
		_k.append(k); _sharp.append(sharp); _mat.append(mat); _mc.append(mc); _hc.append(hc)
		_ct.append(ct); _s0.append(s0); _len.append(ln); _mask.append(mask)
	_dirty = false


## Writes one column record (layout in LumpField) for view at (u, v) into r at offset o.
func fill_column(view: int, u: float, v: float, r: PackedFloat32Array, o: int) -> void:
	var s := size
	var tu := u * s - 0.5
	var tv := v * s - 0.5
	var fi := floorf(tu)
	var fj := floorf(tv)
	var fx := tu - fi
	var fy := tv - fj
	var i0 := clampi(int(fi), 0, s - 1)
	var i1 := clampi(int(fi) + 1, 0, s - 1)
	var j0 := clampi(int(fj), 0, s - 1)
	var j1 := clampi(int(fj) + 1, 0, s - 1)
	_ids[0] = j0 * s + i0
	_ids[1] = j0 * s + i1
	_ids[2] = j1 * s + i0
	_ids[3] = j1 * s + i1
	_ws[0] = (1.0 - fx) * (1.0 - fy)
	_ws[1] = fx * (1.0 - fy)
	_ws[2] = (1.0 - fx) * fy
	_ws[3] = fx * fy

	var m: PackedFloat32Array = _m[view]
	var g: PackedFloat32Array = _g[view]
	var hsq: PackedFloat32Array = _hsq[view]
	var cop: PackedInt32Array = _cop[view]
	var comb: PackedInt32Array = _comb[view]
	var mode: PackedInt32Array = _mode[view]
	var kk: PackedFloat32Array = _k[view]
	var sharp: PackedFloat32Array = _sharp[view]
	var mat: PackedInt32Array = _mat[view]
	var mc: PackedFloat32Array = _mc[view]
	var hc: PackedFloat32Array = _hc[view]
	var ct: PackedFloat32Array = _ct[view]
	var s0: PackedFloat32Array = _s0[view]
	var ln: PackedFloat32Array = _len[view]
	var mask: PackedInt32Array = _mask[view]

	var vm := 0.0
	var vg := 0.0
	var vhsq := 0.0
	var vk := 0.0
	var vsharp := 0.0
	var span_w := 0.0
	var slab_w := 0.0
	var thr_w := 0.0
	var vmc := 0.0
	var vhc := 0.0
	var vct := 0.0
	for q in 9:
		r[o + 5 + q] = 0.0  # op weights 5..13 (k at 9 overwritten below)
	var best := 0
	for c in 4:
		var id := _ids[c]
		var w := _ws[c]
		if w > _ws[best]:
			best = c
		vm += w * m[id]
		vg += w * g[id]
		vhsq += w * hsq[id]
		vk += w * kk[id]
		vsharp += w * sharp[id]
		var co := cop[id]
		r[o + 5 + co] += w
		r[o + 10 + comb[id]] += w
		r[o + 15 + c] = 0.0
		r[o + 19 + c] = s0[id]
		r[o + 23 + c] = ln[id]
		r[o + 27 + c] = mask[id]
		if co == LumpEnc.CARVE_THROUGH:
			thr_w += w
			vct += w * ct[id]
		elif mode[id] == LumpEnc.MODE_SPAN:
			span_w += w
			vmc += w * mc[id]
			vhc += w * hc[id]
		else:
			slab_w += w
			r[o + 15 + c] = w
	r[o] = vm
	# Interpolate the stored value, then decode: that is what makes the H curve useful.
	r[o + 1] = LumpEnc.decode_h(vg, 1 if vhsq >= 0.5 else 0)
	r[o + 2] = vmc / span_w if span_w > 0.0 else 0.5
	r[o + 3] = vhc / span_w if span_w > 0.0 else -1.0
	r[o + 4] = vct / thr_w if thr_w > 0.0 else 1.0
	r[o + 9] = vk
	var cw := span_w + slab_w
	r[o + 14] = slab_w / cw if cw > 0.0 else 0.0
	if slab_w > 0.0:
		for c in 4:
			r[o + 15 + c] /= slab_w
	r[o + 31] = vsharp
	r[o + 32] = mat[_ids[best]]
	r[o + 33] = 0.0
