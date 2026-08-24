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


# =============================================================================
# Pre-validation walker (roadmap #7) — validate-then-mutate for compound tools.
# =============================================================================
## Validate a node spec dict (the args of add_node, OR a `children`/`nodes`
## entry of add_node/create_scene) WITHOUT mutating anything. Walks the entire
## tree recursively and returns an Array of path-pointed error strings, e.g.
##   "children[2].properties.text: property does not exist on Sprite2D"
## Empty array == valid; caller can proceed.
##
## `path_prefix` is the JSON-path-like prefix for errors:
##   ""              top-level (add_node)
##   "nodes[1]"      top-level (create_scene)
##   "children[2]"   a recursed child
## `require_name` is true only when the spec is the top-level add_node call
## (where node_name is required); false for children and create_scene's nodes
## entries (Godot will auto-name those if omitted).
##
## What we check (cheap, no scene load required):
##   - node_type present and ClassDB.class_exists()
##   - script (if provided): FileAccess.file_exists() AND is a Script resource
##   - every key in `properties`: exists on node_type (or on the attached
##     script's @export list). Property TYPE compatibility is NOT checked
##     here — runtime catches type errors with clear messages.
##   - children is an Array, every entry is a Dictionary, recurse.
##
## What we don't check (intentionally):
##   - Property VALUE types (variant codec handles JSON→variant coercion).
##   - res:// paths inside property values (would need per-property variant
##     parsing; too complex for the marginal benefit).
##   - groups membership (any non-empty string is a valid group name).
func _validate_node_spec(spec: Dictionary, path_prefix: String, require_name: bool) -> Array:
	var errors: Array = []
	var prefix: String = path_prefix + "." if not path_prefix.is_empty() else ""

	# node_name (only required for the top-level add_node call).
	var name_str: String = str(spec.get(&"node_name", spec.get(&"name", "")))
	if require_name and name_str.strip_edges().is_empty():
		errors.append("%snode_name: required (non-empty string)" % prefix)

	# node_type — must exist in ClassDB. Without a valid type we can't validate
	# properties either, so short-circuit.
	var type_str: String = str(spec.get(&"node_type", spec.get(&"type", "")))
	if type_str.strip_edges().is_empty():
		errors.append("%snode_type: required (a Godot class name like Node2D, Sprite2D, CharacterBody2D, …)" % prefix)
		# Still walk children so the agent sees ALL issues in one shot.
		_validate_children(spec, prefix, errors)
		return errors
	if not ClassDB.class_exists(type_str):
		errors.append("%snode_type: '%s' is not a known Godot class (use classdb_query to discover valid types)" % [prefix, type_str])
		_validate_children(spec, prefix, errors)
		return errors

	# script (optional): file must exist AND be a Script.
	var script_path: String = str(spec.get(&"script", "")).strip_edges()
	var script_res: Script = null
	if not script_path.is_empty():
		if not script_path.begins_with("res://") and not script_path.begins_with("user://"):
			errors.append("%sscript: path must start with res:// or user:// (got '%s')" % [prefix, script_path])
		elif not FileAccess.file_exists(script_path):
			errors.append("%sscript: file does not exist: '%s'" % [prefix, script_path])
		else:
			var loaded: Resource = load(script_path)
			if loaded == null:
				errors.append("%sscript: failed to load '%s' (corrupt or parse error — check get_errors)" % [prefix, script_path])
			elif not (loaded is Script):
				errors.append("%sscript: '%s' is not a Script (got %s)" % [prefix, script_path, loaded.get_class()])
			else:
				script_res = loaded

	# properties: each key must exist on node_type (plus @export'd properties
	# from the attached script, if any).
	var props_v: Variant = spec.get(&"properties", {})
	if props_v is Dictionary and not (props_v as Dictionary).is_empty():
		var valid_props: Dictionary = _collect_property_names(type_str, script_res)
		# If we couldn't gather any names (shouldn't happen — every Object has
		# basic properties), skip name validation rather than false-positive.
		if not valid_props.is_empty():
			for prop_name_v in (props_v as Dictionary).keys():
				var prop_name := str(prop_name_v)
				if not valid_props.has(prop_name):
					errors.append("%sproperties.%s: property does not exist on %s%s" % [
						prefix, prop_name, type_str,
						(" (or its attached script)" if script_res != null else ""),
					])
	elif not (props_v is Dictionary):
		errors.append("%sproperties: must be a Dictionary, got %s" % [prefix, type_string(typeof(props_v))])

	# groups: shape only — must be an Array (any string element is acceptable).
	var groups_v: Variant = spec.get(&"groups", [])
	if not (groups_v is Array or groups_v is PackedStringArray):
		errors.append("%sgroups: must be an Array of strings, got %s" % [prefix, type_string(typeof(groups_v))])

	# children: recurse.
	_validate_children(spec, prefix, errors)
	return errors


## Walk children recursively, appending into `errors`. Extracted so we can
## still visit children even when the parent's node_type is invalid (so the
## agent sees every issue at once, not just the first).
func _validate_children(spec: Dictionary, prefix: String, errors: Array) -> void:
	var children_v: Variant = spec.get(&"children", [])
	if children_v == null:
		return
	if not (children_v is Array):
		errors.append("%schildren: must be an Array, got %s" % [prefix, type_string(typeof(children_v))])
		return
	var children: Array = children_v
	for i in range(children.size()):
		var child_data: Variant = children[i]
		# Drop the trailing dot from prefix when concatenating an index segment.
		var raw_prefix: String = prefix.trim_suffix(".")
		var child_path: String = (raw_prefix + "." if not raw_prefix.is_empty() else "") + ("children[%d]" % i)
		# children[i] handled WITHOUT trailing dot so the recursion can decide.
		var child_path_no_dot: String = child_path
		if typeof(child_data) != TYPE_DICTIONARY:
			errors.append("%s: must be a Dictionary, got %s" % [child_path_no_dot, type_string(typeof(child_data))])
			continue
		errors.append_array(_validate_node_spec(child_data, child_path_no_dot, false))


## Collect the set of valid property names for a given node type, optionally
## including @export'd properties from an attached script. Returns a
## Dictionary keyed by property name (values are unused).
func _collect_property_names(type_str: String, script: Script) -> Dictionary:
	var out: Dictionary = {}
	if ClassDB.class_exists(type_str):
		for p in ClassDB.class_get_property_list(type_str, false):
			out[str(p.get(&"name", ""))] = true
	if script != null:
		for p in script.get_script_property_list():
			out[str(p.get(&"name", ""))] = true
	return out

func _serialize_value(value: Variant) -> Variant:
	return VariantCodec.serialize_value(value)

# =============================================================================
# create_scene
# =============================================================================
func create_scene(args: Dictionary) -> Dictionary:
	var scene_path: String = _ensure_res_path(str(args.get(&"scene_path", "")))
	var root_node_name: String = str(args.get(&"root_node_name", "Node"))
	var root_node_type: String = str(args.get(&"root_node_type", ""))
	# Variant load so a non-Array `nodes` arg becomes a clean validation
	# error rather than a typed-assignment crash (matches add_node).
	var nodes_v: Variant = args.get(&"nodes", [])
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

	# Pre-validation (roadmap #7): the root is validated above; here we walk
	# the entire `nodes` array (which may contain nested subtrees via
	# `children`) BEFORE touching the filesystem. Path-pointed errors so a
	# malformed nodes[1].children[2].properties.text fails fast and clearly.
	# Also validate the optional `attach_script` for the root.
	var validation_errors: Array = []
	if not (nodes_v is Array):
		validation_errors.append("nodes: must be an Array, got %s" % type_string(typeof(nodes_v)))
	if not attach_script_path.is_empty():
		if not attach_script_path.begins_with("res://") and not attach_script_path.begins_with("user://"):
			validation_errors.append("attach_script: path must start with res:// or user:// (got '%s')" % attach_script_path)
		elif not FileAccess.file_exists(attach_script_path):
			validation_errors.append("attach_script: file does not exist: '%s'" % attach_script_path)
		else:
			var loaded_root_script: Resource = load(attach_script_path)
			if loaded_root_script == null:
				validation_errors.append("attach_script: failed to load '%s' (corrupt or parse error)" % attach_script_path)
			elif not (loaded_root_script is Script):
				validation_errors.append("attach_script: '%s' is not a Script (got %s)" % [attach_script_path, loaded_root_script.get_class()])
	if nodes_v is Array:
		for i in range((nodes_v as Array).size()):
			var node_data: Variant = (nodes_v as Array)[i]
			var entry_path: String = "nodes[%d]" % i
			if typeof(node_data) != TYPE_DICTIONARY:
				validation_errors.append("%s: must be a Dictionary, got %s" % [entry_path, type_string(typeof(node_data))])
				continue
			validation_errors.append_array(_validate_node_spec(node_data, entry_path, false))
	if not validation_errors.is_empty():
		return {
			&"ok": false,
			&"error": "create_scene: pre-validation failed with %d issue(s); no scene file created." % validation_errors.size(),
			&"validation_errors": validation_errors,
			&"hint": "Property names are validated against ClassDB + any @export'd properties on attached scripts. Fix all listed paths and retry.",
		}

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

	# Validation passed → narrow back to typed Array for the build loop.
	var nodes: Array = nodes_v if nodes_v is Array else []
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

	# Script-before-properties: same ordering rule as add_node. Without
	# attaching the script first, any @export'd property in `props` would
	# be silently dropped by node.set() (the var doesn't exist on the bare
	# node yet). Pre-validation guarantees the script loads at this point.
	if not n_script.is_empty():
		var s = load(n_script)
		if s:
			node.set_script(s)
		else:
			node.free()
			return [null, "Failed to load script for child '%s': %s" % [n_name, n_script]]

	_set_node_properties(node, props)

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
	# CRITICAL: do NOT declare these as typed `Dictionary`/`Array` locals —
	# GDScript 4's typed assignment crashes the function before the
	# pre-validator runs if the agent passes the wrong shape (e.g.
	# `children: "not an array"`). Keep them Variant; the validator emits
	# a proper path-pointed type error and we narrow after validation.
	var properties_v: Variant = args.get(&"properties", {})
	var script_path: String = str(args.get(&"script", ""))
	var children_v: Variant = args.get(&"children", [])
	var groups_v: Variant = args.get(&"groups", [])

	if scene_path.strip_edges() == "res://":
		return {&"ok": false, &"error": "Missing 'scene_path'"}

	# Pre-validation (roadmap #7): walk the entire spec — top node, every
	# property name, the script, plus every descendant in `children` — and
	# return ALL issues at once, with path-pointed errors, BEFORE loading
	# the scene from disk. Cheap exit on bad input; the agent gets a single
	# round-trip with the full failure list instead of fixing them one at a
	# time. Zero mutation occurs when validation fails.
	var spec_for_validation: Dictionary = {
		&"node_name": node_name,
		&"node_type": node_type,
		&"script": script_path,
		&"properties": properties_v,
		&"children": children_v,
		&"groups": groups_v,
	}
	var validation_errors: Array = _validate_node_spec(spec_for_validation, "", true)
	if not validation_errors.is_empty():
		return {
			&"ok": false,
			&"error": "add_node: pre-validation failed with %d issue(s); no mutation occurred." % validation_errors.size(),
			&"validation_errors": validation_errors,
			&"hint": "Property names are validated against ClassDB + any @export'd properties on the attached script. Fix all listed paths and retry. Use classdb_query or get_scene_node_properties to discover valid property names.",
		}

	# Validation passed → narrow back to the typed shapes the rest of the
	# function expects. Safe because the validator rejected anything else.
	var properties: Dictionary = properties_v
	var children: Array = children_v
	var groups: Array = groups_v

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

	# ATTACH SCRIPT FIRST, THEN SET PROPERTIES. Setting an @export'd script
	# var on a bare node (before set_script) silently fails because the var
	# doesn't exist on the unscripted node yet. The pre-validator accepts
	# script @exports as valid property names, so this ordering bug caused
	# the validator to report success while the .tscn never actually
	# recorded the value. Pre-validation already proved the script loads.
	if not script_path.is_empty():
		var s := load(script_path)
		if s:
			new_node.set_script(s)
		else:
			root.queue_free()
			return {&"ok": false, &"error": "Failed to load script: " + script_path}

	_set_node_properties(new_node, properties)

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
# set_node_properties (bulk, atomic)
# =============================================================================
## Apply multiple properties to a node in a single load/save cycle.
## ATOMIC (roadmap #7): every property is pre-validated (name exists on the
## node's class + script, and Resource compatibility is satisfied) BEFORE any
## mutation. If ANY entry fails validation, the call returns `ok: false`
## with a `validation_errors` list and ZERO mutation occurs — no scene save,
## no half-applied state. This is the explicit policy change from the old
## per-property tolerance; the agent now gets one round-trip with the full
## issue list instead of having to inspect a mixed `applied`/`failed` shape.
##
## Use modify_node_property for a single property; this is for batch writes.
## Resource-typed properties must use set_resource_property / specialized tools.
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

	# Build per-property metadata from the LIVE target's property list. This
	# already includes @export'd properties from any attached script. We need
	# more than just the name set — the declared variant type tells us
	# whether the property expects a Resource/Object even when its current
	# value happens to be null (which is the common case for fresh Sprite2Ds
	# with no texture, etc.). Checking just `old_value is Resource` misses
	# that case and lets `texture: 1` slip through silently.
	var prop_meta: Dictionary = {}
	for prop in target.get_property_list():
		var pname: String = str(prop.get(&"name", ""))
		prop_meta[pname] = {
			&"type": int(prop.get(&"type", TYPE_NIL)),
			&"class_name": str(prop.get(&"class_name", "")),
		}

	# Pre-validate every entry. Collect ALL issues so the agent gets the full
	# picture in one shot, not just the first failure.
	var validation_errors: Array = []
	var planned: Array = [] # parallel list of {prop_name, parsed, old_value} for the apply phase
	for prop_name_v in properties.keys():
		var prop_name := str(prop_name_v)
		var raw_value = properties[prop_name_v]

		if not prop_meta.has(prop_name):
			validation_errors.append("properties.%s: property does not exist on %s" % [prop_name, target.get_class()])
			continue

		var meta: Dictionary = prop_meta[prop_name]
		var declared_type: int = int(meta.get(&"type", TYPE_NIL))
		var declared_class: String = str(meta.get(&"class_name", ""))
		var old_value = target.get(prop_name)
		var parsed = _parse_value(raw_value)

		# Reject Resource-typed properties that received a non-Object. Accepts
		# null (clearing the property) and any Object/Resource instance the
		# variant codec produced. The declared-type check catches the
		# `texture: 1` case where the current value is null — the older
		# `old_value is Resource` heuristic missed it.
		if declared_type == TYPE_OBJECT and parsed != null and not (parsed is Object):
			var expected: String = declared_class if not declared_class.is_empty() else "Resource"
			validation_errors.append("properties.%s: expects %s (use set_resource_property / set_sprite_texture / set_mesh / set_material / set_collision_shape instead — passing a primitive here would be silently dropped)" % [prop_name, expected])
			continue

		# Belt-and-suspenders: the original heuristic still fires for the
		# already-has-a-Resource case (e.g. someone clearing a texture by
		# passing 0 instead of null — still a misuse worth flagging).
		if old_value is Resource and parsed != null and not (parsed is Resource):
			validation_errors.append("properties.%s: expects a Resource (use set_resource_property / set_sprite_texture / set_mesh / set_material / set_collision_shape instead)" % prop_name)
			continue

		planned.append({
			&"prop_name": prop_name,
			&"parsed": parsed,
			&"old_value": old_value,
		})

	if not validation_errors.is_empty():
		root.queue_free()
		return {
			&"ok": false,
			&"error": "set_node_properties: pre-validation failed with %d issue(s); no mutation occurred." % validation_errors.size(),
			&"validation_errors": validation_errors,
			&"node_path": node_path,
			&"hint": "All property names + Resource-type compatibility are validated before anything is written. Fix every listed issue and retry. Use get_scene_node_properties to read this node's current properties (including @export'd script vars), or classdb_query for the full class API.",
		}

	# Validation passed — apply every property and save.
	var applied: Array = []
	for entry: Dictionary in planned:
		target.set(entry[&"prop_name"], entry[&"parsed"])
		applied.append({
			&"property": entry[&"prop_name"],
			&"old": _serialize_value(entry[&"old_value"]),
			&"new": _serialize_value(entry[&"parsed"]),
		})

	var err := _save_scene(root, scene_path)
	if not err.is_empty():
		return err

	return {
		&"ok": true,
		&"scene_path": scene_path,
		&"node_path": node_path,
		&"applied": applied,
		&"message": "Applied %d propert%s on %s" % [
			applied.size(),
			"y" if applied.size() == 1 else "ies",
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

	# Parse args through VariantCodec for {type:"Vector2",...} discriminated form.
	var parsed_args: Array = []
	for v in (raw_args as Array):
		parsed_args.append(_parse_value(v))

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
