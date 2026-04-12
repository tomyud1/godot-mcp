@tool
extends Node
class_name SceneTools
## Scene operation tools for MCP.
## Handles: create_scene, read_scene, add_node, remove_node, modify_node_property,
##          rename_node, move_node, attach_script, detach_script, set_collision_shape,
##          set_sprite_texture, set_mesh, set_material, instance_scene,
##          get_node_spatial_info, measure_node_distance, snap_node_to_grid,
##          place_node_relative

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

func _parse_typed_value(value, type_hint: int):
	return VariantCodec.parse_typed_value(value, type_hint)

func _get_node3d_global_transform(node: Node3D) -> Transform3D:
	var current: Transform3D = node.transform
	if node.top_level:
		return current
	var parent := node.get_parent_node_3d()
	while parent:
		current = parent.transform * current
		parent = parent.get_parent_node_3d()
	return current

func _set_node3d_global_transform(node: Node3D, global_transform: Transform3D) -> void:
	if node.top_level:
		node.transform = global_transform
		return

	var parent := node.get_parent_node_3d()
	if parent:
		node.transform = _get_node3d_global_transform(parent).affine_inverse() * global_transform
	else:
		node.transform = global_transform

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

func _merge_aabb(a: AABB, b: AABB) -> AABB:
	var min_corner := Vector3(
		minf(a.position.x, b.position.x),
		minf(a.position.y, b.position.y),
		minf(a.position.z, b.position.z)
	)
	var a_end: Vector3 = a.position + a.size
	var b_end: Vector3 = b.position + b.size
	var max_corner := Vector3(
		maxf(a_end.x, b_end.x),
		maxf(a_end.y, b_end.y),
		maxf(a_end.z, b_end.z)
	)
	return AABB(min_corner, max_corner - min_corner)

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
				merged_bounds = _merge_aabb(merged_bounds, child_bounds)
			else:
				merged_bounds = child_bounds
				has_bounds = true

	return merged_bounds if has_bounds else null

func _get_aabb_center(aabb: AABB) -> Vector3:
	return aabb.position + (aabb.size * 0.5)

func _offset_origin_to_aabb_min(origin: Vector3, aabb: AABB) -> Vector3:
	return origin - aabb.position

func _offset_origin_to_aabb_max(origin: Vector3, aabb: AABB) -> Vector3:
	return (aabb.position + aabb.size) - origin

func _offset_origin_to_aabb_center(origin: Vector3, aabb: AABB) -> Vector3:
	return _get_aabb_center(aabb) - origin

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
	if not node.scene_file_path.is_empty():
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
	parent.add_child(new_node, true)
	new_node.owner = root

	var err := _save_scene(root, scene_path)
	if not err.is_empty():
		return err

	return {&"ok": true, &"scene_path": scene_path, &"node_name": new_node.name, &"node_type": node_type,
		&"message": "Added %s (%s) to scene" % [new_node.name, node_type]}

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

	# Guard against direct circular instancing (A instancing itself)
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

	# Set name if provided, otherwise keep the instanced scene's root name
	if not node_name.strip_edges().is_empty():
		instance.name = node_name

	# Apply property overrides (e.g., position, rotation, scale)
	_set_node_properties(instance, properties)

	# Add to tree with readable names, then set owner to scene root only
	# Do NOT set owner on instance children — they belong to the instance's internal scene
	parent.add_child(instance, true)
	instance.owner = root

	# Capture actual name (may differ from requested if there was a conflict)
	var actual_name: String = instance.name

	var err := _save_scene(root, scene_path)
	if not err.is_empty():
		return err

	return {&"ok": true, &"scene_path": scene_path, &"instance_path": instance_path,
		&"node_name": actual_name, &"node_type": instance.get_class(),
		&"message": "Instanced '%s' as '%s' in scene" % [instance_path, actual_name]}

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

	# Apply material based on node type
	# Order matters: CSGPrimitive3D inherits GeometryInstance3D, so check it first
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
	var local_basis: Basis = local_transform.basis
	var global_basis: Basis = global_transform.basis

	var info := {
		&"ok": true,
		&"scene_path": scene_path,
		&"node_path": node_path,
		&"node_name": target_3d.name,
		&"node_type": target_3d.get_class(),
		&"instance_scene_path": target_3d.scene_file_path,
		&"local_transform": _serialize_value(local_transform),
		&"global_transform": _serialize_value(global_transform),
		&"local_position": _serialize_value(local_transform.origin),
		&"global_position": _serialize_value(global_transform.origin),
		&"local_scale": _serialize_value(local_basis.get_scale()),
		&"global_scale": _serialize_value(global_basis.get_scale()),
		&"local_rotation_quaternion": _serialize_value(local_basis.orthonormalized().get_rotation_quaternion()),
		&"global_rotation_quaternion": _serialize_value(global_basis.orthonormalized().get_rotation_quaternion()),
	}

	if include_bounds:
		var subtree_bounds = _get_node_global_aabb(target_3d)
		if subtree_bounds is AABB:
			info[&"global_aabb"] = _serialize_value(subtree_bounds)
			info[&"global_aabb_center"] = _serialize_value(_get_aabb_center(subtree_bounds))
			info[&"global_aabb_size"] = _serialize_value(subtree_bounds.size)
			info[&"has_bounds"] = true
		else:
			info[&"has_bounds"] = false

		if target_3d is VisualInstance3D:
			var visual_target: VisualInstance3D = target_3d
			var local_aabb: AABB = visual_target.get_aabb()
			info[&"local_aabb"] = _serialize_value(local_aabb)
			info[&"local_aabb_center"] = _serialize_value(_get_aabb_center(local_aabb))

	root.queue_free()
	return info

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

	var from_node_3d: Node3D = from_node
	var to_node_3d: Node3D = to_node
	var from_position: Vector3 = _get_node3d_global_transform(from_node_3d).origin
	var to_position: Vector3 = _get_node3d_global_transform(to_node_3d).origin
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

# =============================================================================
# place_node_relative
# =============================================================================
func place_node_relative(args: Dictionary) -> Dictionary:
	var scene_path: String = _ensure_res_path(str(args.get(&"scene_path", "")))
	var node_path: String = str(args.get(&"node_path", ""))
	var target_node_path: String = str(args.get(&"target_node_path", ""))
	var relation: String = str(args.get(&"relation", "on_top_of")).to_lower()
	var gap: float = float(args.get(&"gap", 0.0))
	var use_bounds: bool = bool(args.get(&"use_bounds", true))

	if scene_path.strip_edges() == "res://":
		return {&"ok": false, &"error": "Missing 'scene_path'"}
	if node_path.strip_edges().is_empty():
		return {&"ok": false, &"error": "Missing 'node_path'"}
	if target_node_path.strip_edges().is_empty():
		return {&"ok": false, &"error": "Missing 'target_node_path'"}
	if node_path == target_node_path:
		return {&"ok": false, &"error": "'node_path' and 'target_node_path' must differ"}
	if relation not in ["on_top_of", "below", "left_of", "right_of", "in_front_of", "behind", "centered"]:
		return {&"ok": false, &"error": "Invalid 'relation'. Use: on_top_of, below, left_of, right_of, in_front_of, behind, centered."}

	var result := _load_scene(scene_path)
	if not result[1].is_empty():
		return result[1]

	var root: Node = result[0]
	var moving = _find_node(root, node_path)
	var anchor = _find_node(root, target_node_path)

	if not moving:
		root.queue_free()
		return {&"ok": false, &"error": "Node not found: " + node_path}
	if not anchor:
		root.queue_free()
		return {&"ok": false, &"error": "Node not found: " + target_node_path}
	if not (moving is Node3D):
		root.queue_free()
		return {&"ok": false, &"error": "Node '%s' (%s) is not a Node3D" % [node_path, moving.get_class()]}
	if not (anchor is Node3D):
		root.queue_free()
		return {&"ok": false, &"error": "Node '%s' (%s) is not a Node3D" % [target_node_path, anchor.get_class()]}

	var moving_3d: Node3D = moving
	var anchor_3d: Node3D = anchor
	var moving_global_transform: Transform3D = _get_node3d_global_transform(moving_3d)
	var anchor_global_transform: Transform3D = _get_node3d_global_transform(anchor_3d)
	var new_origin: Vector3 = moving_global_transform.origin

	var moving_bounds = _get_node_global_aabb(moving_3d) if use_bounds else null
	var anchor_bounds = _get_node_global_aabb(anchor_3d) if use_bounds else null
	var bounds_used := moving_bounds is AABB and anchor_bounds is AABB

	if bounds_used:
		var moving_box: AABB = moving_bounds
		var anchor_box: AABB = anchor_bounds
		var anchor_center: Vector3 = _get_aabb_center(anchor_box)
		var moving_min_offset: Vector3 = _offset_origin_to_aabb_min(moving_global_transform.origin, moving_box)
		var moving_max_offset: Vector3 = _offset_origin_to_aabb_max(moving_global_transform.origin, moving_box)
		var moving_center_offset: Vector3 = _offset_origin_to_aabb_center(moving_global_transform.origin, moving_box)

		match relation:
			"centered":
				new_origin = anchor_center - moving_center_offset
			"on_top_of":
				new_origin.x = anchor_center.x - moving_center_offset.x
				new_origin.z = anchor_center.z - moving_center_offset.z
				new_origin.y = anchor_box.position.y + anchor_box.size.y + gap + moving_min_offset.y
			"below":
				new_origin.x = anchor_center.x - moving_center_offset.x
				new_origin.z = anchor_center.z - moving_center_offset.z
				new_origin.y = anchor_box.position.y - gap - moving_max_offset.y
			"left_of":
				new_origin.y = anchor_center.y - moving_center_offset.y
				new_origin.z = anchor_center.z - moving_center_offset.z
				new_origin.x = anchor_box.position.x - gap - moving_max_offset.x
			"right_of":
				new_origin.y = anchor_center.y - moving_center_offset.y
				new_origin.z = anchor_center.z - moving_center_offset.z
				new_origin.x = anchor_box.position.x + anchor_box.size.x + gap + moving_min_offset.x
			"in_front_of":
				new_origin.x = anchor_center.x - moving_center_offset.x
				new_origin.y = anchor_center.y - moving_center_offset.y
				new_origin.z = anchor_box.position.z - gap - moving_max_offset.z
			"behind":
				new_origin.x = anchor_center.x - moving_center_offset.x
				new_origin.y = anchor_center.y - moving_center_offset.y
				new_origin.z = anchor_box.position.z + anchor_box.size.z + gap + moving_min_offset.z
	else:
		match relation:
			"centered":
				new_origin = anchor_global_transform.origin
			"on_top_of":
				new_origin = Vector3(anchor_global_transform.origin.x, anchor_global_transform.origin.y + gap, anchor_global_transform.origin.z)
			"below":
				new_origin = Vector3(anchor_global_transform.origin.x, anchor_global_transform.origin.y - gap, anchor_global_transform.origin.z)
			"left_of":
				new_origin = Vector3(anchor_global_transform.origin.x - gap, anchor_global_transform.origin.y, anchor_global_transform.origin.z)
			"right_of":
				new_origin = Vector3(anchor_global_transform.origin.x + gap, anchor_global_transform.origin.y, anchor_global_transform.origin.z)
			"in_front_of":
				new_origin = Vector3(anchor_global_transform.origin.x, anchor_global_transform.origin.y, anchor_global_transform.origin.z - gap)
			"behind":
				new_origin = Vector3(anchor_global_transform.origin.x, anchor_global_transform.origin.y, anchor_global_transform.origin.z + gap)

	var placed_global_transform := moving_global_transform
	placed_global_transform.origin = new_origin
	_set_node3d_global_transform(moving_3d, placed_global_transform)

	var placed_global_position: Vector3 = _get_node3d_global_transform(moving_3d).origin
	var placed_bounds = _get_node_global_aabb(moving_3d) if use_bounds else null

	var err := _save_scene(root, scene_path)
	if not err.is_empty():
		return err

	var response := {
		&"ok": true,
		&"scene_path": scene_path,
		&"node_path": node_path,
		&"target_node_path": target_node_path,
		&"relation": relation,
		&"gap": gap,
		&"bounds_used": bounds_used,
		&"old_global_position": _serialize_value(moving_global_transform.origin),
		&"new_global_position": _serialize_value(placed_global_position),
		&"target_global_position": _serialize_value(anchor_global_transform.origin),
		&"message": "Placed '%s' %s '%s'" % [node_path, relation, target_node_path]
	}

	if placed_bounds is AABB:
		response[&"new_global_aabb"] = _serialize_value(placed_bounds)
		response[&"new_global_aabb_center"] = _serialize_value(_get_aabb_center(placed_bounds))

	return response

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
