@tool
extends SceneTree
## Parse-checks every addon script.
##
## WHY THIS EXISTS, AND WHY IT IS NOT JUST `if load(path) == null`
##
## `load()` returns a non-null GDScript object even when the script failed to
## parse, so a check written that way reports "0 parse failures" on a file that
## does not compile. That is not theoretical: a duplicate `var _gate` in
## scene_tools.gd shipped past such a check and only surfaced when the addon
## was loaded inside a real editor.
##
## `reload()` is the reliable signal — it returns ERR_PARSE_ERROR (43) — with
## `can_instantiate()` as a corroborating check.
##
## Run: godot --headless --script addons/godot_mcp/utils/test_parse.gd

const SCRIPTS := [
	"res://addons/godot_mcp/utils/paths.gd",
	"res://addons/godot_mcp/utils/scene_tool_context.gd",
	"res://addons/godot_mcp/utils/variant_codec.gd",
	"res://addons/godot_mcp/tool_executor.gd",
	"res://addons/godot_mcp/runtime/mcp_runtime.gd",
	"res://addons/godot_mcp/tools/file_tools.gd",
	"res://addons/godot_mcp/tools/script_tools.gd",
	"res://addons/godot_mcp/tools/visualizer_tools.gd",
	"res://addons/godot_mcp/tools/scene_tools.gd",
	"res://addons/godot_mcp/tools/editor_scene_tools.gd",
	"res://addons/godot_mcp/tools/editor_view_tools.gd",
	"res://addons/godot_mcp/tools/layout_tools.gd",
	"res://addons/godot_mcp/tools/lighting_tools.gd",
	"res://addons/godot_mcp/tools/navigation_tools.gd",
	"res://addons/godot_mcp/tools/project_tools.gd",
	"res://addons/godot_mcp/tools/asset_tools.gd",
	"res://addons/godot_mcp/tools/signal_tools.gd",
]

func _init() -> void:
	var failed := 0

	for path in SCRIPTS:
		var script = load(path)
		if script == null:
			print("  FAIL  %s — could not be loaded at all" % path)
			failed += 1
			continue

		if not (script is GDScript):
			print("  FAIL  %s — not a GDScript" % path)
			failed += 1
			continue

		# The check that actually works. `reload()` re-parses from source and
		# surfaces ERR_PARSE_ERROR, which `load()` does not.
		var err: int = script.reload()
		if err != OK:
			print("  FAIL  %s — parse error %d (%s)" % [path, err, error_string(err)])
			failed += 1
		elif not script.can_instantiate():
			print("  FAIL  %s — parsed but cannot instantiate" % path)
			failed += 1
		else:
			print("  ok    %s" % path)

	print("\n%d scripts, %d parse failures" % [SCRIPTS.size(), failed])
	quit(1 if failed > 0 else 0)
