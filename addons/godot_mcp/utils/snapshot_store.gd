@tool
extends RefCounted
class_name MCPSnapshotStore
## Disk-backed ring buffer of file snapshots for the MCP undo system.
##
## Layout under res://addons/godot_mcp/cache/undo/:
##   stack.json                 — ordered lists: undo (oldest→newest), redo (oldest→newest)
##   entry_<id>/manifest.json   — per-entry metadata (tool, args, files)
##   entry_<id>/files/...       — backup copies, mirroring res:// path
##
## Caps: MAX_ENTRIES (count) and MAX_TOTAL_BYTES (size). Eviction drops the
## oldest entry on the undo stack first; redo entries are kept (they were
## already paid for) until they themselves age out.
##
## "id" is a monotonically increasing integer string ("000001", ...). Stable
## across plugin reloads. Persisted in stack.json as "next_id".

const UNDO_DIR := "res://addons/godot_mcp/cache/undo/"
const STACK_FILE := "res://addons/godot_mcp/cache/undo/stack.json"
const MAX_ENTRIES := 200
const MAX_TOTAL_BYTES := 100 * 1024 * 1024  # 100 MB

const KIND_SNAPSHOT := "snapshot"   # backup of file content (for modify/restore)
const KIND_CREATED := "created"     # path was created by the tool (undo deletes)
const KIND_DELETED := "deleted"     # path was deleted by the tool (undo restores from backup)

var _next_id: int = 1
var _undo_ids: Array[String] = []   # oldest → newest
var _redo_ids: Array[String] = []   # oldest → newest (top-of-redo is the last)
var _loaded := false

func _ensure_loaded() -> void:
	if _loaded:
		return
	_loaded = true
	_ensure_dirs()
	_load_index()

func _ensure_dirs() -> void:
	var abs := ProjectSettings.globalize_path(UNDO_DIR)
	if not DirAccess.dir_exists_absolute(abs):
		DirAccess.make_dir_recursive_absolute(abs)

func _load_index() -> void:
	if not FileAccess.file_exists(STACK_FILE):
		return
	var f := FileAccess.open(STACK_FILE, FileAccess.READ)
	if not f:
		return
	var text := f.get_as_text()
	f.close()
	var parsed = JSON.parse_string(text)
	if typeof(parsed) != TYPE_DICTIONARY:
		return
	_next_id = int(parsed.get("next_id", 1))
	_undo_ids = _to_str_array(parsed.get("undo", []))
	_redo_ids = _to_str_array(parsed.get("redo", []))

	# Sanity: drop any ids whose entry directory is gone.
	_undo_ids = _filter_existing(_undo_ids)
	_redo_ids = _filter_existing(_redo_ids)

func _to_str_array(v: Variant) -> Array[String]:
	var out: Array[String] = []
	if v is Array:
		for x in v:
			out.append(str(x))
	return out

func _filter_existing(ids: Array[String]) -> Array[String]:
	var out: Array[String] = []
	for id in ids:
		if DirAccess.dir_exists_absolute(ProjectSettings.globalize_path(_entry_dir(id))):
			out.append(id)
	return out

func _save_index() -> void:
	_ensure_dirs()
	var payload := {
		"next_id": _next_id,
		"undo": _undo_ids,
		"redo": _redo_ids,
	}
	var f := FileAccess.open(STACK_FILE, FileAccess.WRITE)
	if not f:
		push_error("[MCP undo] Failed to write stack index: %s" % MCPPaths.describe_open_error(STACK_FILE))
		return
	f.store_string(JSON.stringify(payload, "  "))
	f.close()

func _entry_dir(id: String) -> String:
	return UNDO_DIR + "entry_" + id + "/"

func _manifest_path(id: String) -> String:
	return _entry_dir(id) + "manifest.json"

func _files_dir(id: String) -> String:
	return _entry_dir(id) + "files/"

# =============================================================================
# Entry construction
# =============================================================================

## Begin a new entry. Returns an id string. The entry is "pending" — not yet
## on the stack — until commit_entry() is called. Use discard_entry() to drop.
func begin_entry(tool_name: String, args: Dictionary) -> String:
	_ensure_loaded()
	var id := "%06d" % _next_id
	_next_id += 1
	# We persist next_id immediately so two pending entries can't collide if
	# something crashes between begin and commit.
	_save_index()

	var dir_abs := ProjectSettings.globalize_path(_entry_dir(id))
	DirAccess.make_dir_recursive_absolute(dir_abs)
	DirAccess.make_dir_recursive_absolute(dir_abs + "files/")

	var manifest := {
		"id": id,
		"tool": tool_name,
		"args_summary": _summarize_args(tool_name, args),
		"timestamp": int(Time.get_unix_time_from_system()),
		"files": [],   # appended by record_*
	}
	_write_manifest(id, manifest)
	return id

## Snapshot a file (copy current content into entry/files/) and record it.
## Safe to call for files that don't exist yet — recorded as KIND_CREATED so
## undo deletes them.
func record_snapshot(id: String, res_path: String) -> bool:
	_ensure_loaded()
	var manifest := _read_manifest(id)
	if manifest.is_empty():
		return false

	# Skip duplicates within the same entry.
	for entry in manifest.get("files", []):
		if entry.get("path") == res_path:
			return true

	var rec: Dictionary
	if FileAccess.file_exists(res_path):
		var backup_rel := res_path.replace("res://", "")
		var backup_abs := ProjectSettings.globalize_path(_files_dir(id) + backup_rel)
		var backup_dir := backup_abs.get_base_dir()
		if not DirAccess.dir_exists_absolute(backup_dir):
			DirAccess.make_dir_recursive_absolute(backup_dir)
		var copy_err := DirAccess.copy_absolute(ProjectSettings.globalize_path(res_path), backup_abs)
		if copy_err != OK:
			push_error("[MCP undo] Failed to snapshot %s: %s" % [res_path, error_string(copy_err)])
			return false
		rec = {"path": res_path, "kind": KIND_SNAPSHOT, "backup": _files_dir(id) + backup_rel}
	else:
		# File doesn't exist yet — caller is about to create it. Mark as
		# "created" so undo will delete it.
		rec = {"path": res_path, "kind": KIND_CREATED}

	manifest["files"].append(rec)
	_write_manifest(id, manifest)
	return true

## Record that the tool deleted a file. We snapshot the current content first
## so undo can restore it.
func record_deletion(id: String, res_path: String) -> bool:
	_ensure_loaded()
	if not FileAccess.file_exists(res_path):
		return false
	var manifest := _read_manifest(id)
	if manifest.is_empty():
		return false

	var backup_rel := res_path.replace("res://", "")
	var backup_abs := ProjectSettings.globalize_path(_files_dir(id) + backup_rel)
	var backup_dir := backup_abs.get_base_dir()
	if not DirAccess.dir_exists_absolute(backup_dir):
		DirAccess.make_dir_recursive_absolute(backup_dir)
	var copy_err := DirAccess.copy_absolute(ProjectSettings.globalize_path(res_path), backup_abs)
	if copy_err != OK:
		push_error("[MCP undo] Failed to back up deletion %s: %s" % [res_path, error_string(copy_err)])
		return false

	manifest["files"].append({
		"path": res_path,
		"kind": KIND_DELETED,
		"backup": _files_dir(id) + backup_rel,
	})
	_write_manifest(id, manifest)
	return true

## Mark a file as moved/renamed. Records both the old (deleted) and the new
## (created) sides so undo can revert.
func record_rename(id: String, old_path: String, new_path: String) -> bool:
	_ensure_loaded()
	# Snapshot the old path's content (it'll be gone after the rename).
	var ok1 := record_deletion(id, old_path)
	# Mark the new path as created (so undo deletes it).
	var manifest := _read_manifest(id)
	if manifest.is_empty():
		return false
	manifest["files"].append({"path": new_path, "kind": KIND_CREATED})
	_write_manifest(id, manifest)
	return ok1

## Commit a pending entry. Pushes onto the undo stack, clears the redo stack
## (standard undo semantics), and triggers eviction.
func commit_entry(id: String) -> void:
	_ensure_loaded()
	# A commit is a new mutation: discard any redo history.
	for redo_id in _redo_ids:
		_delete_entry_files(redo_id)
	_redo_ids.clear()

	_undo_ids.append(id)
	_save_index()
	_evict_if_needed()

## Drop a pending entry that was never committed (tool failed before mutating,
## or was a no-op).
func discard_entry(id: String) -> void:
	_ensure_loaded()
	_delete_entry_files(id)

# =============================================================================
# Stack operations
# =============================================================================

func peek_top_undo() -> String:
	_ensure_loaded()
	if _undo_ids.is_empty():
		return ""
	return _undo_ids[-1]

func peek_top_redo() -> String:
	_ensure_loaded()
	if _redo_ids.is_empty():
		return ""
	return _redo_ids[-1]

## Pop the most recent undo entry, move it to the redo stack, and return its
## manifest. Caller is responsible for actually performing the file restoration.
func pop_undo() -> Dictionary:
	_ensure_loaded()
	if _undo_ids.is_empty():
		return {}
	var id: String = _undo_ids.pop_back()
	var manifest := _read_manifest(id)
	# Push to redo stack as-is. The manifest already records what was changed;
	# during undo, the actual file restore happens in UndoManager and it must
	# rewrite the manifest's "files" entries to capture the new (just-restored)
	# state for redo. UndoManager calls update_entry_for_redo() to do that.
	_redo_ids.append(id)
	_save_index()
	return manifest

## Pop the most recent redo entry, move it back to the undo stack, return manifest.
func pop_redo() -> Dictionary:
	_ensure_loaded()
	if _redo_ids.is_empty():
		return {}
	var id: String = _redo_ids.pop_back()
	var manifest := _read_manifest(id)
	_undo_ids.append(id)
	_save_index()
	return manifest

## Replace an entry's manifest (used when undo/redo needs to flip the recorded
## state — e.g. after restoring a snapshotted file, store the post-mutation
## content as the new backup so redo can restore it).
func update_entry(id: String, manifest: Dictionary) -> void:
	_write_manifest(id, manifest)

func get_entry(id: String) -> Dictionary:
	_ensure_loaded()
	return _read_manifest(id)

# =============================================================================
# Listing / introspection
# =============================================================================

func list_undo(limit: int = 20) -> Array:
	_ensure_loaded()
	var out: Array = []
	var count := 0
	for i in range(_undo_ids.size() - 1, -1, -1):
		if count >= limit:
			break
		var id: String = _undo_ids[i]
		var m := _read_manifest(id)
		if m.is_empty():
			continue
		out.append(_summary_for(m, _undo_ids.size() - 1 - i))
		count += 1
	return out

func list_redo(limit: int = 20) -> Array:
	_ensure_loaded()
	var out: Array = []
	var count := 0
	for i in range(_redo_ids.size() - 1, -1, -1):
		if count >= limit:
			break
		var id: String = _redo_ids[i]
		var m := _read_manifest(id)
		if m.is_empty():
			continue
		out.append(_summary_for(m, _redo_ids.size() - 1 - i))
		count += 1
	return out

func _summary_for(manifest: Dictionary, index: int) -> Dictionary:
	var ts := int(manifest.get("timestamp", 0))
	var age := int(Time.get_unix_time_from_system()) - ts
	var files: Array = manifest.get("files", [])
	var paths: Array = []
	for entry in files:
		paths.append(entry.get("path", ""))
	return {
		"index": index,
		"id": manifest.get("id", ""),
		"tool": manifest.get("tool", ""),
		"summary": manifest.get("args_summary", ""),
		"files": paths,
		"file_count": files.size(),
		"age_seconds": age,
	}

# =============================================================================
# Eviction
# =============================================================================

## Returns true if eviction occurred. Single-pass: drop oldest undo entries
## (then oldest redo entries if undo is empty) until both caps are satisfied.
func _evict_if_needed() -> bool:
	var evicted := false
	while _exceeds_caps():
		if not _undo_ids.is_empty():
			var oldest: String = _undo_ids.pop_front()
			_delete_entry_files(oldest)
			evicted = true
		elif not _redo_ids.is_empty():
			var oldest: String = _redo_ids.pop_front()
			_delete_entry_files(oldest)
			evicted = true
		else:
			break
	if evicted:
		_save_index()
	return evicted

func _exceeds_caps() -> bool:
	var total := _undo_ids.size() + _redo_ids.size()
	if total > MAX_ENTRIES:
		return true
	if _measure_total_bytes() > MAX_TOTAL_BYTES:
		return true
	return false

func _measure_total_bytes() -> int:
	var total := 0
	for id in _undo_ids:
		total += _measure_entry_bytes(id)
	for id in _redo_ids:
		total += _measure_entry_bytes(id)
	return total

func _measure_entry_bytes(id: String) -> int:
	var dir_abs := ProjectSettings.globalize_path(_entry_dir(id))
	return _dir_size_recursive(dir_abs)

func _dir_size_recursive(abs_path: String) -> int:
	var total := 0
	var dir := DirAccess.open(abs_path)
	if dir == null:
		return 0
	dir.list_dir_begin()
	var name := dir.get_next()
	while name != "":
		if name.begins_with("."):
			name = dir.get_next()
			continue
		var full := abs_path.path_join(name)
		if dir.current_is_dir():
			total += _dir_size_recursive(full)
		else:
			var f := FileAccess.open(full, FileAccess.READ)
			if f:
				total += f.get_length()
				f.close()
		name = dir.get_next()
	dir.list_dir_end()
	return total

func is_at_cap() -> bool:
	_ensure_loaded()
	return _exceeds_caps() or (_undo_ids.size() + _redo_ids.size()) >= MAX_ENTRIES

func cap_status() -> Dictionary:
	_ensure_loaded()
	return {
		"entries": _undo_ids.size() + _redo_ids.size(),
		"max_entries": MAX_ENTRIES,
		"bytes": _measure_total_bytes(),
		"max_bytes": MAX_TOTAL_BYTES,
	}

# =============================================================================
# Internals
# =============================================================================

func _read_manifest(id: String) -> Dictionary:
	var path := _manifest_path(id)
	if not FileAccess.file_exists(path):
		return {}
	var f := FileAccess.open(path, FileAccess.READ)
	if not f:
		return {}
	var text := f.get_as_text()
	f.close()
	var parsed = JSON.parse_string(text)
	if typeof(parsed) != TYPE_DICTIONARY:
		return {}
	return parsed

func _write_manifest(id: String, manifest: Dictionary) -> void:
	var path := _manifest_path(id)
	var f := FileAccess.open(path, FileAccess.WRITE)
	if not f:
		push_error("[MCP undo] Failed to write manifest: %s" % MCPPaths.describe_open_error(path))
		return
	f.store_string(JSON.stringify(manifest, "  "))
	f.close()

func _delete_entry_files(id: String) -> void:
	var dir_abs := ProjectSettings.globalize_path(_entry_dir(id))
	if not DirAccess.dir_exists_absolute(dir_abs):
		return
	_remove_dir_recursive(dir_abs)

func _remove_dir_recursive(abs_path: String) -> void:
	var dir := DirAccess.open(abs_path)
	if dir == null:
		return
	dir.list_dir_begin()
	var name := dir.get_next()
	while name != "":
		if name.begins_with("."):
			name = dir.get_next()
			continue
		var full := abs_path.path_join(name)
		if dir.current_is_dir():
			_remove_dir_recursive(full)
		else:
			DirAccess.remove_absolute(full)
		name = dir.get_next()
	dir.list_dir_end()
	DirAccess.remove_absolute(abs_path)

## Build a one-line human/AI-readable summary of the args. Keeps it short —
## file paths are truncated to a basename, big values are elided.
func _summarize_args(tool_name: String, args: Dictionary) -> String:
	var parts: Array = []
	# Pick a few common keys in priority order.
	var key_priority := ["scene_path", "node_path", "path", "file", "old_path", "new_path",
		"property_name", "name", "node_name", "node_type", "method", "method_name"]
	for k in key_priority:
		if args.has(k):
			var v: String = str(args[k])
			# Trim very long values.
			if v.length() > 60:
				v = v.substr(0, 57) + "..."
			parts.append("%s=%s" % [k, v])
		if parts.size() >= 3:
			break
	if parts.is_empty():
		return tool_name
	return "%s(%s)" % [tool_name, ", ".join(parts)]

# =============================================================================
# Wipe — for tests/debug
# =============================================================================

func wipe_all() -> void:
	_ensure_loaded()
	for id in _undo_ids:
		_delete_entry_files(id)
	for id in _redo_ids:
		_delete_entry_files(id)
	_undo_ids.clear()
	_redo_ids.clear()
	_save_index()
