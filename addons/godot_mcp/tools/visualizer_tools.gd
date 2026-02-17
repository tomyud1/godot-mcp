@tool
extends Node
class_name VisualizerTools
## Crawls a Godot project and parses all GDScript files to build a project map.

var _editor_plugin: EditorPlugin = null
var _scene_tools_ref: Node = null

func set_editor_plugin(plugin: EditorPlugin) -> void:
	_editor_plugin = plugin

func set_scene_tools_ref(scene_tools: Node) -> void:
	_scene_tools_ref = scene_tools

func map_project(args: Dictionary) -> Dictionary:
	"""Crawl the entire project and build a structural map of all scripts."""
	var root_path: String = str(args.get("root", "res://"))
	var include_addons: bool = bool(args.get("include_addons", false))

	if not root_path.begins_with("res://"):
		root_path = "res://" + root_path

	# Collect all .gd files
	var script_paths: Array = []
	_collect_scripts(root_path, script_paths, include_addons)

	if script_paths.is_empty():
		return {"ok": false, "error": "No GDScript files found in " + root_path}

	# Parse each script
	var nodes: Array = []
	var class_map: Dictionary = {}  # class_name -> path

	for path in script_paths:
		var info: Dictionary = _parse_script(path)
		nodes.append(info)
		if info.get("class_name", "") != "":
			class_map[info["class_name"]] = path

	# Build edges
	var edges: Array = []
	for node in nodes:
		var from_path: String = node["path"]

		# extends relationship (resolve class_name to path)
		var extends_class: String = node.get("extends", "")
		if extends_class in class_map:
			edges.append({"from": from_path, "to": class_map[extends_class], "type": "extends"})

		# preload/load references
		for ref in node.get("preloads", []):
			if ref.ends_with(".gd"):
				edges.append({"from": from_path, "to": ref, "type": "preload"})

		# signal connections
		for conn in node.get("connections", []):
			var target: String = conn.get("target", "")
			if target in class_map:
				edges.append({"from": from_path, "to": class_map[target], "type": "signal", "signal_name": conn.get("signal", "")})

	return {
		"ok": true,
		"project_map": {
			"nodes": nodes,
			"edges": edges,
			"total_scripts": nodes.size(),
			"total_connections": edges.size()
		}
	}

func _collect_scripts(path: String, results: Array, include_addons: bool) -> void:
	"""Recursively collect all .gd files."""
	var dir := DirAccess.open(path)
	if dir == null:
		return

	dir.list_dir_begin()
	var name := dir.get_next()
	while name != "":
		if name.begins_with("."):
			name = dir.get_next()
			continue

		var full_path := path.path_join(name)

		if dir.current_is_dir():
			if name == "addons" and not include_addons:
				name = dir.get_next()
				continue
			_collect_scripts(full_path, results, include_addons)
		elif name.ends_with(".gd"):
			results.append(full_path)

		name = dir.get_next()
	dir.list_dir_end()

func _parse_script(path: String) -> Dictionary:
	"""Parse a GDScript file and extract its structure."""
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return {"path": path, "error": "Cannot open file"}

	var content: String = file.get_as_text()
	file.close()

	var lines: PackedStringArray = content.split("\n")
	var line_count: int = lines.size()

	var description := ""
	var extends_class := ""
	var class_name_str := ""
	var variables: Array = []
	var functions: Array = []
	var signals_list: Array = []
	var preloads: Array = []
	var connections: Array = []

	# Regex patterns
	var re_desc := RegEx.new()
	re_desc.compile("^##\\s*@desc:\\s*(.+)")

	var re_extends := RegEx.new()
	re_extends.compile("^extends\\s+(\\w+)")

	var re_class_name := RegEx.new()
	re_class_name.compile("^class_name\\s+(\\w+)")

	# Match: @export var name: Type = value  OR  var name: Type  OR  var name = value
	# Captures: 1=@export, 2=@onready, 3=name, 4=type, 5=default
	var re_var := RegEx.new()
	re_var.compile("^(@export(?:\\([^)]*\\))?\\s+)?(@onready\\s+)?var\\s+(\\w+)\\s*(?::\\s*(\\w+))?(?:\\s*=\\s*(.+))?")

	# Match: func name(params) -> ReturnType:
	var re_func := RegEx.new()
	re_func.compile("^func\\s+(\\w+)\\s*\\(([^)]*)\\)\\s*(?:->\\s*(\\w+))?")

	# Match: signal name(params)
	var re_signal := RegEx.new()
	re_signal.compile("^signal\\s+(\\w+)(?:\\(([^)]*)\\))?")

	var re_preload := RegEx.new()
	re_preload.compile("(?:preload|load)\\s*\\(\\s*\"(res://[^\"]+)\"\\s*\\)")

	# Match: obj.signal.connect(...) pattern (Godot 4 style)
	var re_connect_obj := RegEx.new()
	re_connect_obj.compile("(\\w+)\\.(\\w+)\\.connect\\s*\\(")
	
	# Match: signal.connect(...) pattern (direct signal)
	var re_connect_direct := RegEx.new()
	re_connect_direct.compile("^\\s*(\\w+)\\.connect\\s*\\(")
	
	# Map of variable names to their types (for resolving signal connections)
	var var_type_map: Dictionary = {}

	# First pass: extract metadata and find function boundaries
	var func_starts: Array = []  # [{line_idx, name}]

	for i in range(line_count):
		var line: String = lines[i]
		var stripped: String = line.strip_edges()

		# Description tag (check first 15 lines)
		if i < 15 and description.is_empty():
			var m := re_desc.search(stripped)
			if m:
				description = m.get_string(1)
				continue

		# extends
		if extends_class.is_empty():
			var m := re_extends.search(stripped)
			if m:
				extends_class = m.get_string(1)
				continue

		# class_name
		if class_name_str.is_empty():
			var m := re_class_name.search(stripped)
			if m:
				class_name_str = m.get_string(1)
				continue

		# Variables - only match top-level (not indented)
		# Skip lines that start with tab or spaces (inside functions)
		if not line.begins_with("\t") and not line.begins_with(" "):
			var m_var := re_var.search(stripped)
			if m_var:
				var exported: bool = m_var.get_string(1).strip_edges() != ""
				var onready: bool = m_var.get_string(2).strip_edges() != ""
				var var_name: String = m_var.get_string(3)
				var var_type: String = m_var.get_string(4).strip_edges()
				var default_val: String = m_var.get_string(5).strip_edges()

				# Try to infer type from default value if no explicit type
				if var_type.is_empty() and not default_val.is_empty():
					var_type = _infer_type(default_val)
				
				# Track variable types for signal connection resolution
				if not var_type.is_empty():
					var_type_map[var_name] = var_type

				variables.append({
					"name": var_name,
					"type": var_type,
					"exported": exported,
					"onready": onready,
					"default": default_val
				})

		# Functions
		var m_func := re_func.search(stripped)
		if m_func:
			var func_name: String = m_func.get_string(1)
			var return_type: String = m_func.get_string(3).strip_edges()
			func_starts.append({"line_idx": i, "name": func_name})
			functions.append({
				"name": func_name,
				"params": m_func.get_string(2).strip_edges(),
				"return_type": return_type,
				"line": i + 1,
				"body": ""  # filled in second pass
			})

		# Signals
		var m_sig := re_signal.search(stripped)
		if m_sig:
			signals_list.append({
				"name": m_sig.get_string(1),
				"params": m_sig.get_string(2).strip_edges() if m_sig.get_string(2) else ""
			})

		# Preload/load references
		var m_preload := re_preload.search(stripped)
		if m_preload:
			preloads.append(m_preload.get_string(1))

		# Signal connections (Godot 4 style)
		# Pattern: obj.signal.connect(...) - e.g. wave_manager.wave_started.connect(...)
		var m_conn_obj := re_connect_obj.search(stripped)
		if m_conn_obj:
			var obj_name: String = m_conn_obj.get_string(1)
			var signal_name: String = m_conn_obj.get_string(2)
			var target_type: String = var_type_map.get(obj_name, "")
			connections.append({
				"object": obj_name,
				"signal": signal_name,
				"target": target_type,
				"line": i + 1
			})
		else:
			# Pattern: signal.connect(...) - e.g. body_entered.connect(...)
			var m_conn_direct := re_connect_direct.search(stripped)
			if m_conn_direct:
				connections.append({
					"signal": m_conn_direct.get_string(1),
					"target": extends_class,  # Direct signal likely from parent class
					"line": i + 1
				})

	# Second pass: extract function bodies
	for fi in range(func_starts.size()):
		var start_idx: int = func_starts[fi]["line_idx"]
		var end_idx: int
		if fi + 1 < func_starts.size():
			end_idx = func_starts[fi + 1]["line_idx"]
		else:
			end_idx = line_count

		# Find actual end: look backwards from next func to skip blank lines
		while end_idx > start_idx + 1 and lines[end_idx - 1].strip_edges().is_empty():
			end_idx -= 1

		# Also check for top-level declarations (var, signal, @export, class_name, etc.)
		# that would end the function body
		for check_idx in range(start_idx + 1, end_idx):
			var check_line: String = lines[check_idx]
			# If line is not indented and not empty and not a comment, it's not part of the function
			if not check_line.is_empty() and not check_line.begins_with("\t") and not check_line.begins_with(" ") and not check_line.begins_with("#"):
				end_idx = check_idx
				break

		var body_lines: PackedStringArray = PackedStringArray()
		for li in range(start_idx, end_idx):
			body_lines.append(lines[li])

		var body: String = "\n".join(body_lines)
		# Cap body size to avoid huge payloads
		if body.length() > 3000:
			body = body.substr(0, 3000) + "\n# ... (truncated)"

		functions[fi]["body"] = body
		functions[fi]["body_lines"] = end_idx - start_idx

	# Determine folder
	var folder: String = path.get_base_dir()
	var filename: String = path.get_file()

	return {
		"path": path,
		"filename": filename,
		"folder": folder,
		"class_name": class_name_str,
		"extends": extends_class,
		"description": description,
		"line_count": line_count,
		"variables": variables,
		"functions": functions,
		"signals": signals_list,
		"preloads": preloads,
		"connections": connections
	}

func _infer_type(default_val: String) -> String:
	"""Try to infer GDScript type from a default value."""
	if default_val == "true" or default_val == "false":
		return "bool"
	if default_val.is_valid_int():
		return "int"
	if default_val.is_valid_float():
		return "float"
	if default_val.begins_with("\"") or default_val.begins_with("'"):
		return "String"
	if default_val.begins_with("Vector2"):
		return "Vector2"
	if default_val.begins_with("Vector3"):
		return "Vector3"
	if default_val.begins_with("Color"):
		return "Color"
	if default_val.begins_with("["):
		return "Array"
	if default_val.begins_with("{"):
		return "Dictionary"
	if default_val == "null":
		return "Variant"
	if default_val.ends_with(".new()"):
		return default_val.replace(".new()", "")
	return ""


func map_scenes(args: Dictionary) -> Dictionary:
	"""Crawl the project and build a map of all scenes."""
	var root_path: String = str(args.get("root", "res://"))
	var include_addons: bool = bool(args.get("include_addons", false))

	if not root_path.begins_with("res://"):
		root_path = "res://" + root_path

	# Collect all .tscn files
	var scene_paths: Array = []
	_collect_scenes(root_path, scene_paths, include_addons)

	if scene_paths.is_empty():
		return {"ok": true, "scene_map": {"scenes": [], "total_scenes": 0}}

	# Parse each scene
	var scenes: Array = []
	for path in scene_paths:
		var info: Dictionary = _parse_scene(path)
		scenes.append(info)

	# Build edges between scenes (instantiation, preloads)
	var edges: Array = []
	for scene in scenes:
		var from_path: String = scene["path"]
		for instance in scene.get("instances", []):
			edges.append({"from": from_path, "to": instance, "type": "instance"})

	return {
		"ok": true,
		"scene_map": {
			"scenes": scenes,
			"edges": edges,
			"total_scenes": scenes.size()
		}
	}


func _collect_scenes(path: String, results: Array, include_addons: bool) -> void:
	"""Recursively collect all .tscn files."""
	var dir := DirAccess.open(path)
	if dir == null:
		return

	dir.list_dir_begin()
	var name := dir.get_next()
	while name != "":
		if name.begins_with("."):
			name = dir.get_next()
			continue

		var full_path := path.path_join(name)

		if dir.current_is_dir():
			if name == "addons" and not include_addons:
				name = dir.get_next()
				continue
			_collect_scenes(full_path, results, include_addons)
		elif name.ends_with(".tscn"):
			results.append(full_path)

		name = dir.get_next()
	dir.list_dir_end()


func _parse_scene(path: String) -> Dictionary:
	"""Parse a scene file and extract its structure."""
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return {"path": path, "error": "Cannot open file"}

	var content: String = file.get_as_text()
	file.close()

	var scene_name: String = path.get_file().replace(".tscn", "")
	var root_type: String = ""
	var nodes: Array = []
	var instances: Array = []
	var scripts: Array = []

	# Parse .tscn format
	var lines: PackedStringArray = content.split("\n")
	var current_node: Dictionary = {}
	
	var re_ext_resource := RegEx.new()
	re_ext_resource.compile('\\[ext_resource.*path="([^"]+)".*type="([^"]+)"')
	
	var re_node := RegEx.new()
	re_node.compile('\\[node name="([^"]+)".*type="([^"]+)"')
	
	var re_node_instance := RegEx.new()
	re_node_instance.compile('\\[node name="([^"]+)".*instance=ExtResource\\("([^"]+)"\\)')
	
	var re_script := RegEx.new()
	re_script.compile('script = ExtResource\\("([^"]+)"\\)')

	var ext_resources: Dictionary = {}  # id -> {path, type}
	
	for line in lines:
		# External resources
		var m_ext := re_ext_resource.search(line)
		if m_ext:
			var res_path: String = m_ext.get_string(1)
			var res_type: String = m_ext.get_string(2)
			# Extract ID from the line
			var id_match := RegEx.create_from_string('id="([^"]+)"').search(line)
			if id_match:
				ext_resources[id_match.get_string(1)] = {"path": res_path, "type": res_type}
				if res_type == "PackedScene":
					instances.append(res_path)
				elif res_type == "Script":
					scripts.append(res_path)
			continue

		# Regular nodes
		var m_node := re_node.search(line)
		if m_node:
			var node_name: String = m_node.get_string(1)
			var node_type: String = m_node.get_string(2)
			if root_type.is_empty():
				root_type = node_type
			nodes.append({"name": node_name, "type": node_type})
			continue

		# Instance nodes
		var m_inst := re_node_instance.search(line)
		if m_inst:
			var node_name: String = m_inst.get_string(1)
			nodes.append({"name": node_name, "type": "Instance"})

	return {
		"path": path,
		"name": scene_name,
		"root_type": root_type,
		"nodes": nodes,
		"instances": instances,
		"scripts": scripts,
		"node_count": nodes.size()
	}


# ============================================================================
# INTERNAL FILE MODIFICATION FUNCTIONS (not exposed as MCP tools)
# These are called directly by the visualizer for inline editing
# ============================================================================

func _internal_map_scenes(args: Dictionary) -> Dictionary:
	"""Internal wrapper for map_scenes."""
	return map_scenes(args)


func _internal_refresh_map(args: Dictionary) -> Dictionary:
	"""Refresh the project map."""
	return map_project(args)


func _internal_create_script_file(args: Dictionary) -> Dictionary:
	"""Create a new script file."""
	var script_path: String = args.get("path", "")
	var extends_type: String = args.get("extends", "Node")
	var class_name_str: String = args.get("class_name", "")
	
	if script_path.is_empty():
		return {"ok": false, "error": "No path provided"}
	
	if not script_path.begins_with("res://"):
		script_path = "res://" + script_path
	
	if not script_path.ends_with(".gd"):
		script_path += ".gd"
	
	# Check if file already exists
	if FileAccess.file_exists(script_path):
		return {"ok": false, "error": "File already exists: " + script_path}
	
	# Create directory if needed
	var dir_path: String = script_path.get_base_dir()
	if not DirAccess.dir_exists_absolute(dir_path):
		var err := DirAccess.make_dir_recursive_absolute(dir_path)
		if err != OK:
			return {"ok": false, "error": "Failed to create directory"}
	
	# Build script content
	var content := ""
	if not class_name_str.is_empty():
		content += "class_name " + class_name_str + "\n"
	content += "extends " + extends_type + "\n"
	content += "\n\n"
	content += "func _ready() -> void:\n"
	content += "\tpass\n"
	
	# Write file
	var file := FileAccess.open(script_path, FileAccess.WRITE)
	if file == null:
		return {"ok": false, "error": "Cannot create file: " + script_path}
	
	file.store_string(content)
	file.close()
	
	return {"ok": true, "path": script_path}


func _internal_modify_variable(args: Dictionary) -> Dictionary:
	"""Add, update, or delete a variable in a script file."""
	var script_path: String = args.get("path", "")
	var action: String = args.get("action", "")  # "add", "update", "delete"
	var old_name: String = args.get("old_name", "")
	var new_name: String = args.get("name", "")
	var var_type: String = args.get("type", "")
	var default_val: String = args.get("default", "")
	var exported: bool = args.get("exported", false)
	var onready: bool = args.get("onready", false)
	
	if script_path.is_empty():
		return {"ok": false, "error": "No script path provided"}
	
	var file := FileAccess.open(script_path, FileAccess.READ)
	if file == null:
		return {"ok": false, "error": "Cannot open file: " + script_path}
	
	var content: String = file.get_as_text()
	file.close()
	
	var lines: Array = Array(content.split("\n"))
	var modified := false
	
	if action == "delete":
		# Find and remove the variable declaration
		var pattern := RegEx.new()
		pattern.compile("^(@export(?:\\([^)]*\\))?\\s+)?(?:@onready\\s+)?var\\s+" + old_name + "\\s*(?::|=|$)")
		for i in range(lines.size() - 1, -1, -1):
			if pattern.search(lines[i].strip_edges()):
				lines.remove_at(i)
				modified = true
				break
	
	elif action == "update":
		# Find and update the variable declaration
		var pattern := RegEx.new()
		pattern.compile("^(@export(?:\\([^)]*\\))?\\s+)?(@onready\\s+)?var\\s+" + old_name + "\\s*(?::\\s*\\w+)?(?:\\s*=\\s*.+)?$")
		for i in range(lines.size()):
			var m := pattern.search(lines[i].strip_edges())
			if m:
				# Use onready from args, not from matched pattern
				var new_line := _build_var_line(new_name, var_type, default_val, exported, onready)
				lines[i] = new_line
				modified = true
				break
	
	elif action == "add":
		# Find position to insert (after last variable, before first function)
		var insert_pos := _find_var_insert_position(lines, exported)
		var new_line := _build_var_line(new_name, var_type, default_val, exported, false)
		lines.insert(insert_pos, new_line)
		modified = true
	
	if modified:
		var new_content := "\n".join(PackedStringArray(lines))
		var write_file := FileAccess.open(script_path, FileAccess.WRITE)
		if write_file == null:
			return {"ok": false, "error": "Cannot write to file: " + script_path}
		write_file.store_string(new_content)
		write_file.close()
		return {"ok": true, "action": action, "variable": new_name}
	
	return {"ok": false, "error": "Variable not found: " + old_name}


func _internal_modify_signal(args: Dictionary) -> Dictionary:
	"""Add, update, or delete a signal in a script file."""
	var script_path: String = args.get("path", "")
	var action: String = args.get("action", "")
	var old_name: String = args.get("old_name", "")
	var new_name: String = args.get("name", "")
	var params: String = args.get("params", "")
	
	if script_path.is_empty():
		return {"ok": false, "error": "No script path provided"}
	
	var file := FileAccess.open(script_path, FileAccess.READ)
	if file == null:
		return {"ok": false, "error": "Cannot open file: " + script_path}
	
	var content: String = file.get_as_text()
	file.close()
	
	var lines: Array = Array(content.split("\n"))
	var modified := false
	
	if action == "delete":
		var pattern := RegEx.new()
		pattern.compile("^signal\\s+" + old_name + "(?:\\s*\\(|$)")
		for i in range(lines.size() - 1, -1, -1):
			if pattern.search(lines[i].strip_edges()):
				lines.remove_at(i)
				modified = true
				break
	
	elif action == "update":
		var pattern := RegEx.new()
		pattern.compile("^signal\\s+" + old_name + "(?:\\s*\\([^)]*\\))?$")
		for i in range(lines.size()):
			if pattern.search(lines[i].strip_edges()):
				var new_line := "signal " + new_name
				if not params.is_empty():
					new_line += "(" + params + ")"
				lines[i] = new_line
				modified = true
				break
	
	elif action == "add":
		var insert_pos := _find_signal_insert_position(lines)
		var new_line := "signal " + new_name
		if not params.is_empty():
			new_line += "(" + params + ")"
		lines.insert(insert_pos, new_line)
		modified = true
	
	if modified:
		var new_content := "\n".join(PackedStringArray(lines))
		var write_file := FileAccess.open(script_path, FileAccess.WRITE)
		if write_file == null:
			return {"ok": false, "error": "Cannot write to file: " + script_path}
		write_file.store_string(new_content)
		write_file.close()
		return {"ok": true, "action": action, "signal": new_name}
	
	return {"ok": false, "error": "Signal not found: " + old_name}


func _internal_modify_function(args: Dictionary) -> Dictionary:
	"""Update a function's body in a script file."""
	var script_path: String = args.get("path", "")
	var func_name: String = args.get("name", "")
	var new_body: String = args.get("body", "")
	
	if script_path.is_empty() or func_name.is_empty():
		return {"ok": false, "error": "Missing path or function name"}
	
	var file := FileAccess.open(script_path, FileAccess.READ)
	if file == null:
		return {"ok": false, "error": "Cannot open file: " + script_path}
	
	var content: String = file.get_as_text()
	file.close()
	
	var lines: Array = Array(content.split("\n"))
	
	# Find the function
	var re_func := RegEx.new()
	re_func.compile("^func\\s+" + func_name + "\\s*\\(")
	
	var func_start := -1
	var func_end := -1
	
	for i in range(lines.size()):
		if func_start == -1:
			if re_func.search(lines[i].strip_edges()):
				func_start = i
		elif func_start != -1:
			# Find end of function (next top-level declaration or end of file)
			var stripped: String = lines[i].strip_edges()
			if not stripped.is_empty() and not lines[i].begins_with("\t") and not lines[i].begins_with(" ") and not stripped.begins_with("#"):
				func_end = i
				break
	
	if func_start == -1:
		return {"ok": false, "error": "Function not found: " + func_name}
	
	if func_end == -1:
		func_end = lines.size()
	
	# Remove trailing empty lines from function body
	while func_end > func_start + 1 and lines[func_end - 1].strip_edges().is_empty():
		func_end -= 1
	
	# Replace function body
	var new_lines := Array(new_body.split("\n"))
	
	# Remove old function lines
	for i in range(func_end - 1, func_start - 1, -1):
		lines.remove_at(i)
	
	# Insert new function lines
	for i in range(new_lines.size()):
		lines.insert(func_start + i, new_lines[i])
	
	var new_content := "\n".join(PackedStringArray(lines))
	var write_file := FileAccess.open(script_path, FileAccess.WRITE)
	if write_file == null:
		return {"ok": false, "error": "Cannot write to file: " + script_path}
	write_file.store_string(new_content)
	write_file.close()
	
	return {"ok": true, "function": func_name}


func _internal_modify_function_delete(args: Dictionary) -> Dictionary:
	"""Delete a function from a script file."""
	var script_path: String = args.get("path", "")
	var func_name: String = args.get("name", "")
	
	if script_path.is_empty() or func_name.is_empty():
		return {"ok": false, "error": "Missing path or function name"}
	
	var file := FileAccess.open(script_path, FileAccess.READ)
	if file == null:
		return {"ok": false, "error": "Cannot open file: " + script_path}
	
	var content: String = file.get_as_text()
	file.close()
	
	var lines: Array = Array(content.split("\n"))
	
	# Find the function
	var re_func := RegEx.new()
	re_func.compile("^func\\s+" + func_name + "\\s*\\(")
	
	var func_start := -1
	var func_end := -1
	
	for i in range(lines.size()):
		if func_start == -1:
			if re_func.search(lines[i].strip_edges()):
				func_start = i
		elif func_start != -1:
			# Find end of function (next top-level declaration or end of file)
			var stripped: String = lines[i].strip_edges()
			if not stripped.is_empty() and not lines[i].begins_with("\t") and not lines[i].begins_with(" ") and not stripped.begins_with("#"):
				func_end = i
				break
	
	if func_start == -1:
		return {"ok": false, "error": "Function not found: " + func_name}
	
	if func_end == -1:
		func_end = lines.size()
	
	# Remove trailing empty lines before the function
	while func_end > func_start + 1 and lines[func_end - 1].strip_edges().is_empty():
		func_end -= 1
	
	# Remove the function lines
	for i in range(func_end - 1, func_start - 1, -1):
		lines.remove_at(i)
	
	# Remove extra blank lines that might be left
	# (but keep at least one blank line between declarations)
	
	var new_content := "\n".join(PackedStringArray(lines))
	var write_file := FileAccess.open(script_path, FileAccess.WRITE)
	if write_file == null:
		return {"ok": false, "error": "Cannot write to file: " + script_path}
	write_file.store_string(new_content)
	write_file.close()
	
	return {"ok": true, "deleted": func_name}


func _internal_find_usages(args: Dictionary) -> Dictionary:
	"""Find all usages of a variable, signal, or function across all scripts."""
	var name: String = args.get("name", "")
	var item_type: String = args.get("type", "")  # "variable", "signal", "function"
	var root_path: String = args.get("root", "res://")
	
	if name.is_empty():
		return {"ok": false, "error": "No name provided"}
	
	# Collect all scripts
	var script_paths: Array = []
	_collect_scripts(root_path, script_paths, false)
	
	var usages: Array = []
	
	# Build regex pattern based on type
	var pattern := RegEx.new()
	if item_type == "signal":
		# Match: signal_name.emit() or signal_name.connect() or .signal_name.
		pattern.compile("\\b" + name + "\\b")
	else:
		# Match word boundary for variables and functions
		pattern.compile("\\b" + name + "\\b")
	
	for path in script_paths:
		var file := FileAccess.open(path, FileAccess.READ)
		if file == null:
			continue
		
		var content: String = file.get_as_text()
		file.close()
		
		var lines: PackedStringArray = content.split("\n")
		for i in range(lines.size()):
			var line: String = lines[i]
			if pattern.search(line):
				# Skip the declaration line itself
				if item_type == "variable" and RegEx.create_from_string("^\\s*(@export)?\\s*var\\s+" + name + "\\b").search(line):
					continue
				if item_type == "signal" and RegEx.create_from_string("^\\s*signal\\s+" + name + "\\b").search(line):
					continue
				if item_type == "function" and RegEx.create_from_string("^\\s*func\\s+" + name + "\\s*\\(").search(line):
					continue
				
				usages.append({
					"file": path,
					"line": i + 1,
					"code": line.strip_edges()
				})
	
	return {"ok": true, "usages": usages, "count": usages.size()}


# Helper functions for file modification

func _build_var_line(name: String, type: String, default: String, exported: bool, onready: bool) -> String:
	var line := ""
	if exported:
		line += "@export "
	if onready:
		line += "@onready "
	line += "var " + name
	if not type.is_empty():
		line += ": " + type
	if not default.is_empty():
		line += " = " + default
	return line


func _find_var_insert_position(lines: Array, exported: bool) -> int:
	"""Find the best position to insert a new variable."""
	var last_var_line := -1
	var first_func_line := -1
	var after_class_decl := 0
	
	var re_var := RegEx.new()
	re_var.compile("^(@export)?\\s*(@onready)?\\s*var\\s+")
	var re_func := RegEx.new()
	re_func.compile("^func\\s+")
	var re_class := RegEx.new()
	re_class.compile("^(class_name|extends)\\s+")
	
	for i in range(lines.size()):
		var stripped: String = lines[i].strip_edges()
		if re_class.search(stripped):
			after_class_decl = i + 1
		if re_var.search(stripped):
			last_var_line = i
		if re_func.search(stripped) and first_func_line == -1:
			first_func_line = i
			break
	
	# Insert after last variable, or before first function, or after class declarations
	if last_var_line != -1:
		return last_var_line + 1
	if first_func_line != -1:
		return first_func_line
	return max(after_class_decl, 2)  # At least after extends/class_name


func _find_signal_insert_position(lines: Array) -> int:
	"""Find the best position to insert a new signal."""
	var last_signal_line := -1
	var first_var_line := -1
	var after_class_decl := 0
	
	var re_signal := RegEx.new()
	re_signal.compile("^signal\\s+")
	var re_var := RegEx.new()
	re_var.compile("^(@export)?\\s*var\\s+")
	var re_class := RegEx.new()
	re_class.compile("^(class_name|extends)\\s+")
	
	for i in range(lines.size()):
		var stripped: String = lines[i].strip_edges()
		if re_class.search(stripped):
			after_class_decl = i + 1
		if re_signal.search(stripped):
			last_signal_line = i
		if re_var.search(stripped) and first_var_line == -1:
			first_var_line = i
	
	# Insert after last signal, or before first var, or after class declarations
	if last_signal_line != -1:
		return last_signal_line + 1
	if first_var_line != -1:
		return first_var_line
	return max(after_class_decl, 2)


# ============================================================================
# SCENE VISUALIZER INTERNAL FUNCTIONS
# These are called by the visualizer for scene view functionality
# ============================================================================

func _internal_get_scene_hierarchy(args: Dictionary) -> Dictionary:
	"""Get scene hierarchy for visualizer."""
	if _scene_tools_ref and _scene_tools_ref.has_method("get_scene_hierarchy"):
		return _scene_tools_ref.get_scene_hierarchy(args)
	return {"ok": false, "error": "Scene tools not available"}


func _internal_get_scene_node_properties(args: Dictionary) -> Dictionary:
	"""Get node properties for visualizer panel."""
	if _scene_tools_ref and _scene_tools_ref.has_method("get_scene_node_properties"):
		return _scene_tools_ref.get_scene_node_properties(args)
	return {"ok": false, "error": "Scene tools not available"}


func _internal_set_scene_node_property(args: Dictionary) -> Dictionary:
	"""Set node property from visualizer panel."""
	if _scene_tools_ref and _scene_tools_ref.has_method("set_scene_node_property"):
		return _scene_tools_ref.set_scene_node_property(args)
	return {"ok": false, "error": "Scene tools not available"}


func _internal_add_scene_node(args: Dictionary) -> Dictionary:
	"""Add a node to a scene from visualizer."""
	if _scene_tools_ref and _scene_tools_ref.has_method("add_node"):
		return _scene_tools_ref.add_node(args)
	return {"ok": false, "error": "Scene tools not available"}


func _internal_remove_scene_node(args: Dictionary) -> Dictionary:
	"""Remove a node from a scene from visualizer."""
	if _scene_tools_ref and _scene_tools_ref.has_method("remove_node"):
		return _scene_tools_ref.remove_node(args)
	return {"ok": false, "error": "Scene tools not available"}


func _internal_rename_scene_node(args: Dictionary) -> Dictionary:
	"""Rename a node in a scene from visualizer."""
	if _scene_tools_ref and _scene_tools_ref.has_method("rename_node"):
		return _scene_tools_ref.rename_node(args)
	return {"ok": false, "error": "Scene tools not available"}


func _internal_move_scene_node(args: Dictionary) -> Dictionary:
	"""Move/reorder a node in a scene from visualizer."""
	if _scene_tools_ref and _scene_tools_ref.has_method("move_node"):
		return _scene_tools_ref.move_node(args)
	return {"ok": false, "error": "Scene tools not available"}


# Simpler aliases for context menu actions
func _internal_add_node(args: Dictionary) -> Dictionary:
	"""Add a node to a scene."""
	if _scene_tools_ref and _scene_tools_ref.has_method("add_node"):
		return _scene_tools_ref.add_node(args)
	return {"ok": false, "error": "Scene tools not available"}


func _internal_remove_node(args: Dictionary) -> Dictionary:
	"""Remove a node from a scene."""
	if _scene_tools_ref and _scene_tools_ref.has_method("remove_node"):
		return _scene_tools_ref.remove_node(args)
	return {"ok": false, "error": "Scene tools not available"}


func _internal_rename_node(args: Dictionary) -> Dictionary:
	"""Rename a node in a scene."""
	if _scene_tools_ref and _scene_tools_ref.has_method("rename_node"):
		return _scene_tools_ref.rename_node(args)
	return {"ok": false, "error": "Scene tools not available"}


func _internal_move_node(args: Dictionary) -> Dictionary:
	"""Move/reorder a node in a scene."""
	if _scene_tools_ref and _scene_tools_ref.has_method("move_node"):
		return _scene_tools_ref.move_node(args)
	return {"ok": false, "error": "Scene tools not available"}


func _internal_duplicate_node(args: Dictionary) -> Dictionary:
	"""Duplicate a node in a scene."""
	if _scene_tools_ref and _scene_tools_ref.has_method("duplicate_node"):
		return _scene_tools_ref.duplicate_node(args)
	return {"ok": false, "error": "Scene tools not available"}


func _internal_reorder_node(args: Dictionary) -> Dictionary:
	"""Reorder a node within its parent (change sibling index)."""
	if _scene_tools_ref and _scene_tools_ref.has_method("reorder_node"):
		return _scene_tools_ref.reorder_node(args)
	return {"ok": false, "error": "Scene tools not available"}
