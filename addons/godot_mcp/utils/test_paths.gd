@tool
extends SceneTree
## Headless checks for MCPPaths.confine().
## Run: godot --headless --script addons/godot_mcp/utils/test_paths.gd

const MCPPaths = preload("res://addons/godot_mcp/utils/paths.gd")

var _failures := 0
var _checks := 0

func check(label: String, actual: Variant, expected: Variant) -> void:
	_checks += 1
	if actual != expected:
		_failures += 1
		print("FAIL  %s\n        expected: %s\n        actual:   %s" % [label, expected, actual])

func _init() -> void:
	# --- Paths that must be accepted -------------------------------------
	var allowed := [
		"res://main.gd",
		"res://scenes/level_1.tscn",
		"res://scenes/nested/deep/thing.gd",
		"res://",
		"res://./scenes/level_1.tscn",
		"res://scenes/../main.gd",
		"res://addons/godot_mcp/cache/runtime/x.log",
	]
	for p in allowed:
		check("allow %s" % p, MCPPaths.confine(p, false).ok, true)

	check("allow user:// when permitted", MCPPaths.confine("user://save.dat", true).ok, true)

	# --- Paths that must be rejected -------------------------------------
	var denied := [
		"res://../../.ssh/id_rsa",
		"res://../../../etc/passwd",
		"res://scenes/../../../../etc/hosts",
		"res://addons/../../outside.gd",
		"..",
		"../escape.gd",
	]
	for p in denied:
		check("deny %s" % p, MCPPaths.confine(p, false).ok, false)

	# user:// is off the table when the caller disallows it
	check("deny user:// when disallowed", MCPPaths.confine("user://save.dat", false).ok, false)
	check("deny bare traversal into user", MCPPaths.confine("res://../..", false).ok, false)

	# Absolute paths outside the project must be rejected outright.
	check("deny absolute outside project", MCPPaths.confine("/etc/passwd", false).ok, false)

	# A bare relative path is project-relative by the codebase's existing
	# convention, so "~" is just a directory name inside the project. What
	# matters is that it can never reach the real home directory.
	var tilde = MCPPaths.confine("~/.ssh/id_rsa", false)
	check("bare relative stays inside project", tilde.path.begins_with("res://"), true)

	# Empty and null-byte inputs
	check("deny empty", MCPPaths.confine("", false).ok, false)
	check("deny whitespace", MCPPaths.confine("   ", false).ok, false)
	check("deny null byte", MCPPaths.confine("res://main.gd" + String.chr(0) + ".png", false).ok, false)

	# --- Normalization must not change the destination -------------------
	check(
		"collapses ./ ",
		MCPPaths.confine("res://./scenes/../scenes/a.tscn", false).path,
		"res://scenes/a.tscn"
	)
	check(
		"normalizes backslashes",
		MCPPaths.confine("res://scenes\\a.tscn", false).ok,
		true
	)

	# --- Sibling-directory prefix confusion ------------------------------
	# A root check must respect separator boundaries, so that a directory
	# named like the project plus a suffix is not considered "inside" it.
	var project_root := ProjectSettings.globalize_path("res://").trim_suffix("/")
	check(
		"prefix check respects separators",
		MCPPaths.confine("res://../" + project_root.get_file() + "-evil/secret.gd", false).ok,
		false
	)

	print("\n%d checks, %d failures" % [_checks, _failures])
	quit(1 if _failures > 0 else 0)
