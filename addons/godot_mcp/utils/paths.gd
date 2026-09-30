@tool
extends RefCounted
class_name MCPPaths
## Filesystem path helpers used by all MCP tools.
##
## Centralizes:
##   - user:// directory self-healing (handles project rename rebinding)
##   - cache directory under res://addons/godot_mcp/cache/ for MCP-internal state
##   - path confinement for every agent-supplied path
##   - small absolute-path helpers for diagnostics

const CACHE_DIR := "res://addons/godot_mcp/cache/"
const RUNTIME_CACHE_DIR := "res://addons/godot_mcp/cache/runtime/"
const SCREENSHOT_CACHE_DIR := "res://addons/godot_mcp/cache/screenshots/"

## Result of a confinement check. `path` is only meaningful when `ok` is true.
class ConfinementResult extends RefCounted:
	var ok: bool = false
	var path: String = ""
	var error: String = ""

## Reject any path that tries to escape the roots the agent is allowed to
## touch. The agent (and anything that manages to steer it) must not be able
## to read or write outside the project or the engine's user:// folder.
##
## This is lexical confinement: it defeats `..` traversal and absolute paths
## that point elsewhere. It does NOT resolve symlinks, so a symlink the user
## deliberately placed inside the project can still point outside — that is
## an accepted limitation, since planting one requires local write access
## already.
static func confine(raw_path: String, allow_user_dir: bool = true) -> ConfinementResult:
	var result := ConfinementResult.new()

	if raw_path.strip_edges().is_empty():
		result.error = "Empty path"
		return result

	# Null bytes can truncate a path after validation has already passed.
	if raw_path.contains(String.chr(0)):
		result.error = "Path contains a null byte"
		return result

	var candidate := raw_path.strip_edges()

	# Normalize the separators Godot accepts on Windows-authored input.
	candidate = candidate.replace("\\", "/")

	# Collapse `.` and `..` segments before checking the prefix, so that
	# "res://scenes/../../etc/passwd" cannot sneak past a naive starts_with.
	var normalized := _normalize_segments(candidate)
	if normalized.is_empty():
		result.error = "Path resolves to an empty location"
		return result

	# A ".." segment that survived normalization means the path climbs above
	# its own root. `globalize_path` does NOT resolve "..", so this has to be
	# rejected here or "res://.." would look like a child of the project.
	for segment in normalized.split("/", false):
		if segment == "..":
			result.error = "Path escapes the allowed roots via '..': %s" % raw_path
			return result

	var allowed_roots: Array[String] = ["res://"]
	if allow_user_dir:
		allowed_roots.append("user://")

	for root in allowed_roots:
		var root_abs := ProjectSettings.globalize_path(root)
		if root_abs.is_empty():
			continue
		var target_abs := ProjectSettings.globalize_path(normalized)
		if target_abs.is_empty():
			continue
		if _is_within(target_abs, root_abs):
			result.ok = true
			result.path = normalized
			return result

	result.error = (
		"Path is outside the allowed roots (res://%s): %s"
		% [" and user://" if allow_user_dir else "", raw_path]
	)
	return result

## Collapse "." and ".." without touching the filesystem.
## A leading ".." is preserved so the caller can detect an escape.
static func _normalize_segments(path: String) -> String:
	var rest := path

	# Strip a Windows drive prefix (C:/...) so the segment logic below is
	# platform-neutral.
	if rest.length() >= 2 and rest[1] == ":":
		rest = rest.substr(2)

	# Match the scheme explicitly. Deriving it by searching for the first "/"
	# is off by one: in "res://x" the first slash is at index 4, which would
	# yield the broken prefix "res:/".
	var prefix := "res://"
	if rest.begins_with("res://"):
		prefix = "res://"
		rest = rest.substr(6)
	elif rest.begins_with("user://"):
		prefix = "user://"
		rest = rest.substr(7)
	elif rest.begins_with("/"):
		prefix = "/"
		rest = rest.trim_prefix("/")

	var out: Array[String] = []
	for segment in rest.split("/", false):
		if segment == "." or segment.is_empty():
			continue
		if segment == "..":
			if out.size() > 0 and out[out.size() - 1] != "..":
				out.remove_at(out.size() - 1)
			else:
				out.append("..")
			continue
		out.append(segment)

	return prefix + "/".join(out)

## True when `target` is `root` itself or sits beneath it. Compares on
## separator boundaries so "/project-evil" is not treated as inside "/project".
static func _is_within(target: String, root: String) -> bool:
	var normalized_root := root.trim_suffix("/")
	if normalized_root.is_empty():
		normalized_root = "/"
	if target == normalized_root:
		return true
	return target.begins_with(normalized_root + "/")

## Gate helper shaped for direct use in a tool's return type: returns an
## empty Dictionary when the path is acceptable, or a ready-to-return error
## dict when it is not. This is the form every tool uses.
##
##     var _gate := MCPPaths.check(scene_path)
##     if not _gate.is_empty():
##         return _gate
static func check(path: String, allow_user_dir: bool = false) -> Dictionary:
	var result := confine(path, allow_user_dir)
	if result.ok:
		return {}
	return {
		&"ok": false,
		&"error": result.error,
		&"path": path,
		&"hint": "Paths must stay inside the project (res://).",
	}

## Ensure user:// exists on disk. Godot rebinds user:// when
## application/config/name changes, but does not always create the new folder.
## Some FileAccess.open(WRITE) calls then silently fail. Call this before any
## write into user://.
static func ensure_user_dir() -> bool:
	var user_abs := ProjectSettings.globalize_path("user://")
	if user_abs.is_empty():
		return false
	if DirAccess.dir_exists_absolute(user_abs):
		return true
	var err := DirAccess.make_dir_recursive_absolute(user_abs)
	return err == OK or DirAccess.dir_exists_absolute(user_abs)

## Ensure the MCP cache directory exists. Project-relative, so it never
## rebinds on project rename — preferred over user:// for editor-side state.
static func ensure_cache_dir() -> bool:
	return _ensure_dir(CACHE_DIR)

static func ensure_runtime_cache_dir() -> bool:
	return _ensure_dir(RUNTIME_CACHE_DIR)

static func ensure_screenshot_cache_dir() -> bool:
	return _ensure_dir(SCREENSHOT_CACHE_DIR)

static func _ensure_dir(res_path: String) -> bool:
	var abs_path := ProjectSettings.globalize_path(res_path)
	if abs_path.is_empty():
		return false
	if DirAccess.dir_exists_absolute(abs_path):
		return true
	var err := DirAccess.make_dir_recursive_absolute(abs_path)
	return err == OK or DirAccess.dir_exists_absolute(abs_path)

## Render an absolute filesystem path for a res:// or user:// path,
## suitable for inclusion in error messages.
static func absolute_for(path: String) -> String:
	return ProjectSettings.globalize_path(path)

## Diagnose why a FileAccess.open(WRITE) just failed. Returns a structured
## detail string for an error message.
static func describe_open_error(target_path: String) -> String:
	var code := FileAccess.get_open_error()
	var abs_path := ProjectSettings.globalize_path(target_path)
	var parent_dir := abs_path.get_base_dir()
	var parent_exists := DirAccess.dir_exists_absolute(parent_dir)
	return "FileAccess error %d (%s) writing %s — parent dir %s %s" % [
		code,
		error_string(code) if code != OK else "no error code",
		abs_path,
		parent_dir,
		"exists" if parent_exists else "MISSING (run-time tool may need user:// to be initialized)"
	]
