@tool
extends Node
class_name ProjectTools
## Project configuration and debug tools for MCP.
## Handles: get_project_settings, list_settings, update_project_settings,
##          get_input_map, configure_input_map, get_collision_layers,
##          get_node_properties, setup_autoload,
##          get_console_log, get_errors, clear_console_log,
##          open_in_godot, scene_tree_dump, close_editor_tabs

const VariantCodec = preload("res://addons/godot_mcp/utils/variant_codec.gd")
const MCPPaths = preload("res://addons/godot_mcp/utils/paths.gd")

var _editor_plugin: EditorPlugin = null

# Reference to the MCPClient in the addon. Set by the plugin so we can ask
# the TS server (via the editor WebSocket connection) whether the runtime
# helper is currently connected.
var _mcp_client: Object = null

func set_mcp_client(client: Object) -> void:
	_mcp_client = client

# Track the moment the editor most recently launched a scene so we can report
# uptime and detect "started but immediately crashed" cases.
var _last_run_scene_started_at_ms: int = 0
var _last_run_scene_target: String = ""

# Resolved res:// path of the most recently played scene. Used by
# _resolve_script_path to disambiguate basename collisions: the .tscn lists
# its ext_resource paths verbatim, so when an error mentions "foo.gd" and
# multiple foo.gd exist in the project, the one referenced by the most
# recently played scene is almost always the right one. (ResourceLoader's
# editor-side cache is unreliable post-stop_scene.)
var _last_run_scene_resolved_path: String = ""

# Cached reference to the editor Output panel's RichTextLabel.
var _editor_log_rtl: RichTextLabel = null

# Cached reference to the Debugger > Errors tab's Tree widget.
var _debugger_error_tree: Tree = null

# Read-side log watermarks. Both get_console_log / get_errors honor these so a
# fresh run_scene (or an explicit clear_console_log) starts the agent on a clean
# slate without destroying the human's editor scrollback. See _arm_log_watermark.
#   _clear_char_offset      char offset into the Output panel's parsed text
#   _debugger_error_baseline number of Debugger>Errors rows to skip
var _clear_char_offset: int = 0
var _debugger_error_baseline: int = 0

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

	var warnings: Array = []
	var rename_info: Dictionary = {}

	# Detect a config-name change BEFORE we apply it. Godot rebinds user://
	# whenever application/config/name changes, but does not create the new
	# folder on disk. The first FileAccess.WRITE into user:// then silently
	# fails. We pre-create the folder and warn the caller.
	if settings.has("application/config/name"):
		var old_name := str(ProjectSettings.get_setting("application/config/name", ""))
		var new_name := str(settings["application/config/name"])
		if old_name != new_name:
			rename_info = {
				&"setting": "application/config/name",
				&"old": old_name,
				&"new": new_name,
				&"warning": "Renaming the project changes the user:// path. Existing user:// files (saved games, settings, generated assets cached in user://) will appear to disappear because user:// now points at a different folder. The new folder will be auto-created."
			}
			warnings.append(rename_info)

	var updated: Array = []
	for key: String in settings:
		if key.begins_with("input/"):
			var existing = ProjectSettings.get_setting(key, {&"deadzone": 0.5, &"events": []})
			var merged: Dictionary = {&"deadzone": 0.5, &"events": []}
			if existing is Dictionary:
				merged = existing.duplicate()
			if settings[key] is Dictionary:
				merged.merge(settings[key], true)
			ProjectSettings.set_setting(key, merged)
		else:
			ProjectSettings.set_setting(key, settings[key])
		updated.append(key)

	_save_and_refresh_settings()

	# After the save, the new application/config/name takes effect. Make sure
	# user:// resolves to a real folder so subsequent tool calls don't fail.
	if not rename_info.is_empty():
		var ok := MCPPaths.ensure_user_dir()
		rename_info[&"new_user_path"] = MCPPaths.absolute_for("user://")
		rename_info[&"new_user_path_created"] = ok

	var out: Dictionary = {&"ok": true, &"updated": updated, &"count": updated.size()}
	if not warnings.is_empty():
		out[&"warnings"] = warnings
	return out

# =============================================================================
# get_input_map
# =============================================================================
func get_input_map(args: Dictionary) -> Dictionary:
	var include_deadzones: bool = bool(args.get(&"include_deadzones", true))

	# Merge action names from both sources:
	# - InputMap.get_actions() covers built-ins (ui_*, spatial_editor/*, etc.)
	# - ProjectSettings input/* keys cover project-defined actions
	# The editor InputMap only knows about built-ins + actions added via InputMap.add_action()
	# during the current session; project.godot actions are NOT automatically loaded into it.
	var all_actions: Dictionary = {}
	for action: StringName in InputMap.get_actions():
		all_actions[str(action)] = true
	for prop: Dictionary in ProjectSettings.get_property_list():
		var pname: String = prop[&"name"]
		if pname.begins_with("input/"):
			all_actions[pname.substr(6)] = true

	var sorted_names: Array = all_actions.keys()
	sorted_names.sort()

	var result: Dictionary = {}
	for action_name: String in sorted_names:
		var ps_key: String = "input/" + action_name
		var events: Array = []
		var deadzone: float = 0.5

		if ProjectSettings.has_setting(ps_key):
			# Project-defined or overridden action — ProjectSettings is the source of truth.
			# The editor InputMap may have a stale or default deadzone for these.
			var ps_data = ProjectSettings.get_setting(ps_key, {})
			if ps_data is Dictionary:
				deadzone = float(ps_data.get(&"deadzone", 0.5))
				for e in ps_data.get(&"events", []):
					if not e is InputEvent:
						continue
					events.append(_describe_input_event(e))
		elif InputMap.has_action(action_name):
			# Pure built-in with no project override — read from InputMap directly.
			deadzone = InputMap.action_get_deadzone(action_name)
			for e: InputEvent in InputMap.action_get_events(action_name):
				events.append(_describe_input_event(e))

		var action_data := {&"events": events}
		if include_deadzones:
			action_data[&"deadzone"] = deadzone
		result[action_name] = action_data

	return {&"ok": true, &"actions": result, &"count": result.size()}

func _describe_input_event(e: InputEvent) -> Dictionary:
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
		item[&"axis_value"] = e.axis_value
	return item

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
	else:
		InputMap.action_set_deadzone(action, deadzone)

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
		TYPE_QUATERNION: return "Quaternion"
		TYPE_AABB: return "AABB"
		TYPE_BASIS: return "Basis"
		TYPE_TRANSFORM3D: return "Transform3D"
		TYPE_OBJECT: return "Resource"
		TYPE_ARRAY: return "Array"
		TYPE_DICTIONARY: return "Dictionary"
		_: return "Variant"

func _serialize_value(value: Variant) -> Variant:
	return VariantCodec.serialize_value(value)

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

## Walk the entire editor base control and return *every* EditorLog widget's
## RichTextLabel + a short text sample. Used by get_console_log({debug:true})
## to diagnose cases where prints from the running game land in a different
## widget than the one we cache (seen on Godot 4.6 in some layouts: the
## "Output" panel displays editor-side stop/start notifications but game
## stdout appears to route elsewhere). Returning the full list lets the test
## agent compare the cached pick against alternatives.
func _enumerate_editor_log_rtls() -> Array:
	if not _editor_plugin:
		return []
	var base := _editor_plugin.get_editor_interface().get_base_control()
	if not base:
		return []
	var logs: Array[Node] = []
	_collect_nodes_by_class(base, "EditorLog", logs)
	var out: Array = []
	for editor_log in logs:
		var rtl := _find_child_rtl(editor_log)
		if rtl == null:
			continue
		var text: String = rtl.get_parsed_text()
		out.append({
			&"editor_log_path": str(editor_log.get_path()),
			&"rtl_path": str(rtl.get_path()),
			&"text_length": text.length(),
			&"line_count": rtl.get_line_count(),
			&"sample_tail": text.substr(maxi(0, text.length() - 200)),
		})
	return out

func _collect_nodes_by_class(node: Node, cls_name: String, out: Array[Node]) -> void:
	if node.get_class() == cls_name:
		out.append(node)
	for child: Node in node.get_children():
		_collect_nodes_by_class(child, cls_name, out)

## Read the state of the Output panel's filter toggles (Info / Warning /
## Error). When Info is off, regular print() lines from the running game
## are excluded from the EditorLog's RichTextLabel — get_parsed_text() will
## simply not contain them, and the agent has no way of knowing why prints
## "disappeared". This was the root cause of the round-1 issue #49 confusion.
##
## EditorLog's filter buttons are CheckBox / Button children with the
## tooltip text "Toggle visibility of standard output messages." (and
## warning / error variants). We can't depend on the C++ class members so
## we walk the children and pattern-match.
##
## Returns a dict like {info: true/false, warning: true/false,
## error: true/false, detected: bool}. `detected` is false when no toggles
## could be located (e.g. very different Godot version), in which case the
## bool fields are all set to true so callers don't false-positive.
func _read_editor_log_filters() -> Dictionary:
	var out: Dictionary = {&"info": true, &"warning": true, &"error": true, &"detected": false}
	if not _editor_plugin:
		return out
	var base := _editor_plugin.get_editor_interface().get_base_control()
	if not base:
		return out
	var editor_log := _find_node_by_class(base, "EditorLog")
	if not editor_log:
		return out
	var any_found := false
	# EditorLog filter buttons are typically BaseButton (CheckBox subclass)
	# in a small HBoxContainer at the top of the panel. The tooltip text is
	# the most stable identifier across Godot 4.x.
	var buttons: Array[Node] = []
	_collect_filter_buttons(editor_log, buttons)
	for b in buttons:
		if not b is BaseButton:
			continue
		var tooltip: String = ""
		if b.has_method("get_tooltip_text"):
			tooltip = str(b.call("get_tooltip_text"))
		else:
			tooltip = str(b.get("tooltip_text"))
		var lower: String = tooltip.to_lower()
		var pressed: bool = bool((b as BaseButton).button_pressed)
		# Match what's stable across Godot 4.x: "standard output" → info,
		# "warning" → warning, "error" → error. Extra "messages" suffix
		# isn't required.
		if "standard output" in lower or " info " in lower or lower.begins_with("info"):
			out[&"info"] = pressed
			any_found = true
		elif "warning" in lower:
			out[&"warning"] = pressed
			any_found = true
		elif "error" in lower:
			out[&"error"] = pressed
			any_found = true
	out[&"detected"] = any_found
	return out

func _collect_filter_buttons(node: Node, out: Array[Node]) -> void:
	if node is BaseButton:
		out.append(node)
	for child: Node in node.get_children():
		_collect_filter_buttons(child, out)

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
	# If the panel shrank below our watermark, it was cleared out from under us
	# (manual Clear button, editor's clear-on-play, etc.). The watermark is stale
	# — drop it and read the whole panel rather than returning a false "empty".
	if _clear_char_offset > full_text.length():
		_clear_char_offset = 0
	if _clear_char_offset > 0:
		full_text = full_text.substr(_clear_char_offset)
	var lines: Array = []
	for line: String in full_text.split("\n"):
		if not line.strip_edges().is_empty():
			lines.append(line)
	return lines

## Mark the current end of both log surfaces (Output panel + Debugger>Errors) as
## the baseline so subsequent get_console_log / get_errors calls only return
## entries produced after this point. Called by run_scene to give the agent a
## clean read of a fresh launch without wiping the human's Output scrollback.
func _arm_log_watermark() -> void:
	# Output panel: an absolute char offset into the parsed text. If the editor
	# is configured to hard-clear the panel on play, it wipes the panel itself,
	# so a non-zero offset would chop the start of the NEW run's output — zero it
	# and let the editor's own clear do the work.
	var editor_clears := false
	if _editor_plugin:
		var es := _editor_plugin.get_editor_interface().get_editor_settings()
		if es and es.has_setting("run/output/always_clear_output_on_play"):
			editor_clears = bool(es.get_setting("run/output/always_clear_output_on_play"))
	if editor_clears:
		_clear_char_offset = 0
	else:
		var rtl := _get_editor_log_rtl()
		_clear_char_offset = rtl.get_parsed_text().length() if rtl else 0
	# Debugger > Errors tab: a row-count baseline (the tab is a Tree, not text we
	# can offset into). Godot clears this list when a new debug session starts;
	# _read_debugger_errors detects that (current rows < baseline) and resets, so
	# this is correct whether or not Godot clears the tab on run.
	_debugger_error_baseline = _count_debugger_error_rows()

## Count the top-level rows currently in the Debugger > Errors tab (0 if the tab
## isn't available). Used to set and validate _debugger_error_baseline.
func _count_debugger_error_rows() -> int:
	var tree := _get_debugger_error_tree()
	if not tree:
		return 0
	var root := tree.get_root()
	if not root:
		return 0
	var count := 0
	var item := root.get_first_child()
	while item:
		count += 1
		item = item.get_next()
	return count

# =============================================================================
# get_console_log
# =============================================================================
func get_console_log(args: Dictionary) -> Dictionary:
	var max_lines: int = int(args.get(&"max_lines", 50))
	# Opt-in introspection: dump every EditorLog widget in the editor base
	# control so the agent can confirm we're scraping the right one (some
	# Godot 4.x layouts route running-game stdout through a separate widget).
	var debug: bool = bool(args.get(&"debug", false))

	var rtl := _get_editor_log_rtl()
	if not rtl:
		return {&"ok": false,
			&"error": "Could not access the Godot editor Output panel. Make sure the MCP plugin is enabled and running inside the Godot editor."}

	var all_lines := _read_output_panel_lines()
	var start := maxi(0, all_lines.size() - max_lines)
	var lines := all_lines.slice(start)
	var result := {&"ok": true, &"lines": lines, &"line_count": lines.size(),
		&"content": "\n".join(lines)}

	# Detect the Output panel's filter-button state. EditorLog rebuilds its
	# RichTextLabel from filtered messages, so when Info is off, print()
	# lines from the running game don't appear in get_parsed_text() at all
	# — there's nothing for us to scrape. Surface this proactively so the
	# agent can ask the user to toggle Info on instead of chasing a phantom
	# bug. (This was the root cause of the round-1 #49 confusion.)
	var filters: Dictionary = _read_editor_log_filters()

	if debug:
		result[&"editor_log_rtl_path"] = str(rtl.get_path()) if rtl else "<not found>"
		result[&"editor_log_candidates"] = _enumerate_editor_log_rtls()
		result[&"output_panel_filters"] = filters

	# Hard-fail diagnostic: Info filter off. EditorLog filters out standard
	# output before get_parsed_text(), so print() lines are missing even when
	# warnings/errors remain visible. Surface this regardless of line count.
	if filters.get(&"detected", false) and not bool(filters.get(&"info", true)):
		result[&"output_panel_filters"] = filters
		var info_hint := "The Godot Output panel's 'Info' filter is OFF. Regular print() lines from the running game are hidden from the panel (and from this tool's scrape) until the user toggles the Info button in the Output panel back on. push_error / push_warning still surface via get_errors regardless of this filter."
		result[&"info_filter_hint"] = info_hint
		result[&"hint"] = info_hint

	# Diagnostic: if the panel reads empty but the project is actively playing,
	# our cached EditorLog RTL may be the wrong widget (rebuilt by the editor,
	# wrong layout, etc.). Try a one-shot re-resolution before reporting empty.
	if lines.is_empty() and _editor_plugin and _editor_plugin.get_editor_interface().is_playing_scene():
		_editor_log_rtl = null  # force re-find
		var refreshed_lines: Array = _read_output_panel_lines()
		if not refreshed_lines.is_empty():
			lines = refreshed_lines.slice(maxi(0, refreshed_lines.size() - max_lines))
			result[&"lines"] = lines
			result[&"line_count"] = lines.size()
			result[&"content"] = "\n".join(lines)
			result[&"editor_log_rtl_refreshed"] = true
		else:
			# Empty AND a scene is playing — either filters are hiding the
			# content or we're on the wrong RTL. Surface both possibilities.
			rtl = _get_editor_log_rtl()
			var rtl_info: Dictionary = {}
			if rtl:
				rtl_info[&"node_path"] = str(rtl.get_path())
				rtl_info[&"name"] = str(rtl.name)
				rtl_info[&"text_length"] = rtl.get_parsed_text().length()
				rtl_info[&"line_count_raw"] = rtl.get_line_count()
			else:
				rtl_info[&"node_path"] = "<not found>"
			var diag: String = "Output panel reads empty while a scene is playing."
			if filters.get(&"detected", false) and not bool(filters.get(&"info", true)):
				diag += " The Output panel's 'Info' filter is OFF, which hides print() output. Ask the user to toggle Info back on, or use get_errors (which reads the Debugger > Errors tab and is filter-independent)."
			else:
				diag += " The cached EditorLog RTL may not be the panel that receives running-game stdout in this Godot layout. Call get_errors for the Debugger > Errors tab, which uses a separate widget."
			result[&"diagnostic"] = diag
			result[&"editor_log_rtl"] = rtl_info
			result[&"output_panel_filters"] = filters

	# Output panel ≠ Debugger > Errors tab. Runtime push_error / script errors
	# during play often surface only in the Debugger panel. If we spot anything
	# error-shaped in the Output stream, point the agent at get_errors so it
	# doesn't conclude "no errors" from a quiet log.
	for line: String in lines:
		var stripped: String = line.strip_edges()
		for prefix: String in _ERROR_PREFIXES:
			if stripped.begins_with(prefix):
				result[&"errors_detected"] = true
				var errors_hint := "Output contains error-prefixed lines. Call get_errors for structured errors including the Debugger > Errors tab (runtime errors don't appear here)."
				if result.has(&"hint"):
					result[&"errors_hint"] = errors_hint
				else:
					result[&"hint"] = errors_hint
				return result
	return result

# =============================================================================
# get_errors
# =============================================================================
const _ERROR_PREFIXES: PackedStringArray = [
	"ERROR:", "SCRIPT ERROR:", "USER ERROR:",
	"WARNING:", "USER WARNING:", "SCRIPT WARNING:",
	"Parse Error:", "Invalid",
]

const _GET_ERRORS_MAX_WAIT_MS: int = 1000

func get_errors(args: Dictionary) -> Dictionary:
	var max_errors: int = int(args.get(&"max_errors", 50))
	var include_warnings: bool = bool(args.get(&"include_warnings", true))
	var wait_ms: int = clampi(int(args.get(&"wait_ms", 0)), 0, _GET_ERRORS_MAX_WAIT_MS)

	if wait_ms > 0:
		var tree := Engine.get_main_loop() as SceneTree
		if tree:
			await tree.create_timer(wait_ms / 1000.0, false, false, true).timeout
		else:
			OS.delay_msec(wait_ms)

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
	var response: Dictionary = {&"ok": true, &"errors": errors, &"error_count": errors.size(),
		&"summary": "%d error(s) found" % errors.size()}
	if wait_ms > 0:
		response[&"waited_ms"] = wait_ms
	elif errors.is_empty() and _editor_plugin and _editor_plugin.get_editor_interface().is_playing_scene():
		response[&"hint"] = "The Debugger > Errors tab can populate shortly after run_scene returns. If this was called immediately after launching, retry with get_errors({\"wait_ms\": 300}) before concluding there are no runtime errors."
	return response

func _extract_file_line(text: String) -> Dictionary:
	# Two formats seen from Godot's debugger:
	#   "res://path/file.gd:42 @ _ready()"   (full res:// path)
	#   "file.gd:42"                          (bare filename, common in stack-frame columns)
	# Try the res:// form first; fall back to a bare *.gd / *.cs / *.tscn match.
	var res_re := RegEx.create_from_string("(res://[^:\\s]+):(\\d+)")
	var m := res_re.search(text)
	if m:
		return {&"file": m.get_string(1), &"line": int(m.get_string(2))}

	var bare_re := RegEx.create_from_string("([\\w./-]+\\.(?:gd|cs|tscn|tres)):(\\d+)")
	var m2 := bare_re.search(text)
	if m2:
		var file: String = m2.get_string(1)
		if not file.begins_with("res://") and not file.begins_with("user://"):
			# The debugger frequently emits just "issue_49.gd" or "ui/menu.gd"
			# without the res:// prefix and without the leading project
			# subfolder. Prepending res:// is wrong when the real file lives
			# under a subdirectory (res://test/issue_49.gd, etc.). Ask the
			# editor's filesystem index for the actual path; only fall back
			# to the naive res://+basename form when the lookup is ambiguous
			# or the editor index isn't available.
			var resolved: String = _resolve_script_path(file)
			file = resolved if not resolved.is_empty() else "res://" + file
		var out: Dictionary = {&"file": file, &"line": int(m2.get_string(2))}
		return out
	return {}

## Positive cache only: last-run-scene + basename → res:// path for files we
## resolved unambiguously in that context.
## We deliberately do NOT cache negative results — a script that's "missing"
## right now (because EditorFileSystem hasn't indexed a freshly-created file)
## may resolve on the very next call once EFS catches up or the disk fallback
## finds it. Cleared on rescan_filesystem so renames don't leave stale entries.
var _script_path_cache: Dictionary = {}

## Resolve a bare-filename or partial-path suffix to a unique res:// path.
##
## Strategy:
##  1. Walk the EditorFileSystem index for any file whose path ends with
##     "/<suffix>" (slash boundary so "menu.gd" doesn't match "main_menu.gd").
##  2. If EFS returns zero matches, fall back to a disk walk via DirAccess
##     under res://. EFS lags behind disk for files just created via tools
##     (or by external editors) until the editor next scans — this fallback
##     handles the "create file → run scene → get_errors" sequence the test
##     plan exercises.
##
## Returns "" when the lookup is ambiguous (>1 match) or genuinely missing
## from both EFS and disk; the caller then falls back to the naive
## res://<basename> form so the agent never gets a confidently-wrong subfolder.
func _resolve_script_path(suffix: String) -> String:
	if suffix.is_empty():
		return ""
	# The last-run scene is the strongest signal and must beat any cache entry.
	# Otherwise a previous run of dup_a/foo.gd can make a later dup_b/foo.gd
	# debugger frame point at the wrong folder while still passing the
	# "cached path exists on disk" check.
	var scene_resolved: String = _resolve_from_scene_refs(_last_run_scene_resolved_path, suffix)
	if not scene_resolved.is_empty():
		_script_path_cache[_script_path_cache_key(suffix)] = scene_resolved
		return scene_resolved

	# Validate cache hits against disk before trusting them. EFS doesn't
	# notice when a file is renamed/deleted via DirAccess (which is what our
	# rename_file does), so a cached "fresh.gd → res://test/r4/fresh.gd"
	# entry can outlive the file. If the cached path no longer exists,
	# evict and re-resolve.
	var cache_key: String = _script_path_cache_key(suffix)
	if _last_run_scene_resolved_path.is_empty() and _script_path_cache.has(cache_key):
		var cached: String = _script_path_cache[cache_key]
		if cached.is_empty() or FileAccess.file_exists(cached):
			return cached
		_script_path_cache.erase(cache_key)
	var matches: Array[String] = []
	if _editor_plugin:
		var efs := _editor_plugin.get_editor_interface().get_resource_filesystem()
		if efs:
			_collect_efs_matches(efs.get_filesystem(), suffix, matches)
	# EFS is a cached index, not a real-time view of disk. When a file was
	# just created (e.g. via an MCP write_file / create_script call) and a
	# scene was immediately played against it, EFS may not yet know about it.
	# Walk disk as a fallback — bounded depth, skip cache/git directories.
	# Also defends against EFS holding stale entries for files we just
	# renamed via DirAccess: filter EFS hits through FileAccess.file_exists.
	var verified: Array[String] = []
	for m in matches:
		if FileAccess.file_exists(m):
			verified.append(m)
	matches = verified
	if matches.is_empty():
		_collect_disk_matches("res://", suffix, matches, 0)
	var resolved: String = ""
	if matches.size() == 1:
		resolved = matches[0]
	elif matches.size() > 1:
		# Multiple files share this basename. In a well-maintained project
		# this is rare, but test projects accumulate leftover scripts from
		# previous runs. Disambiguate using progressively weaker signals.
		resolved = _disambiguate_matches(matches)
		# If still ambiguous, `resolved` stays empty and the caller falls
		# through to the naive res://<basename> form (safe — never
		# confidently wrong).
	if not resolved.is_empty():
		_script_path_cache[cache_key] = resolved
	# Note: ambiguous (>1) and missing (0) results are NOT cached. We want
	# the next call to retry — EFS may have updated, or the user may have
	# fixed the duplicate.
	return resolved

func _script_path_cache_key(suffix: String) -> String:
	return "%s\n%s" % [_last_run_scene_resolved_path, suffix]

func _resolve_from_scene_refs(scene_path: String, suffix: String) -> String:
	if scene_path.is_empty():
		return ""
	var refs: Dictionary = {}
	_collect_ext_resource_paths(scene_path, refs)
	if refs.is_empty():
		return ""
	var needle: String = suffix
	if not needle.begins_with("/"):
		needle = "/" + needle
	var hits: Array[String] = []
	for ref_path_v in refs.keys():
		var ref_path: String = str(ref_path_v)
		if not FileAccess.file_exists(ref_path):
			continue
		if ref_path.ends_with(needle) or ref_path == "res://" + suffix:
			hits.append(ref_path)
	return hits[0] if hits.size() == 1 else ""

## Pick a single canonical path from multiple basename matches. Tries
## three signals in order of decreasing confidence:
##   1. The last-played scene's `ext_resource path=` list. The error came
##      from this scene; the script it lists is by definition the right
##      one. Survives stop_scene (we just read disk).
##   2. Currently open scene tabs' `ext_resource path=` lists. The user
##      is editing this scene, so its script is the live working copy.
##   3. ResourceLoader.has_cached. Weak signal — the editor-side cache
##      is often empty post-stop_scene because run_scene runs the game in
##      a separate process — but useful as a last resort.
## Returns "" if no signal could disambiguate.
func _disambiguate_matches(matches: Array[String]) -> String:
	# Tier 1: most recently played scene.
	if not _last_run_scene_resolved_path.is_empty():
		var last_refs: Dictionary = {}
		_collect_ext_resource_paths(_last_run_scene_resolved_path, last_refs)
		var hits: Array[String] = []
		for m in matches:
			if last_refs.has(m):
				hits.append(m)
		if hits.size() == 1:
			return hits[0]

	# Tier 2: any open scene tab.
	var open_refs: Dictionary = {}
	if _editor_plugin:
		var ei := _editor_plugin.get_editor_interface()
		if ei and ei.has_method("get_open_scenes"):
			for s in ei.get_open_scenes():
				_collect_ext_resource_paths(str(s), open_refs)
	if not open_refs.is_empty():
		var hits2: Array[String] = []
		for m in matches:
			if open_refs.has(m):
				hits2.append(m)
		if hits2.size() == 1:
			return hits2[0]

	# Tier 3: ResourceLoader cache.
	var cached_matches: Array[String] = []
	for m in matches:
		if ResourceLoader.has_cached(m):
			cached_matches.append(m)
	if cached_matches.size() == 1:
		return cached_matches[0]

	return ""

## Read a .tscn / .tres text file and add every `path="res://..."` value
## found in `ext_resource` lines to the given Dictionary (used as a set).
## Cheap — these files are usually small, and we only call this when
## disambiguating, which is rare.
func _collect_ext_resource_paths(scene_path: String, out: Dictionary) -> void:
	if scene_path.is_empty() or not FileAccess.file_exists(scene_path):
		return
	# Defensive: only parse text-format scene/resource files. .scn is
	# binary; trying to regex it would just waste time.
	var ext: String = scene_path.get_extension().to_lower()
	if ext != "tscn" and ext != "tres":
		return
	var f := FileAccess.open(scene_path, FileAccess.READ)
	if f == null:
		return
	var content: String = f.get_as_text()
	f.close()
	# Match path="res://..." on any line. ext_resource is the common case
	# but sub_resources in .tres can also reference paths.
	var re := RegEx.create_from_string('path="(res://[^"]+)"')
	for m in re.search_all(content):
		out[m.get_string(1)] = true

func _collect_efs_matches(dir, suffix: String, out: Array[String]) -> void:
	if dir == null:
		return
	var needle: String = suffix
	if not needle.begins_with("/"):
		needle = "/" + needle
	for i: int in range(dir.get_file_count()):
		var p: String = dir.get_file_path(i)
		if p.ends_with(needle) or p == "res:/" + needle:
			out.append(p)
	for i: int in range(dir.get_subdir_count()):
		_collect_efs_matches(dir.get_subdir(i), suffix, out)

const _DISK_SCAN_MAX_DEPTH: int = 10
## Directories that never contain user scripts and would just slow the walk.
const _DISK_SCAN_SKIP_DIRS: Array[String] = [".godot", ".git", ".import", "node_modules"]

func _collect_disk_matches(dir_path: String, suffix: String, out: Array[String], depth: int) -> void:
	if depth > _DISK_SCAN_MAX_DEPTH:
		return
	var d := DirAccess.open(dir_path)
	if d == null:
		return
	var needle: String = suffix
	if not needle.begins_with("/"):
		needle = "/" + needle
	d.list_dir_begin()
	var entry: String = d.get_next()
	while entry != "":
		if entry == "." or entry == "..":
			entry = d.get_next()
			continue
		var full: String = dir_path
		if not full.ends_with("/"):
			full += "/"
		full += entry
		if d.current_is_dir():
			if entry in _DISK_SCAN_SKIP_DIRS:
				entry = d.get_next()
				continue
			_collect_disk_matches(full, suffix, out, depth + 1)
		else:
			if full.ends_with(needle) or full == "res://" + suffix:
				# De-dupe in case the EFS pass already found the same file
				# (won't normally happen since we only fall through to disk
				# when EFS was empty, but cheap insurance).
				if not (full in out):
					out.append(full)
		entry = d.get_next()
	d.list_dir_end()

## Look up theme icons by name from the editor's base control. Returns the
## resolved Texture2D objects (skipping any names not found in the current
## theme). Used to classify Tree rows by icon identity instead of by text,
## since debugger error rows don't include the literal word "warning"/"error"
## in their visible columns.
func _resolve_severity_icons(names: Array) -> Array:
	var out: Array = []
	if not _editor_plugin:
		return out
	var base := _editor_plugin.get_editor_interface().get_base_control()
	if not base:
		return out
	for n in names:
		if base.has_theme_icon(n, "EditorIcons"):
			var icon := base.get_theme_icon(n, "EditorIcons")
			if icon != null:
				out.append(icon)
	return out

## Classify a debugger Tree row as "error" or "warning". Strategy:
##  1. Compare the row's column-0 icon against the editor's warning/error
##     icon set (most reliable; what the panel actually renders).
##  2. Fall back to message text for the rare case where icons don't match
##     (e.g. theme overrides). Default is "error" — false-categorizing a
##     warning as an error is safer than the reverse for the agent.
func _classify_severity(item: TreeItem, message: String, warning_icons: Array, error_icons: Array) -> String:
	var row_icon := item.get_icon(0)
	if row_icon != null:
		for w in warning_icons:
			if row_icon == w:
				return "warning"
		for e in error_icons:
			if row_icon == e:
				return "error"
	var lower: String = message.to_lower()
	if "warning" in lower:
		return "warning"
	return "error"

func _read_debugger_errors(include_warnings: bool) -> Array:
	var tree := _get_debugger_error_tree()
	if not tree:
		return []
	var root := tree.get_root()
	if not root:
		return []

	# Skip rows that were already present when the watermark was last armed
	# (run_scene / clear_console_log, issue #54). If the tab now holds fewer rows
	# than the baseline, Godot cleared it on a new debug session — the baseline is
	# stale, so show everything. New rows are appended after old ones, so a simple
	# prefix-skip is correct.
	var skip := _debugger_error_baseline
	if _count_debugger_error_rows() < skip:
		skip = 0

	# Resolve the editor's warning/error icons once so we can classify each row
	# by icon (the row text rarely contains the literal word "warning"/"error";
	# severity is communicated visually). Both old and new icon names are
	# checked because the theme icon set has shifted across Godot 4.x.
	var warning_icons: Array = _resolve_severity_icons(["Warning", "StatusWarning"])
	var error_icons: Array = _resolve_severity_icons(["Error", "StatusError"])

	var errors: Array = []
	var item := root.get_first_child()
	var row_index := 0
	while item:
		if row_index < skip:
			row_index += 1
			item = item.get_next()
			continue
		row_index += 1
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

		var severity: String = _classify_severity(item, message, warning_icons, error_icons)

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
			# In Godot 4's ScriptEditorDebugger error tree, the top row holds
			# only the error title — file path and line number live in the
			# child rows (stack frames). If the top-row scrape missed
			# file/line, try each column individually AND the joined row
			# (handles "file in one column, line in another" layouts).
			if not error_info.has(&"file"):
				var joined: String = " ".join(trace_parts)
				var candidates: Array = trace_parts.duplicate()
				candidates.append(joined)
				for tp_v in candidates:
					var tp: String = str(tp_v)
					var child_loc := _extract_file_line(tp)
					if not child_loc.is_empty():
						error_info[&"file"] = child_loc.get(&"file", "")
						error_info[&"line"] = child_loc.get(&"line", 0)
						break
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
	# Strict match only: ScriptEditorDebugger contains several Tree nodes
	# (errors, stack, inspector, profiler). Falling back to candidates[0] when
	# nothing in the parent chain names "Error" silently returns the WRONG
	# tree — worse than returning nothing, since the agent would see "0 errors"
	# from e.g. the stack frame tree and conclude all is well.
	var candidates: Array[Tree] = []
	_collect_trees(node, candidates)
	for tree: Tree in candidates:
		var p := tree.get_parent()
		while p and p != node:
			if "Error" in p.name or "error" in p.name:
				return tree
			p = p.get_parent()
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

	# Hard-clear the editor Output panel, and watermark the Debugger > Errors tab
	# (which we can't safely mutate) so get_errors stops reporting rows logged
	# before this call. Mirrors run_scene's clean-slate behavior (issue #54).
	rtl.clear()
	_clear_char_offset = 0
	_debugger_error_baseline = _count_debugger_error_rows()
	return {&"ok": true,
		&"message": "Console log cleared (Output panel emptied; Debugger > Errors rows hidden from get_errors)."}

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
## Dump the live scene tree open in the editor (reflects unsaved edits).
## Default: full tree, indented text, one node per line.
##
## Opt-in pagination/scoping args:
##   max_depth     int >= 0     depth limit; 0 = only the (sub)root. Omit
##                              or pass < 0 for unlimited.
##   offset        int >= 0     skip the first N nodes in DFS preorder.
##   limit         int >= 1     emit at most N nodes after offset.
##   subtree_root  string       scene-relative node path ("UI/HUD", "."),
##                              empty/missing = scene root. Depth resets
##                              to 0 at the subtree root.
##
## Response (new fields are additive — zero-arg behavior is unchanged
## except `total_node_count` is now always returned):
##   tree              indented text, only nodes in the window
##   scene_path        as before
##   total_node_count  nodes in the (subtree_root + max_depth) scope
##   truncated         true iff offset/limit clipped output (max_depth
##                     scoping is intentional, not truncation)
##   next_offset       present only when truncated; offset + emitted
##   subtree_root      echoed when provided
func scene_tree_dump(args: Dictionary) -> Dictionary:
	if not _editor_plugin:
		return {&"ok": false, &"error": "Editor plugin not available"}

	var ei = _editor_plugin.get_editor_interface()
	var edited_scene = ei.get_edited_scene_root()

	if not edited_scene:
		return {&"ok": true, &"tree": "(no scene open)", &"message": "No scene is currently open in the editor"}

	# Parse + validate args (all optional).
	var max_depth_raw: Variant = args.get(&"max_depth", null)
	var max_depth: int = -1
	if max_depth_raw != null:
		max_depth = int(max_depth_raw)
		if max_depth < 0:
			# Negative means unlimited; clamp to -1 for the walker.
			max_depth = -1

	var offset: int = int(args.get(&"offset", 0))
	if offset < 0:
		return {&"ok": false, &"error": "scene_tree_dump: offset must be >= 0 (got %d)" % offset}

	var limit_raw: Variant = args.get(&"limit", null)
	var limit: int = -1
	if limit_raw != null:
		limit = int(limit_raw)
		if limit <= 0:
			return {&"ok": false, &"error": "scene_tree_dump: limit must be >= 1 (got %d)" % limit}

	var subtree_root_in: String = str(args.get(&"subtree_root", "")).strip_edges()
	var root_node: Node = edited_scene
	if not subtree_root_in.is_empty() and subtree_root_in != ".":
		# Accept both "Foo/Bar" (scene-relative) and "./Foo/Bar". The scene
		# root itself is represented as "." or "".
		var lookup_path: String = subtree_root_in
		if lookup_path.begins_with("./"):
			lookup_path = lookup_path.substr(2)
		var resolved: Node = edited_scene.get_node_or_null(NodePath(lookup_path))
		if resolved == null:
			return {
				&"ok": false,
				&"error": "scene_tree_dump: subtree_root '%s' not found under scene root '%s'" % [subtree_root_in, edited_scene.name],
			}
		root_node = resolved

	# Single DFS preorder walk: count every in-scope node, but only render
	# lines that fall inside [offset, offset+limit).
	var state := {&"index": 0, &"emitted": 0, &"total": 0}
	var parts: PackedStringArray = []
	_dump_walk(root_node, 0, max_depth, offset, limit, state, parts)

	var total: int = int(state[&"total"])
	var emitted: int = int(state[&"emitted"])
	var truncated: bool = (offset + emitted) < total

	var response: Dictionary = {
		&"ok": true,
		&"tree": "\n".join(parts) if not parts.is_empty() else "",
		&"scene_path": edited_scene.scene_file_path,
		&"total_node_count": total,
	}
	# Only echo `subtree_root` when the caller actually scoped to a node other
	# than the scene root. Empty/missing and "." are both treated as "scene
	# root" — echoing "." would create a spec/implementation mismatch where
	# two semantically-identical calls return different shapes.
	if not subtree_root_in.is_empty() and subtree_root_in != ".":
		response[&"subtree_root"] = subtree_root_in
	if truncated:
		response[&"truncated"] = true
		response[&"next_offset"] = offset + emitted
	return response

# DFS preorder walker. Counts every node within the (max_depth) scope and
# appends a formatted line to `parts` only for nodes whose flat preorder
# index falls inside [offset, offset+limit).
func _dump_walk(
	node: Node,
	depth: int,
	max_depth: int,
	offset: int,
	limit: int,
	state: Dictionary,
	parts: PackedStringArray,
) -> void:
	state[&"total"] = int(state[&"total"]) + 1
	var idx: int = int(state[&"index"])
	state[&"index"] = idx + 1

	var emit: bool = idx >= offset and (limit < 0 or int(state[&"emitted"]) < limit)
	if emit:
		var indent := "  ".repeat(depth)
		var line := "%s%s (%s)" % [indent, node.name, node.get_class()]
		var script = node.get_script()
		if script and script.resource_path:
			line += " [%s]" % script.resource_path.get_file()
		parts.append(line)
		state[&"emitted"] = int(state[&"emitted"]) + 1

	if max_depth >= 0 and depth >= max_depth:
		return
	for child: Node in node.get_children():
		_dump_walk(child, depth + 1, max_depth, offset, limit, state, parts)

# =============================================================================
# close_editor_tabs
# =============================================================================
## Close open editor tabs (scenes and/or scripts). Files on disk are NOT
## touched — this only changes the editor's UI state.
##
## Args:
##   kind   String?         "scene", "script", or "any" (default). Controls
##                          which tab kinds the call targets.
##   paths  Array[String]?  Specific paths to close (with or without "res://").
##                          Omit / empty / null = close all matching tabs of
##                          the chosen kind. Paths not currently open are
##                          reported in `not_open` (informational, not error).
##
## Returns:
##   { ok, scenes_closed, scripts_closed_not_supported, not_open,
##     remaining_scenes, remaining_scripts, message }
##
## SCENES: uses EditorInterface.close_scene() (Godot 4.5+). Unsaved changes
## are DISCARDED silently — matches Godot's native close-tab behavior; save
## first via the editor or save_resource_to_file if you need to preserve them.
##
## SCRIPTS: Godot's public ScriptEditor API does not currently expose a way
## to close script tabs from script. Requested script paths are returned in
## `scripts_closed_not_supported` with a clear reason rather than being
## silently skipped. Workarounds: close manually via the X button on the
## tab, or use `force=true` on the next file mutation to bypass the
## editor-open guard.
func close_editor_tabs(args: Dictionary) -> Dictionary:
	if not _editor_plugin:
		return {&"ok": false, &"error": "Editor plugin not available"}

	var ei := _editor_plugin.get_editor_interface()
	if ei == null:
		return {&"ok": false, &"error": "Editor interface not available"}

	var kind: String = str(args.get(&"kind", "any")).to_lower().strip_edges()
	if kind == "":
		kind = "any"
	if kind != "any" and kind != "scene" and kind != "script":
		return {&"ok": false, &"error": "Invalid 'kind': %s (must be 'scene', 'script', or 'any')" % kind}

	# Parse paths filter. Empty / missing = close all of the chosen kind.
	var requested: Array = []
	var paths_arg: Variant = args.get(&"paths", null)
	if paths_arg == null:
		paths_arg = args.get(&"scenes", null)  # legacy compat — accept old key
	if paths_arg != null:
		if paths_arg is Array or paths_arg is PackedStringArray:
			for s in paths_arg:
				var raw := str(s).strip_edges()
				if raw.is_empty():
					continue
				requested.append(raw if raw.begins_with("res://") else "res://" + raw)
		elif paths_arg is String:
			var s2 := str(paths_arg).strip_edges()
			if not s2.is_empty():
				requested.append(s2 if s2.begins_with("res://") else "res://" + s2)
		else:
			return {&"ok": false, &"error": "'paths' must be an array of strings (or omitted to close all)"}

	# Snapshot current state once so iteration doesn't see shifting open sets.
	var open_scenes: PackedStringArray = ei.get_open_scenes() if ei.has_method("get_open_scenes") else PackedStringArray()
	var se := ei.get_script_editor()
	var open_script_paths: Array = []
	if se:
		for s in se.get_open_scripts():
			if s is Script:
				open_script_paths.append(s.resource_path)

	var scenes_closed: Array = []
	var scenes_failed: Array = []
	var scripts_not_supported: Array = []
	var not_open: Array = []

	# --- Scene side ---
	if kind == "scene" or kind == "any":
		if not ei.has_method("close_scene"):
			return {
				&"ok": false,
				&"error": "close_editor_tabs (scene) requires EditorInterface.close_scene() — Godot 4.5+. Current engine version: %s" % Engine.get_version_info().get("string", "unknown"),
			}

		var scene_targets: Array = []
		if requested.is_empty():
			for p in open_scenes:
				scene_targets.append(str(p))
		else:
			for raw in requested:
				if open_scenes.has(raw):
					scene_targets.append(raw)

		for path_v in scene_targets:
			var path: String = str(path_v)
			ei.open_scene_from_path(path)  # focus before close_scene closes the active tab
			var err = ei.close_scene()
			if err == OK:
				scenes_closed.append(path)
			else:
				scenes_failed.append({&"path": path, &"error_code": err})

	# --- Script side ---
	if kind == "script" or kind == "any":
		var script_targets: Array = []
		if requested.is_empty():
			for p in open_script_paths:
				script_targets.append(p)
		else:
			for raw in requested:
				if raw in open_script_paths:
					script_targets.append(raw)
		for path_v in script_targets:
			scripts_not_supported.append({
				&"path": str(path_v),
				&"reason": "Godot's public ScriptEditor API does not expose script-tab close from scripting. Close manually via the X on the tab, or use force=true on the next file mutation to bypass the editor-open guard.",
			})

	# --- not_open: requested paths that exist in neither editor ---
	if not requested.is_empty():
		for raw in requested:
			var here_as_scene: bool = open_scenes.has(raw)
			var here_as_script: bool = open_script_paths.has(raw)
			if not here_as_scene and not here_as_script:
				not_open.append(raw)

	# --- Post-call snapshot of remaining state ---
	var remaining_scenes: Array = []
	for p in ei.get_open_scenes() if ei.has_method("get_open_scenes") else PackedStringArray():
		remaining_scenes.append(str(p))
	var remaining_scripts: Array = []
	if se:
		for s in se.get_open_scripts():
			if s is Script:
				remaining_scripts.append(s.resource_path)

	var msg_parts: PackedStringArray = []
	msg_parts.append("Closed %d scene tab(s)" % scenes_closed.size())
	if not scripts_not_supported.is_empty():
		msg_parts.append("%d script tab(s) cannot be closed via API" % scripts_not_supported.size())
	if not not_open.is_empty():
		msg_parts.append("%d path(s) not open" % not_open.size())
	if not scenes_failed.is_empty():
		msg_parts.append("%d failed" % scenes_failed.size())

	var ok := scenes_failed.is_empty()
	var response: Dictionary = {
		&"ok": ok,
		&"scenes_closed": scenes_closed,
		&"scripts_closed_not_supported": scripts_not_supported,
		&"not_open": not_open,
		&"remaining_scenes": remaining_scenes,
		&"remaining_scripts": remaining_scripts,
		&"message": ", ".join(msg_parts),
	}
	if not scenes_failed.is_empty():
		response[&"scenes_failed"] = scenes_failed
		response[&"error"] = "close_editor_tabs: %d scene tab(s) failed to close" % scenes_failed.size()
	return response


# =============================================================================
# get_editor_selection / set_editor_selection
# =============================================================================
## Read or write the editor's current node selection. Selection is editor UI
## state (not stored in the .tscn) and is scoped to the currently edited
## scene tab. Lets the AI say "fix this" / "change the color here" without
## the user having to type a node path, and lets follow-up tools focus the
## user's gizmo on a freshly-created node.

func get_editor_selection(_args: Dictionary) -> Dictionary:
	if not _editor_plugin:
		return {&"ok": false, &"error": "Editor plugin not available"}
	var ei := _editor_plugin.get_editor_interface()
	var edited: Node = ei.get_edited_scene_root() if ei else null
	if edited == null:
		# Stable `reason` field lets the agent branch without string-matching
		# the human-readable `message`.
		return {
			&"ok": true,
			&"scene_path": "",
			&"selection": [],
			&"count": 0,
			&"reason": "no_scene_open",
			&"message": "No scene is currently open in the editor.",
		}

	var selection := ei.get_selection()
	var entries: Array = []
	if selection != null:
		for n in selection.get_selected_nodes():
			if not (n is Node):
				continue
			entries.append(_describe_selected_node(edited, n))

	var out: Dictionary = {
		&"ok": true,
		&"scene_path": str(edited.scene_file_path),
		&"selection": entries,
		&"count": entries.size(),
	}
	if entries.is_empty():
		out[&"reason"] = "none_selected"
		out[&"message"] = "No nodes are currently selected in the active scene."
	else:
		out[&"reason"] = "ok"
	return out


## Replace or extend the editor's selection.
##
## Args:
##   node_paths  Array[String] | String   scene-relative paths. "." or "" =
##                                       scene root. A single string is
##                                       accepted as a one-element array.
##   mode        "replace" (default) | "add"
##                                       replace clears the existing
##                                       selection first; add appends.
##
## Pre-validates every path against the live edited scene tree (NOT the
## .tscn on disk — selection only makes sense for live nodes) before
## mutating, matching the "validate-then-mutate" pattern. If ANY path
## fails to resolve, no selection change happens and `not_found` is
## populated.
##
## Returns {ok, scene_path, selected:[{path,name,type}], not_found:[...], mode}.
func set_editor_selection(args: Dictionary) -> Dictionary:
	if not _editor_plugin:
		return {&"ok": false, &"error": "Editor plugin not available"}
	var ei := _editor_plugin.get_editor_interface()
	var edited: Node = ei.get_edited_scene_root() if ei else null
	if edited == null:
		return {&"ok": false, &"error": "No scene is currently open in the editor"}

	# Normalize node_paths: accept a String for the single-target convenience case.
	var raw: Variant = args.get(&"node_paths", null)
	if raw == null:
		raw = args.get(&"node_path", null) # tolerate the singular spelling
	if raw == null:
		return {&"ok": false, &"error": "set_editor_selection: missing 'node_paths' (array of scene-relative paths; '.' = scene root)"}

	var path_list: Array = []
	if raw is String:
		path_list = [str(raw)]
	elif raw is Array or raw is PackedStringArray:
		for v in raw:
			path_list.append(str(v))
	else:
		return {&"ok": false, &"error": "set_editor_selection: 'node_paths' must be a string or an array of strings"}

	var mode: String = str(args.get(&"mode", "replace")).strip_edges()
	if mode != "replace" and mode != "add":
		return {&"ok": false, &"error": "set_editor_selection: 'mode' must be 'replace' or 'add' (got '%s')" % mode}

	# Pre-validate every path. Selection works on LIVE editor nodes, so we
	# resolve against the in-memory tree (not by loading the .tscn from disk).
	var resolved: Array[Node] = []
	var resolved_descs: Array = []
	var not_found: Array = []
	for raw_path in path_list:
		var p: String = str(raw_path).strip_edges()
		var node: Node = _resolve_editor_node(edited, p)
		if node == null:
			not_found.append(p)
		else:
			resolved.append(node)
			resolved_descs.append(_describe_selected_node(edited, node))

	if not not_found.is_empty():
		return {
			&"ok": false,
			&"scene_path": str(edited.scene_file_path),
			&"error": "set_editor_selection: %d node path(s) could not be resolved in the active scene" % not_found.size(),
			&"not_found": not_found,
			&"selected": [], # nothing changed
			&"mode": mode,
			&"hint": "Paths are scene-relative ('.' = scene root, 'UI/HUD/Label' for nested). Use scene_tree_dump or find_nodes to discover paths.",
		}

	var selection := ei.get_selection()
	if selection == null:
		return {&"ok": false, &"error": "EditorInterface.get_selection() returned null"}

	if mode == "replace":
		selection.clear()
	for n in resolved:
		selection.add_node(n)

	return {
		&"ok": true,
		&"scene_path": str(edited.scene_file_path),
		&"selected": resolved_descs,
		&"not_found": [],
		&"mode": mode,
		&"count": resolved_descs.size(),
	}


## Resolve a scene-relative path to a live Node under `scene_root`. Accepts
## "." or "" (the scene root itself) and conventional relative paths like
## "UI/HUD/Label". Returns null if the path doesn't resolve.
func _resolve_editor_node(scene_root: Node, raw_path: String) -> Node:
	var p := raw_path.strip_edges()
	if p.is_empty() or p == ".":
		return scene_root
	if p.begins_with("./"):
		p = p.substr(2)
	return scene_root.get_node_or_null(NodePath(p))


## Describe a selected node the way the AI wants to consume it: relative path
## from the scene root (matching find_nodes / scene_tree_dump conventions),
## display name, and class. NodePath stringification yields "." for self,
## which is exactly what we want for the scene root.
func _describe_selected_node(scene_root: Node, node: Node) -> Dictionary:
	var rel: String = String(scene_root.get_path_to(node))
	return {
		&"path": rel,
		&"name": str(node.name),
		&"type": node.get_class(),
	}


# =============================================================================
# run_scene / stop_scene / is_playing
# =============================================================================

## Hard cap for `startup_timeout_ms`. Must stay comfortably below the TS
## server's per-tool transport timeout (30000ms) so the `run_scene` reply
## can always travel back before the wire gives up. 25s leaves ~5s of
## headroom for the response trip.
const _RUN_SCENE_MAX_STARTUP_MS: int = 25000

## Launch a scene in the editor. With block_until_started=true (default true)
## the call waits until the editor's play state flips on, so the agent can
## reliably call get_errors/get_runtime_log/take_screenshot immediately after.
## Set wait_for_runtime=true to additionally block until the MCPRuntime
## autoload connects back; required for take_screenshot / send_input to work
## right away.
##
## This function is a coroutine. The polling loops yield to the SceneTree
## via `await tree.create_timer().timeout` instead of `OS.delay_msec`, so
## the editor's WebSocket pump keeps running while we wait. Same fix the
## `wait` tool received — `OS.delay_msec` freezes the main thread, which
## freezes `MCPClient._process()`, which prevents the editor from reading
## the `runtime_status` push the server already sent. Without this fix,
## `run_scene({wait_for_runtime:true})` could return
## `runtime_connected: false` even though the runtime had already connected.
func run_scene(args: Dictionary) -> Dictionary:
	if not _editor_plugin:
		return {&"ok": false, &"error": "Editor plugin not available"}
	var ei := _editor_plugin.get_editor_interface()
	var scene: String = str(args.get(&"scene", ""))
	var block_until_started: bool = bool(args.get(&"block_until_started", true))
	var wait_for_runtime: bool = bool(args.get(&"wait_for_runtime", false))
	# Default of 10s gives slower machines (cold-cache import, autoload heavy
	# games) enough headroom for the editor to reach the playing state and
	# for MCPRuntime to connect. Tune up via the argument if needed; values
	# above _RUN_SCENE_MAX_STARTUP_MS are clamped (not rejected) so the
	# response always fits inside the transport timeout.
	var requested_timeout_ms: int = int(args.get(&"startup_timeout_ms", 10000))
	if requested_timeout_ms < 0:
		requested_timeout_ms = 0
	var startup_timeout_ms: int = mini(requested_timeout_ms, _RUN_SCENE_MAX_STARTUP_MS)
	var startup_timeout_clamped: bool = requested_timeout_ms > _RUN_SCENE_MAX_STARTUP_MS

	if ei.is_playing_scene():
		return {&"ok": false, &"error": "A scene is already running. Call stop_scene first."}

	# Soft-clear the log surfaces the agent reads (issue #54). Stale output and
	# errors from a previous run otherwise get misattributed to this launch. This
	# is a read-side watermark only: the human's Output panel keeps its
	# scrollback; get_console_log / get_errors simply ignore everything logged
	# before now. Armed BEFORE play so the new run's first lines fall after it.
	var clear_output: bool = bool(args.get(&"clear_output", true))
	if clear_output:
		_arm_log_watermark()

	# Determine which scene file will run, so we can compute /root/<RootName>
	# for the agent's downstream query_runtime_node calls.
	var resolved_scene_path: String = ""
	if scene == "current":
		var edited := ei.get_edited_scene_root()
		resolved_scene_path = edited.scene_file_path if edited else ""
		ei.play_current_scene()
		_last_run_scene_target = "current"
	elif not scene.is_empty():
		if not scene.begins_with("res://"):
			scene = "res://" + scene
		if not FileAccess.file_exists(scene):
			return {&"ok": false, &"error": "Scene file not found: %s" % scene}
		resolved_scene_path = scene
		ei.play_custom_scene(scene)
		_last_run_scene_target = scene
	else:
		resolved_scene_path = str(ProjectSettings.get_setting("application/run/main_scene", ""))
		ei.play_main_scene()
		_last_run_scene_target = "main"

	_last_run_scene_started_at_ms = Time.get_ticks_msec()
	_last_run_scene_resolved_path = resolved_scene_path
	var root_node_name: String = _peek_scene_root_name(resolved_scene_path)
	var runtime_root: String = "/root/%s" % root_node_name if not root_node_name.is_empty() else ""

	var started: bool = ei.is_playing_scene()
	var runtime_connected: bool = _runtime_is_connected()
	var poll_started_ms: int = 0
	var poll_runtime_ms: int = 0

	# Use the SceneTree timer (not OS.delay_msec) so _process() ticks keep
	# running on MCPClient and the WebSocket pump can deliver runtime_status
	# pushes mid-wait. Fall back to OS.delay_msec only if no SceneTree (e.g.
	# headless CLI invocation, vanishingly rare for an editor plugin).
	var tree := Engine.get_main_loop() as SceneTree

	if block_until_started and not started:
		var t0 := Time.get_ticks_msec()
		while not started and (Time.get_ticks_msec() - t0) < startup_timeout_ms:
			if tree:
				await tree.create_timer(0.05, false, false, true).timeout
			else:
				OS.delay_msec(50)
			started = ei.is_playing_scene()
		poll_started_ms = Time.get_ticks_msec() - t0

	if wait_for_runtime and started and not runtime_connected:
		var t1 := Time.get_ticks_msec()
		while not runtime_connected and (Time.get_ticks_msec() - t1) < startup_timeout_ms:
			if tree:
				await tree.create_timer(0.1, false, false, true).timeout
			else:
				OS.delay_msec(100)
			runtime_connected = _runtime_is_connected()
		poll_runtime_ms = Time.get_ticks_msec() - t1

	# Setup-failure mode vs transient-timeout mode: if the user asked us to
	# wait for the runtime helper and it never showed, distinguish "autoload
	# misconfigured" (deterministic, needs user action) from "timeout" (might
	# work next time). The cheap check is ProjectSettings — the plugin
	# registers MCPRuntime there on _enable_plugin().
	var runtime_setup: Dictionary = {}
	if wait_for_runtime and not runtime_connected:
		runtime_setup = _diagnose_runtime_autoload()

	var out: Dictionary = {
		&"ok": true,
		&"message": "Scene launched" + (" (%s)" % scene if not scene.is_empty() else " (main scene)"),
		&"started": started,
		&"runtime_connected": runtime_connected,
		&"wait_for_started_ms": poll_started_ms,
		&"wait_for_runtime_ms": poll_runtime_ms,
		&"scene_path": resolved_scene_path,
		&"runtime_root": runtime_root,
		&"hint": "" if started else "Editor did not flip to playing state within startup_timeout_ms. Check get_errors and get_console_log for autoload/load errors.",
	}
	if not runtime_setup.is_empty():
		out[&"runtime_setup"] = runtime_setup
		if runtime_setup.get(&"ok", true) == false:
			out[&"hint"] = str(runtime_setup.get(&"hint", ""))
	if startup_timeout_clamped:
		out[&"startup_timeout_clamped"] = true
		out[&"requested_startup_timeout_ms"] = requested_timeout_ms
		out[&"effective_startup_timeout_ms"] = startup_timeout_ms
		out[&"note"] = "Requested startup_timeout_ms (%dms) exceeded the %dms cap (set just below the transport timeout); waited %dms instead." % [requested_timeout_ms, _RUN_SCENE_MAX_STARTUP_MS, startup_timeout_ms]
	return out

## Check whether the MCPRuntime autoload is actually registered in the
## project — not just whether our plugin tried to register it. The most
## common failure mode is: plugin disabled, plugin enabled but project not
## restarted, or a different autoload squatting on the "MCPRuntime" name.
## Returns {ok: bool, hint: String, ...} when wait_for_runtime times out, so
## the agent gets a deterministic setup error instead of a silent "waited 10s".
const _MCP_RUNTIME_AUTOLOAD_KEY: String = "autoload/MCPRuntime"
const _MCP_RUNTIME_AUTOLOAD_PATH: String = "res://addons/godot_mcp/runtime/mcp_runtime.gd"

func _diagnose_runtime_autoload() -> Dictionary:
	if not ProjectSettings.has_setting(_MCP_RUNTIME_AUTOLOAD_KEY):
		return {
			&"ok": false,
			&"reason": &"autoload_missing",
			&"hint": "MCPRuntime autoload is not registered in project.godot. Enable the godot_mcp plugin in Project > Project Settings > Plugins, then restart the project (autoload changes only take effect on restart).",
		}
	var registered: String = str(ProjectSettings.get_setting(_MCP_RUNTIME_AUTOLOAD_KEY, ""))
	# An empty string in the setting is functionally identical to the setting
	# being absent — Godot won't load anything. Surface it as the same reason
	# so the agent gets a single deterministic code path for "not there".
	if registered.strip_edges().is_empty():
		return {
			&"ok": false,
			&"reason": &"autoload_missing",
			&"hint": "MCPRuntime autoload entry exists in project.godot but is empty. Enable the godot_mcp plugin in Project > Project Settings > Plugins, then restart the project (autoload changes only take effect on restart).",
		}
	# Godot stores the autoload value as either "res://path.gd" or "*res://path.gd"
	# (leading '*' means "enabled"). Strip the marker for the path comparison.
	var clean_path: String = registered.lstrip("*")
	var enabled: bool = registered.begins_with("*")
	if clean_path != _MCP_RUNTIME_AUTOLOAD_PATH:
		return {
			&"ok": false,
			&"reason": &"autoload_path_mismatch",
			&"registered_path": clean_path,
			&"expected_path": _MCP_RUNTIME_AUTOLOAD_PATH,
			&"hint": "Another autoload is using the 'MCPRuntime' name and pointing at %s. Remove or rename it so the godot_mcp plugin can register its runtime helper." % clean_path,
		}
	if not enabled:
		return {
			&"ok": false,
			&"reason": &"autoload_disabled",
			&"hint": "MCPRuntime autoload is registered but disabled. Enable it in Project > Project Settings > Autoload, then restart the project (autoload state only takes effect on restart — toggling it while a scene is running has no effect on the live autoload).",
		}
	# Autoload is registered and enabled, but no runtime client has connected
	# back. Most likely: project was running before the plugin/autoload landed
	# and hasn't been restarted, or the runtime script failed to load.
	return {
		&"ok": false,
		&"reason": &"autoload_registered_but_not_connected",
		&"hint": "MCPRuntime autoload is registered and enabled but no runtime client connected within the wait window. If you just enabled the plugin, restart the project so the autoload runs. Also check get_errors for autoload load failures.",
	}

## Read the root node name out of a .tscn without instantiating it. Returns an
## empty string if the file can't be loaded (autoload-only / corrupt / .scn).
func _peek_scene_root_name(scene_path: String) -> String:
	if scene_path.is_empty() or not FileAccess.file_exists(scene_path):
		return ""
	var packed := load(scene_path) as PackedScene
	if packed == null:
		return ""
	var st := packed.get_state()
	if st.get_node_count() == 0:
		return ""
	return str(st.get_node_name(0))

func stop_scene(_args: Dictionary) -> Dictionary:
	if not _editor_plugin:
		return {&"ok": false, &"error": "Editor plugin not available"}
	var ei := _editor_plugin.get_editor_interface()
	if not ei.is_playing_scene():
		return {&"ok": true, &"message": "No scene is currently running"}
	ei.stop_playing_scene()
	return {&"ok": true, &"message": "Scene stopped"}

## Backward-compatible thin wrapper around get_runtime_status. Keep using this
## if you only need the boolean. For richer info (uptime, runtime helper status,
## last launched scene), prefer get_runtime_status.
func is_playing(_args: Dictionary) -> Dictionary:
	if not _editor_plugin:
		return {&"ok": false, &"error": "Editor plugin not available"}
	var ei := _editor_plugin.get_editor_interface()
	var playing := ei.is_playing_scene()
	var scene_path := ei.get_playing_scene() if playing else ""
	return {&"ok": true, &"playing": playing, &"scene": scene_path}

## Combined editor-side and runtime-side status snapshot.
func get_runtime_status(_args: Dictionary) -> Dictionary:
	if not _editor_plugin:
		return {&"ok": false, &"error": "Editor plugin not available"}
	var ei := _editor_plugin.get_editor_interface()
	var playing := ei.is_playing_scene()
	var uptime_ms := 0
	if playing and _last_run_scene_started_at_ms > 0:
		uptime_ms = Time.get_ticks_msec() - _last_run_scene_started_at_ms

	# Engine.get_version_info() returns major/minor/patch/string/build/hex/...;
	# we surface both the short string ("4.5.0.stable") for quick reads and
	# the full dict so callers can branch on (major, minor) without parsing.
	var version_info: Dictionary = Engine.get_version_info()

	return {
		&"ok": true,
		&"playing": playing,
		&"playing_scene": ei.get_playing_scene() if playing else "",
		&"last_launched": _last_run_scene_target,
		&"uptime_ms": uptime_ms,
		&"runtime_helper_connected": _runtime_is_connected(),
		&"godot_version": str(version_info.get(&"string", "unknown")),
		&"godot_version_info": version_info,
	}

# =============================================================================
# Editor-side wait. Runtime tools (take_screenshot, send_input,
# query_runtime_node, get_runtime_log, list_signal_connections with
# source="runtime") are routed by the TS MCP server directly to the
# MCPRuntime autoload running inside the user's game and never reach this
# editor-side dispatcher.
# =============================================================================
func _runtime_is_connected() -> bool:
	if _mcp_client == null:
		return false
	if _mcp_client.has_method("is_runtime_connected"):
		return _mcp_client.is_runtime_connected()
	return false

## Hard cap for `wait`. Must stay comfortably below the TS server's per-request
## timeout (30000ms) so the tool always has time to round-trip the result
## back before the transport gives up. We also never want to freeze the editor
## for a long time, so 20s is already on the generous side.
const _WAIT_MAX_MS: int = 20000

func wait(args: Dictionary) -> Dictionary:
	# Accept either ms (int) or seconds (float). If both are provided, ms wins.
	# Values above _WAIT_MAX_MS are clamped (not rejected) so the agent can
	# pass generous timeouts without tripping an error.
	#
	# IMPORTANT: we yield to the scene tree via `create_timer().timeout` INSTEAD
	# of `OS.delay_msec`, because the latter freezes the editor's main thread,
	# which in turn freezes the WebSocket pump, causes the TS server to hit
	# its 30s request timeout, and leaves the socket in a broken state when
	# Godot tries to write the response.
	var ms_raw: float = 0.0
	var had_input: bool = false
	if args.has(&"ms") and typeof(args.get(&"ms")) != TYPE_NIL:
		ms_raw = float(args.get(&"ms", 0))
		had_input = true
	elif args.has(&"seconds") and typeof(args.get(&"seconds")) != TYPE_NIL:
		ms_raw = float(args.get(&"seconds", 0.0)) * 1000.0
		had_input = true

	if not had_input or ms_raw <= 0.0:
		return {&"ok": false, &"error": "Missing or non-positive duration. Pass ms (int) or seconds (float)."}

	var requested_ms: int = int(round(ms_raw))
	var ms: int = clampi(requested_ms, 1, _WAIT_MAX_MS)
	var clamped: bool = requested_ms > _WAIT_MAX_MS

	var tree := Engine.get_main_loop() as SceneTree
	if tree:
		await tree.create_timer(ms / 1000.0, false, false, true).timeout
	else:
		# Fallback (headless / no SceneTree). Still safer than a long blocking
		# delay because `ms` is already clamped to _WAIT_MAX_MS.
		OS.delay_msec(ms)

	var out: Dictionary = {&"ok": true, &"waited_ms": ms}
	if clamped:
		out[&"clamped"] = true
		out[&"requested_ms"] = requested_ms
		out[&"note"] = "Requested duration exceeded the %dms cap; waited %dms. Keep waits short; for long operations use get_runtime_status polling instead." % [_WAIT_MAX_MS, ms]
	return out

# =============================================================================
# rescan_filesystem
# =============================================================================

func rescan_filesystem(_args: Dictionary) -> Dictionary:
	if not _editor_plugin:
		return {&"ok": false, &"error": "No editor plugin available"}
	var efs := _editor_plugin.get_editor_interface().get_resource_filesystem()
	# Drop the basename → res:// cache used by _extract_file_line either way —
	# stale entries shouldn't survive a rescan call regardless of whether the
	# scan we requested is the one Godot ends up running.
	_script_path_cache.clear()
	if efs.is_scanning():
		# Don't fail: a scan is already in flight, which by the time the caller
		# next interacts with the filesystem will have produced the same
		# observable state our scan() would have. Returning a hard error here
		# breaks automation that just wants "make sure the editor sees disk".
		return {
			&"ok": true,
			&"already_scanning": true,
			&"message": "Filesystem scan already in progress; the in-flight scan will pick up recent disk changes. No new scan triggered.",
		}
	efs.scan()
	return {&"ok": true, &"already_scanning": false, &"message": "Filesystem rescan triggered."}

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
