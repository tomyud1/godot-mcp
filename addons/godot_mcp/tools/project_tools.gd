@tool
extends Node
class_name ProjectTools
## Project configuration and debug tools for MCP.
## Handles: get_project_settings, list_settings, update_project_settings,
##          get_input_map, configure_input_map, get_collision_layers,
##          get_node_properties, setup_autoload,
##          get_console_log, get_errors, clear_console_log,
##          open_in_godot, scene_tree_dump

var _editor_plugin: EditorPlugin = null

# Cached reference to the editor Output panel's RichTextLabel.
var _editor_log_rtl: RichTextLabel = null

# Cached reference to the Debugger > Errors tab's Tree widget.
var _debugger_error_tree: Tree = null

# Character offset for clear_console_log.
var _clear_char_offset: int = 0

func set_editor_plugin(plugin: EditorPlugin) -> void:
	_editor_plugin = plugin

# =============================================================================
# get_project_settings
# =============================================================================
func get_project_settings(args: Dictionary) -> Dictionary:
	var include_render: bool = bool(args.get(&"include_render", true))
	var include_physics: bool = bool(args.get(&"include_physics", true))

	var out: Dictionary = {}
	out[&"main_scene"] = str(ProjectSettings.get_setting("application/run/main_scene", ""))

	# Window size
	var width = ProjectSettings.get_setting("display/window/size/viewport_width", null)
	var height = ProjectSettings.get_setting("display/window/size/viewport_height", null)
	if width != null: out[&"window_width"] = int(width)
	if height != null: out[&"window_height"] = int(height)

	# Stretch
	var stretch_mode = ProjectSettings.get_setting("display/window/stretch/mode", null)
	var stretch_aspect = ProjectSettings.get_setting("display/window/stretch/aspect", null)
	if stretch_mode != null: out[&"stretch_mode"] = str(stretch_mode)
	if stretch_aspect != null: out[&"stretch_aspect"] = str(stretch_aspect)

	if include_physics:
		var pps = ProjectSettings.get_setting("physics/common/physics_ticks_per_second", null)
		if pps != null: out[&"physics_ticks_per_second"] = int(pps)

	if include_render:
		var method = ProjectSettings.get_setting("rendering/renderer/rendering_method", null)
		if method != null: out[&"rendering_method"] = str(method)
		var vsync = ProjectSettings.get_setting("display/window/vsync/vsync_mode", null)
		if vsync != null: out[&"vsync"] = str(vsync)

	return {&"ok": true, &"settings": out}

# =============================================================================
# list_settings
# =============================================================================
func list_settings(args: Dictionary) -> Dictionary:
	var category: String = str(args.get(&"category", ""))

	var properties: Array = ProjectSettings.get_property_list()

	if category.strip_edges().is_empty():
		var categories: Dictionary = {}
		for prop: Dictionary in properties:
			var prop_name: String = prop[&"name"]
			if prop_name.is_empty() or prop_name.begins_with("_"):
				continue
			var slash_idx := prop_name.find("/")
			if slash_idx == -1:
				continue
			var cat: String = prop_name.substr(0, slash_idx)
			categories[cat] = categories.get(cat, 0) + 1
		return {&"ok": true, &"categories": categories,
			&"hint": "Pass a category name to list its settings with current values and valid options."}

	var settings: Array = []
	for prop: Dictionary in properties:
		var prop_name: String = prop[&"name"]
		if not prop_name.begins_with(category + "/"):
			continue
		if prop_name.begins_with("_"):
			continue

		var info: Dictionary = {
			&"path": prop_name,
			&"type": _type_to_string(prop[&"type"]),
			&"value": _serialize_value(ProjectSettings.get_setting(prop_name))
		}

		var hint: int = prop.get(&"hint", 0)
		var hint_string: String = str(prop.get(&"hint_string", ""))
		if hint == PROPERTY_HINT_ENUM and not hint_string.is_empty():
			info[&"enum_values"] = hint_string
		elif hint == PROPERTY_HINT_RANGE and not hint_string.is_empty():
			info[&"range"] = hint_string

		settings.append(info)

	return {&"ok": true, &"category": category, &"settings": settings, &"count": settings.size()}

# =============================================================================
# update_project_settings
# =============================================================================
func update_project_settings(args: Dictionary) -> Dictionary:
	var settings = args.get(&"settings", {})
	if not settings is Dictionary or settings.is_empty():
		return {&"ok": false, &"error": "Missing or empty 'settings' dictionary. Use list_settings to discover available setting paths."}

	var updated: Array = []
	for key: String in settings:
		ProjectSettings.set_setting(key, settings[key])
		updated.append(key)

	_save_and_refresh_settings()
	return {&"ok": true, &"updated": updated, &"count": updated.size()}

# =============================================================================
# get_input_map
# =============================================================================
func get_input_map(args: Dictionary) -> Dictionary:
	var include_deadzones: bool = bool(args.get(&"include_deadzones", true))
	var actions: Array = InputMap.get_actions()
	actions.sort()

	var result: Dictionary = {}
	for action: StringName in actions:
		var events: Array = []
		for e: InputEvent in InputMap.action_get_events(action):
			var item := {&"type": e.get_class()}

			if e is InputEventKey:
				var keycode = e.physical_keycode if e.physical_keycode != 0 else e.keycode
				item[&"keycode"] = keycode
				item[&"key_label"] = OS.get_keycode_string(keycode) if keycode != 0 else ""
			elif e is InputEventMouseButton:
				item[&"button_index"] = e.button_index
			elif e is InputEventJoypadButton:
				item[&"button_index"] = e.button_index
			elif e is InputEventJoypadMotion:
				item[&"axis"] = e.axis
				if include_deadzones:
					item[&"axis_value"] = e.axis_value

			events.append(item)
		result[action] = events

	return {&"ok": true, &"actions": result, &"count": result.size()}

# =============================================================================
# configure_input_map
# =============================================================================
func configure_input_map(args: Dictionary) -> Dictionary:
	var action: String = str(args.get(&"action", ""))
	var operation: String = str(args.get(&"operation", ""))

	if action.strip_edges().is_empty():
		return {&"ok": false, &"error": "Missing 'action' name"}
	if operation.strip_edges().is_empty():
		return {&"ok": false, &"error": "Missing 'operation'. Use: add, remove, set"}

	match operation:
		"add":
			return _input_map_add(action, args)
		"remove":
			return _input_map_remove(action)
		"set":
			return _input_map_set(action, args)
		_:
			return {&"ok": false, &"error": "Unknown operation: %s. Use: add, remove, set" % operation}

func _input_map_add(action: String, args: Dictionary) -> Dictionary:
	var deadzone: float = float(args.get(&"deadzone", 0.5))
	var events_data: Array = args.get(&"events", [])

	var created := false
	if not InputMap.has_action(action):
		InputMap.add_action(action, deadzone)
		created = true

	var added_events: Array = []
	var event_errors: Array = []
	for event_desc in events_data:
		if not event_desc is Dictionary:
			continue
		var result: Dictionary = _create_input_event(event_desc)
		if result.has(&"error"):
			event_errors.append(result[&"error"])
			continue
		InputMap.action_add_event(action, result[&"event"])
		added_events.append(_describe_event(result[&"event"]))

	_persist_action(action)
	_save_and_refresh_settings()
	_try_refresh_input_map_ui()

	var msg := "Action '%s' %s" % [action, "created" if created else "updated"]
	if added_events.size() > 0:
		msg += " with %d event(s)" % added_events.size()

	var out: Dictionary = {&"ok": true, &"message": msg, &"events_added": added_events}
	if event_errors.size() > 0:
		out[&"event_errors"] = event_errors
	return out

func _input_map_remove(action: String) -> Dictionary:
	if not InputMap.has_action(action):
		return {&"ok": false, &"error": "Action not found: " + action}

	InputMap.erase_action(action)
	if ProjectSettings.has_setting("input/" + action):
		ProjectSettings.clear("input/" + action)
	_save_and_refresh_settings()
	_try_refresh_input_map_ui()

	return {&"ok": true, &"message": "Removed action: " + action}

func _input_map_set(action: String, args: Dictionary) -> Dictionary:
	var deadzone: float = float(args.get(&"deadzone", 0.5))
	var events_data: Array = args.get(&"events", [])

	if InputMap.has_action(action):
		InputMap.erase_action(action)

	InputMap.add_action(action, deadzone)

	var added_events: Array = []
	var event_errors: Array = []
	for event_desc in events_data:
		if not event_desc is Dictionary:
			continue
		var result: Dictionary = _create_input_event(event_desc)
		if result.has(&"error"):
			event_errors.append(result[&"error"])
			continue
		InputMap.action_add_event(action, result[&"event"])
		added_events.append(_describe_event(result[&"event"]))

	_persist_action(action)
	_save_and_refresh_settings()
	_try_refresh_input_map_ui()

	var out: Dictionary = {&"ok": true, &"message": "Set action '%s' with %d event(s)" % [action, added_events.size()], &"events": added_events}
	if event_errors.size() > 0:
		out[&"event_errors"] = event_errors
	return out

func _create_input_event(desc: Dictionary) -> Dictionary:
	var type: String = str(desc.get(&"type", ""))

	match type:
		"key":
			var key_string: String = str(desc.get(&"key", ""))
			if key_string.is_empty():
				return {&"error": "Missing 'key' for key event"}
			var event := InputEventKey.new()
			var keycode := OS.find_keycode_from_string(key_string)
			if keycode == 0:
				return {&"error": "Unknown key: " + key_string}
			event.physical_keycode = keycode
			return {&"event": event}

		"mouse_button":
			var button_index: int = int(desc.get(&"button_index", 0))
			if button_index <= 0:
				return {&"error": "Invalid 'button_index' for mouse_button (must be >= 1: 1=left, 2=right, 3=middle)"}
			var event := InputEventMouseButton.new()
			event.button_index = button_index
			return {&"event": event}

		"joypad_button":
			var button_index: int = int(desc.get(&"button_index", -1))
			if button_index < 0:
				return {&"error": "Missing or invalid 'button_index' for joypad_button"}
			var event := InputEventJoypadButton.new()
			event.button_index = button_index
			return {&"event": event}

		"joypad_motion":
			var axis: int = int(desc.get(&"axis", -1))
			if axis < 0:
				return {&"error": "Missing or invalid 'axis' for joypad_motion"}
			var axis_value: float = float(desc.get(&"axis_value", 0.0))
			var event := InputEventJoypadMotion.new()
			event.axis = axis
			event.axis_value = axis_value
			return {&"event": event}

		_:
			return {&"error": "Unknown event type: '%s'. Use: key, mouse_button, joypad_button, joypad_motion" % type}

func _save_and_refresh_settings() -> void:
	ProjectSettings.save()
	ProjectSettings.notify_property_list_changed()

func _try_refresh_input_map_ui() -> void:
	if not _editor_plugin:
		return
	var base := _editor_plugin.get_editor_interface().get_base_control()
	var pse := _find_node_by_class(base, "ProjectSettingsEditor")
	if not pse:
		return
	if pse.has_method("_update_action_map_editor"):
		pse.call("_update_action_map_editor")
	else:
		push_warning("[Godot MCP] Input map changed and saved, but the editor UI could not refresh. Reopen Project Settings to see changes.")

func _persist_action(action: String) -> void:
	if not InputMap.has_action(action):
		return
	var deadzone: float = InputMap.action_get_deadzone(action)
	var events: Array = InputMap.action_get_events(action)
	ProjectSettings.set_setting("input/" + action, {
		"deadzone": deadzone,
		"events": events
	})

func _describe_event(event: InputEvent) -> String:
	if event is InputEventKey:
		var keycode: int = event.physical_keycode if event.physical_keycode != 0 else event.keycode
		var label: String = OS.get_keycode_string(keycode) if keycode != 0 else "Unknown"
		return "Key: " + label
	elif event is InputEventMouseButton:
		return "Mouse Button: " + str(event.button_index)
	elif event is InputEventJoypadButton:
		return "Joypad Button: " + str(event.button_index)
	elif event is InputEventJoypadMotion:
		return "Joypad Axis: %d (%.1f)" % [event.axis, event.axis_value]
	return event.get_class()

# =============================================================================
# get_collision_layers
# =============================================================================
func get_collision_layers(_args: Dictionary) -> Dictionary:
	var layers_2d: Array = _collect_layers("layer_names/2d_physics")
	var layers_3d: Array = _collect_layers("layer_names/3d_physics")
	return {&"ok": true, &"layers_2d": layers_2d, &"layers_3d": layers_3d}

func _collect_layers(prefix: String) -> Array:
	var out: Array = []
	for i: int in range(1, 33):
		var key := "%s/layer_%d" % [prefix, i]
		var layer_name := str(ProjectSettings.get_setting(key, ""))
		if not layer_name.is_empty():
			out.append({&"index": i, &"name": layer_name})
	return out

# =============================================================================
# get_node_properties
# =============================================================================
const _SKIP_PROPS: Dictionary = {
	"script": true, "owner": true, "scene_file_path": true, "unique_name_in_owner": true,
}

const ENUM_HINTS = {
	"anchors_preset": "0:Top Left,1:Top Right,2:Bottom Right,3:Bottom Left,4:Center Left,5:Center Top,6:Center Right,7:Center Bottom,8:Center,9:Left Wide,10:Top Wide,11:Right Wide,12:Bottom Wide,13:VCenter Wide,14:HCenter Wide,15:Full Rect",
	"grow_horizontal": "0:Begin,1:End,2:Both",
	"grow_vertical": "0:Begin,1:End,2:Both",
	"horizontal_alignment": "0:Left,1:Center,2:Right,3:Fill",
	"vertical_alignment": "0:Top,1:Center,2:Bottom,3:Fill"
}

func get_node_properties(args: Dictionary) -> Dictionary:
	var node_type: String = str(args.get(&"node_type", ""))
	if node_type.strip_edges().is_empty():
		return {&"ok": false, &"error": "Missing 'node_type'"}
	if not ClassDB.class_exists(node_type):
		return {&"ok": false, &"error": "Unknown node type: " + node_type}

	var temp = ClassDB.instantiate(node_type)
	if not temp:
		return {&"ok": false, &"error": "Cannot instantiate: " + node_type}

	var properties: Array = []
	for prop: Dictionary in temp.get_property_list():
		var prop_name: String = prop[&"name"]
		if prop_name.begins_with("_"):
			continue
		if _SKIP_PROPS.has(prop_name):
			continue
		if not (prop.get(&"usage", 0) & PROPERTY_USAGE_EDITOR):
			continue

		var info := {
			&"name": prop_name,
			&"type": _type_to_string(prop[&"type"]),
			&"default": _serialize_value(temp.get(prop_name))
		}

		# Enum hints
		if prop.has(&"hint") and prop[&"hint"] == PROPERTY_HINT_ENUM and prop.has(&"hint_string"):
			info[&"enum_values"] = prop[&"hint_string"]
		if prop_name in ENUM_HINTS:
			info[&"enum_values"] = ENUM_HINTS[prop_name]

		properties.append(info)

	temp.queue_free()

	# Inheritance chain
	var chain: Array = []
	var cls: String = node_type
	while cls != "":
		chain.append(cls)
		cls = ClassDB.get_parent_class(cls)

	return {&"ok": true, &"node_type": node_type, &"inheritance_chain": chain,
		&"property_count": properties.size(), &"properties": properties}

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

func _serialize_value(value: Variant) -> Variant:
	match typeof(value):
		TYPE_VECTOR2: return {&"type": &"Vector2", &"x": value.x, &"y": value.y}
		TYPE_VECTOR3: return {&"type": &"Vector3", &"x": value.x, &"y": value.y, &"z": value.z}
		TYPE_COLOR: return {&"type": &"Color", &"r": value.r, &"g": value.g, &"b": value.b, &"a": value.a}
		TYPE_VECTOR2I: return {&"type": &"Vector2i", &"x": value.x, &"y": value.y}
		TYPE_VECTOR3I: return {&"type": &"Vector3i", &"x": value.x, &"y": value.y, &"z": value.z}
		TYPE_OBJECT:
			if value and value is Resource and value.resource_path:
				return {&"type": &"Resource", &"path": value.resource_path}
			return null
		_: return value

# =============================================================================
# setup_autoload
# =============================================================================
func setup_autoload(args: Dictionary) -> Dictionary:
	var operation: String = str(args.get(&"operation", ""))

	if operation.strip_edges().is_empty():
		return {&"ok": false, &"error": "Missing 'operation'. Use: add, remove, list"}

	match operation:
		"list":
			return _autoload_list()
		"add":
			return _autoload_add(args)
		"remove":
			return _autoload_remove(args)
		_:
			return {&"ok": false, &"error": "Unknown operation: %s. Use: add, remove, list" % operation}

func _autoload_list() -> Dictionary:
	var autoloads: Array = []
	for prop: Dictionary in ProjectSettings.get_property_list():
		var prop_name: String = prop[&"name"]
		if not prop_name.begins_with("autoload/"):
			continue
		var al_name: String = prop_name.substr(9)
		var al_path: String = str(ProjectSettings.get_setting(prop_name, ""))
		var enabled: bool = al_path.begins_with("*")
		if enabled:
			al_path = al_path.substr(1)
		autoloads.append({&"name": al_name, &"path": al_path, &"enabled": enabled})
	return {&"ok": true, &"autoloads": autoloads, &"count": autoloads.size()}

func _autoload_add(args: Dictionary) -> Dictionary:
	var autoload_name: String = str(args.get(&"name", ""))
	var path: String = str(args.get(&"path", ""))

	if autoload_name.strip_edges().is_empty():
		return {&"ok": false, &"error": "Missing 'name'"}
	if path.strip_edges().is_empty():
		return {&"ok": false, &"error": "Missing 'path' for add operation"}

	if not path.begins_with("res://"):
		path = "res://" + path
	if not FileAccess.file_exists(path):
		return {&"ok": false, &"error": "File not found: " + path}

	var setting_key := "autoload/" + autoload_name
	ProjectSettings.set_setting(setting_key, "*" + path)
	_save_and_refresh_settings()

	return {&"ok": true, &"message": "Registered autoload: %s -> %s" % [autoload_name, path]}

func _autoload_remove(args: Dictionary) -> Dictionary:
	var autoload_name: String = str(args.get(&"name", ""))

	if autoload_name.strip_edges().is_empty():
		return {&"ok": false, &"error": "Missing 'name'"}

	var setting_key := "autoload/" + autoload_name
	if not ProjectSettings.has_setting(setting_key):
		return {&"ok": false, &"error": "Autoload not found: " + autoload_name}

	ProjectSettings.clear(setting_key)
	_save_and_refresh_settings()

	return {&"ok": true, &"message": "Unregistered autoload: " + autoload_name}

# =============================================================================
# Editor Output Panel access
# =============================================================================
# We read directly from the editor's internal EditorLog RichTextLabel.
# This is real-time and matches exactly what the user sees in the Output panel.
# =============================================================================

func _get_editor_log_rtl() -> RichTextLabel:
	"""Find (and cache) the RichTextLabel inside the editor's Output panel."""
	if is_instance_valid(_editor_log_rtl):
		return _editor_log_rtl
	if not _editor_plugin:
		return null
	var base := _editor_plugin.get_editor_interface().get_base_control()
	var editor_log := _find_node_by_class(base, "EditorLog")
	if editor_log:
		_editor_log_rtl = _find_child_rtl(editor_log)
	return _editor_log_rtl

func _find_node_by_class(root: Node, cls_name: String) -> Node:
	if root.get_class() == cls_name:
		return root
	for child: Node in root.get_children():
		var found := _find_node_by_class(child, cls_name)
		if found:
			return found
	return null

func _find_child_rtl(node: Node) -> RichTextLabel:
	for child: Node in node.get_children():
		if child is RichTextLabel:
			return child
		var found := _find_child_rtl(child)
		if found:
			return found
	return null

func _read_output_panel_lines() -> Array:
	"""Return all non-empty lines from the editor Output panel (after clear offset)."""
	var rtl := _get_editor_log_rtl()
	if not rtl:
		return []
	var full_text: String = rtl.get_parsed_text()
	if _clear_char_offset > 0 and _clear_char_offset < full_text.length():
		full_text = full_text.substr(_clear_char_offset)
	elif _clear_char_offset >= full_text.length():
		return []
	var lines: Array = []
	for line: String in full_text.split("\n"):
		if not line.strip_edges().is_empty():
			lines.append(line)
	return lines

# =============================================================================
# get_console_log
# =============================================================================
func get_console_log(args: Dictionary) -> Dictionary:
	var max_lines: int = int(args.get(&"max_lines", 50))

	var rtl := _get_editor_log_rtl()
	if not rtl:
		return {&"ok": false,
			&"error": "Could not access the Godot editor Output panel. Make sure the MCP plugin is enabled and running inside the Godot editor."}

	var all_lines := _read_output_panel_lines()
	var start := maxi(0, all_lines.size() - max_lines)
	var lines := all_lines.slice(start)
	return {&"ok": true, &"lines": lines, &"line_count": lines.size(),
		&"content": "\n".join(lines)}

# =============================================================================
# get_errors
# =============================================================================
const _ERROR_PREFIXES: PackedStringArray = [
	"ERROR:", "SCRIPT ERROR:", "USER ERROR:",
	"WARNING:", "USER WARNING:", "SCRIPT WARNING:",
	"Parse Error:", "Invalid",
]

func get_errors(args: Dictionary) -> Dictionary:
	var max_errors: int = int(args.get(&"max_errors", 50))
	var include_warnings: bool = bool(args.get(&"include_warnings", true))

	var all_errors: Array = []

	# Source 1: Output panel
	var rtl := _get_editor_log_rtl()
	if rtl:
		var all_lines := _read_output_panel_lines()
		for i: int in range(all_lines.size()):
			var line: String = all_lines[i].strip_edges()
			if line.is_empty():
				continue

			var is_error := false
			var severity := "error"
			for prefix: String in _ERROR_PREFIXES:
				if line.begins_with(prefix):
					is_error = true
					if "WARNING" in prefix:
						severity = "warning"
					break

			if not is_error and line.begins_with("at: ") and "res://" in line:
				if all_errors.size() > 0:
					var prev: Dictionary = all_errors[all_errors.size() - 1]
					var loc := _extract_file_line(line)
					if not loc.is_empty():
						prev[&"file"] = loc.get(&"file", "")
						prev[&"line"] = loc.get(&"line", 0)
				continue

			if not is_error:
				continue
			if severity == "warning" and not include_warnings:
				continue

			var error_info := {&"message": line, &"severity": severity, &"source": &"output"}
			var loc := _extract_file_line(line)
			if not loc.is_empty():
				error_info[&"file"] = loc.get(&"file", "")
				error_info[&"line"] = loc.get(&"line", 0)
			all_errors.append(error_info)

	# Source 2: Debugger > Errors tab
	var dbg_errors := _read_debugger_errors(include_warnings)
	all_errors.append_array(dbg_errors)

	var start := maxi(0, all_errors.size() - max_errors)
	var errors := all_errors.slice(start)
	return {&"ok": true, &"errors": errors, &"error_count": errors.size(),
		&"summary": "%d error(s) found" % errors.size()}

func _extract_file_line(text: String) -> Dictionary:
	var idx := text.find("res://")
	if idx == -1:
		return {}
	var rest := text.substr(idx)
	var colon_idx := rest.find(":", 6)
	if colon_idx == -1:
		return {&"file": rest.strip_edges()}
	var file_path := rest.substr(0, colon_idx)
	var after_colon := rest.substr(colon_idx + 1)
	var line_str := ""
	for c in after_colon:
		if c.is_valid_int():
			line_str += c
		else:
			break
	if not line_str.is_empty():
		return {&"file": file_path, &"line": int(line_str)}
	return {&"file": file_path}

func _read_debugger_errors(include_warnings: bool) -> Array:
	var tree := _get_debugger_error_tree()
	if not tree:
		return []
	var root := tree.get_root()
	if not root:
		return []

	var errors: Array = []
	var item := root.get_first_child()
	while item:
		var col_count := tree.columns
		var parts: Array = []
		for col: int in range(col_count):
			var text: String = item.get_text(col)
			if not text.strip_edges().is_empty():
				parts.append(text)
		var message: String = " | ".join(parts) if not parts.is_empty() else ""

		if message.strip_edges().is_empty():
			item = item.get_next()
			continue

		var severity := "error"
		if "warning" in message.to_lower():
			severity = "warning"

		if severity == "warning" and not include_warnings:
			item = item.get_next()
			continue

		var error_info := {&"message": message, &"severity": severity, &"source": &"debugger"}

		var loc := _extract_file_line(message)
		if not loc.is_empty():
			error_info[&"file"] = loc.get(&"file", "")
			error_info[&"line"] = loc.get(&"line", 0)

		var stack_trace: Array = []
		var child_item := item.get_first_child()
		while child_item:
			var trace_parts: Array = []
			for col: int in range(col_count):
				var t: String = child_item.get_text(col)
				if not t.strip_edges().is_empty():
					trace_parts.append(t)
			if not trace_parts.is_empty():
				stack_trace.append(" | ".join(trace_parts))
			child_item = child_item.get_next()
		if not stack_trace.is_empty():
			error_info[&"stack_trace"] = stack_trace

		errors.append(error_info)
		item = item.get_next()

	return errors

func _get_debugger_error_tree() -> Tree:
	if is_instance_valid(_debugger_error_tree):
		return _debugger_error_tree
	if not _editor_plugin:
		return null
	var base := _editor_plugin.get_editor_interface().get_base_control()
	var debugger := _find_node_by_class(base, "ScriptEditorDebugger")
	if not debugger:
		return null
	var tree := _find_error_tree(debugger)
	if tree:
		_debugger_error_tree = tree
	return _debugger_error_tree

func _find_error_tree(node: Node) -> Tree:
	var candidates: Array[Tree] = []
	_collect_trees(node, candidates)
	for tree: Tree in candidates:
		var p := tree.get_parent()
		while p and p != node:
			if "Error" in p.name or "error" in p.name:
				return tree
			p = p.get_parent()
	if not candidates.is_empty():
		return candidates[0]
	return null

func _collect_trees(node: Node, out: Array[Tree]) -> void:
	if node is Tree:
		out.append(node as Tree)
	for child: Node in node.get_children():
		_collect_trees(child, out)

# =============================================================================
# clear_console_log
# =============================================================================
func clear_console_log(_args: Dictionary) -> Dictionary:
	var rtl := _get_editor_log_rtl()
	if not rtl:
		return {&"ok": false,
			&"error": "Could not access the Godot editor Output panel. Make sure the MCP plugin is enabled and running inside the Godot editor."}

	# Actually clear the editor Output panel
	rtl.clear()
	_clear_char_offset = 0
	return {&"ok": true,
		&"message": "Console log cleared."}

# =============================================================================
# open_in_godot
# =============================================================================
func open_in_godot(args: Dictionary) -> Dictionary:
	var path: String = str(args.get(&"path", ""))
	var line: int = int(args.get(&"line", 0))

	if path.strip_edges().is_empty():
		return {&"ok": false, &"error": "Missing 'path'"}

	if not path.begins_with("res://"):
		path = "res://" + path

	if not _editor_plugin:
		return {&"ok": false, &"error": "Editor plugin not available"}

	var ei = _editor_plugin.get_editor_interface()

	if path.ends_with(".gd") or path.ends_with(".shader"):
		var script = load(path)
		if script:
			ei.edit_resource(script)
			if line > 0:
				ei.get_script_editor().goto_line(line - 1)
		else:
			return {&"ok": false, &"error": "Could not load: " + path}
	elif path.ends_with(".tscn") or path.ends_with(".scn"):
		ei.open_scene_from_path(path)
	else:
		var res = load(path)
		if res:
			ei.edit_resource(res)

	return {&"ok": true, &"message": "Opened %s%s" % [path, " at line %d" % line if line > 0 else ""]}

# =============================================================================
# scene_tree_dump
# =============================================================================
func scene_tree_dump(_args: Dictionary) -> Dictionary:
	if not _editor_plugin:
		return {&"ok": false, &"error": "Editor plugin not available"}

	var ei = _editor_plugin.get_editor_interface()
	var edited_scene = ei.get_edited_scene_root()

	if not edited_scene:
		return {&"ok": true, &"tree": "(no scene open)", &"message": "No scene is currently open in the editor"}

	var tree_text := _dump_node(edited_scene, 0)

	return {&"ok": true, &"tree": tree_text, &"scene_path": edited_scene.scene_file_path}

func _dump_node(node: Node, depth: int) -> String:
	var indent := "  ".repeat(depth)
	var line := "%s%s (%s)" % [indent, node.name, node.get_class()]

	var script = node.get_script()
	if script:
		line += " [%s]" % script.resource_path.get_file()

	var children := node.get_children()
	if children.is_empty():
		return line

	var parts: PackedStringArray = [line]
	for child: Node in children:
		parts.append(_dump_node(child, depth + 1))
	return "\n".join(parts)

# =============================================================================
# run_scene / stop_scene / is_playing
# =============================================================================

func run_scene(args: Dictionary) -> Dictionary:
	if not _editor_plugin:
		return {&"ok": false, &"error": "Editor plugin not available"}
	var ei := _editor_plugin.get_editor_interface()
	var scene: String = str(args.get(&"scene", ""))

	if ei.is_playing_scene():
		return {&"ok": false, &"error": "A scene is already running. Call stop_scene first."}

	if scene == "current":
		ei.play_current_scene()
	elif not scene.is_empty():
		if not scene.begins_with("res://"):
			scene = "res://" + scene
		if not FileAccess.file_exists(scene):
			return {&"ok": false, &"error": "Scene file not found: %s" % scene}
		ei.play_custom_scene(scene)
	else:
		ei.play_main_scene()

	return {&"ok": true, &"message": "Scene launched" + (" (%s)" % scene if not scene.is_empty() else " (main scene)")}

func stop_scene(_args: Dictionary) -> Dictionary:
	if not _editor_plugin:
		return {&"ok": false, &"error": "Editor plugin not available"}
	var ei := _editor_plugin.get_editor_interface()
	if not ei.is_playing_scene():
		return {&"ok": true, &"message": "No scene is currently running"}
	ei.stop_playing_scene()
	return {&"ok": true, &"message": "Scene stopped"}

func is_playing(_args: Dictionary) -> Dictionary:
	if not _editor_plugin:
		return {&"ok": false, &"error": "Editor plugin not available"}
	var ei := _editor_plugin.get_editor_interface()
	var playing := ei.is_playing_scene()
	var scene_path := ei.get_playing_scene() if playing else ""
	return {&"ok": true, &"playing": playing, &"scene": scene_path}

# =============================================================================
# rescan_filesystem
# =============================================================================

func rescan_filesystem(_args: Dictionary) -> Dictionary:
	if not _editor_plugin:
		return {&"ok": false, &"error": "No editor plugin available"}
	var efs := _editor_plugin.get_editor_interface().get_resource_filesystem()
	if efs.is_scanning():
		return {&"ok": false, &"error": "A filesystem scan is already in progress. Wait and retry."}
	efs.scan()
	return {&"ok": true, &"message": "Filesystem rescan triggered."}

# =============================================================================
# classdb_query
# =============================================================================

const _WELL_KNOWN_VIRTUALS: Array[String] = [
	"_ready", "_process", "_physics_process", "_input", "_unhandled_input",
	"_unhandled_key_input", "_enter_tree", "_exit_tree", "_draw",
	"_gui_input", "_init", "_notification",
]

func classdb_query(args: Dictionary) -> Dictionary:
	var class_name_str: String = str(args.get(&"class_name", ""))
	if class_name_str.strip_edges().is_empty():
		return {&"ok": false, &"error": "Missing 'class_name'"}
	if not ClassDB.class_exists(class_name_str):
		return {&"ok": false, &"error": "Class '%s' does not exist in ClassDB" % class_name_str}

	var query: String = str(args.get(&"query", "all"))
	var include_virtual: bool = args.get(&"include_virtual", true)
	var result: Dictionary = {&"ok": true, &"class": class_name_str}

	result[&"parent_class"] = ClassDB.get_parent_class(class_name_str)

	if query == "all" or query == "properties":
		var props: Array = []
		for prop: Dictionary in ClassDB.class_get_property_list(class_name_str, true):
			if int(prop.get(&"usage", 0)) & PROPERTY_USAGE_EDITOR:
				props.append({&"name": prop[&"name"], &"type": type_string(int(prop[&"type"]))})
		result[&"properties"] = props

	if query == "all" or query == "methods":
		var methods: Array = []
		for method: Dictionary in ClassDB.class_get_method_list(class_name_str, true):
			var mname: String = method.get(&"name", "")
			if mname.begins_with("_"):
				if not include_virtual:
					continue
				if mname not in _WELL_KNOWN_VIRTUALS:
					continue
			var method_args: Array = []
			for arg: Dictionary in method.get(&"args", []):
				method_args.append({&"name": arg[&"name"], &"type": type_string(int(arg[&"type"]))})
			methods.append({&"name": mname, &"args": method_args,
				&"return_type": type_string(int(method.get(&"return", {}).get(&"type", 0)))})
		result[&"methods"] = methods

	if query == "all" or query == "signals":
		var signals_list: Array = []
		for sig: Dictionary in ClassDB.class_get_signal_list(class_name_str, true):
			var sig_args: Array = []
			for arg: Dictionary in sig.get(&"args", []):
				sig_args.append({&"name": arg[&"name"], &"type": type_string(int(arg[&"type"]))})
			signals_list.append({&"name": sig[&"name"], &"args": sig_args})
		result[&"signals"] = signals_list

	return result
