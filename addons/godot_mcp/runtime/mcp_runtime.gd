extends Node
## MCPRuntime — autoload that lives inside the user's running game and exposes
## a small set of "runtime" tools to the MCP server (take_screenshot,
## send_input, query_runtime_node, get_runtime_log, list_signal_connections).
##
## Connects to the same MCP WebSocket server as the editor plugin, but
## identifies itself with role="runtime" in its hello message so the server
## can route runtime tool calls to it.
##
## Auto-registered as an autoload by the godot_mcp editor plugin on
## _enable_plugin(); removed on _disable_plugin().

const SERVER_URL := "ws://127.0.0.1:6505"
const CACHE_SCREENSHOT_DIR := "res://addons/godot_mcp/cache/screenshots/"
const LOG_RING_CAPACITY := 500

const VariantCodec = preload("res://addons/godot_mcp/utils/variant_codec.gd")

## Methods that require confirm=true. Mirrors scene_tools.gd's denylist plus
## extra wariness about hitting autoload nodes directly (/root/* singletons).
const _CALL_METHOD_DENYLIST: Dictionary = {
	"queue_free": true,
	"free": true,
	"set_script": true,
	"remove_child": true,
	"replace_by": true,
	"reparent": true,
}

var _socket: WebSocketPeer = WebSocketPeer.new()
var _connected := false
var _reconnect_at_msec := 0
var _project_path := ""

# Circular buffer of recent runtime log lines. Populated only by explicit
# push_runtime_log() calls (internal connection events + user scripts that
# opt in). Engine-level push_error / push_warning / script errors are NOT
# captured here — those surface in the editor's Debugger > Errors tab and
# are reachable via the editor-side get_errors tool, not get_runtime_log.
var _log_ring: Array = []
var _started_at_msec := 0


func _ready() -> void:
	_project_path = ProjectSettings.globalize_path("res://")
	_started_at_msec = Time.get_ticks_msec()
	process_mode = Node.PROCESS_MODE_ALWAYS
	push_runtime_log("info", "MCPRuntime starting (project=%s)" % _project_path)
	_attempt_connect()


func _process(_delta: float) -> void:
	_socket.poll()
	var st := _socket.get_ready_state()

	if st == WebSocketPeer.STATE_OPEN:
		if not _connected:
			_connected = true
			_send({
				"type": "godot_ready",
				"role": "runtime",
				"project_path": _project_path,
				"started_at": _started_at_msec,
			})
			push_runtime_log("info", "MCPRuntime connected to MCP server.")

		while _socket.get_available_packet_count() > 0:
			var raw := _socket.get_packet().get_string_from_utf8()
			_handle_message(raw)

	elif st == WebSocketPeer.STATE_CLOSED:
		if _connected:
			_connected = false
			push_runtime_log("warn", "MCPRuntime disconnected; will retry.")
		var now := Time.get_ticks_msec()
		if now >= _reconnect_at_msec:
			_attempt_connect()


func _attempt_connect() -> void:
	_socket = WebSocketPeer.new()
	_socket.outbound_buffer_size = 8 * 1024 * 1024  # screenshots can be big
	_socket.inbound_buffer_size = 256 * 1024
	var err := _socket.connect_to_url(SERVER_URL)
	_reconnect_at_msec = Time.get_ticks_msec() + 2000
	if err != OK:
		push_runtime_log("warn", "MCPRuntime connect_to_url failed: %d (%s)" % [err, error_string(err)])


func _handle_message(json_string: String) -> void:
	var msg = JSON.parse_string(json_string)
	if msg == null or not msg is Dictionary:
		return
	var msg_type: String = str(msg.get("type", ""))
	match msg_type:
		"ping":
			_send({"type": "pong"})
		"tool_invoke":
			var rid: String = str(msg.get("id", ""))
			var tool_name: String = str(msg.get("tool", ""))
			var args = msg.get("args", {})
			if not args is Dictionary:
				args = {}
			var result := _dispatch(tool_name, args)
			var success: bool = bool(result.get("ok", false))
			# Keep the full dict (with `ok`) so the agent receives a consistent
			# shape. On failure, ship the structured body too, not just the
			# error string — callers rely on details like `where`, `hint`, etc.
			var err_msg: String = str(result.get("error", "")) if not success else ""
			_send({
				"type": "tool_result",
				"id": rid,
				"success": success,
				"result": result,
				"error": err_msg,
			})
		_:
			pass


func _dispatch(tool_name: String, args: Dictionary) -> Dictionary:
	match tool_name:
		"take_screenshot":
			return _take_screenshot(args)
		"send_input":
			return _send_input(args)
		"query_runtime_node":
			return _query_runtime_node(args)
		"get_runtime_log":
			return _get_runtime_log(args)
		"list_signal_connections":
			return _list_signal_connections(args)
		"get_performance_monitors":
			return _get_performance_monitors(args)
		"call_method":
			return _call_method(args)
		_:
			return {"ok": false, "error": "Unknown runtime tool: %s" % tool_name}


# =============================================================================
# take_screenshot
# =============================================================================
func _take_screenshot(args: Dictionary) -> Dictionary:
	var save_to: String = str(args.get("save_to", "")).strip_edges()
	var return_base64: bool = bool(args.get("return_base64", false))

	var viewport := get_viewport()
	if viewport == null:
		return {"ok": false, "error": "No viewport available"}
	var img: Image = viewport.get_texture().get_image()
	if img == null:
		return {"ok": false, "error": "Viewport returned no image"}

	var resource_path := ""
	if save_to.is_empty():
		_ensure_cache_dir()
		resource_path = "%sscreenshot_%d.png" % [CACHE_SCREENSHOT_DIR, Time.get_ticks_msec()]
	else:
		if not save_to.begins_with("res://") and not save_to.begins_with("user://"):
			save_to = "res://" + save_to
		resource_path = save_to

	var abs_path := ProjectSettings.globalize_path(resource_path)
	var dir := abs_path.get_base_dir()
	if not DirAccess.dir_exists_absolute(dir):
		DirAccess.make_dir_recursive_absolute(dir)

	var err := img.save_png(abs_path)
	if err != OK:
		return {"ok": false, "error": "save_png failed: %d (%s) at %s" % [err, error_string(err), abs_path]}

	var out := {
		"ok": true,
		"resource_path": resource_path,
		"absolute_path": abs_path,
		"width": img.get_width(),
		"height": img.get_height(),
	}
	if return_base64:
		out["base64_png"] = Marshalls.raw_to_base64(FileAccess.get_file_as_bytes(abs_path))
	return out


# =============================================================================
# send_input
# =============================================================================
func _send_input(args: Dictionary) -> Dictionary:
	var event_desc: Dictionary = args.get("event", {})
	if event_desc.is_empty():
		return {"ok": false, "error": "Missing 'event' dictionary"}
	var event := _build_input_event(event_desc)
	if event == null:
		return {"ok": false, "error": "Could not construct InputEvent from: %s" % str(event_desc)}
	Input.parse_input_event(event)
	return {
		"ok": true,
		"dispatched": event.get_class(),
		"event": event_desc,
	}


func _build_input_event(desc: Dictionary) -> InputEvent:
	var t: String = str(desc.get("type", ""))
	match t:
		"key":
			var k := InputEventKey.new()
			k.pressed = bool(desc.get("pressed", true))
			if desc.has("keycode"):
				k.keycode = int(desc["keycode"])
			if desc.has("physical_keycode"):
				k.physical_keycode = int(desc["physical_keycode"])
			if desc.has("key"):
				var keystr := str(desc["key"]).to_upper()
				k.physical_keycode = OS.find_keycode_from_string(keystr)
			if desc.has("shift"): k.shift_pressed = bool(desc["shift"])
			if desc.has("ctrl"): k.ctrl_pressed = bool(desc["ctrl"])
			if desc.has("alt"): k.alt_pressed = bool(desc["alt"])
			if desc.has("meta"): k.meta_pressed = bool(desc["meta"])
			return k
		"mouse_button":
			var mb := InputEventMouseButton.new()
			mb.pressed = bool(desc.get("pressed", true))
			mb.button_index = int(desc.get("button_index", MOUSE_BUTTON_LEFT))
			if desc.has("position"):
				mb.position = _to_vec2(desc["position"])
				mb.global_position = mb.position
			if desc.has("double_click"):
				mb.double_click = bool(desc["double_click"])
			return mb
		"mouse_motion":
			var mm := InputEventMouseMotion.new()
			if desc.has("position"):
				mm.position = _to_vec2(desc["position"])
				mm.global_position = mm.position
			if desc.has("relative"):
				mm.relative = _to_vec2(desc["relative"])
			return mm
		"action":
			var act := InputEventAction.new()
			act.action = str(desc.get("action", ""))
			act.pressed = bool(desc.get("pressed", true))
			act.strength = float(desc.get("strength", 1.0 if act.pressed else 0.0))
			return act
		_:
			return null


func _to_vec2(v: Variant) -> Vector2:
	if v is Vector2:
		return v
	if v is Dictionary:
		return Vector2(float(v.get("x", 0)), float(v.get("y", 0)))
	if v is Array and v.size() >= 2:
		return Vector2(float(v[0]), float(v[1]))
	return Vector2.ZERO


# =============================================================================
# query_runtime_node — inspect a live node in the running scene tree
# =============================================================================
func _query_runtime_node(args: Dictionary) -> Dictionary:
	var node_path: String = str(args.get("node_path", "")).strip_edges()
	if node_path.is_empty():
		return {"ok": false, "error": "Missing 'node_path' (e.g. /root/Main/Player or relative path from current_scene)"}
	var properties: Array = args.get("properties", [])
	var include_children: bool = bool(args.get("include_children", false))
	var include_groups: bool = bool(args.get("include_groups", true))

	var tree := get_tree()
	if tree == null:
		return {"ok": false, "error": "SceneTree unavailable"}

	var node: Node = null
	if node_path.begins_with("/"):
		node = tree.root.get_node_or_null(NodePath(node_path))
	else:
		var current := tree.current_scene
		if current:
			node = current.get_node_or_null(NodePath(node_path))
		if node == null:
			node = tree.root.get_node_or_null(NodePath(node_path))

	if node == null:
		return {"ok": false, "error": "Node not found: %s" % node_path}

	var info := {
		"ok": true,
		"name": str(node.name),
		"class": node.get_class(),
		"path": str(node.get_path()),
		"valid": true,
	}
	if include_groups:
		info["groups"] = node.get_groups()

	if properties.is_empty():
		# Default subset that's almost always interesting
		properties = ["position", "global_position", "rotation", "scale", "visible", "modulate"]
	var prop_values := {}
	for pname_v in properties:
		var pname := str(pname_v)
		var v = node.get(pname)
		if v != null:
			prop_values[pname] = _serialize(v)
	info["properties"] = prop_values

	if include_children:
		var kids: Array = []
		for c in node.get_children():
			kids.append({"name": str(c.name), "class": c.get_class()})
		info["children"] = kids

	return info


func _serialize(v: Variant) -> Variant:
	match typeof(v):
		TYPE_VECTOR2: return {"type": "Vector2", "x": v.x, "y": v.y}
		TYPE_VECTOR3: return {"type": "Vector3", "x": v.x, "y": v.y, "z": v.z}
		TYPE_COLOR: return {"type": "Color", "r": v.r, "g": v.g, "b": v.b, "a": v.a}
		TYPE_OBJECT:
			if v == null:
				return null
			return "<%s>" % v.get_class() if v.has_method("get_class") else "<Object>"
		_: return v


# =============================================================================
# get_runtime_log — recent runtime log lines pushed via push_runtime_log()
# =============================================================================
func _get_runtime_log(args: Dictionary) -> Dictionary:
	var limit: int = clampi(int(args.get("limit", 200)), 1, LOG_RING_CAPACITY)
	var since_ms: int = int(args.get("since_ms", 0))
	var filtered: Array = []
	for entry in _log_ring:
		if entry.get("ts_ms", 0) >= since_ms:
			filtered.append(entry)
	if filtered.size() > limit:
		filtered = filtered.slice(filtered.size() - limit, filtered.size())
	return {
		"ok": true,
		"entries": filtered,
		"count": filtered.size(),
		"started_at_ms": _started_at_msec,
		"now_ms": Time.get_ticks_msec(),
		"hint": "This ring buffer only holds explicit push_runtime_log() entries. For script prints/stdout use get_console_log; for runtime push_error / script errors use get_errors (it reads the Debugger > Errors tab).",
	}


# Public: user scripts can call MCPRuntime.push_runtime_log("info", "msg") to
# surface custom diagnostics in the agent's get_runtime_log results.
func push_runtime_log(level: String, text: String) -> void:
	if _log_ring.size() >= LOG_RING_CAPACITY:
		_log_ring.pop_front()
	_log_ring.append({
		"ts_ms": Time.get_ticks_msec(),
		"level": level,
		"text": text,
	})


# =============================================================================
# list_signal_connections — runtime-side
# =============================================================================
func _list_signal_connections(args: Dictionary) -> Dictionary:
	var node_path: String = str(args.get("node_path", "")).strip_edges()
	if node_path.is_empty():
		return {"ok": false, "error": "Missing 'node_path'"}

	var tree := get_tree()
	if tree == null:
		return {"ok": false, "error": "SceneTree unavailable"}

	var node: Node = null
	if node_path.begins_with("/"):
		node = tree.root.get_node_or_null(NodePath(node_path))
	else:
		var current := tree.current_scene
		if current:
			node = current.get_node_or_null(NodePath(node_path))

	if node == null:
		return {"ok": false, "error": "Node not found: %s" % node_path}

	var outgoing: Array = []
	for sig in node.get_signal_list():
		var sig_name := str(sig["name"])
		for conn in node.get_signal_connection_list(sig_name):
			var callable: Callable = conn["callable"]
			var dst = callable.get_object()
			outgoing.append({
				"signal": sig_name,
				"to_object": str(dst.get_path()) if dst is Node else "<%s>" % (dst.get_class() if dst else "null"),
				"method": callable.get_method(),
				"flags": int(conn.get("flags", 0)),
			})

	return {
		"ok": true,
		"source": "runtime",
		"node_path": node_path,
		"outgoing": outgoing,
		"outgoing_count": outgoing.size(),
	}


# =============================================================================
# get_performance_monitors — snapshot of Godot's Performance singleton
# =============================================================================
## Returns a single-frame snapshot of the in-game Performance singleton:
## fps, frame/physics times, static memory (current + peak), renderer counts,
## and engine-wide object/node tallies. Custom monitors registered via
## Performance.add_custom_monitor() are included under `custom_monitors`
## when any are present.
##
## The roadmap (#5) explicitly enumerates fps, frame_time_ms, physics_fps,
## static_memory_mb, static_memory_peak_mb, draw_calls, objects, nodes,
## orphan_nodes. `physics_fps` in Godot 4 isn't a single monitor — it's the
## product of the configured tick rate (`physics_ticks_per_second`) and
## actual physics step time (`physics_process_time_ms`); we return both so
## the agent can spot "physics is configured at 60 Hz but each step takes
## 28 ms" type issues.
func _get_performance_monitors(_args: Dictionary) -> Dictionary:
	var static_mem: int = int(Performance.get_monitor(Performance.MEMORY_STATIC))
	var static_mem_peak: int = int(Performance.get_monitor(Performance.MEMORY_STATIC_MAX))
	var out: Dictionary = {
		"ok": true,
		"fps": Performance.get_monitor(Performance.TIME_FPS),
		"frame_time_ms": Performance.get_monitor(Performance.TIME_PROCESS) * 1000.0,
		"physics_process_time_ms": Performance.get_monitor(Performance.TIME_PHYSICS_PROCESS) * 1000.0,
		"physics_ticks_per_second": Engine.physics_ticks_per_second,
		"static_memory_bytes": static_mem,
		"static_memory_mb": static_mem / 1048576.0,
		"static_memory_peak_bytes": static_mem_peak,
		"static_memory_peak_mb": static_mem_peak / 1048576.0,
		"draw_calls": int(Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME)),
		"objects_in_frame": int(Performance.get_monitor(Performance.RENDER_TOTAL_OBJECTS_IN_FRAME)),
		"primitives_in_frame": int(Performance.get_monitor(Performance.RENDER_TOTAL_PRIMITIVES_IN_FRAME)),
		"total_objects": int(Performance.get_monitor(Performance.OBJECT_COUNT)),
		"nodes": int(Performance.get_monitor(Performance.OBJECT_NODE_COUNT)),
		"orphan_nodes": int(Performance.get_monitor(Performance.OBJECT_ORPHAN_NODE_COUNT)),
	}

	# Custom monitors are only available in Godot 4.x via has/get APIs; iterate
	# the registered names and surface anything the user's scripts registered
	# via Performance.add_custom_monitor("foo/bar", callable).
	var custom: Dictionary = {}
	if Performance.has_method("get_custom_monitor_names"):
		for name_v in Performance.get_custom_monitor_names():
			var mname: String = str(name_v)
			var v = Performance.get_custom_monitor(mname)
			custom[mname] = _serialize(v)
	if not custom.is_empty():
		out["custom_monitors"] = custom

	return out


# =============================================================================
# call_method — runtime-side: invoke any method on a live node
# =============================================================================
## The "write half" of query_runtime_node. Find the live node, validate the
## method exists with matching arity, parse args through VariantCodec, invoke
## via callv(), serialize the return. Coroutine methods (functions containing
## `await`) are dispatched fire-and-forget — the GDScriptFunctionState handle
## is reported but not captured; side effects still run.
func _call_method(args: Dictionary) -> Dictionary:
	var node_path: String = str(args.get("node_path", "")).strip_edges()
	var method: String = str(args.get("method", "")).strip_edges()
	var raw_args: Variant = args.get("args", [])
	var confirm: bool = bool(args.get("confirm", false))
	var expect_return: bool = bool(args.get("expect_return", true))

	if node_path.is_empty():
		return {"ok": false, "error": "Missing 'node_path' (runtime: absolute like /root/Main/Player, or relative from current_scene)"}
	if method.is_empty():
		return {"ok": false, "error": "Missing 'method'"}
	if not (raw_args is Array):
		return {"ok": false, "error": "'args' must be an array (got %s)" % type_string(typeof(raw_args))}

	if _CALL_METHOD_DENYLIST.has(method) and not confirm:
		return {
			"ok": false,
			"error": "Method '%s' is on the destructive denylist. Pass confirm=true to allow it." % method,
			"denylisted": true,
			"denylist": _CALL_METHOD_DENYLIST.keys(),
		}

	# Extra wariness: autoloads live as direct children of /root. Calling
	# anything there without confirm could nuke a global singleton.
	if not confirm and node_path.begins_with("/root/"):
		var trimmed: String = node_path.trim_prefix("/root/")
		# /root/Main/Player → "Main/Player" (the part before the first /)
		# is the autoload or scene. We can't reliably tell autoload vs scene
		# from here, so only block calls *directly on* /root/<name>, not on
		# descendants. /root/Main is suspect; /root/Main/Player is not.
		if not trimmed.contains("/") and not trimmed.is_empty():
			return {
				"ok": false,
				"error": "Refusing to call '%s' directly on /root/%s without confirm=true. This path is likely an autoload singleton or the active scene root; passing confirm=true acknowledges that risk." % [method, trimmed],
				"autoload_guard": true,
			}

	var tree := get_tree()
	if tree == null:
		return {"ok": false, "error": "SceneTree unavailable"}

	var node: Node = null
	if node_path.begins_with("/"):
		node = tree.root.get_node_or_null(NodePath(node_path))
	else:
		var current := tree.current_scene
		if current:
			node = current.get_node_or_null(NodePath(node_path))
		if node == null:
			node = tree.root.get_node_or_null(NodePath(node_path))

	if node == null:
		return {"ok": false, "error": "Node not found: %s" % node_path}

	if not node.has_method(method):
		var available: Array = _collect_method_names_runtime(node)
		var suggestions: Array = _closest_method_matches_runtime(method, available, 5)
		return {
			"ok": false,
			"error": "Node %s (%s) has no method '%s'.%s" % [
				node_path, node.get_class(), method,
				(" Closest matches: " + ", ".join(suggestions)) if not suggestions.is_empty() else "",
			],
			"available_methods_sample": available.slice(0, mini(50, available.size())),
			"closest_matches": suggestions,
		}

	var parsed_args: Array = []
	for v in (raw_args as Array):
		parsed_args.append(VariantCodec.parse_value(v))

	var sig_info: Dictionary = _find_method_info_runtime(node, method)
	if not sig_info.is_empty():
		var declared_args: Array = sig_info.get("args", [])
		var defaults: Array = sig_info.get("default_args", [])
		var max_arity: int = declared_args.size()
		var min_arity: int = max_arity - defaults.size()
		var passed: int = parsed_args.size()
		if passed < min_arity or passed > max_arity:
			return {
				"ok": false,
				"error": "Arity mismatch for %s.%s: expected %d..%d args, got %d. Signature: %s" % [
					node.get_class(), method, min_arity, max_arity, passed,
					_format_method_signature_runtime(sig_info),
				],
				"method_signature": _format_method_signature_runtime(sig_info),
			}

	var t0: int = Time.get_ticks_msec()
	var ret = node.callv(method, parsed_args)
	var duration_ms: int = Time.get_ticks_msec() - t0

	var is_coroutine: bool = ret != null and typeof(ret) == TYPE_OBJECT and str(ret.get_class()) == "GDScriptFunctionState"

	var response: Dictionary = {
		"ok": true,
		"node_path": node_path,
		"node_class": node.get_class() if is_instance_valid(node) else "<freed>",
		"method": method,
		"duration_ms": duration_ms,
		"awaited": false,
		"is_coroutine": is_coroutine,
		"runtime": true,
	}
	if not sig_info.is_empty():
		response["method_signature"] = _format_method_signature_runtime(sig_info)

	if expect_return and not is_coroutine:
		response["return_value"] = _serialize_runtime_return(ret)
		response["return_type"] = _type_name_for_runtime(ret)
	elif is_coroutine:
		response["hint"] = "Method is a coroutine (contains `await`). Dispatched fire-and-forget; return value not captured. Use query_runtime_node after a `wait` to observe side effects."
	return response


func _collect_method_names_runtime(node: Node) -> Array:
	var names: Array = []
	for m in node.get_method_list():
		var n: String = str(m.get("name", ""))
		if n.is_empty():
			continue
		if n.begins_with("_") and not n.begins_with("__"):
			continue
		names.append(n)
	return names


func _closest_method_matches_runtime(query: String, available: Array, limit: int) -> Array:
	if query.is_empty() or available.is_empty():
		return []
	var scored: Array = []
	for n in available:
		var s: float = query.similarity(str(n))
		if s > 0.4:
			scored.append({"name": n, "score": s})
	scored.sort_custom(func(a, b): return float(a["score"]) > float(b["score"]))
	var out: Array = []
	for i in range(mini(limit, scored.size())):
		out.append(scored[i]["name"])
	return out


func _find_method_info_runtime(node: Node, method: String) -> Dictionary:
	for m in node.get_method_list():
		if str(m.get("name", "")) == method:
			return m
	return {}


func _format_method_signature_runtime(info: Dictionary) -> String:
	var name: String = str(info.get("name", ""))
	var declared_args: Array = info.get("args", [])
	var defaults: Array = info.get("default_args", [])
	var min_arity: int = declared_args.size() - defaults.size()
	var parts: Array = []
	for i in range(declared_args.size()):
		var a: Dictionary = declared_args[i]
		var aname: String = str(a.get("name", "arg%d" % i))
		var atype: int = int(a.get("type", TYPE_NIL))
		var atype_str: String = type_string(atype) if atype != TYPE_NIL else "Variant"
		if i >= min_arity:
			parts.append("%s: %s = <default>" % [aname, atype_str])
		else:
			parts.append("%s: %s" % [aname, atype_str])
	var ret_info: Dictionary = info.get("return", {})
	var ret_type: int = int(ret_info.get("type", TYPE_NIL))
	var ret_str: String = type_string(ret_type) if ret_type != TYPE_NIL else "void"
	return "%s(%s) -> %s" % [name, ", ".join(parts), ret_str]


func _serialize_runtime_return(v: Variant) -> Variant:
	if v == null:
		return null
	match typeof(v):
		TYPE_OBJECT:
			if v is Node:
				var path_str: String = ""
				if (v as Node).is_inside_tree():
					path_str = str((v as Node).get_path())
				return {
					"type": "Object",
					"class": (v as Node).get_class(),
					"name": str((v as Node).name),
					"node_path": path_str,
					"serializable": false,
				}
			if v is Resource:
				var rp: String = str((v as Resource).resource_path)
				var d: Dictionary = {
					"type": "Resource",
					"class": (v as Resource).get_class(),
					"serializable": false,
				}
				if not rp.is_empty():
					d["resource_path"] = rp
				return d
			return {
				"type": "Object",
				"class": v.get_class() if v.has_method("get_class") else "Object",
				"serializable": false,
			}
		TYPE_ARRAY:
			var out: Array = []
			for item in (v as Array):
				out.append(_serialize_runtime_return(item))
			return out
		TYPE_DICTIONARY:
			var od: Dictionary = {}
			for k in (v as Dictionary):
				od[k] = _serialize_runtime_return((v as Dictionary)[k])
			return od
		_:
			return VariantCodec.serialize_value(v)


func _type_name_for_runtime(v: Variant) -> String:
	if v == null:
		return "null"
	var t: int = typeof(v)
	if t == TYPE_OBJECT:
		return v.get_class() if v != null and v.has_method("get_class") else "Object"
	return type_string(t)


# =============================================================================
func _ensure_cache_dir() -> void:
	var abs := ProjectSettings.globalize_path(CACHE_SCREENSHOT_DIR)
	if not DirAccess.dir_exists_absolute(abs):
		DirAccess.make_dir_recursive_absolute(abs)


func _send(msg: Dictionary) -> void:
	if _socket.get_ready_state() == WebSocketPeer.STATE_OPEN:
		_socket.send_text(JSON.stringify(msg))
