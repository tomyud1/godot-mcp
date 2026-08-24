@tool
extends Node
class_name ToolExecutor
## Routes tool invocations to the appropriate handler.

const UndoManagerScript = preload("res://addons/godot_mcp/utils/undo_manager.gd")

var _editor_plugin: EditorPlugin = null
var _mcp_client: Object = null

var _file_tools: Node
var _scene_tools: Node
var _script_tools: Node
var _project_tools: Node
var _asset_tools: Node
var _visualizer_tools: Node

var _undo_manager: MCPUndoManager

# Tool name → [handler_node, method_name]
var _tool_map: Dictionary = {}

var _initialized := false

## Mutating tools and how the dispatcher should snapshot them.
## Each entry is a Dictionary with one or more of:
##   "snapshot_args": [arg_keys]           — pre-snapshot files at these arg paths
##   "delete_args":   [arg_keys]           — pre-back-up + record as DELETED
##   "rename_args":   [old_key, new_key]   — pre-back-up old; post-record new as CREATED
##   "create_result": [result_keys]        — post-record paths from the result dict as CREATED
##                                           (use when the tool may normalize the path
##                                           differently than what came in)
##   "self_snapshots": true                — the tool records its own backups during
##                                           dispatch (used when the set of affected
##                                           files is only known at runtime, e.g.
##                                           delete_folder). The dispatcher still opens
##                                           the entry and commits/discards it, and
##                                           passes the entry id to the tool via
##                                           args["__entry_id"].
##
## Tools NOT in this map are treated as read-only and never snapshotted.
const _MUTATING_TOOLS := {
	# --- file_tools ---
	"create_script": {"create_result": ["path"]},

	# --- scene_tools (scene-mutating) ---
	"create_scene": {"create_result": ["path"]},
	"add_node": {"snapshot_args": ["scene_path"]},
	"remove_node": {"snapshot_args": ["scene_path"]},
	"modify_node_property": {"snapshot_args": ["scene_path"]},
	"rename_node": {"snapshot_args": ["scene_path"]},
	"move_node": {"snapshot_args": ["scene_path"]},
	"attach_script": {"snapshot_args": ["scene_path"]},
	"detach_script": {"snapshot_args": ["scene_path"]},
	"set_collision_shape": {"snapshot_args": ["scene_path"]},
	"set_sprite_texture": {"snapshot_args": ["scene_path"]},
	"instance_scene": {"snapshot_args": ["scene_path"]},
	"set_mesh": {"snapshot_args": ["scene_path"]},
	"set_material": {"snapshot_args": ["scene_path"]},
	"snap_node_to_grid": {"snapshot_args": ["scene_path"]},
	"set_scene_node_property": {"snapshot_args": ["scene_path"]},
	"set_node_properties": {"snapshot_args": ["scene_path"]},
	"set_node_groups": {"snapshot_args": ["scene_path"]},
	"set_resource_property": {"snapshot_args": ["scene_path"]},
	"save_resource_to_file": {"snapshot_args": ["scene_path"], "create_result": ["save_to"]},
	"connect_signal": {"snapshot_args": ["scene_path"]},
	"disconnect_signal": {"snapshot_args": ["scene_path"]},
	# call_method (editor mode only — runtime calls bypass the executor and
	# are routed straight to MCPRuntime by the bridge, so they never reach
	# this map). scene_path may be absent if the caller relies on the
	# active-scene fallback; the snapshot helper silently skips in that case.
	"call_method": {"snapshot_args": ["scene_path"]},

	# --- script_tools / file ops ---
	"edit_script": {"snapshot_args": ["__edit_file"]},  # special: nested under args.edit.file
	"create_folder": {"create_result": ["path"]},
	"delete_file": {"delete_args": ["path"]},
	"delete_folder": {"self_snapshots": true},
	"rename_file": {"rename_args": ["old_path", "new_path"]},
	# write_file: snapshot_args handles both modify (KIND_SNAPSHOT) and create
	# (KIND_CREATED) — record_snapshot picks the right kind based on whether
	# the file existed at pre-call snapshot time.
	"write_file": {"snapshot_args": ["path"]},

	# --- project_tools ---
	"update_project_settings": {"snapshot_args": ["__project_godot"]},
	"configure_input_map": {"snapshot_args": ["__project_godot"]},
	"setup_autoload": {"snapshot_args": ["__project_godot"]},

	# --- asset_tools ---
	"generate_2d_asset": {"create_result": ["path", "output_path"]},
}

const _PROJECT_GODOT_PATH := "res://project.godot"

func _init_tools() -> void:
	"""Initialize all tool handlers. Called from set_editor_plugin."""
	if _initialized:
		return
	_initialized = true
	
	_file_tools = preload("res://addons/godot_mcp/tools/file_tools.gd").new()
	_file_tools.name = "FileTools"
	add_child(_file_tools)

	_scene_tools = preload("res://addons/godot_mcp/tools/scene_tools.gd").new()
	_scene_tools.name = "SceneTools"
	add_child(_scene_tools)

	_script_tools = preload("res://addons/godot_mcp/tools/script_tools.gd").new()
	_script_tools.name = "ScriptTools"
	add_child(_script_tools)

	_project_tools = preload("res://addons/godot_mcp/tools/project_tools.gd").new()
	_project_tools.name = "ProjectTools"
	add_child(_project_tools)

	_asset_tools = preload("res://addons/godot_mcp/tools/asset_tools.gd").new()
	_asset_tools.name = "AssetTools"
	add_child(_asset_tools)

	_visualizer_tools = preload("res://addons/godot_mcp/tools/visualizer_tools.gd").new()
	_visualizer_tools.name = "VisualizerTools"
	add_child(_visualizer_tools)

	# Build tool routing map
	_tool_map = {
		&"list_dir": [_file_tools, &"list_dir"],
		&"read_file": [_file_tools, &"read_file"],
		&"search_project": [_file_tools, &"search_project"],
		&"create_script": [_file_tools, &"create_script"],

		&"create_scene": [_scene_tools, &"create_scene"],
		&"read_scene": [_scene_tools, &"read_scene"],
		&"add_node": [_scene_tools, &"add_node"],
		&"remove_node": [_scene_tools, &"remove_node"],
		&"modify_node_property": [_scene_tools, &"modify_node_property"],
		&"rename_node": [_scene_tools, &"rename_node"],
		&"move_node": [_scene_tools, &"move_node"],
		&"attach_script": [_scene_tools, &"attach_script"],
		&"detach_script": [_scene_tools, &"detach_script"],
		&"set_collision_shape": [_scene_tools, &"set_collision_shape"],
		&"set_sprite_texture": [_scene_tools, &"set_sprite_texture"],
		&"instance_scene": [_scene_tools, &"instance_scene"],
		&"set_mesh": [_scene_tools, &"set_mesh"],
		&"set_material": [_scene_tools, &"set_material"],
		&"get_node_spatial_info": [_scene_tools, &"get_node_spatial_info"],
		&"measure_node_distance": [_scene_tools, &"measure_node_distance"],
		&"snap_node_to_grid": [_scene_tools, &"snap_node_to_grid"],
		&"get_scene_hierarchy": [_scene_tools, &"get_scene_hierarchy"],
		&"get_scene_node_properties": [_scene_tools, &"get_scene_node_properties"],
		&"set_scene_node_property": [_scene_tools, &"set_scene_node_property"],
		&"set_node_properties": [_scene_tools, &"set_node_properties"],
		&"set_node_groups": [_scene_tools, &"set_node_groups"],
		&"get_node_groups": [_scene_tools, &"get_node_groups"],
		&"find_nodes": [_scene_tools, &"find_nodes"],
		&"set_resource_property": [_scene_tools, &"set_resource_property"],
		&"save_resource_to_file": [_scene_tools, &"save_resource_to_file"],
		&"get_resource_info": [_scene_tools, &"get_resource_info"],
		&"list_signal_connections": [_scene_tools, &"list_signal_connections"],
		&"connect_signal": [_scene_tools, &"connect_signal"],
		&"disconnect_signal": [_scene_tools, &"disconnect_signal"],
		&"call_method": [_scene_tools, &"call_method"],

		&"edit_script": [_script_tools, &"edit_script"],
		&"validate_script": [_script_tools, &"validate_script"],
		&"list_scripts": [_script_tools, &"list_scripts"],
		&"create_folder": [_script_tools, &"create_folder"],
		&"delete_file": [_script_tools, &"delete_file"],
		&"delete_folder": [_script_tools, &"delete_folder"],
		&"rename_file": [_script_tools, &"rename_file"],
		&"write_file": [_script_tools, &"write_file"],

		&"get_project_settings": [_project_tools, &"get_project_settings"],
		&"list_settings": [_project_tools, &"list_settings"],
		&"update_project_settings": [_project_tools, &"update_project_settings"],
		&"get_input_map": [_project_tools, &"get_input_map"],
		&"configure_input_map": [_project_tools, &"configure_input_map"],
		&"get_collision_layers": [_project_tools, &"get_collision_layers"],
		&"setup_autoload": [_project_tools, &"setup_autoload"],
		&"get_node_properties": [_project_tools, &"get_node_properties"],
		&"get_console_log": [_project_tools, &"get_console_log"],
		&"get_errors": [_project_tools, &"get_errors"],
		&"clear_console_log": [_project_tools, &"clear_console_log"],
		&"open_in_godot": [_project_tools, &"open_in_godot"],
		&"scene_tree_dump": [_project_tools, &"scene_tree_dump"],
		&"close_editor_tabs": [_project_tools, &"close_editor_tabs"],
		&"get_editor_selection": [_project_tools, &"get_editor_selection"],
		&"set_editor_selection": [_project_tools, &"set_editor_selection"],
		&"classdb_query": [_project_tools, &"classdb_query"],
		&"rescan_filesystem": [_project_tools, &"rescan_filesystem"],
		&"run_scene": [_project_tools, &"run_scene"],
		&"stop_scene": [_project_tools, &"stop_scene"],
		&"is_playing": [_project_tools, &"is_playing"],
		&"get_runtime_status": [_project_tools, &"get_runtime_status"],
		&"wait": [_project_tools, &"wait"],

		&"generate_2d_asset": [_asset_tools, &"generate_2d_asset"],

		&"map_project": [_visualizer_tools, &"map_project"],
		&"map_scenes": [_visualizer_tools, &"map_scenes"],
	}

func set_editor_plugin(plugin: EditorPlugin) -> void:
	_editor_plugin = plugin

	# Initialize tools first (must be done synchronously)
	_init_tools()

	# Pass editor plugin reference to all tool handlers
	if _file_tools: _file_tools.set_editor_plugin(plugin)
	if _scene_tools: _scene_tools.set_editor_plugin(plugin)
	if _script_tools: _script_tools.set_editor_plugin(plugin)
	if _project_tools: _project_tools.set_editor_plugin(plugin)
	if _asset_tools: _asset_tools.set_editor_plugin(plugin)
	if _visualizer_tools:
		_visualizer_tools.set_editor_plugin(plugin)
		# Pass scene_tools reference for visualizer internal scene functions
		_visualizer_tools.set_scene_tools_ref(_scene_tools)

	# Lazily create the undo manager so tests / non-editor contexts that don't
	# call set_editor_plugin don't pay for snapshot infrastructure.
	if _undo_manager == null:
		_undo_manager = UndoManagerScript.new()
	_undo_manager.set_editor_plugin(plugin)

	# Self-snapshotting tools (e.g. delete_folder) record their own backups
	# during dispatch and therefore need a direct handle to the undo manager.
	if _script_tools and _script_tools.has_method("set_undo_manager"):
		_script_tools.set_undo_manager(_undo_manager)

func set_mcp_client(client: Object) -> void:
	_mcp_client = client
	if _project_tools and _project_tools.has_method("set_mcp_client"):
		_project_tools.set_mcp_client(client)

## Tools that are coroutines (contain `await`). They MUST be dispatched via
## a direct method call + await so the return value is preserved. Generic
## `node.call()` / `callv()` do NOT return the right value for coroutines in
## GDScript 4 (see godotengine/godot#50894, #103887). Keep this set small.
const _COROUTINE_TOOLS := {
	"wait": true,
	"run_scene": true,
	"get_errors": true,
}

## Tools that may NOT appear inside a batch_execute sub-command. Either because
## they manipulate the very thing batch_execute uses for atomicity (the undo
## stack), recurse on it, or have process-lifecycle side effects that aren't
## snapshotable / rollback-able.
const _DISALLOWED_IN_BATCH := {
	"batch_execute": true,
	"mcp_undo": true,
	"mcp_redo": true,
	"mcp_undo_history": true,
	"wait": true,
	"run_scene": true,
	"stop_scene": true,
}

func execute_tool(tool_name: String, args: Dictionary) -> Dictionary:
	"""Execute a tool by name with the given arguments.

	This function is a coroutine because at least one tool (`wait`) uses
	`await` to yield to the SceneTree. Callers MUST `await` the result or
	they'll get a GDScriptFunctionState instead of a Dictionary."""

	# Handle internal visualizer commands (not exposed as MCP tools)
	if tool_name.begins_with("visualizer._internal_"):
		var vmethod: String = tool_name.replace("visualizer.", "")
		if _visualizer_tools and _visualizer_tools.has_method(vmethod):
			return _visualizer_tools.call(vmethod, args)
		else:
			return {&"ok": false, &"error": "Internal method not found: " + vmethod}

	# Built-in undo/redo/history tools — handled directly here.
	match tool_name:
		"mcp_undo":
			_parse_stringified_args(args)
			return _builtin_undo(args)
		"mcp_redo":
			_parse_stringified_args(args)
			return _builtin_redo(args)
		"mcp_undo_history":
			_parse_stringified_args(args)
			return _builtin_history(args)
		"batch_execute":
			_parse_stringified_args(args)
			return await _builtin_batch_execute(args)

	if not _tool_map.has(tool_name):
		return {
			&"ok": false,
			&"error": "Unknown tool: %s. Available: %s" % [tool_name, ", ".join(_tool_map.keys())]
		}

	_parse_stringified_args(args)

	# Snapshot lifecycle for mutating tools.
	var entry_id := ""
	var registry: Dictionary = _MUTATING_TOOLS.get(tool_name, {})
	if not registry.is_empty() and _undo_manager != null:
		entry_id = _undo_manager.begin(tool_name, args)
		_pre_tool_snapshots(entry_id, tool_name, args, registry)
		# Self-snapshotting tools record their own backups during dispatch and
		# need the entry id handed to them. Injected AFTER begin() so it never
		# pollutes the manifest's args summary.
		if registry.get("self_snapshots", false):
			args["__entry_id"] = entry_id

	var result: Dictionary = await _dispatch_only(tool_name, args)

	# Finalize snapshot lifecycle.
	if entry_id != "":
		var ok: bool = bool(result.get(&"ok", false))
		if ok:
			_post_tool_snapshots(entry_id, tool_name, args, result, registry)
			# A self-snapshotting tool can legitimately record nothing (empty
			# folder, or undo disabled). Don't push an empty entry onto the
			# undo stack — discard it so mcp_undo history stays meaningful.
			if registry.get("self_snapshots", false) \
					and (_undo_manager.get_store().get_entry(entry_id).get("files", []) as Array).is_empty():
				_undo_manager.discard(entry_id)
			else:
				_undo_manager.commit(entry_id)
		else:
			# Tool reported failure: drop the pre-snapshot. We do NOT auto-roll-back
			# the file system — by design a partial mutation is left in place so
			# the AI/user can decide what to do.
			_undo_manager.discard(entry_id)

	return result

## Call a tool handler directly and return a Dictionary result. No snapshot
## lifecycle, no parse-args, no built-in dispatch — caller is responsible for
## those. Used by `execute_tool` and `_builtin_batch_execute`.
func _dispatch_only(tool_name: String, args: Dictionary) -> Dictionary:
	if not _tool_map.has(tool_name):
		return {&"ok": false, &"error": "Unknown tool: %s" % tool_name}

	var handler: Array = _tool_map[tool_name]
	var node: Node = handler[0]
	var method: StringName = handler[1]
	if not node.has_method(method):
		return {&"ok": false, &"error": "Tool handler not found: %s.%s" % [node.name, method]}

	var result: Variant
	if _COROUTINE_TOOLS.has(tool_name):
		# Direct method dispatch for coroutine tools so `await` returns the
		# Dictionary correctly.
		match tool_name:
			"wait":
				result = await node.wait(args)
			"run_scene":
				result = await node.run_scene(args)
			"get_errors":
				result = await node.get_errors(args)
			_:
				push_error("[MCP] Coroutine tool '%s' has no direct dispatch case." % tool_name)
				result = {&"ok": false, &"error": "Coroutine tool '%s' missing dispatch case" % tool_name}
	else:
		result = node.call(method, args)

	if result == null or not (result is Dictionary):
		push_error("[MCP] Tool '%s' returned invalid result: %s" % [tool_name, str(result)])
		return {&"ok": false, &"error": "Tool '%s' returned null or non-Dictionary (possible crash — check Godot console)" % tool_name}
	if not result.has(&"ok"):
		result[&"ok"] = false
		result[&"error"] = result.get(&"error", "Tool returned no status")
	return result

# =============================================================================
# Snapshot lifecycle helpers
# =============================================================================

## Run before the tool executes: capture pre-mutation backups.
func _pre_tool_snapshots(entry_id: String, tool_name: String, args: Dictionary, registry: Dictionary) -> void:
	# snapshot_args: back up files at these arg-keyed paths (or marker keys).
	for key in registry.get("snapshot_args", []):
		var path := _resolve_arg_path(args, str(key), tool_name)
		if path != "":
			_undo_manager.record_snapshot(entry_id, path)
	# delete_args: back up + record as DELETED.
	for key in registry.get("delete_args", []):
		var path := _resolve_arg_path(args, str(key), tool_name)
		if path != "":
			_undo_manager.record_deletion(entry_id, path)
	# rename_args: back up the OLD side now (content will be gone after rename).
	# The NEW side is recorded post-tool from the result (or args fallback).
	var rename_pair: Array = registry.get("rename_args", [])
	if rename_pair.size() == 2:
		var old_path := _resolve_arg_path(args, str(rename_pair[0]), tool_name)
		if old_path != "":
			_undo_manager.record_deletion(entry_id, old_path)

## Run after the tool succeeds: record any newly-created paths.
func _post_tool_snapshots(entry_id: String, tool_name: String, args: Dictionary, result: Dictionary, registry: Dictionary) -> void:
	for key_v in registry.get("create_result", []):
		var key := str(key_v)
		var path := ""
		if result.has(key):
			path = _normalize_res_path(str(result[key]))
		elif args.has(key):
			# Fallback to args if the tool didn't echo the path.
			path = _normalize_res_path(str(args[key]))
		if path != "":
			# record_snapshot would copy the file's content (since it exists
			# post-mutation) and on undo would *restore* that content rather
			# than *delete* the file. For create_result we want undo = delete,
			# so register the path as CREATED directly without a backup.
			_record_created(entry_id, path)
	var rename_pair: Array = registry.get("rename_args", [])
	if rename_pair.size() == 2:
		var new_key := str(rename_pair[1])
		var new_path := ""
		if result.has(new_key):
			new_path = _normalize_res_path(str(result[new_key]))
		elif args.has(new_key):
			new_path = _normalize_res_path(str(args[new_key]))
		if new_path != "":
			_record_created(entry_id, new_path)

## Append a KIND_CREATED record to an entry's manifest. Stays out of the public
## SnapshotStore API since it's only meaningful post-mutation. The record is
## stamped with is_dir=true when the path is a directory at record time, so the
## undo manager can route to DirAccess (remove_absolute / make_dir_recursive)
## instead of trying to back-up/restore non-existent file content.
func _record_created(entry_id: String, path: String) -> void:
	var store := _undo_manager.get_store()
	var manifest := store.get_entry(entry_id)
	if manifest.is_empty():
		return
	for existing in manifest.get("files", []):
		if existing.get("path") == path:
			return  # already recorded
	var rec := {"path": path, "kind": MCPSnapshotStore.KIND_CREATED}
	# Detect at record time: a created directory has no content to back up.
	# Without this flag, undo would call FileAccess.file_exists(dir_path) which
	# returns false and silently leaves the directory in place.
	if DirAccess.dir_exists_absolute(path) and not FileAccess.file_exists(path):
		rec["is_dir"] = true
	manifest["files"].append(rec)
	store.update_entry(entry_id, manifest)

## Resolve a path from args, including special markers for nested/derived paths.
func _resolve_arg_path(args: Dictionary, key: String, _tool_name: String) -> String:
	match key:
		"__edit_file":
			# edit_script: args.edit.file
			var edit_v: Variant = args.get("edit", {})
			if edit_v is Dictionary and (edit_v as Dictionary).has("file"):
				return _normalize_res_path(str((edit_v as Dictionary)["file"]))
			return ""
		"__project_godot":
			return _PROJECT_GODOT_PATH
		_:
			if args.has(key):
				return _normalize_res_path(str(args[key]))
			return ""

func _normalize_res_path(path: String) -> String:
	var p := path.strip_edges()
	if p.is_empty():
		return ""
	if not p.begins_with("res://"):
		p = "res://" + p
	return p

# =============================================================================
# Built-in undo/redo/history handlers
# =============================================================================

func _builtin_undo(args: Dictionary) -> Dictionary:
	if _undo_manager == null:
		return {&"ok": false, &"error": "Undo manager not initialized"}
	var count := int(args.get("count", 1))
	if count < 1:
		count = 1
	var preview: bool = bool(args.get("preview", false))
	if preview:
		var summaries := _undo_manager.get_store().list_undo(count)
		return {&"ok": true, &"preview": true, &"would_undo": summaries}

	var undone: Array = []
	var errors: Array = []
	for i in range(count):
		var r := _undo_manager.undo_one()
		if not r.get("ok", false):
			# If stack is just empty, treat as success-with-stop.
			var err_msg: String = str(r.get("error", ""))
			if err_msg == "Undo stack is empty" and undone.size() > 0:
				break
			errors.append(err_msg)
			break
		undone.append(r.get("undid", {}))
	return {
		&"ok": errors.is_empty() and undone.size() > 0,
		&"undone_count": undone.size(),
		&"undone": undone,
		&"errors": errors,
		&"message": "Undid %d entr%s" % [undone.size(), "y" if undone.size() == 1 else "ies"],
	}

func _builtin_redo(args: Dictionary) -> Dictionary:
	if _undo_manager == null:
		return {&"ok": false, &"error": "Undo manager not initialized"}
	var count := int(args.get("count", 1))
	if count < 1:
		count = 1
	var preview: bool = bool(args.get("preview", false))
	if preview:
		var summaries := _undo_manager.get_store().list_redo(count)
		return {&"ok": true, &"preview": true, &"would_redo": summaries}

	var redone: Array = []
	var errors: Array = []
	for i in range(count):
		var r := _undo_manager.redo_one()
		if not r.get("ok", false):
			var err_msg: String = str(r.get("error", ""))
			if err_msg == "Redo stack is empty" and redone.size() > 0:
				break
			errors.append(err_msg)
			break
		redone.append(r.get("redid", {}))
	return {
		&"ok": errors.is_empty() and redone.size() > 0,
		&"redone_count": redone.size(),
		&"redone": redone,
		&"errors": errors,
		&"message": "Redid %d entr%s" % [redone.size(), "y" if redone.size() == 1 else "ies"],
	}

func _builtin_history(args: Dictionary) -> Dictionary:
	if _undo_manager == null:
		return {&"ok": false, &"error": "Undo manager not initialized"}
	var limit := int(args.get("limit", 20))
	if limit < 1:
		limit = 1
	var hist := _undo_manager.list_history(limit)
	hist[&"ok"] = true
	return hist

# =============================================================================
# Batch execution
# =============================================================================

## Execute a list of sub-commands under one shared snapshot entry so the whole
## batch is one undo step. In atomic mode (default), any sub-command failure
## rolls back every earlier successful step before returning. In non-atomic
## mode the batch stops at the first failure (or runs through, if
## stop_on_error=false) and commits whatever succeeded.
func _builtin_batch_execute(args: Dictionary) -> Dictionary:
	# Top-level args may arrive with commands as a JSON-stringified array.
	_parse_stringified_args(args)

	var commands_v: Variant = args.get("commands", [])
	if not (commands_v is Array):
		return {&"ok": false, &"error": "batch_execute: 'commands' must be an array"}
	var commands: Array = commands_v
	if commands.is_empty():
		return {&"ok": false, &"error": "batch_execute: 'commands' array is empty"}

	var atomic: bool = bool(args.get("atomic", true))
	var stop_on_error: bool = bool(args.get("stop_on_error", true))

	# --- Phase 1: cheap pre-validation. ---
	# Catch unknown / disallowed / structurally-wrong commands before any
	# mutation. Deep schema checks are deferred to each tool itself; rollback
	# in atomic mode covers mid-batch failure.
	for i in range(commands.size()):
		var cmd_v: Variant = commands[i]
		if not (cmd_v is Dictionary):
			return {&"ok": false, &"error": "commands[%d] must be an object with {name, args}" % i}
		var cmd: Dictionary = cmd_v
		var name_v: Variant = cmd.get("name", cmd.get("tool"))
		if name_v == null or str(name_v).is_empty():
			return {&"ok": false, &"error": "commands[%d] missing 'name'" % i}
		var name: String = str(name_v)
		if _DISALLOWED_IN_BATCH.has(name):
			return {
				&"ok": false,
				&"error": "commands[%d]: tool '%s' is not allowed inside batch_execute" % [i, name],
			}
		if not _tool_map.has(name):
			return {&"ok": false, &"error": "commands[%d]: unknown tool '%s'" % [i, name]}
		var sub_args_v: Variant = cmd.get("args", {})
		if not (sub_args_v is Dictionary):
			return {&"ok": false, &"error": "commands[%d].args must be an object" % i}

	# --- Phase 2: execute under a single shared snapshot entry. ---
	var entry_id := ""
	if _undo_manager != null:
		entry_id = _undo_manager.begin("batch_execute", {
			"count": commands.size(),
			"atomic": atomic,
		})

	var results: Array = []
	var failures: Array = []
	var succeeded := 0
	var failed_at := -1
	var failed_name := ""
	var first_error := ""

	for i in range(commands.size()):
		var cmd: Dictionary = commands[i]
		var name: String = str(cmd.get("name", cmd.get("tool", "")))
		var sub_args_v: Variant = cmd.get("args", {})
		var sub_args: Dictionary = sub_args_v if sub_args_v is Dictionary else {}
		_parse_stringified_args(sub_args)

		var registry: Dictionary = _MUTATING_TOOLS.get(name, {})
		if not registry.is_empty() and entry_id != "":
			_pre_tool_snapshots(entry_id, name, sub_args, registry)
			# Self-snapshotting sub-commands record into the shared batch entry.
			if registry.get("self_snapshots", false):
				sub_args["__entry_id"] = entry_id

		var result: Dictionary = await _dispatch_only(name, sub_args)
		var ok: bool = bool(result.get(&"ok", false))

		if ok and not registry.is_empty() and entry_id != "":
			_post_tool_snapshots(entry_id, name, sub_args, result, registry)

		results.append({"ok": ok, "name": name, "result": result})

		if ok:
			succeeded += 1
		else:
			var err_msg: String = str(result.get(&"error", "(no error message)"))
			failures.append({"index": i, "name": name, "error": err_msg})
			if failed_at == -1:
				# Top-level fields describe the FIRST failure for callers that
				# only look at the summary. `failures` has the full list.
				failed_at = i
				failed_name = name
				first_error = err_msg
			if atomic or stop_on_error:
				break

	# --- Phase 3: finalize. ---
	var top_ok: bool = failed_at == -1
	var rolled_back := false
	var rollback_errors: Array = []

	# If no sub-command actually recorded a snapshot (all read-only, or only
	# tools not in _MUTATING_TOOLS), drop the entry instead of polluting the
	# undo stack with a no-op. We still set rolled_back=true for atomic
	# failures so the response shape is consistent, even though there was
	# nothing to roll back.
	var has_files: bool = false
	if entry_id != "":
		var manifest := _undo_manager.get_store().get_entry(entry_id)
		has_files = not (manifest.get("files", []) as Array).is_empty()

	if entry_id != "":
		if top_ok:
			if has_files:
				_undo_manager.commit(entry_id)
			else:
				_undo_manager.discard(entry_id)
				entry_id = ""
		elif atomic:
			if has_files:
				var rb: Dictionary = _undo_manager.rollback_pending(entry_id)
				rolled_back = true
				if not bool(rb.get("ok", true)):
					rollback_errors = rb.get("errors", [])
			else:
				_undo_manager.discard(entry_id)
				entry_id = ""
				rolled_back = true  # vacuously — there was nothing to roll back
		elif succeeded > 0 and has_files:
			# Non-atomic, partial success — keep the snapshot so the user can
			# undo what did happen.
			_undo_manager.commit(entry_id)
		else:
			_undo_manager.discard(entry_id)
			entry_id = ""

	var response: Dictionary = {
		&"ok": top_ok,
		&"atomic": atomic,
		&"stop_on_error": stop_on_error,
		&"succeeded": succeeded,
		&"total": commands.size(),
		&"results": results,
	}
	if not top_ok:
		response[&"failed_at"] = failed_at
		response[&"failed_command"] = failed_name
		response[&"error"] = first_error
		response[&"failures"] = failures
		response[&"rolled_back"] = rolled_back
		if not rollback_errors.is_empty():
			response[&"rollback_errors"] = rollback_errors
	if entry_id != "" and (top_ok or (not atomic and succeeded > 0)):
		response[&"undo_entry_id"] = entry_id
	return response

func _parse_stringified_args(args: Dictionary) -> void:
	for key in args:
		var val = args[key]
		if val is String:
			var s: String = val.strip_edges()
			if (s.begins_with("{") and s.ends_with("}")) or (s.begins_with("[") and s.ends_with("]")):
				var parsed = JSON.parse_string(s)
				if parsed != null:
					args[key] = parsed

func get_available_tools() -> Array:
	"""Return list of available tool names."""
	return _tool_map.keys()
