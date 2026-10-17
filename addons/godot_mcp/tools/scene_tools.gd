@tool
extends Node
class_name SceneTools
## Scene operation tools for MCP.
## Handles: create_scene, read_scene, add_node, instance_scene, remove_node,
##          modify_node_property, rename_node, move_node, attach_script, detach_script,
##          set_collision_shape, set_sprite_texture, set_mesh, set_material,
##          get_node_spatial_info, measure_node_distance, snap_node_to_grid

const VariantCodec = preload("res://addons/godot_mcp/utils/variant_codec.gd")
const PropertyWriter = preload("res://addons/godot_mcp/utils/property_writer.gd")

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

# =============================================================================
# Building nodes from specs (create_scene `nodes`, add_node + `children`)
# =============================================================================
## Known node-spec keys. Anything else is a typo (common agent mistakes:
## parent_path, class, kind) and is reported instead of being ignored.
const _CHILD_SPEC_KEYS: PackedStringArray = [
	"name", "node_name", "type", "node_type", "script",
	"properties", "children", "groups",
]

## Build a node and its children from a spec, entirely in memory. No scene is
## loaded or saved here, so callers can gather every problem first and only
## touch the file when ctx.errors is empty.
##   ctx = {"errors": [], "adjusted": []}
## Errors are path-pointed ("children[2].properties.texture: ...").
## Returns the built node, or null when the node itself couldn't be created.
## On failure the caller frees whatever was returned.
func _build_node(spec: Dictionary, where: String, require_name: bool, ctx: Dictionary) -> Node:
	var errors: Array = ctx.errors
	var prefix := where + "." if not where.is_empty() else ""

	for key in spec.keys():
		if not _CHILD_SPEC_KEYS.has(str(key)):
			errors.append("%s: unknown key '%s'. Valid keys: %s" % [where if not where.is_empty() else "node", key, ", ".join(_CHILD_SPEC_KEYS)])

	var name_str := str(spec.get(&"node_name", spec.get(&"name", ""))).strip_edges()
	if require_name and name_str.is_empty():
		errors.append("%snode_name: required (non-empty string)" % prefix)

	var node: Node = null
	var type_str := str(spec.get(&"node_type", spec.get(&"type", ""))).strip_edges()
	if type_str.is_empty():
		errors.append("%snode_type: required (a Godot class name like Node2D, Sprite2D, CharacterBody2D, ...)" % prefix)
	elif not ClassDB.class_exists(type_str):
		errors.append("%snode_type: '%s' is not a Godot class%s (use classdb_query to check names)" % [prefix, type_str, _closest_class(type_str, "Node")])
	elif not ClassDB.is_parent_class(type_str, "Node"):
		errors.append("%snode_type: '%s' is not a node class" % [prefix, type_str])
	elif not ClassDB.can_instantiate(type_str):
		errors.append("%snode_type: '%s' is abstract; use a concrete subclass" % [prefix, type_str])
	else:
		node = ClassDB.instantiate(type_str)
		if not name_str.is_empty():
			node.name = name_str

	# Script before properties: @export'd variables only exist once the
	# script is attached.
	var script_path := str(spec.get(&"script", "")).strip_edges()
	if not script_path.is_empty():
		var script := _load_script_checked(script_path, prefix + "script", errors)
		if script != null and node != null:
			var base := str(script.get_instance_base_type())
			if not base.is_empty() and not ClassDB.is_parent_class(type_str, base):
				errors.append("%sscript: %s extends %s, so it can't be attached to a %s" % [prefix, script_path, base, type_str])
			else:
				node.set_script(script)

	var props_v: Variant = spec.get(&"properties", {})
	if props_v == null:
		props_v = {}
	if not (props_v is Dictionary):
		errors.append("%sproperties: must be an object, got %s" % [prefix, PropertyWriter.json_type(props_v)])
	elif node != null and not (props_v as Dictionary).is_empty():
		var r := PropertyWriter.write(node, props_v, prefix + "properties")
		errors.append_array(r.errors)
		ctx.adjusted.append_array(r.adjusted)

	var groups_v: Variant = spec.get(&"groups", [])
	if groups_v == null:
		groups_v = []
	if not (groups_v is Array or groups_v is PackedStringArray):
		errors.append("%sgroups: must be an array of strings, got %s" % [prefix, PropertyWriter.json_type(groups_v)])
	else:
		for g in groups_v:
			if not (g is String or g is StringName) or str(g).strip_edges().is_empty():
				errors.append("%sgroups: every entry must be a non-empty string, got %s" % [prefix, PropertyWriter.json_type(g)])
			elif node != null:
				node.add_to_group(str(g), true)

	var children_v: Variant = spec.get(&"children", [])
	if children_v == null:
		children_v = []
	if not (children_v is Array):
		errors.append("%schildren: must be an array, got %s" % [prefix, PropertyWriter.json_type(children_v)])
	else:
		for i in range((children_v as Array).size()):
			var child_where := "%schildren[%d]" % [prefix, i]
			var child_spec: Variant = children_v[i]
			if not (child_spec is Dictionary):
				errors.append("%s: must be an object, got %s" % [child_where, PropertyWriter.json_type(child_spec)])
				continue
			var child := _build_node(child_spec, child_where, false, ctx)
			if child == null:
				continue
			if node != null:
				node.add_child(child, true)
			else:
				child.free()
	return node


## Load a script for attaching, reporting why it can't be used.
func _load_script_checked(path: String, where: String, errors: Array) -> Script:
	if not path.begins_with("res://") and not path.begins_with("user://"):
		errors.append("%s: path must start with res:// or user:// (got '%s')" % [where, path])
		return null
	if not FileAccess.file_exists(path):
		errors.append("%s: file does not exist: '%s'" % [where, path])
		return null
	var loaded: Resource = load(path)
	if loaded == null:
		errors.append("%s: failed to load '%s' (parse error? check get_errors)" % [where, path])
		return null
	if not (loaded is Script):
		errors.append("%s: '%s' is not a script (it's a %s)" % [where, path, loaded.get_class()])
		return null
	return loaded


## " (did you mean 'X'?)" against classes that inherit `base`.
func _closest_class(name: String, base: String) -> String:
	var best := ""
	var best_score := 0.0
	for c in ClassDB.get_inheriters_from_class(base):
		var score := name.to_lower().similarity(str(c).to_lower())
		if score > best_score:
			best_score = score
			best = c
	return " (did you mean '%s'?)" % best if best_score >= 0.5 else ""


## Standard response when validation finds problems. Nothing was changed.
func _validation_failure(tool: String, errors: Array, hint: String = "") -> Dictionary:
	var out := {
		&"ok": false,
		&"error": "%s: %d problem(s) found; nothing was changed. %s" % [tool, errors.size(), "; ".join(errors.slice(0, 3))],
		&"validation_errors": errors,
	}
	if not hint.is_empty():
		out[&"hint"] = hint
	return out


const _PROPERTY_HINT := "Values are read according to each property's type. Resource properties (texture, shape, mesh, material, ...) take a file path \"res://...\", {\"type\": \"Resource\", \"path\": \"res://...\"}, or an inline resource like {\"type\": \"RectangleShape2D\", \"size\": {\"x\": 32, \"y\": 32}}. Edit a property of a held resource with a colon path, e.g. \"material:albedo_color\". Use get_scene_node_properties or classdb_query to look up property names and types."

func _serialize_value(value: Variant) -> Variant:
	return VariantCodec.serialize_value(value)

# =============================================================================
# create_scene
# =============================================================================
func create_scene(args: Dictionary) -> Dictionary:
	var scene_path: String = _ensure_res_path(str(args.get(&"scene_path", "")))
	var root_node_type: String = str(args.get(&"root_node_type", "")).strip_edges()
	var nodes_v: Variant = args.get(&"nodes", [])
	if nodes_v == null:
		nodes_v = []
	var attach_script_path: String = str(args.get(&"attach_script", "")).strip_edges()

	if scene_path.strip_edges() == "res://":
		return {&"ok": false, &"error": "Missing 'scene_path' parameter"}
	if root_node_type.is_empty():
		return {&"ok": false, &"error": "Missing 'root_node_type' parameter"}
	if not scene_path.ends_with(".tscn"):
		scene_path += ".tscn"
	if FileAccess.file_exists(scene_path):
		return {&"ok": false, &"error": "Scene already exists: " + scene_path}
	# Default root name comes from the file name: res://player_ship.tscn -> PlayerShip.
	var root_node_name: String = str(args.get(&"root_node_name", "")).strip_edges()
	if root_node_name.is_empty():
		root_node_name = scene_path.get_file().get_basename().to_pascal_case()

	# Build the whole tree in memory first. Every problem in the spec is
	# collected; the scene file is only written when there are none.
	var ctx := {"errors": [], "adjusted": []}
	var root_spec := {&"node_name": root_node_name, &"node_type": root_node_type, &"script": attach_script_path}
	var root := _build_node(root_spec, "", true, ctx)
	for i in range(ctx.errors.size()):
		# Root problems are reported against create_scene's own argument names.
		ctx.errors[i] = str(ctx.errors[i]).replace("node_type:", "root_node_type:").replace("node_name:", "root_node_name:").replace("script:", "attach_script:")
	if not (nodes_v is Array):
		ctx.errors.append("nodes: must be an array, got %s" % PropertyWriter.json_type(nodes_v))
	else:
		for i in range((nodes_v as Array).size()):
			var node_data: Variant = nodes_v[i]
			if not (node_data is Dictionary):
				ctx.errors.append("nodes[%d]: must be an object, got %s" % [i, PropertyWriter.json_type(node_data)])
				continue
			var child := _build_node(node_data, "nodes[%d]" % i, false, ctx)
			if child == null:
				continue
			if root != null:
				root.add_child(child, true)
			else:
				child.free()

	if not ctx.errors.is_empty():
		if root != null:
			root.free()
		return _validation_failure("create_scene", ctx.errors, _PROPERTY_HINT)

	for child: Node in root.get_children():
		_set_owner_recursive(child, root)

	var dir_path := scene_path.get_base_dir()
	if not DirAccess.dir_exists_absolute(dir_path):
		DirAccess.make_dir_recursive_absolute(dir_path)

	var node_count := _count_nodes(root) - 1
	var err := _save_scene(root, scene_path)
	if not err.is_empty():
		return err

	var out := {&"ok": true, &"path": scene_path, &"root_name": root_node_name, &"root_type": root_node_type,
		&"child_count": node_count, &"message": "Scene created at " + scene_path}
	_add_adjusted(out, ctx.adjusted)
	return out


## Attach "Godot adjusted these values" info to a success response.
func _add_adjusted(out: Dictionary, adjusted: Array) -> void:
	if adjusted.is_empty():
		return
	out[&"adjusted"] = adjusted
	out[&"warning"] = "Godot changed %d value(s) while setting them (clamped, wrapped or normalized). See 'adjusted' for requested vs stored." % adjusted.size()

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
	var parent_path: String = str(args.get(&"parent_path", "."))
	if scene_path.strip_edges() == "res://":
		return {&"ok": false, &"error": "Missing 'scene_path'"}

	# Build the node (and any children) in memory and validate everything
	# before the scene file is even loaded.
	var spec := {
		&"node_name": args.get(&"node_name", ""),
		&"node_type": args.get(&"node_type", ""),
		&"script": args.get(&"script", ""),
		&"properties": args.get(&"properties", {}),
		&"children": args.get(&"children", []),
		&"groups": args.get(&"groups", []),
	}
	var ctx := {"errors": [], "adjusted": []}
	var new_node := _build_node(spec, "", true, ctx)
	if not ctx.errors.is_empty():
		if new_node != null:
			new_node.free()
		return _validation_failure("add_node", ctx.errors, _PROPERTY_HINT)

	var result := _load_scene(scene_path)
	if not result[1].is_empty():
		new_node.free()
		return result[1]

	var root: Node = result[0]
	var parent = _find_node(root, parent_path)
	if not parent:
		new_node.free()
		root.queue_free()
		return {&"ok": false, &"error": "Parent node not found: " + parent_path}

	parent.add_child(new_node, true)
	_set_owner_recursive(new_node, root)

	var actual_name := str(new_node.name)
	var node_path := str(root.get_path_to(new_node))
	var node_type := new_node.get_class()
	var descendants := _count_nodes(new_node) - 1

	var err := _save_scene(root, scene_path)
	if not err.is_empty():
		return err

	var out := {&"ok": true, &"scene_path": scene_path, &"node_name": actual_name, &"node_path": node_path,
		&"node_type": node_type, &"descendants_added": descendants,
		&"message": "Added %s (%s) to scene%s" % [actual_name, node_type,
			(" with %d descendant(s)" % descendants) if descendants > 0 else ""]}
	_add_adjusted(out, ctx.adjusted)
	return out

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
## Load a scene, write properties on one node through PropertyWriter, and
## save only if every property was accepted. `props` is either a Dictionary
## or a Callable(target: Node) -> Dictionary that picks the properties once
## the node is known; the Callable may return {"__error": "..."} to refuse.
## Used by set_node_properties and every tool built on it.
func _write_scene_node(scene_path: String, node_path: String, props: Variant, tool: String) -> Dictionary:
	var result := _load_scene(scene_path)
	if not result[1].is_empty():
		return result[1]
	var root: Node = result[0]
	var target := _find_node(root, node_path)
	if not target:
		root.queue_free()
		return {&"ok": false, &"error": "Node not found: %s (paths are relative to the scene root; '.' is the root)" % node_path}

	var props_dict: Dictionary = props if props is Dictionary else {}
	if props is Callable:
		props_dict = (props as Callable).call(target)
		if props_dict.has("__error"):
			root.queue_free()
			return {&"ok": false, &"error": "%s: %s" % [tool, props_dict["__error"]]}

	var r := PropertyWriter.write(target, props_dict, "properties")
	if not r.ok:
		root.queue_free()
		return _validation_failure(tool, r.errors, _PROPERTY_HINT)

	var err := _save_scene(root, scene_path)
	if not err.is_empty():
		return err

	var out := {
		&"ok": true,
		&"scene_path": scene_path,
		&"node_path": node_path,
		&"applied": r.applied,
		&"message": "Set %d propert%s on %s" % [r.applied.size(), "y" if r.applied.size() == 1 else "ies", node_path],
	}
	_add_adjusted(out, r.adjusted)
	return out


## Kept for existing callers; set_node_properties does the same with one entry.
func modify_node_property(args: Dictionary) -> Dictionary:
	var scene_path: String = _ensure_res_path(str(args.get(&"scene_path", "")))
	var node_path: String = str(args.get(&"node_path", "."))
	var property_name: String = str(args.get(&"property_name", "")).strip_edges()
	if scene_path.strip_edges() == "res://":
		return {&"ok": false, &"error": "Missing 'scene_path'"}
	if property_name.is_empty():
		return {&"ok": false, &"error": "Missing 'property_name'"}
	if not args.has(&"value"):
		return {&"ok": false, &"error": "Missing 'value' (pass null to clear a resource property)"}
	var out := _write_scene_node(scene_path, node_path, {property_name: args[&"value"]}, "modify_node_property")
	if out.get(&"ok", false):
		var entry: Dictionary = out.applied[0]
		out[&"property_name"] = property_name
		out[&"old_value"] = entry.old
		out[&"new_value"] = entry.new
		out[&"message"] = "Set %s.%s" % [node_path, property_name]
	return out

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
## Kept for existing callers. Same as set_node_properties with
## {"shape": {"type": shape_type, ...shape_params}}.
func set_collision_shape(args: Dictionary) -> Dictionary:
	var scene_path: String = _ensure_res_path(str(args.get(&"scene_path", "")))
	var node_path: String = str(args.get(&"node_path", "."))
	var shape_type: String = str(args.get(&"shape_type", "")).strip_edges()
	var shape_params: Variant = args.get(&"shape_params", {})
	if scene_path.strip_edges() == "res://":
		return {&"ok": false, &"error": "Missing 'scene_path'"}
	if shape_type.is_empty():
		return {&"ok": false, &"error": "Missing 'shape_type'"}
	if shape_params == null:
		shape_params = {}
	if not (shape_params is Dictionary):
		return {&"ok": false, &"error": "'shape_params' must be an object"}
	var inline: Dictionary = (shape_params as Dictionary).duplicate()
	inline["type"] = shape_type
	var out := _write_scene_node(scene_path, node_path, {"shape": inline}, "set_collision_shape")
	if out.get(&"ok", false):
		out[&"message"] = "Set %s on node '%s'" % [shape_type, node_path]
	return out

# =============================================================================
# set_sprite_texture
# =============================================================================
## Kept for existing callers. Same as set_node_properties with
## {"texture": "res://..."} or an inline texture. Works on any node with a
## `texture` property (Sprite2D/3D, TextureRect, PointLight2D, particles, ...).
func set_sprite_texture(args: Dictionary) -> Dictionary:
	var scene_path: String = _ensure_res_path(str(args.get(&"scene_path", "")))
	var node_path: String = str(args.get(&"node_path", "."))
	var texture_type: String = str(args.get(&"texture_type", "")).strip_edges()
	var params_v: Variant = args.get(&"texture_params", {})
	if scene_path.strip_edges() == "res://":
		return {&"ok": false, &"error": "Missing 'scene_path'"}
	if texture_type.is_empty():
		return {&"ok": false, &"error": "Missing 'texture_type'"}
	if params_v == null:
		params_v = {}
	if not (params_v is Dictionary):
		return {&"ok": false, &"error": "'texture_params' must be an object"}
	var params: Dictionary = params_v

	var value: Variant
	var tex_path := ""
	match texture_type:
		"FromPath", "ImageTexture":
			tex_path = str(params.get(&"path", ""))
			if tex_path.is_empty():
				return {&"ok": false, &"error": "Missing 'path' in texture_params for %s" % texture_type}
			value = tex_path
		"NewImageTexture":
			# An in-memory ImageTexture built from the raw image file, rather
			# than the imported CompressedTexture2D that load() returns.
			tex_path = str(params.get(&"path", ""))
			if tex_path.is_empty():
				return {&"ok": false, &"error": "Missing 'path' in texture_params for NewImageTexture"}
			var img := Image.new()
			var ierr := img.load(ProjectSettings.globalize_path(tex_path))
			if ierr != OK:
				return {&"ok": false, &"error": "Image.load failed for %s (err=%d %s)" % [tex_path, ierr, error_string(ierr)]}
			value = ImageTexture.create_from_image(img)
		_:
			var inline: Dictionary = params.duplicate()
			inline["type"] = texture_type
			# Old defaults: these were always created at 64x64.
			match texture_type:
				"PlaceholderTexture2D":
					if not inline.has("size"):
						inline["size"] = {"x": 64, "y": 64}
				"GradientTexture2D", "NoiseTexture2D":
					if not inline.has("width"):
						inline["width"] = 64
					if not inline.has("height"):
						inline["height"] = 64
			value = inline

	var dec := PropertyWriter.decode(value, {"type": TYPE_OBJECT, "class_name": "Texture2D"}, null, "texture_params")
	if not dec.errors.is_empty():
		return _validation_failure("set_sprite_texture", dec.errors, _PROPERTY_HINT)
	var texture: Texture2D = dec.value

	var out := _write_scene_node(scene_path, node_path, {"texture": texture}, "set_sprite_texture")
	if out.get(&"ok", false):
		out[&"texture_type"] = texture_type
		out[&"texture_class"] = texture.get_class()
		out[&"texture_path"] = tex_path
		out[&"width"] = texture.get_width()
		out[&"height"] = texture.get_height()
		out[&"message"] = "Set %s (%s) on node '%s'" % [texture_type, texture.get_class(), node_path]
	return out

# =============================================================================
# instance_scene
# =============================================================================
func instance_scene(args: Dictionary) -> Dictionary:
	var scene_path: String = _ensure_res_path(str(args.get(&"scene_path", "")))
	var instance_path: String = _ensure_res_path(str(args.get(&"instance_path", "")))
	var node_name: String = str(args.get(&"node_name", ""))
	var parent_path: String = str(args.get(&"parent_path", "."))
	var properties_v: Variant = args.get(&"properties", {})

	if scene_path.strip_edges() == "res://":
		return {&"ok": false, &"error": "Missing 'scene_path'"}
	if instance_path.strip_edges() == "res://":
		return {&"ok": false, &"error": "Missing 'instance_path'"}
	if properties_v == null:
		properties_v = {}
	if not (properties_v is Dictionary):
		return {&"ok": false, &"error": "'properties' must be an object"}

	if scene_path == instance_path:
		return {&"ok": false, &"error": "Cannot instance a scene inside itself (circular reference): " + instance_path}

	var instance_packed = load(instance_path) as PackedScene
	if not instance_packed:
		return {&"ok": false, &"error": "Failed to load scene: " + instance_path}

	var instance = _instantiate_packed_scene_for_edit(instance_packed, true)
	if not instance:
		return {&"ok": false, &"error": "Failed to instantiate scene: " + instance_path}
	if not node_name.strip_edges().is_empty():
		instance.name = node_name

	# Property overrides are validated before the parent scene is touched.
	var r := PropertyWriter.write(instance, properties_v, "properties")
	if not r.ok:
		instance.free()
		return _validation_failure("instance_scene", r.errors, _PROPERTY_HINT)

	var result := _load_scene(scene_path)
	if not result[1].is_empty():
		instance.free()
		return result[1]

	var root: Node = result[0]
	var parent = _find_node(root, parent_path)
	if not parent:
		instance.free()
		root.queue_free()
		return {&"ok": false, &"error": "Parent node not found: " + parent_path}

	parent.add_child(instance, true)
	instance.owner = root

	var actual_name: String = instance.name
	var node_type: String = instance.get_class()

	var err := _save_scene(root, scene_path)
	if not err.is_empty():
		return err

	var out := {&"ok": true, &"scene_path": scene_path, &"instance_path": instance_path,
		&"node_name": actual_name, &"node_type": node_type,
		&"message": "Instanced '%s' as '%s' in scene" % [instance_path, actual_name]}
	_add_adjusted(out, r.adjusted)
	return out

# =============================================================================
# set_mesh
# =============================================================================
## Kept for existing callers. Same as set_node_properties with
## {"mesh": {"type": mesh_type, ...mesh_params}} or {"mesh": "res://..."}.
func set_mesh(args: Dictionary) -> Dictionary:
	var scene_path: String = _ensure_res_path(str(args.get(&"scene_path", "")))
	var node_path: String = str(args.get(&"node_path", "."))
	var mesh_type: String = str(args.get(&"mesh_type", "")).strip_edges()
	var params_v: Variant = args.get(&"mesh_params", {})
	if scene_path.strip_edges() == "res://":
		return {&"ok": false, &"error": "Missing 'scene_path'"}
	if mesh_type.is_empty():
		return {&"ok": false, &"error": "Missing 'mesh_type'"}
	if params_v == null:
		params_v = {}
	if not (params_v is Dictionary):
		return {&"ok": false, &"error": "'mesh_params' must be an object"}
	var params: Dictionary = params_v

	var value: Variant
	if mesh_type == "file":
		var file_path := str(params.get(&"path", ""))
		if file_path.is_empty():
			return {&"ok": false, &"error": "Missing 'path' in mesh_params for file type"}
		value = file_path
	else:
		var inline: Dictionary = params.duplicate()
		inline["type"] = mesh_type
		value = inline
	var out := _write_scene_node(scene_path, node_path, {"mesh": value}, "set_mesh")
	if out.get(&"ok", false):
		out[&"message"] = "Set %s on node '%s'" % [mesh_type, node_path]
	return out

# =============================================================================
# set_material
# =============================================================================
## Kept for existing callers. Picks the node's material slot
## (material_override, surface_material_override/<i>, or material) and
## assigns {"type": material_type, ...material_params} or a file.
func set_material(args: Dictionary) -> Dictionary:
	var scene_path: String = _ensure_res_path(str(args.get(&"scene_path", "")))
	var node_path: String = str(args.get(&"node_path", "."))
	var material_type: String = str(args.get(&"material_type", "")).strip_edges()
	var params_v: Variant = args.get(&"material_params", {})
	var surface_index: int = int(args.get(&"surface_index", -1))
	if scene_path.strip_edges() == "res://":
		return {&"ok": false, &"error": "Missing 'scene_path'"}
	if material_type.is_empty():
		return {&"ok": false, &"error": "Missing 'material_type'"}
	if params_v == null:
		params_v = {}
	if not (params_v is Dictionary):
		return {&"ok": false, &"error": "'material_params' must be an object"}
	var params: Dictionary = params_v

	var value: Variant
	if material_type == "file":
		var file_path := str(params.get(&"path", ""))
		if file_path.is_empty():
			return {&"ok": false, &"error": "Missing 'path' in material_params for file type"}
		value = file_path
	else:
		var inline: Dictionary = params.duplicate()
		# Short names this tool has always accepted.
		if inline.has("emission_energy") and not inline.has("emission_energy_multiplier"):
			inline["emission_energy_multiplier"] = inline["emission_energy"]
			inline.erase("emission_energy")
		if inline.has("emission") and not inline.has("emission_enabled"):
			inline["emission_enabled"] = true
		inline["type"] = material_type
		value = inline

	var slot := [""]
	var pick := func(target: Node) -> Dictionary:
		if target is MeshInstance3D and surface_index >= 0:
			slot[0] = "surface_material_override/%d" % surface_index
		elif target is CSGPrimitive3D or target is CanvasItem:
			slot[0] = "material"
		elif target is GeometryInstance3D:
			slot[0] = "material_override"
		else:
			return {"__error": "Node '%s' (%s) does not support material assignment" % [node_path, target.get_class()]}
		return {slot[0]: value}
	var out := _write_scene_node(scene_path, node_path, pick, "set_material")
	if out.get(&"ok", false):
		out[&"message"] = "Set %s on node '%s' via %s" % [material_type, node_path, slot[0]]
	return out

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
	"""Set one property on a node in a scene (visualizer inline editing).
	The value is read according to the property's type; value_type is
	accepted for older visualizer builds but no longer needed."""
	var scene_path: String = _ensure_res_path(str(args.get(&"scene_path", "")))
	var node_path: String = str(args.get(&"node_path", "."))
	var property_name: String = str(args.get(&"property_name", "")).strip_edges()
	if scene_path.strip_edges() == "res://":
		return {&"ok": false, &"error": "Missing 'scene_path'"}
	if property_name.is_empty():
		return {&"ok": false, &"error": "Missing 'property_name'"}
	var out := _write_scene_node(scene_path, node_path, {property_name: args.get(&"value")}, "set_scene_node_property")
	if out.get(&"ok", false):
		var entry: Dictionary = out.applied[0]
		out[&"property_name"] = property_name
		out[&"old_value"] = entry.old
		out[&"new_value"] = entry.new
		out[&"message"] = "Set %s.%s" % [node_path, property_name]
	return out

# =============================================================================
# set_node_properties (bulk, atomic)
# =============================================================================
## Set one or more properties on a node. All-or-nothing: every entry is
## validated and decoded by property type first, and the scene is saved only
## if every write was accepted. Supports resources by path or inline, and
## colon paths into held resources ("material:albedo_color").
func set_node_properties(args: Dictionary) -> Dictionary:
	var scene_path: String = _ensure_res_path(str(args.get(&"scene_path", "")))
	var node_path: String = str(args.get(&"node_path", "."))
	var properties_v: Variant = args.get(&"properties", {})
	if scene_path.strip_edges() == "res://":
		return {&"ok": false, &"error": "Missing 'scene_path'"}
	if not (properties_v is Dictionary) or (properties_v as Dictionary).is_empty():
		return {&"ok": false, &"error": "Missing or empty 'properties' object"}
	if scene_path.get_extension() in ["tres", "res"]:
		if node_path != "." and not node_path.is_empty():
			return {&"ok": false, &"error": "node_path doesn't apply to a resource file; omit it or pass \".\""}
		return _write_resource_file(scene_path, properties_v)
	return _write_scene_node(scene_path, node_path, properties_v, "set_node_properties")


## set_node_properties on a .tres/.res file: edit a shared resource (material,
## theme, shape, custom Resource) in place and save it. Undo snapshots the file
## like a scene.
func _write_resource_file(path: String, props: Dictionary) -> Dictionary:
	if not ResourceLoader.exists(path):
		return {&"ok": false, &"error": "Resource does not exist: " + path}
	var res: Resource = load(path)
	if res == null:
		return {&"ok": false, &"error": "Failed to load resource: " + path}
	var r := PropertyWriter.write(res, props, "properties")
	if not r.ok:
		# Writes may have partially applied to the cached instance; reload it
		# from disk so the editor doesn't keep half-changed state.
		ResourceLoader.load(path, "", ResourceLoader.CACHE_MODE_REPLACE)
		return _validation_failure("set_node_properties", r.errors, _PROPERTY_HINT)
	var err := ResourceSaver.save(res, path)
	if err != OK:
		return {&"ok": false, &"error": "Failed to save %s: %s" % [path, error_string(err)]}
	_refresh_filesystem()
	var out := {
		&"ok": true,
		&"scene_path": path,
		&"resource_class": res.get_class(),
		&"applied": r.applied,
		&"message": "Set %d propert%s on %s" % [r.applied.size(), "y" if r.applied.size() == 1 else "ies", path],
	}
	_add_adjusted(out, r.adjusted)
	return out

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

# =============================================================================
# find_nodes — general node search
# =============================================================================
## Search a scene for nodes matching one or more filters (name, type, group).
## Scene-scoped; defaults to the currently edited scene when scene_path is
## omitted. Filters AND together. Returns {path, name, type, groups} per match.
func find_nodes(args: Dictionary) -> Dictionary:
	var scene_path_in: String = str(args.get(&"scene_path", "")).strip_edges()
	var name_pattern: String = str(args.get(&"name_pattern", ""))
	var type_filter: String = str(args.get(&"type", "")).strip_edges()
	var in_group: String = str(args.get(&"in_group", "")).strip_edges()
	var recursive: bool = bool(args.get(&"recursive", true))

	# Resolve scene_path. If omitted/empty, fall back to the editor's current
	# edited scene. We still load the on-disk version (consistent with the rest
	# of scene_tools), so unsaved edits are not visible.
	var scene_path: String = ""
	if scene_path_in.is_empty():
		if _editor_plugin == null:
			return {
				&"ok": false,
				&"error": "find_nodes: no scene_path provided and no editor plugin available to detect the active scene",
			}
		var ei := _editor_plugin.get_editor_interface()
		var edited: Node = ei.get_edited_scene_root() if ei else null
		if edited == null or str(edited.scene_file_path).is_empty():
			return {
				&"ok": false,
				&"error": "find_nodes: no scene_path provided and no saved scene is currently open in the editor",
			}
		scene_path = str(edited.scene_file_path)
	else:
		scene_path = _ensure_res_path(scene_path_in)
		if scene_path.strip_edges() == "res://":
			return {&"ok": false, &"error": "find_nodes: invalid scene_path"}

	# Validate the `type` filter up-front: must be a known ClassDB class OR a
	# known script global class name. Otherwise the AI gets silent zero matches
	# from a typo, which is the most confusing failure mode.
	var script_class_target: String = ""
	if not type_filter.is_empty():
		if ClassDB.class_exists(type_filter):
			pass
		else:
			# Try to resolve as a script global_class_name (custom class_name).
			var found := false
			for entry in ProjectSettings.get_global_class_list():
				if str(entry.get("class", "")) == type_filter:
					script_class_target = type_filter
					found = true
					break
			if not found:
				return {
					&"ok": false,
					&"error": "find_nodes: type '%s' is not a known ClassDB class or global script class_name" % type_filter,
				}

	var result := _load_scene(scene_path)
	if not result[1].is_empty():
		return result[1]
	var root: Node = result[0]

	var matches: Array = []
	_collect_find_matches(
		root,
		".",
		name_pattern,
		type_filter,
		script_class_target,
		in_group,
		recursive,
		matches,
	)
	root.queue_free()

	var filters_echo: Dictionary = {&"recursive": recursive}
	if not name_pattern.is_empty():
		filters_echo[&"name_pattern"] = name_pattern
	if not type_filter.is_empty():
		filters_echo[&"type"] = type_filter
	if not in_group.is_empty():
		filters_echo[&"in_group"] = in_group

	return {
		&"ok": true,
		&"scene_path": scene_path,
		&"filters": filters_echo,
		&"matches": matches,
		&"count": matches.size(),
	}

func _collect_find_matches(
	node: Node,
	path: String,
	name_pattern: String,
	type_filter: String,
	script_class_target: String,
	in_group: String,
	recursive: bool,
	matches: Array,
) -> void:
	if _node_matches_filters(node, name_pattern, type_filter, script_class_target, in_group):
		matches.append({
			&"path": path,
			&"name": str(node.name),
			&"type": node.get_class(),
			&"groups": node.get_groups(),
		})

	if not recursive and path != ".":
		# Non-recursive: only the root and its direct children get visited.
		return

	for child in node.get_children():
		var child_path: String = str(child.name) if path == "." else path + "/" + str(child.name)
		_collect_find_matches(
			child,
			child_path,
			name_pattern,
			type_filter,
			script_class_target,
			in_group,
			recursive,
			matches,
		)

func _node_matches_filters(
	node: Node,
	name_pattern: String,
	type_filter: String,
	script_class_target: String,
	in_group: String,
) -> bool:
	if not name_pattern.is_empty():
		var n: String = str(node.name)
		var has_glob: bool = name_pattern.contains("*") or name_pattern.contains("?")
		if has_glob:
			if not n.matchn(name_pattern):
				return false
		else:
			if n.findn(name_pattern) == -1:
				return false

	if not type_filter.is_empty():
		var class_ok: bool = node.is_class(type_filter)
		if not class_ok and not script_class_target.is_empty():
			# Walk the script inheritance chain looking for a matching class_name.
			var script: Script = node.get_script() as Script
			while script != null:
				if str(script.get_global_name()) == script_class_target:
					class_ok = true
					break
				script = script.get_base_script()
		if not class_ok:
			return false

	if not in_group.is_empty():
		if not node.is_in_group(in_group):
			return false

	return true

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
## Kept for existing callers. Same as set_node_properties with a colon path:
## resource_path "material/next_pass" + property_name "albedo_color"
## -> "material:next_pass:albedo_color".
func set_resource_property(args: Dictionary) -> Dictionary:
	var scene_path: String = _ensure_res_path(str(args.get(&"scene_path", "")))
	var node_path: String = str(args.get(&"node_path", "."))
	var resource_path: String = str(args.get(&"resource_path", "")).strip_edges()
	var property_name: String = str(args.get(&"property_name", "")).strip_edges()
	if scene_path.strip_edges() == "res://":
		return {&"ok": false, &"error": "Missing 'scene_path'"}
	if property_name.is_empty():
		return {&"ok": false, &"error": "Missing 'property_name'"}
	if not args.has(&"value"):
		return {&"ok": false, &"error": "Missing 'value'"}
	var segments: Array = Array(resource_path.split("/", false))
	segments.append(property_name)
	var key := ":".join(segments)
	var out := _write_scene_node(scene_path, node_path, {key: args[&"value"]}, "set_resource_property")
	if out.get(&"ok", false):
		var entry: Dictionary = out.applied[0]
		out[&"resource_path"] = resource_path
		out[&"property_name"] = property_name
		out[&"old_value"] = entry.old
		out[&"new_value"] = entry.new
		out[&"message"] = "Set %s.%s" % [node_path, key]
	return out

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

# =============================================================================
# call_method — editor-side: invoke any method on any node in a .tscn
# =============================================================================
## Methods that require `confirm: true` because they trivially destroy state
## or bypass other tools' invariants. Applied in BOTH editor and runtime modes
## (the runtime side imports the same list).
const _CALL_METHOD_DENYLIST: Dictionary = {
	"queue_free": true,
	"free": true,
	"set_script": true,        # use attach_script — handles editor sync
	"remove_child": true,
	"replace_by": true,
	"reparent": true,
}

## Editor-side call_method. Loads the scene from disk, finds the node, invokes
## the method with parsed args, captures the (serialized) return value, and
## ALWAYS saves the scene back — even for methods that didn't visibly mutate,
## so the snapshot/undo machinery has a consistent file to compare against.
func call_method(args: Dictionary) -> Dictionary:
	var scene_path_in: String = str(args.get(&"scene_path", "")).strip_edges()
	var node_path: String = str(args.get(&"node_path", ".")).strip_edges()
	var method: String = str(args.get(&"method", "")).strip_edges()
	var raw_args: Variant = args.get(&"args", [])
	var confirm: bool = bool(args.get(&"confirm", false))
	var expect_return: bool = bool(args.get(&"expect_return", true))

	if method.is_empty():
		return {&"ok": false, &"error": "Missing 'method'"}
	if not (raw_args is Array):
		return {&"ok": false, &"error": "'args' must be an array (got %s)" % type_string(typeof(raw_args))}

	if _CALL_METHOD_DENYLIST.has(method) and not confirm:
		return {
			&"ok": false,
			&"error": "Method '%s' is on the destructive denylist. Pass confirm=true to allow it. (Editor mode: prefer remove_node / detach_script / attach_script for those concerns.)" % method,
			&"denylisted": true,
			&"denylist": _CALL_METHOD_DENYLIST.keys(),
		}

	# Resolve scene_path: fall back to the editor's edited scene if missing.
	var scene_path: String = ""
	if scene_path_in.is_empty():
		if _editor_plugin == null:
			return {&"ok": false, &"error": "call_method: no scene_path provided and no editor plugin available to detect the active scene"}
		var ei := _editor_plugin.get_editor_interface()
		var edited: Node = ei.get_edited_scene_root() if ei else null
		if edited == null or str(edited.scene_file_path).is_empty():
			return {&"ok": false, &"error": "call_method: no scene_path provided and no saved scene is currently open in the editor"}
		scene_path = str(edited.scene_file_path)
	else:
		scene_path = _ensure_res_path(scene_path_in)
		if scene_path.strip_edges() == "res://":
			return {&"ok": false, &"error": "call_method: invalid scene_path"}

	var load_result := _load_scene(scene_path)
	if not load_result[1].is_empty():
		return load_result[1]
	var root: Node = load_result[0]

	var target := _find_node(root, node_path)
	if target == null:
		root.queue_free()
		return {&"ok": false, &"error": "Node not found: %s" % node_path}

	# Method existence — with closest-match suggestions on miss.
	if not target.has_method(method):
		var available: Array = _collect_method_names(target)
		var suggestions: Array = _closest_method_matches(method, available, 5)
		root.queue_free()
		return {
			&"ok": false,
			&"error": "Node %s (%s) has no method '%s'.%s" % [
				node_path, target.get_class(), method,
				(" Closest matches: " + ", ".join(suggestions)) if not suggestions.is_empty() else "",
			],
			&"available_methods_sample": available.slice(0, mini(50, available.size())),
			&"closest_matches": suggestions,
		}

	# Godot reality check: editor-side scenes are instantiated with
	# GEN_EDIT_STATE_MAIN. Scripts ARE attached and @export'd vars are
	# editable, but for non-@tool scripts the engine does NOT dispatch
	# user-defined method bodies — `callv("heal", [])` silently returns null
	# instead of running the script. This is a Godot limitation, not ours.
	#
	# Detect the case and refuse with a clear pointer to runtime mode rather
	# than letting the AI think its method ran but returned nothing.
	# Built-in / C++ class methods (set_modulate, add_to_group, …) still work
	# fine — they don't go through script dispatch.
	var script: Script = target.get_script()
	if script != null and not script.is_tool():
		var script_method_names: Array = []
		for m in script.get_script_method_list():
			script_method_names.append(str(m.get("name", "")))
		if method in script_method_names:
			root.queue_free()
			return {
				&"ok": false,
				&"error": "Method '%s' is user-defined in a non-@tool script (%s). Editor-mode call_method cannot execute non-@tool script methods — Godot does NOT dispatch them when the scene is instantiated in the editor context, so the call would silently return null. Fix: either add `@tool` as the first line of the script (advanced — runs the script in the editor too), or use runtime mode: run_scene then call_method with runtime: true." % [method, script.resource_path],
				&"reason": "non_tool_script_method",
				&"script_path": str(script.resource_path),
				&"is_tool_script": false,
				&"hint": "For most game-logic methods (take_damage, respawn, play_intro, …) runtime mode is the right answer. Editor mode is for engine/built-in methods (set_modulate, add_to_group, add_user_signal, Curve2D.add_point, etc.) that mutate persistent scene state.",
			}

	# Decode args by the method's declared parameter types (a Texture2D
	# parameter accepts "res://x.png"; set("prop", v) decodes v by the
	# property's type). Mismatches are errors instead of silent no-ops.
	var decoded := PropertyWriter.decode_call_args(target, method, raw_args as Array, "args")
	if not decoded.errors.is_empty():
		root.queue_free()
		return _validation_failure("call_method", decoded.errors, "Argument values are read according to the method signature. Resources take \"res://...\" or an inline {\"type\": \"<Class>\", ...}.")
	var parsed_args: Array = decoded.args

	# Arity check using MethodInfo. Skip if we can't find a signature (some
	# C++ overloads expose multiple entries; we just don't fail-fast in that
	# case — Godot's own call() will raise a clearer error than we could).
	var sig_info: Dictionary = _find_method_info(target, method)
	if not sig_info.is_empty():
		var declared_args: Array = sig_info.get("args", [])
		var defaults: Array = sig_info.get("default_args", [])
		var max_arity: int = declared_args.size()
		var min_arity: int = max_arity - defaults.size()
		var passed: int = parsed_args.size()
		if passed < min_arity or passed > max_arity:
			root.queue_free()
			return {
				&"ok": false,
				&"error": "Arity mismatch for %s.%s: expected %d..%d args, got %d. Signature: %s" % [
					target.get_class(), method, min_arity, max_arity, passed,
					_format_method_signature(sig_info),
				],
				&"method_signature": _format_method_signature(sig_info),
			}

	var t0: int = Time.get_ticks_msec()
	var ret = target.callv(method, parsed_args)
	var duration_ms: int = Time.get_ticks_msec() - t0

	# Coroutine fire-and-forget: callv on a function that contains `await`
	# returns a GDScriptFunctionState. We don't capture its eventual return;
	# the side effects still run.
	var is_coroutine: bool = ret != null and typeof(ret) == TYPE_OBJECT and str(ret.get_class()) == "GDScriptFunctionState"

	# Always save (per design): keeps the .tscn round-trippable and the
	# snapshot/undo machinery consistent. Even apparently read-only methods
	# may mutate hidden state we can't introspect.
	var save_err := _save_scene(root, scene_path)
	if not save_err.is_empty():
		return save_err

	var response: Dictionary = {
		&"ok": true,
		&"scene_path": scene_path,
		&"node_path": node_path,
		&"node_class": target.get_class() if is_instance_valid(target) else "<freed>",
		&"method": method,
		&"duration_ms": duration_ms,
		&"awaited": false,
		&"is_coroutine": is_coroutine,
		&"runtime": false,
	}
	if not sig_info.is_empty():
		response[&"method_signature"] = _format_method_signature(sig_info)

	if expect_return and not is_coroutine:
		response[&"return_value"] = _serialize_call_method_return(ret)
		response[&"return_type"] = _type_name_for(ret)
	elif is_coroutine:
		response[&"hint"] = "Method is a coroutine (contains `await`). Dispatched fire-and-forget; the return value is a GDScriptFunctionState and is not captured. Use query_runtime_node / follow-up call_method to observe side effects after waiting."
	return response

func _collect_method_names(node: Node) -> Array:
	var names: Array = []
	for m in node.get_method_list():
		var n: String = str(m.get("name", ""))
		if n.is_empty():
			continue
		# Skip private engine methods (_notification, _physics_process, etc.)
		# from the suggestions surface — they're rarely what the AI meant.
		if n.begins_with("_") and not n.begins_with("__"):
			continue
		names.append(n)
	return names

func _closest_method_matches(query: String, available: Array, limit: int) -> Array:
	if query.is_empty() or available.is_empty():
		return []
	var scored: Array = []
	for n in available:
		var s: float = query.similarity(str(n))
		if s > 0.4:
			scored.append({"name": n, "score": s})
	scored.sort_custom(func(a, b): return float(a["score"]) > float(b["score"]))
	var out: Array = []
	for i in range(mini(limit, scored.size())):
		out.append(scored[i]["name"])
	return out

func _find_method_info(node: Node, method: String) -> Dictionary:
	for m in node.get_method_list():
		if str(m.get("name", "")) == method:
			return m
	return {}

func _format_method_signature(info: Dictionary) -> String:
	var name: String = str(info.get("name", ""))
	var declared_args: Array = info.get("args", [])
	var defaults: Array = info.get("default_args", [])
	var min_arity: int = declared_args.size() - defaults.size()
	var parts: Array = []
	for i in range(declared_args.size()):
		var a: Dictionary = declared_args[i]
		var aname: String = str(a.get("name", "arg%d" % i))
		var atype: int = int(a.get("type", TYPE_NIL))
		var atype_str: String = type_string(atype) if atype != TYPE_NIL else "Variant"
		if i >= min_arity:
			parts.append("%s: %s = <default>" % [aname, atype_str])
		else:
			parts.append("%s: %s" % [aname, atype_str])
	var ret_info: Dictionary = info.get("return", {})
	var ret_type: int = int(ret_info.get("type", TYPE_NIL))
	var ret_str: String = type_string(ret_type) if ret_type != TYPE_NIL else "void"
	return "%s(%s) -> %s" % [name, ", ".join(parts), ret_str]

## Serialize a call_method return value. Reuses VariantCodec for primitives
## and standard variant types; adds richer Object/Node/Resource handling so
## the AI can follow up via query_runtime_node / get_resource_info.
func _serialize_call_method_return(v: Variant) -> Variant:
	if v == null:
		return null
	match typeof(v):
		TYPE_OBJECT:
			if v is Node:
				var path_str: String = ""
				if (v as Node).is_inside_tree():
					path_str = str((v as Node).get_path())
				return {
					&"type": &"Object",
					&"class": (v as Node).get_class(),
					&"name": str((v as Node).name),
					&"node_path": path_str,
					&"serializable": false,
				}
			if v is Resource:
				var rp: String = str((v as Resource).resource_path)
				var d: Dictionary = {
					&"type": &"Resource",
					&"class": (v as Resource).get_class(),
					&"serializable": false,
				}
				if not rp.is_empty():
					d[&"resource_path"] = rp
				return d
			return {
				&"type": &"Object",
				&"class": v.get_class() if v.has_method("get_class") else "Object",
				&"serializable": false,
			}
		TYPE_ARRAY:
			var out: Array = []
			for item in (v as Array):
				out.append(_serialize_call_method_return(item))
			return out
		TYPE_DICTIONARY:
			var od: Dictionary = {}
			for k in (v as Dictionary):
				od[k] = _serialize_call_method_return((v as Dictionary)[k])
			return od
		_:
			return VariantCodec.serialize_value(v)

func _type_name_for(v: Variant) -> String:
	if v == null:
		return "null"
	var t: int = typeof(v)
	if t == TYPE_OBJECT:
		return v.get_class() if v != null and v.has_method("get_class") else "Object"
	return type_string(t)
