@tool
extends Node
class_name ToolExecutor
## Routes tool invocations to the appropriate handler.

var _editor_plugin: EditorPlugin = null

var _file_tools: Node
var _scene_tools: Node
var _script_tools: Node
var _project_tools: Node
var _asset_tools: Node
var _visualizer_tools: Node

# Tool name → [handler_node, method_name]
var _tool_map: Dictionary = {}

var _initialized := false

func _init_tools() -> void:
	"""Initialize all tool handlers. Called from set_editor_plugin."""
	if _initialized:
		return
	_initialized = true
	
	_file_tools = preload("res://addons/godot_mcp/tools/file_tools.gd").new()
	_file_tools.name = "FileTools"
	add_child(_file_tools)

	_scene_tools = preload("res://addons/godot_mcp/tools/scene_tools.gd").new()
	_scene_tools.name = "SceneTools"
	add_child(_scene_tools)

	_script_tools = preload("res://addons/godot_mcp/tools/script_tools.gd").new()
	_script_tools.name = "ScriptTools"
	add_child(_script_tools)

	_project_tools = preload("res://addons/godot_mcp/tools/project_tools.gd").new()
	_project_tools.name = "ProjectTools"
	add_child(_project_tools)

	_asset_tools = preload("res://addons/godot_mcp/tools/asset_tools.gd").new()
	_asset_tools.name = "AssetTools"
	add_child(_asset_tools)

	_visualizer_tools = preload("res://addons/godot_mcp/tools/visualizer_tools.gd").new()
	_visualizer_tools.name = "VisualizerTools"
	add_child(_visualizer_tools)

	# Build tool routing map
	_tool_map = {
		# File tools
		"list_dir": [_file_tools, "list_dir"],
		"read_file": [_file_tools, "read_file"],
		"search_project": [_file_tools, "search_project"],
		"create_script": [_file_tools, "create_script"],

		# Scene tools
		"create_scene": [_scene_tools, "create_scene"],
		"read_scene": [_scene_tools, "read_scene"],
		"add_node": [_scene_tools, "add_node"],
		"remove_node": [_scene_tools, "remove_node"],
		"modify_node_property": [_scene_tools, "modify_node_property"],
		"rename_node": [_scene_tools, "rename_node"],
		"move_node": [_scene_tools, "move_node"],
		"attach_script": [_scene_tools, "attach_script"],
		"detach_script": [_scene_tools, "detach_script"],
		"set_collision_shape": [_scene_tools, "set_collision_shape"],
		"set_sprite_texture": [_scene_tools, "set_sprite_texture"],
		"get_scene_hierarchy": [_scene_tools, "get_scene_hierarchy"],
		"get_scene_node_properties": [_scene_tools, "get_scene_node_properties"],
		"set_scene_node_property": [_scene_tools, "set_scene_node_property"],

		# Script/file management tools
		"apply_diff_preview": [_script_tools, "apply_diff_preview"],
		"validate_script": [_script_tools, "validate_script"],
		"list_scripts": [_script_tools, "list_scripts"],
		"create_folder": [_script_tools, "create_folder"],
		"delete_file": [_script_tools, "delete_file"],
		"rename_file": [_script_tools, "rename_file"],

		# Project/debug tools
		"get_project_settings": [_project_tools, "get_project_settings"],
		"get_input_map": [_project_tools, "get_input_map"],
		"get_collision_layers": [_project_tools, "get_collision_layers"],
		"get_node_properties": [_project_tools, "get_node_properties"],
		"get_console_log": [_project_tools, "get_console_log"],
		"get_errors": [_project_tools, "get_errors"],
		"clear_console_log": [_project_tools, "clear_console_log"],
		"open_in_godot": [_project_tools, "open_in_godot"],
		"scene_tree_dump": [_project_tools, "scene_tree_dump"],

		# Asset generation tools
		"generate_2d_asset": [_asset_tools, "generate_2d_asset"],
		"search_comfyui_nodes": [_asset_tools, "search_comfyui_nodes"],
		"inspect_runninghub_workflow": [_asset_tools, "inspect_runninghub_workflow"],
		"customize_and_run_workflow": [_asset_tools, "customize_and_run_workflow"],

		# Visualizer tools
		"map_project": [_visualizer_tools, "map_project"],
		"map_scenes": [_visualizer_tools, "map_scenes"],
	}

func set_editor_plugin(plugin: EditorPlugin) -> void:
	_editor_plugin = plugin
	
	# Initialize tools first (must be done synchronously)
	_init_tools()
	
	# Pass editor plugin reference to all tool handlers
	if _file_tools: _file_tools.set_editor_plugin(plugin)
	if _scene_tools: _scene_tools.set_editor_plugin(plugin)
	if _script_tools: _script_tools.set_editor_plugin(plugin)
	if _project_tools: _project_tools.set_editor_plugin(plugin)
	if _asset_tools: _asset_tools.set_editor_plugin(plugin)
	if _visualizer_tools:
		_visualizer_tools.set_editor_plugin(plugin)
		# Pass scene_tools reference for visualizer internal scene functions
		_visualizer_tools.set_scene_tools_ref(_scene_tools)

func execute_tool(tool_name: String, args: Dictionary) -> Dictionary:
	"""Execute a tool by name with the given arguments."""
	
	# Handle internal visualizer commands (not exposed as MCP tools)
	if tool_name.begins_with("visualizer._internal_"):
		var method: String = tool_name.replace("visualizer.", "")
		if _visualizer_tools and _visualizer_tools.has_method(method):
			return _visualizer_tools.call(method, args)
		else:
			return {"ok": false, "error": "Internal method not found: " + method}
	
	if not _tool_map.has(tool_name):
		return {
			"ok": false,
			"error": "Unknown tool: %s. Available: %s" % [tool_name, ", ".join(_tool_map.keys())]
		}

	var handler: Array = _tool_map[tool_name]
	var node: Node = handler[0]
	var method: String = handler[1]

	if not node.has_method(method):
		return {"ok": false, "error": "Tool handler not found: %s.%s" % [node.name, method]}

	return node.call(method, args)

func get_available_tools() -> Array:
	"""Return list of available tool names."""
	return _tool_map.keys()
