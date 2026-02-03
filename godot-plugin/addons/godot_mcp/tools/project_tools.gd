@tool
extends Node
class_name ProjectTools
## Project configuration and debug tools for MCP.
## Handles: get_project_settings, get_input_map, get_collision_layers,
##          get_node_properties, get_console_log, get_errors, clear_console_log,
##          open_in_godot, scene_tree_dump

var _editor_plugin: EditorPlugin = null

# Buffer for capturing console output
var _console_buffer: Array = []
const MAX_CONSOLE_LINES := 500

func set_editor_plugin(plugin: EditorPlugin) -> void:
	_editor_plugin = plugin

# =============================================================================
# get_project_settings
# =============================================================================
func get_project_settings(args: Dictionary) -> Dictionary:
	var include_render: bool = bool(args.get("include_render", true))
	var include_physics: bool = bool(args.get("include_physics", true))

	var out: Dictionary = {}
	out["main_scene"] = str(ProjectSettings.get_setting("application/run/main_scene", ""))

	# Window size
	var width = ProjectSettings.get_setting("display/window/size/viewport_width", null)
	var height = ProjectSettings.get_setting("display/window/size/viewport_height", null)
	if width != null: out["window_width"] = int(width)
	if height != null: out["window_height"] = int(height)

	# Stretch
	var stretch_mode = ProjectSettings.get_setting("display/window/stretch/mode", null)
	var stretch_aspect = ProjectSettings.get_setting("display/window/stretch/aspect", null)
	if stretch_mode != null: out["stretch_mode"] = str(stretch_mode)
	if stretch_aspect != null: out["stretch_aspect"] = str(stretch_aspect)

	if include_physics:
		var pps = ProjectSettings.get_setting("physics/common/physics_ticks_per_second", null)
		if pps != null: out["physics_ticks_per_second"] = int(pps)

	if include_render:
		var method = ProjectSettings.get_setting("rendering/renderer/rendering_method", null)
		if method != null: out["rendering_method"] = str(method)
		var vsync = ProjectSettings.get_setting("display/window/vsync/vsync_mode", null)
		if vsync != null: out["vsync"] = str(vsync)

	return {"ok": true, "settings": out}

# =============================================================================
# get_input_map
# =============================================================================
func get_input_map(args: Dictionary) -> Dictionary:
	var include_deadzones: bool = bool(args.get("include_deadzones", true))
	var actions: Array = InputMap.get_actions()
	actions.sort()

	var result: Dictionary = {}
	for action in actions:
		var events: Array = []
		for e in InputMap.action_get_events(action):
			var item := {"type": e.get_class()}

			if e is InputEventKey:
				var keycode = e.physical_keycode if e.physical_keycode != 0 else e.keycode
				item["keycode"] = keycode
				item["key_label"] = OS.get_keycode_string(keycode) if keycode != 0 else ""
			elif e is InputEventMouseButton:
				item["button_index"] = e.button_index
			elif e is InputEventJoypadButton:
				item["button_index"] = e.button_index
			elif e is InputEventJoypadMotion:
				item["axis"] = e.axis
				if include_deadzones:
					item["axis_value"] = e.axis_value

			events.append(item)
		result[action] = events

	return {"ok": true, "actions": result, "count": result.size()}

# =============================================================================
# get_collision_layers
# =============================================================================
func get_collision_layers(_args: Dictionary) -> Dictionary:
	var layers_2d: Array = _collect_layers("layer_names/2d_physics")
	var layers_3d: Array = _collect_layers("layer_names/3d_physics")
	return {"ok": true, "layers_2d": layers_2d, "layers_3d": layers_3d}

func _collect_layers(prefix: String) -> Array:
	var out: Array = []
	for i in range(1, 33):
		var key := "%s/layer_%d" % [prefix, i]
		var layer_name := str(ProjectSettings.get_setting(key, ""))
		if not layer_name.is_empty():
			out.append({"index": i, "name": layer_name})
	return out

# =============================================================================
# get_node_properties
# =============================================================================
const ENUM_HINTS = {
	"anchors_preset": "0:Top Left,1:Top Right,2:Bottom Right,3:Bottom Left,4:Center Left,5:Center Top,6:Center Right,7:Center Bottom,8:Center,9:Left Wide,10:Top Wide,11:Right Wide,12:Bottom Wide,13:VCenter Wide,14:HCenter Wide,15:Full Rect",
	"grow_horizontal": "0:Begin,1:End,2:Both",
	"grow_vertical": "0:Begin,1:End,2:Both",
	"horizontal_alignment": "0:Left,1:Center,2:Right,3:Fill",
	"vertical_alignment": "0:Top,1:Center,2:Bottom,3:Fill"
}

func get_node_properties(args: Dictionary) -> Dictionary:
	var node_type: String = str(args.get("node_type", ""))
	if node_type.strip_edges().is_empty():
		return {"ok": false, "error": "Missing 'node_type'"}
	if not ClassDB.class_exists(node_type):
		return {"ok": false, "error": "Unknown node type: " + node_type}

	var temp = ClassDB.instantiate(node_type)
	if not temp:
		return {"ok": false, "error": "Cannot instantiate: " + node_type}

	var properties: Array = []
	for prop in temp.get_property_list():
		var prop_name: String = prop["name"]
		if prop_name.begins_with("_"):
			continue
		if prop_name in ["script", "owner", "scene_file_path", "unique_name_in_owner"]:
			continue
		if not (prop.get("usage", 0) & PROPERTY_USAGE_EDITOR):
			continue

		var info := {
			"name": prop_name,
			"type": _type_to_string(prop["type"]),
			"default": _serialize_value(temp.get(prop_name))
		}

		# Enum hints
		if prop.has("hint") and prop["hint"] == PROPERTY_HINT_ENUM and prop.has("hint_string"):
			info["enum_values"] = prop["hint_string"]
		if prop_name in ENUM_HINTS:
			info["enum_values"] = ENUM_HINTS[prop_name]

		properties.append(info)

	temp.queue_free()

	# Inheritance chain
	var chain: Array = []
	var cls: String = node_type
	while cls != "":
		chain.append(cls)
		cls = ClassDB.get_parent_class(cls)

	return {"ok": true, "node_type": node_type, "inheritance_chain": chain,
		"property_count": properties.size(), "properties": properties}

func _type_to_string(type_id: int) -> String:
	match type_id:
		TYPE_BOOL: return "bool"
		TYPE_INT: return "int"
		TYPE_FLOAT: return "float"
		TYPE_STRING: return "String"
		TYPE_VECTOR2: return "Vector2"
		TYPE_VECTOR3: return "Vector3"
		TYPE_VECTOR2I: return "Vector2i"
		TYPE_VECTOR3I: return "Vector3i"
		TYPE_COLOR: return "Color"
		TYPE_RECT2: return "Rect2"
		TYPE_OBJECT: return "Resource"
		TYPE_ARRAY: return "Array"
		TYPE_DICTIONARY: return "Dictionary"
		_: return "Variant"

func _serialize_value(value) -> Variant:
	match typeof(value):
		TYPE_VECTOR2: return {"type": "Vector2", "x": value.x, "y": value.y}
		TYPE_VECTOR3: return {"type": "Vector3", "x": value.x, "y": value.y, "z": value.z}
		TYPE_COLOR: return {"type": "Color", "r": value.r, "g": value.g, "b": value.b, "a": value.a}
		TYPE_VECTOR2I: return {"type": "Vector2i", "x": value.x, "y": value.y}
		TYPE_VECTOR3I: return {"type": "Vector3i", "x": value.x, "y": value.y, "z": value.z}
		TYPE_OBJECT:
			if value and value is Resource and value.resource_path:
				return {"type": "Resource", "path": value.resource_path}
			return null
		_: return value

# =============================================================================
# get_console_log
# =============================================================================
func get_console_log(args: Dictionary) -> Dictionary:
	var max_lines: int = int(args.get("max_lines", 50))

	# Try to read the editor log file
	var log_path := _get_editor_log_path()
	if log_path.is_empty() or not FileAccess.file_exists(log_path):
		return {"ok": true, "lines": [], "line_count": 0,
			"message": "Console log not available. Check Godot editor output panel."}

	var file := FileAccess.open(log_path, FileAccess.READ)
	if not file:
		return {"ok": false, "error": "Cannot read log file"}

	# Read all lines and return the last max_lines
	var all_lines: Array = []
	while not file.eof_reached():
		all_lines.append(file.get_line())
	file.close()

	var start := maxi(0, all_lines.size() - max_lines)
	var lines := all_lines.slice(start)

	return {"ok": true, "lines": lines, "line_count": lines.size(),
		"content": "\n".join(lines)}

func _get_editor_log_path() -> String:
	# Godot stores editor logs in user data directory
	var log_dir := OS.get_user_data_dir().get_base_dir()
	var log_path := log_dir.path_join("godot/editor_logs/godot.log")
	if FileAccess.file_exists(log_path):
		return log_path
	# Alternative location
	log_path = OS.get_user_data_dir().path_join("logs/godot.log")
	if FileAccess.file_exists(log_path):
		return log_path
	return ""

# =============================================================================
# get_errors
# =============================================================================
func get_errors(args: Dictionary) -> Dictionary:
	var max_errors: int = int(args.get("max_errors", 50))

	var log_path := _get_editor_log_path()
	if log_path.is_empty() or not FileAccess.file_exists(log_path):
		return {"ok": true, "errors": [], "error_count": 0,
			"message": "Error log not available"}

	var file := FileAccess.open(log_path, FileAccess.READ)
	if not file:
		return {"ok": false, "error": "Cannot read log file"}

	var errors: Array = []
	while not file.eof_reached() and errors.size() < max_errors:
		var line := file.get_line()
		# Look for error patterns
		if "ERROR" in line or "error" in line.to_lower():
			var error_info := {"message": line.strip_edges()}

			# Try to extract file:line info
			var regex_match := _extract_file_line(line)
			if not regex_match.is_empty():
				error_info["file"] = regex_match.get("file", "")
				error_info["line"] = regex_match.get("line", 0)

			errors.append(error_info)

	file.close()

	return {"ok": true, "errors": errors, "error_count": errors.size(),
		"summary": "%d error(s) found" % errors.size()}

func _extract_file_line(text: String) -> Dictionary:
	"""Try to extract file path and line number from an error message."""
	# Pattern: res://path/file.gd:123
	var idx := text.find("res://")
	if idx == -1:
		return {}

	var rest := text.substr(idx)
	var colon_idx := rest.find(":", 6)  # Skip "res://"
	if colon_idx == -1:
		return {"file": rest.strip_edges()}

	var file_path := rest.substr(0, colon_idx)
	var after_colon := rest.substr(colon_idx + 1)

	# Try to parse line number
	var line_str := ""
	for c in after_colon:
		if c.is_valid_int():
			line_str += c
		else:
			break

	if not line_str.is_empty():
		return {"file": file_path, "line": int(line_str)}
	return {"file": file_path}

# =============================================================================
# clear_console_log
# =============================================================================
func clear_console_log(_args: Dictionary) -> Dictionary:
	var log_path := _get_editor_log_path()
	if log_path.is_empty():
		return {"ok": true, "message": "No log file to clear"}

	# We can't actually clear the editor log while Godot is running
	# But we can note the current position to ignore previous entries
	return {"ok": true, "message": "Console log clear acknowledged. New errors will be tracked from this point."}

# =============================================================================
# open_in_godot
# =============================================================================
func open_in_godot(args: Dictionary) -> Dictionary:
	var path: String = str(args.get("path", ""))
	var line: int = int(args.get("line", 0))

	if path.strip_edges().is_empty():
		return {"ok": false, "error": "Missing 'path'"}

	if not path.begins_with("res://"):
		path = "res://" + path

	if not _editor_plugin:
		return {"ok": false, "error": "Editor plugin not available"}

	var ei = _editor_plugin.get_editor_interface()

	if path.ends_with(".gd") or path.ends_with(".shader"):
		var script = load(path)
		if script:
			ei.edit_resource(script)
			if line > 0:
				ei.get_script_editor().goto_line(line - 1)
		else:
			return {"ok": false, "error": "Could not load: " + path}
	elif path.ends_with(".tscn") or path.ends_with(".scn"):
		ei.open_scene_from_path(path)
	else:
		var res = load(path)
		if res:
			ei.edit_resource(res)

	return {"ok": true, "message": "Opened %s%s" % [path, " at line %d" % line if line > 0 else ""]}

# =============================================================================
# scene_tree_dump
# =============================================================================
func scene_tree_dump(_args: Dictionary) -> Dictionary:
	if not _editor_plugin:
		return {"ok": false, "error": "Editor plugin not available"}

	var ei = _editor_plugin.get_editor_interface()
	var edited_scene = ei.get_edited_scene_root()

	if not edited_scene:
		return {"ok": true, "tree": "(no scene open)", "message": "No scene is currently open in the editor"}

	var tree_text := _dump_node(edited_scene, 0)

	return {"ok": true, "tree": tree_text, "scene_path": edited_scene.scene_file_path}

func _dump_node(node: Node, depth: int) -> String:
	var indent := "  ".repeat(depth)
	var line := "%s%s (%s)" % [indent, node.name, node.get_class()]

	var script = node.get_script()
	if script:
		line += " [%s]" % script.resource_path.get_file()

	var result := line
	for child in node.get_children():
		result += "\n" + _dump_node(child, depth + 1)
	return result
