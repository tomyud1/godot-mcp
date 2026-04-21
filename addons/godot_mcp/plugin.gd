@tool
extends EditorPlugin
## Godot MCP Plugin
## Connects to the godot-mcp-server via WebSocket and executes tools.

const MCPClientScript = preload("res://addons/godot_mcp/mcp_client.gd")
const ToolExecutorScript = preload("res://addons/godot_mcp/tool_executor.gd")

const MCP_RUNTIME_AUTOLOAD_NAME := "MCPRuntime"
const MCP_RUNTIME_AUTOLOAD_PATH := "res://addons/godot_mcp/runtime/mcp_runtime.gd"

var _mcp_client: Node  # MCPClient
var _tool_executor: Node  # ToolExecutor
var _status_label: Label

func _enter_tree() -> void:
	print("[Godot MCP] Plugin loading...")

	# Create MCP client
	_mcp_client = MCPClientScript.new()
	_mcp_client.name = "MCPClient"
	add_child(_mcp_client)

	# Create tool executor
	_tool_executor = ToolExecutorScript.new()
	_tool_executor.name = "ToolExecutor"
	add_child(_tool_executor)  # _ready() runs here, creating child tools
	_tool_executor.set_editor_plugin(self)  # Now _visualizer_tools exists
	if _tool_executor.has_method("set_mcp_client"):
		_tool_executor.set_mcp_client(_mcp_client)

	# Connect signals
	_mcp_client.connected.connect(_on_connected)
	_mcp_client.disconnected.connect(_on_disconnected)
	_mcp_client.tool_requested.connect(_on_tool_requested)
	_mcp_client.client_count_changed.connect(_on_client_count_changed)
	_mcp_client.runtime_status_changed.connect(_on_runtime_status_changed)

	# Add status indicator to editor
	_setup_status_indicator()

	# Start connection
	_mcp_client.connect_to_server()

	print("[Godot MCP] Plugin loaded - connecting to MCP server...")

func _enable_plugin() -> void:
	# _enable_plugin() runs once when the user toggles the plugin ON in
	# Project > Project Settings > Plugins. _enter_tree() runs every time
	# the editor opens. We register the runtime autoload here so we don't
	# touch the user's project.godot on every editor restart.
	_register_runtime_autoload()

func _disable_plugin() -> void:
	_unregister_runtime_autoload()

func _exit_tree() -> void:
	print("[Godot MCP] Plugin unloading...")

	if _mcp_client:
		_mcp_client.disconnect_from_server()
		_mcp_client.queue_free()

	if _tool_executor:
		_tool_executor.queue_free()

	if _status_label:
		remove_control_from_container(EditorPlugin.CONTAINER_TOOLBAR, _status_label)
		_status_label.queue_free()

	print("[Godot MCP] Plugin unloaded")

func _register_runtime_autoload() -> void:
	if not FileAccess.file_exists(MCP_RUNTIME_AUTOLOAD_PATH):
		push_warning("[Godot MCP] Runtime autoload script missing: %s" % MCP_RUNTIME_AUTOLOAD_PATH)
		return
	# add_autoload_singleton is idempotent for the same name+path.
	add_autoload_singleton(MCP_RUNTIME_AUTOLOAD_NAME, MCP_RUNTIME_AUTOLOAD_PATH)
	print("[Godot MCP] Registered autoload '%s' -> %s" % [MCP_RUNTIME_AUTOLOAD_NAME, MCP_RUNTIME_AUTOLOAD_PATH])

func _unregister_runtime_autoload() -> void:
	# Only remove if the autoload is ours; don't stomp a user's same-named
	# autoload pointing somewhere else.
	var key := "autoload/" + MCP_RUNTIME_AUTOLOAD_NAME
	if not ProjectSettings.has_setting(key):
		return
	var current_path := str(ProjectSettings.get_setting(key, ""))
	if current_path.lstrip("*") != MCP_RUNTIME_AUTOLOAD_PATH:
		print("[Godot MCP] Autoload '%s' points to %s; leaving it alone." % [MCP_RUNTIME_AUTOLOAD_NAME, current_path])
		return
	remove_autoload_singleton(MCP_RUNTIME_AUTOLOAD_NAME)
	print("[Godot MCP] Unregistered autoload '%s'" % MCP_RUNTIME_AUTOLOAD_NAME)

func _on_runtime_status_changed(connected: bool) -> void:
	if not _status_label:
		return
	if connected:
		var current := _status_label.text
		if current.find(" + Runtime") < 0:
			_status_label.text = current + " + Runtime"
	else:
		_status_label.text = _status_label.text.replace(" + Runtime", "")

func _setup_status_indicator() -> void:
	"""Add a small status label to the editor toolbar."""
	_status_label = Label.new()
	_status_label.text = "MCP: Connecting..."
	_status_label.add_theme_color_override("font_color", Color.YELLOW)
	_status_label.add_theme_font_size_override("font_size", 20)
	add_control_to_container(EditorPlugin.CONTAINER_TOOLBAR, _status_label)

func _on_connected() -> void:
	print("[Godot MCP] Connected to MCP server")
	if _status_label:
		_status_label.text = "MCP: No Agent"
		_status_label.add_theme_color_override("font_color", Color(1.0, 0.6, 0.0))  # orange

func _on_disconnected() -> void:
	print("[Godot MCP] Disconnected from MCP server")
	if _status_label:
		_status_label.text = "MCP: Disconnected"
		_status_label.add_theme_color_override("font_color", Color.RED)

func _on_client_count_changed(count: int) -> void:
	if not _status_label:
		return
	if count > 0:
		_status_label.text = "MCP: Agent Active" if count == 1 else "MCP: Agents (%d)" % count
		_status_label.add_theme_color_override("font_color", Color.GREEN)
	else:
		_status_label.text = "MCP: No Agent"
		_status_label.add_theme_color_override("font_color", Color(1.0, 0.6, 0.0))  # orange

func _on_tool_requested(request_id: String, tool_name: String, args: Dictionary) -> void:
	"""Handle incoming tool request from MCP server.

	execute_tool is a coroutine (at least one tool — `wait` — uses `await`),
	so we MUST await it here. For non-coroutine tools the await returns
	immediately with the Dictionary, so there is no overhead for the common
	case."""
	print("[Godot MCP] Executing tool: ", tool_name)

	var result: Dictionary = await _tool_executor.execute_tool(tool_name, args)

	var success: bool = result.get(&"ok", false)
	# We keep the full dict and ship it as `result` regardless of success so
	# structured failure details (open_in_editor, where, clamped, …) survive
	# the round-trip to the agent. The top-level `error` string is kept on
	# failure for clients that only read that field.
	if success:
		result.erase(&"ok")
		_mcp_client.send_tool_result(request_id, true, result)
	else:
		var error: String = result.get(&"error", "Unknown error")
		_mcp_client.send_tool_result(request_id, false, result, error)
