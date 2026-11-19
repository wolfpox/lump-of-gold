extends Control
## Relief editor: draw a silhouette and line art flat, then build height on it with soft
## brushes. The silhouette is shared, so the back side automatically has the same outline;
## flip to the back to sculpt it as a second canvas.
##
## Left: tools.  Middle: flat canvas of the current side (paint here).  Right: 3D view.
## Keys: F flip side, G game view, [ ] brush size, Ctrl+Z undo, Ctrl+S save, X mirror symmetry,
##       1-9 pick tool.  3D view: left-drag orbit, right/middle-drag pan, wheel zoom.

const N := ReliefDoc.N
const Op := ReliefBrush.Op
const SAVE_NAME := "relief.lump"

const TOOLS := [
	{id = "raise", label = "Raise", op = Op.RAISE, layer = "sculpt", sign = 1.0},
	{id = "lower", label = "Lower / Carve", op = Op.RAISE, layer = "sculpt", sign = -1.0},
	{id = "smooth", label = "Smooth", op = Op.SMOOTH, layer = "sculpt", sign = 1.0},
	{id = "flatten", label = "Flatten", op = Op.FLATTEN, layer = "sculpt", sign = 1.0},
	{id = "reset", label = "Reset to base", op = Op.RESET, layer = "sculpt", sign = 1.0},
	{id = "sil_add", label = "Silhouette +", op = Op.PAINT, layer = "mask", sign = 1.0},
	{id = "sil_sub", label = "Silhouette -", op = Op.ERASE, layer = "mask", sign = 1.0},
	{id = "ink", label = "Line art", op = Op.PAINT, layer = "guide", sign = 1.0},
	{id = "ink_erase", label = "Line art eraser", op = Op.ERASE, layer = "guide", sign = 1.0},
]

var doc := ReliefDoc.new()
var brush := ReliefBrush.new()
var side := 0
var tool_idx := 0
var settings := {}  # tool id -> {size, hardness, opacity, flow, depth}
var spacing := 0.12
var symmetry := false
var use_pressure := true

var textures := {}  # layer key -> ImageTexture
var dirty := {}
var mat3d: Array[ShaderMaterial] = []
var mat2d := ShaderMaterial.new()

var canvas := ColorRect.new()
var overlay := Control.new()
var view3d := SubViewportContainer.new()
var sub := SubViewport.new()
var pivot := Node3D.new()
var camera := Camera3D.new()
var status := Label.new()
var side_buttons: Array[Button] = []
var tool_buttons: Array[Button] = []
var sliders := {}

var _stroking := false
var _stroke_key := ""
var _last_dab := Vector2.ZERO
var _carry := 0.0
var _queue: Array[Vector3] = []
var _cursor := Vector2(-1000, -1000)
var _undo: Array[Dictionary] = []
var _base_pending := false
var _base_task := -1
var _base_result: Array = []
var _base_started := 0
var _yaw := -0.45
var _pitch := -0.25
var _dist := 1.9
var _pan := Vector2.ZERO
var _drag := 0
# Game view: the low-poly mesh with full-res normals + AO, i.e. what an export will look like.
var game_view := false
var budget := 600
var ao_strength := 1.0
var game_mats: Array[ShaderMaterial] = []
var ao_mats: Array[ShaderMaterial] = []
var ao_vps: Array[SubViewport] = []
var sculpt_mis: Array[MeshInstance3D] = []
var game_mi := MeshInstance3D.new()
var wire_mi := MeshInstance3D.new()
var game_check: CheckBox
var wire_check: CheckBox
var _game_dirty := true
var _game_task := -1
var _game_result: Dictionary = {}
var _game_info := ""
var _last_change := 0
var _ao_dirty := [true, true]
var _ao_last := [0, 0]

var _shot_path := ""
var _frames := 0
var _settle := 0


func _ready() -> void:
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--shot="):
			_shot_path = a.trim_prefix("--shot=")
	for t in TOOLS:
		settings[t.id] = _default_settings(t.id)
	doc.make_default()
	doc.sd = ReliefDoc.compute_sd(doc.mask)
	doc.phi = ReliefDoc.compute_phi(doc.mask)
	for k in ["mask", "sculpt0", "sculpt1", "guide0", "guide1", "sd"]:
		textures[k] = _make_tex(doc.get_layer(k), N)
	textures["phi"] = _make_tex(doc.phi, ReliefDoc.PHI_N)
	_build_ui()
	_build_3d()
	_build_ao()
	_apply_all_uniforms()
	_select_tool(0)
	_set_side(0)
	get_window().files_dropped.connect(_on_files_dropped)


func _default_settings(id: String) -> Dictionary:
	match id:
		"raise", "lower":
			return {size = 40.0, hardness = 0.0, opacity = 1.0, flow = 0.2, depth = 0.03}
		"smooth":
			return {size = 40.0, hardness = 0.0, opacity = 1.0, flow = 0.5, depth = 0.0}
		"flatten", "reset":
			return {size = 40.0, hardness = 0.2, opacity = 1.0, flow = 0.3, depth = 0.0}
		"sil_add", "sil_sub":
			return {size = 24.0, hardness = 0.8, opacity = 1.0, flow = 1.0, depth = 0.0}
		"ink":
			return {size = 2.5, hardness = 0.5, opacity = 1.0, flow = 1.0, depth = 0.0}
	return {size = 12.0, hardness = 0.7, opacity = 1.0, flow = 1.0, depth = 0.0}


# ------------------------------------------------------------------------------ textures

func _make_tex(arr: PackedFloat32Array, n: int) -> ImageTexture:
	return ImageTexture.create_from_image(
		Image.create_from_data(n, n, false, Image.FORMAT_RF, arr.to_byte_array()))


func _upload(key: String) -> void:
	var arr: PackedFloat32Array = doc.phi if key == "phi" else doc.get_layer(key)
	var n := ReliefDoc.PHI_N if key == "phi" else N
	(textures[key] as ImageTexture).update(
		Image.create_from_data(n, n, false, Image.FORMAT_RF, arr.to_byte_array()))
	match key:
		"sculpt0":
			_height_changed(0)
		"sculpt1":
			_height_changed(1)
		"sd", "phi":
			_height_changed(-1)


## Something that shapes a side changed: re-bake its AO soon and rebuild the game mesh
## once editing pauses. s = -1 means both sides.
func _height_changed(s: int) -> void:
	for i in 2:
		if s == -1 or s == i:
			_ao_dirty[i] = true
	_game_dirty = true
	_last_change = Time.get_ticks_msec()


# ------------------------------------------------------------------------------ UI

func _build_ui() -> void:
	mat2d.shader = load("res://relief/relief2d.gdshader")
	set_anchors_preset(Control.PRESET_FULL_RECT)
	var bg := ColorRect.new()
	bg.color = Color(0.1, 0.1, 0.11)
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(bg)
	var row := HBoxContainer.new()
	row.set_anchors_preset(Control.PRESET_FULL_RECT)
	row.add_theme_constant_override("separation", 6)
	add_child(row)

	var scroll := ScrollContainer.new()
	scroll.custom_minimum_size.x = 290
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	row.add_child(scroll)
	var panel := VBoxContainer.new()
	panel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	panel.add_theme_constant_override("separation", 4)
	scroll.add_child(panel)

	_header(panel, "Side")
	var sides := HBoxContainer.new()
	panel.add_child(sides)
	var sg := ButtonGroup.new()
	for i in 2:
		var b := Button.new()
		b.text = ["Front", "Back"][i]
		b.toggle_mode = true
		b.button_group = sg
		b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		b.pressed.connect(_set_side.bind(i))
		sides.add_child(b)
		side_buttons.append(b)

	_header(panel, "Tool")
	var grid := GridContainer.new()
	grid.columns = 2
	panel.add_child(grid)
	var tg := ButtonGroup.new()
	for i in TOOLS.size():
		var b := Button.new()
		b.text = "%d %s" % [i + 1, TOOLS[i].label]
		b.toggle_mode = true
		b.button_group = tg
		b.alignment = HORIZONTAL_ALIGNMENT_LEFT
		b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		b.pressed.connect(_select_tool.bind(i))
		grid.add_child(b)
		tool_buttons.append(b)

	_header(panel, "Brush")
	_slider(panel, "size", "Size (px)", 1.0, 200.0, 0.5, _on_brush_slider.bind("size"))
	_slider(panel, "hardness", "Hardness", 0.0, 1.0, 0.01, _on_brush_slider.bind("hardness"))
	_slider(panel, "opacity", "Opacity (stroke max)", 0.0, 1.0, 0.01, _on_brush_slider.bind("opacity"))
	_slider(panel, "flow", "Flow (per dab)", 0.01, 1.0, 0.01, _on_brush_slider.bind("flow"))
	_slider(panel, "depth", "Depth", 0.001, 0.15, 0.001, _on_brush_slider.bind("depth"))
	_slider(panel, "spacing", "Spacing", 0.03, 1.0, 0.01, func(v: float) -> void: spacing = v)
	(sliders["spacing"] as HSlider).value = spacing
	_check(panel, "Mirror symmetry (X)", symmetry, func(on: bool) -> void: symmetry = on)
	_check(panel, "Pen pressure -> flow", use_pressure, func(on: bool) -> void: use_pressure = on)

	_header(panel, "Shape modifiers (this side)")
	_slider(panel, "inflate", "Inflate (round up from outline)", 0.0, 0.4, 0.002, _on_param.bind("inflate"))
	_slider(panel, "roundness", "Inflate profile (low = boxy)", 0.05, 2.0, 0.01, _on_param.bind("roundness"))
	_slider(panel, "plate", "Plate height", 0.0, 0.2, 0.001, _on_param.bind("plate"))
	_slider(panel, "edge_r", "Edge falloff width (px)", 0.0, 160.0, 0.5, _on_param.bind("edge_r"))
	var eh := HBoxContainer.new()
	panel.add_child(eh)
	var el := Label.new()
	el.text = "Edge shape"
	eh.add_child(el)
	var eo := OptionButton.new()
	for s in ["Round", "Soft S-curve", "Chamfer", "Cove"]:
		eo.add_item(s)
	eo.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	eo.item_selected.connect(func(i: int) -> void: _on_param(float(i), "edge_shape"))
	eh.add_child(eo)
	sliders["edge_shape"] = eo
	_slider(panel, "core", "Core thickness (both sides)", 0.0, 0.2, 0.001, _on_core)
	(sliders["core"] as HSlider).value = doc.core

	_header(panel, "Game view")
	game_check = _check(panel, "Game view: low poly + baked look (G)", false, _set_game_view)
	_slider(panel, "budget", "Triangle budget per side", 40.0, 4000.0, 10.0, func(v: float) -> void:
		budget = int(v)
		_game_dirty = true
		_last_change = Time.get_ticks_msec())
	_set_slider_quiet("budget", budget)
	wire_check = _check(panel, "Wireframe", false, func(on: bool) -> void:
		wire_mi.visible = on and game_view)
	_check(panel, "Flat shading (hide normal detail)", false, func(on: bool) -> void:
		for m in game_mats:
			m.set_shader_parameter("flat_normals", on))
	_slider(panel, "ao", "Ambient occlusion", 0.0, 1.5, 0.01, func(v: float) -> void:
		ao_strength = v
		_apply_all_uniforms())
	_set_slider_quiet("ao", ao_strength)
	_slider(panel, "ao_r", "AO reach (px)", 4.0, 160.0, 1.0, func(v: float) -> void:
		for m in ao_mats:
			m.set_shader_parameter("radius_texels", v)
		_height_changed(-1))
	_set_slider_quiet("ao_r", 40.0)

	_header(panel, "View")
	_slider(panel, "guide_op", "Line art opacity", 0.0, 1.0, 0.01,
		func(v: float) -> void: mat2d.set_shader_parameter("guide_opacity", v))
	(sliders["guide_op"] as HSlider).value = 0.85
	_check(panel, "Show line art on 3D", false, func(on: bool) -> void:
		for m in mat3d + game_mats:
			m.set_shader_parameter("guide_amount", 0.9 if on else 0.0))
	_check(panel, "Contour lines", false, func(on: bool) -> void:
		var st := 0.01 if on else 0.0
		mat2d.set_shader_parameter("contour_step", st)
		for m in mat3d + game_mats:
			m.set_shader_parameter("contour_step", st))
	_check(panel, "Gold material", false, _set_gold)
	_slider(panel, "shade", "Flat view shading boost", 0.5, 6.0, 0.1,
		func(v: float) -> void: mat2d.set_shader_parameter("shade_gain", v))
	(sliders["shade"] as HSlider).value = 1.5

	_header(panel, "File")
	var fr := HBoxContainer.new()
	panel.add_child(fr)
	for pair in [["Undo", _undo_last], ["Save", _save], ["Load", _load]]:
		var b := Button.new()
		b.text = pair[0]
		b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		b.pressed.connect(pair[1])
		fr.add_child(b)
	var fr2 := HBoxContainer.new()
	panel.add_child(fr2)
	for pair in [["Clear sculpt", _clear_sculpt], ["Clear line art", _clear_guide], ["Load line art…", _pick_guide]]:
		var b := Button.new()
		b.text = pair[0]
		b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		b.pressed.connect(pair[1])
		fr2.add_child(b)

	status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	status.custom_minimum_size.y = 60
	status.add_theme_font_size_override("font_size", 12)
	panel.add_child(status)

	# Flat canvas
	var arc := AspectRatioContainer.new()
	arc.ratio = 1.0
	arc.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	arc.size_flags_stretch_ratio = 1.0
	row.add_child(arc)
	canvas.material = mat2d
	canvas.mouse_filter = Control.MOUSE_FILTER_STOP
	canvas.mouse_default_cursor_shape = Control.CURSOR_CROSS
	canvas.gui_input.connect(_on_canvas_input)
	canvas.mouse_exited.connect(func() -> void:
		_cursor = Vector2(-1000, -1000)
		overlay.queue_redraw())
	arc.add_child(canvas)
	overlay.set_anchors_preset(Control.PRESET_FULL_RECT)
	overlay.mouse_filter = Control.MOUSE_FILTER_IGNORE
	overlay.draw.connect(_draw_overlay)
	canvas.add_child(overlay)

	# 3D view
	view3d.stretch = true
	view3d.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	view3d.size_flags_stretch_ratio = 1.05
	view3d.gui_input.connect(_on_view_input)
	row.add_child(view3d)
	sub.own_world_3d = true
	sub.msaa_3d = Viewport.MSAA_4X
	view3d.add_child(sub)


func _header(parent: Control, text: String) -> void:
	var l := Label.new()
	l.text = text
	l.add_theme_color_override("font_color", Color(0.95, 0.78, 0.4))
	parent.add_child(l)


func _slider(parent: Control, key: String, text: String, lo: float, hi: float, st: float,
		cb: Callable) -> void:
	var l := Label.new()
	l.add_theme_font_size_override("font_size", 12)
	parent.add_child(l)
	var s := HSlider.new()
	s.min_value = lo
	s.max_value = hi
	s.step = st
	s.value_changed.connect(func(v: float) -> void:
		l.text = "%s: %s" % [text, String.num(v, 3)]
		cb.call(v))
	s.changed.connect(func() -> void: l.text = "%s: %s" % [text, String.num(s.value, 3)])
	l.text = text
	parent.add_child(s)
	sliders[key] = s
	sliders[key + "_label"] = l
	s.set_meta("text", text)


func _set_slider_quiet(key: String, v: float) -> void:
	var s: HSlider = sliders[key]
	s.set_value_no_signal(v)
	(sliders[key + "_label"] as Label).text = "%s: %s" % [s.get_meta("text"), String.num(v, 3)]


func _check(parent: Control, text: String, on: bool, cb: Callable) -> CheckBox:
	var c := CheckBox.new()
	c.text = text
	c.button_pressed = on
	c.toggled.connect(cb)
	parent.add_child(c)
	return c


# ------------------------------------------------------------------------------ 3D

func _build_3d() -> void:
	var world := Node3D.new()
	sub.add_child(world)
	var env := WorldEnvironment.new()
	var e := Environment.new()
	var sky := Sky.new()
	var sm := ProceduralSkyMaterial.new()
	sm.sky_top_color = Color(0.3, 0.33, 0.4)
	sm.sky_horizon_color = Color(0.55, 0.54, 0.52)
	sm.ground_bottom_color = Color(0.1, 0.1, 0.1)
	sm.ground_horizon_color = Color(0.4, 0.38, 0.35)
	sky.sky_material = sm
	e.background_mode = Environment.BG_COLOR
	e.background_color = Color(0.13, 0.135, 0.15)
	e.sky = sky
	e.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	e.ambient_light_energy = 0.45
	e.reflected_light_source = Environment.REFLECTION_SOURCE_SKY
	e.tonemap_mode = Environment.TONE_MAPPER_AGX
	env.environment = e
	world.add_child(env)

	world.add_child(pivot)
	camera.position = Vector3(0, 0, _dist)
	camera.fov = 35
	camera.near = 0.02
	pivot.add_child(camera)
	# Lights ride with the camera (studio-style), so the form always reads with raking light.
	var key := DirectionalLight3D.new()
	key.rotation_degrees = Vector3(-35, -40, 0)
	key.light_energy = 0.85
	key.shadow_bias = 0.04
	key.shadow_normal_bias = 1.5
	key.shadow_enabled = true
	key.directional_shadow_mode = DirectionalLight3D.SHADOW_ORTHOGONAL
	key.directional_shadow_max_distance = 4.0
	pivot.add_child(key)
	var fill := DirectionalLight3D.new()
	fill.rotation_degrees = Vector3(-10, 130, 0)
	fill.light_energy = 0.25
	pivot.add_child(fill)

	var plane := PlaneMesh.new()
	plane.orientation = PlaneMesh.FACE_Z
	plane.size = Vector2(1, 1)
	plane.subdivide_width = N - 1
	plane.subdivide_depth = N - 1
	plane.custom_aabb = AABB(Vector3(-0.6, -0.6, -0.6), Vector3(1.2, 1.2, 1.2))
	var shader: Shader = load("res://relief/relief3d.gdshader")
	for i in 2:
		var m := ShaderMaterial.new()
		m.shader = shader
		m.set_shader_parameter("is_back", i == 1)
		mat3d.append(m)
		var mi := MeshInstance3D.new()
		mi.mesh = plane
		mi.material_override = m
		if i == 1:
			mi.rotation.y = PI
		world.add_child(mi)
		sculpt_mis.append(mi)
	var gshader: Shader = load("res://relief/relief_game.gdshader")
	for i in 2:
		var m := ShaderMaterial.new()
		m.shader = gshader
		m.set_shader_parameter("is_back", i == 1)
		game_mats.append(m)
	game_mi.visible = false
	world.add_child(game_mi)
	var wm := StandardMaterial3D.new()
	wm.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	wm.albedo_color = Color(0.1, 0.55, 0.95)
	wire_mi.material_override = wm
	wire_mi.visible = false
	world.add_child(wire_mi)
	_update_camera()


## One SubViewport per side that renders the AO bake shader into a 512x512 texture.
## It only re-renders when asked (UPDATE_ONCE), i.e. after the heights change.
func _build_ao() -> void:
	var shader: Shader = load("res://relief/relief_ao.gdshader")
	for i in 2:
		var vp := SubViewport.new()
		vp.size = Vector2i(N, N)
		vp.disable_3d = true
		vp.transparent_bg = false
		vp.render_target_update_mode = SubViewport.UPDATE_ONCE
		var m := ShaderMaterial.new()
		m.shader = shader
		var r := ColorRect.new()
		r.size = Vector2(N, N)
		r.material = m
		vp.add_child(r)
		add_child(vp)
		ao_vps.append(vp)
		ao_mats.append(m)


func _set_game_view(on: bool) -> void:
	if on and not game_view:
		_game_dirty = true
	game_view = on
	if game_check and game_check.button_pressed != on:
		game_check.set_pressed_no_signal(on)
	for mi in sculpt_mis:
		mi.visible = not on
	game_mi.visible = on and game_mi.mesh != null
	wire_mi.visible = on and wire_check.button_pressed and wire_mi.mesh != null
	_set_status()


func _update_camera() -> void:
	pivot.rotation = Vector3(_pitch, _yaw, 0)
	pivot.position = pivot.basis * Vector3(_pan.x, _pan.y, 0)
	camera.position = Vector3(0, 0, _dist)


func _set_gold(on: bool) -> void:
	for m in mat3d + game_mats:
		m.set_shader_parameter("albedo_col", Color(1.0, 0.77, 0.34) if on else Color(0.8, 0.76, 0.7))
		m.set_shader_parameter("metal", 1.0 if on else 0.0)
		m.set_shader_parameter("rough", 0.3 if on else 0.62)


func _on_view_input(ev: InputEvent) -> void:
	if ev is InputEventMouseButton:
		var mb := ev as InputEventMouseButton
		if mb.button_index == MOUSE_BUTTON_WHEEL_UP and mb.pressed:
			_dist = maxf(0.4, _dist * 0.9)
		elif mb.button_index == MOUSE_BUTTON_WHEEL_DOWN and mb.pressed:
			_dist = minf(6.0, _dist / 0.9)
		elif mb.button_index == MOUSE_BUTTON_LEFT:
			_drag = 1 if mb.pressed else 0
		elif mb.button_index in [MOUSE_BUTTON_RIGHT, MOUSE_BUTTON_MIDDLE]:
			_drag = 2 if mb.pressed else 0
		if mb.double_click:
			_pan = Vector2.ZERO
			_yaw = 0.0 if side == 0 else PI
			_pitch = 0.0
		_update_camera()
	elif ev is InputEventMouseMotion and _drag != 0:
		var mm := ev as InputEventMouseMotion
		if _drag == 1:
			_yaw -= mm.relative.x * 0.008
			_pitch = clampf(_pitch - mm.relative.y * 0.008, -1.5, 1.5)
		else:
			_pan += Vector2(-mm.relative.x, mm.relative.y) * 0.0012 * _dist
		_update_camera()


# ------------------------------------------------------------------------------ state

func _set_side(i: int) -> void:
	side = i
	side_buttons[i].button_pressed = true
	var p: Dictionary = doc.params[i]
	for k in ["inflate", "roundness", "plate", "edge_r"]:
		_set_slider_quiet(k, p[k])
	(sliders["edge_shape"] as OptionButton).select(int(p.edge_shape))
	_apply_2d_uniforms()
	# Turn the 3D view to face the side being edited, keeping the current tilt.
	var target := 0.0 if i == 0 else PI
	var front_facing := cos(_yaw) > 0.0
	if front_facing != (i == 0):
		_yaw = target - 0.45 * (1.0 if i == 0 else -1.0)
	_update_camera()
	_set_status()


func _select_tool(i: int) -> void:
	tool_idx = i
	tool_buttons[i].button_pressed = true
	var s: Dictionary = settings[TOOLS[i].id]
	for k in ["size", "hardness", "opacity", "flow", "depth"]:
		_set_slider_quiet(k, s[k])
	(sliders["depth"] as HSlider).editable = TOOLS[i].op == Op.RAISE
	overlay.queue_redraw()
	_set_status()


func _on_brush_slider(v: float, key: String) -> void:
	settings[TOOLS[tool_idx].id][key] = v
	overlay.queue_redraw()


func _on_param(v: float, key: String) -> void:
	doc.params[side][key] = v
	_apply_all_uniforms()
	_height_changed(side)


func _on_core(v: float) -> void:
	doc.core = v
	_apply_all_uniforms()
	_height_changed(-1)


func _apply_side_uniforms(m: ShaderMaterial, s: int) -> void:
	var p: Dictionary = doc.params[s]
	m.set_shader_parameter("sd_tex", textures["sd"])
	m.set_shader_parameter("phi_tex", textures["phi"])
	m.set_shader_parameter("sculpt_tex", textures["sculpt%d" % s])
	m.set_shader_parameter("guide_tex", textures["guide%d" % s])
	m.set_shader_parameter("core", doc.core)
	for k in ["plate", "inflate", "roundness", "edge_r"]:
		m.set_shader_parameter(k, float(p[k]))
	m.set_shader_parameter("edge_shape", int(p.edge_shape))
	m.set_shader_parameter("ao_strength", ao_strength)
	if ao_vps.size() == 2:
		m.set_shader_parameter("ao_tex", ao_vps[s].get_texture())


func _apply_2d_uniforms() -> void:
	_apply_side_uniforms(mat2d, side)
	mat2d.set_shader_parameter("mask_tex", textures["mask"])
	mat2d.set_shader_parameter("mirror", side == 1)


func _apply_all_uniforms() -> void:
	if mat3d.size() < 2:
		return
	for i in 2:
		_apply_side_uniforms(mat3d[i], i)
		_apply_side_uniforms(game_mats[i], i)
		if ao_mats.size() == 2:
			_apply_side_uniforms(ao_mats[i], i)
	_apply_2d_uniforms()


func _set_status(extra: String = "") -> void:
	var t: Dictionary = TOOLS[tool_idx]
	var s := "Editing %s. Tool: %s." % ["FRONT" if side == 0 else "BACK (mirrored, as seen from behind)", t.label]
	if _base_task != -1 or _base_pending:
		s += "\nUpdating silhouette fields…"
	if game_view:
		s += "\nGame view: " + ("building mesh…" if _game_task != -1 else _game_info)
	if extra != "":
		s += "\n" + extra
	status.text = s


# ------------------------------------------------------------------------------ painting

func _layer_key(t: Dictionary) -> String:
	match t.layer:
		"sculpt":
			return "sculpt%d" % side
		"guide":
			return "guide%d" % side
	return "mask"


func _canvas_to_px(pos: Vector2) -> Vector2:
	var uv := pos / canvas.size
	if side == 1:
		uv.x = 1.0 - uv.x
	return uv * N


func _on_canvas_input(ev: InputEvent) -> void:
	if ev is InputEventMouseButton:
		var mb := ev as InputEventMouseButton
		if mb.button_index == MOUSE_BUTTON_LEFT:
			if mb.pressed:
				_begin_stroke(mb.position, 1.0)
			else:
				_end_stroke()
		elif mb.pressed and mb.button_index in [MOUSE_BUTTON_WHEEL_UP, MOUSE_BUTTON_WHEEL_DOWN]:
			_resize_brush(1.1 if mb.button_index == MOUSE_BUTTON_WHEEL_UP else 1.0 / 1.1)
	elif ev is InputEventMouseMotion:
		var mm := ev as InputEventMouseMotion
		_cursor = mm.position
		overlay.queue_redraw()
		if _stroking:
			var pr := mm.pressure if (use_pressure and mm.pressure > 0.0) else 1.0
			_stroke_to(_canvas_to_px(mm.position), pr)


func _flush_queue() -> void:
	if _queue.is_empty():
		return
	for d in _queue:
		brush.dab(d.x, d.y, d.z)
	_queue.clear()
	doc.set_layer(_stroke_key, brush.buf)
	dirty[_stroke_key] = true
	if _stroke_key == "mask":
		_base_pending = true


func _begin_stroke(pos: Vector2, pressure: float) -> void:
	_flush_queue()
	var t: Dictionary = TOOLS[tool_idx]
	var s: Dictionary = settings[t.id]
	_stroke_key = _layer_key(t)
	_push_undo(_stroke_key)
	brush.radius = float(s.size) * 0.5
	brush.hardness = s.hardness
	brush.opacity = s.opacity
	brush.flow = s.flow
	brush.depth = float(s.depth) * float(t.sign)
	var p := _canvas_to_px(pos)
	brush.begin(doc.get_layer(_stroke_key), t.op, p)
	_stroking = true
	_last_dab = p
	_carry = 0.0
	_queue_dab(p, pressure)


func _stroke_to(p: Vector2, pressure: float) -> void:
	var step := maxf(0.5, brush.radius * 2.0 * spacing)
	var seg := p - _last_dab
	var length := seg.length()
	if length <= 0.0:
		return
	var dir := seg / length
	var travelled := step - _carry
	var start := _last_dab
	while travelled <= length:
		_queue_dab(start + dir * travelled, pressure)
		travelled += step
	_carry = length - (travelled - step)
	_last_dab = p


func _queue_dab(p: Vector2, pressure: float) -> void:
	_queue.append(Vector3(p.x, p.y, pressure))
	if symmetry:
		_queue.append(Vector3(N - p.x, p.y, pressure))


func _end_stroke() -> void:
	_stroking = false


func _resize_brush(f: float) -> void:
	var s: Dictionary = settings[TOOLS[tool_idx].id]
	s.size = clampf(float(s.size) * f, 1.0, 200.0)
	_set_slider_quiet("size", s.size)
	overlay.queue_redraw()


func _draw_overlay() -> void:
	if _cursor.x < -100.0:
		return
	var r := float(settings[TOOLS[tool_idx].id].size) * 0.5 / N * canvas.size.x
	var h := float(settings[TOOLS[tool_idx].id].hardness)
	overlay.draw_arc(_cursor, maxf(r, 1.5), 0, TAU, 64, Color(1, 1, 1, 0.8), 1.0, true)
	if h > 0.05 and r > 4.0:
		overlay.draw_arc(_cursor, r * h, 0, TAU, 48, Color(1, 1, 1, 0.35), 1.0, true)
	if symmetry:
		var mx := Vector2(canvas.size.x - _cursor.x, _cursor.y)
		overlay.draw_arc(mx, maxf(r, 1.5), 0, TAU, 64, Color(1, 1, 1, 0.35), 1.0, true)


func _process(_dt: float) -> void:
	# Apply queued dabs within a time budget so the UI never freezes on big brushes.
	if not _queue.is_empty():
		var t0 := Time.get_ticks_usec()
		while not _queue.is_empty() and Time.get_ticks_usec() - t0 < 14000:
			var d: Vector3 = _queue.pop_front()
			brush.dab(d.x, d.y, d.z)
		doc.set_layer(_stroke_key, brush.buf)
		dirty[_stroke_key] = true
		if _stroke_key == "mask":
			_base_pending = true
	for k in dirty.keys():
		_upload(k)
	dirty.clear()
	_poll_base()
	_poll_ao()
	_poll_game()
	if _shot_path != "":
		_frames += 1
		if _frames == 5:
			_demo_strokes()
			if "sil" in _shot_path:
				_flush_queue()
				_select_tool(5)
				_begin_stroke(canvas.size * Vector2(0.75, 0.3), 1.0)
				for i in 30:
					var t := i / 29.0
					_stroke_to(_canvas_to_px(canvas.size * Vector2(0.75 + 0.12 * t, 0.3 - 0.1 * t)), 1.0)
				_end_stroke()
			if "game" in _shot_path:
				_set_game_view(true)
				wire_check.button_pressed = "wire" in _shot_path
				if "flat" in _shot_path:
					for m in game_mats:
						m.set_shader_parameter("flat_normals", true)
			if "back" in _shot_path:
				doc.params[1].plate = 0.03
				doc.params[1].edge_r = 24.0
				_set_side(1)
				_apply_all_uniforms()
				_yaw = PI + 0.9
				_update_camera()
		var idle := _base_task == -1 and not _base_pending and _queue.is_empty() \
			and _game_task == -1 and not (game_view and _game_dirty)
		_settle = _settle + 1 if idle else 0
		if _frames > 40 and _settle > 5:
			get_viewport().get_texture().get_image().save_png(_shot_path)
			get_tree().quit()


# ------------------------------------------------------------------------------ AO + game mesh

func _poll_ao() -> void:
	var now := Time.get_ticks_msec()
	for i in 2:
		if _ao_dirty[i] and now - int(_ao_last[i]) > 80:
			_ao_dirty[i] = false
			_ao_last[i] = now
			ao_vps[i].render_target_update_mode = SubViewport.UPDATE_ONCE


func _poll_game() -> void:
	if _game_task != -1 and WorkerThreadPool.is_task_completed(_game_task):
		WorkerThreadPool.wait_for_task_completion(_game_task)
		_game_task = -1
		var res := _game_result
		game_mi.mesh = ReliefMesher.to_array_mesh(res)
		for i in 2:
			game_mi.set_surface_override_material(i, game_mats[i])
		wire_mi.mesh = ReliefMesher.to_wire_mesh(res)
		var f: int = res.sides[0].tris.size() / 3
		var b: int = res.sides[1].tris.size() / 3
		_game_info = "%d triangles (front %d, back %d), %d outline points, built in %d ms" % [
			f + b, f, b, res.outline_count, res.ms]
		_set_game_view(game_view)
	var quiet := Time.get_ticks_msec() - _last_change > 200
	if game_view and _game_dirty and _game_task == -1 and not _stroking and quiet \
			and _base_task == -1 and not _base_pending:
		_game_dirty = false
		var snap := {
			sd = doc.sd, phi = doc.phi, sculpt0 = doc.sculpt0, sculpt1 = doc.sculpt1,
			params = [doc.params[0].duplicate(), doc.params[1].duplicate()],
			core = doc.core, budget = budget,
		}
		_game_task = WorkerThreadPool.add_task(func() -> void:
			_game_result = ReliefMesher.build(snap))
		_set_status()


# ------------------------------------------------------------------------------ base fields

func _poll_base() -> void:
	if _base_task != -1 and WorkerThreadPool.is_task_completed(_base_task):
		WorkerThreadPool.wait_for_task_completion(_base_task)
		_base_task = -1
		doc.sd = _base_result[0]
		doc.phi = _base_result[1]
		_upload("sd")
		_upload("phi")
		_set_status("Silhouette fields updated in %d ms." % (Time.get_ticks_msec() - _base_started))
	if _base_pending and _base_task == -1:
		_base_pending = false
		_base_started = Time.get_ticks_msec()
		var m := doc.mask.duplicate()
		_base_task = WorkerThreadPool.add_task(func() -> void:
			_base_result = [ReliefDoc.compute_sd(m), ReliefDoc.compute_phi(m)])
		_set_status()


# ------------------------------------------------------------------------------ undo / file

func _push_undo(key: String) -> void:
	_undo.append({key = key, data = doc.get_layer(key).duplicate()})
	if _undo.size() > 40:
		_undo.pop_front()


func _undo_last() -> void:
	if _undo.is_empty() or _stroking:
		return
	_flush_queue()
	var u: Dictionary = _undo.pop_back()
	doc.set_layer(u.key, u.data)
	dirty[u.key] = true
	if u.key == "mask":
		_base_pending = true


func _clear_sculpt() -> void:
	var k := "sculpt%d" % side
	_push_undo(k)
	var a := PackedFloat32Array()
	a.resize(N * N)
	doc.set_layer(k, a)
	dirty[k] = true


func _clear_guide() -> void:
	var k := "guide%d" % side
	_push_undo(k)
	var a := PackedFloat32Array()
	a.resize(N * N)
	doc.set_layer(k, a)
	dirty[k] = true


func _save_path() -> String:
	if OS.has_feature("editor") or OS.has_feature("pc"):
		var dir := ProjectSettings.globalize_path("res://out")
		DirAccess.make_dir_recursive_absolute(dir)
		return dir.path_join(SAVE_NAME)
	return "user://" + SAVE_NAME


func _save() -> void:
	var p := _save_path()
	var err := doc.save(p)
	_set_status("Saved to %s" % p if err == OK else "Save failed (%s)" % error_string(err))


func _load() -> void:
	var p := _save_path()
	var err := doc.load_from(p)
	if err != OK:
		_set_status("Nothing loaded from %s (%s)" % [p, error_string(err)])
		return
	_undo.clear()
	for k in ["mask", "sculpt0", "sculpt1", "guide0", "guide1"]:
		dirty[k] = true
	_base_pending = true
	_set_slider_quiet("core", doc.core)
	_set_side(side)
	_apply_all_uniforms()
	_set_status("Loaded %s" % p)


func _pick_guide() -> void:
	var fd := FileDialog.new()
	fd.file_mode = FileDialog.FILE_MODE_OPEN_FILE
	fd.access = FileDialog.ACCESS_FILESYSTEM
	fd.filters = PackedStringArray(["*.png, *.jpg, *.jpeg, *.webp ; Images"])
	fd.use_native_dialog = true
	fd.file_selected.connect(func(path: String) -> void:
		_load_guide_image(path)
		fd.queue_free())
	fd.canceled.connect(fd.queue_free)
	add_child(fd)
	fd.popup_centered_ratio(0.6)


func _on_files_dropped(files: PackedStringArray) -> void:
	if files.size() > 0:
		_load_guide_image(files[0])


## Line art from an image: dark and opaque pixels become ink. Fitted into the square canvas.
func _load_guide_image(path: String) -> void:
	var img := Image.load_from_file(path)
	if img == null or img.is_empty():
		_set_status("Could not load %s" % path)
		return
	img.convert(Image.FORMAT_RGBA8)
	var sc := float(N) / maxf(img.get_width(), img.get_height())
	var w := maxi(1, int(img.get_width() * sc))
	var h := maxi(1, int(img.get_height() * sc))
	img.resize(w, h, Image.INTERPOLATE_LANCZOS)
	var k := "guide%d" % side
	_push_undo(k)
	var g := PackedFloat32Array()
	g.resize(N * N)
	var ox := (N - w) / 2
	var oy := (N - h) / 2
	for y in h:
		for x in w:
			var c := img.get_pixel(x, y)
			var ink := (1.0 - c.get_luminance()) * c.a
			var cx := ox + x
			if side == 1:
				cx = N - 1 - cx  # back canvas is mirrored; store so it reads correctly from behind
			g[(oy + y) * N + cx] = clampf(ink, 0.0, 1.0)
	doc.set_layer(k, g)
	dirty[k] = true
	_set_status("Loaded line art from %s" % path.get_file())


func _unhandled_key_input(ev: InputEvent) -> void:
	var k := ev as InputEventKey
	if k == null or not k.pressed or k.echo and k.keycode not in [KEY_BRACKETLEFT, KEY_BRACKETRIGHT]:
		return
	if k.ctrl_pressed and k.keycode == KEY_Z:
		_undo_last()
	elif k.ctrl_pressed and k.keycode == KEY_S:
		_save()
	elif k.keycode == KEY_F:
		_set_side(1 - side)
	elif k.keycode == KEY_G:
		_set_game_view(not game_view)
	elif k.keycode == KEY_X:
		symmetry = not symmetry
		overlay.queue_redraw()
		_set_status("Mirror symmetry %s" % ("on" if symmetry else "off"))
	elif k.keycode == KEY_BRACKETLEFT:
		_resize_brush(1.0 / 1.15)
	elif k.keycode == KEY_BRACKETRIGHT:
		_resize_brush(1.15)
	elif k.keycode >= KEY_1 and k.keycode <= KEY_9:
		var i := k.keycode - KEY_1
		if i < TOOLS.size():
			_select_tool(i)


# ------------------------------------------------------------------------------ screenshot

## Only used with --shot=path: paints a few strokes so the screenshot shows something.
func _demo_strokes() -> void:
	var c := canvas.size
	_select_tool(0)
	_begin_stroke(c * Vector2(0.35, 0.3), 1.0)
	for i in 40:
		var t := i / 39.0
		_stroke_to(_canvas_to_px(c * Vector2(0.35 + 0.3 * t, 0.3 + 0.05 * sin(t * PI))), 1.0)
	_end_stroke()
	_select_tool(1)
	_begin_stroke(c * Vector2(0.5, 0.6), 1.0)
	for i in 30:
		var t := i / 29.0
		_stroke_to(_canvas_to_px(c * Vector2(0.5 + 0.12 * cos(t * TAU), 0.6 + 0.12 * sin(t * TAU))), 1.0)
	_end_stroke()
