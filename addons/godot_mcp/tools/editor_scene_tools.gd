@tool
extends Node
class_name EditorSceneTools
## Live editor scene-tree tools for MCP.
## Handles: call_node_method

const SceneToolContext = preload("res://addons/godot_mcp/utils/scene_tool_context.gd")

var _context := SceneToolContext.new()

func set_editor_plugin(plugin: EditorPlugin) -> void:
	_context.set_owner_name("EditorSceneTools")
	_context.set_editor_plugin(plugin)

func set_scene_tools_ref(scene_tools: Node) -> void:
	_context.set_scene_tools_ref(scene_tools)

func _serialize_method_result(value: Variant) -> Variant:
	if typeof(value) != TYPE_OBJECT:
		return _context.serialize_value(value)

	if value == null:
		return null

	if value is Node:
		var node: Node = value
		return {
			&"type": &"Node",
			&"class": node.get_class(),
			&"name": node.name,
			&"node_path": str(node.get_path()),
		}

	if value is Resource:
		return _context.serialize_value(value)

	var object_value: Object = value
	return {
		&"type": &"Object",
		&"class": object_value.get_class(),
	}

func _method_return_type_name(value: Variant) -> String:
	if typeof(value) == TYPE_OBJECT and value != null:
		return value.get_class()
	return type_string(typeof(value))

func call_node_method(args: Dictionary) -> Dictionary:
	var scene_path := _context.ensure_res_path(str(args.get(&"scene_path", "")).strip_edges())
	var node_path := str(args.get(&"node_path", ".")).strip_edges()
	var method_name := str(args.get(&"method_name", "")).strip_edges()
	var save_scene_after := bool(args.get(&"save_scene_after", true))
	var raw_args: Variant = args.get(&"args", [])

	if scene_path.is_empty():
		return {&"ok": false, &"error": "Missing 'scene_path'"}
	if method_name.is_empty():
		return {&"ok": false, &"error": "Missing 'method_name'"}
	if node_path.is_empty():
		node_path = "."
	if not (raw_args is Array):
		return {&"ok": false, &"error": "'args' must be an array if provided"}

	var editor_scene_result := _context.load_editor_scene_root(scene_path)
	if not editor_scene_result[1].is_empty():
		return editor_scene_result[1]

	var scene_root: Node = editor_scene_result[0]
	var target := _context.find_node(scene_root, node_path)
	if not target:
		return {&"ok": false, &"error": "Node not found in the open editor scene: " + node_path}
	if not target.has_method(method_name):
		return {
			&"ok": false,
			&"error": "Node '%s' (%s) does not implement method '%s'" % [node_path, target.get_class(), method_name],
		}

	var parsed_args: Array = []
	for value in raw_args:
		parsed_args.append(_context.parse_value(value))

	var return_value = target.callv(method_name, parsed_args)
	if save_scene_after:
		var save_result := _context.save_editor_scene(scene_path)
		if not save_result.is_empty():
			return save_result
	else:
		var unsaved_result := _context.mark_editor_scene_as_unsaved(scene_path)
		if not unsaved_result.is_empty():
			return unsaved_result

	return {
		&"ok": true,
		&"scene_path": scene_path,
		&"node_path": node_path,
		&"method_name": method_name,
		&"args_count": parsed_args.size(),
		&"saved_scene": save_scene_after,
		&"return_type": _method_return_type_name(return_value),
		&"return_value": _serialize_method_result(return_value),
	}
