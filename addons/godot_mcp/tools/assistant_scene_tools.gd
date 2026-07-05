@tool
extends Node
class_name AssistantSceneTools

const _FILE_TOOLS := preload("res://addons/godot_mcp/tools/file_tools.gd")
## Scene operation tools for MCP.
## Handles: create_scene, read_scene, add_node, remove_node, modify_node_property,
##          rename_node, move_node, attach_script, detach_script, set_collision_shape,
##          set_sprite_texture

const _SKIP_PROPS: Dictionary[String, bool] = {
	"script": true, "owner": true, "scene_file_path": true,
	"unique_name_in_owner": true, "editor_description": true,
}

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
		_editor_plugin.get_editor_interface().get_resource_filesystem().call_deferred("scan")

func _reload_scene_in_editor(scene_path: String) -> void:
	if not _editor_plugin:
		return
	var ei = _editor_plugin.get_editor_interface()
	var edited = ei.get_edited_scene_root()
	if edited and edited.scene_file_path == scene_path:
		ei.reload_scene_from_path(scene_path)

func _suggest_scenes_in_dir(dir_path: String) -> PackedStringArray:
	var out: PackedStringArray = []
	var dir := DirAccess.open(dir_path)
	if dir == null:
		return out
	dir.list_dir_begin()
	var name := dir.get_next()
	while name != "" and out.size() < 5:
		if not dir.current_is_dir() and (name.ends_with(".tscn") or name.ends_with(".scn")):
			out.append(dir_path.path_join(name))
		name = dir.get_next()
	dir.list_dir_end()
	return out

func _ensure_res_path(path: String) -> String:
	var trimmed := path.strip_edges()
	if trimmed.begins_with("uid://"):
		var resolved := _resolve_uid_path(trimmed)
		if not resolved.is_empty():
			return resolved
		return trimmed
	if not trimmed.begins_with("res://"):
		return "res://" + trimmed
	return trimmed

func _resolve_uid_path(uid_path: String) -> String:
	var uid_id := int(ResourceUID.text_to_id(uid_path))
	if uid_id <= 0:
		return ""
	var resolved := str(ResourceUID.get_id_path(uid_id)).strip_edges()
	if resolved.is_empty():
		return ""
	return resolved

func _load_scene(scene_path: String) -> Array:
	"""Returns [scene_root, error_dict]. If error_dict is not empty, scene_root is null."""
	if DirAccess.dir_exists_absolute(scene_path):
		var hint := _suggest_scenes_in_dir(scene_path)
		var msg := "Expected a .tscn scene file, got a directory: " + scene_path
		if not hint.is_empty():
			msg += ". Did you mean: " + ", ".join(hint) + "?"
		else:
			msg += ". Use list_dir to discover scene files, or search_project with glob='*.tscn'."
		return [null, {&"ok": false, &"error": msg}]
	if not FileAccess.file_exists(scene_path):
		var msg2 := "Scene does not exist: " + scene_path
		if not scene_path.ends_with(".tscn") and not scene_path.ends_with(".scn"):
			msg2 += " (path must end in .tscn or .scn)"
		return [null, {&"ok": false, &"error": msg2}]

	var packed = load(scene_path) as PackedScene
	if not packed:
		return [null, {&"ok": false, &"error": "Failed to load scene: " + scene_path}]

	var root = packed.instantiate()
	if not root:
		return [null, {&"ok": false, &"error": "Failed to instantiate scene"}]

	return [root, {}]

func _save_scene(scene_root: Node, scene_path: String) -> Dictionary:
	"""Pack and save a scene. Returns error dict or empty on success."""
	var packed = PackedScene.new()
	var pack_result = packed.pack(scene_root)
	if pack_result != OK:
		scene_root.queue_free()
		return {&"ok": false, &"error": "Failed to pack scene: " + str(pack_result)}

	var save_result = ResourceSaver.save(packed, scene_path)
	scene_root.queue_free()

	if save_result != OK:
		return {&"ok": false, &"error": "Failed to save scene: " + str(save_result)}

	_refresh_and_reload(scene_path)
	return {}

func _find_node(scene_root: Node, node_path: String) -> Node:
	if node_path == "." or node_path.is_empty():
		return scene_root
	return scene_root.get_node_or_null(node_path)

func _parse_value(value: Variant) -> Variant:
	"""Convert dictionary-encoded types to Godot types."""
	if value is Dictionary:
		var t: String = value.get(&"type", "")
		match t:
			"Vector2": return Vector2(value.get(&"x", 0), value.get(&"y", 0))
			"Vector3": return Vector3(value.get(&"x", 0), value.get(&"y", 0), value.get(&"z", 0))
			"Color": return Color(value.get(&"r", 1), value.get(&"g", 1), value.get(&"b", 1), value.get(&"a", 1))
			"Vector2i": return Vector2i(value.get(&"x", 0), value.get(&"y", 0))
			"Vector3i": return Vector3i(value.get(&"x", 0), value.get(&"y", 0), value.get(&"z", 0))
			"Rect2": return Rect2(value.get(&"x", 0), value.get(&"y", 0), value.get(&"width", 0), value.get(&"height", 0))
	return value

func _set_node_properties(node: Node, properties: Dictionary) -> void:
	for prop_name: String in properties:
		var prop_value = _parse_value(properties[prop_name])
		node.set(prop_name, prop_value)

func _serialize_value(value: Variant) -> Variant:
	match typeof(value):
		TYPE_VECTOR2: return {&"type": &"Vector2", &"x": value.x, &"y": value.y}
		TYPE_VECTOR3: return {&"type": &"Vector3", &"x": value.x, &"y": value.y, &"z": value.z}
		TYPE_COLOR: return {&"type": &"Color", &"r": value.r, &"g": value.g, &"b": value.b, &"a": value.a}
		TYPE_VECTOR2I: return {&"type": &"Vector2i", &"x": value.x, &"y": value.y}
		TYPE_VECTOR3I: return {&"type": &"Vector3i", &"x": value.x, &"y": value.y, &"z": value.z}
		TYPE_RECT2: return {&"type": &"Rect2", &"x": value.position.x, &"y": value.position.y, &"width": value.size.x, &"height": value.size.y}
		TYPE_OBJECT:
			if value and value is Resource and value.resource_path:
				return {&"type": &"Resource", &"path": value.resource_path}
			return null
		_: return value

# =============================================================================
# create_scene
# =============================================================================
func create_scene(args: Dictionary) -> Dictionary:
	# Accept both the schema-canonical names (path/root_type/root_name) and the
	# older internal names (scene_path/root_node_type/root_node_name) so we are
	# resilient to either form. The schema advertises path/root_type/root_name.
	var raw_path: String = str(args.get(&"path", args.get(&"scene_path", "")))
	var scene_path: String = _ensure_res_path(raw_path)
	var root_node_name: String = str(args.get(&"root_name", args.get(&"root_node_name", "Node")))
	var root_node_type: String = str(args.get(&"root_type", args.get(&"root_node_type", "")))
	var nodes: Array = args.get(&"nodes", [])
	var attach_script_path: String = str(args.get(&"attach_script", ""))

	if scene_path.strip_edges() == "res://" or raw_path.strip_edges().is_empty():
		return {&"ok": false, &"error": "Missing 'path' parameter (res:// path of the new scene)"}
	if root_node_type.strip_edges().is_empty():
		return {&"ok": false, &"error": "Missing 'root_type' parameter (e.g. Node2D, Control)"}
	if not scene_path.ends_with(".tscn"):
		scene_path += ".tscn"
	if FileAccess.file_exists(scene_path):
		return {&"ok": false, &"error": "Scene already exists: " + scene_path}
	if not ClassDB.class_exists(root_node_type):
		return {&"ok": false, &"error": "Invalid root node type: " + root_node_type}

	# Ensure parent directory
	var dir_path := scene_path.get_base_dir()
	if not DirAccess.dir_exists_absolute(dir_path):
		DirAccess.make_dir_recursive_absolute(dir_path)

	var root: Node = ClassDB.instantiate(root_node_type) as Node
	if not root:
		return {&"ok": false, &"error": "Failed to create root node of type: " + root_node_type}
	root.name = root_node_name

	if not attach_script_path.is_empty():
		var script_res = load(attach_script_path)
		if script_res:
			root.set_script(script_res)

	var node_count := 0
	for node_data: Variant in nodes:
		if typeof(node_data) == TYPE_DICTIONARY:
			var created = _create_node_recursive(node_data, root, root)
			if created:
				node_count += _count_nodes(created)

	var err := _save_scene(root, scene_path)
	if not err.is_empty():
		return err

	return {&"ok": true, &"path": scene_path, &"root_type": root_node_type, &"child_count": node_count,
		&"message": "Scene created at " + scene_path}

func _create_node_recursive(data: Dictionary, parent: Node, owner: Node) -> Node:
	var n_name: String = str(data.get(&"name", "Node"))
	var n_type: String = str(data.get(&"type", "Node"))
	var n_script: String = str(data.get(&"script", ""))
	var props: Dictionary = data.get(&"properties", {})
	var children: Array = data.get(&"children", [])

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

	for child_data: Variant in children:
		if typeof(child_data) == TYPE_DICTIONARY:
			_create_node_recursive(child_data, node, owner)
	return node

func _count_nodes(node: Node) -> int:
	var count := 1
	for child: Node in node.get_children():
		count += _count_nodes(child)
	return count

# =============================================================================
# read_scene
# =============================================================================
func read_scene(args: Dictionary) -> Dictionary:
	var scene_path: String = _ensure_res_path(str(args.get(&"scene_path", "")))
	var include_properties: bool = args.get(&"include_properties", false)
	var max_depth: int = int(args.get(&"max_depth", 4))
	var node_path_filter: String = str(args.get(&"node_path", "")).strip_edges()

	if scene_path.strip_edges() == "res://":
		return {&"ok": false, &"error": "Missing 'scene_path' parameter"}

	var result := _load_scene(scene_path)
	if not result[1].is_empty():
		return result[1]

	var root: Node = result[0]
	var subtree_root: Node = root
	var base_path := "."
	if not node_path_filter.is_empty() and node_path_filter != ".":
		var found := _find_node(root, node_path_filter)
		if not found:
			root.queue_free()
			return {&"ok": false, &"error": "Node not found: " + node_path_filter}
		subtree_root = found
		base_path = node_path_filter

	var script_warnings: Array = []
	var structure = _build_node_structure(subtree_root, include_properties, base_path, 0, max_depth, script_warnings)
	root.queue_free()

	var out: Dictionary = {&"ok": true, &"scene_path": scene_path, &"root": structure, &"max_depth": max_depth}
	if not script_warnings.is_empty():
		out[&"script_warnings"] = script_warnings
		out[&"hint"] = "One or more attached scripts look incompatible with their node. Inspect them with read_file (script_metadata field) or get_errors before editing the scene."
	return out

func _build_node_structure(node: Node, include_props: bool, path: String = ".", depth: int = 0, max_depth: int = 4, script_warnings: Array = []) -> Dictionary:
	const PROPERTIES: PackedStringArray = ["position", "rotation", "scale", "size", "offset", "visible",
			"modulate", "z_index", "text", "collision_layer", "collision_mask", "mass"]
	var data := {&"name": str(node.name), &"type": node.get_class(), &"path": path}
	var script = node.get_script()
	if script:
		var script_path: String = script.resource_path
		data[&"script"] = script_path
		# Cheap header peek (no `load()`) to flag a clearly incompatible base
		# class — when the script's `extends` isn't a parent of the actual
		# node type. Skipped silently for unknown base classes.
		var meta := _FILE_TOOLS.analyze_script_header(script_path)
		var node_class: String = node.get_class()
		var ext_str: String = str(meta.get(&"extends", ""))
		if not ext_str.is_empty() and ClassDB.class_exists(ext_str) and not ClassDB.is_parent_class(node_class, ext_str):
			var warning := "Script %s extends `%s` but the node is a `%s` — incompatible base class." % [script_path, ext_str, node_class]
			data[&"script_warning"] = warning
			script_warnings.append({&"node_path": path, &"script": script_path, &"warning": warning})

	if include_props:
		var props := {}
		for prop_name: String in PROPERTIES:
			var val = node.get(prop_name)
			if val != null:
				props[prop_name] = _serialize_value(val)
		if not props.is_empty():
			data[&"properties"] = props

	var children := node.get_children()
	if children.is_empty():
		return data

	if depth >= max_depth:
		data[&"children_omitted"] = children.size()
		return data

	var out_children: Array = []
	for child: Node in children:
		var child_path = child.name if path == "." else path + "/" + child.name
		out_children.append(_build_node_structure(child, include_props, child_path, depth + 1, max_depth, script_warnings))
	data[&"children"] = out_children
	return data

# =============================================================================
# add_node
# =============================================================================
func add_node(args: Dictionary) -> Dictionary:
	var scene_path: String = _ensure_res_path(str(args.get(&"scene_path", "")))
	var node_name: String = str(args.get(&"node_name", ""))
	var node_type: String = str(args.get(&"node_type", "Node"))
	var parent_path: String = str(args.get(&"parent_path", "."))
	var properties: Dictionary = args.get(&"properties", {})

	if scene_path.strip_edges() == "res://":
		return {&"ok": false, &"error": "Missing 'scene_path'"}
	if node_name.strip_edges().is_empty():
		return {&"ok": false, &"error": "Missing 'node_name'"}
	if not ClassDB.class_exists(node_type):
		return {&"ok": false, &"error": "Invalid node type: " + node_type}

	var result := _load_scene(scene_path)
	if not result[1].is_empty():
		return result[1]

	var root: Node = result[0]
	var parent = _find_node(root, parent_path)
	if not parent:
		root.queue_free()
		return {&"ok": false, &"error": "Parent node not found: " + parent_path}

	var new_node: Node = ClassDB.instantiate(node_type) as Node
	if not new_node:
		root.queue_free()
		return {&"ok": false, &"error": "Failed to create node of type: " + node_type}

	new_node.name = node_name
	_set_node_properties(new_node, properties)
	parent.add_child(new_node)
	new_node.owner = root

	var err := _save_scene(root, scene_path)
	if not err.is_empty():
		return err

	return {&"ok": true, &"scene_path": scene_path, &"node_name": node_name, &"node_type": node_type,
		&"message": "Added %s (%s) to scene" % [node_name, node_type]}

# =============================================================================
# remove_node
# =============================================================================
func remove_node(args: Dictionary) -> Dictionary:
	var scene_path: String = _ensure_res_path(str(args.get(&"scene_path", "")))
	var node_path: String = str(args.get(&"node_path", ""))

	if scene_path.strip_edges() == "res://":
		return {&"ok": false, &"error": "Missing 'scene_path'"}
	if node_path.strip_edges().is_empty() or node_path == ".":
		return {&"ok": false, &"error": "Cannot remove root node"}

	var result := _load_scene(scene_path)
	if not result[1].is_empty():
		return result[1]

	var root: Node = result[0]
	var target = root.get_node_or_null(node_path)
	if not target:
		root.queue_free()
		return {&"ok": false, &"error": "Node not found: " + node_path}

	var n_name = target.name
	var n_type = target.get_class()
	target.get_parent().remove_child(target)
	target.queue_free()

	var err := _save_scene(root, scene_path)
	if not err.is_empty():
		return err

	return {&"ok": true, &"scene_path": scene_path, &"removed_node": node_path,
		&"message": "Removed %s (%s)" % [n_name, n_type]}

# =============================================================================
# get_node_property - read a single property from a node without dumping the scene
# =============================================================================
func get_node_property(args: Dictionary) -> Dictionary:
	var scene_path: String = _ensure_res_path(str(args.get(&"scene_path", "")))
	var node_path: String = str(args.get(&"node_path", "."))
	var property_name: String = str(args.get(&"property_name", "")).strip_edges()

	if scene_path.strip_edges() == "res://":
		return {&"ok": false, &"error": "Missing 'scene_path'"}
	if property_name.is_empty():
		return {&"ok": false, &"error": "Missing 'property_name'"}

	var result := _load_scene(scene_path)
	if not result[1].is_empty():
		return result[1]

	var root: Node = result[0]
	var target = _find_node(root, node_path)
	if not target:
		root.queue_free()
		return {&"ok": false, &"error": "Node not found: " + node_path}

	var has_prop := false
	for prop: Dictionary in target.get_property_list():
		if prop[&"name"] == property_name:
			has_prop = true
			break
	if not has_prop:
		var node_type = target.get_class()
		root.queue_free()
		return {&"ok": false, &"error": "Property '%s' not found on %s (%s)" % [property_name, node_path, node_type]}

	var value = target.get(property_name)
	var node_type2 = target.get_class()
	root.queue_free()

	return {
		&"ok": true,
		&"scene_path": scene_path,
		&"node_path": node_path,
		&"node_type": node_type2,
		&"property_name": property_name,
		&"value": _serialize_value(value),
	}

# =============================================================================
# modify_node_property
# =============================================================================
func modify_node_property(args: Dictionary) -> Dictionary:
	var scene_path: String = _ensure_res_path(str(args.get(&"scene_path", "")))
	var node_path: String = str(args.get(&"node_path", "."))
	var property_name: String = str(args.get(&"property_name", "")).strip_edges()
	if property_name.is_empty():
		property_name = str(args.get(&"property_path", "")).strip_edges()
	var value = args.get(&"value")

	if scene_path.strip_edges() == "res://":
		return {&"ok": false, &"error": "Missing 'scene_path'"}
	if property_name.strip_edges().is_empty():
		return {&"ok": false, &"error": "Missing 'property_name'"}
	if value == null:
		return {&"ok": false, &"error": "Missing 'value'"}

	var result := _load_scene(scene_path)
	if not result[1].is_empty():
		return result[1]

	var root: Node = result[0]
	var target = _find_node(root, node_path)
	if not target:
		root.queue_free()
		return {&"ok": false, &"error": "Node not found: " + node_path}

	# Check property exists
	var prop_exists := false
	for prop: Dictionary in target.get_property_list():
		if prop[&"name"] == property_name:
			prop_exists = true
			break
	if not prop_exists:
		var node_type = target.get_class()
		root.queue_free()
		return {&"ok": false, &"error": "Property '%s' not found on %s (%s). Use get_node_properties to discover available properties." % [property_name, node_path, node_type]}

	var parsed = _parse_value(value)
	var old_value = target.get(property_name)

	# Validate resource type compatibility
	if old_value is Resource and not (parsed is Resource):
		root.queue_free()
		return {&"ok": false, &"error": "Property '%s' expects a Resource. Use specialized tools (set_collision_shape, set_sprite_texture) instead." % property_name}

	target.set(property_name, parsed)

	var err := _save_scene(root, scene_path)
	if not err.is_empty():
		return err

	return {&"ok": true, &"scene_path": scene_path, &"node_path": node_path,
		&"property_name": property_name, &"old_value": str(old_value), &"new_value": str(parsed),
		&"message": "Set %s.%s = %s" % [node_path, property_name, str(parsed)]}

# =============================================================================
# rename_node
# =============================================================================
func rename_node(args: Dictionary) -> Dictionary:
	var scene_path: String = _ensure_res_path(str(args.get(&"scene_path", "")))
	var node_path: String = str(args.get(&"node_path", ""))
	var new_name: String = str(args.get(&"new_name", ""))

	if scene_path.strip_edges() == "res://":
		return {&"ok": false, &"error": "Missing 'scene_path'"}
	if node_path.strip_edges().is_empty():
		return {&"ok": false, &"error": "Missing 'node_path'"}
	if new_name.strip_edges().is_empty():
		return {&"ok": false, &"error": "Missing 'new_name'"}

	var result := _load_scene(scene_path)
	if not result[1].is_empty():
		return result[1]

	var root: Node = result[0]
	var target = _find_node(root, node_path)
	if not target:
		root.queue_free()
		return {&"ok": false, &"error": "Node not found: " + node_path}

	var old_name = target.name
	target.name = new_name

	var err := _save_scene(root, scene_path)
	if not err.is_empty():
		return err

	return {&"ok": true, &"old_name": str(old_name), &"new_name": new_name,
		&"message": "Renamed '%s' to '%s'" % [old_name, new_name]}

# =============================================================================
# move_node
# =============================================================================
func move_node(args: Dictionary) -> Dictionary:
	var scene_path: String = _ensure_res_path(str(args.get(&"scene_path", "")))
	var node_path: String = str(args.get(&"node_path", ""))
	var new_parent_path: String = str(args.get(&"new_parent_path", "."))
	var sibling_index: int = int(args.get(&"sibling_index", -1))

	if scene_path.strip_edges() == "res://":
		return {&"ok": false, &"error": "Missing 'scene_path'"}
	if node_path.strip_edges().is_empty() or node_path == ".":
		return {&"ok": false, &"error": "Cannot move root node"}

	var result := _load_scene(scene_path)
	if not result[1].is_empty():
		return result[1]

	var root: Node = result[0]
	var target = root.get_node_or_null(node_path)
	if not target:
		root.queue_free()
		return {&"ok": false, &"error": "Node not found: " + node_path}

	var new_parent = _find_node(root, new_parent_path)
	if not new_parent:
		root.queue_free()
		return {&"ok": false, &"error": "New parent not found: " + new_parent_path}

	target.get_parent().remove_child(target)
	new_parent.add_child(target)
	target.owner = root

	if sibling_index >= 0:
		new_parent.move_child(target, mini(sibling_index, new_parent.get_child_count() - 1))

	var err := _save_scene(root, scene_path)
	if not err.is_empty():
		return err

	return {&"ok": true, &"message": "Moved '%s' to '%s'" % [node_path, new_parent_path]}

# =============================================================================
# duplicate_node
# =============================================================================
func duplicate_node(args: Dictionary) -> Dictionary:
	var scene_path: String = _ensure_res_path(str(args.get(&"scene_path", "")))
	var node_path: String = str(args.get(&"node_path", ""))
	var new_name: String = str(args.get(&"new_name", ""))

	if scene_path.strip_edges() == "res://":
		return {&"ok": false, &"error": "Missing 'scene_path'"}
	if node_path.strip_edges().is_empty() or node_path == ".":
		return {&"ok": false, &"error": "Cannot duplicate root node"}

	var result := _load_scene(scene_path)
	if not result[1].is_empty():
		return result[1]

	var root: Node = result[0]
	var target = root.get_node_or_null(node_path)
	if not target:
		root.queue_free()
		return {&"ok": false, &"error": "Node not found: " + node_path}

	var parent = target.get_parent()
	if not parent:
		root.queue_free()
		return {&"ok": false, &"error": "Cannot duplicate - no parent"}

	var duplicate = target.duplicate()

	if new_name.is_empty():
		var base_name = target.name
		var counter = 2
		new_name = base_name + str(counter)
		while parent.has_node(NodePath(new_name)):
			counter += 1
			new_name = base_name + str(counter)

	duplicate.name = new_name
	parent.add_child(duplicate)

	_set_owner_recursive(duplicate, root)

	var original_index = target.get_index()
	parent.move_child(duplicate, original_index + 1)

	var err := _save_scene(root, scene_path)
	if not err.is_empty():
		return err

	return {&"ok": true, &"new_name": new_name,
		&"message": "Duplicated '%s' as '%s'" % [node_path, new_name]}


func _set_owner_recursive(node: Node, owner: Node) -> void:
	node.owner = owner
	for child: Node in node.get_children():
		_set_owner_recursive(child, owner)


# =============================================================================
# reorder_node - simpler function just for changing sibling order
# =============================================================================
func reorder_node(args: Dictionary) -> Dictionary:
	var scene_path: String = _ensure_res_path(str(args.get(&"scene_path", "")))
	var node_path: String = str(args.get(&"node_path", ""))
	var new_index: int = int(args.get(&"new_index", -1))

	if scene_path.strip_edges() == "res://":
		return {&"ok": false, &"error": "Missing 'scene_path'"}
	if node_path.strip_edges().is_empty() or node_path == ".":
		return {&"ok": false, &"error": "Cannot reorder root node"}

	var result := _load_scene(scene_path)
	if not result[1].is_empty():
		return result[1]

	var root: Node = result[0]
	var target = root.get_node_or_null(node_path)
	if not target:
		root.queue_free()
		return {&"ok": false, &"error": "Node not found: " + node_path}

	var parent = target.get_parent()
	if not parent:
		root.queue_free()
		return {&"ok": false, &"error": "Cannot reorder - no parent"}

	var old_index = target.get_index()
	var max_index = parent.get_child_count() - 1
	new_index = clampi(new_index, 0, max_index)

	if old_index == new_index:
		root.queue_free()
		return {&"ok": true, &"message": "No change needed"}

	parent.move_child(target, new_index)

	var err := _save_scene(root, scene_path)
	if not err.is_empty():
		return err

	return {&"ok": true, &"old_index": old_index, &"new_index": new_index,
		&"message": "Moved '%s' from index %d to %d" % [node_path, old_index, new_index]}


# =============================================================================
# attach_script
# =============================================================================
func attach_script(args: Dictionary) -> Dictionary:
	var scene_path: String = _ensure_res_path(str(args.get(&"scene_path", "")))
	var node_path: String = str(args.get(&"node_path", "."))
	var script_path: String = str(args.get(&"script_path", ""))

	if scene_path.strip_edges() == "res://":
		return {&"ok": false, &"error": "Missing 'scene_path'"}
	if script_path.strip_edges().is_empty():
		return {&"ok": false, &"error": "Missing 'script_path'"}

	var result := _load_scene(scene_path)
	if not result[1].is_empty():
		return result[1]

	var root: Node = result[0]
	var target = _find_node(root, node_path)
	if not target:
		root.queue_free()
		return {&"ok": false, &"error": "Node not found: " + node_path}

	var script_res = load(script_path)
	if not script_res:
		root.queue_free()
		return {&"ok": false, &"error": "Failed to load script: " + script_path}

	target.set_script(script_res)

	var err := _save_scene(root, scene_path)
	if not err.is_empty():
		return err

	return {&"ok": true, &"message": "Attached %s to node '%s'" % [script_path, node_path]}

# =============================================================================
# detach_script
# =============================================================================
func detach_script(args: Dictionary) -> Dictionary:
	var scene_path: String = _ensure_res_path(str(args.get(&"scene_path", "")))
	var node_path: String = str(args.get(&"node_path", "."))

	if scene_path.strip_edges() == "res://":
		return {&"ok": false, &"error": "Missing 'scene_path'"}

	var result := _load_scene(scene_path)
	if not result[1].is_empty():
		return result[1]

	var root: Node = result[0]
	var target = _find_node(root, node_path)
	if not target:
		root.queue_free()
		return {&"ok": false, &"error": "Node not found: " + node_path}

	target.set_script(null)

	var err := _save_scene(root, scene_path)
	if not err.is_empty():
		return err

	return {&"ok": true, &"message": "Detached script from node '%s'" % node_path}

# =============================================================================
# set_collision_shape
# =============================================================================
func set_collision_shape(args: Dictionary) -> Dictionary:
	var scene_path: String = _ensure_res_path(str(args.get(&"scene_path", "")))
	var node_path: String = str(args.get(&"node_path", "."))
	var shape_type: String = str(args.get(&"shape_type", ""))
	var shape_params: Dictionary = args.get(&"shape_params", {})

	if scene_path.strip_edges() == "res://":
		return {&"ok": false, &"error": "Missing 'scene_path'"}
	if shape_type.strip_edges().is_empty():
		return {&"ok": false, &"error": "Missing 'shape_type'"}
	if not ClassDB.class_exists(shape_type):
		return {&"ok": false, &"error": "Invalid shape type: " + shape_type}

	var result := _load_scene(scene_path)
	if not result[1].is_empty():
		return result[1]

	var root: Node = result[0]
	var target = _find_node(root, node_path)
	if not target:
		root.queue_free()
		return {&"ok": false, &"error": "Node not found: " + node_path}

	var shape = ClassDB.instantiate(shape_type)
	if not shape:
		root.queue_free()
		return {&"ok": false, &"error": "Failed to create shape: " + shape_type}

	if shape_params.has(&"radius"):
		shape.set("radius", float(shape_params[&"radius"]))
	if shape_params.has(&"height"):
		shape.set("height", float(shape_params[&"height"]))
	if shape_params.has(&"size"):
		var size_data = shape_params[&"size"]
		if typeof(size_data) == TYPE_DICTIONARY:
			if size_data.has(&"z"):
				shape.set("size", Vector3(size_data.get(&"x", 1), size_data.get(&"y", 1), size_data.get(&"z", 1)))
			else:
				shape.set("size", Vector2(size_data.get(&"x", 1), size_data.get(&"y", 1)))

	target.set("shape", shape)

	var err := _save_scene(root, scene_path)
	if not err.is_empty():
		return err

	return {&"ok": true, &"message": "Set %s on node '%s'" % [shape_type, node_path]}

# =============================================================================
# set_sprite_texture
# =============================================================================
func set_sprite_texture(args: Dictionary) -> Dictionary:
	var scene_path: String = _ensure_res_path(str(args.get(&"scene_path", "")))
	var node_path: String = str(args.get(&"node_path", "."))
	var texture_type: String = str(args.get(&"texture_type", ""))
	var texture_params: Dictionary = args.get(&"texture_params", {})

	if scene_path.strip_edges() == "res://":
		return {&"ok": false, &"error": "Missing 'scene_path'"}
	if texture_type.strip_edges().is_empty():
		return {&"ok": false, &"error": "Missing 'texture_type'"}

	var result := _load_scene(scene_path)
	if not result[1].is_empty():
		return result[1]

	var root: Node = result[0]
	var target = _find_node(root, node_path)
	if not target:
		root.queue_free()
		return {&"ok": false, &"error": "Node not found: " + node_path}

	var texture: Texture2D = null

	match texture_type:
		"ImageTexture":
			var tex_path: String = str(texture_params.get(&"path", ""))
			if tex_path.is_empty():
				root.queue_free()
				return {&"ok": false, &"error": "Missing 'path' in texture_params for ImageTexture"}
			texture = load(tex_path)
			if not texture:
				root.queue_free()
				return {&"ok": false, &"error": "Failed to load texture: " + tex_path}

		"PlaceholderTexture2D":
			texture = PlaceholderTexture2D.new()
			var size_data = texture_params.get(&"size", {&"x": 64, &"y": 64})
			if typeof(size_data) == TYPE_DICTIONARY:
				texture.size = Vector2(size_data.get(&"x", 64), size_data.get(&"y", 64))

		"GradientTexture2D":
			texture = GradientTexture2D.new()
			texture.width = int(texture_params.get(&"width", 64))
			texture.height = int(texture_params.get(&"height", 64))

		"NoiseTexture2D":
			texture = NoiseTexture2D.new()
			texture.width = int(texture_params.get(&"width", 64))
			texture.height = int(texture_params.get(&"height", 64))

		_:
			root.queue_free()
			return {&"ok": false, &"error": "Unknown texture type: " + texture_type}

	target.set("texture", texture)

	var err := _save_scene(root, scene_path)
	if not err.is_empty():
		return err

	return {&"ok": true, &"message": "Set %s texture on node '%s'" % [texture_type, node_path]}

# =============================================================================
# get_scene_hierarchy (for visualizer)
# =============================================================================
func get_scene_hierarchy(args: Dictionary) -> Dictionary:
	"""Get the full scene hierarchy with node information for the visualizer."""
	var scene_path: String = _ensure_res_path(str(args.get(&"scene_path", "")))

	if scene_path.strip_edges() == "res://":
		return {&"ok": false, &"error": "Missing 'scene_path'"}

	var result := _load_scene(scene_path)
	if not result[1].is_empty():
		return result[1]

	var root: Node = result[0]
	var hierarchy = _build_hierarchy_recursive(root, ".")
	root.queue_free()

	return {&"ok": true, &"scene_path": scene_path, &"hierarchy": hierarchy}

func _build_hierarchy_recursive(node: Node, path: String) -> Dictionary:
	"""Build node hierarchy with all info needed for visualizer."""
	var data := {
		&"name": str(node.name),
		&"type": node.get_class(),
		&"path": path,
		&"children": [],
		&"child_count": node.get_child_count()
	}

	var script = node.get_script()
	if script:
		data[&"script"] = script.resource_path

	var parent = node.get_parent()
	if parent:
		data[&"index"] = node.get_index()

	for i: int in range(node.get_child_count()):
		var child = node.get_child(i)
		var child_path = child.name if path == "." else path + "/" + child.name
		data[&"children"].append(_build_hierarchy_recursive(child, child_path))

	return data

# =============================================================================
# get_scene_node_properties (dynamic property fetching)
# =============================================================================
func get_scene_node_properties(args: Dictionary) -> Dictionary:
	"""Get all properties of a specific node in a scene with their current values."""
	var scene_path: String = _ensure_res_path(str(args.get(&"scene_path", "")))
	var node_path: String = str(args.get(&"node_path", "."))

	if scene_path.strip_edges() == "res://":
		return {&"ok": false, &"error": "Missing 'scene_path'"}

	var result := _load_scene(scene_path)
	if not result[1].is_empty():
		return result[1]

	var root: Node = result[0]
	var target = _find_node(root, node_path)
	if not target:
		root.queue_free()
		return {&"ok": false, &"error": "Node not found: " + node_path}

	var node_type = target.get_class()
	var properties: Array = []
	var categories: Dictionary = {}

	for prop: Dictionary in target.get_property_list():
		var prop_name: String = prop[&"name"]

		if prop_name.begins_with("_"):
			continue
		if _SKIP_PROPS.has(prop_name):
			continue

		var usage = prop.get(&"usage", 0)
		if not (usage & PROPERTY_USAGE_EDITOR):
			continue

		var current_value = target.get(prop_name)

		var prop_info := {
			&"name": prop_name,
			&"type": prop[&"type"],
			&"type_name": _type_id_to_name(prop[&"type"]),
			&"hint": prop.get(&"hint", 0),
			&"hint_string": prop.get(&"hint_string", ""),
			&"value": _serialize_value(current_value),
			&"usage": usage
		}

		var category = _get_property_category(target, prop_name)
		prop_info[&"category"] = category

		if not categories.has(category):
			categories[category] = []
		categories[category].append(prop_info)
		properties.append(prop_info)

	var chain: Array = []
	var cls: String = node_type
	while cls != "":
		chain.append(cls)
		cls = ClassDB.get_parent_class(cls)

	root.queue_free()

	return {
		&"ok": true,
		&"scene_path": scene_path,
		&"node_path": node_path,
		&"node_type": node_type,
		&"node_name": target.name,
		&"inheritance_chain": chain,
		&"properties": properties,
		&"categories": categories,
		&"property_count": properties.size()
	}

func _type_id_to_name(type_id: int) -> String:
	"""Convert Godot type ID to human-readable name."""
	match type_id:
		TYPE_NIL: return "null"
		TYPE_BOOL: return "bool"
		TYPE_INT: return "int"
		TYPE_FLOAT: return "float"
		TYPE_STRING: return "String"
		TYPE_VECTOR2: return "Vector2"
		TYPE_VECTOR2I: return "Vector2i"
		TYPE_RECT2: return "Rect2"
		TYPE_RECT2I: return "Rect2i"
		TYPE_VECTOR3: return "Vector3"
		TYPE_VECTOR3I: return "Vector3i"
		TYPE_TRANSFORM2D: return "Transform2D"
		TYPE_VECTOR4: return "Vector4"
		TYPE_VECTOR4I: return "Vector4i"
		TYPE_PLANE: return "Plane"
		TYPE_QUATERNION: return "Quaternion"
		TYPE_AABB: return "AABB"
		TYPE_BASIS: return "Basis"
		TYPE_TRANSFORM3D: return "Transform3D"
		TYPE_PROJECTION: return "Projection"
		TYPE_COLOR: return "Color"
		TYPE_STRING_NAME: return "StringName"
		TYPE_NODE_PATH: return "NodePath"
		TYPE_RID: return "RID"
		TYPE_OBJECT: return "Object"
		TYPE_CALLABLE: return "Callable"
		TYPE_SIGNAL: return "Signal"
		TYPE_DICTIONARY: return "Dictionary"
		TYPE_ARRAY: return "Array"
		TYPE_PACKED_BYTE_ARRAY: return "PackedByteArray"
		TYPE_PACKED_INT32_ARRAY: return "PackedInt32Array"
		TYPE_PACKED_INT64_ARRAY: return "PackedInt64Array"
		TYPE_PACKED_FLOAT32_ARRAY: return "PackedFloat32Array"
		TYPE_PACKED_FLOAT64_ARRAY: return "PackedFloat64Array"
		TYPE_PACKED_STRING_ARRAY: return "PackedStringArray"
		TYPE_PACKED_VECTOR2_ARRAY: return "PackedVector2Array"
		TYPE_PACKED_VECTOR3_ARRAY: return "PackedVector3Array"
		TYPE_PACKED_COLOR_ARRAY: return "PackedColorArray"
		_: return "Variant"

func _get_property_category(node: Node, prop_name: String) -> String:
	"""Determine which class in the hierarchy defines this property."""
	var cls: String = node.get_class()
	while cls != "":
		var class_props = ClassDB.class_get_property_list(cls, true)
		for prop: Dictionary in class_props:
			if prop[&"name"] == prop_name:
				return cls
		cls = ClassDB.get_parent_class(cls)
	return node.get_class()

# =============================================================================
# set_scene_node_property (for visualizer inline editing)
# =============================================================================
func set_scene_node_property(args: Dictionary) -> Dictionary:
	"""Set a property on a node in a scene (supports complex types)."""
	var scene_path: String = _ensure_res_path(str(args.get(&"scene_path", "")))
	var node_path: String = str(args.get(&"node_path", "."))
	var property_name: String = str(args.get(&"property_name", ""))
	var value = args.get(&"value")
	var value_type: int = int(args.get(&"value_type", -1))

	if scene_path.strip_edges() == "res://":
		return {&"ok": false, &"error": "Missing 'scene_path'"}
	if property_name.strip_edges().is_empty():
		return {&"ok": false, &"error": "Missing 'property_name'"}

	var result := _load_scene(scene_path)
	if not result[1].is_empty():
		return result[1]

	var root: Node = result[0]
	var target = _find_node(root, node_path)
	if not target:
		root.queue_free()
		return {&"ok": false, &"error": "Node not found: " + node_path}

	var parsed_value = _parse_typed_value(value, value_type)
	var old_value = target.get(property_name)

	target.set(property_name, parsed_value)

	var err := _save_scene(root, scene_path)
	if not err.is_empty():
		return err

	return {
		&"ok": true,
		&"scene_path": scene_path,
		&"node_path": node_path,
		&"property_name": property_name,
		&"old_value": _serialize_value(old_value),
		&"new_value": _serialize_value(parsed_value),
		&"message": "Set %s.%s" % [node_path, property_name]
	}

func _parse_typed_value(value, type_hint: int):
	"""Parse a value based on its type hint."""
	if type_hint == -1:
		return _parse_value(value)

	if typeof(value) == TYPE_DICTIONARY:
		if value.has(&"type"):
			return _parse_value(value)

		match type_hint:
			TYPE_VECTOR2:
				return Vector2(value.get(&"x", 0), value.get(&"y", 0))
			TYPE_VECTOR2I:
				return Vector2i(value.get(&"x", 0), value.get(&"y", 0))
			TYPE_VECTOR3:
				return Vector3(value.get(&"x", 0), value.get(&"y", 0), value.get(&"z", 0))
			TYPE_VECTOR3I:
				return Vector3i(value.get(&"x", 0), value.get(&"y", 0), value.get(&"z", 0))
			TYPE_COLOR:
				return Color(value.get(&"r", 1), value.get(&"g", 1), value.get(&"b", 1), value.get(&"a", 1))
			TYPE_RECT2:
				return Rect2(value.get(&"x", 0), value.get(&"y", 0), value.get(&"width", 0), value.get(&"height", 0))

	return value

# =============================================================================
# .tscn as JSON tools
# =============================================================================
func parse_tscn_as_json(args: Dictionary) -> Dictionary:
	var scene_path: String = _ensure_res_path(str(args.get(&"scene_path", "")))
	if scene_path.strip_edges() == "res://":
		return {&"ok": false, &"error": "Missing 'scene_path'"}
	if not FileAccess.file_exists(scene_path):
		return {&"ok": false, &"error": "File not found: " + scene_path}

	var file := FileAccess.open(scene_path, FileAccess.READ)
	if file == null:
		return {&"ok": false, &"error": "Failed to read file: " + scene_path}
	var content := file.get_as_text()
	file.close()

	var document := _parse_tscn_document(content)
	return {
		&"ok": true,
		&"scene_path": scene_path,
		&"document": document,
	}

func write_tscn_from_json(args: Dictionary) -> Dictionary:
	var scene_path: String = _ensure_res_path(str(args.get(&"scene_path", "")))
	var document: Dictionary = args.get(&"document", {})
	if scene_path.strip_edges() == "res://":
		return {&"ok": false, &"error": "Missing 'scene_path'"}
	if document.is_empty():
		return {&"ok": false, &"error": "Missing 'document'"}

	var text := _build_tscn_text(document)
	var file := FileAccess.open(scene_path, FileAccess.WRITE)
	if file == null:
		return {&"ok": false, &"error": "Failed to write file: " + scene_path}
	file.store_string(text)
	file.close()

	_refresh_and_reload(scene_path)

	return {
		&"ok": true,
		&"scene_path": scene_path,
		&"message": "Wrote .tscn from JSON document",
	}

func apply_tscn_json_patch(args: Dictionary) -> Dictionary:
	var scene_path: String = _ensure_res_path(str(args.get(&"scene_path", "")))
	var operations: Array = args.get(&"operations", [])

	if scene_path.strip_edges() == "res://":
		return {&"ok": false, &"error": "Missing 'scene_path'"}
	if operations.is_empty():
		return {&"ok": false, &"error": "Missing 'operations'"}

	var parse_result := parse_tscn_as_json({&"scene_path": scene_path})
	if not parse_result.get(&"ok", false):
		return parse_result

	var document: Dictionary = parse_result.get(&"document", {})
	var sections: Array = document.get(&"sections", [])
	var applied := 0

	for op_data: Variant in operations:
		if not (op_data is Dictionary):
			continue
		var op: Dictionary = op_data
		var op_name: String = str(op.get(&"op", ""))
		match op_name:
			"set_property":
				var indices := _find_section_indices(
					sections,
					str(op.get(&"section_type", "")),
					op.get(&"section_match", {})
				)
				var key: String = str(op.get(&"key", ""))
				var value: String = str(op.get(&"value", ""))
				for index: int in indices:
					var section: Dictionary = sections[index]
					var properties: Array = section.get(&"properties", [])
					var found := false
					for i: int in range(properties.size()):
						if str(properties[i].get(&"key", "")) == key:
							properties[i][&"value"] = value
							found = true
							break
					if not found:
						properties.append({&"key": key, &"value": value})
					section[&"properties"] = properties
					sections[index] = section
					applied += 1
			"delete_property":
				var indices := _find_section_indices(
					sections,
					str(op.get(&"section_type", "")),
					op.get(&"section_match", {})
				)
				var key: String = str(op.get(&"key", ""))
				for index: int in indices:
					var section: Dictionary = sections[index]
					var properties: Array = section.get(&"properties", [])
					var new_props: Array = []
					for prop: Dictionary in properties:
						if str(prop.get(&"key", "")) != key:
							new_props.append(prop)
					section[&"properties"] = new_props
					sections[index] = section
					applied += 1
			"add_section":
				var section: Dictionary = op.get(&"section", {})
				if not section.is_empty():
					sections.append(section)
					applied += 1
			"remove_section":
				var indices := _find_section_indices(
					sections,
					str(op.get(&"section_type", "")),
					op.get(&"section_match", {})
				)
				indices.sort()
				indices.reverse()
				for index: int in indices:
					sections.remove_at(index)
					applied += 1
			_:
				return {&"ok": false, &"error": "Unsupported patch op: " + op_name}

	document[&"sections"] = sections
	var write_result := write_tscn_from_json({&"scene_path": scene_path, &"document": document})
	if not write_result.get(&"ok", false):
		return write_result

	return {
		&"ok": true,
		&"scene_path": scene_path,
		&"applied_operations": applied,
		&"message": "Applied JSON patch operations to scene",
	}

func _parse_tscn_document(content: String) -> Dictionary:
	var lines := content.split("\n")
	var document := {&"sections": []}
	var current_section: Dictionary = {}

	for line: String in lines:
		var stripped := line.strip_edges()
		if stripped.begins_with("[") and stripped.ends_with("]"):
			if not current_section.is_empty():
				document[&"sections"].append(current_section)
			current_section = _parse_tscn_header(stripped)
			current_section[&"properties"] = []
			continue

		if current_section.is_empty():
			continue
		if stripped.is_empty() or stripped.begins_with(";"):
			continue

		var eq := line.find("=")
		if eq == -1:
			continue

		var key := line.substr(0, eq).strip_edges()
		var value := line.substr(eq + 1).strip_edges()
		current_section[&"properties"].append({&"key": key, &"value": value})

	if not current_section.is_empty():
		document[&"sections"].append(current_section)

	return document

func _parse_tscn_header(line: String) -> Dictionary:
	var body := line.substr(1, line.length() - 2).strip_edges()
	var first_space := body.find(" ")
	if first_space == -1:
		return {&"type": body, &"attributes": {}}

	var section_type := body.substr(0, first_space)
	var rest := body.substr(first_space + 1)
	var attributes: Dictionary = {}

	var regex := RegEx.new()
	regex.compile('(\\w+)=(("[^"]*")|([^\\s]+))')
	for match: RegExMatch in regex.search_all(rest):
		attributes[match.get_string(1)] = match.get_string(2)

	return {&"type": section_type, &"attributes": attributes}

func _build_tscn_text(document: Dictionary) -> String:
	var lines: PackedStringArray = []
	var sections: Array = document.get(&"sections", [])
	for section_data: Variant in sections:
		if not (section_data is Dictionary):
			continue
		var section: Dictionary = section_data
		var section_type: String = str(section.get(&"type", ""))
		if section_type.is_empty():
			continue

		var header_parts: PackedStringArray = [section_type]
		var attrs: Dictionary = section.get(&"attributes", {})
		var attr_keys: Array = attrs.keys()
		attr_keys.sort()
		for key: String in attr_keys:
			header_parts.append("%s=%s" % [key, str(attrs[key])])

		lines.append("[%s]" % " ".join(header_parts))

		var properties: Array = section.get(&"properties", [])
		for property_data: Variant in properties:
			if not (property_data is Dictionary):
				continue
			var prop: Dictionary = property_data
			lines.append("%s = %s" % [str(prop.get(&"key", "")), str(prop.get(&"value", ""))])

		lines.append("")

	return "\n".join(lines).strip_edges() + "\n"

func _find_section_indices(sections: Array, section_type: String, section_match: Dictionary) -> Array:
	var found: Array = []
	for i: int in range(sections.size()):
		if not (sections[i] is Dictionary):
			continue
		var section: Dictionary = sections[i]
		if not section_type.is_empty() and str(section.get(&"type", "")) != section_type:
			continue

		var attrs: Dictionary = section.get(&"attributes", {})
		var matches := true
		for key: String in section_match.keys():
			var a := str(attrs.get(key, "")).trim_prefix("\"").trim_suffix("\"")
			var b := str(section_match[key]).trim_prefix("\"").trim_suffix("\"")
			if a != b:
				matches = false
				break
		if matches:
			found.append(i)
	return found

# =============================================================================
# Advanced Operations
# =============================================================================

func list_nodes_in_scene(args: Dictionary) -> Dictionary:
	var scene_path: String = _ensure_res_path(str(args.get(&"scene_path", "")))
	if scene_path.strip_edges() == "res://":
		return {&"ok": false, &"error": "Missing 'scene_path' parameter"}

	var result = _load_scene(scene_path)
	var root: Node = result[0]
	var err: Dictionary = result[1]
	if not err.is_empty():
		return err

	var nodes := []
	var queue := [root]
	while not queue.is_empty():
		var curr: Node = queue.pop_front()
		var p: String = "." if curr == root else str(root.get_path_to(curr))

		var s: String = ""
		var scr = curr.get_script()
		if scr and scr.resource_path:
			s = scr.resource_path

		nodes.append({
			"name": curr.name,
			"path": p,
			"class": curr.get_class(),
			"script": s
		})
		for c in curr.get_children():
			queue.append(c)

	root.queue_free()
	return {&"ok": true, &"scene_path": scene_path, &"nodes": nodes}

func find_scene_by_name(args: Dictionary) -> Dictionary:
	var name: String = str(args.get(&"name", "")).to_lower()
	if name.is_empty():
		return {&"ok": false, &"error": "Missing 'name' parameter"}

	var results := []
	var stack := ["res://"]
	var max_depth := 20
	var depth := 0

	while stack.size() > 0 and depth < max_depth:
		var curr_stack = stack.duplicate()
		stack.clear()
		depth += 1
		for dir_path in curr_stack:
			if dir_path.begins_with("res://.godot"):
				continue
			var dir := DirAccess.open(dir_path)
			if dir:
				dir.list_dir_begin()
				var file := dir.get_next()
				while file != "":
					var full_path = dir_path.path_join(file)
					if dir.current_is_dir():
						if not file.begins_with("."):
							stack.append(full_path)
					elif file.ends_with(".tscn"):
						var bn = file.get_file().get_basename().to_lower()
						if name in bn or name in full_path.to_lower():
							results.append(full_path)
					file = dir.get_next()
				dir.list_dir_end()

	return {&"ok": true, &"matches": results}

func connect_signal(args: Dictionary) -> Dictionary:
	var scene_path: String = _ensure_res_path(str(args.get(&"scene_path", "")))
	var source_path: String = str(args.get(&"source_node", ""))
	var signal_name: String = str(args.get(&"signal_name", ""))
	var target_path: String = str(args.get(&"target_node", ""))
	var method_name: String = str(args.get(&"method_name", ""))

	if scene_path.strip_edges() == "res://": return {&"ok": false, &"error": "Missing scene_path"}
	if source_path.is_empty() or target_path.is_empty(): return {&"ok": false, &"error": "Missing node paths"}
	if signal_name.is_empty() or method_name.is_empty(): return {&"ok": false, &"error": "Missing signal or method"}

	var result = _load_scene(scene_path)
	var root: Node = result[0]
	var err: Dictionary = result[1]
	if not err.is_empty(): return err

	var src_node: Node = _find_node(root, source_path)
	var tgt_node: Node = _find_node(root, target_path)

	if not src_node:
		root.queue_free()
		return {&"ok": false, &"error": "Source node not found"}
	if not tgt_node:
		root.queue_free()
		return {&"ok": false, &"error": "Target node not found"}

	var err_code = src_node.connect(signal_name, Callable(tgt_node, method_name), CONNECT_PERSIST)
	if err_code != OK:
		root.queue_free()
		return {&"ok": false, &"error": "Failed to connect signal: " + str(err_code)}

	var save_err = _save_scene(root, scene_path)
	if not save_err.is_empty(): return save_err

	return {&"ok": true, &"message": "Connected %s.%s to %s.%s" % [source_path, signal_name, target_path, method_name]}

func instantiate_packed_scene(args: Dictionary) -> Dictionary:
	var scene_path: String = _ensure_res_path(str(args.get(&"scene_path", "")))
	var parent_path: String = str(args.get(&"parent_path", ""))
	var packed_scene_path: String = _ensure_res_path(str(args.get(&"packed_scene_path", "")))
	var node_name: String = str(args.get(&"name", ""))

	if scene_path.strip_edges() == "res://" or packed_scene_path.strip_edges() == "res://":
		return {&"ok": false, &"error": "Missing scene_path or packed_scene_path"}

	if not FileAccess.file_exists(packed_scene_path):
		return {&"ok": false, &"error": "Packed scene does not exist: " + packed_scene_path}

	var packed = load(packed_scene_path) as PackedScene
	if not packed:
		return {&"ok": false, &"error": "Failed to load packed scene: " + packed_scene_path}

	var result = _load_scene(scene_path)
	var root: Node = result[0]
	var err: Dictionary = result[1]
	if not err.is_empty(): return err

	var parent_node: Node = _find_node(root, parent_path)
	if not parent_node:
		root.queue_free()
		return {&"ok": false, &"error": "Parent node not found at path: " + parent_path}

	var child: Node = packed.instantiate()
	if not child:
		root.queue_free()
		return {&"ok": false, &"error": "Failed to instantiate packed scene"}

	if not node_name.is_empty():
		child.name = node_name

	parent_node.add_child(child)
	# IMPORTANT: New node must be owned by the scene root in order to be saved.
	child.owner = root
	# also need to set owner for children of the instantiated scene if they were not packed
	# wait, inner children of a packed scene belong to the packed scene, Godot handles them fine.

	var save_err = _save_scene(root, scene_path)
	if not save_err.is_empty(): return save_err

	return {&"ok": true, &"message": "Instantiated " + packed_scene_path + " under " + parent_path, &"node_name": child.name}

func list_signals(args: Dictionary) -> Dictionary:
	var scene_path: String = _ensure_res_path(str(args.get(&"scene_path", "")))
	var node_path: String = str(args.get(&"node_path", ""))

	if scene_path.strip_edges() == "res://":
		return {&"ok": false, &"error": "Missing 'scene_path'"}

	var result = _load_scene(scene_path)
	var root: Node = result[0]
	var err: Dictionary = result[1]
	if not err.is_empty(): return err

	var node: Node = _find_node(root, node_path)
	if not node:
		root.queue_free()
		return {&"ok": false, &"error": "Node not found"}

	var sig_dicts = node.get_signal_list()
	var signals := []
	for s in sig_dicts:
		var s_name: String = str(s.get("name", ""))
		var args_list: Array = s.get("args", [])
		var arg_h = []
		for a in args_list:
			arg_h.append(str(a.get("name", "")) + ":" + str(a.get("type", 0)))
		signals.append({"name": s_name, "args": arg_h})

	root.queue_free()
	return {&"ok": true, &"node_path": node_path, &"signals": signals}
