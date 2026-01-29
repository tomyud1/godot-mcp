@tool
extends Node
class_name FileTools
## File operation tools for MCP.
## Handles: list_dir, read_file, search_project, create_script

const DEFAULT_MAX_BYTES := 200_000
const DEFAULT_MAX_RESULTS := 200
const SKIP_EXTENSIONS := [".import", ".png", ".jpg", ".jpeg", ".webp", ".svg",
	".ogg", ".wav", ".mp3", ".escn", ".glb", ".gltf", ".uid"]

var _editor_plugin: EditorPlugin = null

func set_editor_plugin(plugin: EditorPlugin) -> void:
	_editor_plugin = plugin

# =============================================================================
# list_dir - List files and folders in a directory
# =============================================================================
func list_dir(args: Dictionary) -> Dictionary:
	var root: String = str(args.get("root", "res://"))
	var include_hidden: bool = bool(args.get("include_hidden", false))

	if not root.begins_with("res://"):
		root = "res://" + root

	var dir := DirAccess.open(root)
	if dir == null:
		return {"ok": false, "error": "Cannot open directory: " + root}

	var files: Array = []
	var folders: Array = []

	dir.list_dir_begin()
	var name := dir.get_next()
	while name != "":
		# Skip hidden files unless requested
		if not include_hidden and name.begins_with("."):
			name = dir.get_next()
			continue

		# Skip .uid files
		if name.to_lower().ends_with(".uid"):
			name = dir.get_next()
			continue

		var full_path := root.path_join(name)
		if dir.current_is_dir():
			folders.append(name)
		else:
			files.append(name)

		name = dir.get_next()
	dir.list_dir_end()

	# Sort alphabetically
	files.sort()
	folders.sort()

	return {
		"ok": true,
		"path": root,
		"files": files,
		"folders": folders,
		"total": files.size() + folders.size()
	}

# =============================================================================
# read_file - Read contents of a file
# =============================================================================
func read_file(args: Dictionary) -> Dictionary:
	var path: String = str(args.get("path", ""))
	var start_line: int = int(args.get("start_line", 1))
	var end_line: int = int(args.get("end_line", 0))
	var max_bytes: int = int(args.get("max_bytes", DEFAULT_MAX_BYTES))

	if path.strip_edges().is_empty():
		return {"ok": false, "error": "Missing 'path' parameter"}

	if not path.begins_with("res://"):
		path = "res://" + path

	if not FileAccess.file_exists(path):
		return {"ok": false, "error": "File not found: " + path}

	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return {"ok": false, "error": "Cannot open file: " + path}

	var content: String
	var line_count: int = 0

	# If no line range specified, read up to max_bytes
	if end_line <= 0 and start_line <= 1:
		var size := mini(max_bytes, file.get_length())
		content = file.get_buffer(size).get_string_from_utf8()
		# Count lines
		line_count = content.count("\n") + 1
	else:
		# Read specific line range
		var lines: Array = []
		var current_line := 0
		var total_bytes := 0

		while not file.eof_reached():
			var line := file.get_line()
			current_line += 1

			if current_line < start_line:
				continue
			if end_line > 0 and current_line > end_line:
				break

			lines.append(line)
			total_bytes += line.length() + 1  # +1 for newline

			if total_bytes > max_bytes:
				break

		content = "\n".join(lines)
		line_count = lines.size()

	file.close()

	return {
		"ok": true,
		"path": path,
		"content": content,
		"line_count": line_count,
		"range": [start_line, end_line] if end_line > 0 else null
	}

# =============================================================================
# search_project - Search for text in project files
# =============================================================================
func search_project(args: Dictionary) -> Dictionary:
	var query: String = str(args.get("query", ""))
	var glob_filter: String = str(args.get("glob", ""))
	var max_results: int = int(args.get("max_results", DEFAULT_MAX_RESULTS))
	var case_sensitive: bool = bool(args.get("case_sensitive", false))

	if query.strip_edges().is_empty():
		return {"ok": false, "error": "Missing 'query' parameter"}

	var search_query := query if case_sensitive else query.to_lower()
	var files := _collect_files("res://", glob_filter)
	var matches: Array = []

	for file_path in files:
		if matches.size() >= max_results:
			break

		var file := FileAccess.open(file_path, FileAccess.READ)
		if file == null:
			continue

		var line_num := 0
		while not file.eof_reached():
			var line := file.get_line()
			line_num += 1

			var search_line := line if case_sensitive else line.to_lower()
			if search_line.find(search_query) != -1:
				matches.append({
					"file": file_path,
					"line": line_num,
					"content": line.strip_edges()
				})

				if matches.size() >= max_results:
					break

		file.close()

	return {
		"ok": true,
		"query": query,
		"matches": matches,
		"total_matches": matches.size(),
		"truncated": matches.size() >= max_results
	}

func _collect_files(path: String, glob_filter: String) -> Array:
	"""Recursively collect all searchable files."""
	var result: Array = []
	_collect_files_recursive(path, glob_filter, result)
	return result

func _collect_files_recursive(path: String, glob_filter: String, out: Array) -> void:
	var dir := DirAccess.open(path)
	if dir == null:
		return

	dir.list_dir_begin()
	var name := dir.get_next()
	while name != "":
		# Skip hidden
		if name.begins_with("."):
			name = dir.get_next()
			continue

		var full_path := path.path_join(name)

		if dir.current_is_dir():
			_collect_files_recursive(full_path, glob_filter, out)
		else:
			# Skip binary files
			var skip := false
			for ext in SKIP_EXTENSIONS:
				if name.to_lower().ends_with(ext):
					skip = true
					break

			if not skip:
				# Apply glob filter if specified
				if glob_filter.is_empty() or _matches_glob(full_path, glob_filter):
					out.append(full_path)

		name = dir.get_next()
	dir.list_dir_end()

func _matches_glob(path: String, pattern: String) -> bool:
	"""Simple glob matching: *.gd, **/*.tscn, etc."""
	# Handle **/*.ext pattern
	if pattern.begins_with("**/"):
		var ext := pattern.substr(3)  # Remove **/
		return path.ends_with(ext.replace("*", ""))

	# Handle *.ext pattern
	if pattern.begins_with("*."):
		return path.ends_with(pattern.substr(1))

	# Simple contains check
	return path.find(pattern) != -1

# =============================================================================
# create_script - Create a new GDScript file
# =============================================================================
func create_script(args: Dictionary) -> Dictionary:
	var path: String = str(args.get("path", ""))
	var content: String = str(args.get("content", ""))

	if path.strip_edges().is_empty():
		return {"ok": false, "error": "Missing 'path' parameter"}

	if not path.begins_with("res://"):
		path = "res://" + path

	# Add .gd extension if missing
	if not "." in path.get_file():
		path += ".gd"

	# Check if file already exists
	if FileAccess.file_exists(path):
		return {"ok": false, "error": "File already exists: " + path}

	# Ensure parent directory exists
	var dir_path := path.get_base_dir()
	if not DirAccess.dir_exists_absolute(dir_path):
		var err := DirAccess.make_dir_recursive_absolute(dir_path)
		if err != OK:
			return {"ok": false, "error": "Could not create directory: " + dir_path}

	# Write file
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		return {"ok": false, "error": "Could not create file: " + path}

	file.store_string(content)
	file.close()

	# Refresh filesystem so Godot sees the new file
	_refresh_filesystem()

	return {
		"ok": true,
		"path": path,
		"size_bytes": content.length(),
		"message": "Script created successfully"
	}

func _refresh_filesystem() -> void:
	"""Tell Godot to rescan the filesystem."""
	if _editor_plugin != null:
		_editor_plugin.get_editor_interface().get_resource_filesystem().scan()
	elif Engine.is_editor_hint():
		# Fallback if no plugin reference
		var editor_interface = Engine.get_singleton("EditorInterface")
		if editor_interface:
			editor_interface.get_resource_filesystem().scan()
