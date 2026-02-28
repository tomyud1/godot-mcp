@tool
extends Node
class_name FileTools
## File operation tools for MCP.
## Handles: list_dir, read_file, search_project, create_script

const DEFAULT_MAX_BYTES := 200_000
const DEFAULT_MAX_RESULTS := 200
const MAX_TRAVERSAL_DEPTH := 20
const _SKIP_EXTENSIONS: Dictionary = {
	".import": true, ".png": true, ".jpg": true, ".jpeg": true,
	".webp": true, ".svg": true, ".ogg": true, ".wav": true,
	".mp3": true, ".escn": true, ".glb": true, ".gltf": true,
	".uid": true,
}

var _editor_plugin: EditorPlugin = null

func set_editor_plugin(plugin: EditorPlugin) -> void:
	_editor_plugin = plugin

# =============================================================================
# list_dir - List files and folders in a directory
# =============================================================================
func list_dir(args: Dictionary) -> Dictionary:
	var root: String = str(args.get(&"root", "res://"))
	var include_hidden: bool = bool(args.get(&"include_hidden", false))

	if not root.begins_with("res://"):
		root = "res://" + root

	var dir := DirAccess.open(root)
	if dir == null:
		return {&"ok": false, &"error": "Cannot open directory: " + root}

	var files: PackedStringArray = []
	var folders: PackedStringArray = []

	dir.list_dir_begin()
	var name := dir.get_next()
	while name != "":
		# Skip hidden files unless requested
		if not include_hidden and name.begins_with("."):
			name = dir.get_next()
			continue

		# Skip .uid files
		if name.ends_with(".uid"):
			name = dir.get_next()
			continue

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
		&"ok": true,
		&"path": root,
		&"files": files,
		&"folders": folders,
		&"total": files.size() + folders.size()
	}

# =============================================================================
# read_file - Read contents of a file
# =============================================================================
func read_file(args: Dictionary) -> Dictionary:
	var path: String = str(args.get(&"path", ""))
	var start_line: int = int(args.get(&"start_line", 1))
	var end_line: int = int(args.get(&"end_line", 0))
	var max_bytes: int = int(args.get(&"max_bytes", DEFAULT_MAX_BYTES))

	if path.strip_edges().is_empty():
		return {&"ok": false, &"error": "Missing 'path' parameter"}

	if not path.begins_with("res://"):
		path = "res://" + path

	if not FileAccess.file_exists(path):
		return {&"ok": false, &"error": "File not found: " + path}

	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return {&"ok": false, &"error": "Cannot open file: " + path}

	var content: String
	var line_count: int = 0

	# Bulk read — single syscall for any access pattern
	var file_size := file.get_length()
	var read_size := mini(max_bytes, file_size)
	var raw_content := file.get_buffer(read_size).get_string_from_utf8()
	file.close()

	if end_line <= 0 and start_line <= 1:
		content = raw_content
		line_count = content.count("\n") + 1
	else:
		# Slice the requested line range from the bulk-read content
		var all_lines := raw_content.split("\n")
		var from := maxi(start_line - 1, 0)
		var to := all_lines.size() if end_line <= 0 else mini(end_line, all_lines.size())
		var sliced := all_lines.slice(from, to)
		content = "\n".join(sliced)
		line_count = sliced.size()

	return {
		&"ok": true,
		&"path": path,
		&"content": content,
		&"line_count": line_count,
		&"range": [start_line, end_line] if end_line > 0 else null
	}

# =============================================================================
# search_project - Search for text in project files
# =============================================================================
func search_project(args: Dictionary) -> Dictionary:
	var query: String = str(args.get(&"query", ""))
	var glob_filter: String = str(args.get(&"glob", ""))
	var max_results: int = int(args.get(&"max_results", DEFAULT_MAX_RESULTS))
	var case_sensitive: bool = bool(args.get(&"case_sensitive", false))

	if query.strip_edges().is_empty():
		return {&"ok": false, &"error": "Missing 'query' parameter"}

	var search_query := query if case_sensitive else query.to_lower()
	var files := _collect_files("res://", glob_filter)
	var matches: Array = []

	for file_path: String in files:
		if matches.size() >= max_results:
			break

		var file := FileAccess.open(file_path, FileAccess.READ)
		if file == null:
			continue

		# Bulk read — single syscall instead of one per line
		var content := file.get_as_text()
		file.close()

		# Quick whole-file check to skip non-matching files entirely
		var search_content := content if case_sensitive else content.to_lower()
		if search_content.find(search_query) == -1:
			continue

		# Only split files that actually contain the query
		var lines := content.split("\n")
		for i: int in range(lines.size()):
			var line := lines[i]
			var search_line := line if case_sensitive else line.to_lower()
			if search_line.find(search_query) != -1:
				matches.append({
					&"file": file_path,
					&"line": i + 1,
					&"content": line.strip_edges()
				})
				if matches.size() >= max_results:
					break

	return {
		&"ok": true,
		&"query": query,
		&"matches": matches,
		&"total_matches": matches.size(),
		&"truncated": matches.size() >= max_results
	}

func _collect_files(path: String, glob_filter: String) -> PackedStringArray:
	"""Recursively collect all searchable files."""
	var result: PackedStringArray = []
	_collect_files_recursive(path, glob_filter, result)
	return result

func _collect_files_recursive(path: String, glob_filter: String, out: PackedStringArray, depth: int = 0) -> void:
	if depth >= MAX_TRAVERSAL_DEPTH:
		return
	var dir := DirAccess.open(path)
	if dir == null:
		return

	dir.list_dir_begin()
	var file_name := dir.get_next()
	while file_name != "":
		# Skip hidden
		if file_name.begins_with("."):
			file_name = dir.get_next()
			continue

		var full_path := path.path_join(file_name)

		if dir.current_is_dir():
			_collect_files_recursive(full_path, glob_filter, out, depth + 1)
		else:
			# Skip binary files — O(1) Dictionary lookup on the extension
			var ext := "." + file_name.get_extension().to_lower()
			if not _SKIP_EXTENSIONS.has(ext):
				if glob_filter.is_empty() or _matches_glob(full_path, glob_filter):
					out.append(full_path)

		file_name = dir.get_next()
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
	var path: String = str(args.get(&"path", ""))
	var content: String = str(args.get(&"content", ""))

	if path.strip_edges().is_empty():
		return {&"ok": false, &"error": "Missing 'path' parameter"}

	if not path.begins_with("res://"):
		path = "res://" + path

	# Add .gd extension if missing
	if not "." in path.get_file():
		path += ".gd"

	# Check if file already exists
	if FileAccess.file_exists(path):
		return {&"ok": false, &"error": "File already exists: " + path}

	# Ensure parent directory exists
	var dir_path := path.get_base_dir()
	if not DirAccess.dir_exists_absolute(dir_path):
		var err := DirAccess.make_dir_recursive_absolute(dir_path)
		if err != OK:
			return {&"ok": false, &"error": "Could not create directory: " + dir_path}

	# Write file
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		return {&"ok": false, &"error": "Could not create file: " + path}

	file.store_string(content)
	file.close()

	# Refresh filesystem so Godot sees the new file
	_refresh_filesystem()

	return {
		&"ok": true,
		&"path": path,
		&"size_bytes": content.length(),
		&"message": "Script created successfully"
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
