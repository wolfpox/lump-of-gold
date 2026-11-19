class_name LumpExport
extends RefCounted
## glTF binary export of a rebuilt mesh, plus a re-import check.

static func export_glb(mesh: ArrayMesh, path: String, node_name: String = "LumpOfGold") -> Error:
	var root := Node3D.new()
	root.name = node_name
	var mi := MeshInstance3D.new()
	mi.name = "Sculpt"
	mi.mesh = mesh
	root.add_child(mi)
	mi.owner = root
	var doc := GLTFDocument.new()
	var state := GLTFState.new()
	var err := doc.append_from_scene(root, state)
	if err == OK:
		DirAccess.make_dir_recursive_absolute(path.get_base_dir())
		err = doc.write_to_filesystem(state, path)
	root.free()
	return err


## The .glb as bytes (for downloads in the browser build).
static func glb_buffer(mesh: ArrayMesh, node_name: String = "LumpOfGold") -> PackedByteArray:
	var root := Node3D.new()
	root.name = node_name
	var mi := MeshInstance3D.new()
	mi.name = "Sculpt"
	mi.mesh = mesh
	root.add_child(mi)
	mi.owner = root
	var doc := GLTFDocument.new()
	var state := GLTFState.new()
	var out := PackedByteArray()
	if doc.append_from_scene(root, state) == OK:
		out = doc.generate_buffer(state)
	root.free()
	return out


## Loads a .glb back and returns {tris, aabb} of its meshes, or {} on failure.
static func reimport_stats(path: String) -> Dictionary:
	var doc := GLTFDocument.new()
	var state := GLTFState.new()
	if doc.append_from_file(path, state) != OK:
		return {}
	var scene := doc.generate_scene(state)
	if scene == null:
		return {}
	var tris := 0
	var box := AABB()
	var first := true
	var stack: Array[Node] = [scene]
	while not stack.is_empty():
		var node: Node = stack.pop_back()
		stack.append_array(node.get_children())
		if node is ImporterMeshInstance3D and node.mesh:
			var am: ArrayMesh = node.mesh.get_mesh()
			tris += am.get_faces().size() / 3
			box = am.get_aabb() if first else box.merge(am.get_aabb())
			first = false
		elif node is MeshInstance3D and node.mesh:
			tris += node.mesh.get_faces().size() / 3
			box = node.mesh.get_aabb() if first else box.merge(node.mesh.get_aabb())
			first = false
	scene.free()
	return {tris = tris, aabb = box}
