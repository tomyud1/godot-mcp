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

var _socket: WebSocketPeer = WebSocketPeer.new()
var _connected := false
var _reconnect_at_msec := 0
var _project_path := ""

# Circular buffer of recent runtime log lines. We grow it via push_runtime_log()
# (called by user scripts that opt in) and via captured push_error/push_warning
# through Engine.print_error_messages — but most prints come from the engine
# via the editor's debugger, so get_runtime_log mirrors what the editor
# already sees with a runtime-focused timestamp.
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
			result.erase("ok")
			_send({
				"type": "tool_result",
				"id": rid,
				"success": success,
				"result": result if success else null,
				"error": str(result.get("error", "")) if not success else "",
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
		"hint": "For full engine output (prints from your scripts) the editor's get_console_log already includes the running game's stdout.",
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
func _ensure_cache_dir() -> void:
	var abs := ProjectSettings.globalize_path(CACHE_SCREENSHOT_DIR)
	if not DirAccess.dir_exists_absolute(abs):
		DirAccess.make_dir_recursive_absolute(abs)


func _send(msg: Dictionary) -> void:
	if _socket.get_ready_state() == WebSocketPeer.STATE_OPEN:
		_socket.send_text(JSON.stringify(msg))
