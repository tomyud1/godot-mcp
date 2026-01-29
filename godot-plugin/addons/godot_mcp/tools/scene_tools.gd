@tool
extends Node
class_name SceneTools
## Scene operation tools for MCP.
## Handles: create_scene, read_scene, add_node, remove_node, modify_node_property,
##          rename_node, move_node, attach_script, detach_script, set_collision_shape,
##          set_sprite_texture

var _editor_plugin: EditorPlugin = null

func set_editor_plugin(plugin: EditorPlugin) -> void:
	_editor_plugin = plugin

# =============================================================================
# Shared helpers
# =============================================================================
func _refresh_and_reload(scene_path: String) -> void:
	_refresh_filesystem()
	_reload_scene_in_editor(scene_path)

func _refresh_filesystem() -> void:
	if _editor_plugin:
		_editor_plugin.get_editor_interface().get_resource_filesystem().scan()

func _reload_scene_in_editor(scene_path: String) -> void:
	if not _editor_plugin:
		return
	var ei = _editor_plugin.get_editor_interface()
	var edited = ei.get_edited_scene_root()
	if edited and edited.scene_file_path == scene_path:
		ei.reload_scene_from_path(scene_path)

func _ensure_res_path(path: String) -> String:
	if not path.begins_with("res://"):
		return "res://" + path
	return path

func _load_scene(scene_path: String) -> Array:
	"""Returns [scene_root, error_dict]. If error_dict is not empty, scene_root is null."""
	if not FileAccess.file_exists(scene_path):
		return [null, {"ok": false, "error": "Scene does not exist: " + scene_path}]

	var packed = load(scene_path) as PackedScene
	if not packed:
		return [null, {"ok": false, "error": "Failed to load scene: " + scene_path}]

	var root = packed.instantiate()
	if not root:
		return [null, {"ok": false, "error": "Failed to instantiate scene"}]

	return [root, {}]

func _save_scene(scene_root: Node, scene_path: String) -> Dictionary:
	"""Pack and save a scene. Returns error dict or empty on success."""
	var packed = PackedScene.new()
	var pack_result = packed.pack(scene_root)
	if pack_result != OK:
		scene_root.queue_free()
		return {"ok": false, "error": "Failed to pack scene: " + str(pack_result)}

	var save_result = ResourceSaver.save(packed, scene_path)
	scene_root.queue_free()

	if save_result != OK:
		return {"ok": false, "error": "Failed to save scene: " + str(save_result)}

	_refresh_and_reload(scene_path)
	return {}

func _find_node(scene_root: Node, node_path: String) -> Node:
	if node_path == "." or node_path.is_empty():
		return scene_root
	return scene_root.get_node_or_null(node_path)

func _parse_value(value):
	"""Convert dictionary-encoded types to Godot types."""
	if typeof(value) == TYPE_DICTIONARY and value.has("type"):
		match value["type"]:
			"Vector2": return Vector2(value.get("x", 0), value.get("y", 0))
			"Vector3": return Vector3(value.get("x", 0), value.get("y", 0), value.get("z", 0))
			"Color": return Color(value.get("r", 1), value.get("g", 1), value.get("b", 1), value.get("a", 1))
			"Vector2i": return Vector2i(value.get("x", 0), value.get("y", 0))
			"Vector3i": return Vector3i(value.get("x", 0), value.get("y", 0), value.get("z", 0))
			"Rect2": return Rect2(value.get("x", 0), value.get("y", 0), value.get("width", 0), value.get("height", 0))
	return value

func _set_node_properties(node: Node, properties: Dictionary) -> void:
	for prop_name in properties:
		var prop_value = _parse_value(properties[prop_name])
		node.set(prop_name, prop_value)

func _serialize_value(value) -> Variant:
	match typeof(value):
		TYPE_VECTOR2: return {"type": "Vector2", "x": value.x, "y": value.y}
		TYPE_VECTOR3: return {"type": "Vector3", "x": value.x, "y": value.y, "z": value.z}
		TYPE_COLOR: return {"type": "Color", "r": value.r, "g": value.g, "b": value.b, "a": value.a}
		TYPE_VECTOR2I: return {"type": "Vector2i", "x": value.x, "y": value.y}
		TYPE_VECTOR3I: return {"type": "Vector3i", "x": value.x, "y": value.y, "z": value.z}
		TYPE_RECT2: return {"type": "Rect2", "x": value.position.x, "y": value.position.y, "width": value.size.x, "height": value.size.y}
		TYPE_OBJECT:
			if value and value is Resource and value.resource_path:
				return {"type": "Resource", "path": value.resource_path}
			return null
		_: return value

# =============================================================================
# create_scene
# =============================================================================
func create_scene(args: Dictionary) -> Dictionary:
	var scene_path: String = _ensure_res_path(str(args.get("scene_path", "")))
	var root_node_name: String = str(args.get("root_node_name", "Node"))
	var root_node_type: String = str(args.get("root_node_type", ""))
	var nodes: Array = args.get("nodes", [])
	var attach_script_path: String = str(args.get("attach_script", ""))

	if scene_path.strip_edges() == "res://":
		return {"ok": false, "error": "Missing 'scene_path' parameter"}
	if root_node_type.strip_edges().is_empty():
		return {"ok": false, "error": "Missing 'root_node_type' parameter"}
	if not scene_path.ends_with(".tscn"):
		scene_path += ".tscn"
	if FileAccess.file_exists(scene_path):
		return {"ok": false, "error": "Scene already exists: " + scene_path}
	if not ClassDB.class_exists(root_node_type):
		return {"ok": false, "error": "Invalid root node type: " + root_node_type}

	# Ensure parent directory
	var dir_path := scene_path.get_base_dir()
	if not DirAccess.dir_exists_absolute(dir_path):
		DirAccess.make_dir_recursive_absolute(dir_path)

	var root: Node = ClassDB.instantiate(root_node_type) as Node
	if not root:
		return {"ok": false, "error": "Failed to create root node of type: " + root_node_type}
	root.name = root_node_name

	if not attach_script_path.is_empty():
		var script_res = load(attach_script_path)
		if script_res:
			root.set_script(script_res)

	var node_count := 0
	for node_data in nodes:
		if typeof(node_data) == TYPE_DICTIONARY:
			var created = _create_node_recursive(node_data, root, root)
			if created:
				node_count += _count_nodes(created)

	var err := _save_scene(root, scene_path)
	if not err.is_empty():
		return err

	return {"ok": true, "path": scene_path, "root_type": root_node_type, "child_count": node_count,
		"message": "Scene created at " + scene_path}

func _create_node_recursive(data: Dictionary, parent: Node, owner: Node) -> Node:
	var n_name: String = str(data.get("name", "Node"))
	var n_type: String = str(data.get("type", "Node"))
	var n_script: String = str(data.get("script", ""))
	var props: Dictionary = data.get("properties", {})
	var children: Array = data.get("children", [])

	if not ClassDB.class_exists(n_type):
		return null
	var node: Node = ClassDB.instantiate(n_type) as Node
	if not node:
		return null

	node.name = n_name
	_set_node_properties(node, props)

	if not n_script.is_empty():
		var s = load(n_script)
		if s:
			node.set_script(s)

	parent.add_child(node)
	node.owner = owner

	for child_data in children:
		if typeof(child_data) == TYPE_DICTIONARY:
			_create_node_recursive(child_data, node, owner)
	return node

func _count_nodes(node: Node) -> int:
	var count := 1
	for child in node.get_children():
		count += _count_nodes(child)
	return count

# =============================================================================
# read_scene
# =============================================================================
func read_scene(args: Dictionary) -> Dictionary:
	var scene_path: String = _ensure_res_path(str(args.get("scene_path", "")))
	var include_properties: bool = args.get("include_properties", false)

	if scene_path.strip_edges() == "res://":
		return {"ok": false, "error": "Missing 'scene_path' parameter"}

	var result := _load_scene(scene_path)
	if not result[1].is_empty():
		return result[1]

	var root: Node = result[0]
	var structure = _build_node_structure(root, include_properties)
	root.queue_free()

	return {"ok": true, "scene_path": scene_path, "root": structure}

func _build_node_structure(node: Node, include_props: bool, path: String = ".") -> Dictionary:
	var data := {"name": str(node.name), "type": node.get_class(), "path": path, "children": []}
	var script = node.get_script()
	if script:
		data["script"] = script.resource_path

	if include_props:
		var props := {}
		for prop_name in ["position", "rotation", "scale", "size", "offset", "visible",
				"modulate", "z_index", "text", "collision_layer", "collision_mask", "mass"]:
			var val = node.get(prop_name)
			if val != null:
				props[prop_name] = _serialize_value(val)
		if not props.is_empty():
			data["properties"] = props

	for child in node.get_children():
		var child_path = child.name if path == "." else path + "/" + child.name
		data["children"].append(_build_node_structure(child, include_props, child_path))
	return data

# =============================================================================
# add_node
# =============================================================================
func add_node(args: Dictionary) -> Dictionary:
	var scene_path: String = _ensure_res_path(str(args.get("scene_path", "")))
	var node_name: String = str(args.get("node_name", ""))
	var node_type: String = str(args.get("node_type", "Node"))
	var parent_path: String = str(args.get("parent_path", "."))
	var properties: Dictionary = args.get("properties", {})

	if scene_path.strip_edges() == "res://":
		return {"ok": false, "error": "Missing 'scene_path'"}
	if node_name.strip_edges().is_empty():
		return {"ok": false, "error": "Missing 'node_name'"}
	if not ClassDB.class_exists(node_type):
		return {"ok": false, "error": "Invalid node type: " + node_type}

	var result := _load_scene(scene_path)
	if not result[1].is_empty():
		return result[1]

	var root: Node = result[0]
	var parent = _find_node(root, parent_path)
	if not parent:
		root.queue_free()
		return {"ok": false, "error": "Parent node not found: " + parent_path}

	var new_node: Node = ClassDB.instantiate(node_type) as Node
	if not new_node:
		root.queue_free()
		return {"ok": false, "error": "Failed to create node of type: " + node_type}

	new_node.name = node_name
	_set_node_properties(new_node, properties)
	parent.add_child(new_node)
	new_node.owner = root

	var err := _save_scene(root, scene_path)
	if not err.is_empty():
		return err

	return {"ok": true, "scene_path": scene_path, "node_name": node_name, "node_type": node_type,
		"message": "Added %s (%s) to scene" % [node_name, node_type]}

# =============================================================================
# remove_node
# =============================================================================
func remove_node(args: Dictionary) -> Dictionary:
	var scene_path: String = _ensure_res_path(str(args.get("scene_path", "")))
	var node_path: String = str(args.get("node_path", ""))

	if scene_path.strip_edges() == "res://":
		return {"ok": false, "error": "Missing 'scene_path'"}
	if node_path.strip_edges().is_empty() or node_path == ".":
		return {"ok": false, "error": "Cannot remove root node"}

	var result := _load_scene(scene_path)
	if not result[1].is_empty():
		return result[1]

	var root: Node = result[0]
	var target = root.get_node_or_null(node_path)
	if not target:
		root.queue_free()
		return {"ok": false, "error": "Node not found: " + node_path}

	var n_name = target.name
	var n_type = target.get_class()
	target.get_parent().remove_child(target)
	target.queue_free()

	var err := _save_scene(root, scene_path)
	if not err.is_empty():
		return err

	return {"ok": true, "scene_path": scene_path, "removed_node": node_path,
		"message": "Removed %s (%s)" % [n_name, n_type]}

# =============================================================================
# modify_node_property
# =============================================================================
func modify_node_property(args: Dictionary) -> Dictionary:
	var scene_path: String = _ensure_res_path(str(args.get("scene_path", "")))
	var node_path: String = str(args.get("node_path", "."))
	var property_name: String = str(args.get("property_name", ""))
	var value = args.get("value")

	if scene_path.strip_edges() == "res://":
		return {"ok": false, "error": "Missing 'scene_path'"}
	if property_name.strip_edges().is_empty():
		return {"ok": false, "error": "Missing 'property_name'"}
	if value == null:
		return {"ok": false, "error": "Missing 'value'"}

	var result := _load_scene(scene_path)
	if not result[1].is_empty():
		return result[1]

	var root: Node = result[0]
	var target = _find_node(root, node_path)
	if not target:
		root.queue_free()
		return {"ok": false, "error": "Node not found: " + node_path}

	# Check property exists
	var prop_exists := false
	for prop in target.get_property_list():
		if prop["name"] == property_name:
			prop_exists = true
			break
	if not prop_exists:
		var node_type = target.get_class()
		root.queue_free()
		return {"ok": false, "error": "Property '%s' not found on %s (%s). Use get_node_properties to discover available properties." % [property_name, node_path, node_type]}

	var parsed = _parse_value(value)
	var old_value = target.get(property_name)

	# Validate resource type compatibility
	if old_value is Resource and not (parsed is Resource):
		root.queue_free()
		return {"ok": false, "error": "Property '%s' expects a Resource. Use specialized tools (set_collision_shape, set_sprite_texture) instead." % property_name}

	target.set(property_name, parsed)

	var err := _save_scene(root, scene_path)
	if not err.is_empty():
		return err

	return {"ok": true, "scene_path": scene_path, "node_path": node_path,
		"property_name": property_name, "old_value": str(old_value), "new_value": str(parsed),
		"message": "Set %s.%s = %s" % [node_path, property_name, str(parsed)]}

# =============================================================================
# rename_node
# =============================================================================
func rename_node(args: Dictionary) -> Dictionary:
	var scene_path: String = _ensure_res_path(str(args.get("scene_path", "")))
	var node_path: String = str(args.get("node_path", ""))
	var new_name: String = str(args.get("new_name", ""))

	if scene_path.strip_edges() == "res://":
		return {"ok": false, "error": "Missing 'scene_path'"}
	if node_path.strip_edges().is_empty():
		return {"ok": false, "error": "Missing 'node_path'"}
	if new_name.strip_edges().is_empty():
		return {"ok": false, "error": "Missing 'new_name'"}

	var result := _load_scene(scene_path)
	if not result[1].is_empty():
		return result[1]

	var root: Node = result[0]
	var target = _find_node(root, node_path)
	if not target:
		root.queue_free()
		return {"ok": false, "error": "Node not found: " + node_path}

	var old_name = target.name
	target.name = new_name

	var err := _save_scene(root, scene_path)
	if not err.is_empty():
		return err

	return {"ok": true, "old_name": str(old_name), "new_name": new_name,
		"message": "Renamed '%s' to '%s'" % [old_name, new_name]}

# =============================================================================
# move_node
# =============================================================================
func move_node(args: Dictionary) -> Dictionary:
	var scene_path: String = _ensure_res_path(str(args.get("scene_path", "")))
	var node_path: String = str(args.get("node_path", ""))
	var new_parent_path: String = str(args.get("new_parent_path", "."))
	var sibling_index: int = int(args.get("sibling_index", -1))

	if scene_path.strip_edges() == "res://":
		return {"ok": false, "error": "Missing 'scene_path'"}
	if node_path.strip_edges().is_empty() or node_path == ".":
		return {"ok": false, "error": "Cannot move root node"}

	var result := _load_scene(scene_path)
	if not result[1].is_empty():
		return result[1]

	var root: Node = result[0]
	var target = root.get_node_or_null(node_path)
	if not target:
		root.queue_free()
		return {"ok": false, "error": "Node not found: " + node_path}

	var new_parent = _find_node(root, new_parent_path)
	if not new_parent:
		root.queue_free()
		return {"ok": false, "error": "New parent not found: " + new_parent_path}

	target.get_parent().remove_child(target)
	new_parent.add_child(target)
	target.owner = root

	if sibling_index >= 0:
		new_parent.move_child(target, mini(sibling_index, new_parent.get_child_count() - 1))

	var err := _save_scene(root, scene_path)
	if not err.is_empty():
		return err

	return {"ok": true, "message": "Moved '%s' to '%s'" % [node_path, new_parent_path]}

# =============================================================================
# attach_script
# =============================================================================
func attach_script(args: Dictionary) -> Dictionary:
	var scene_path: String = _ensure_res_path(str(args.get("scene_path", "")))
	var node_path: String = str(args.get("node_path", "."))
	var script_path: String = str(args.get("script_path", ""))

	if scene_path.strip_edges() == "res://":
		return {"ok": false, "error": "Missing 'scene_path'"}
	if script_path.strip_edges().is_empty():
		return {"ok": false, "error": "Missing 'script_path'"}

	var result := _load_scene(scene_path)
	if not result[1].is_empty():
		return result[1]

	var root: Node = result[0]
	var target = _find_node(root, node_path)
	if not target:
		root.queue_free()
		return {"ok": false, "error": "Node not found: " + node_path}

	var script_res = load(script_path)
	if not script_res:
		root.queue_free()
		return {"ok": false, "error": "Failed to load script: " + script_path}

	target.set_script(script_res)

	var err := _save_scene(root, scene_path)
	if not err.is_empty():
		return err

	return {"ok": true, "message": "Attached %s to node '%s'" % [script_path, node_path]}

# =============================================================================
# detach_script
# =============================================================================
func detach_script(args: Dictionary) -> Dictionary:
	var scene_path: String = _ensure_res_path(str(args.get("scene_path", "")))
	var node_path: String = str(args.get("node_path", "."))

	if scene_path.strip_edges() == "res://":
		return {"ok": false, "error": "Missing 'scene_path'"}

	var result := _load_scene(scene_path)
	if not result[1].is_empty():
		return result[1]

	var root: Node = result[0]
	var target = _find_node(root, node_path)
	if not target:
		root.queue_free()
		return {"ok": false, "error": "Node not found: " + node_path}

	target.set_script(null)

	var err := _save_scene(root, scene_path)
	if not err.is_empty():
		return err

	return {"ok": true, "message": "Detached script from node '%s'" % node_path}

# =============================================================================
# set_collision_shape
# =============================================================================
func set_collision_shape(args: Dictionary) -> Dictionary:
	var scene_path: String = _ensure_res_path(str(args.get("scene_path", "")))
	var node_path: String = str(args.get("node_path", "."))
	var shape_type: String = str(args.get("shape_type", ""))
	var shape_params: Dictionary = args.get("shape_params", {})

	if scene_path.strip_edges() == "res://":
		return {"ok": false, "error": "Missing 'scene_path'"}
	if shape_type.strip_edges().is_empty():
		return {"ok": false, "error": "Missing 'shape_type'"}
	if not ClassDB.class_exists(shape_type):
		return {"ok": false, "error": "Invalid shape type: " + shape_type}

	var result := _load_scene(scene_path)
	if not result[1].is_empty():
		return result[1]

	var root: Node = result[0]
	var target = _find_node(root, node_path)
	if not target:
		root.queue_free()
		return {"ok": false, "error": "Node not found: " + node_path}

	# Create shape resource
	var shape = ClassDB.instantiate(shape_type)
	if not shape:
		root.queue_free()
		return {"ok": false, "error": "Failed to create shape: " + shape_type}

	# Apply shape parameters
	if shape_params.has("radius"):
		shape.set("radius", float(shape_params["radius"]))
	if shape_params.has("height"):
		shape.set("height", float(shape_params["height"]))
	if shape_params.has("size"):
		var size_data = shape_params["size"]
		if typeof(size_data) == TYPE_DICTIONARY:
			if size_data.has("z"):
				shape.set("size", Vector3(size_data.get("x", 1), size_data.get("y", 1), size_data.get("z", 1)))
			else:
				shape.set("size", Vector2(size_data.get("x", 1), size_data.get("y", 1)))

	target.set("shape", shape)

	var err := _save_scene(root, scene_path)
	if not err.is_empty():
		return err

	return {"ok": true, "message": "Set %s on node '%s'" % [shape_type, node_path]}

# =============================================================================
# set_sprite_texture
# =============================================================================
func set_sprite_texture(args: Dictionary) -> Dictionary:
	var scene_path: String = _ensure_res_path(str(args.get("scene_path", "")))
	var node_path: String = str(args.get("node_path", "."))
	var texture_type: String = str(args.get("texture_type", ""))
	var texture_params: Dictionary = args.get("texture_params", {})

	if scene_path.strip_edges() == "res://":
		return {"ok": false, "error": "Missing 'scene_path'"}
	if texture_type.strip_edges().is_empty():
		return {"ok": false, "error": "Missing 'texture_type'"}

	var result := _load_scene(scene_path)
	if not result[1].is_empty():
		return result[1]

	var root: Node = result[0]
	var target = _find_node(root, node_path)
	if not target:
		root.queue_free()
		return {"ok": false, "error": "Node not found: " + node_path}

	var texture: Texture2D = null

	match texture_type:
		"ImageTexture":
			var tex_path: String = str(texture_params.get("path", ""))
			if tex_path.is_empty():
				root.queue_free()
				return {"ok": false, "error": "Missing 'path' in texture_params for ImageTexture"}
			texture = load(tex_path)
			if not texture:
				root.queue_free()
				return {"ok": false, "error": "Failed to load texture: " + tex_path}

		"PlaceholderTexture2D":
			texture = PlaceholderTexture2D.new()
			var size_data = texture_params.get("size", {"x": 64, "y": 64})
			if typeof(size_data) == TYPE_DICTIONARY:
				texture.size = Vector2(size_data.get("x", 64), size_data.get("y", 64))

		"GradientTexture2D":
			texture = GradientTexture2D.new()
			texture.width = int(texture_params.get("width", 64))
			texture.height = int(texture_params.get("height", 64))

		"NoiseTexture2D":
			texture = NoiseTexture2D.new()
			texture.width = int(texture_params.get("width", 64))
			texture.height = int(texture_params.get("height", 64))

		_:
			root.queue_free()
			return {"ok": false, "error": "Unknown texture type: " + texture_type}

	target.set("texture", texture)

	var err := _save_scene(root, scene_path)
	if not err.is_empty():
		return err

	return {"ok": true, "message": "Set %s texture on node '%s'" % [texture_type, node_path]}
