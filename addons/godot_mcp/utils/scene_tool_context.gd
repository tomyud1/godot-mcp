@tool
extends RefCounted
class_name SceneToolContext
## Shared SceneTools/editor-plugin bridge used by tool modules.

var _owner_name: String = "Tool"
var _editor_plugin: EditorPlugin = null
var _scene_tools_ref: Node = null

func set_owner_name(name: String) -> void:
	_owner_name = name

func set_editor_plugin(plugin: EditorPlugin) -> void:
	_editor_plugin = plugin

func get_editor_plugin() -> EditorPlugin:
	return _editor_plugin

func set_scene_tools_ref(scene_tools: Node) -> void:
	_scene_tools_ref = scene_tools

func get_scene_tools_ref() -> Node:
	return _scene_tools_ref

func require_scene_tools() -> Dictionary:
	if _scene_tools_ref:
		return {}
	return {&"ok": false, &"error": "%s is missing its SceneTools dependency" % _owner_name}

func ensure_res_path(path: String) -> String:
	if not _scene_tools_ref:
		if not path.begins_with("res://"):
			return "res://" + path
		return path
	return _scene_tools_ref.call("_ensure_res_path", path)

func load_scene(scene_path: String) -> Array:
	var dependency_error := require_scene_tools()
	if not dependency_error.is_empty():
		return [null, dependency_error]
	return _scene_tools_ref.call("_load_scene", scene_path)

func save_scene(scene_root: Node, scene_path: String) -> Dictionary:
	var dependency_error := require_scene_tools()
	if not dependency_error.is_empty():
		return dependency_error
	return _scene_tools_ref.call("_save_scene", scene_root, scene_path)

func load_editor_scene_root(scene_path: String = "") -> Array:
	if not _editor_plugin:
		return [null, {&"ok": false, &"error": "Live editor scene access requires an active editor plugin"}]

	var ei := _editor_plugin.get_editor_interface()
	var edited_scene := ei.get_edited_scene_root()
	if not edited_scene:
		return [null, {&"ok": false, &"error": "No scene is currently open in the editor"}]

	if not scene_path.is_empty():
		var normalized_scene_path := ensure_res_path(scene_path)
		if edited_scene.scene_file_path != normalized_scene_path:
			return [
				null,
				{
					&"ok": false,
					&"error": "This tool only operates on the currently open editor scene. Open '%s' in the editor and retry." % normalized_scene_path,
					&"open_scene_path": edited_scene.scene_file_path,
				},
			]

	return [edited_scene, {}]

func refresh_filesystem() -> void:
	if not _editor_plugin:
		return
	var filesystem := _editor_plugin.get_editor_interface().get_resource_filesystem()
	if filesystem and not filesystem.is_scanning():
		filesystem.scan()

func mark_editor_scene_as_unsaved(scene_path: String = "") -> Dictionary:
	var result := load_editor_scene_root(scene_path)
	if not result[1].is_empty():
		return result[1]

	_editor_plugin.get_editor_interface().mark_scene_as_unsaved()
	return {}

func save_editor_scene(scene_path: String = "") -> Dictionary:
	var result := load_editor_scene_root(scene_path)
	if not result[1].is_empty():
		return result[1]

	var save_result := _editor_plugin.get_editor_interface().save_scene()
	if save_result != OK:
		return {&"ok": false, &"error": "Failed to save the current editor scene: " + str(save_result)}

	refresh_filesystem()
	return {}

func release_scene_root(scene_root: Node, should_free: bool) -> void:
	if should_free and is_instance_valid(scene_root):
		scene_root.queue_free()

func find_node(scene_root: Node, node_path: String) -> Node:
	if not _scene_tools_ref:
		return null
	return _scene_tools_ref.call("_find_node", scene_root, node_path)

func parse_value(value: Variant) -> Variant:
	if not _scene_tools_ref:
		return value
	return _scene_tools_ref.call("_parse_value", value)

func parse_typed_value(value: Variant, type_hint: int, property_metadata: Dictionary = {}) -> Variant:
	if not _scene_tools_ref:
		return value
	return _scene_tools_ref.call("_parse_typed_value", value, type_hint, property_metadata)

func serialize_value(value: Variant) -> Variant:
	if not _scene_tools_ref:
		return value
	return _scene_tools_ref.call("_serialize_value", value)

func get_node3d_global_transform(node: Node3D) -> Transform3D:
	if not _scene_tools_ref:
		return node.transform
	return _scene_tools_ref.call("_get_node3d_global_transform", node)

func set_node3d_global_transform(node: Node3D, global_transform: Transform3D) -> void:
	if not _scene_tools_ref:
		node.transform = global_transform
		return
	_scene_tools_ref.call("_set_node3d_global_transform", node, global_transform)

func get_node_global_aabb(node: Node) -> Variant:
	if not _scene_tools_ref:
		return null
	return _scene_tools_ref.call("_get_node_global_aabb", node)

func load_inspection_root(scene_path: String, runtime: bool) -> Array:
	if runtime:
		var editor_scene_result := load_editor_scene_root(scene_path)
		if not editor_scene_result[1].is_empty():
			var runtime_error: Dictionary = editor_scene_result[1].duplicate(true)
			if not runtime_error.get(&"error", "").contains("runtime inspection"):
				runtime_error[&"error"] = str(runtime_error.get(&"error", "")).replace(
					"This tool only operates on the currently open editor scene.",
					"Runtime inspection only sees the currently open editor scene."
				)
			return [null, runtime_error, "", false]
		return [editor_scene_result[0], {}, "editor_live", false]

	var result := load_scene(scene_path)
	if not result[1].is_empty():
		return [null, result[1], "", false]
	return [result[0], {}, "scene_file", true]

func get_scene_tree() -> SceneTree:
	var scene_tools_node = get_scene_tools_ref()
	if scene_tools_node and scene_tools_node.is_inside_tree():
		return scene_tools_node.get_tree()
	if _editor_plugin:
		return _editor_plugin.get_tree()
	var main_loop = Engine.get_main_loop()
	if main_loop is SceneTree:
		return main_loop
	return null

func mount_scene_root(scene_root: Node, helper_name: String) -> Array:
	var scene_tree := get_scene_tree()
	if not scene_tree:
		return [null, {&"ok": false, &"error": "Operation requires a SceneTree context"}]

	var helper := Node.new()
	helper.name = helper_name
	helper.process_mode = Node.PROCESS_MODE_DISABLED
	scene_tree.root.add_child(helper)
	helper.add_child(scene_root)
	return [helper, {}]

func unmount_scene_root(scene_root: Node, helper: Node) -> void:
	if not helper:
		return
	if scene_root and scene_root.get_parent() == helper:
		helper.remove_child(scene_root)
	if helper.get_parent():
		helper.get_parent().remove_child(helper)
	helper.queue_free()
