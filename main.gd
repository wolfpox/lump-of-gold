extends Node3D
## Lump of Gold demo.
## The sculpt lives only in three 64x64 RGBA16 images (front, side, top), shown on the left.
## The 3D mesh is always rebuilt from those images.  Clicking the lump carves by writing new
## values into the image under the cursor; then the mesh is rebuilt.  Nothing edits the mesh.
##
## Controls: left-drag = orbit, wheel = zoom, left-click on the lump = carve.

const T := 64
const PREVIEW_PX := 192

var shape := LumpNugget.new(T)
var tex: LumpTextureSet
var undo_stack: Array[LumpTextureSet] = []
var mult := 1

var mesh_instance := MeshInstance3D.new()
var body := StaticBody3D.new()
var collision := CollisionShape3D.new()
var pivot := Node3D.new()
var camera := Camera3D.new()
var material := LumpMesher.gold_material()

var previews: Array[TextureRect] = []
var status := Label.new()
var brush_radius := HSlider.new()
var brush_depth := HSlider.new()
var res_buttons: Array[Button] = []

var _yaw := -0.6
var _pitch := -0.35
var _dist := 1.7
var _press_pos := Vector2.ZERO
var _dragging := false
var _busy := false
var _task := -1
var _task_result: Dictionary = {}
var _task_tex: LumpTextureSet
var _shot_path := ""
var _frames := 0


func _ready() -> void:
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--shot="):
			_shot_path = a.trim_prefix("--shot=")
	_build_world()
	_build_ui()
	tex = LumpBaker.bake(shape)
	_refresh_previews()
	_rebuild()


# ----------------------------------------------------------------------------- scene

func _build_world() -> void:
	var env := WorldEnvironment.new()
	var e := Environment.new()
	var sky := Sky.new()
	var sky_mat := ProceduralSkyMaterial.new()
	sky_mat.sky_top_color = Color(0.32, 0.36, 0.44)
	sky_mat.sky_horizon_color = Color(0.62, 0.6, 0.58)
	sky_mat.ground_bottom_color = Color(0.12, 0.11, 0.1)
	sky_mat.ground_horizon_color = Color(0.45, 0.42, 0.38)
	sky.sky_material = sky_mat
	e.background_mode = Environment.BG_SKY
	e.sky = sky
	e.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	e.reflected_light_source = Environment.REFLECTION_SOURCE_SKY
	e.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	env.environment = e
	add_child(env)

	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-50, -35, 0)
	sun.light_energy = 1.3
	sun.shadow_enabled = true
	add_child(sun)
	var fill := DirectionalLight3D.new()
	fill.rotation_degrees = Vector3(-20, 140, 0)
	fill.light_energy = 0.45
	add_child(fill)

	material.metallic = 0.7
	material.roughness = 0.35
	mesh_instance.material_override = material
	add_child(mesh_instance)
	body.add_child(collision)
	add_child(body)

	# Faint unit-cube outline: the volume the three images describe.
	var box := MeshInstance3D.new()
	var bm := ImmediateMesh.new()
	bm.surface_begin(Mesh.PRIMITIVE_LINES)
	for a in 3:
		for s1 in [-0.5, 0.5]:
			for s2 in [-0.5, 0.5]:
				var p0 := Vector3.ZERO
				var p1 := Vector3.ZERO
				p0[a] = -0.5; p1[a] = 0.5
				p0[(a + 1) % 3] = s1; p1[(a + 1) % 3] = s1
				p0[(a + 2) % 3] = s2; p1[(a + 2) % 3] = s2
				bm.surface_add_vertex(p0)
				bm.surface_add_vertex(p1)
	bm.surface_end()
	box.mesh = bm
	var lm := StandardMaterial3D.new()
	lm.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	lm.albedo_color = Color(1, 1, 1, 0.15)
	lm.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	box.material_override = lm
	add_child(box)

	add_child(pivot)
	pivot.add_child(camera)
	camera.fov = 40
	_update_camera()


func _build_ui() -> void:
	var layer := CanvasLayer.new()
	add_child(layer)
	var panel := PanelContainer.new()
	panel.position = Vector2(10, 10)
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.08, 0.08, 0.1, 0.88)
	sb.set_content_margin_all(10)
	sb.set_corner_radius_all(6)
	panel.add_theme_stylebox_override("panel", sb)
	layer.add_child(panel)
	var vb := VBoxContainer.new()
	vb.add_theme_constant_override("separation", 6)
	panel.add_child(vb)

	var title := Label.new()
	title.text = "Lump of Gold"
	title.add_theme_font_size_override("font_size", 20)
	vb.add_child(title)
	vb.add_child(_note("The lump is stored ONLY in these three 64×64 images.\nThe mesh on the right is rebuilt from them.\nClick the lump to carve: that writes into an image."))

	var grid := GridContainer.new()
	grid.columns = 3
	grid.add_theme_constant_override("h_separation", 8)
	vb.add_child(grid)
	for v in 3:
		var col := VBoxContainer.new()
		var lbl := Label.new()
		lbl.text = ["FRONT (looks along Z)", "SIDE (looks along X)", "TOP (looks along Y)"][v]
		lbl.add_theme_font_size_override("font_size", 11)
		col.add_child(lbl)
		var tr := TextureRect.new()
		tr.custom_minimum_size = Vector2(PREVIEW_PX, PREVIEW_PX)
		tr.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		tr.stretch_mode = TextureRect.STRETCH_SCALE
		tr.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
		col.add_child(tr)
		previews.append(tr)
		grid.add_child(col)
	vb.add_child(_note("Each image is drawn as its 4 channels:\n" +
		"  top-left  R = depth of the middle of the solid\n" +
		"  top-right G = thickness (warm) / distance outside the outline (blue)\n" +
		"  bottom-left  B = carves: orange = pocket, green = stacked pockets (bit flags), cyan = tunnel\n" +
		"  bottom-right A = which operation + material per texel (green = bit-flag mode)"))

	var brush := HBoxContainer.new()
	vb.add_child(brush)
	brush.add_child(_note("Brush radius"))
	brush_radius.min_value = 1.5; brush_radius.max_value = 8.0; brush_radius.step = 0.5; brush_radius.value = 3.5
	brush_radius.custom_minimum_size = Vector2(120, 0)
	brush.add_child(brush_radius)
	brush.add_child(_note("depth"))
	brush_depth.min_value = 1.0; brush_depth.max_value = 10.0; brush_depth.step = 0.5; brush_depth.value = 4.0
	brush_depth.custom_minimum_size = Vector2(120, 0)
	brush.add_child(brush_depth)

	var row := HBoxContainer.new()
	vb.add_child(row)
	row.add_child(_note("Mesh detail"))
	for m in [1, 2, 4]:
		var b := Button.new()
		b.text = "%d×" % m
		b.toggle_mode = true
		b.button_pressed = m == 1
		b.tooltip_text = "Rebuild the mesh at %d× the image resolution (%d³ grid). Same images." % [m, T * m]
		b.pressed.connect(_set_mult.bind(m))
		row.add_child(b)
		res_buttons.append(b)
	var undo := Button.new()
	undo.text = "Undo carve"
	undo.pressed.connect(_undo)
	row.add_child(undo)
	var reset := Button.new()
	reset.text = "Reset"
	reset.pressed.connect(_reset)
	row.add_child(reset)
	var export := Button.new()
	export.text = "Export .glb + images"
	export.pressed.connect(_export)
	row.add_child(export)

	status.add_theme_font_size_override("font_size", 12)
	vb.add_child(status)
	vb.add_child(_note("Left-drag: orbit   Wheel: zoom   Click lump: carve"))


func _note(t: String) -> Label:
	var l := Label.new()
	l.text = t
	l.add_theme_font_size_override("font_size", 12)
	l.add_theme_color_override("font_color", Color(0.8, 0.8, 0.8))
	return l


# ----------------------------------------------------------------------------- rebuild

func _rebuild() -> void:
	if _busy:
		return
	_busy = true
	status.text = "Rebuilding mesh from the images at %d× ..." % mult
	_task_tex = tex.duplicate_set()
	var n := T * mult
	if OS.has_feature("web"):
		# The browser build is single-threaded (GitHub Pages can't enable threads), so
		# build on the main thread after letting the "Rebuilding" text draw.
		await get_tree().process_frame
		await get_tree().process_frame
		_apply_result(LumpMesher.build(LumpField.new(_task_tex), n))
		return
	_task = WorkerThreadPool.add_task(func() -> void:
		_task_result = LumpMesher.build(LumpField.new(_task_tex), n))


func _apply_result(res: Dictionary) -> void:
	var mesh := LumpMesher.to_array_mesh(res, 1.0)
	mesh_instance.mesh = mesh
	collision.shape = mesh.create_trimesh_shape()
	var s: Dictionary = res.stats
	status.text = "Mesh %d× (%d³ grid): %d triangles, rebuilt in %.2f s from %d KB of images." % [
		mult, T * mult, s.tris, s.ms_total / 1000.0, 3 * T * T * 8 / 1024] + _carve_note
	_busy = false


func _process(_dt: float) -> void:
	if _task >= 0 and WorkerThreadPool.is_task_completed(_task):
		WorkerThreadPool.wait_for_task_completion(_task)
		_task = -1
		_apply_result(_task_result)
	if _shot_path != "":
		_frames += 1
		if _frames == 90 and not _busy:
			_demo_carve()
		if _frames > 200 and not _busy:
			get_viewport().get_texture().get_image().save_png(_shot_path)
			get_tree().quit()


var _carve_note := ""


func _set_mult(m: int) -> void:
	for i in res_buttons.size():
		res_buttons[i].button_pressed = [1, 2, 4][i] == m
	if m == mult:
		return
	mult = m
	_carve_note = ""
	_rebuild()


func _refresh_previews() -> void:
	for v in 3:
		previews[v].texture = ImageTexture.create_from_image(tex.make_preview(v))


# ----------------------------------------------------------------------------- carving

## Carve at a point on the surface (unit-cube coordinates), seen along direction dir.
func carve_at(p: Vector3, dir: Vector3) -> void:
	# Write into the image whose viewing axis is closest to the camera direction.
	var ad := dir.abs()
	var view := LumpEnc.VIEW_FRONT
	if ad.x >= ad.y and ad.x >= ad.z:
		view = LumpEnc.VIEW_SIDE
	elif ad.y >= ad.z:
		view = LumpEnc.VIEW_TOP
	var uvw := _to_view(view, p)
	var frame: int = LumpNugget.view_props(view).frame
	tex.decode()
	var rec := PackedFloat32Array()
	rec.resize(LumpField.CS)
	tex.fill_column(view, uvw.x, uvw.y, rec, 0)
	var fl := LumpEnc.frame_s0_len(frame, rec[0], rec[1], tex.texel)
	var tc := (uvw.z - fl.x) / fl.y
	var th := brush_depth.value * tex.texel / fl.y
	undo_stack.append(tex.duplicate_set())
	var st := LumpCarver.carve_pocket(tex, view, uvw.x, uvw.y, brush_radius.value * tex.texel,
		tc, th, LumpEnc.CARVE_SMOOTH, 2)
	_carve_note = "\nLast carve wrote into the %s image: %d texels changed%s." % [
		LumpEnc.VIEW_NAMES[view].to_upper(), st.changed,
		(", %d switched to stacked-pocket bit flags" % st.promoted) if st.promoted > 0 else ""]
	_refresh_previews()
	_rebuild()


static func _to_view(view: int, p: Vector3) -> Vector3:
	match view:
		LumpEnc.VIEW_FRONT: return Vector3(p.x, p.y, p.z)
		LumpEnc.VIEW_SIDE: return Vector3(p.z, p.y, p.x)
		_: return Vector3(p.x, p.z, p.y)


func _undo() -> void:
	if undo_stack.is_empty() or _busy:
		return
	tex = undo_stack.pop_back()
	_carve_note = "\nUndid last carve (restored the previous images)."
	_refresh_previews()
	_rebuild()


func _reset() -> void:
	if _busy:
		return
	undo_stack.clear()
	tex = LumpBaker.bake(shape)
	_carve_note = ""
	_refresh_previews()
	_rebuild()


func _export() -> void:
	if mesh_instance.mesh == null:
		return
	if OS.has_feature("web"):
		_export_web()
		return
	var dir := "res://out/demo"
	var err := LumpExport.export_glb(mesh_instance.mesh as ArrayMesh, dir.path_join("lump.glb"))
	tex.save_dds(dir)
	for v in 3:
		tex.make_preview(v).save_png(dir.path_join("preview_%s.png" % LumpEnc.VIEW_NAMES[v]))
	_carve_note = "\nExported %s to %s (lump.glb + lump_front/side/top.dds)." % ["OK" if err == OK else "FAILED", ProjectSettings.globalize_path(dir)]
	status.text = status.text.split("\n")[0] + _carve_note


## Browser: pack lump.glb and the three .dds images into one zip and download it.
func _export_web() -> void:
	var zip_path := "user://lump_export.zip"
	var zip := ZIPPacker.new()
	if zip.open(zip_path) != OK:
		status.text = status.text.split("\n")[0] + "\nExport failed: could not write the zip."
		return
	var glb := LumpExport.glb_buffer(mesh_instance.mesh as ArrayMesh)
	zip.start_file("lump.glb")
	zip.write_file(glb)
	zip.close_file()
	for v in 3:
		zip.start_file("lump_%s.dds" % LumpEnc.VIEW_NAMES[v])
		zip.write_file(tex.to_image(v).save_dds_to_buffer())
		zip.close_file()
	zip.close()
	JavaScriptBridge.download_buffer(FileAccess.get_file_as_bytes(zip_path), "lump_of_gold.zip", "application/zip")
	_carve_note = "\nDownloaded lump_of_gold.zip (lump.glb + lump_front/side/top.dds)."
	status.text = status.text.split("\n")[0] + _carve_note


func _demo_carve() -> void:
	# Screenshot mode: carve once into the front of the cap, as a click would.
	var from := Vector3(-0.05, 0.1, 1.5)
	var to := Vector3(-0.05, 0.1, -1.5)
	var hit := get_world_3d().direct_space_state.intersect_ray(PhysicsRayQueryParameters3D.create(from, to))
	if hit:
		carve_at(hit.position + Vector3(0.5, 0.5, 0.5), (to - from).normalized())


# ----------------------------------------------------------------------------- input

func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.button_index == MOUSE_BUTTON_LEFT:
			if mb.pressed:
				_press_pos = mb.position
				_dragging = false
			elif not _dragging and not _busy:
				_click(mb.position)
		elif mb.button_index == MOUSE_BUTTON_WHEEL_UP and mb.pressed:
			_dist = maxf(0.6, _dist * 0.9)
			_update_camera()
		elif mb.button_index == MOUSE_BUTTON_WHEEL_DOWN and mb.pressed:
			_dist = minf(5.0, _dist * 1.1)
			_update_camera()
	elif event is InputEventMouseMotion and (event as InputEventMouseMotion).button_mask & MOUSE_BUTTON_MASK_LEFT:
		var mm := event as InputEventMouseMotion
		if _dragging or mm.position.distance_to(_press_pos) > 4.0:
			_dragging = true
			_yaw -= mm.relative.x * 0.008
			_pitch = clampf(_pitch - mm.relative.y * 0.008, -1.5, 1.5)
			_update_camera()


func _click(pos: Vector2) -> void:
	var from := camera.project_ray_origin(pos)
	var dir := camera.project_ray_normal(pos)
	var hit := get_world_3d().direct_space_state.intersect_ray(PhysicsRayQueryParameters3D.create(from, from + dir * 10.0))
	if hit:
		carve_at(hit.position + Vector3(0.5, 0.5, 0.5), dir)


func _update_camera() -> void:
	pivot.rotation = Vector3(_pitch, _yaw, 0)
	camera.position = Vector3(-0.32, 0, _dist)
