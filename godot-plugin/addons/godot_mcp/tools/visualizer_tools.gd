@tool
extends Node
class_name VisualizerTools
## Crawls a Godot project and parses all GDScript files to build a project map.

var _editor_plugin: EditorPlugin = null

func set_editor_plugin(plugin: EditorPlugin) -> void:
	_editor_plugin = plugin

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
	var re_var := RegEx.new()
	re_var.compile("^(@export(?:\\([^)]*\\))?\\s+)?(?:@onready\\s+)?var\\s+(\\w+)\\s*(?::\\s*(\\w+))?(?:\\s*=\\s*(.+))?")

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

		# Variables
		var m_var := re_var.search(stripped)
		if m_var:
			var exported: bool = m_var.get_string(1).strip_edges() != ""
			var var_name: String = m_var.get_string(2)
			var var_type: String = m_var.get_string(3).strip_edges()
			var default_val: String = m_var.get_string(4).strip_edges()

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
