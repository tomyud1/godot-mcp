@tool
extends Node
class_name SceneTools
## Scene operation tools for MCP.
## Handles: create_scene, read_scene, add_node, instance_scene, remove_node,
##          modify_node_property, rename_node, move_node, attach_script, detach_script,
##          set_collision_shape, set_sprite_texture, set_mesh, set_material,
##          get_node_spatial_info, measure_node_distance, snap_node_to_grid

const VariantCodec = preload("res://addons/godot_mcp/utils/variant_codec.gd")

const _SKIP_PROPS: Dictionary[String, bool] = {
	"script": true, "owner": true,
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
		return [null, {&"ok": false, &"error": "Scene does not exist: " + scene_path}]

	var packed = load(scene_path) as PackedScene
	if not packed:
		return [null, {&"ok": false, &"error": "Failed to load scene: " + scene_path}]

	var root = _instantiate_packed_scene_for_edit(packed)
	if not root:
		return [null, {&"ok": false, &"error": "Failed to instantiate scene"}]

	return [root, {}]

func _instantiate_packed_scene_for_edit(packed: PackedScene, as_instance: bool = false) -> Node:
	if not packed:
		return null

	if not Engine.is_editor_hint():
		return packed.instantiate()

	if as_instance:
		return packed.instantiate(PackedScene.GEN_EDIT_STATE_INSTANCE)

	var state = packed.get_state()
	if state and state.get_base_scene_state() != null:
		return packed.instantiate(PackedScene.GEN_EDIT_STATE_MAIN_INHERITED)

	return packed.instantiate(PackedScene.GEN_EDIT_STATE_MAIN)

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
	return VariantCodec.parse_value(value)

func _set_node_properties(node: Node, properties: Dictionary) -> void:
	for prop_name: String in properties:
		var prop_value = _parse_value(properties[prop_name])
		node.set(prop_name, prop_value)

func _serialize_value(value: Variant) -> Variant:
	return VariantCodec.serialize_value(value)

# =============================================================================
# create_scene
# =============================================================================
func create_scene(args: Dictionary) -> Dictionary:
	var scene_path: String = _ensure_res_path(str(args.get(&"scene_path", "")))
	var root_node_name: String = str(args.get(&"root_node_name", "Node"))
	var root_node_type: String = str(args.get(&"root_node_type", ""))
	var nodes: Array = args.get(&"nodes", [])
	var attach_script_path: String = str(args.get(&"attach_script", ""))

	if scene_path.strip_edges() == "res://":
		return {&"ok": false, &"error": "Missing 'scene_path' parameter"}
	if root_node_type.strip_edges().is_empty():
		return {&"ok": false, &"error": "Missing 'root_node_type' parameter"}
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
		if typeof(node_data) != TYPE_DICTIONARY:
			root.queue_free()
			return {&"ok": false, &"error": "Every entry in 'nodes' must be a Dictionary; got %s" % type_string(typeof(node_data))}
		var created_pair := _create_node_recursive(node_data, root, root)
		if created_pair[1] != "":
			root.queue_free()
			return {&"ok": false, &"error": "create_scene: %s" % String(created_pair[1])}
		if created_pair[0] != null:
			node_count += _count_nodes(created_pair[0])

	var err := _save_scene(root, scene_path)
	if not err.is_empty():
		return err

	return {&"ok": true, &"path": scene_path, &"root_type": root_node_type, &"child_count": node_count,
		&"message": "Scene created at " + scene_path}

## Known child-spec keys. Anything else is a typo (common agent mistake: using
## parent_path, class, kind, etc. in a child block). We reject unknown keys so
## the bug surfaces loudly rather than defaulting to a generic Node.
const _CHILD_SPEC_KEYS: PackedStringArray = [
	"name", "node_name", "type", "node_type", "script",
	"properties", "children", "groups",
]

## Recursively create a child node. Returns [Node_or_null, error_string].
## Accepts EITHER {name, type} OR {node_name, node_type} so the child spec can
## use the same key names as add_node's top-level arguments. Unknown keys
## trigger an error so malformed specs are caught instead of silently
## producing a generic Node with the wrong name.
func _create_node_recursive(data: Dictionary, parent: Node, owner: Node) -> Array:
	# Validate keys first so typos fail loudly instead of silently.
	for key in data.keys():
		var key_str: String = str(key)
		if not _CHILD_SPEC_KEYS.has(key_str):
			return [null, "Unknown child spec key '%s'. Valid keys: %s" % [key_str, ", ".join(_CHILD_SPEC_KEYS)]]

	var n_name: String = str(data.get(&"node_name", data.get(&"name", "")))
	var n_type: String = str(data.get(&"node_type", data.get(&"type", "")))
	var n_script: String = str(data.get(&"script", ""))
	var props: Dictionary = data.get(&"properties", {})
	var children: Array = data.get(&"children", [])
	var groups: Array = data.get(&"groups", [])

	if n_type.is_empty():
		return [null, "Child spec missing 'node_type' (or 'type')"]
	if not ClassDB.class_exists(n_type):
		return [null, "Unknown node type in child spec: %s" % n_type]
	var node: Node = ClassDB.instantiate(n_type) as Node
	if not node:
		return [null, "Failed to instantiate node of type: %s" % n_type]

	if not n_name.is_empty():
		node.name = n_name
	_set_node_properties(node, props)

	if not n_script.is_empty():
		var s = load(n_script)
		if s:
			node.set_script(s)
		else:
			node.free()
			return [null, "Failed to load script for child '%s': %s" % [n_name, n_script]]

	for g in groups:
		var gname := str(g)
		if not gname.is_empty():
			node.add_to_group(gname, true)

	parent.add_child(node, true)
	node.owner = owner

	for child_data: Variant in children:
		if typeof(child_data) != TYPE_DICTIONARY:
			return [null, "Every entry in 'children' must be a Dictionary; got %s" % type_string(typeof(child_data))]
		var sub := _create_node_recursive(child_data, node, owner)
		if sub[1] != "":
			return sub
	return [node, ""]

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

	if scene_path.strip_edges() == "res://":
		return {&"ok": false, &"error": "Missing 'scene_path' parameter"}

	var result := _load_scene(scene_path)
	if not result[1].is_empty():
		return result[1]

	var root: Node = result[0]
	var structure = _build_node_structure(root, include_properties)
	root.queue_free()

	return {&"ok": true, &"scene_path": scene_path, &"root": structure}

func _build_node_structure(node: Node, include_props: bool, path: String = ".") -> Dictionary:
	const PROPERTIES: PackedStringArray = ["position", "rotation", "scale", "size", "offset", "visible",
			"modulate", "z_index", "text", "collision_layer", "collision_mask", "mass"]
	var data := {&"name": str(node.name), &"type": node.get_class(), &"path": path, &"children": []}
	if not node.scene_file_path.is_empty() and path != ".":
		data[&"instance"] = node.scene_file_path
	var script = node.get_script()
	if script:
		data[&"script"] = script.resource_path

	if include_props:
		var props := {}
		for prop_name: String in PROPERTIES:
			var val = node.get(prop_name)
			if val != null:
				props[prop_name] = _serialize_value(val)
		if not props.is_empty():
			data[&"properties"] = props

	for child: Node in node.get_children():
		var child_path = child.name if path == "." else path + "/" + child.name
		data[&"children"].append(_build_node_structure(child, include_props, child_path))
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
	var script_path: String = str(args.get(&"script", ""))
	var children: Array = args.get(&"children", [])
	var groups: Array = args.get(&"groups", [])

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

	if not script_path.is_empty():
		var s := load(script_path)
		if s:
			new_node.set_script(s)
		else:
			root.queue_free()
			return {&"ok": false, &"error": "Failed to load script: " + script_path}

	for g in groups:
		var gname := str(g)
		if not gname.is_empty():
			new_node.add_to_group(gname, true)

	parent.add_child(new_node, true)
	new_node.owner = root

	var added_descendants: int = 0
	for child_data: Variant in children:
		if typeof(child_data) != TYPE_DICTIONARY:
			root.queue_free()
			return {&"ok": false, &"error": "Every entry in 'children' must be a Dictionary; got %s" % type_string(typeof(child_data))}
		var created_pair := _create_node_recursive(child_data, new_node, root)
		if created_pair[1] != "":
			root.queue_free()
			return {&"ok": false, &"error": "add_node: %s" % String(created_pair[1])}
		if created_pair[0] != null:
			added_descendants += _count_nodes(created_pair[0])

	var err := _save_scene(root, scene_path)
	if not err.is_empty():
		return err

	return {&"ok": true, &"scene_path": scene_path, &"node_name": new_node.name, &"node_type": node_type,
		&"descendants_added": added_descendants,
		&"message": "Added %s (%s) to scene%s" % [new_node.name, node_type,
			(" with %d descendant(s)" % added_descendants) if added_descendants > 0 else ""]}

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
# modify_node_property
# =============================================================================
func modify_node_property(args: Dictionary) -> Dictionary:
	var scene_path: String = _ensure_res_path(str(args.get(&"scene_path", "")))
	var node_path: String = str(args.get(&"node_path", "."))
	var property_name: String = str(args.get(&"property_name", ""))
	var value = args.get(&"value")

	if scene_path.strip_edges() == "res://":
		return {&"ok": false, &"error": "Missing 'scene_path'"}
	if property_name.strip_edges().is_empty():
		return {&"ok": false, &"error": "Missing 'property_name'"}
	if value == null:
		return {&"ok": false, &"error": "Missing 'value'"}

	# Refuse to set the script via modify_node_property: it rewrites the .tscn
	# but doesn't update the editor's live node, which makes connect_signal
	# fail later. attach_script does both.
	if property_name == "script":
		return {&"ok": false, &"error": "Use attach_script to set or change a node's script. modify_node_property only edits the .tscn on disk, leaving the editor's in-memory node without the script (which breaks connect_signal and other tools that validate against the live node)."}

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
		return {&"ok": false, &"error": "Property '%s' expects a Resource. Use specialized tools (set_collision_shape, set_sprite_texture, set_mesh, set_material) instead." % property_name}

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
		shape.set("size", _parse_value(shape_params[&"size"]))

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
		# Canonical name for "load whatever texture is at this path".
		# "ImageTexture" is kept as a deprecated alias for backward compat.
		"FromPath", "ImageTexture":
			var tex_path: String = str(texture_params.get(&"path", ""))
			if tex_path.is_empty():
				root.queue_free()
				return {&"ok": false, &"error": "Missing 'path' in texture_params for %s" % texture_type}
			texture = load(tex_path)
			if not texture:
				root.queue_free()
				return {&"ok": false, &"error": "Failed to load texture: " + tex_path}

		# Real ImageTexture from raw image data on disk (use when you need
		# an in-memory ImageTexture rather than a CompressedTexture2D).
		"NewImageTexture":
			var src_path: String = str(texture_params.get(&"path", ""))
			if src_path.is_empty():
				root.queue_free()
				return {&"ok": false, &"error": "Missing 'path' in texture_params for NewImageTexture"}
			var img := Image.new()
			var ierr := img.load(ProjectSettings.globalize_path(src_path))
			if ierr != OK:
				root.queue_free()
				return {&"ok": false, &"error": "Image.load failed for %s (err=%d %s)" % [src_path, ierr, error_string(ierr)]}
			texture = ImageTexture.create_from_image(img)

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

	# Report what the texture actually decodes to. For texture_type "FromPath"
	# (or its alias "ImageTexture"), Godot's importer typically returns a
	# CompressedTexture2D, NOT an ImageTexture — surfacing this here saves the
	# agent a round trip via get_resource_info.
	var resolved_class: String = texture.get_class() if texture else ""
	var tex_path: String = ""
	if texture_type in ["FromPath", "ImageTexture", "NewImageTexture"]:
		tex_path = str(texture_params.get(&"path", ""))

	return {
		&"ok": true,
		&"texture_type": texture_type,
		&"texture_class": resolved_class,
		&"texture_path": tex_path,
		&"width": texture.get_width() if texture else 0,
		&"height": texture.get_height() if texture else 0,
		&"message": "Set %s (%s) on node '%s'" % [texture_type, resolved_class, node_path],
	}

# =============================================================================
# instance_scene
# =============================================================================
func instance_scene(args: Dictionary) -> Dictionary:
	var scene_path: String = _ensure_res_path(str(args.get(&"scene_path", "")))
	var instance_path: String = _ensure_res_path(str(args.get(&"instance_path", "")))
	var node_name: String = str(args.get(&"node_name", ""))
	var parent_path: String = str(args.get(&"parent_path", "."))
	var properties: Dictionary = args.get(&"properties", {})

	if scene_path.strip_edges() == "res://":
		return {&"ok": false, &"error": "Missing 'scene_path'"}
	if instance_path.strip_edges() == "res://":
		return {&"ok": false, &"error": "Missing 'instance_path'"}

	if scene_path == instance_path:
		return {&"ok": false, &"error": "Cannot instance a scene inside itself (circular reference): " + instance_path}

	var instance_packed = load(instance_path) as PackedScene
	if not instance_packed:
		return {&"ok": false, &"error": "Failed to load scene: " + instance_path}

	var result := _load_scene(scene_path)
	if not result[1].is_empty():
		return result[1]

	var root: Node = result[0]
	var parent = _find_node(root, parent_path)
	if not parent:
		root.queue_free()
		return {&"ok": false, &"error": "Parent node not found: " + parent_path}

	var instance = _instantiate_packed_scene_for_edit(instance_packed, true)
	if not instance:
		root.queue_free()
		return {&"ok": false, &"error": "Failed to instantiate scene: " + instance_path}

	if not node_name.strip_edges().is_empty():
		instance.name = node_name

	_set_node_properties(instance, properties)

	parent.add_child(instance, true)
	instance.owner = root

	var actual_name: String = instance.name

	var err := _save_scene(root, scene_path)
	if not err.is_empty():
		return err

	return {&"ok": true, &"scene_path": scene_path, &"instance_path": instance_path,
		&"node_name": actual_name, &"node_type": instance.get_class(),
		&"message": "Instanced '%s' as '%s' in scene" % [instance_path, actual_name]}

# =============================================================================
# set_mesh
# =============================================================================
func set_mesh(args: Dictionary) -> Dictionary:
	var scene_path: String = _ensure_res_path(str(args.get(&"scene_path", "")))
	var node_path: String = str(args.get(&"node_path", "."))
	var mesh_type: String = str(args.get(&"mesh_type", ""))
	var mesh_params: Dictionary = args.get(&"mesh_params", {})

	if scene_path.strip_edges() == "res://":
		return {&"ok": false, &"error": "Missing 'scene_path'"}
	if mesh_type.strip_edges().is_empty():
		return {&"ok": false, &"error": "Missing 'mesh_type'"}

	var result := _load_scene(scene_path)
	if not result[1].is_empty():
		return result[1]

	var root: Node = result[0]
	var target = _find_node(root, node_path)
	if not target:
		root.queue_free()
		return {&"ok": false, &"error": "Node not found: " + node_path}

	if not (target is MeshInstance3D):
		root.queue_free()
		return {&"ok": false, &"error": "Node '%s' is %s, expected MeshInstance3D" % [node_path, target.get_class()]}

	var mesh: Mesh = null

	if mesh_type == "file":
		var file_path: String = str(mesh_params.get(&"path", ""))
		if file_path.is_empty():
			root.queue_free()
			return {&"ok": false, &"error": "Missing 'path' in mesh_params for file type"}
		var loaded = load(file_path)
		if not loaded or not (loaded is Mesh):
			root.queue_free()
			return {&"ok": false, &"error": "Failed to load mesh resource (or not a Mesh): " + file_path}
		mesh = loaded
	else:
		if not ClassDB.class_exists(mesh_type):
			root.queue_free()
			return {&"ok": false, &"error": "Unknown mesh type: " + mesh_type}
		if not ClassDB.can_instantiate(mesh_type):
			root.queue_free()
			return {&"ok": false, &"error": "Cannot instantiate mesh type: " + mesh_type}

		var instance = ClassDB.instantiate(mesh_type)
		if not (instance is PrimitiveMesh):
			if instance is Node:
				instance.queue_free()
			root.queue_free()
			return {&"ok": false, &"error": "'%s' is not a PrimitiveMesh type" % mesh_type}
		mesh = instance

		if mesh_params.has(&"radius"):
			mesh.set("radius", float(mesh_params[&"radius"]))
		if mesh_params.has(&"height"):
			mesh.set("height", float(mesh_params[&"height"]))
		if mesh_params.has(&"top_radius"):
			mesh.set("top_radius", float(mesh_params[&"top_radius"]))
		if mesh_params.has(&"bottom_radius"):
			mesh.set("bottom_radius", float(mesh_params[&"bottom_radius"]))
		if mesh_params.has(&"inner_radius"):
			mesh.set("inner_radius", float(mesh_params[&"inner_radius"]))
		if mesh_params.has(&"outer_radius"):
			mesh.set("outer_radius", float(mesh_params[&"outer_radius"]))
		if mesh_params.has(&"radial_segments"):
			mesh.set("radial_segments", int(mesh_params[&"radial_segments"]))
		if mesh_params.has(&"rings"):
			mesh.set("rings", int(mesh_params[&"rings"]))
		if mesh_params.has(&"left_to_right"):
			mesh.set("left_to_right", float(mesh_params[&"left_to_right"]))
		if mesh_params.has(&"subdivide_width"):
			mesh.set("subdivide_width", int(mesh_params[&"subdivide_width"]))
		if mesh_params.has(&"subdivide_height"):
			mesh.set("subdivide_height", int(mesh_params[&"subdivide_height"]))
		if mesh_params.has(&"subdivide_depth"):
			mesh.set("subdivide_depth", int(mesh_params[&"subdivide_depth"]))
		if mesh_params.has(&"text"):
			mesh.set("text", str(mesh_params[&"text"]))
		if mesh_params.has(&"font_size"):
			mesh.set("font_size", int(mesh_params[&"font_size"]))
		if mesh_params.has(&"depth"):
			mesh.set("depth", float(mesh_params[&"depth"]))
		if mesh_params.has(&"size"):
			mesh.set("size", _parse_value(mesh_params[&"size"]))

	target.set("mesh", mesh)

	var err := _save_scene(root, scene_path)
	if not err.is_empty():
		return err

	return {&"ok": true, &"message": "Set %s on node '%s'" % [mesh_type, node_path]}

# =============================================================================
# set_material
# =============================================================================
func set_material(args: Dictionary) -> Dictionary:
	var scene_path: String = _ensure_res_path(str(args.get(&"scene_path", "")))
	var node_path: String = str(args.get(&"node_path", "."))
	var material_type: String = str(args.get(&"material_type", ""))
	var material_params: Dictionary = args.get(&"material_params", {})
	var surface_index: int = int(args.get(&"surface_index", -1))

	if scene_path.strip_edges() == "res://":
		return {&"ok": false, &"error": "Missing 'scene_path'"}
	if material_type.strip_edges().is_empty():
		return {&"ok": false, &"error": "Missing 'material_type'"}

	var result := _load_scene(scene_path)
	if not result[1].is_empty():
		return result[1]

	var root: Node = result[0]
	var target = _find_node(root, node_path)
	if not target:
		root.queue_free()
		return {&"ok": false, &"error": "Node not found: " + node_path}

	var material: Material = null

	if material_type == "file":
		var file_path: String = str(material_params.get(&"path", ""))
		if file_path.is_empty():
			root.queue_free()
			return {&"ok": false, &"error": "Missing 'path' in material_params for file type"}
		var loaded = load(file_path)
		if not loaded or not (loaded is Material):
			root.queue_free()
			return {&"ok": false, &"error": "Failed to load material (or not a Material): " + file_path}
		material = loaded

	elif material_type == "StandardMaterial3D":
		material = StandardMaterial3D.new()

		if material_params.has(&"albedo_color"):
			material.albedo_color = _parse_value(material_params[&"albedo_color"])
		if material_params.has(&"metallic"):
			material.metallic = float(material_params[&"metallic"])
		if material_params.has(&"roughness"):
			material.roughness = float(material_params[&"roughness"])
		if material_params.has(&"emission"):
			var parsed_emission = _parse_value(material_params[&"emission"])
			if parsed_emission is Color:
				material.emission = parsed_emission
				material.emission_enabled = true
		if material_params.has(&"emission_energy"):
			material.emission_energy_multiplier = float(material_params[&"emission_energy"])
		if material_params.has(&"transparency"):
			material.transparency = int(material_params[&"transparency"])

	else:
		root.queue_free()
		return {&"ok": false, &"error": "Unknown material type: '%s'. Use 'StandardMaterial3D' or 'file'." % material_type}

	var apply_mode: String
	if target is MeshInstance3D:
		if surface_index >= 0:
			target.set_surface_override_material(surface_index, material)
			apply_mode = "surface_override_material[%d]" % surface_index
		else:
			target.material_override = material
			apply_mode = "material_override"
	elif target is CSGPrimitive3D:
		target.set("material", material)
		apply_mode = "material"
	elif target is GeometryInstance3D:
		target.material_override = material
		apply_mode = "material_override"
	else:
		root.queue_free()
		return {&"ok": false, &"error": "Node '%s' (%s) does not support material assignment" % [node_path, target.get_class()]}

	var err := _save_scene(root, scene_path)
	if not err.is_empty():
		return err

	return {&"ok": true, &"message": "Set %s on node '%s' via %s" % [material_type, node_path, apply_mode]}

# =============================================================================
# get_node_spatial_info
# =============================================================================
func get_node_spatial_info(args: Dictionary) -> Dictionary:
	var scene_path: String = _ensure_res_path(str(args.get(&"scene_path", "")))
	var node_path: String = str(args.get(&"node_path", "."))
	var include_bounds: bool = bool(args.get(&"include_bounds", true))

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
	if not (target is Node3D):
		root.queue_free()
		return {&"ok": false, &"error": "Node '%s' (%s) is not a Node3D" % [node_path, target.get_class()]}

	var target_3d: Node3D = target
	var local_transform: Transform3D = target_3d.transform
	var global_transform: Transform3D = _get_node3d_global_transform(target_3d)

	var info := {
		&"ok": true,
		&"scene_path": scene_path,
		&"node_path": node_path,
		&"node_name": target_3d.name,
		&"node_type": target_3d.get_class(),
		&"local_position": _serialize_value(local_transform.origin),
		&"global_position": _serialize_value(global_transform.origin),
		&"local_scale": _serialize_value(local_transform.basis.get_scale()),
		&"global_scale": _serialize_value(global_transform.basis.get_scale()),
		&"local_rotation_quaternion": _serialize_value(local_transform.basis.orthonormalized().get_rotation_quaternion()),
		&"global_rotation_quaternion": _serialize_value(global_transform.basis.orthonormalized().get_rotation_quaternion()),
	}

	if include_bounds:
		var subtree_bounds = _get_node_global_aabb(target_3d)
		if subtree_bounds is AABB:
			info[&"global_aabb"] = _serialize_value(subtree_bounds)
			info[&"global_aabb_center"] = _serialize_value(subtree_bounds.position + (subtree_bounds.size * 0.5))
			info[&"global_aabb_size"] = _serialize_value(subtree_bounds.size)
			info[&"has_bounds"] = true
		else:
			info[&"has_bounds"] = false

		if target_3d is VisualInstance3D:
			var visual_target: VisualInstance3D = target_3d
			var local_aabb: AABB = visual_target.get_aabb()
			info[&"local_aabb"] = _serialize_value(local_aabb)

	root.queue_free()
	return info

func _get_node3d_global_transform(node: Node3D) -> Transform3D:
	var current: Transform3D = node.transform
	if node.top_level:
		return current
	var parent := node.get_parent_node_3d()
	while parent:
		current = parent.transform * current
		parent = parent.get_parent_node_3d()
	return current

func _get_node_global_aabb(node: Node) -> Variant:
	var has_bounds := false
	var merged_bounds := AABB()

	if node is VisualInstance3D:
		var visual: VisualInstance3D = node
		var visual_transform := _get_node3d_global_transform(visual)
		merged_bounds = _transform_aabb(visual.get_aabb(), visual_transform)
		has_bounds = true

	for child: Node in node.get_children():
		var child_bounds = _get_node_global_aabb(child)
		if child_bounds is AABB:
			if has_bounds:
				merged_bounds = merged_bounds.merge(child_bounds)
			else:
				merged_bounds = child_bounds
				has_bounds = true

	return merged_bounds if has_bounds else null

func _transform_aabb(aabb: AABB, transform: Transform3D) -> AABB:
	var corners: Array[Vector3] = [
		aabb.position,
		aabb.position + Vector3(aabb.size.x, 0, 0),
		aabb.position + Vector3(0, aabb.size.y, 0),
		aabb.position + Vector3(0, 0, aabb.size.z),
		aabb.position + Vector3(aabb.size.x, aabb.size.y, 0),
		aabb.position + Vector3(aabb.size.x, 0, aabb.size.z),
		aabb.position + Vector3(0, aabb.size.y, aabb.size.z),
		aabb.position + aabb.size,
	]

	var first: Vector3 = transform * corners[0]
	var min_corner := first
	var max_corner := first

	for i: int in range(1, corners.size()):
		var point: Vector3 = transform * corners[i]
		min_corner = Vector3(
			minf(min_corner.x, point.x),
			minf(min_corner.y, point.y),
			minf(min_corner.z, point.z)
		)
		max_corner = Vector3(
			maxf(max_corner.x, point.x),
			maxf(max_corner.y, point.y),
			maxf(max_corner.z, point.z)
		)

	return AABB(min_corner, max_corner - min_corner)

# =============================================================================
# measure_node_distance
# =============================================================================
func measure_node_distance(args: Dictionary) -> Dictionary:
	var scene_path: String = _ensure_res_path(str(args.get(&"scene_path", "")))
	var from_node_path: String = str(args.get(&"from_node_path", ""))
	var to_node_path: String = str(args.get(&"to_node_path", ""))

	if scene_path.strip_edges() == "res://":
		return {&"ok": false, &"error": "Missing 'scene_path'"}
	if from_node_path.strip_edges().is_empty():
		return {&"ok": false, &"error": "Missing 'from_node_path'"}
	if to_node_path.strip_edges().is_empty():
		return {&"ok": false, &"error": "Missing 'to_node_path'"}

	var result := _load_scene(scene_path)
	if not result[1].is_empty():
		return result[1]

	var root: Node = result[0]
	var from_node = _find_node(root, from_node_path)
	var to_node = _find_node(root, to_node_path)

	if not from_node:
		root.queue_free()
		return {&"ok": false, &"error": "Node not found: " + from_node_path}
	if not to_node:
		root.queue_free()
		return {&"ok": false, &"error": "Node not found: " + to_node_path}
	if not (from_node is Node3D):
		root.queue_free()
		return {&"ok": false, &"error": "Node '%s' (%s) is not a Node3D" % [from_node_path, from_node.get_class()]}
	if not (to_node is Node3D):
		root.queue_free()
		return {&"ok": false, &"error": "Node '%s' (%s) is not a Node3D" % [to_node_path, to_node.get_class()]}

	var from_position: Vector3 = _get_node3d_global_transform(from_node).origin
	var to_position: Vector3 = _get_node3d_global_transform(to_node).origin
	var delta: Vector3 = to_position - from_position

	root.queue_free()

	return {
		&"ok": true,
		&"scene_path": scene_path,
		&"from_node_path": from_node_path,
		&"to_node_path": to_node_path,
		&"from_global_position": _serialize_value(from_position),
		&"to_global_position": _serialize_value(to_position),
		&"delta": _serialize_value(delta),
		&"distance": delta.length(),
		&"horizontal_distance": Vector2(delta.x, delta.z).length(),
	}

# =============================================================================
# snap_node_to_grid
# =============================================================================
func snap_node_to_grid(args: Dictionary) -> Dictionary:
	var scene_path: String = _ensure_res_path(str(args.get(&"scene_path", "")))
	var node_path: String = str(args.get(&"node_path", "."))
	var space: String = str(args.get(&"space", "global")).to_lower()
	var axes: PackedStringArray = _normalized_axes(args.get(&"axes", ["x", "y", "z"]))
	var grid_value = _grid_size_to_vector3(args.get(&"grid_size", 1.0))

	if scene_path.strip_edges() == "res://":
		return {&"ok": false, &"error": "Missing 'scene_path'"}
	if grid_value == null:
		return {&"ok": false, &"error": "Invalid 'grid_size'. Use a positive number or {x,y,z} object."}
	if axes.is_empty():
		return {&"ok": false, &"error": "Missing or invalid 'axes'. Use any of: x, y, z."}
	if space not in ["local", "global"]:
		return {&"ok": false, &"error": "Invalid 'space'. Use 'local' or 'global'."}

	var result := _load_scene(scene_path)
	if not result[1].is_empty():
		return result[1]

	var root: Node = result[0]
	var target = _find_node(root, node_path)
	if not target:
		root.queue_free()
		return {&"ok": false, &"error": "Node not found: " + node_path}
	if not (target is Node3D):
		root.queue_free()
		return {&"ok": false, &"error": "Node '%s' (%s) is not a Node3D" % [node_path, target.get_class()]}

	var target_3d: Node3D = target
	var grid: Vector3 = grid_value
	var old_local_transform: Transform3D = target_3d.transform
	var old_global_transform: Transform3D = _get_node3d_global_transform(target_3d)

	if space == "local":
		var new_local_transform := old_local_transform
		new_local_transform.origin = _snap_position_to_grid(old_local_transform.origin, grid, axes)
		target_3d.transform = new_local_transform
	else:
		var new_global_transform := old_global_transform
		new_global_transform.origin = _snap_position_to_grid(old_global_transform.origin, grid, axes)
		_set_node3d_global_transform(target_3d, new_global_transform)

	var new_local_position: Vector3 = target_3d.transform.origin
	var new_global_position: Vector3 = _get_node3d_global_transform(target_3d).origin

	var err := _save_scene(root, scene_path)
	if not err.is_empty():
		return err

	return {
		&"ok": true,
		&"scene_path": scene_path,
		&"node_path": node_path,
		&"space": space,
		&"axes": Array(axes),
		&"grid_size": _serialize_value(grid),
		&"old_local_position": _serialize_value(old_local_transform.origin),
		&"new_local_position": _serialize_value(new_local_position),
		&"old_global_position": _serialize_value(old_global_transform.origin),
		&"new_global_position": _serialize_value(new_global_position),
		&"message": "Snapped '%s' to %s grid" % [node_path, space]
	}

func _set_node3d_global_transform(node: Node3D, global_transform: Transform3D) -> void:
	if node.top_level:
		node.transform = global_transform
		return
	var parent := node.get_parent_node_3d()
	if parent:
		node.transform = _get_node3d_global_transform(parent).affine_inverse() * global_transform
	else:
		node.transform = global_transform

func _grid_size_to_vector3(grid_size: Variant) -> Variant:
	var parsed = _parse_value(grid_size)
	if parsed is Vector3:
		if parsed.x <= 0.0 or parsed.y <= 0.0 or parsed.z <= 0.0:
			return null
		return parsed
	if typeof(parsed) == TYPE_FLOAT or typeof(parsed) == TYPE_INT:
		var scalar: float = float(parsed)
		if scalar <= 0.0:
			return null
		return Vector3(scalar, scalar, scalar)
	return null

func _normalized_axes(axes_value: Variant) -> PackedStringArray:
	var normalized := PackedStringArray()
	if axes_value is Array:
		for axis_value in axes_value:
			var axis: String = str(axis_value).to_lower()
			if axis in ["x", "y", "z"] and axis not in normalized:
				normalized.append(axis)
	return normalized

func _snap_position_to_grid(position: Vector3, grid: Vector3, axes: PackedStringArray) -> Vector3:
	var snapped := position
	if "x" in axes:
		snapped.x = round(position.x / grid.x) * grid.x
	if "y" in axes:
		snapped.y = round(position.y / grid.y) * grid.y
	if "z" in axes:
		snapped.z = round(position.z / grid.z) * grid.z
	return snapped

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
	return VariantCodec.parse_typed_value(value, type_hint)

# =============================================================================
# set_node_properties (bulk)
# =============================================================================
## Apply multiple properties to a node in a single load/save cycle.
## Non-atomic: properties that exist and validate are applied; the rest are
## reported as failures. The scene is only saved if at least one applied.
func set_node_properties(args: Dictionary) -> Dictionary:
	var scene_path: String = _ensure_res_path(str(args.get(&"scene_path", "")))
	var node_path: String = str(args.get(&"node_path", "."))
	var properties: Dictionary = args.get(&"properties", {})

	if scene_path.strip_edges() == "res://":
		return {&"ok": false, &"error": "Missing 'scene_path'"}
	if properties.is_empty():
		return {&"ok": false, &"error": "Missing or empty 'properties' dictionary"}

	var result := _load_scene(scene_path)
	if not result[1].is_empty():
		return result[1]

	var root: Node = result[0]
	var target := _find_node(root, node_path)
	if not target:
		root.queue_free()
		return {&"ok": false, &"error": "Node not found: " + node_path}

	# Build the set of valid property names once.
	var valid_props: Dictionary = {}
	for prop in target.get_property_list():
		valid_props[str(prop[&"name"])] = true

	var applied: Array = []
	var failed: Array = []

	for prop_name_v in properties.keys():
		var prop_name := str(prop_name_v)
		var raw_value = properties[prop_name_v]

		if not valid_props.has(prop_name):
			failed.append({&"property": prop_name, &"reason": "no such property on " + target.get_class()})
			continue

		var old_value = target.get(prop_name)
		var parsed = _parse_value(raw_value)

		if old_value is Resource and not (parsed is Resource):
			failed.append({&"property": prop_name, &"reason": "expects a Resource (use set_resource_property or specialized tool)"})
			continue

		target.set(prop_name, parsed)
		applied.append({
			&"property": prop_name,
			&"old": _serialize_value(old_value),
			&"new": _serialize_value(parsed),
		})

	if applied.is_empty():
		root.queue_free()
		return {
			&"ok": false,
			&"error": "No properties applied. See 'failed' for per-property reasons.",
			&"failed": failed,
		}

	var err := _save_scene(root, scene_path)
	if not err.is_empty():
		return err

	return {
		&"ok": true,
		&"scene_path": scene_path,
		&"node_path": node_path,
		&"applied": applied,
		&"failed": failed,
		&"message": "Applied %d/%d propert%s on %s" % [
			applied.size(), applied.size() + failed.size(),
			"y" if (applied.size() + failed.size()) == 1 else "ies",
			node_path,
		],
	}

# =============================================================================
# Node groups (scene-file editing)
# =============================================================================
## Set the FULL group membership of a node. `mode` controls behavior:
##   "replace" (default) — node ends up in exactly the listed groups
##   "add"     — listed groups added; existing groups untouched
##   "remove"  — listed groups removed; others untouched
func set_node_groups(args: Dictionary) -> Dictionary:
	var scene_path: String = _ensure_res_path(str(args.get(&"scene_path", "")))
	var node_path: String = str(args.get(&"node_path", "."))
	var groups_arg: Array = args.get(&"groups", [])
	var mode: String = str(args.get(&"mode", "replace"))

	if scene_path.strip_edges() == "res://":
		return {&"ok": false, &"error": "Missing 'scene_path'"}

	var result := _load_scene(scene_path)
	if not result[1].is_empty():
		return result[1]

	var root: Node = result[0]
	var target := _find_node(root, node_path)
	if not target:
		root.queue_free()
		return {&"ok": false, &"error": "Node not found: " + node_path}

	var requested: Array[String] = []
	for g in groups_arg:
		var s := str(g).strip_edges()
		if not s.is_empty():
			requested.append(s)

	var current_groups := target.get_groups()

	match mode:
		"replace":
			for g in current_groups:
				target.remove_from_group(g)
			for g in requested:
				target.add_to_group(g, true)
		"add":
			for g in requested:
				target.add_to_group(g, true)
		"remove":
			for g in requested:
				target.remove_from_group(g)
		_:
			root.queue_free()
			return {&"ok": false, &"error": "Invalid 'mode': " + mode + ". Use 'replace', 'add', or 'remove'."}

	var err := _save_scene(root, scene_path)
	if not err.is_empty():
		return err

	# Re-load to read the persisted groups.
	var verify := _load_scene(scene_path)
	var resulting_groups: Array = []
	if verify[1].is_empty():
		var v_target := _find_node(verify[0], node_path)
		if v_target:
			resulting_groups = v_target.get_groups()
		verify[0].queue_free()

	return {
		&"ok": true,
		&"scene_path": scene_path,
		&"node_path": node_path,
		&"mode": mode,
		&"groups": resulting_groups,
		&"message": "Node '%s' groups (%s): %s" % [node_path, mode, str(resulting_groups)],
	}

func get_node_groups(args: Dictionary) -> Dictionary:
	var scene_path: String = _ensure_res_path(str(args.get(&"scene_path", "")))
	var node_path: String = str(args.get(&"node_path", "."))

	if scene_path.strip_edges() == "res://":
		return {&"ok": false, &"error": "Missing 'scene_path'"}

	var result := _load_scene(scene_path)
	if not result[1].is_empty():
		return result[1]

	var root: Node = result[0]
	var target := _find_node(root, node_path)
	if not target:
		root.queue_free()
		return {&"ok": false, &"error": "Node not found: " + node_path}

	var groups := target.get_groups()
	root.queue_free()

	return {
		&"ok": true,
		&"scene_path": scene_path,
		&"node_path": node_path,
		&"groups": groups,
	}

func find_nodes_in_group(args: Dictionary) -> Dictionary:
	var scene_path: String = _ensure_res_path(str(args.get(&"scene_path", "")))
	var group_name: String = str(args.get(&"group", ""))

	if scene_path.strip_edges() == "res://":
		return {&"ok": false, &"error": "Missing 'scene_path'"}
	if group_name.strip_edges().is_empty():
		return {&"ok": false, &"error": "Missing 'group'"}

	var result := _load_scene(scene_path)
	if not result[1].is_empty():
		return result[1]

	var root: Node = result[0]
	var matches: Array = []
	_collect_nodes_in_group(root, group_name, ".", matches)
	root.queue_free()

	return {
		&"ok": true,
		&"scene_path": scene_path,
		&"group": group_name,
		&"matches": matches,
		&"count": matches.size(),
	}

func _collect_nodes_in_group(node: Node, group_name: String, path: String, matches: Array) -> void:
	if node.is_in_group(group_name):
		matches.append({&"path": path, &"name": str(node.name), &"type": node.get_class()})
	for child in node.get_children():
		var child_path = child.name if path == "." else path + "/" + child.name
		_collect_nodes_in_group(child, group_name, child_path, matches)

# =============================================================================
# Generic resource property tools
# =============================================================================
## Set a property on a node's existing Resource property (or on a sub-resource of one).
## Example uses: tweak a SphereShape3D radius without re-creating the shape;
## change a StandardMaterial3D albedo_color on an existing material.
##
## resource_path: dot/slash path from the node to the resource.
##   "shape"                       → the node's shape resource
##   "material/albedo_color_texture" → texture sub-resource of the node's material
func set_resource_property(args: Dictionary) -> Dictionary:
	var scene_path: String = _ensure_res_path(str(args.get(&"scene_path", "")))
	var node_path: String = str(args.get(&"node_path", "."))
	var resource_path: String = str(args.get(&"resource_path", ""))
	var property_name: String = str(args.get(&"property_name", ""))
	var value = args.get(&"value")

	if scene_path.strip_edges() == "res://":
		return {&"ok": false, &"error": "Missing 'scene_path'"}
	if property_name.strip_edges().is_empty():
		return {&"ok": false, &"error": "Missing 'property_name'"}

	var result := _load_scene(scene_path)
	if not result[1].is_empty():
		return result[1]

	var root: Node = result[0]
	var target := _find_node(root, node_path)
	if not target:
		root.queue_free()
		return {&"ok": false, &"error": "Node not found: " + node_path}

	# Walk to the resource.
	var resource: Object = target
	if not resource_path.is_empty():
		for segment in resource_path.split("/", false):
			if resource == null:
				root.queue_free()
				return {&"ok": false, &"error": "Resource path broke at segment '%s' (got null)" % segment}
			resource = resource.get(segment)
		if resource == null:
			root.queue_free()
			return {&"ok": false, &"error": "Resource at '%s' is null on node '%s'" % [resource_path, node_path]}
		if not (resource is Resource):
			root.queue_free()
			return {&"ok": false, &"error": "'%s' is not a Resource (got %s)" % [resource_path, typeof(resource)]}

	var has_prop := false
	for p in resource.get_property_list():
		if str(p[&"name"]) == property_name:
			has_prop = true
			break
	if not has_prop:
		root.queue_free()
		return {&"ok": false, &"error": "Property '%s' not found on %s" % [property_name, resource.get_class()]}

	var old_value = resource.get(property_name)
	var parsed = _parse_value(value)
	resource.set(property_name, parsed)

	var err := _save_scene(root, scene_path)
	if not err.is_empty():
		return err

	return {
		&"ok": true,
		&"scene_path": scene_path,
		&"node_path": node_path,
		&"resource_path": resource_path,
		&"property_name": property_name,
		&"old_value": _serialize_value(old_value),
		&"new_value": _serialize_value(parsed),
		&"message": "Set %s.%s.%s" % [node_path, resource_path, property_name],
	}

## Save a Resource currently held by a node (or sub-resource) to its own .tres file
## so it can be shared by other scenes / referenced by path. After saving, the
## node's property is reassigned to the loaded-from-disk version so future edits
## via this tool persist to that file.
func save_resource_to_file(args: Dictionary) -> Dictionary:
	var scene_path: String = _ensure_res_path(str(args.get(&"scene_path", "")))
	var node_path: String = str(args.get(&"node_path", "."))
	var resource_path: String = str(args.get(&"resource_path", ""))
	var save_to: String = _ensure_res_path(str(args.get(&"save_to", "")))

	if scene_path.strip_edges() == "res://":
		return {&"ok": false, &"error": "Missing 'scene_path'"}
	if save_to.strip_edges() == "res://":
		return {&"ok": false, &"error": "Missing 'save_to'"}

	var result := _load_scene(scene_path)
	if not result[1].is_empty():
		return result[1]

	var root: Node = result[0]
	var target := _find_node(root, node_path)
	if not target:
		root.queue_free()
		return {&"ok": false, &"error": "Node not found: " + node_path}

	# Walk to the resource. Track parent for re-assignment.
	var parent_obj: Object = target
	var parent_prop: String = ""
	var resource: Object = target
	if resource_path.is_empty():
		root.queue_free()
		return {&"ok": false, &"error": "Missing 'resource_path' (e.g., 'shape', 'material', 'mesh')"}

	var segments := Array(resource_path.split("/", false))
	for i in range(segments.size()):
		var seg = str(segments[i])
		if i == segments.size() - 1:
			parent_obj = resource
			parent_prop = seg
		resource = resource.get(seg)
		if resource == null:
			root.queue_free()
			return {&"ok": false, &"error": "Resource walk broke at '%s'" % seg}

	if not (resource is Resource):
		root.queue_free()
		return {&"ok": false, &"error": "Target is not a Resource (got %s)" % typeof(resource)}

	# Ensure target dir exists.
	var dir := save_to.get_base_dir()
	if not DirAccess.dir_exists_absolute(dir):
		DirAccess.make_dir_recursive_absolute(dir)

	var save_err := ResourceSaver.save(resource, save_to)
	if save_err != OK:
		root.queue_free()
		return {&"ok": false, &"error": "ResourceSaver.save failed: %s (%d)" % [error_string(save_err), save_err]}

	var loaded := load(save_to)
	if loaded == null:
		root.queue_free()
		return {&"ok": false, &"error": "Saved but failed to reload from %s" % save_to}

	parent_obj.set(parent_prop, loaded)

	var serr := _save_scene(root, scene_path)
	if not serr.is_empty():
		return serr

	return {
		&"ok": true,
		&"scene_path": scene_path,
		&"node_path": node_path,
		&"resource_path": resource_path,
		&"saved_to": save_to,
		&"resource_class": loaded.get_class(),
		&"message": "Saved %s to %s and reattached to node" % [loaded.get_class(), save_to],
	}

# =============================================================================
# get_resource_info — generic resource introspection (any .tres/.res/.png/etc.)
# =============================================================================
## Inspect any resource on disk: type, dimensions for textures, vertex counts
## for meshes, key properties, and dependencies. Replaces ad-hoc image/PNG checks
## with a uniform tool that works for Resource, PackedScene, Texture2D, Mesh,
## AudioStream, Material, FontFile, Animation, Shader, etc.
func get_resource_info(args: Dictionary) -> Dictionary:
	# Two modes:
	#   1) path = "res://...resource"     → load from disk and inspect
	#   2) scene_path + node_path + resource_property → read a resource that
	#      lives ON a node inside a scene file (no need to save it as .tres
	#      first). Supports either or both of these arg shapes.
	var path: String = _ensure_res_path(str(args.get(&"path", "")))
	var scene_path: String = _ensure_res_path(str(args.get(&"scene_path", "")))
	var node_path: String = str(args.get(&"node_path", ""))
	var resource_property: String = str(args.get(&"resource_property", ""))

	var res: Resource = null
	var info: Dictionary = {&"ok": true}
	var loaded_root: Node = null

	if path.strip_edges() != "res://":
		if not FileAccess.file_exists(path):
			return {&"ok": false, &"error": "File not found: " + path}
		res = load(path)
		if res == null:
			return {&"ok": false, &"error": "Failed to load resource: " + path}
		info[&"path"] = path
		var f := FileAccess.open(path, FileAccess.READ)
		if f:
			info[&"file_size_bytes"] = f.get_length()
			f.close()
	elif scene_path.strip_edges() != "res://" and not node_path.is_empty() and not resource_property.is_empty():
		var sresult := _load_scene(scene_path)
		if not sresult[1].is_empty():
			return sresult[1]
		loaded_root = sresult[0]
		var target := _find_node(loaded_root, node_path)
		if not target:
			loaded_root.queue_free()
			return {&"ok": false, &"error": "Node not found: " + node_path}
		var prop_value = target.get(resource_property)
		if prop_value == null or not (prop_value is Resource):
			loaded_root.queue_free()
			return {&"ok": false, &"error": "Property '%s' on node '%s' is not a Resource (got %s)" % [resource_property, node_path, type_string(typeof(prop_value))]}
		res = prop_value
		info[&"scene_path"] = scene_path
		info[&"node_path"] = node_path
		info[&"resource_property"] = resource_property
	else:
		return {&"ok": false, &"error": "Provide either 'path' (resource on disk) or 'scene_path'+'node_path'+'resource_property' (resource attached to a node)."}

	info[&"class"] = res.get_class()
	info[&"resource_name"] = res.resource_name
	if res.resource_path:
		info[&"resource_path"] = res.resource_path

	# Type-specific extras.
	if res is Texture2D:
		var t: Texture2D = res
		info[&"width"] = t.get_width()
		info[&"height"] = t.get_height()
		info[&"has_alpha"] = t.has_alpha() if t.has_method("has_alpha") else null

	elif res is Mesh:
		var m: Mesh = res
		var surfaces: Array = []
		for i in range(m.get_surface_count()):
			var arr := m.surface_get_arrays(i)
			var verts: int = arr[Mesh.ARRAY_VERTEX].size() if arr and arr.size() > Mesh.ARRAY_VERTEX else 0
			surfaces.append({&"index": i, &"vertices": verts})
		info[&"surface_count"] = m.get_surface_count()
		info[&"surfaces"] = surfaces
		info[&"aabb"] = _serialize_value(m.get_aabb())

	elif res is AudioStream:
		var a: AudioStream = res
		info[&"length_seconds"] = a.get_length() if a.has_method("get_length") else null

	elif res is PackedScene:
		var ps: PackedScene = res
		var st := ps.get_state()
		info[&"node_count"] = st.get_node_count()

	elif res is Material:
		# Surface a few common Material properties.
		var keys := ["albedo_color", "metallic", "roughness", "emission", "shading_mode"]
		var mat_props := {}
		for k in keys:
			var v = res.get(k)
			if v != null:
				mat_props[k] = _serialize_value(v)
		info[&"properties"] = mat_props

	elif res is Animation:
		var anim: Animation = res
		info[&"length_seconds"] = anim.length
		info[&"track_count"] = anim.get_track_count()
		info[&"loop_mode"] = anim.loop_mode

	elif res is Shape2D or res is Shape3D:
		var keys2 := ["radius", "height", "size", "extents"]
		var sh_props := {}
		for k in keys2:
			var v = res.get(k)
			if v != null:
				sh_props[k] = _serialize_value(v)
		info[&"properties"] = sh_props

	# Dependencies (other resources this one references). Only meaningful for
	# resources actually on disk.
	var dep_path: String = path if path.strip_edges() != "res://" else (res.resource_path if res else "")
	if not dep_path.is_empty():
		var deps := ResourceLoader.get_dependencies(dep_path)
		if deps.size() > 0:
			info[&"dependencies"] = Array(deps)

	if loaded_root:
		loaded_root.queue_free()

	return info

# =============================================================================
# Signal connection tools (scene file source)
# =============================================================================
## List signal connections originating from a node in a scene file.
## For runtime queries on a live game, set source="runtime" (handled separately).
func list_signal_connections(args: Dictionary) -> Dictionary:
	var source: String = str(args.get(&"source", "scene_file"))
	if source != "scene_file":
		return {&"ok": false, &"error": "list_signal_connections source='%s' is handled by the runtime helper. Ensure your game is running and try again." % source}

	var scene_path: String = _ensure_res_path(str(args.get(&"scene_path", "")))
	var node_path: String = str(args.get(&"node_path", "."))
	var include_outgoing: bool = bool(args.get(&"include_outgoing", true))
	var include_incoming: bool = bool(args.get(&"include_incoming", true))

	if scene_path.strip_edges() == "res://":
		return {&"ok": false, &"error": "Missing 'scene_path'"}

	var result := _load_scene(scene_path)
	if not result[1].is_empty():
		return result[1]

	var root: Node = result[0]
	var target := _find_node(root, node_path)
	if not target:
		root.queue_free()
		return {&"ok": false, &"error": "Node not found: " + node_path}

	var outgoing: Array = []
	var incoming: Array = []

	if include_outgoing:
		for sig in target.get_signal_list():
			var sig_name := str(sig[&"name"])
			for conn in target.get_signal_connection_list(sig_name):
				outgoing.append(_serialize_connection(conn, root))

	if include_incoming:
		# Walk the whole scene and collect connections targeting our node.
		_collect_incoming(root, target, root, incoming)

	root.queue_free()

	return {
		&"ok": true,
		&"source": "scene_file",
		&"scene_path": scene_path,
		&"node_path": node_path,
		&"outgoing": outgoing,
		&"incoming": incoming,
		&"outgoing_count": outgoing.size(),
		&"incoming_count": incoming.size(),
	}

func _collect_incoming(node: Node, target: Node, root: Node, out: Array) -> void:
	for sig in node.get_signal_list():
		var sig_name := str(sig[&"name"])
		for conn in node.get_signal_connection_list(sig_name):
			var callable: Callable = conn[&"callable"]
			if callable.get_object() == target:
				out.append(_serialize_connection(conn, root))
	for child in node.get_children():
		_collect_incoming(child, target, root, out)

func _serialize_connection(conn: Dictionary, root: Node) -> Dictionary:
	var callable: Callable = conn[&"callable"]
	var src_obj = conn.get(&"source", null)
	var src_node = src_obj if src_obj is Node else null
	var dst_node = callable.get_object() if callable.get_object() is Node else null
	return {
		&"signal": str(conn.get(&"signal", "")) if conn.has(&"signal") else str(conn.get(&"name", "")),
		&"from_node": _node_path_str(src_node, root) if src_node else null,
		&"to_node": _node_path_str(dst_node, root) if dst_node else null,
		&"method": callable.get_method(),
		&"flags": int(conn.get(&"flags", 0)),
	}

func _node_path_str(node: Node, root: Node) -> String:
	if node == null:
		return ""
	if node == root:
		return "."
	return str(root.get_path_to(node))

## Add a signal connection between two nodes in a scene file.
func connect_signal(args: Dictionary) -> Dictionary:
	var scene_path: String = _ensure_res_path(str(args.get(&"scene_path", "")))
	var from_node: String = str(args.get(&"from_node", ""))
	var signal_name: String = str(args.get(&"signal", ""))
	var to_node: String = str(args.get(&"to_node", ""))
	var method: String = str(args.get(&"method", ""))
	var flags: int = int(args.get(&"flags", 0))

	if scene_path.strip_edges() == "res://":
		return {&"ok": false, &"error": "Missing 'scene_path'"}
	if from_node.is_empty() or signal_name.is_empty() or to_node.is_empty() or method.is_empty():
		return {&"ok": false, &"error": "from_node, signal, to_node, and method are all required"}

	var result := _load_scene(scene_path)
	if not result[1].is_empty():
		return result[1]

	var root: Node = result[0]
	var src := _find_node(root, from_node)
	var dst := _find_node(root, to_node)
	if not src:
		root.queue_free()
		return {&"ok": false, &"error": "from_node not found: " + from_node}
	if not dst:
		root.queue_free()
		return {&"ok": false, &"error": "to_node not found: " + to_node}
	if not src.has_signal(signal_name):
		root.queue_free()
		return {&"ok": false, &"error": "Signal '%s' not found on %s" % [signal_name, src.get_class()]}
	if not dst.has_method(method):
		root.queue_free()
		return {&"ok": false, &"error": "Method '%s' not found on %s. Make sure the target script defines it (and that the script was attached via attach_script so the editor's live node sees it)." % [method, dst.get_class()]}

	var callable := Callable(dst, method)
	if src.is_connected(signal_name, callable):
		root.queue_free()
		return {&"ok": true, &"already_connected": true,
			&"message": "Connection already exists; no change."}

	# CRITICAL: connections must be made with CONNECT_PERSIST (flag 8) or
	# PackedScene.pack() will strip them when we save. Force it on so the
	# caller can't silently end up with a runtime-only connection that
	# vanishes on save.
	var persist_flags: int = flags | Object.CONNECT_PERSIST
	var err := src.connect(signal_name, callable, persist_flags)
	if err != OK:
		root.queue_free()
		return {&"ok": false, &"error": "connect() returned %d (%s)" % [err, error_string(err)]}

	var serr := _save_scene(root, scene_path)
	if not serr.is_empty():
		return serr

	# Verify the connection actually landed in the .tscn by re-reading the
	# scene state. If it didn't, the save silently dropped it (usually
	# because the dst node is not an owned descendant of root) and we should
	# return a clear error rather than claim success.
	var persisted := _signal_is_persisted(scene_path, from_node, signal_name, to_node, method)
	if not persisted:
		return {&"ok": false, &"error": "connect() succeeded at runtime but the connection did not persist into the .tscn. Ensure the target node is part of the scene (not an external autoload) and that the script is attached via attach_script."}

	return {
		&"ok": true,
		&"scene_path": scene_path,
		&"from_node": from_node,
		&"signal": signal_name,
		&"to_node": to_node,
		&"method": method,
		&"flags": persist_flags,
		&"persisted": true,
		&"message": "Connected %s.%s -> %s.%s (written to .tscn)" % [from_node, signal_name, to_node, method],
	}

## Re-read the saved .tscn and confirm the [connection] is there. This catches
## the silent "pack stripped it" case.
func _signal_is_persisted(scene_path: String, from_node: String, signal_name: String, to_node: String, method: String) -> bool:
	# Force re-read from disk; the resource we just saved may still be cached
	# in memory from the in-editor loader.
	var packed := ResourceLoader.load(scene_path, "PackedScene", ResourceLoader.CACHE_MODE_IGNORE) as PackedScene
	if packed == null:
		return false
	var st := packed.get_state()
	var want_from := NodePath(from_node).get_concatenated_names()
	var want_to := NodePath(to_node).get_concatenated_names()
	for i in range(st.get_connection_count()):
		var src_path: NodePath = st.get_connection_source(i)
		var dst_path: NodePath = st.get_connection_target(i)
		var sig: StringName = st.get_connection_signal(i)
		var mth: StringName = st.get_connection_method(i)
		if String(sig) != signal_name or String(mth) != method:
			continue
		if src_path.get_concatenated_names() == want_from and dst_path.get_concatenated_names() == want_to:
			return true
	return false

func disconnect_signal(args: Dictionary) -> Dictionary:
	var scene_path: String = _ensure_res_path(str(args.get(&"scene_path", "")))
	var from_node: String = str(args.get(&"from_node", ""))
	var signal_name: String = str(args.get(&"signal", ""))
	var to_node: String = str(args.get(&"to_node", ""))
	var method: String = str(args.get(&"method", ""))

	if scene_path.strip_edges() == "res://":
		return {&"ok": false, &"error": "Missing 'scene_path'"}
	if from_node.is_empty() or signal_name.is_empty() or to_node.is_empty() or method.is_empty():
		return {&"ok": false, &"error": "from_node, signal, to_node, and method are all required"}

	var result := _load_scene(scene_path)
	if not result[1].is_empty():
		return result[1]

	var root: Node = result[0]
	var src := _find_node(root, from_node)
	var dst := _find_node(root, to_node)
	if not src or not dst:
		root.queue_free()
		return {&"ok": false, &"error": "from_node or to_node not found"}

	var callable := Callable(dst, method)
	if not src.is_connected(signal_name, callable):
		root.queue_free()
		return {&"ok": true, &"already_disconnected": true,
			&"message": "Connection did not exist; no change."}

	src.disconnect(signal_name, callable)

	var serr := _save_scene(root, scene_path)
	if not serr.is_empty():
		return serr

	return {
		&"ok": true,
		&"message": "Disconnected %s.%s -> %s.%s" % [from_node, signal_name, to_node, method],
	}
