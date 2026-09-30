@tool
extends Node
class_name SignalTools
## Persisted scene signal connection tools for MCP.
## Handles: map_scene_signals, update_scene_signal_connections

const SceneToolContext = preload("res://addons/godot_mcp/utils/scene_tool_context.gd")

const _ACTION_ALIASES := {
	"add": "add",
	"connect": "add",
	"remove": "remove",
	"disconnect": "remove",
}

var _context := SceneToolContext.new()

func set_editor_plugin(plugin: EditorPlugin) -> void:
	_context.set_owner_name("SignalTools")
	_context.set_editor_plugin(plugin)

func set_scene_tools_ref(scene_tools: Node) -> void:
	_context.set_scene_tools_ref(scene_tools)

func _ensure_res_path(path: String) -> String:
	return _context.ensure_res_path(path)

func _load_scene(scene_path: String) -> Array:
	return _context.load_scene(scene_path)

func _save_scene(scene_root: Node, scene_path: String) -> Dictionary:
	return _context.save_scene(scene_root, scene_path)

func _find_node(scene_root: Node, node_path: String) -> Node:
	return _context.find_node(scene_root, node_path)

func _serialize_value(value: Variant) -> Variant:
	return _context.serialize_value(value)

func _parse_value(value: Variant) -> Variant:
	return _context.parse_value(value)

func _release_scene_root(scene_root: Node) -> void:
	_context.release_scene_root(scene_root, true)

func _load_packed_scene(scene_path: String) -> Array:
	if not FileAccess.file_exists(scene_path):
		return [null, {&"ok": false, &"error": "Scene does not exist: " + scene_path}]

	var packed := load(scene_path) as PackedScene
	if not packed:
		return [null, {&"ok": false, &"error": "Failed to load scene: " + scene_path}]

	return [packed, {}]

func _node_path_to_string(path_value: Variant) -> String:
	var path_string := str(path_value)
	if path_string.is_empty():
		return "."
	return path_string

func _connection_flag_names(flags: int) -> Array:
	var names: Array = []
	if (flags & Object.CONNECT_DEFERRED) != 0:
		names.append("deferred")
	if (flags & Object.CONNECT_PERSIST) != 0:
		names.append("persist")
	if (flags & Object.CONNECT_ONE_SHOT) != 0:
		names.append("one_shot")
	if (flags & Object.CONNECT_REFERENCE_COUNTED) != 0:
		names.append("reference_counted")
	if names.is_empty():
		names.append("none")
	return names

func _serialize_connection_entry(state: SceneState, idx: int, inherited: bool, inherited_depth: int) -> Dictionary:
	var flags: int = state.get_connection_flags(idx)
	return {
		&"declared_in_scene_path": state.get_path(),
		&"source_node_path": _node_path_to_string(state.get_connection_source(idx)),
		&"signal_name": str(state.get_connection_signal(idx)),
		&"target_node_path": _node_path_to_string(state.get_connection_target(idx)),
		&"method_name": str(state.get_connection_method(idx)),
		&"flags": flags,
		&"flag_names": _connection_flag_names(flags),
		&"binds": _serialize_value(state.get_connection_binds(idx)),
		&"unbinds": state.get_connection_unbinds(idx),
		&"inherited": inherited,
		&"inherited_depth": inherited_depth,
	}

func _append_validation_issue(issues: Array, connection: Dictionary, message: String, severity: String = "error") -> void:
	issues.append({
		&"severity": severity,
		&"message": message,
		&"source_node_path": connection.get(&"source_node_path", "."),
		&"signal_name": connection.get(&"signal_name", ""),
		&"target_node_path": connection.get(&"target_node_path", "."),
		&"method_name": connection.get(&"method_name", ""),
		&"declared_in_scene_path": connection.get(&"declared_in_scene_path", ""),
		&"inherited": connection.get(&"inherited", false),
	})

func _validate_connection(scene_root: Node, connection: Dictionary, issues: Array) -> void:
	var source_path := str(connection.get(&"source_node_path", "."))
	var target_path := str(connection.get(&"target_node_path", "."))
	var signal_name := StringName(str(connection.get(&"signal_name", "")))
	var method_name := StringName(str(connection.get(&"method_name", "")))

	var source := _find_node(scene_root, source_path)
	var target := _find_node(scene_root, target_path)

	var validation := {
		&"source_exists": source != null,
		&"target_exists": target != null,
		&"signal_exists": false,
		&"method_exists": false,
	}

	if source:
		validation[&"source_class"] = source.get_class()
		validation[&"signal_exists"] = source.has_signal(signal_name)
	else:
		_append_validation_issue(issues, connection, "Source node not found in instantiated scene: " + source_path)

	if target:
		validation[&"target_class"] = target.get_class()
		validation[&"method_exists"] = target.has_method(method_name)
	else:
		_append_validation_issue(issues, connection, "Target node not found in instantiated scene: " + target_path)

	if source and not validation[&"signal_exists"]:
		_append_validation_issue(issues, connection, "Signal '%s' does not exist on node '%s' (%s)" % [signal_name, source_path, source.get_class()])

	if target and not validation[&"method_exists"]:
		_append_validation_issue(issues, connection, "Method '%s' does not exist on node '%s' (%s)" % [method_name, target_path, target.get_class()])

	connection[&"validation"] = validation

func _collect_scene_state_connections(state: SceneState, scene_root: Node, include_validation: bool, inherited: bool, inherited_depth: int, connections: Array, issues: Array) -> void:
	if state == null:
		return

	for idx: int in range(state.get_connection_count()):
		var connection := _serialize_connection_entry(state, idx, inherited, inherited_depth)
		connection[&"connection_index"] = connections.size()
		if include_validation and scene_root:
			_validate_connection(scene_root, connection, issues)
		connections.append(connection)

func _normalize_action(action: String) -> String:
	return _ACTION_ALIASES.get(action.to_lower(), "")

func _parse_connection_flags(flags_value: Variant) -> int:
	var flags := Object.CONNECT_PERSIST
	if flags_value == null:
		return flags

	if typeof(flags_value) == TYPE_INT:
		return int(flags_value) | Object.CONNECT_PERSIST

	if flags_value is Array:
		for raw_name in flags_value:
			var flag_name := str(raw_name).to_lower().strip_edges()
			match flag_name:
				"deferred":
					flags |= Object.CONNECT_DEFERRED
				"persist":
					flags |= Object.CONNECT_PERSIST
				"one_shot", "oneshot":
					flags |= Object.CONNECT_ONE_SHOT
				"reference_counted", "ref_counted":
					flags |= Object.CONNECT_REFERENCE_COUNTED
		return flags

	if flags_value is Dictionary:
		var flag_dict: Dictionary = flags_value
		if bool(flag_dict.get(&"deferred", false)):
			flags |= Object.CONNECT_DEFERRED
		if bool(flag_dict.get(&"persist", true)):
			flags |= Object.CONNECT_PERSIST
		if bool(flag_dict.get(&"one_shot", false)):
			flags |= Object.CONNECT_ONE_SHOT
		if bool(flag_dict.get(&"reference_counted", false)):
			flags |= Object.CONNECT_REFERENCE_COUNTED
	return flags

func _build_callable(target: Node, method_name: String, binds_value: Variant, unbinds: int) -> Array:
	var callable := Callable(target, StringName(method_name))
	var parsed_binds_result := _parse_bind_arguments(binds_value)
	if not parsed_binds_result[1].is_empty():
		return [Callable(), [], parsed_binds_result[1]]

	var binds: Array = parsed_binds_result[0]
	if not binds.is_empty():
		callable = callable.bindv(binds)

	if unbinds > 0:
		callable = callable.unbind(unbinds)

	return [callable, binds, {}]

func _parse_bind_arguments(binds_value: Variant) -> Array:
	var binds: Array = []
	if binds_value == null:
		return [binds, {}]
	if not (binds_value is Array):
		return [binds, {&"ok": false, &"error": "'binds' must be an array when provided"}]

	for item in binds_value:
		binds.append(_parse_value(item))
	return [binds, {}]

func _extract_connection_identity(operation: Dictionary) -> Dictionary:
	return {
		&"source_node_path": str(operation.get(&"source_node_path", operation.get(&"source", "."))).strip_edges(),
		&"signal_name": str(operation.get(&"signal_name", operation.get(&"signal", ""))).strip_edges(),
		&"target_node_path": str(operation.get(&"target_node_path", operation.get(&"target", "."))).strip_edges(),
		&"method_name": str(operation.get(&"method_name", operation.get(&"method", ""))).strip_edges(),
	}

func _resolve_connection_identity(scene_root: Node, identity: Dictionary, require_signal: bool = true, require_method: bool = true) -> Array:
	var source_path := str(identity.get(&"source_node_path", "."))
	var signal_name := str(identity.get(&"signal_name", ""))
	var target_path := str(identity.get(&"target_node_path", "."))
	var method_name := str(identity.get(&"method_name", ""))

	if signal_name.is_empty():
		return [null, null, {&"ok": false, &"error": "Missing required field: signal_name"}]
	if method_name.is_empty():
		return [null, null, {&"ok": false, &"error": "Missing required field: method_name"}]

	var source := _find_node(scene_root, source_path)
	if not source:
		return [null, null, {&"ok": false, &"error": "Source node not found: " + source_path}]
	if require_signal and not source.has_signal(StringName(signal_name)):
		return [null, null, {&"ok": false, &"error": "Signal '%s' does not exist on node '%s' (%s)" % [signal_name, source_path, source.get_class()]}]

	var target := _find_node(scene_root, target_path)
	if not target:
		return [null, null, {&"ok": false, &"error": "Target node not found: " + target_path}]
	if require_method and not target.has_method(StringName(method_name)):
		return [null, null, {&"ok": false, &"error": "Method '%s' does not exist on node '%s' (%s)" % [method_name, target_path, target.get_class()]}]

	return [source, target, {}]

func _result_base(index: int, action: String, identity: Dictionary) -> Dictionary:
	return {
		&"index": index,
		&"action": action,
		&"source_node_path": identity.get(&"source_node_path", "."),
		&"signal_name": identity.get(&"signal_name", ""),
		&"target_node_path": identity.get(&"target_node_path", "."),
		&"method_name": identity.get(&"method_name", ""),
	}

func _add_connection(scene_root: Node, operation: Dictionary, index: int) -> Dictionary:
	var identity := _extract_connection_identity(operation)
	var result := _result_base(index, "add", identity)
	var validated := _resolve_connection_identity(scene_root, identity, true, true)
	if not validated[2].is_empty():
		result.merge(validated[2], true)
		result[&"ok"] = false
		result[&"changed"] = false
		result[&"status"] = "error"
		return result

	var source: Node = validated[0]
	var target: Node = validated[1]
	var binds_value = operation.get(&"binds", null)
	var unbinds: int = max(0, int(operation.get(&"unbinds", 0)))
	var callable_result := _build_callable(target, str(identity[&"method_name"]), binds_value, unbinds)
	if not callable_result[2].is_empty():
		result.merge(callable_result[2], true)
		result[&"ok"] = false
		result[&"changed"] = false
		result[&"status"] = "error"
		return result

	var callable: Callable = callable_result[0]
	var binds: Array = callable_result[1]
	var signal_name := StringName(str(identity[&"signal_name"]))
	if source.is_connected(signal_name, callable):
		result[&"ok"] = true
		result[&"changed"] = false
		result[&"status"] = "already_exists"
		result[&"flags"] = _parse_connection_flags(operation.get(&"flags", null))
		result[&"flag_names"] = _connection_flag_names(int(result[&"flags"]))
		result[&"binds"] = _serialize_value(binds)
		result[&"unbinds"] = unbinds
		return result

	var flags := _parse_connection_flags(operation.get(&"flags", null))
	var error := source.connect(signal_name, callable, flags)
	if error != OK:
		result[&"ok"] = false
		result[&"changed"] = false
		result[&"status"] = "error"
		result[&"error"] = "Failed to connect signal: " + error_string(error)
		return result

	result[&"ok"] = true
	result[&"changed"] = true
	result[&"status"] = "added"
	result[&"flags"] = flags
	result[&"flag_names"] = _connection_flag_names(flags)
	result[&"binds"] = _serialize_value(binds)
	result[&"unbinds"] = unbinds
	return result

func _remove_matching_connections(source: Node, signal_name: StringName, target: Node, method_name: String, remove_all_matching: bool) -> Array:
	var matches: Array = []
	for connection: Dictionary in source.get_signal_connection_list(signal_name):
		var callable: Callable = connection.get(&"callable", Callable())
		if callable.get_object() != target:
			continue
		if str(callable.get_method()) != method_name:
			continue
		matches.append(callable)
		if not remove_all_matching:
			break
	return matches

func _remove_connection(scene_root: Node, operation: Dictionary, index: int) -> Dictionary:
	var identity := _extract_connection_identity(operation)
	var result := _result_base(index, "remove", identity)
	var validated := _resolve_connection_identity(scene_root, identity, false, false)
	if not validated[2].is_empty():
		result.merge(validated[2], true)
		result[&"ok"] = false
		result[&"changed"] = false
		result[&"status"] = "error"
		return result

	var source: Node = validated[0]
	var target: Node = validated[1]
	var signal_name := StringName(str(identity[&"signal_name"]))
	if not source.has_signal(signal_name):
		result[&"ok"] = true
		result[&"changed"] = false
		result[&"status"] = "not_found"
		return result
	var binds_provided := operation.has(&"binds") or operation.has(&"unbinds")
	var remove_all_matching: bool = bool(operation.get(&"remove_all_matching", not binds_provided))
	var removed_count := 0

	if binds_provided:
		var callable_result := _build_callable(target, str(identity[&"method_name"]), operation.get(&"binds", null), max(0, int(operation.get(&"unbinds", 0))))
		if not callable_result[2].is_empty():
			result.merge(callable_result[2], true)
			result[&"ok"] = false
			result[&"changed"] = false
			result[&"status"] = "error"
			return result

		var callable: Callable = callable_result[0]
		if source.is_connected(signal_name, callable):
			source.disconnect(signal_name, callable)
			removed_count = 1
			result[&"binds"] = _serialize_value(callable_result[1])
			result[&"unbinds"] = max(0, int(operation.get(&"unbinds", 0)))
		else:
			result[&"ok"] = true
			result[&"changed"] = false
			result[&"status"] = "not_found"
			return result
	else:
		var matching_callables := _remove_matching_connections(source, signal_name, target, str(identity[&"method_name"]), remove_all_matching)
		if matching_callables.is_empty():
			result[&"ok"] = true
			result[&"changed"] = false
			result[&"status"] = "not_found"
			return result

		for callable: Callable in matching_callables:
			if source.is_connected(signal_name, callable):
				source.disconnect(signal_name, callable)
				removed_count += 1

	result[&"ok"] = true
	result[&"changed"] = removed_count > 0
	result[&"status"] = "removed" if removed_count > 0 else "not_found"
	result[&"removed_count"] = removed_count
	return result

func _apply_operation(scene_root: Node, operation_value: Variant, index: int) -> Dictionary:
	if not (operation_value is Dictionary):
		return {
			&"index": index,
			&"ok": false,
			&"changed": false,
			&"status": "error",
			&"error": "Each operation must be a dictionary",
		}

	var operation: Dictionary = operation_value
	var action := _normalize_action(str(operation.get(&"action", "")).strip_edges())
	if action.is_empty():
		return {
			&"index": index,
			&"ok": false,
			&"changed": false,
			&"status": "error",
			&"error": "Unsupported action. Use add/connect or remove/disconnect.",
		}

	match action:
		"add":
			return _add_connection(scene_root, operation, index)
		"remove":
			return _remove_connection(scene_root, operation, index)

	return {
		&"index": index,
		&"ok": false,
		&"changed": false,
		&"status": "error",
		&"error": "Unsupported action: " + action,
	}

func map_scene_signals(args: Dictionary) -> Dictionary:
	var scene_path := _ensure_res_path(str(args.get(&"scene_path", "")).strip_edges())
	var _gate := MCPPaths.check(scene_path, false)
	if not _gate.is_empty():
		return _gate
	if scene_path.is_empty():
		return {&"ok": false, &"error": "Missing required field: scene_path"}

	var include_inherited: bool = bool(args.get(&"include_inherited", true))
	var include_validation: bool = bool(args.get(&"include_validation", true))

	var packed_result := _load_packed_scene(scene_path)
	if not packed_result[1].is_empty():
		return packed_result[1]

	var packed: PackedScene = packed_result[0]
	var state := packed.get_state()
	if state == null:
		return {&"ok": false, &"error": "Failed to read SceneState from: " + scene_path}

	var scene_root: Node = null
	if include_validation:
		var load_result := _load_scene(scene_path)
		if not load_result[1].is_empty():
			return load_result[1]
		scene_root = load_result[0]

	var connections: Array = []
	var issues: Array = []
	_collect_scene_state_connections(state, scene_root, include_validation, false, 0, connections, issues)

	var inherited_count := 0
	if include_inherited:
		var depth := 1
		var base_state = state.get_base_scene_state()
		while base_state != null:
			var before_count := connections.size()
			_collect_scene_state_connections(base_state, scene_root, include_validation, true, depth, connections, issues)
			inherited_count += connections.size() - before_count
			base_state = base_state.get_base_scene_state()
			depth += 1

	if scene_root:
		_release_scene_root(scene_root)

	return {
		&"ok": true,
		&"scene_path": scene_path,
		&"connections": connections,
		&"issues": issues,
		&"local_connection_count": state.get_connection_count(),
		&"inherited_connection_count": inherited_count,
		&"total_connection_count": connections.size(),
		&"issue_count": issues.size(),
	}

func update_scene_signal_connections(args: Dictionary) -> Dictionary:
	var scene_path := _ensure_res_path(str(args.get(&"scene_path", "")).strip_edges())
	var _gate := MCPPaths.check(scene_path, false)
	if not _gate.is_empty():
		return _gate
	if scene_path.is_empty():
		return {&"ok": false, &"error": "Missing required field: scene_path"}

	var operations_value = args.get(&"operations", [])
	if not (operations_value is Array):
		return {&"ok": false, &"error": "'operations' must be an array"}
	var operations: Array = operations_value
	if operations.is_empty():
		return {&"ok": false, &"error": "'operations' must contain at least one operation"}

	var load_result := _load_scene(scene_path)
	if not load_result[1].is_empty():
		return load_result[1]

	var scene_root: Node = load_result[0]
	var stop_on_error: bool = bool(args.get(&"stop_on_error", false))
	var results: Array = []
	var changed_count := 0
	var error_count := 0

	for index: int in range(operations.size()):
		var op_result := _apply_operation(scene_root, operations[index], index)
		results.append(op_result)
		if bool(op_result.get(&"changed", false)):
			changed_count += 1
		if not bool(op_result.get(&"ok", false)):
			error_count += 1
			if stop_on_error:
				break

	if changed_count > 0:
		var save_result := _save_scene(scene_root, scene_path)
		if not save_result.is_empty():
			return {
				&"ok": false,
				&"error": save_result.get(&"error", "Failed to save scene after updating signal connections"),
				&"scene_path": scene_path,
				&"results": results,
				&"changed_count": changed_count,
				&"error_count": error_count,
			}
	else:
		_release_scene_root(scene_root)

	return {
		&"ok": error_count == 0,
		&"scene_path": scene_path,
		&"saved": changed_count > 0,
		&"changed_count": changed_count,
		&"error_count": error_count,
		&"operation_count": results.size(),
		&"results": results,
	}
