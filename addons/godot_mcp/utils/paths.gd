@tool
extends RefCounted
class_name MCPPaths
## Filesystem path helpers used by all MCP tools.
##
## Centralizes:
##   - user:// directory self-healing (handles project rename rebinding)
##   - cache directory under res://addons/godot_mcp/cache/ for MCP-internal state
##   - small absolute-path helpers for diagnostics

const CACHE_DIR := "res://addons/godot_mcp/cache/"
const RUNTIME_CACHE_DIR := "res://addons/godot_mcp/cache/runtime/"
const SCREENSHOT_CACHE_DIR := "res://addons/godot_mcp/cache/screenshots/"

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
