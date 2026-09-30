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
## Vision models clamp the long edge to roughly this, so capturing larger just
## spends tokens on pixels that get thrown away.
const DEFAULT_MAX_DIMENSION := 1568
## Refuse to inline a PNG larger than this. 6 MiB of base64 is ~1.6M tokens,
## which would evict the entire conversation.
const DEFAULT_MAX_SCREENSHOT_BYTES := 6 * 1024 * 1024
const VariantCodec := preload("res://addons/godot_mcp/utils/variant_codec.gd")

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
			Callable(self, "_run_dispatch").call(rid, tool_name, args)
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
		"probe_ui":
			return _probe_ui(args)
		"probe_camera":
			return _probe_camera(args)
		"assert_runtime":
			return _assert_runtime(args)
		"get_runtime_log":
			return _get_runtime_log(args)
		"list_signal_connections":
			return _list_signal_connections(args)
		"runtime_call_method":
			return _runtime_call_method(args)
		"runtime_eval":
			return await _runtime_eval(args)
		"runtime_wait":
			return await _runtime_wait(args)
		"runtime_await_signal":
			return await _runtime_await_signal(args)
		_:
			return {"ok": false, "error": "Unknown runtime tool: %s" % tool_name}


func _run_dispatch(rid: String, tool_name: String, args: Dictionary) -> void:
	var result: Dictionary = await _dispatch(tool_name, args)
	_send_result(rid, result)


func _send_result(rid: String, result: Dictionary) -> void:
	var success: bool = bool(result.get("ok", false))
	result.erase("ok")
	_send({
		"type": "tool_result",
		"id": rid,
		"success": success,
		"result": result if success else null,
		"error": str(result.get("error", "")) if not success else "",
	})


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
	var original_width := img.get_width()
	var original_height := img.get_height()

	# Downscale before encoding. Vision models clamp the long edge to ~1568px
	# anyway, and Anthropic rejects anything over 8000px outright, so capturing
	# at full resolution spends tokens on pixels nobody will look at.
	var max_dimension: int = int(args.get("max_dimension", 0))
	if max_dimension <= 0:
		max_dimension = DEFAULT_MAX_DIMENSION
	img = _fit_within(img, max_dimension)
	var downscaled := img.get_width() != original_width or img.get_height() != original_height

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

	# Read the encoded bytes back so we can report the real size and refuse to
	# inline something oversized rather than blowing up the context window.
	var encoded := FileAccess.get_file_as_bytes(abs_path)
	var max_bytes: int = int(args.get("max_bytes", 0))
	if max_bytes <= 0:
		max_bytes = DEFAULT_MAX_SCREENSHOT_BYTES
	if encoded.size() > max_bytes:
		return {
			"ok": false,
			"error": "Screenshot is %d bytes, over the %d byte inline limit. The PNG is still saved at %s — pass a smaller max_dimension, or use a structured probe instead of an image." % [encoded.size(), max_bytes, resource_path],
			"resource_path": resource_path,
			"absolute_path": abs_path,
			"width": img.get_width(),
			"height": img.get_height(),
			"bytes": encoded.size(),
			"hint": "Non-multimodal agents should prefer query_runtime_node / get_ui_controls over screenshots.",
		}

	var out := {
		"ok": true,
		"resource_path": resource_path,
		"absolute_path": abs_path,
		"width": img.get_width(),
		"height": img.get_height(),
		"original_width": original_width,
		"original_height": original_height,
		"downscaled": downscaled,
		"bytes": encoded.size(),
	}
	if return_base64:
		out["base64_png"] = Marshalls.raw_to_base64(encoded)
	return out


# =============================================================================
# Screenshot helpers
# =============================================================================
func _fit_within(img: Image, max_dimension: int) -> Image:
	var w := img.get_width()
	var h := img.get_height()
	var longest := maxi(w, h)
	if max_dimension <= 0 or longest <= max_dimension:
		return img
	var scale := float(max_dimension) / float(longest)
	var target := Vector2i(maxi(1, int(round(w * scale))), maxi(1, int(round(h * scale))))
	# INTERPOLATE_BILINEAR keeps downscaled text readable without the cost of
	# LANCZOS on large frames.
	return img.duplicate().resize(target.x, target.y, Image.INTERPOLATE_BILINEAR)


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
# Structured probes
#
# A screenshot is a weak witness: it cannot show whether collision worked,
# whether the frame is the right size, or whether two Controls overlap, and a
# single angle can mislead. These report the measurements the engine already
# knows, which is both cheaper and more reliable — and it is the only path that
# works at all for a non-multimodal agent.
# =============================================================================
func _resolve_node(raw_path: String) -> Node:
	var tree := get_tree()
	if tree == null:
		return null
	if raw_path.begins_with("/"):
		return tree.root.get_node_or_null(NodePath(raw_path))
	var current := tree.current_scene
	if current:
		var found := current.get_node_or_null(NodePath(raw_path))
		if found:
			return found
	return tree.root.get_node_or_null(NodePath(raw_path))


## Snapshot of the on-screen Control layout: rects, text, and overlap.
## This is the "GameState" read that covers most UI questions in ~1 KB.
func _probe_ui(args: Dictionary) -> Dictionary:
	var tree := get_tree()
	if tree == null:
		return {"ok": false, "error": "SceneTree unavailable"}
	var root: Node = tree.current_scene if tree.current_scene else tree.root
	if root == null:
		return {"ok": false, "error": "No current scene"}

	var viewport := get_viewport()
	var viewport_rect := Rect2(Vector2.ZERO, viewport.get_visible_rect().size) if viewport else Rect2()
	var max_controls: int = int(args.get("max_controls", 60))
	var include_hidden: bool = bool(args.get("include_hidden", false))

	# A zero-sized viewport (headless, minimized, or before the window is
	# realized) would make every on-screen test fail and silently hide the
	# whole UI. Report everything and say why instead.
	var viewport_usable := viewport_rect.size.x > 1.0 and viewport_rect.size.y > 1.0
	var viewport_note := "Rects are in viewport pixels with the origin at the top-left, matching Control.get_global_rect()."
	if not viewport_usable:
		include_hidden = true
		viewport_note = "Viewport has no measurable size (%s), so the on-screen filter was disabled. Resize the game window and re-probe for filtered results." % str(viewport_rect.size)

	var controls: Array = []
	var overlaps: Array = []
	var _collected: Array[Rect2] = []
	var _collected_names: Array[String] = []

	_collect_controls(root, viewport_rect, include_hidden, max_controls, controls, _collected, _collected_names, overlaps)

	return {
		"ok": true,
		"viewport": {"width": int(viewport_rect.size.x), "height": int(viewport_rect.size.y)},
		"viewport_usable": viewport_usable,
		"control_count": controls.size(),
		"controls": controls,
		"overlaps": overlaps,
		"note": viewport_note,
	}


func _collect_controls(node: Node, viewport_rect: Rect2, include_hidden: bool, budget: int, out: Array, rects: Array[Rect2], names: Array[String], overlaps: Array) -> void:
	if out.size() >= budget:
		return
	for child in node.get_children():
		if out.size() >= budget:
			return
		if child is Control:
			var c := child as Control
			var visible := c.is_visible_in_tree()
			if visible or include_hidden:
				var r := c.get_global_rect()
				# Only controls that actually intersect the screen are
				# interesting; off-screen layout is what the agent asked to
				# debug, not background geometry.
				if r.intersects(viewport_rect) or include_hidden:
					out.append({
						"path": str(c.get_path()),
						"type": c.get_class(),
						"visible": visible,
						"rect": {
							"x": snappedf(r.position.x, 0.01),
							"y": snappedf(r.position.y, 0.01),
							"width": snappedf(r.size.x, 0.01),
							"height": snappedf(r.size.y, 0.01),
						},
						"on_screen": r.intersects(viewport_rect),
						"modulate": "#%s" % c.modulate.to_html(false),
					})
					# Overlap between siblings is a classic UI bug and is
					# invisible in a low-contrast screenshot.
					for i in rects.size():
						var other: Rect2 = rects[i]
						if other.intersects(r) and other.size.length() > 1.0 and r.size.length() > 1.0:
							var ov := other.intersection(r)
							# Ignore incidental touching of neighbours.
							if ov.size.x * ov.size.y > 4.0:
								overlaps.append({
									"a": names[i], "b": str(c.get_path()),
									"overlap_area": snappedf(ov.size.x * ov.size.y, 0.01),
								})
					rects.append(r)
					names.append(str(c.get_path()))
		_collect_controls(child, viewport_rect, include_hidden, budget, out, rects, names, overlaps)


## Where a Node3D sits on screen, and whether the active camera can see it.
## Answers "is my level geometry actually in shot" without decoding a frame.
func _probe_camera(args: Dictionary) -> Dictionary:
	var tree := get_tree()
	if tree == null:
		return {"ok": false, "error": "SceneTree unavailable"}
	var viewport := get_viewport()
	if viewport == null:
		return {"ok": false, "error": "No viewport"}
	var camera := viewport.get_camera_3d()
	if camera == null:
		return {"ok": false, "error": "No active Camera3D in the current viewport"}

	var size := viewport.get_visible_rect().size
	var cam_pos := camera.global_position
	var results: Array = []
	var targets: Array = args.get("node_paths", [])

	for path in targets:
		var node := _resolve_node(str(path))
		if node == null:
			results.append({"path": str(path), "found": false})
			continue
		if not (node is Node3D):
			results.append({"path": str(node.get_path()), "found": true, "is_3d": false})
			continue
		var n3 := node as Node3D
		var world := n3.global_position
		var screen := camera.unproject_position(world)
		var behind := camera.is_position_behind(world)
		results.append({
			"path": str(n3.get_path()),
			"found": true,
			"is_3d": true,
			"visible": n3.is_visible_in_tree() and not behind and Rect2(Vector2.ZERO, size).has_point(screen),
			"behind_camera": behind,
			"screen": {"x": snappedf(screen.x, 0.01), "y": snappedf(screen.y, 0.01)},
			"on_screen": (not behind) and Rect2(Vector2.ZERO, size).has_point(screen),
			"distance": snappedf(cam_pos.distance_to(world), 0.01),
		})

	return {
		"ok": true,
		"camera": str(camera.get_path()),
		"camera_position": {"x": snappedf(cam_pos.x, 0.01), "y": snappedf(cam_pos.y, 0.01), "z": snappedf(cam_pos.z, 0.01)},
		"viewport": {"width": int(size.x), "height": int(size.y)},
		"targets": results,
	}


# =============================================================================
# assert_runtime — bounded checks against the running game
#
# Each check returns {passed, actual, expected} so a failure is evidence rather
# than a vibe. This is how an agent verifies behaviour without pixels at all.
# =============================================================================
func _assert_runtime(args: Dictionary) -> Dictionary:
	var checks: Array = args.get("checks", [])
	if checks.is_empty():
		return {"ok": false, "error": "Missing 'checks' — pass a list of {kind, ...} assertions."}
	# Without a tree we cannot resolve a single node path, so say so once
	# rather than emitting a null-reference error per check.
	if get_tree() == null:
		return {"ok": false, "error": "SceneTree unavailable — the runtime helper is not attached to a running game."}

	var results: Array = []
	var passed_count := 0
	var failed_count := 0

	for check in checks:
		if typeof(check) != TYPE_DICTIONARY:
			results.append({"passed": false, "error": "Each check must be an object"})
			failed_count += 1
			continue
		var r := _run_assertion(check)
		if bool(r.get("passed", false)):
			passed_count += 1
		else:
			failed_count += 1
		results.append(r)

	return {
		"ok": true,
		"total": results.size(),
		"passed": passed_count,
		"failed": failed_count,
		"all_passed": failed_count == 0,
		"results": results,
	}


func _run_assertion(check: Dictionary) -> Dictionary:
	var kind := str(check.get("kind", ""))
	var node := _resolve_node(str(check.get("node_path", ""))) if not str(check.get("node_path", "")).is_empty() else null

	match kind:
		"node_exists":
			var passed := node != null
			return {"kind": kind, "node_path": check.get("node_path", ""), "passed": passed,
					"actual": "present" if passed else "absent"}

		"node_visible":
			if node == null:
				return {"kind": kind, "node_path": check.get("node_path", ""), "passed": false, "error": "Node not found"}
			var vis: bool = node.is_visible_in_tree()
			return {"kind": kind, "node_path": str(node.get_path()), "passed": vis == bool(check.get("visible", true)),
					"actual": vis, "expected": check.get("visible", true)}

		"node_inside_viewport":
			if node == null:
				return {"kind": kind, "node_path": check.get("node_path", ""), "passed": false, "error": "Node not found"}
			var viewport := get_viewport()
			if viewport == null:
				return {"kind": kind, "passed": false, "error": "No viewport"}
			if not (node is Control):
				return {"kind": kind, "passed": false, "error": "node_inside_viewport requires a Control"}
			var screen := Rect2(Vector2.ZERO, viewport.get_visible_rect().size)
			var on := screen.encloses((node as Control).get_global_rect())
			return {"kind": kind, "node_path": str(node.get_path()), "passed": on,
					"actual": on, "rect": str((node as Control).get_global_rect())}

		"rect_contains_point":
			if node == null or not (node is Control):
				return {"kind": kind, "passed": false, "error": "rect_contains_point requires an existing Control"}
			var p := check.get("point", {})
			var pt := Vector2(float(p.get("x", 0)), float(p.get("y", 0)))
			var contains: bool = (node as Control).get_global_rect().has_point(pt)
			return {"kind": kind, "node_path": str(node.get_path()), "passed": contains,
					"actual": contains, "point": {"x": pt.x, "y": pt.y}}

		"text_matches":
			if node == null:
				return {"kind": kind, "node_path": check.get("node_path", ""), "passed": false, "error": "Node not found"}
			var actual_text := _read_text(node)
			if actual_text == null:
				return {"kind": kind, "node_path": str(node.get_path()), "passed": false,
						"error": "Node has no readable text (expected Label/RichTextLabel/LineEdit/Button)"}
			var needle := str(check.get("text", ""))
			var found: bool = actual_text.contains(needle) if bool(check.get("contains", true)) else actual_text == needle
			return {"kind": kind, "node_path": str(node.get_path()), "passed": found,
					"actual": actual_text, "expected": needle}

		"property_equals":
			if node == null:
				return {"kind": kind, "node_path": check.get("node_path", ""), "passed": false, "error": "Node not found"}
			var prop := str(check.get("property", ""))
			if prop.is_empty():
				return {"kind": kind, "passed": false, "error": "Missing 'property'"}
			var expected_val = check.get("value")
			var actual_val = VariantCodec.serialize_value(node.get(prop))
			var eq := _values_equal(actual_val, expected_val)
			return {"kind": kind, "node_path": str(node.get_path()), "passed": eq,
					"actual": actual_val, "expected": expected_val}

		"group_count":
			var tree := get_tree()
			if tree == null:
				return {"kind": kind, "passed": false, "error": "SceneTree unavailable"}
			var g := str(check.get("group", ""))
			var n := tree.get_nodes_in_group(g).size()
			var want := int(check.get("equals", -1))
			return {"kind": kind, "group": g, "passed": (n == want), "actual": n, "expected": want}

		"no_errors":
			# Combines with get_errors; here we only report the log ring so the
			# check is self-contained.
			var errs := _collect_recent_errors()
			var max_errors := int(check.get("max", 0))
			var ok := errs.size() <= max_errors
			return {"kind": kind, "passed": ok, "actual": errs.size(), "expected": "<= %d" % max_errors, "errors": errs}

		_:
			return {"kind": kind, "passed": false,
					"error": "Unknown assertion kind '%s'. Supported: node_exists, node_visible, node_inside_viewport, rect_contains_point, text_matches, property_equals, group_count, no_errors." % kind}


func _read_text(node: Node) -> Variant:
	if node is RichTextLabel:
		return (node as RichTextLabel).get_parsed_text()
	if node is Label:
		return (node as Label).text
	if node is LineEdit:
		return (node as LineEdit).text
	if node is Button:
		return (node as Button).text
	if node is TextEdit:
		return (node as TextEdit).text
	return null


func _values_equal(a: Variant, b: Variant) -> bool:
	if typeof(a) != typeof(b):
		return false
	return str(a) == str(b) and (a is String or a is bool or a is int or a is float)


func _collect_recent_errors() -> Array:
	var out: Array = []
	for entry in _log_ring:
		if str(entry.get("level", "")) == "error":
			out.append(str(entry.get("text", "")))
	return out


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
# runtime_eval — execute arbitrary GDScript in the running game
# =============================================================================
func _runtime_eval(args: Dictionary) -> Dictionary:
	var code: String = str(args.get("code", "")).strip_edges()
	if code.is_empty():
		return {"ok": false, "error": "Missing 'code' (GDScript to evaluate in the running game)."}

	# This is arbitrary code execution inside the running game, with the
	# ability to quit it or corrupt its state. Require an explicit opt-in for
	# the same reason delete_file requires confirm=true: a single misdirected
	# or prompt-injected call should not be able to do it silently.
	if not bool(args.get("confirm", false)):
		return {
			"ok": false,
			"error": "runtime_eval executes arbitrary GDScript in the running game. REQUIRES confirm=true.",
			"hint": "Re-issue with confirm=true, or prefer query_runtime_node / runtime_call_method when they suffice.",
		}

	var built := _build_eval_node(code)
	if not built[0]:
		return {"ok": false, "error": "Failed to compile GDScript: %s" % built[1]}

	var temp_node: Node = built[1]
	var result: Variant = null
	if temp_node.has_method("execute"):
		result = await temp_node.execute()
	temp_node.queue_free()

	return {"ok": true, "result": VariantCodec.serialize_value(result)}


func _build_eval_node(code: String) -> Array:
	var script := _compile_eval_script(_prepare_eval_code(code))
	if script == null:
		script = _compile_eval_script(code)
	if script == null:
		return [false, "Check syntax. Use explicit 'return expr' for a value, or 'return await ...' for coroutine results."]

	var temp_node := Node.new()
	temp_node.set_script(script)
	temp_node.process_mode = Node.PROCESS_MODE_ALWAYS
	add_child(temp_node)
	return [true, temp_node]


func _compile_eval_script(body: String) -> GDScript:
	var source := """extends Node

func execute():
	var __result = null
	__result = await _run()
	return __result

func _run():
%s
""" % _indent_code(body)
	var script := GDScript.new()
	script.source_code = source
	if script.reload() != OK:
		return null
	return script


func _prepare_eval_code(code: String) -> String:
	var trimmed := code.strip_edges()
	if trimmed.is_empty():
		return ""
	var lines := trimmed.split("\n")
	var idx := lines.size() - 1
	while idx >= 0 and lines[idx].strip_edges().is_empty():
		idx -= 1
	if idx < 0:
		return trimmed
	var last := lines[idx].strip_edges()
	if last.begins_with("return ") or _is_statement_start(last):
		return trimmed
	return "%s\nreturn (%s)" % [trimmed, last]


func _is_statement_start(line: String) -> bool:
	var l := line.strip_edges()
	for kw in ["var ", "const ", "if ", "elif ", "else", "for ", "while ", "match ", "func ", "class ", "extends ", "break", "continue", "pass", "assert"]:
		if l.begins_with(kw):
			return true
	return l.ends_with(":")


func _indent_code(code: String) -> String:
	var out := ""
	for line in code.split("\n"):
		out += "\t" + line + "\n"
	return out


# =============================================================================
# runtime_wait — await N game frames so the engine actually ticks
# =============================================================================
func _runtime_wait(args: Dictionary) -> Dictionary:
	var frames: int = clampi(int(args.get("frames", 1)), 0, 3000)
	var use_physics: bool = str(args.get("frame_type", "render")).to_lower() == "physics"
	var tree := get_tree()
	if tree == null:
		return {"ok": false, "error": "SceneTree unavailable"}
	for i in frames:
		if use_physics:
			await tree.physics_frame
		else:
			await tree.process_frame
	return {"ok": true, "waited_frames": frames, "frame_type": "physics" if use_physics else "render"}


# =============================================================================
# runtime_await_signal — block until a signal fires on a live node or timeout
# =============================================================================
func _runtime_await_signal(args: Dictionary) -> Dictionary:
	var node_path: String = str(args.get("node_path", "")).strip_edges()
	var signal_name: String = str(args.get("signal_name", "")).strip_edges()
	if node_path.is_empty():
		return {"ok": false, "error": "Missing 'node_path'"}
	if signal_name.is_empty():
		return {"ok": false, "error": "Missing 'signal_name'"}

	var timeout: float = clampf(float(args.get("timeout", 10.0)), 0.1, 25.0)
	var tree := get_tree()
	if tree == null:
		return {"ok": false, "error": "SceneTree unavailable"}

	var node := _find_node(tree, node_path)
	if node == null:
		return {"ok": false, "error": "Node not found: %s" % node_path}
	if not node.has_signal(signal_name):
		return {"ok": false, "error": "Signal not found: %s on %s" % [signal_name, node_path]}

	var timer: SceneTreeTimer = tree.create_timer(timeout)
	var state: Array = [false]
	var cb := func():
		state[0] = true
	node.connect(signal_name, cb, CONNECT_ONE_SHOT)
	while not state[0] and timer.time_left > 0:
		await tree.process_frame
	if node.is_connected(signal_name, cb):
		node.disconnect(signal_name, cb)
	return {
		"ok": true,
		"node_path": node_path,
		"signal_name": signal_name,
		"received": state[0],
		"timeout": not state[0],
	}


# =============================================================================
# runtime_call_method — call a method on a live node in the running scene tree
# =============================================================================
func _runtime_call_method(args: Dictionary) -> Dictionary:
	var node_path: String = str(args.get("node_path", "")).strip_edges()
	var method_name: String = str(args.get("method_name", "")).strip_edges()
	if node_path.is_empty():
		return {"ok": false, "error": "Missing 'node_path'"}
	if method_name.is_empty():
		return {"ok": false, "error": "Missing 'method_name'"}
	var raw_args: Variant = args.get("args", [])
	if not raw_args is Array:
		return {"ok": false, "error": "'args' must be an array if provided"}

	var tree := get_tree()
	if tree == null:
		return {"ok": false, "error": "SceneTree unavailable"}
	var node := _find_node(tree, node_path)
	if node == null:
		return {"ok": false, "error": "Node not found: %s" % node_path}
	if not node.has_method(method_name):
		return {"ok": false, "error": "Method not found: %s on %s" % [method_name, node_path]}

	var result: Variant = node.callv(method_name, raw_args)
	return {
		"ok": true,
		"node_path": node_path,
		"method_name": method_name,
		"result": VariantCodec.serialize_value(result),
	}


func _find_node(tree: SceneTree, node_path: String) -> Node:
	if node_path.begins_with("/"):
		return tree.root.get_node_or_null(NodePath(node_path))
	if tree.current_scene != null:
		var node := tree.current_scene.get_node_or_null(NodePath(node_path))
		if node != null:
			return node
	return tree.root.get_node_or_null(NodePath(node_path))


# =============================================================================
func _ensure_cache_dir() -> void:
	var abs := ProjectSettings.globalize_path(CACHE_SCREENSHOT_DIR)
	if not DirAccess.dir_exists_absolute(abs):
		DirAccess.make_dir_recursive_absolute(abs)


func _send(msg: Dictionary) -> void:
	if _socket.get_ready_state() == WebSocketPeer.STATE_OPEN:
		_socket.send_text(JSON.stringify(msg))
