@tool
extends Node
class_name MCPClient
## WebSocket client for communication with the MCP server.
## Handles connection, reconnection, and message routing.

signal connected
signal disconnected
signal tool_requested(request_id: String, tool_name: String, args: Dictionary)
signal client_count_changed(count: int)
signal runtime_status_changed(connected: bool)

const DEFAULT_URL := "ws://127.0.0.1:6505"
const RECONNECT_DELAY := 2.0
const MAX_RECONNECT_DELAY := 10.0
const MAX_PACKETS_PER_FRAME := 32

var socket: WebSocketPeer = WebSocketPeer.new()
var server_url: String = DEFAULT_URL
var _is_connected := false
var _reconnect_timer: Timer
var _current_reconnect_delay := RECONNECT_DELAY
var _should_reconnect := true
var _project_path: String
var _initialized := false
var _runtime_connected: bool = false

func _ready() -> void:
	_project_path = ProjectSettings.globalize_path("res://")

	# Create reconnect timer
	_reconnect_timer = Timer.new()
	_reconnect_timer.one_shot = true
	_reconnect_timer.timeout.connect(_on_reconnect_timer)
	add_child(_reconnect_timer)
	_initialized = true

func _process(_delta: float) -> void:
	if not _initialized:
		return
	if socket.get_ready_state() == WebSocketPeer.STATE_CLOSED:
		if _is_connected:
			_handle_disconnect()
		elif _should_reconnect and not _reconnect_timer.time_left > 0:
			_schedule_reconnect()
		return

	socket.poll()

	match socket.get_ready_state():
		WebSocketPeer.STATE_OPEN:
			if not _is_connected:
				_handle_connect()
			var packets_processed := 0
			while socket.get_available_packet_count() > 0 and packets_processed < MAX_PACKETS_PER_FRAME:
				_handle_message(socket.get_packet().get_string_from_utf8())
				packets_processed += 1

		WebSocketPeer.STATE_CLOSING:
			pass  # Wait for close

		WebSocketPeer.STATE_CLOSED:
			if _is_connected:
				_handle_disconnect()

func connect_to_server(url: String = DEFAULT_URL) -> void:
	server_url = url
	_should_reconnect = true
	_current_reconnect_delay = RECONNECT_DELAY
	_attempt_connection()

func disconnect_from_server() -> void:
	_should_reconnect = false
	if _reconnect_timer:
		_reconnect_timer.stop()
	if socket.get_ready_state() == WebSocketPeer.STATE_OPEN:
		socket.close()
	_is_connected = false

func _attempt_connection() -> void:
	if socket and socket.get_ready_state() != WebSocketPeer.STATE_CLOSED:
		socket.close()

	socket = WebSocketPeer.new()
	socket.outbound_buffer_size = 4 * 1024 * 1024  # 4 MB
	socket.inbound_buffer_size  = 1 * 1024 * 1024   # 1 MB
	_is_connected = false

	print("[MCP] Connecting to ", server_url, "...")
	var err := socket.connect_to_url(server_url)
	if err != OK:
		push_error("[MCP] Failed to connect: ", err)
		_schedule_reconnect()

func _handle_connect() -> void:
	_is_connected = true
	_current_reconnect_delay = RECONNECT_DELAY  # Reset backoff
	print("[MCP] Connected to server")

	# Send godot_ready message with project info. role=editor distinguishes
	# this connection from the runtime helper that may also connect.
	_send_message({
		&"type": &"godot_ready",
		&"role": &"editor",
		&"project_path": _project_path,
	})

	connected.emit()

func _handle_disconnect() -> void:
	_is_connected = false
	print("[MCP] Disconnected from server")
	disconnected.emit()

	if _should_reconnect:
		_schedule_reconnect()

func _schedule_reconnect() -> void:
	if not _reconnect_timer:
		return
	print("[MCP] Reconnecting in ", _current_reconnect_delay, " seconds...")
	_reconnect_timer.start(_current_reconnect_delay)
	# Exponential backoff
	_current_reconnect_delay = min(_current_reconnect_delay * 2, MAX_RECONNECT_DELAY)

func _on_reconnect_timer() -> void:
	_attempt_connection()

func _handle_message(json_string: String) -> void:
	var message = JSON.parse_string(json_string)
	if message == null:
		push_error("[MCP] Failed to parse message: ", json_string)
		return

	var msg_type: String = message.get(&"type", "")
	match msg_type:
		"ping":
			_send_message({&"type": &"pong"})
		"tool_invoke":
			var request_id: String = message.get(&"id", "")
			var tool_name: String = message.get(&"tool", "")
			var args: Dictionary = message.get(&"args", {})
			print("[MCP] Tool request: ", tool_name, " (", request_id, ")")
			tool_requested.emit(request_id, tool_name, args)
		"client_status":
			var count: int = int(message.get(&"count", 0))
			client_count_changed.emit(count)
		"runtime_status":
			var rconn: bool = bool(message.get(&"connected", false))
			if rconn != _runtime_connected:
				_runtime_connected = rconn
				runtime_status_changed.emit(rconn)
		_:
			print("[MCP] Unknown message type: ", msg_type)

func send_tool_result(request_id: String, success: bool, result = null, error: String = "") -> void:
	var response := {
		&"type": &"tool_result",
		&"id": request_id,
		&"success": success,
	}

	# Always include the structured result dict when we have one, even on
	# failure. This lets tools ship extra context fields (open_in_editor,
	# is_active, clamped, requested_ms, etc.) alongside the top-level error
	# message instead of losing them on the wire.
	if result != null:
		response[&"result"] = result
	if not success:
		response[&"error"] = error

	_send_message(response)
	print("[MCP] Sent result for ", request_id, " (success=", success, ")")

func _send_message(message: Dictionary) -> void:
	if socket.get_ready_state() == WebSocketPeer.STATE_OPEN:
		socket.send_text(JSON.stringify(message))

func is_connected_to_server() -> bool:
	return _is_connected

func is_runtime_connected() -> bool:
	return _runtime_connected
