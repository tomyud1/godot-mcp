@tool
extends Node
class_name ScriptTools
## Script and file management tools for MCP.
## Handles: edit_script, validate_script, list_scripts,
##          create_folder, delete_file, rename_file

var _editor_plugin: EditorPlugin = null

## Set by ToolExecutor for self-snapshotting tools (delete_folder). May stay
## null in non-editor / test contexts — handlers must degrade gracefully.
var _undo_manager: MCPUndoManager = null

func set_editor_plugin(plugin: EditorPlugin) -> void:
	_editor_plugin = plugin

func set_undo_manager(manager: MCPUndoManager) -> void:
	_undo_manager = manager

func _refresh_filesystem() -> void:
	if _editor_plugin:
		_editor_plugin.get_editor_interface().get_resource_filesystem().scan()

func _ensure_res_path(path: String) -> String:
	if not path.begins_with("res://"):
		return "res://" + path
	return path

# =============================================================================
# edit_script - Apply a small surgical code edit to a GDScript file
# =============================================================================
func edit_script(args: Dictionary) -> Dictionary:
	var edit: Dictionary = args.get(&"edit", {})
	if edit.is_empty():
		return {&"ok": false, &"error": "Missing 'edit' payload"}

	var path: String = str(edit.get(&"file", ""))
	if path.is_empty():
		return {&"ok": false, &"error": "Missing 'file' in edit"}

	path = _ensure_res_path(path)

	if not FileAccess.file_exists(path):
		return {&"ok": false, &"error": "File not found: " + path}

	var spec_type: String = str(edit.get(&"type", "snippet_replace"))
	if spec_type != "snippet_replace":
		return {&"ok": false, &"error": "Only 'snippet_replace' type is supported"}

	var old_snippet: String = str(edit.get(&"old_snippet", ""))
	var new_snippet: String = str(edit.get(&"new_snippet", ""))
	var context_before: String = str(edit.get(&"context_before", ""))
	var context_after: String = str(edit.get(&"context_after", ""))

	if old_snippet.is_empty():
		return {&"ok": false, &"error": "Missing 'old_snippet' in edit"}

	# Read current file content
	var file := FileAccess.open(path, FileAccess.READ)
	if not file:
		return {&"ok": false, &"error": "Cannot read file: " + path}
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
		return {&"ok": false, &"error": "Could not find old_snippet in file. Make sure old_snippet matches the file content exactly."}

	# Check for multiple occurrences
	var second_pos := content.find(search_text, pos + 1)
	if second_pos != -1 and context_before.is_empty() and context_after.is_empty():
		return {&"ok": false, &"error": "old_snippet appears multiple times. Add context_before or context_after for disambiguation."}

	# Apply the replacement
	var original_content := content
	var new_content := content.substr(0, pos) + new_snippet + content.substr(pos + old_snippet.length())

	# Write back
	file = FileAccess.open(path, FileAccess.WRITE)
	if not file:
		return {&"ok": false, &"error": "Cannot write file: " + path}
	file.store_string(new_content)
	file.close()

	# Count changes
	var old_lines := old_snippet.split("\n")
	var new_lines := new_snippet.split("\n")
	var added := maxi(0, new_lines.size() - old_lines.size())
	var removed := maxi(0, old_lines.size() - new_lines.size())

	_refresh_filesystem()

	return {
		&"ok": true,
		&"path": path,
		&"added": added,
		&"removed": removed,
		&"auto_applied": true,
		&"message": "Applied edit to %s (+%d -%d lines)" % [path, added, removed]
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
		var message: String = "Script has errors."
		var hint: String = ""
		if errors.size() > 0:
			message += " Details: " + "; ".join(errors)
		else:
			message += " Godot returned error_code %d but did not expose parse line details through this validation path." % err
			hint = "For editor-plugin/addon scripts, validate_script can fail without diagnostics because dependencies and @tool context are not fully loaded in this isolated parser path. Check get_errors/get_console_log after enabling or reloading the addon for actionable line details."
		var out: Dictionary = {
			&"ok": true,
			&"valid": false,
			&"path": path,
			&"error_code": err,
			&"errors": errors,
			&"diagnostics_available": errors.size() > 0,
			&"message": message,
		}
		if not hint.is_empty():
			out[&"hint"] = hint
		return out

	# Parsing succeeded. The script is syntactically valid GDScript. We used
	# to *also* check `script.can_instantiate()` and report `valid: false`
	# when it returned false — but that flagged perfectly normal scripts
	# (e.g. `extends Node2D` + `@export var foo: int = 0`) because a
	# free-floating GDScript instance with no resource_path can\'t always
	# satisfy `can_instantiate()` even though `node.set_script(...)` works
	# fine. Treat parse success as the primary signal; surface a
	# `can_instantiate` flag for callers that genuinely care about
	# free-instance creation (autoloads, dynamic class loading).
	return {
		&"ok": true,
		&"valid": true,
		&"path": path,
		&"can_instantiate": script.can_instantiate(),
		&"message": "No syntax errors found"
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
	var scripts: Array = []
	_collect_scripts("res://", scripts)

	return {
		&"ok": true,
		&"scripts": scripts,
		&"count": scripts.size()
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

	# Refuse to delete files the editor currently has open. Deleting the
	# live scene/script out from under the editor (especially the active tab)
	# can crash Godot because internal pointers still reference the
	# in-memory copy. The agent must close the tab first, then retry.
	var open_info := _file_is_open_in_editor(path)
	if open_info[&"open"] and not force:
		return {
			&"ok": false,
			&"error": "Refusing to delete %s: it is currently open in the editor (%s). Close the tab first, or pass force=true to delete anyway (WILL LIKELY CRASH if it's the active scene)." % [path, open_info[&"where"]],
			&"open_in_editor": true,
			&"where": open_info[&"where"],
			&"is_active": open_info[&"is_active"],
		}

	if create_backup:
		var backup_path := path + ".bak"
		DirAccess.copy_absolute(path, backup_path)

	var err := DirAccess.remove_absolute(path)
	if err != OK:
		return {&"ok": false, &"error": "Failed to delete file: " + str(err)}

	_refresh_filesystem()

	return {&"ok": true, &"path": path, &"message": "File deleted" + (" (backup created)" if create_backup else "")}

## Detect whether `path` is currently open in the editor (either as an edited
## scene tab or as a script in the script editor). Returns a dict with:
##   open:      bool — open anywhere in the editor
##   where:     String — short human description (which tab/panel)
##   is_active: bool — true if it's the CURRENTLY FOCUSED scene tab (deleting
##              this case is the most crash-prone)
func _file_is_open_in_editor(path: String) -> Dictionary:
	var out := {&"open": false, &"where": "", &"is_active": false}
	if _editor_plugin == null:
		return out
	var ei := _editor_plugin.get_editor_interface()

	# Scene tabs
	if ei.has_method("get_open_scenes"):
		var open_scenes: PackedStringArray = ei.get_open_scenes()
		if open_scenes.has(path):
			out[&"open"] = true
			out[&"where"] = "scene tab"
			var edited = ei.get_edited_scene_root()
			if edited and edited.scene_file_path == path:
				out[&"is_active"] = true
				out[&"where"] = "active scene tab"
			return out

	# Script editor
	var se := ei.get_script_editor()
	if se:
		for s in se.get_open_scripts():
			if s is Script and s.resource_path == path:
				out[&"open"] = true
				out[&"where"] = "script editor"
				var cur := se.get_current_script()
				if cur and cur.resource_path == path:
					out[&"is_active"] = true
					out[&"where"] = "active script editor tab"
				return out

	return out

# =============================================================================
# rename_file
# =============================================================================
## Move or rename a project file and (by default) update every reference to
## it in other text-format project files. Without the reference rewrite,
## renaming `res://foo.gd` would leave `.tscn` files with broken
## `ext_resource path="res://foo.gd"` lines and `preload("res://foo.gd")`
## calls in scripts, breaking the project the next time the editor scans.
##
## Args:
##   old_path           string   existing file path (with or without res://)
##   new_path           string   new file path; parent dirs auto-created
##   update_references  bool     default true. When true, scan .tscn / .tres
##                               / .gd / .cs / .gdshader / project.godot
##                               for the old path and rewrite to the new
##                               path. Also updates `autoload/*` entries in
##                               ProjectSettings if they pointed at the
##                               renamed file.
##
## Returns {ok, old_path, new_path, references_updated:[{file, replacements}],
## reference_files_scanned, reference_files_changed, message}.
func rename_file(args: Dictionary) -> Dictionary:
	var old_path: String = str(args.get(&"old_path", ""))
	var new_path: String = str(args.get(&"new_path", ""))
	var update_references: bool = bool(args.get(&"update_references", true))

	if old_path.strip_edges().is_empty():
		return {&"ok": false, &"error": "Missing 'old_path'"}
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

	# Capture the resource's UID *before* the move, while ResourceLoader can
	# still resolve old_path. Used after the move to update the central
	# ResourceUID registry — without this, scenes that referenced the
	# resource via uid="uid://..." still resolve to the OLD path on load,
	# producing "file not found" errors against the renamed-away path even
	# though every text reference was rewritten.
	var pre_move_uid: int = ResourceLoader.get_resource_uid(old_path)

	# Move the .uid sidecar (used by .gd, .gdshader, etc.) so the new
	# location stays linked to its UID. .tscn / .tres embed the UID in the
	# file itself, so they don't have a sidecar.
	var old_uid_sidecar: String = old_path + ".uid"
	var new_uid_sidecar: String = new_path + ".uid"
	if FileAccess.file_exists(old_uid_sidecar):
		var sidecar_err := DirAccess.rename_absolute(old_uid_sidecar, new_uid_sidecar)
		if sidecar_err != OK:
			push_warning("[Godot MCP] rename_file: failed to move .uid sidecar %s -> %s (err=%d). UID resolution may stay pinned to the old path until rescan." % [old_uid_sidecar, new_uid_sidecar, sidecar_err])

	var err := DirAccess.rename_absolute(old_path, new_path)
	if err != OK:
		# Try to roll back the sidecar if we already moved it; leaving the
		# project in a half-renamed state is worse than the original error.
		if FileAccess.file_exists(new_uid_sidecar) and not FileAccess.file_exists(old_uid_sidecar):
			DirAccess.rename_absolute(new_uid_sidecar, old_uid_sidecar)
		return {&"ok": false, &"error": "Failed to rename: " + str(err)}

	# Update the central UID registry so .tscn ext_resource lookups (which
	# go UID → path before falling back to the literal path string) resolve
	# to the new location instead of the deleted old one.
	if pre_move_uid != ResourceUID.INVALID_ID:
		if ResourceUID.has_id(pre_move_uid):
			ResourceUID.set_id(pre_move_uid, new_path)
		else:
			ResourceUID.add_id(pre_move_uid, new_path)

	var ref_results: Dictionary = {&"updates": [], &"scanned": 0, &"changed": 0}
	if update_references:
		ref_results = _rewrite_references(old_path, new_path)

	# Tell EditorFileSystem about the move so the editor's in-memory index
	# reflects disk before the next call. update_file() is synchronous; the
	# fallback scan() is async and won't help callers that immediately run
	# run_scene / get_errors.
	_notify_efs_about_rename(old_path, new_path, ref_results.get(&"updates", []))

	# Force-evict any cached version of files we touched. ResourceLoader
	# caches by path; after a rewrite, the next load(path) would otherwise
	# return the stale pre-rewrite resource. CACHE_MODE_REPLACE evicts +
	# reloads. Best-effort: failures (e.g. file gone, type mismatch) are
	# logged but don't abort the rename.
	_evict_resource_cache(old_path, new_path, ref_results.get(&"updates", []))

	# Reload any *clean* open scene tabs whose .tscn we just rewrote. Dirty
	# tabs are skipped and reported; silently closing them would discard
	# unsaved editor-only scene edits.
	var reload_results: Dictionary = _reload_affected_open_scenes(ref_results.get(&"updates", []))
	var scenes_reloaded: Array = reload_results.get(&"reloaded", [])
	var scenes_skipped_dirty: Array = reload_results.get(&"skipped_dirty", [])
	var scene_reload_failed: Array = reload_results.get(&"failed", [])
	var scene_reload_warnings: Array = reload_results.get(&"warnings", [])

	_refresh_filesystem()

	var msg: String = "Renamed %s to %s" % [old_path, new_path]
	if update_references:
		msg += " (updated %d reference(s) across %d file(s))" % [
			_total_replacements(ref_results.get(&"updates", [])),
			int(ref_results.get(&"changed", 0)),
		]
	if not scenes_reloaded.is_empty():
		msg += "; reloaded %d open scene tab(s)" % scenes_reloaded.size()
	if not scenes_skipped_dirty.is_empty():
		msg += "; skipped %d dirty scene tab(s) to preserve unsaved changes" % scenes_skipped_dirty.size()
	if not scene_reload_warnings.is_empty():
		msg += "; skipped %d scene reload(s) because dirty state could not be verified" % scene_reload_warnings.size()

	var response: Dictionary = {
		&"ok": true,
		&"old_path": old_path,
		&"new_path": new_path,
		&"references_updated": ref_results.get(&"updates", []),
		&"reference_files_scanned": int(ref_results.get(&"scanned", 0)),
		&"reference_files_changed": int(ref_results.get(&"changed", 0)),
		&"scenes_reloaded": scenes_reloaded,
		&"message": msg,
	}
	if not scenes_skipped_dirty.is_empty():
		response[&"scenes_skipped_dirty"] = scenes_skipped_dirty
		response[&"warning"] = "Some open scene tabs were not reloaded because they have unsaved changes. Save and reopen those scenes before running if the editor still holds stale script references."
	if not scene_reload_failed.is_empty():
		response[&"scene_reload_failed"] = scene_reload_failed
	if not scene_reload_warnings.is_empty():
		response[&"scene_reload_warnings"] = scene_reload_warnings
	return response

## Drop stale entries from the global Resource cache. ResourceLoader keys
## its cache by path; without this, a load() call against a freshly-
## rewritten .tscn would still return the pre-rewrite PackedScene (the one
## holding the old script reference), which is what made round-6 §2.5 /
## §4.4 fail despite our text rewrites being correct on disk.
func _evict_resource_cache(_old_path: String, new_path: String, updates: Array) -> void:
	# The renamed source file: its new path may already be cached from an
	# earlier load (e.g. when the test scene was first run before the
	# rename). Replacing the cache entry forces the next load to read
	# fresh bytes.
	if ResourceLoader.has_cached(new_path):
		ResourceLoader.load(new_path, "", ResourceLoader.CACHE_MODE_REPLACE)
	# Every rewritten resource file: its on-disk content changed under our
	# feet, so any cached copy is stale.
	for u in updates:
		var p: String = str((u as Dictionary).get(&"file", ""))
		if not p.begins_with("res://"):
			continue
		# Only cacheable resource types — skipping project.godot, .gd, .cs
		# (loaded as scripts, but reloading them mid-edit is risky and the
		# script editor handles its own refresh).
		var ext: String = p.get_extension().to_lower()
		if ext != "tscn" and ext != "tres" and ext != "gdshader" and ext != "shader":
			continue
		if ResourceLoader.has_cached(p):
			ResourceLoader.load(p, "", ResourceLoader.CACHE_MODE_REPLACE)

## Tell EditorFileSystem the renamed file moved + every rewritten file
## changed. update_file() is synchronous — the index reflects disk
## immediately afterward — whereas scan() is async and won't have completed
## by the time the caller does its next run_scene / get_errors.
func _notify_efs_about_rename(old_path: String, new_path: String, updates: Array) -> void:
	if not _editor_plugin:
		return
	var efs := _editor_plugin.get_editor_interface().get_resource_filesystem()
	if efs == null:
		return
	if efs.has_method("update_file"):
		efs.call("update_file", old_path)
		efs.call("update_file", new_path)
		for u in updates:
			var p: String = str((u as Dictionary).get(&"file", ""))
			# Skip synthetic "project.godot:autoload/X" entries — they're
			# logical references, not real files EFS needs to re-index.
			if not p.begins_with("res://"):
				continue
			efs.call("update_file", p)

## Close + reopen any clean scene tab whose .tscn we just rewrote. This is the
## only reliable way to evict a stale PackedScene from the editor's in-memory
## resource cache for an open tab; ResourceLoader.CACHE_MODE_REPLACE only
## affects future loads, not currently-edited resources. Dirty tabs are skipped
## because close_scene() discards unsaved changes. If the Godot build does not
## expose a reliable dirty-state API, reload is skipped with a warning rather
## than risking unsaved data loss.
func _reload_affected_open_scenes(updates: Array) -> Dictionary:
	var result: Dictionary = {&"reloaded": [], &"skipped_dirty": [], &"failed": [], &"warnings": []}
	if not _editor_plugin:
		return result
	var ei := _editor_plugin.get_editor_interface()
	if ei == null:
		return result
	if not ei.has_method("get_open_scenes") or not ei.has_method("open_scene_from_path") or not ei.has_method("close_scene"):
		return result
	var open: PackedStringArray = ei.get_open_scenes()
	if open.is_empty():
		return result
	# Build the set of rewritten scene paths.
	var rewritten_scenes: Dictionary = {}
	for u in updates:
		var p: String = str((u as Dictionary).get(&"file", ""))
		if p.ends_with(".tscn"):
			rewritten_scenes[p] = true
	if rewritten_scenes.is_empty():
		return result
	# Remember which tab was active so we can restore focus afterward.
	var previously_edited: Node = ei.get_edited_scene_root()
	var previously_edited_path: String = previously_edited.scene_file_path if previously_edited else ""
	for path_v in open:
		var path: String = str(path_v)
		if not rewritten_scenes.has(path):
			continue
		# close_scene() closes the *currently edited* scene, so we have to
		# focus the target tab first. open_scene_from_path on an already-open
		# scene just brings it into focus (no reload).
		ei.open_scene_from_path(path)
		if not ei.has_method("is_scene_changed"):
			result[&"warnings"].append({
				&"path": path,
				&"reason": "dirty_state_unknown",
				&"message": "Skipped automatic scene reload because this Godot version does not expose EditorInterface.is_scene_changed(); closing could discard unsaved changes. The rewritten file is correct on disk, and UID-backed scene references should still run cleanly, but the open editor tab may show stale paths until manually reopened.",
			})
			continue
		if bool(ei.call("is_scene_changed")):
			result[&"skipped_dirty"].append(path)
			continue
		var err = ei.close_scene()
		if err != OK:
			# Tab couldn't be closed — leave it alone, the user can reload
			# manually. Reporting the failure is more useful than silently
			# pretending we reloaded.
			result[&"failed"].append({&"path": path, &"error_code": err})
			continue
		ei.open_scene_from_path(path)
		result[&"reloaded"].append(path)
	# Restore focus.
	if not previously_edited_path.is_empty():
		ei.open_scene_from_path(previously_edited_path)
	return result

## Project file extensions that are text-format and may contain res:// paths.
## Binary formats (.scn, .res, .png, etc.) are skipped — paths inside binary
## resources are stored as numeric resource ids, not literal strings.
const _REWRITABLE_EXTS: Array[String] = [
	"tscn", "tres", "gd", "cs", "gdshader", "shader", "godot",
]
const _REFERENCE_SCAN_SKIP_DIRS: Array[String] = [
	".godot", ".git", ".import", "node_modules",
]
const _REFERENCE_SCAN_SKIP_PATH_PREFIXES: Array[String] = [
	"res://addons/godot_mcp/cache/",
]

func _rewrite_references(old_path: String, new_path: String) -> Dictionary:
	var updates: Array = []
	var scanned: int = 0
	var changed: int = 0
	_rewrite_in_dir("res://", old_path, new_path, updates, [scanned, changed], 0)
	# The accumulator trick (passing a single Array element so it gets
	# mutated by reference) is awkward in GDScript; recompute totals from
	# the updates array, which is the source of truth.
	scanned = _rewrite_in_dir_scan_count
	_rewrite_in_dir_scan_count = 0
	changed = updates.size()

	# Also fix autoload entries — those live in ProjectSettings, not in any
	# file we just scanned (project.godot was scanned, but ProjectSettings
	# in-memory state needs an explicit update so the next save doesn't
	# overwrite our text-level edit).
	var autoload_updates: Array = _rewrite_autoload_references(old_path, new_path)
	for u in autoload_updates:
		updates.append(u)
	if not autoload_updates.is_empty():
		# Persist the in-memory ProjectSettings change.
		ProjectSettings.save()

	return {&"updates": updates, &"scanned": scanned, &"changed": changed + autoload_updates.size()}

# Module-level counter populated by _rewrite_in_dir so callers can read the
# number of files we actually opened. Reset at the top of _rewrite_references.
var _rewrite_in_dir_scan_count: int = 0

func _rewrite_in_dir(dir_path: String, old_path: String, new_path: String, updates: Array, _unused: Array, depth: int) -> void:
	if depth > 12:
		return
	var d := DirAccess.open(dir_path)
	if d == null:
		return
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
			if _should_skip_reference_scan_dir(entry, full):
				entry = d.get_next()
				continue
			_rewrite_in_dir(full, old_path, new_path, updates, _unused, depth + 1)
		else:
			# Skip the renamed file itself (it's at new_path now anyway).
			if full == new_path:
				entry = d.get_next()
				continue
			var ext: String = entry.get_extension().to_lower()
			# project.godot has no extension Godot exposes via get_extension;
			# special-case it.
			var should_scan: bool = ext in _REWRITABLE_EXTS or entry == "project.godot"
			if should_scan:
				_rewrite_in_dir_scan_count += 1
				var n_replaced: int = _rewrite_one_file(full, old_path, new_path)
				if n_replaced > 0:
					updates.append({&"file": full, &"replacements": n_replaced})
		entry = d.get_next()
	d.list_dir_end()

func _should_skip_reference_scan_dir(entry: String, full_path: String) -> bool:
	if entry in _REFERENCE_SCAN_SKIP_DIRS:
		return true
	var normalized := full_path
	if not normalized.ends_with("/"):
		normalized += "/"
	for prefix in _REFERENCE_SCAN_SKIP_PATH_PREFIXES:
		if normalized.begins_with(prefix):
			return true
	return false

## Open a text file, replace every literal occurrence of `old_path` with
## `new_path`, and write back. Returns the number of replacements made.
## Path strings inside Godot resource files are always literal "res://..."
## (no escape sequences for the slash), so a simple substring replace is
## both safe and exhaustive.
func _rewrite_one_file(file_path: String, old_path: String, new_path: String) -> int:
	var f := FileAccess.open(file_path, FileAccess.READ)
	if not f:
		return 0
	var content: String = f.get_as_text()
	f.close()
	if not (old_path in content):
		return 0
	# count() exists on String in Godot 4 — counts non-overlapping matches.
	var n: int = content.count(old_path)
	var rewritten: String = content.replace(old_path, new_path)
	var w := FileAccess.open(file_path, FileAccess.WRITE)
	if not w:
		# Couldn't write — surface zero so the caller doesn't think the
		# file changed when it actually didn't.
		return 0
	w.store_string(rewritten)
	w.close()
	return n

func _rewrite_autoload_references(old_path: String, new_path: String) -> Array:
	var updates: Array = []
	for prop: Dictionary in ProjectSettings.get_property_list():
		var pname: String = prop.get(&"name", "")
		if not pname.begins_with("autoload/"):
			continue
		var current := str(ProjectSettings.get_setting(pname, ""))
		var enabled_marker: String = "*" if current.begins_with("*") else ""
		var clean: String = current.lstrip("*")
		if clean == old_path:
			ProjectSettings.set_setting(pname, enabled_marker + new_path)
			updates.append({&"file": "project.godot:" + pname, &"replacements": 1})
	return updates

func _total_replacements(updates: Array) -> int:
	var total: int = 0
	for u in updates:
		total += int((u as Dictionary).get(&"replacements", 0))
	return total

# =============================================================================
# delete_folder - Recursively delete a directory and all of its contents.
# =============================================================================
## Self-snapshotting tool: before deleting anything it records every contained
## file with the undo manager, so a single `mcp_undo` restores the whole tree.
## The dispatcher hands the snapshot entry id in via args["__entry_id"].
##
## Args:
##   path           string  folder to delete (res:// prepended if missing)
##   confirm        bool    REQUIRED — must be true
##   recursive      bool    REQUIRED for a non-empty folder
##   force          bool    bypass the "file open in editor" guard
##   force_orphan   bool    delete even if files are referenced from outside
##   allow_no_undo  bool    delete a too-large folder without an undo entry
##
## Returns {ok, path, deleted_files, deleted_count, removed_dirs, total_bytes,
##          undo_available, message} (+ partial / delete_errors on partial fail).
##
## Folders never restore empty sub-directories on undo — only files are tracked.
func delete_folder(args: Dictionary) -> Dictionary:
	var path: String = str(args.get(&"path", ""))
	var confirm: bool = bool(args.get(&"confirm", false))
	var recursive: bool = bool(args.get(&"recursive", false))
	var force: bool = bool(args.get(&"force", false))
	var force_orphan: bool = bool(args.get(&"force_orphan", false))
	var allow_no_undo: bool = bool(args.get(&"allow_no_undo", false))
	var entry_id: String = str(args.get(&"__entry_id", ""))

	if path.strip_edges().is_empty():
		return {&"ok": false, &"error": "Missing 'path'"}
	if not confirm:
		return {&"ok": false, &"error": "Must set confirm=true to delete a folder"}

	path = _ensure_res_path(path.strip_edges())
	# Drop any trailing slash, but never mangle the 'res://' prefix itself.
	while path.length() > 6 and path.ends_with("/"):
		path = path.substr(0, path.length() - 1)

	if path == "res://":
		return {&"ok": false, &"error": "Refusing to delete the project root (res://)"}

	# Never delete the plugin itself or anything that contains it — doing so
	# mid-operation would crash the editor and orphan this very tool.
	var dir_with_slash := path + "/"
	for protected in _DELETE_FOLDER_PROTECTED:
		if protected == path \
				or protected.begins_with(dir_with_slash) \
				or path.begins_with(protected + "/"):
			return {
				&"ok": false,
				&"error": "Refusing to delete protected path: %s (overlaps %s)" % [path, protected],
			}

	if not DirAccess.dir_exists_absolute(path):
		if FileAccess.file_exists(path):
			return {&"ok": false, &"error": "%s is a file, not a folder. Use delete_file instead." % path}
		return {&"ok": false, &"error": "Folder not found: " + path}

	# --- Walk the tree. files: all contained files; subdirs: post-order so
	#     forward iteration removes the deepest directory first. ---
	var files: Array = []
	var subdirs: Array = []
	_walk_folder(path, files, subdirs)

	if (not files.is_empty() or not subdirs.is_empty()) and not recursive:
		return {
			&"ok": false,
			&"error": "Folder '%s' is not empty (%d file(s), %d sub-folder(s)). Pass recursive=true to delete it and everything inside." % [path, files.size(), subdirs.size()],
			&"not_empty": true,
			&"file_count": files.size(),
			&"subdir_count": subdirs.size(),
		}

	# --- Guard 1: files open in the editor. ---
	if not force:
		var open_files: Array = []
		for f in files:
			var info := _file_is_open_in_editor(str(f))
			if info[&"open"]:
				open_files.append({
					&"path": f,
					&"where": info[&"where"],
					&"is_active": info[&"is_active"],
				})
		if not open_files.is_empty():
			return {
				&"ok": false,
				&"error": "Refusing to delete %s: %d file(s) inside are open in the editor. Close those tabs first, or pass force=true (deleting an open scene can crash Godot)." % [path, open_files.size()],
				&"open_in_editor": open_files,
			}

	# --- Guard 2: references from OUTSIDE the folder. ---
	if not force_orphan:
		var refs := _scan_external_references(path, files)
		if not refs.is_empty():
			return {
				&"ok": false,
				&"error": "Refusing to delete %s: %d external file(s) contain a literal 'res://...' string pointing into this folder (preload, ext_resource path=, FileAccess.open targets, hardcoded path strings, autoload entries, etc.). The scan is intentionally conservative — ANY literal path-string match counts, even runtime targets that get re-created on next run, because the scanner cannot statically tell the difference between a load-bearing reference and a benign string. To proceed: (a) repoint or remove the listed references, or (b) pass force_orphan=true to delete anyway (the listed files will end up with dangling/broken references; runtime-only string references will simply hit a missing path until the script writes the file again)." % [path, refs.size()],
				&"referenced": refs,
				&"hint": "If you reviewed the 'referenced' list and these are safe to orphan (e.g. runtime FileAccess write targets), retry with force_orphan=true.",
			}

	# --- Guard 3: undo budget. ---
	var total_bytes := 0
	for f in files:
		total_bytes += _file_size(str(f))
	var have_undo := (_undo_manager != null) and (entry_id != "")
	if not allow_no_undo and have_undo and not files.is_empty():
		var cap: Dictionary = _undo_manager.get_store().cap_status()
		var max_bytes: int = int(cap.get("max_bytes", 0))
		# One delete must not be allowed to monopolise the ring buffer and
		# evict all existing history. Half the cap is the refusal threshold.
		if max_bytes > 0 and total_bytes > max_bytes / 2:
			return {
				&"ok": false,
				&"error": "Refusing to delete %s: its contents (%.1f MB) are too large to snapshot for undo without evicting existing history (cap %.0f MB). Pass allow_no_undo=true to delete without an undo entry." % [path, total_bytes / 1048576.0, max_bytes / 1048576.0],
				&"too_large_for_undo": true,
				&"total_bytes": total_bytes,
			}

	# --- Record snapshots BEFORE deleting (record_deletion reads the file). ---
	var record := have_undo and not allow_no_undo
	var undo_available := false
	var undo_skipped: Array = []
	if record:
		for f in files:
			if _undo_manager.record_deletion(entry_id, str(f)):
				undo_available = true
			else:
				undo_skipped.append(f)

	# --- Delete files, then empty sub-directories (deepest first), then root. ---
	var deleted_files: Array = []
	var delete_errors: Array = []
	for f in files:
		var ferr := DirAccess.remove_absolute(ProjectSettings.globalize_path(str(f)))
		if ferr == OK:
			deleted_files.append(f)
		else:
			delete_errors.append({&"path": f, &"error": error_string(ferr)})

	var removed_dirs: Array = []
	for d in subdirs:
		if DirAccess.remove_absolute(ProjectSettings.globalize_path(str(d))) == OK:
			removed_dirs.append(d)
	var root_removed := DirAccess.remove_absolute(ProjectSettings.globalize_path(path)) == OK

	_refresh_filesystem()

	# Nothing could be removed AND there were errors — report failure. The
	# dispatcher will discard the (unused) snapshot entry; harmless because no
	# file actually left disk.
	if deleted_files.is_empty() and not delete_errors.is_empty():
		return {
			&"ok": false,
			&"error": "Failed to delete any file in %s (%d error(s))." % [path, delete_errors.size()],
			&"delete_errors": delete_errors,
		}

	var subdir_count := removed_dirs.size()
	var msg := "Deleted folder %s — %d file(s), %d sub-folder(s), %.1f KB" % [
		path, deleted_files.size(), subdir_count, total_bytes / 1024.0]
	if not record:
		msg += " (undo not recorded)"
	elif undo_available:
		msg += " (undo: mcp_undo)"
	else:
		msg += " (undo unavailable — empty folder)"
	if not undo_skipped.is_empty():
		msg += "; %d file(s) could not be backed up for undo" % undo_skipped.size()
	if not delete_errors.is_empty():
		msg += "; %d file(s) failed to delete" % delete_errors.size()

	var result: Dictionary = {
		&"ok": true,
		&"path": path,
		&"deleted_files": deleted_files,
		&"deleted_count": deleted_files.size(),
		&"removed_dirs": removed_dirs,
		&"root_removed": root_removed,
		&"total_bytes": total_bytes,
		&"undo_available": undo_available,
		&"message": msg,
	}
	if not delete_errors.is_empty():
		result[&"partial"] = true
		result[&"delete_errors"] = delete_errors
	if not undo_skipped.is_empty():
		result[&"undo_skipped"] = undo_skipped
	return result

## Paths the delete_folder tool will never remove (and never remove a parent of).
const _DELETE_FOLDER_PROTECTED: Array[String] = [
	"res://addons/godot_mcp",
]

# =============================================================================
# write_file - Generic text-file writer (creates or overwrites any text file).
# =============================================================================
## Writes UTF-8 text to a project file. Creates the file when missing; refuses
## to clobber an existing file unless overwrite=true. Auto-creates parent dirs
## unless create_dirs=false. Guards against accidental overwrites of plugin
## source code (anywhere under res://addons/godot_mcp/ except cache/) unless
## force=true.
##
## Snapshot integration: the dispatcher pre-snapshots `path` via snapshot_args.
## Because record_snapshot detects file existence at snapshot time, the entry
## becomes KIND_SNAPSHOT for an overwrite (undo restores prior content) or
## KIND_CREATED for a new write (undo deletes the file). No extra code here.
##
## For GDScript boilerplate (`extends`, `class_name`) use create_script — it
## refuses non-.gd paths after the Gap-4 fix, so the two tools have a clean
## boundary: this writes anything; create_script writes .gd specifically.
func write_file(args: Dictionary) -> Dictionary:
	var path: String = str(args.get(&"path", ""))
	var content_arg: Variant = args.get(&"content", null)
	var overwrite: bool = bool(args.get(&"overwrite", false))
	var create_dirs: bool = bool(args.get(&"create_dirs", true))
	var force: bool = bool(args.get(&"force", false))

	if path.strip_edges().is_empty():
		return {&"ok": false, &"error": "Missing 'path'"}
	if content_arg == null:
		return {&"ok": false, &"error": "Missing 'content' (pass an empty string to write an empty file)"}
	var content: String = str(content_arg)

	path = _ensure_res_path(path.strip_edges())

	# Path-traversal guard. _ensure_res_path only prepends the prefix — it
	# doesn't resolve ".." segments, so "res://foo/../../etc" would happily
	# land outside the project tree once ProjectSettings.globalize_path runs.
	# We refuse any path containing "." or ".." as a standalone segment.
	for segment in path.substr(6).split("/"):
		if segment == ".." or segment == ".":
			return {
				&"ok": false,
				&"error": "Refusing to write to %s: path contains a '%s' segment. Use absolute res:// paths without traversal segments." % [path, segment],
				&"path_traversal": true,
			}

	# Plugin-source guard: writing to live plugin files mid-session can crash
	# the editor (the script is currently loaded). Cache subdirectory is the
	# legitimate write target for the snapshot store and explicitly allowed.
	if path.begins_with("res://addons/godot_mcp/") \
			and not path.begins_with("res://addons/godot_mcp/cache/") \
			and not force:
		return {
			&"ok": false,
			&"error": "Refusing to write to plugin source at %s. Overwriting plugin files mid-session can crash the editor. Pass force=true if you really mean to update the plugin." % path,
			&"protected": true,
		}

	if DirAccess.dir_exists_absolute(path):
		return {&"ok": false, &"error": "%s is a directory, not a file." % path}

	var existed := FileAccess.file_exists(path)
	if existed and not overwrite:
		return {
			&"ok": false,
			&"error": "File already exists at %s. Pass overwrite=true to replace it." % path,
			&"file_exists": true,
		}

	var parent := path.get_base_dir()
	if create_dirs:
		if not parent.is_empty() and parent != "res:/" and not DirAccess.dir_exists_absolute(parent):
			var derr := DirAccess.make_dir_recursive_absolute(parent)
			if derr != OK:
				return {&"ok": false, &"error": "Failed to create parent directory %s: %s" % [parent, error_string(derr)]}
	elif not DirAccess.dir_exists_absolute(parent):
		return {
			&"ok": false,
			&"error": "Parent directory does not exist: %s. Pass create_dirs=true to auto-create." % parent,
		}

	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		return {
			&"ok": false,
			&"error": "Failed to open %s for writing (err %d)" % [path, FileAccess.get_open_error()],
		}
	f.store_string(content)
	f.close()

	# Editor housekeeping — has to run AFTER the disk write so the refresh
	# picks up fresh bytes. Without this, a follow-up load() in the same
	# session can return the stale pre-write resource from cache, and open
	# scene tabs would display the old version.
	var refresh_info := _refresh_editor_after_write(path)

	var bytes := content.to_utf8_buffer().size()
	var response: Dictionary = {
		&"ok": true,
		&"path": path,
		&"existed": existed,
		&"bytes_written": bytes,
		&"message": "%s %s (%d bytes)" % ["Overwrote" if existed else "Created", path, bytes],
	}
	# Surface what the refresh touched so callers (and the test agent) can
	# verify the right open tabs were reloaded.
	var any_refresh: bool = refresh_info.get("cache_evicted", false) \
			or refresh_info.get("scene_reloaded", false) \
			or refresh_info.get("script_reloaded", false)
	if any_refresh:
		response[&"editor_refresh"] = refresh_info
	return response

## Editor housekeeping after a file write. Beyond a plain rescan: replaces
## the ResourceLoader cache entry for the written path (so subsequent load()
## reads fresh bytes), force-reloads cached Script resources, and reloads
## any open scene tab whose .tscn we just rewrote. Returns a summary dict so
## write_file can surface what actually happened.
##
## Why no `has_cached` gate: Godot 4's editor keeps resources alive in places
## ResourceLoader.has_cached() can't see (open scene tabs, EditorFileSystem
## index, threaded loaders). The gate was missing real stale-view scenarios.
## CACHE_MODE_REPLACE is idempotent — when nothing was cached it just loads
## fresh, costing one parse per resource-extension write. The flags reflect
## what the call actually did (load succeeded or failed), not whether a stale
## cache existed beforehand.
func _refresh_editor_after_write(path: String) -> Dictionary:
	var info: Dictionary = {
		&"cache_evicted": false,
		&"scene_reloaded": false,
		&"script_reloaded": false,
	}
	_refresh_filesystem()

	var ext := path.get_extension().to_lower()

	if ext == "tscn" or ext == "tres" or ext == "gdshader" or ext == "shader" or ext == "scn":
		var r = ResourceLoader.load(path, "", ResourceLoader.CACHE_MODE_REPLACE)
		if r != null:
			info[&"cache_evicted"] = true

	if ext == "gd":
		var s = ResourceLoader.load(path, "Script", ResourceLoader.CACHE_MODE_REPLACE)
		if s and s is Script:
			(s as Script).reload()
			info[&"script_reloaded"] = true

	if (ext == "tscn" or ext == "scn") and _editor_plugin:
		var ei := _editor_plugin.get_editor_interface()
		if ei and ei.has_method("get_open_scenes"):
			var open: PackedStringArray = ei.get_open_scenes()
			if open.has(path):
				ei.reload_scene_from_path(path)
				info[&"scene_reloaded"] = true

	return info

## Recursively collect every file and sub-directory under dir_path.
## Hidden files (.import / .uid sidecars, .gdignore, …) are included so the
## folder can actually be emptied and so undo can restore them.
## subdirs is built post-order: a directory is appended only after all of its
## descendants, so iterating subdirs forward removes the deepest one first.
func _walk_folder(dir_path: String, files: Array, subdirs: Array) -> void:
	var d := DirAccess.open(dir_path)
	if d == null:
		return
	d.include_hidden = true
	d.list_dir_begin()
	var entry := d.get_next()
	while entry != "":
		if entry == "." or entry == "..":
			entry = d.get_next()
			continue
		var full := dir_path.path_join(entry)
		if d.current_is_dir():
			_walk_folder(full, files, subdirs)
			subdirs.append(full)
		else:
			files.append(full)
		entry = d.get_next()
	d.list_dir_end()

func _file_size(res_path: String) -> int:
	var f := FileAccess.open(res_path, FileAccess.READ)
	if f == null:
		return 0
	var s := f.get_length()
	f.close()
	return s

func _read_text(file_path: String) -> String:
	var f := FileAccess.open(file_path, FileAccess.READ)
	if f == null:
		return ""
	var t := f.get_as_text()
	f.close()
	return t

## Scan every text-format project file OUTSIDE the folder being deleted for a
## literal reference to any file that is about to be removed. Returns a list of
## {file, references} dictionaries. A folder-prefix pre-check keeps this cheap:
## files that never mention the folder path are skipped without per-path work.
func _scan_external_references(folder_path: String, deleted_files: Array) -> Array:
	var out: Array = []
	if deleted_files.is_empty():
		return out
	var folder_prefix := folder_path
	if not folder_prefix.ends_with("/"):
		folder_prefix += "/"
	var deleted_set: Dictionary = {}
	for f in deleted_files:
		deleted_set[str(f)] = true
	_scan_refs_in_dir("res://", folder_prefix, deleted_set, out)
	return out

func _scan_refs_in_dir(dir_path: String, folder_prefix: String, deleted_set: Dictionary, out: Array) -> void:
	var d := DirAccess.open(dir_path)
	if d == null:
		return
	d.list_dir_begin()
	var entry := d.get_next()
	while entry != "":
		if entry == "." or entry == "..":
			entry = d.get_next()
			continue
		var full := dir_path.path_join(entry)
		if d.current_is_dir():
			# Skip caches/.godot/.git and the folder being deleted itself —
			# references from within a folder that's all going away are moot.
			if _should_skip_reference_scan_dir(entry, full) \
					or (full + "/").begins_with(folder_prefix):
				entry = d.get_next()
				continue
			_scan_refs_in_dir(full, folder_prefix, deleted_set, out)
		else:
			var ext := entry.get_extension().to_lower()
			if ext in _REWRITABLE_EXTS or entry == "project.godot":
				var content := _read_text(full)
				if folder_prefix in content:
					for dp in deleted_set:
						if dp in content:
							out.append({&"file": full, &"references": dp})
		entry = d.get_next()
	d.list_dir_end()
