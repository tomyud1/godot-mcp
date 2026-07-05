@tool
extends Node
class_name ScriptTools
## Script and file management tools for MCP.
## Handles: edit_script, validate_script, list_scripts,
##          create_folder, delete_file, rename_file

const FILE_TOOLS = preload("res://addons/godot_mcp/tools/file_tools.gd")

const _REFERENCE_SCAN_EXTS: Dictionary = {
	".gd": true,
	".tscn": true,
	".tres": true,
	".material": true,
	".gdshader": true,
	".cfg": true,
	".json": true,
}

var _editor_plugin: EditorPlugin = null

func set_editor_plugin(plugin: EditorPlugin) -> void:
	_editor_plugin = plugin

func _refresh_filesystem() -> void:
	if _editor_plugin:
		_editor_plugin.get_editor_interface().get_resource_filesystem().call_deferred("scan")

func _ensure_res_path(path: String) -> String:
	if not path.begins_with("res://"):
		return "res://" + path
	return path

# =============================================================================
# Post-edit helpers
# -----------------------------------------------------------------------------
# These let edit_script / patch_file_lines / create_script bundle "did this
# parse?" and "what does the surrounding code look like now?" into the same
# tool result, so the model never has to spend a second round-trip on
# read_file + validate_script just to confirm its own write landed.
# =============================================================================

# Parse a GDScript source string in-memory and report whether it compiled.
# We deliberately mirror validate_script (GDScript.new().reload()) so callers
# get the same verdict without paying for a second tool call. On failure we
# pull short error lines from the editor Output panel when available.
func _validate_gd_source(source_code: String, path: String) -> Dictionary:
	var script := GDScript.new()
	script.source_code = source_code
	var err := script.reload()
	if err == OK:
		return {&"parsed": true}
	var details: Array = _collect_recent_script_errors(path)
	var out: Dictionary = {
		&"parsed": false,
		&"error_code": err,
	}
	if details.size() > 0:
		out[&"errors"] = details
	return out

# Build a numbered snippet of `lines` covering [start_line..end_line] (1-indexed,
# inclusive) padded by `context` lines above and below. Lines inside the edit
# region are prefixed with '>' so the model can immediately see what changed.
# This format matches read_file's preview convention so callers can reuse the
# numbers with read_file/patch_file_lines for follow-up edits.
static func _format_line_window(lines: Array, start_line: int, end_line: int, context: int) -> String:
	var total: int = lines.size()
	if total == 0:
		return ""
	var anchor_start: int = start_line
	var anchor_end: int = end_line
	# Pure delete: nothing remains in the region. Anchor the snippet at the
	# join point so the model can see the surrounding context.
	if anchor_end < anchor_start:
		anchor_end = anchor_start
	var first: int = maxi(1, anchor_start - context)
	var last: int = mini(total, anchor_end + context)
	if last < first:
		return ""
	var out: Array = []
	for i in range(first, last + 1):
		var marker: String = ">" if i >= start_line and i <= end_line else " "
		out.append("%s%5d| %s" % [marker, i, lines[i - 1]])
	return "\n".join(out)

# Attach script_metadata + validation to a result dict for .gd file edits, so
# the model can confirm the write parsed without a follow-up tool call.
func _attach_post_edit_summary(result: Dictionary, path: String, source_code: String) -> void:
	if path.get_extension().to_lower() != "gd":
		return
	result[&"validation"] = _validate_gd_source(source_code, path)
	var meta: Dictionary = FILE_TOOLS.analyze_script_header(path)
	meta.erase(&"path")
	result[&"script_metadata"] = meta

# =============================================================================
# edit_script - Replace the contents of a script file
# =============================================================================
func edit_script(args: Dictionary) -> Dictionary:
	# v0.5 accepted a surgical `edit` object. Keep that wire shape working
	# while exposing the newer full-file path/content form to MCP clients.
	if args.has(&"edit"):
		return _edit_script_snippet(args.get(&"edit", {}))
	var path: String = str(args.get(&"path", ""))
	var content: String = str(args.get(&"content", ""))

	if path.strip_edges().is_empty():
		return {&"ok": false, &"error": "Missing 'path' payload"}

	path = _ensure_res_path(path)

	if not FileAccess.file_exists(path):
		return {&"ok": false, &"error": "File not found: " + path}

	var file := FileAccess.open(path, FileAccess.WRITE)
	if not file:
		return {&"ok": false, &"error": "Cannot write file: " + path}
	file.store_string(content)
	file.close()

	# NOTE: We intentionally do NOT force EditorFileSystem.scan() here.
	# For in-place edits Godot's own file watcher detects the mtime change;
	# forcing a scan races _update_script_classes and has crashed the editor.

	var line_array: PackedStringArray = content.split("\n")
	var result: Dictionary = {
		&"ok": true,
		&"path": path,
		&"new_total_lines": line_array.size(),
		&"size_bytes": content.length(),
		&"message": "Applied full file edit to %s" % path,
	}
	_attach_post_edit_summary(result, path, content)
	return result

func _edit_script_snippet(edit: Dictionary) -> Dictionary:
	if edit.is_empty():
		return {&"ok": false, &"error": "Missing 'edit' payload"}
	var path := _ensure_res_path(str(edit.get(&"file", "")))
	var old_snippet := str(edit.get(&"old_snippet", ""))
	var new_snippet := str(edit.get(&"new_snippet", ""))
	if path == "res://" or old_snippet.is_empty():
		return {&"ok": false, &"error": "edit requires file and old_snippet"}
	if not FileAccess.file_exists(path):
		return {&"ok": false, &"error": "File not found: " + path}
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return {&"ok": false, &"error": "Cannot read file: " + path}
	var content := file.get_as_text()
	file.close()
	var position := content.find(old_snippet)
	if position == -1:
		return {&"ok": false, &"error": "Could not find old_snippet exactly"}
	if content.find(old_snippet, position + old_snippet.length()) != -1 \
		and str(edit.get(&"context_before", "")).is_empty() \
		and str(edit.get(&"context_after", "")).is_empty():
		return {&"ok": false, &"error": "old_snippet appears multiple times; add context"}
	var updated := content.substr(0, position) + new_snippet + content.substr(position + old_snippet.length())
	file = FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		return {&"ok": false, &"error": "Cannot write file: " + path}
	file.store_string(updated)
	file.close()
	var result := {&"ok": true, &"path": path, &"auto_applied": true, &"message": "Applied snippet edit to %s" % path}
	_attach_post_edit_summary(result, path, updated)
	return result

# =============================================================================
# patch_file_lines - Insert/replace/delete exact line ranges
# =============================================================================
func patch_file_lines(args: Dictionary) -> Dictionary:
	var path: String = str(args.get(&"path", ""))
	if path.strip_edges().is_empty():
		return {&"ok": false, &"error": "Missing 'path'"}

	path = _ensure_res_path(path)
	if not FileAccess.file_exists(path):
		return {&"ok": false, &"error": "File not found: " + path}

	var file := FileAccess.open(path, FileAccess.READ)
	if not file:
		return {&"ok": false, &"error": "Cannot read file: " + path}
	var original_text := file.get_as_text()
	file.close()

	var had_trailing_newline := original_text.ends_with("\n")
	var lines: Array = original_text.split("\n")

	var edits: Array = args.get(&"edits", [])
	if edits.is_empty():
		return {&"ok": false, &"error": "Missing 'edits' payload"}

	# Sort edits in reverse order by start_line so modifying lines doesn't offset subsequent edits
	edits.sort_custom(func(a, b): return int(a.get(&"start_line", 1)) > int(b.get(&"start_line", 1)))

	# Track per-edit metadata so the response can describe exactly which lines
	# the patch landed on (no separate read_file follow-up needed).
	var applied_edits: Array = []
	var total_lines_added := 0
	var total_lines_removed := 0
	for edit_obj in edits:
		var start_line: int = int(edit_obj.get(&"start_line", 1))
		if start_line < 1:
			return {&"ok": false, &"error": "start_line must be >= 1"}

		var end_line: int = int(edit_obj.get(&"end_line", start_line))
		var content: String = str(edit_obj.get(&"content", ""))
		var mode: String = str(edit_obj.get(&"mode", "replace"))

		var insert_lines: Array = content.split("\n") if content != "" else []
		var start_index := clampi(start_line - 1, 0, lines.size())
		var inserted_count := 0
		var removed_count := 0

		if mode == "insert":
			for i: int in range(insert_lines.size()):
				lines.insert(start_index + i, insert_lines[i])
			inserted_count = insert_lines.size()
		elif mode == "delete":
			var end_index := clampi(end_line - 1, 0, maxi(lines.size() - 1, 0))
			var to_remove := maxi(0, end_index - start_index + 1)
			for _j: int in range(to_remove):
				if start_index < lines.size():
					lines.remove_at(start_index)
					removed_count += 1
		else: # replace is the default
			end_line = maxi(end_line, start_line)
			start_index = clampi(start_index, 0, maxi(lines.size() - 1, 0))
			var end_index := clampi(end_line - 1, 0, maxi(lines.size() - 1, 0))
			var to_remove := maxi(0, end_index - start_index + 1)
			for _i: int in range(to_remove):
				if start_index < lines.size():
					lines.remove_at(start_index)
					removed_count += 1
			for i: int in range(insert_lines.size()):
				lines.insert(start_index + i, insert_lines[i])
			inserted_count = insert_lines.size()

		total_lines_added += inserted_count
		total_lines_removed += removed_count
		# new_start_line / new_end_line are recomputed below using cumulative
		# offsets — the values captured at apply-time are stale for cascaded
		# edits because we apply bottom-up (so a later edit at a lower line
		# shifts already-recorded coords).
		applied_edits.append({
			&"mode": mode,
			&"start_line": start_line,
			&"end_line": end_line,
			&"lines_added": inserted_count,
			&"lines_removed": removed_count,
		})

	var updated := "\n".join(lines)
	if had_trailing_newline and not updated.ends_with("\n"):
		updated += "\n"

	file = FileAccess.open(path, FileAccess.WRITE)
	if not file:
		return {&"ok": false, &"error": "Cannot write file: " + path}
	file.store_string(updated)
	file.close()

	# NOTE: no explicit EditorFileSystem.scan() — see edit_script for rationale.
	# Godot's file watcher detects in-place modification; forcing a scan here
	# has raced _update_script_classes and crashed the editor.

	# applied_edits was built in reverse order (matches the sort above); flip
	# it back to the user's original order so callers can correlate easily.
	applied_edits.reverse()

	# Walk edits in original-line order accumulating the line delta from each
	# preceding edit. This produces the *final* coordinates of every edited
	# region after all edits have settled — what the model actually needs to
	# locate the new code without a follow-up read_file.
	var by_line: Array = applied_edits.duplicate()
	by_line.sort_custom(func(a, b): return int(a[&"start_line"]) < int(b[&"start_line"]))
	var cumulative_offset := 0
	for ae in by_line:
		var orig_start: int = int(ae[&"start_line"])
		var added: int = int(ae[&"lines_added"])
		var ns: int = orig_start + cumulative_offset
		ae[&"new_start_line"] = ns
		if added > 0:
			ae[&"new_end_line"] = ns + added - 1
		else:
			# Pure delete or empty insert: no surviving lines at this position.
			ae[&"new_end_line"] = ns - 1
		# Snippet of the file as it now exists, with `>` markers on the new
		# region. This is the bit that lets the model skip the read_file
		# round-trip after editing.
		var window: String = _format_line_window(lines, ns, ae[&"new_end_line"], 2)
		if window != "":
			ae[&"context"] = window
		cumulative_offset += added - int(ae[&"lines_removed"])

	var result: Dictionary = {
		&"ok": true,
		&"path": path,
		&"edits": applied_edits,
		&"edit_count": applied_edits.size(),
		&"total_lines_added": total_lines_added,
		&"total_lines_removed": total_lines_removed,
		&"new_total_lines": lines.size(),
		&"final_newline": had_trailing_newline,
		&"message": "Patched %d edit(s); +%d / -%d lines." % [applied_edits.size(), total_lines_added, total_lines_removed]
	}
	_attach_post_edit_summary(result, path, updated)
	return result

# =============================================================================
# spaces_to_tabs
# =============================================================================
func spaces_to_tabs(args: Dictionary) -> Dictionary:
	var path: String = str(args.get(&"path", ""))
	if path.strip_edges().is_empty():
		return {&"ok": false, &"error": "Missing 'path'"}

	path = _ensure_res_path(path)
	if not FileAccess.file_exists(path):
		return {&"ok": false, &"error": "File not found: " + path}

	var spaces_per_tab: int = int(args.get(&"spaces_per_tab", 4))
	if spaces_per_tab < 1:
		spaces_per_tab = 4
	var space_str := ""
	for _i in range(spaces_per_tab):
		space_str += " "

	var file := FileAccess.open(path, FileAccess.READ)
	if not file:
		return {&"ok": false, &"error": "Cannot read file: " + path}
	var content := file.get_as_text()
	file.close()

	var lines := content.split("\n")
	var changed_lines := 0

	for i in range(lines.size()):
		var line: String = lines[i]
		var content_start := -1
		for j in range(line.length()):
			if line[j] != ' ' and line[j] != '\t':
				content_start = j
				break

		if content_start == -1:
			content_start = line.length()

		var prefix: String = line.substr(0, content_start)
		if prefix.contains(" "):
			var tabified_prefix := prefix.replace(space_str, "\t")
			lines[i] = tabified_prefix + line.substr(content_start)
			if lines[i] != line:
				changed_lines += 1

	var new_content := "\n".join(lines)
	if new_content != content:
		file = FileAccess.open(path, FileAccess.WRITE)
		if not file:
			return {&"ok": false, &"error": "Cannot write file: " + path}
		file.store_string(new_content)
		file.close()

	return {
		&"ok": true,
		&"path": path,
		&"message": "Converted spaces to tabs (%d spaces = 1 tab) in %d line(s)." % [spaces_per_tab, changed_lines]
	}

# =============================================================================
# validate_script
# =============================================================================
func validate_script(args: Dictionary) -> Dictionary:
	var path: String = str(args.get(&"path", ""))
	if path.strip_edges().is_empty():
		return {&"ok": false, &"error": "Missing 'path'"}

	path = _ensure_res_path(path)

	if not FileAccess.file_exists(path):
		return {&"ok": false, &"error": "File not found: " + path}

	# Read the source text directly from disk so we validate the *current*
	# file contents, not a stale resource-cache entry.
	var file := FileAccess.open(path, FileAccess.READ)
	if not file:
		return {&"ok": false, &"error": "Cannot read file: " + path}
	var source_code := file.get_as_text()
	file.close()

	# Create a fresh GDScript instance and assign the source for parsing.
	var script := GDScript.new()
	script.source_code = source_code

	# reload() triggers the parser/compiler and returns OK or an error code.
	var err := script.reload()

	if err != OK:
		# Try to extract useful details from the Godot output log.
		var errors := _collect_recent_script_errors(path)
		return {
			&"ok": true,
			&"valid": false,
			&"parsed": false,
			&"loaded": false,
			&"instantiable": false,
			&"path": path,
			&"error_code": err,
			&"errors": errors,
			&"message": "Parse failed." + (" Details: " + "; ".join(errors) if errors.size() > 0 else " Check Godot console for details.")
		}

	# At this point the parser accepted the source. Whether it can be
	# instantiated depends on its base type (e.g. abstract @tool helpers,
	# RefCounted-only classes, or scripts whose base class wasn't loaded yet
	# all return false here even though the source is perfectly valid).
	var instantiable: bool = script.can_instantiate()
	var base_class: String = ""
	if script.get_instance_base_type() != &"":
		base_class = String(script.get_instance_base_type())

	# `valid` now means "the source parses cleanly". Instantiation is reported
	# separately so callers can tell a real failure from an abstract/utility
	# script that simply isn't meant to be `.new()`'d.
	return {
		&"ok": true,
		&"valid": true,
		&"parsed": true,
		&"loaded": true,
		&"instantiable": instantiable,
		&"base_class": base_class,
		&"path": path,
		&"message": "Parsed cleanly." if instantiable else "Parsed cleanly. Script is not directly instantiable (base=%s); this is normal for abstract/utility scripts." % base_class
	}

func _collect_recent_script_errors(script_path: String) -> Array:
	"""Grab recent SCRIPT ERROR / Parse Error lines from the editor Output panel
	that mention the given script path.  Best-effort — returns [] if the panel
	cannot be accessed."""
	var errors: Array = []
	if not _editor_plugin:
		return errors

	# Find the editor's Output panel RichTextLabel
	var base := _editor_plugin.get_editor_interface().get_base_control()
	var editor_log := _find_node_by_class(base, "EditorLog")
	if not editor_log:
		return errors
	var rtl := _find_child_rtl(editor_log)
	if not rtl:
		return errors

	var text: String = rtl.get_parsed_text()
	var short_path := script_path.get_file()  # e.g. "player.gd"

	for line: String in text.split("\n"):
		line = line.strip_edges()
		if line.is_empty():
			continue
		if short_path in line or script_path in line:
			if line.begins_with("SCRIPT ERROR:") or line.begins_with("Parse Error:") \
				or line.begins_with("ERROR:") or line.begins_with("at:"):
				errors.append(line)

	# Keep only the last 10 relevant lines
	if errors.size() > 10:
		errors = errors.slice(errors.size() - 10)
	return errors

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

# =============================================================================
# list_scripts
# =============================================================================
func list_scripts(args: Dictionary) -> Dictionary:
	var root: String = str(args.get(&"root", "res://"))
	var name_filter: String = str(args.get(&"filter", "")).to_lower()
	var max_results: int = int(args.get(&"max_results", 200))
	# Plugin-heavy projects (like this one) drown the list in addon scripts.
	# Default to excluding res://addons/ unless the caller explicitly opts in.
	var exclude_addons: bool = bool(args.get(&"exclude_addons", true))
	if not root.begins_with("res://"):
		root = "res://" + root

	var scripts: Array = []
	_collect_scripts(root, scripts)
	var total := scripts.size()

	var addon_count := 0
	if exclude_addons:
		var project_only: Array = []
		for s in scripts:
			if str(s).begins_with("res://addons/"):
				addon_count += 1
				continue
			project_only.append(s)
		scripts = project_only

	if not name_filter.is_empty():
		var filtered: Array = []
		for s in scripts:
			if str(s).to_lower().find(name_filter) != -1:
				filtered.append(s)
		scripts = filtered

	var truncated := false
	if scripts.size() > max_results:
		truncated = true
		scripts = scripts.slice(0, max_results)

	var result: Dictionary = {
		&"ok": true,
		&"scripts": scripts,
		&"count": scripts.size(),
		&"total": total,
		&"truncated": truncated,
		&"exclude_addons": exclude_addons,
	}
	if exclude_addons and addon_count > 0:
		result[&"addon_count"] = addon_count
		result[&"project_count"] = total - addon_count
		result[&"hint"] = "%d addon script(s) hidden. Pass exclude_addons=false to include them." % addon_count
	return result

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
	var path: String = str(args.get(&"path", ""))
	if path.strip_edges().is_empty():
		return {&"ok": false, &"error": "Missing 'path'"}

	path = _ensure_res_path(path)

	if DirAccess.dir_exists_absolute(path):
		return {&"ok": true, &"path": path, &"message": "Directory already exists"}

	var err := DirAccess.make_dir_recursive_absolute(path)
	if err != OK:
		return {&"ok": false, &"error": "Failed to create directory: " + str(err)}

	_refresh_filesystem()

	return {&"ok": true, &"path": path, &"message": "Directory created"}

# =============================================================================
# delete_file
# =============================================================================
func delete_file(args: Dictionary) -> Dictionary:
	var path: String = str(args.get(&"path", ""))
	var confirm: bool = bool(args.get(&"confirm", false))
	var create_backup: bool = bool(args.get(&"create_backup", true))
	var force: bool = bool(args.get(&"force", false))

	if path.strip_edges().is_empty():
		return {&"ok": false, &"error": "Missing 'path'"}
	if not confirm:
		return {&"ok": false, &"error": "Must set confirm=true to delete"}

	path = _ensure_res_path(path)

	if not FileAccess.file_exists(path):
		return {&"ok": false, &"error": "File not found: " + path}

	var open_info := _file_is_open_in_editor(path)
	if open_info[&"open"] and not force:
		return {
			&"ok": false,
			&"error": "Refusing to delete an open editor file; close its tab or explicitly pass force=true",
			&"open_in_editor": true,
			&"where": open_info[&"where"],
			&"is_active": open_info[&"is_active"],
		}

	# Create backup
	if create_backup:
		var backup_path := path + ".bak"
		DirAccess.copy_absolute(path, backup_path)

	var err := DirAccess.remove_absolute(path)
	if err != OK:
		return {&"ok": false, &"error": "Failed to delete file: " + str(err)}

	_refresh_filesystem()

	return {&"ok": true, &"path": path, &"message": "File deleted" + (" (backup created)" if create_backup else "")}

func _file_is_open_in_editor(path: String) -> Dictionary:
	var out := {&"open": false, &"where": "", &"is_active": false}
	if _editor_plugin == null:
		return out
	var editor := _editor_plugin.get_editor_interface()
	if editor.has_method("get_open_scenes") and editor.get_open_scenes().has(path):
		out[&"open"] = true
		out[&"where"] = "scene tab"
		var edited = editor.get_edited_scene_root()
		if edited and edited.scene_file_path == path:
			out[&"is_active"] = true
			out[&"where"] = "active scene tab"
		return out
	var script_editor := editor.get_script_editor()
	if script_editor:
		for script in script_editor.get_open_scripts():
			if script is Script and script.resource_path == path:
				out[&"open"] = true
				out[&"where"] = "script editor"
				var current := script_editor.get_current_script()
				if current and current.resource_path == path:
					out[&"is_active"] = true
					out[&"where"] = "active script editor tab"
				return out
	return out

# =============================================================================
# rename_file_with_references / move_file_with_references
# =============================================================================
func move_file_with_references(args: Dictionary) -> Dictionary:
	return rename_file_with_references(args)

func rename_file(args: Dictionary) -> Dictionary:
	return rename_file_with_references(args)

func rename_file_with_references(args: Dictionary) -> Dictionary:
	# Schema declares `path` / `new_path`; accept `old_path` as a tolerant alias.
	var old_path: String = str(args.get(&"path", args.get(&"old_path", "")))
	var new_path: String = str(args.get(&"new_path", ""))
	var update_references: bool = bool(args.get(&"update_references", true))

	if old_path.strip_edges().is_empty():
		return {&"ok": false, &"error": "Missing 'path'"}
	if new_path.strip_edges().is_empty():
		return {&"ok": false, &"error": "Missing 'new_path'"}

	old_path = _ensure_res_path(old_path)
	new_path = _ensure_res_path(new_path)

	if not FileAccess.file_exists(old_path):
		return {&"ok": false, &"error": "File not found: " + old_path}
	if FileAccess.file_exists(new_path):
		return {&"ok": false, &"error": "Target already exists: " + new_path}

	# Ensure target directory exists
	var dir_path := new_path.get_base_dir()
	if not DirAccess.dir_exists_absolute(dir_path):
		DirAccess.make_dir_recursive_absolute(dir_path)

	var err := DirAccess.rename_absolute(old_path, new_path)
	if err != OK:
		return {&"ok": false, &"error": "Failed to rename: " + str(err)}

	var updates: Array = []
	if update_references:
		updates = _replace_path_references(old_path, new_path)

	_refresh_filesystem()

	return {
		&"ok": true,
		&"old_path": old_path,
		&"new_path": new_path,
		&"updated_references": updates,
		&"updated_reference_files": updates.size(),
		&"message": "Renamed %s to %s" % [old_path, new_path],
	}

func _replace_path_references(old_path: String, new_path: String) -> Array:
	var files: Array = []
	_collect_reference_files("res://", files)
	var updated: Array = []

	for file_path: String in files:
		if file_path == new_path:
			continue
		var file := FileAccess.open(file_path, FileAccess.READ)
		if file == null:
			continue
		var text := file.get_as_text()
		file.close()

		if text.find(old_path) == -1:
			continue

		var replaced := text.replace(old_path, new_path)
		if replaced == text:
			continue

		file = FileAccess.open(file_path, FileAccess.WRITE)
		if file == null:
			continue
		file.store_string(replaced)
		file.close()

		updated.append(file_path)

	return updated

func _collect_reference_files(path: String, out: Array) -> void:
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
			_collect_reference_files(full_path, out)
		else:
			var ext := "." + name.get_extension().to_lower()
			if _REFERENCE_SCAN_EXTS.has(ext):
				out.append(full_path)

		name = dir.get_next()
	dir.list_dir_end()
