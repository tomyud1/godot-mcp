@tool
extends EditorPlugin
## Godot MCP Plugin
## Connects to the godot-mcp-server via WebSocket and executes tools.

const MCPClientScript = preload("res://addons/godot_mcp/mcp_client.gd")
const ToolExecutorScript = preload("res://addons/godot_mcp/tool_executor.gd")
# Tools that touch the editor UI / scene tree and MUST run on the main thread.
const MAIN_THREAD_TOOLS: Array[StringName] = [
	&"get_console_log",
	&"get_errors",
	&"clear_console_log",
	&"open_in_godot",
	&"scene_tree_dump",
	&"get_node_properties",
]
# Tools safe to run on a background thread (pure read, no editor API calls).
# Everything else runs on the main thread (filesystem refresh, editor UI, etc.).
const BACKGROUND_SAFE_TOOLS: Array[StringName] = [
	&"list_dir",
	&"read_file",
	&"search_project",
	&"list_scripts",
	&"map_project",
	&"map_scenes",
	&"validate_script",
]

var _mcp_client: MCPClient # MCPClient
var _tool_executor: ToolExecutor # ToolExecutor
var _status_label: Label
var _thread: Thread
var _mutex: Mutex
var _pending_requests: Array = [] # [{id, tool, args}]
var _thread_running := false


func _enter_tree() -> void:
	print("[Godot MCP] Plugin loading...")

	_mutex = Mutex.new()

	# Create MCP client
	_mcp_client = MCPClientScript.new()
	_mcp_client.name = "MCPClient"
	add_child(_mcp_client)

	# Create tool executor
	_tool_executor = ToolExecutorScript.new()
	_tool_executor.name = "ToolExecutor"
	add_child(_tool_executor) # _ready() runs here, creating child tools
	_tool_executor.set_editor_plugin(self) # Now _visualizer_tools exists

	# Connect signals
	_mcp_client.connected.connect(_on_connected)
	_mcp_client.disconnected.connect(_on_disconnected)
	_mcp_client.tool_requested.connect(_on_tool_requested)

	# Add status indicator to editor
	_setup_status_indicator()

	# Start connection
	_mcp_client.connect_to_server()

	print("[Godot MCP] Plugin loaded - connecting to MCP server...")


func _exit_tree() -> void:
	print("[Godot MCP] Plugin unloading...")

	# Stop accepting new work and wait for the background thread to finish
	_thread_running = false
	if _thread and _thread.is_started():
		_thread.wait_to_finish()
	_thread = null

	if _mcp_client:
		_mcp_client.disconnect_from_server()
		_mcp_client.queue_free()

	if _tool_executor:
		_tool_executor.queue_free()

	if _status_label:
		remove_control_from_container(EditorPlugin.CONTAINER_TOOLBAR, _status_label)
		_status_label.queue_free()

	print("[Godot MCP] Plugin unloaded")


func _setup_status_indicator() -> void:
	"""Add a small status label to the editor toolbar."""
	_status_label = Label.new()
	_status_label.text = "MCP: Connecting..."
	_status_label.add_theme_color_override(&"font_color", Color.YELLOW)
	_status_label.add_theme_font_size_override(&"font_size", 12)
	add_control_to_container(EditorPlugin.CONTAINER_TOOLBAR, _status_label)


func _on_connected() -> void:
	print("[Godot MCP] Connected to MCP server")
	if _status_label:
		_status_label.text = "MCP: Connected"
		_status_label.add_theme_color_override(&"font_color", Color.GREEN)


func _on_disconnected() -> void:
	print("[Godot MCP] Disconnected from MCP server")
	if _status_label:
		_status_label.text = "MCP: Disconnected"
		_status_label.add_theme_color_override(&"font_color", Color.RED)


func _on_tool_requested(request_id: String, tool_name: String, args: Dictionary) -> void:
	"""Handle incoming tool request from MCP server."""
	print("[Godot MCP] Executing tool: ", tool_name)

	# Only pure-read tools go to the background thread; everything else
	# stays on the main thread (filesystem refresh, editor UI, etc.).
	if StringName(tool_name) not in BACKGROUND_SAFE_TOOLS:
		var result: Dictionary = _tool_executor.execute_tool(tool_name, args)
		_send_result(request_id, result)
		return

	# Queue for background execution
	_mutex.lock()
	_pending_requests.append({ &"id": request_id, &"tool": tool_name, &"args": args })
	_mutex.unlock()

	_ensure_thread_running()


func _ensure_thread_running() -> void:
	# Use our own flag — Thread.is_started() stays true until wait_to_finish()
	if _thread_running:
		return
	# Previous thread finished — clean it up before starting a new one
	if _thread:
		_thread.wait_to_finish()
	_thread = Thread.new()
	_thread_running = true
	_thread.start(_thread_loop)


func _thread_loop() -> void:
	while _thread_running:
		# Swap the whole queue out under the lock — O(1) instead of O(n) pop_front
		_mutex.lock()
		if _pending_requests.is_empty():
			_mutex.unlock()
			_thread_running = false
			return
		var batch: Array = _pending_requests
		_pending_requests = []
		_mutex.unlock()

		for req: Dictionary in batch:
			var result: Dictionary = _tool_executor.execute_tool(req[&"tool"], req[&"args"])
			call_deferred(&"_send_result", req[&"id"], result)


func _send_result(request_id: String, result: Dictionary) -> void:
	var success: bool = result.get(&"ok", false)
	if success:
		result.erase(&"ok")
		_mcp_client.send_tool_result(request_id, true, result)
	else:
		var error: String = result.get(&"error", "Unknown error")
		_mcp_client.send_tool_result(request_id, false, null, error)
