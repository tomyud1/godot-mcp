@tool
extends RefCounted
class_name MCPUndoManager
## Orchestrates the MCP undo/redo system on top of MCPSnapshotStore.
##
## Responsibilities:
##   - begin/commit/discard the per-tool snapshot lifecycle
##   - perform undo: read manifest, restore each file, capture post-state for redo
##   - perform redo: re-apply the captured "redo" content
##   - reload affected scenes/scripts in the editor when their backing file changes
##   - emit a one-shot warning when the cap is hit (no spam)
##
## Pure snapshot model — no integration with EditorUndoRedoManager. The user's
## native Ctrl+Z does NOT reach AI-applied changes; that is a documented
## tradeoff in exchange for one uniform code path.

const SnapshotStoreScript = preload("res://addons/godot_mcp/utils/snapshot_store.gd")

var _store: MCPSnapshotStore
var _editor_plugin: EditorPlugin = null
var _cap_warning_emitted := false

func _init() -> void:
	_store = SnapshotStoreScript.new()

func set_editor_plugin(plugin: EditorPlugin) -> void:
	_editor_plugin = plugin

func get_store() -> MCPSnapshotStore:
	return _store

# =============================================================================
# Per-tool lifecycle
# =============================================================================

## Begin a new entry for tool_name with args. Returns the entry id; the caller
## must call commit() or discard() before returning to the dispatcher.
func begin(tool_name: String, args: Dictionary) -> String:
	return _store.begin_entry(tool_name, args)

## Snapshot a file under res:// (or a path that will become one).
func record_snapshot(id: String, res_path: String) -> void:
	_store.record_snapshot(id, res_path)

## Record that the tool deleted res_path. The store backs up the current
## content so undo can restore it. Returns true if the backup was captured
## (false if the file was missing or could not be copied).
func record_deletion(id: String, res_path: String) -> bool:
	return _store.record_deletion(id, res_path)

## Record a rename old_path → new_path. Undo restores old_path and deletes
## new_path.
func record_rename(id: String, old_path: String, new_path: String) -> void:
	_store.record_rename(id, old_path, new_path)

## Commit the entry to the undo stack. If commit pushes us past the cap, emit
## a single warning (subsequent caps stay quiet).
func commit(id: String) -> void:
	_store.commit_entry(id)
	if _store.is_at_cap() and not _cap_warning_emitted:
		_cap_warning_emitted = true
		var status := _store.cap_status()
		push_warning("[MCP undo] Snapshot ring buffer reached cap (%d entries / %.1f MB). Oldest entries will be evicted as new mutations occur. This warning is emitted once per editor session." % [
			status["entries"], status["bytes"] / (1024.0 * 1024.0)
		])

## Discard a pending entry (tool failed before mutating, or entry was a no-op).
func discard(id: String) -> void:
	_store.discard_entry(id)

## Roll back a still-pending entry: restore every file the entry recorded, then
## discard the entry. Used by batch_execute in atomic mode when a sub-command
## fails after earlier sub-commands have already mutated.
##
## Conceptually this is "undo the partial batch and forget it ever happened" —
## the entry is NOT pushed onto either stack. Returns
## {ok, restored:[paths], errors:[strings]}.
func rollback_pending(id: String) -> Dictionary:
	var manifest := _store.get_entry(id)
	if manifest.is_empty():
		return {"ok": false, "error": "Entry not found: " + id, "restored": [], "errors": []}

	var files: Array = manifest.get("files", [])
	var restored: Array = []
	var errors: Array = []

	# Reverse order so create/delete operations unwind inverse to recording.
	for i in range(files.size() - 1, -1, -1):
		var rec: Dictionary = files[i]
		var path: String = rec.get("path", "")
		var kind: String = rec.get("kind", "")
		match kind:
			MCPSnapshotStore.KIND_SNAPSHOT:
				var ok := _restore_file(rec.get("backup", ""), path)
				if ok:
					restored.append(path)
				else:
					errors.append("Failed to restore %s" % path)
			MCPSnapshotStore.KIND_CREATED:
				# File (or directory) was created by the partial batch. Delete
				# it if present. Missing path is fine — nothing to undo.
				var abs := ProjectSettings.globalize_path(path)
				# is_dir flag is stamped at record time; we also detect via
				# DirAccess so pre-flag manifests still do the right thing.
				var is_dir: bool = bool(rec.get("is_dir", false)) \
						or (DirAccess.dir_exists_absolute(abs) and not FileAccess.file_exists(abs))
				if is_dir:
					if DirAccess.dir_exists_absolute(abs):
						var derr := DirAccess.remove_absolute(abs)
						if derr != OK:
							errors.append("Failed to remove created directory %s: %s" % [path, error_string(derr)])
						else:
							restored.append(path)
				elif FileAccess.file_exists(abs):
					var del_err := DirAccess.remove_absolute(abs)
					if del_err != OK:
						errors.append("Failed to delete %s: %s" % [path, error_string(del_err)])
					else:
						restored.append(path)
			MCPSnapshotStore.KIND_DELETED:
				var ok2 := _restore_file(rec.get("backup", ""), path)
				if ok2:
					restored.append(path)
				else:
					errors.append("Failed to restore deleted %s" % path)
			_:
				errors.append("Unknown file record kind: %s" % kind)

	_post_restore_editor_refresh(restored)
	_store.discard_entry(id)

	return {
		"ok": errors.is_empty(),
		"restored": restored,
		"errors": errors,
	}

# =============================================================================
# Undo / Redo
# =============================================================================

## Undo the top-of-stack entry. Returns a result dict for the AI.
func undo_one() -> Dictionary:
	var manifest := _store.pop_undo()
	if manifest.is_empty():
		return {"ok": false, "error": "Undo stack is empty"}

	var id: String = str(manifest.get("id", ""))
	var files: Array = manifest.get("files", [])
	# Capture post-mutation content for each file so redo can re-apply it.
	# We read the CURRENT (post-mutation) content of each file, then perform
	# the restore. The redo entry has its kinds inverted: snapshot→snapshot,
	# created→deleted, deleted→created.
	var redo_files: Array = []
	var restored: Array = []
	var errors: Array = []

	# Process in REVERSE so create/delete operations unwind in the order
	# inverse to how they were recorded (matches expected file-system semantics
	# when an entry mixes operations).
	for i in range(files.size() - 1, -1, -1):
		var rec: Dictionary = files[i]
		var path: String = rec.get("path", "")
		var kind: String = rec.get("kind", "")
		var redo_rec := {"path": path}

		match kind:
			MCPSnapshotStore.KIND_SNAPSHOT:
				# File existed before mutation. Capture current content as the
				# redo backup (under the same entry id, in a "redo_files/"
				# subfolder), then restore the original.
				if FileAccess.file_exists(path):
					var redo_backup_rel := path.replace("res://", "")
					var redo_backup_abs := ProjectSettings.globalize_path(
						"res://addons/godot_mcp/cache/undo/entry_" + id + "/redo_files/" + redo_backup_rel)
					var redo_dir := redo_backup_abs.get_base_dir()
					if not DirAccess.dir_exists_absolute(redo_dir):
						DirAccess.make_dir_recursive_absolute(redo_dir)
					DirAccess.copy_absolute(ProjectSettings.globalize_path(path), redo_backup_abs)
					redo_rec["kind"] = MCPSnapshotStore.KIND_SNAPSHOT
					redo_rec["backup"] = "res://addons/godot_mcp/cache/undo/entry_" + id + "/redo_files/" + redo_backup_rel
				else:
					# File was deleted between mutation and undo (external?).
					# Treat the redo as "create from this same backup".
					redo_rec["kind"] = MCPSnapshotStore.KIND_CREATED

				var ok := _restore_file(rec.get("backup", ""), path)
				if not ok:
					errors.append("Failed to restore %s" % path)
				else:
					restored.append(path)

			MCPSnapshotStore.KIND_CREATED:
				# File or directory was created by the tool. Undo removes it;
				# redo recreates it. Directories have no content to back up —
				# the redo record just carries is_dir=true and make_dir on redo.
				var abs := ProjectSettings.globalize_path(path)
				var is_dir: bool = bool(rec.get("is_dir", false)) \
						or (DirAccess.dir_exists_absolute(abs) and not FileAccess.file_exists(abs))
				if is_dir:
					redo_rec["kind"] = MCPSnapshotStore.KIND_CREATED
					redo_rec["is_dir"] = true
					if DirAccess.dir_exists_absolute(abs):
						var derr := DirAccess.remove_absolute(abs)
						if derr != OK:
							# Most likely cause: user dropped a file into the
							# folder after creation. Don't silently swallow.
							errors.append("Failed to remove created directory %s on undo: %s (the directory may now contain user content)" % [path, error_string(derr)])
						else:
							restored.append(path)
				elif FileAccess.file_exists(path):
					var redo_backup_rel := path.replace("res://", "")
					var redo_backup_res := "res://addons/godot_mcp/cache/undo/entry_" + id + "/redo_files/" + redo_backup_rel
					var redo_backup_abs := ProjectSettings.globalize_path(redo_backup_res)
					var redo_dir := redo_backup_abs.get_base_dir()
					if not DirAccess.dir_exists_absolute(redo_dir):
						DirAccess.make_dir_recursive_absolute(redo_dir)
					DirAccess.copy_absolute(ProjectSettings.globalize_path(path), redo_backup_abs)
					redo_rec["kind"] = MCPSnapshotStore.KIND_CREATED
					redo_rec["backup"] = redo_backup_res
					var del_err := DirAccess.remove_absolute(ProjectSettings.globalize_path(path))
					if del_err != OK:
						errors.append("Failed to delete %s on undo: %s" % [path, error_string(del_err)])
					else:
						restored.append(path)
				else:
					# Already gone — nothing to undo for this file. Redo would
					# need a backup we don't have; mark as CREATED with no
					# backup so redo will report a missing-backup error rather
					# than silently no-op.
					redo_rec["kind"] = MCPSnapshotStore.KIND_CREATED

			MCPSnapshotStore.KIND_DELETED:
				# File was deleted by the tool. Undo restores from backup. For
				# redo, capture nothing (file content is the backup we already
				# have); redo just deletes again.
				var ok2 := _restore_file(rec.get("backup", ""), path)
				if not ok2:
					errors.append("Failed to restore deleted %s" % path)
				else:
					restored.append(path)
				redo_rec["kind"] = MCPSnapshotStore.KIND_DELETED
				redo_rec["backup"] = rec.get("backup", "")
			_:
				errors.append("Unknown file record kind: %s" % kind)

		redo_files.push_front(redo_rec)  # preserve original ordering for redo

	# Update the manifest with the redo-side file records so a subsequent redo
	# will use the post-mutation content.
	manifest["files"] = redo_files
	_store.update_entry(id, manifest)

	# Refresh editor state so reloads pick up the file changes.
	_post_restore_editor_refresh(restored)

	var result := {
		"ok": errors.is_empty(),
		"undid": {
			"tool": manifest.get("tool", ""),
			"summary": manifest.get("args_summary", ""),
			"files": restored,
		},
	}
	if not errors.is_empty():
		result["error"] = "; ".join(errors)
	return result

## Redo the top-of-redo-stack entry — re-apply the most recently undone change.
func redo_one() -> Dictionary:
	var manifest := _store.pop_redo()
	if manifest.is_empty():
		return {"ok": false, "error": "Redo stack is empty"}

	var id: String = str(manifest.get("id", ""))
	var files: Array = manifest.get("files", [])
	var new_undo_files: Array = []
	var restored: Array = []
	var errors: Array = []

	for rec: Dictionary in files:
		var path: String = rec.get("path", "")
		var kind: String = rec.get("kind", "")
		var undo_rec := {"path": path}

		match kind:
			MCPSnapshotStore.KIND_SNAPSHOT:
				# Capture current (pre-redo) content for next-undo, then apply
				# the redo content.
				if FileAccess.file_exists(path):
					var undo_backup_rel := path.replace("res://", "")
					var undo_backup_abs := ProjectSettings.globalize_path(
						"res://addons/godot_mcp/cache/undo/entry_" + id + "/files/" + undo_backup_rel)
					var undo_dir := undo_backup_abs.get_base_dir()
					if not DirAccess.dir_exists_absolute(undo_dir):
						DirAccess.make_dir_recursive_absolute(undo_dir)
					DirAccess.copy_absolute(ProjectSettings.globalize_path(path), undo_backup_abs)
					undo_rec["kind"] = MCPSnapshotStore.KIND_SNAPSHOT
					undo_rec["backup"] = "res://addons/godot_mcp/cache/undo/entry_" + id + "/files/" + undo_backup_rel
				else:
					undo_rec["kind"] = MCPSnapshotStore.KIND_CREATED

				var ok := _restore_file(rec.get("backup", ""), path)
				if not ok:
					errors.append("Failed to redo %s" % path)
				else:
					restored.append(path)

			MCPSnapshotStore.KIND_CREATED:
				# Redo re-creates whatever the original tool created. For files,
				# restore from the redo backup the previous undo captured. For
				# directories, just recreate the empty folder — there is no
				# content to restore.
				if bool(rec.get("is_dir", false)):
					var abs := ProjectSettings.globalize_path(path)
					var merr := DirAccess.make_dir_recursive_absolute(abs)
					if merr != OK:
						errors.append("Failed to recreate directory %s on redo: %s" % [path, error_string(merr)])
					else:
						restored.append(path)
					undo_rec["kind"] = MCPSnapshotStore.KIND_CREATED
					undo_rec["is_dir"] = true
				else:
					var ok2 := _restore_file(rec.get("backup", ""), path)
					if not ok2:
						errors.append("Failed to recreate %s on redo" % path)
					else:
						restored.append(path)
					undo_rec["kind"] = MCPSnapshotStore.KIND_CREATED

			MCPSnapshotStore.KIND_DELETED:
				# Re-delete the file. Capture the just-restored content as the
				# undo backup so a subsequent undo can restore again.
				if FileAccess.file_exists(path):
					var backup_rel := path.replace("res://", "")
					var backup_abs := ProjectSettings.globalize_path(
						"res://addons/godot_mcp/cache/undo/entry_" + id + "/files/" + backup_rel)
					var backup_dir := backup_abs.get_base_dir()
					if not DirAccess.dir_exists_absolute(backup_dir):
						DirAccess.make_dir_recursive_absolute(backup_dir)
					DirAccess.copy_absolute(ProjectSettings.globalize_path(path), backup_abs)
					undo_rec["kind"] = MCPSnapshotStore.KIND_DELETED
					undo_rec["backup"] = "res://addons/godot_mcp/cache/undo/entry_" + id + "/files/" + backup_rel
					var del_err := DirAccess.remove_absolute(ProjectSettings.globalize_path(path))
					if del_err != OK:
						errors.append("Failed to re-delete %s: %s" % [path, error_string(del_err)])
					else:
						restored.append(path)
				else:
					# Already gone; nothing to do.
					undo_rec["kind"] = MCPSnapshotStore.KIND_DELETED
					undo_rec["backup"] = rec.get("backup", "")
			_:
				errors.append("Unknown file record kind: %s" % kind)

		new_undo_files.append(undo_rec)

	manifest["files"] = new_undo_files
	_store.update_entry(id, manifest)
	_post_restore_editor_refresh(restored)

	var result := {
		"ok": errors.is_empty(),
		"redid": {
			"tool": manifest.get("tool", ""),
			"summary": manifest.get("args_summary", ""),
			"files": restored,
		},
	}
	if not errors.is_empty():
		result["error"] = "; ".join(errors)
	return result

# =============================================================================
# History listing
# =============================================================================

func list_history(limit: int = 20) -> Dictionary:
	return {
		"undo": _store.list_undo(limit),
		"redo": _store.list_redo(limit),
		"cap": _store.cap_status(),
	}

# =============================================================================
# Internals
# =============================================================================

## Copy backup → res_path. Creates parent directories as needed.
func _restore_file(backup_res_path: String, target_res_path: String) -> bool:
	if backup_res_path.is_empty():
		return false
	var backup_abs := ProjectSettings.globalize_path(backup_res_path)
	if not FileAccess.file_exists(backup_abs):
		push_error("[MCP undo] Backup missing: %s" % backup_res_path)
		return false
	var target_abs := ProjectSettings.globalize_path(target_res_path)
	var target_dir := target_abs.get_base_dir()
	if not DirAccess.dir_exists_absolute(target_dir):
		DirAccess.make_dir_recursive_absolute(target_dir)
	# Use binary copy so .tscn / .gd / binary resources all work.
	var err := DirAccess.copy_absolute(backup_abs, target_abs)
	if err != OK:
		push_error("[MCP undo] copy_absolute failed (%s) restoring %s" % [error_string(err), target_res_path])
		return false
	return true

## After file restoration, refresh the editor:
##   - rescan filesystem so the dock/cache picks up changes
##   - reload any scene tab whose backing .tscn was restored
##   - reload any open script whose backing .gd was restored
func _post_restore_editor_refresh(paths: Array) -> void:
	if _editor_plugin == null:
		return
	var ei := _editor_plugin.get_editor_interface()
	if ei == null:
		return
	ei.get_resource_filesystem().scan()

	for p_v in paths:
		var p: String = str(p_v)
		if p.ends_with(".tscn") or p.ends_with(".scn"):
			# Reload the scene tab if open.
			if ei.has_method("get_open_scenes"):
				var open_scenes: PackedStringArray = ei.get_open_scenes()
				if open_scenes.has(p):
					ei.reload_scene_from_path(p)
		elif p.ends_with(".gd"):
			# Force the script editor to drop its cached buffer for this file.
			# Godot has no direct "reload script from disk" API; the closest
			# safe operation is to force-reload the resource so subsequent
			# calls see the new content. The script editor will pick up the
			# change on next focus.
			var s := ResourceLoader.load(p, "Script", ResourceLoader.CACHE_MODE_REPLACE)
			if s and s is Script:
				(s as Script).reload()

func reset_cap_warning() -> void:
	_cap_warning_emitted = false
