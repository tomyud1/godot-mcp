@tool
extends SceneTree
## End-to-end check that the tool layer routes paths through
## MCPPaths.confine(). Testing the helper alone would not catch a call site
## that forgot to use it.
##
## These handlers are pure filesystem logic, so they are called without being
## added to the scene tree (no editor plugin is available headless).

func _init() -> void:
	var file_tools = load("res://addons/godot_mcp/tools/file_tools.gd").new()
	var script_tools = load("res://addons/godot_mcp/tools/script_tools.gd").new()
	var asset_tools = load("res://addons/godot_mcp/tools/asset_tools.gd").new()
	var project_tools = load("res://addons/godot_mcp/tools/project_tools.gd").new()
	var editor_view_tools = load("res://addons/godot_mcp/tools/editor_view_tools.gd").new()

	var failed := 0
	# Sits one level above the project: outside res:// but still writable.
	var canary := ProjectSettings.globalize_path("res://").get_base_dir().path_join("godot-mcp-canary.txt")

	var f := FileAccess.open(canary, FileAccess.WRITE)
	if f == null:
		print("FAIL  could not create canary at %s" % canary)
		quit(1)
		return
	f.store_string("TOP SECRET")
	f.close()

	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path("res://scripts"))
	var g := FileAccess.open("res://scripts/hello.gd", FileAccess.WRITE)
	g.store_string("extends Node\n")
	g.close()

	# --- traversal must be refused --------------------------------------
	var blocked := [
		["read_file", func(): return file_tools.read_file({"path": "res://../godot-mcp-canary.txt"})],
		["list_dir", func(): return file_tools.list_dir({"root": "res://../.."})],
		["create_script", func(): return file_tools.create_script({"path": "res://../escape.gd", "content": "x\n"})],
		["edit_script", func(): return script_tools.edit_script({"edit": {
			"file": "res://../godot-mcp-canary.txt", "type": "snippet_replace",
			"old_snippet": "TOP SECRET", "new_snippet": "PWNED"}})],
		["validate_script", func(): return script_tools.validate_script({"path": "res://../godot-mcp-canary.txt"})],
		["create_folder", func(): return script_tools.create_folder({"path": "res://../evil_dir"})],
		# generate_2d_asset mkdirs and writes a PNG at save_path.
		["generate_2d_asset", func(): return asset_tools.generate_2d_asset({
			"svg_code": "<svg width=\"8\" height=\"8\" xmlns=\"http://www.w3.org/2000/svg\"></svg>",
			"filename": "pwn.png", "save_path": "res://../" })],
		# An autoload path is executed on every game launch.
		["setup_autoload.add", func(): return project_tools._autoload_add({
			"name": "Evil", "path": "res://../godot-mcp-canary.txt", "operation": "add"})],
		["open_in_godot", func(): return project_tools.open_in_godot({"path": "res://../godot-mcp-canary.txt"})],
	]
	for entry in blocked:
		var res = entry[1].call()
		if bool(res.get("ok", false)):
			print("FAIL  %s allowed traversal" % entry[0])
			failed += 1
		else:
			print("ok    %s blocked traversal" % entry[0])

	# --- screenshot output paths ----------------------------------------
	# _ensure_output_path is pure path logic, so it can be called without an
	# editor viewport behind it.
	var abs_res = editor_view_tools._ensure_output_path(ProjectSettings.globalize_path("res://").get_base_dir().path_join("pwn.png"), false)
	if (abs_res[2] as Dictionary).is_empty():
		print("FAIL  screenshot allowed an absolute path without opt-in")
		failed += 1
	else:
		print("ok    screenshot refuses absolute path without opt-in")

	var abs_ok = editor_view_tools._ensure_output_path(ProjectSettings.globalize_path("res://").get_base_dir().path_join("pwn.png"), true)
	if not (abs_ok[2] as Dictionary).is_empty():
		print("FAIL  screenshot rejected an absolute path with opt-in: %s" % abs_ok[2])
		failed += 1
	else:
		print("ok    screenshot honours allow_absolute_output")

	var user_res = editor_view_tools._ensure_output_path("user://mcp_screenshots/ok.png", false)
	if not (user_res[2] as Dictionary).is_empty():
		print("FAIL  screenshot rejected a normal user:// path: %s" % user_res[2])
		failed += 1
	else:
		print("ok    screenshot accepts user:// output")

	var rel_res = editor_view_tools._ensure_output_path("shot.png", false)
	if not (rel_res[2] as Dictionary).is_empty():
		print("FAIL  screenshot rejected a relative path: %s" % rel_res[2])
		failed += 1
	else:
		print("ok    screenshot accepts relative output (maps to user://)")

	var trav_res = editor_view_tools._ensure_output_path("user://../escaped.png", false)
	if (trav_res[2] as Dictionary).is_empty():
		print("FAIL  screenshot allowed a traversing user:// path")
		failed += 1
	else:
		print("ok    screenshot blocks traversal in user:// output")

	# --- legitimate project paths must still work ------------------------
	var read_ok = file_tools.read_file({"path": "res://scripts/hello.gd"})
	if bool(read_ok.get("ok", false)):
		print("ok    read_file reads project files")
	else:
		print("FAIL  read_file broke: %s" % read_ok); failed += 1

	var inside = file_tools.read_file({"path": "res://scripts/../scripts/hello.gd"})
	if bool(inside.get("ok", false)):
		print("ok    read_file allows in-project ../")
	else:
		print("FAIL  read_file rejected safe in-project ../: %s" % inside); failed += 1

	var listed = file_tools.list_dir({"root": "res://scripts"})
	if bool(listed.get("ok", false)):
		print("ok    list_dir lists project dirs")
	else:
		print("FAIL  list_dir broke: %s" % listed); failed += 1

	# --- the file outside the project must be untouched ------------------
	var check := FileAccess.open(canary, FileAccess.READ)
	var content := check.get_as_text()
	check.close()
	if content.strip_edges() != "TOP SECRET":
		print("FAIL  canary modified: %s" % content)
		failed += 1
	else:
		print("ok    canary file untouched")
	DirAccess.remove_absolute(canary)

	print("\n%d failures" % failed)
	quit(1 if failed > 0 else 0)
