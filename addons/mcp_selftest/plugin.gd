@tool
extends EditorPlugin
## Editor-context self test for the godot_mcp addon.
##
## The other GDScript checks run with `godot --headless --script`, which is a
## plain MainLoop — not the editor. That misses everything that only exists in
## a real editor: EditorPlugin wiring, EditorInterface / EditorFileSystem
## access, and `@tool` coroutines awaiting `process_frame`. A duplicate
## variable in scene_tools.gd got past the headless suite and only broke here,
## because the plugin failed to compile when the editor loaded it.
##
## Inert unless GODOT_MCP_SELFTEST=1, so enabling it in project.godot does not
## disturb the headless checks.
##
## Run:
##   GODOT_MCP_SELFTEST=1 godot --headless --editor --quit-after 900
## Exits non-zero on failure, so CI can rely on it.

const ToolExecutor = preload("res://addons/godot_mcp/tool_executor.gd")

var _failures := 0
var _checks := 0

func _enter_tree() -> void:
	if OS.get_environment("GODOT_MCP_SELFTEST") != "1":
		return
	_run.call_deferred()

func _check(ok: bool, label: String, detail: String = "") -> void:
	_checks += 1
	if not ok:
		_failures += 1
	print("  %s  %s%s" % ["ok  " if ok else "FAIL", label, ("  <- " + detail) if detail else ""])

func _run() -> void:
	await get_tree().process_frame
	print("--- editor-context self test ---")

	var ex = ToolExecutor.new()
	ex.name = "SelfTestExecutor"
	add_child(ex)
	ex.set_editor_plugin(self)

	# The change most likely to break outside headless: rescan_filesystem is a
	# coroutine that awaits process_frame inside an @tool EditorPlugin, and it
	# was previously the most-called tool in the whole system.
	var r = await ex.execute_tool("rescan_filesystem", {})
	_check(typeof(r) == TYPE_DICTIONARY, "rescan_filesystem returns a Dictionary (not a coroutine state)", str(typeof(r)))
	if typeof(r) == TYPE_DICTIONARY:
		_check(r.get("ok") == true, "rescan_filesystem succeeds", str(r.get("error", "")))
		_check(r.has("synchronized"), "reports synchronized")
		_check(r.get("synchronized") == true, "synchronized is true",
			"waited_ms=%s was_already_scanning=%s" % [r.get("waited_ms"), r.get("was_already_scanning")])

	var r2 = await ex.execute_tool("rescan_filesystem", {})
	_check(typeof(r2) == TYPE_DICTIONARY and r2.get("ok") == true, "second rescan succeeds")
	_check(typeof(r2) == TYPE_DICTIONARY and r2.get("synchronized") == true, "second call also reports synchronized")

	# Ordinary dispatch, to prove the executor still routes after the
	# coroutine special-case was added.
	var settings = await ex.execute_tool("get_project_settings", {"category": "application"})
	_check(typeof(settings) == TYPE_DICTIONARY and settings.get("ok") == true,
		"get_project_settings routes through the executor", str(settings.get("error", "")))

	var missing = await ex.execute_tool("no_such_tool_xyz", {})
	_check(typeof(missing) == TYPE_DICTIONARY and missing.get("ok") == false, "unknown tool is rejected cleanly")

	# Path confinement must hold in the editor context too.
	var escaped = await ex.execute_tool("read_file", {"path": "res://../../etc/passwd"})
	_check(typeof(escaped) == TYPE_DICTIONARY and escaped.get("ok") == false,
		"path confinement applies in the editor", str(escaped.get("ok")))

	# Runtime-only tools must report a clear error rather than half-working
	# when no game is running.
	var probe = await ex.execute_tool("probe_ui", {})
	_check(typeof(probe) == TYPE_DICTIONARY, "runtime tool returns a Dictionary with no game running")

	print("--- %d checks, %d failures ---" % [_checks, _failures])
	get_tree().quit(1 if _failures > 0 else 0)
