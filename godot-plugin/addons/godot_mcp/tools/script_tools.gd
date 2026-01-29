@tool
extends Node
class_name ScriptTools
## Script and file management tools for MCP.
## Handles: apply_diff_preview, validate_script, list_scripts,
##          create_folder, delete_file, rename_file

var _editor_plugin: EditorPlugin = null

func set_editor_plugin(plugin: EditorPlugin) -> void:
	_editor_plugin = plugin

func _refresh_filesystem() -> void:
	if _editor_plugin:
		_editor_plugin.get_editor_interface().get_resource_filesystem().scan()

func _ensure_res_path(path: String) -> String:
	if not path.begins_with("res://"):
		return "res://" + path
	return path

# =============================================================================
# apply_diff_preview - Simplified snippet replace without CodeApplier dependency
# =============================================================================
func apply_diff_preview(args: Dictionary) -> Dictionary:
	var edit: Dictionary = args.get("edit", {})
	if edit.is_empty():
		return {"ok": false, "error": "Missing 'edit' payload"}

	var path: String = str(edit.get("file", ""))
	if path.is_empty():
		return {"ok": false, "error": "Missing 'file' in edit"}

	path = _ensure_res_path(path)

	if not FileAccess.file_exists(path):
		return {"ok": false, "error": "File not found: " + path}

	var spec_type: String = str(edit.get("type", "snippet_replace"))
	if spec_type != "snippet_replace":
		return {"ok": false, "error": "Only 'snippet_replace' type is supported"}

	var old_snippet: String = str(edit.get("old_snippet", ""))
	var new_snippet: String = str(edit.get("new_snippet", ""))
	var context_before: String = str(edit.get("context_before", ""))
	var context_after: String = str(edit.get("context_after", ""))

	if old_snippet.is_empty():
		return {"ok": false, "error": "Missing 'old_snippet' in edit"}

	# Read current file content
	var file := FileAccess.open(path, FileAccess.READ)
	if not file:
		return {"ok": false, "error": "Cannot read file: " + path}
	var content := file.get_as_text()
	file.close()

	# Find and replace the snippet
	var search_text := old_snippet
	var pos := content.find(search_text)

	# If not found directly, try with context
	if pos == -1 and not context_before.is_empty():
		var ctx_pos := content.find(context_before)
		if ctx_pos != -1:
			var after_ctx := ctx_pos + context_before.length()
			var remaining := content.substr(after_ctx)
			var snippet_pos := remaining.find(old_snippet)
			if snippet_pos != -1:
				pos = after_ctx + snippet_pos

	if pos == -1:
		return {"ok": false, "error": "Could not find old_snippet in file. Make sure old_snippet matches the file content exactly."}

	# Check for multiple occurrences
	var second_pos := content.find(search_text, pos + 1)
	if second_pos != -1 and context_before.is_empty() and context_after.is_empty():
		return {"ok": false, "error": "old_snippet appears multiple times. Add context_before or context_after for disambiguation."}

	# Apply the replacement
	var original_content := content
	var new_content := content.substr(0, pos) + new_snippet + content.substr(pos + old_snippet.length())

	# Write back
	file = FileAccess.open(path, FileAccess.WRITE)
	if not file:
		return {"ok": false, "error": "Cannot write file: " + path}
	file.store_string(new_content)
	file.close()

	# Count changes
	var old_lines := old_snippet.split("\n")
	var new_lines := new_snippet.split("\n")
	var added := maxi(0, new_lines.size() - old_lines.size())
	var removed := maxi(0, old_lines.size() - new_lines.size())

	_refresh_filesystem()

	return {
		"ok": true,
		"path": path,
		"added": added,
		"removed": removed,
		"auto_applied": true,
		"message": "Applied edit to %s (+%d -%d lines)" % [path, added, removed]
	}

# =============================================================================
# validate_script
# =============================================================================
func validate_script(args: Dictionary) -> Dictionary:
	var path: String = str(args.get("path", ""))
	if path.strip_edges().is_empty():
		return {"ok": false, "error": "Missing 'path'"}

	path = _ensure_res_path(path)

	if not FileAccess.file_exists(path):
		return {"ok": false, "error": "File not found: " + path}

	# Attempt to load the script - Godot will parse it
	var script: GDScript = load(path)

	if script == null:
		return {
			"ok": true,
			"valid": false,
			"path": path,
			"message": "Script has syntax errors. Check Godot console for details."
		}

	if not script.can_instantiate():
		return {
			"ok": true,
			"valid": false,
			"path": path,
			"message": "Script loaded but cannot be instantiated (may have errors)"
		}

	return {
		"ok": true,
		"valid": true,
		"path": path,
		"message": "No syntax errors found"
	}

# =============================================================================
# list_scripts
# =============================================================================
func list_scripts(args: Dictionary) -> Dictionary:
	var scripts: Array = []
	_collect_scripts("res://", scripts)

	return {
		"ok": true,
		"scripts": scripts,
		"count": scripts.size()
	}

func _collect_scripts(path: String, out: Array) -> void:
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
			_collect_scripts(full_path, out)
		elif name.ends_with(".gd"):
			out.append(full_path)

		name = dir.get_next()
	dir.list_dir_end()

# =============================================================================
# create_folder
# =============================================================================
func create_folder(args: Dictionary) -> Dictionary:
	var path: String = str(args.get("path", ""))
	if path.strip_edges().is_empty():
		return {"ok": false, "error": "Missing 'path'"}

	path = _ensure_res_path(path)

	if DirAccess.dir_exists_absolute(path):
		return {"ok": true, "path": path, "message": "Directory already exists"}

	var err := DirAccess.make_dir_recursive_absolute(path)
	if err != OK:
		return {"ok": false, "error": "Failed to create directory: " + str(err)}

	_refresh_filesystem()

	return {"ok": true, "path": path, "message": "Directory created"}

# =============================================================================
# delete_file
# =============================================================================
func delete_file(args: Dictionary) -> Dictionary:
	var path: String = str(args.get("path", ""))
	var confirm: bool = bool(args.get("confirm", false))
	var create_backup: bool = bool(args.get("create_backup", true))

	if path.strip_edges().is_empty():
		return {"ok": false, "error": "Missing 'path'"}
	if not confirm:
		return {"ok": false, "error": "Must set confirm=true to delete"}

	path = _ensure_res_path(path)

	if not FileAccess.file_exists(path):
		return {"ok": false, "error": "File not found: " + path}

	# Create backup
	if create_backup:
		var backup_path := path + ".bak"
		DirAccess.copy_absolute(path, backup_path)

	var err := DirAccess.remove_absolute(path)
	if err != OK:
		return {"ok": false, "error": "Failed to delete file: " + str(err)}

	_refresh_filesystem()

	return {"ok": true, "path": path, "message": "File deleted" + (" (backup created)" if create_backup else "")}

# =============================================================================
# rename_file
# =============================================================================
func rename_file(args: Dictionary) -> Dictionary:
	var old_path: String = str(args.get("old_path", ""))
	var new_path: String = str(args.get("new_path", ""))

	if old_path.strip_edges().is_empty():
		return {"ok": false, "error": "Missing 'old_path'"}
	if new_path.strip_edges().is_empty():
		return {"ok": false, "error": "Missing 'new_path'"}

	old_path = _ensure_res_path(old_path)
	new_path = _ensure_res_path(new_path)

	if not FileAccess.file_exists(old_path):
		return {"ok": false, "error": "File not found: " + old_path}
	if FileAccess.file_exists(new_path):
		return {"ok": false, "error": "Target already exists: " + new_path}

	# Ensure target directory exists
	var dir_path := new_path.get_base_dir()
	if not DirAccess.dir_exists_absolute(dir_path):
		DirAccess.make_dir_recursive_absolute(dir_path)

	var err := DirAccess.rename_absolute(old_path, new_path)
	if err != OK:
		return {"ok": false, "error": "Failed to rename: " + str(err)}

	_refresh_filesystem()

	return {"ok": true, "old_path": old_path, "new_path": new_path,
		"message": "Renamed %s to %s" % [old_path, new_path]}
