# Godot MCP Server - Complete Project Plan

## Overview

This document contains everything needed to build a **Godot MCP Server** that integrates Godot game engine tools with the RAGy application via the Model Context Protocol (MCP).

**Goal:** Create a clean, modular MCP server that exposes Godot editor functionality (scene manipulation, script editing, file operations) to any MCP-compatible AI client, with RAGy as the primary client.

---

## Project Paths

```
/Users/tomeryud/
├── projects/RAGy/                    # RAGy app (MCP client) - REFERENCE
├── godot-ai-assistant/               # Old Godot app - REFERENCE (do not modify)
└── godot-mcp/                        # NEW PROJECT (build here)
    ├── mcp-server/                   # Node.js MCP server
    └── godot-plugin/                 # Minimal GDScript plugin
```

---

## Part 1: Understanding RAGy (The MCP Client)

### What is RAGy?

RAGy is an Electron desktop app for building RAG (Retrieval-Augmented Generation) systems. It allows users to:
- Upload documents and chunk them
- Generate embeddings and build vector databases
- Chat with AI using RAG context
- Use MCP tools for extended functionality

### RAGy's MCP Architecture

RAGy already has MCP infrastructure. Key files to study:

#### MCP Client Manager
**Path:** `/Users/tomeryud/projects/RAGy/server/mcp/mcp-client.js`

This manages connections to MCP servers. Key code pattern:

```javascript
import { Client } from '@modelcontextprotocol/sdk/client/index.js';
import { StdioClientTransport } from '@modelcontextprotocol/sdk/client/stdio.js';

class MCPClientManager {
  constructor() {
    this.clients = new Map(); // serverName -> { client, transport }
    this.initialized = false;
  }

  async initialize() {
    // Connect to each MCP server as a child process
    await this.connectToServer('memory', {
      command: 'node',
      args: [path.join(__dirname, '../mcp-servers/memory-server.js')],
    });

    await this.connectToServer('rag', {
      command: 'node',
      args: [path.join(__dirname, '../mcp-servers/rag-server.js')],
    });

    // TODO: Add godot server here
    // await this.connectToServer('godot', {
    //   command: 'node',
    //   args: ['/Users/tomeryud/godot-mcp/mcp-server/src/index.js'],
    // });
  }

  async connectToServer(serverName, config) {
    const client = new Client({ name: 'ragy-chat-client', version: '1.0.0' }, { capabilities: {} });
    const transport = new StdioClientTransport({ command: config.command, args: config.args });
    await client.connect(transport);
    this.clients.set(serverName, { client, transport, config });
  }

  async getAllTools() {
    // Collects tools from all connected servers
    const allTools = [];
    for (const [serverName, { client }] of this.clients) {
      const response = await client.listTools();
      const toolsWithServer = response.tools.map(tool => ({ ...tool, _mcpServer: serverName }));
      allTools.push(...toolsWithServer);
    }
    return allTools;
  }

  async callTool(toolName, args, serverName) {
    const serverInfo = this.clients.get(serverName);
    return await serverInfo.client.callTool({ name: toolName, arguments: args });
  }
}
```

#### Example MCP Server (RAG Server)
**Path:** `/Users/tomeryud/projects/RAGy/server/mcp-servers/rag-server.js`

This shows the pattern for building MCP servers:

```javascript
import { Server } from '@modelcontextprotocol/sdk/server/index.js';
import { StdioServerTransport } from '@modelcontextprotocol/sdk/server/stdio.js';
import { CallToolRequestSchema, ListToolsRequestSchema } from '@modelcontextprotocol/sdk/types.js';

const server = new Server(
  { name: 'ragy-rag-server', version: '1.0.0' },
  { capabilities: { tools: {} } }
);

// Define available tools
server.setRequestHandler(ListToolsRequestSchema, async () => {
  return {
    tools: [
      {
        name: 'search_documents',
        description: 'Semantic search across the knowledge base',
        inputSchema: {
          type: 'object',
          properties: {
            query: { type: 'string', description: 'Search query' },
            top_k: { type: 'number', description: 'Number of results' }
          },
          required: ['query']
        }
      }
    ]
  };
});

// Handle tool execution
server.setRequestHandler(CallToolRequestSchema, async (request) => {
  const { name, arguments: args } = request.params;

  if (name === 'search_documents') {
    // Execute the tool and return result
    const results = await doSearch(args.query, args.top_k);
    return {
      content: [{ type: 'text', text: JSON.stringify(results) }]
    };
  }
});

// Start server
const transport = new StdioServerTransport();
await server.connect(transport);
```

#### AI Service with Tools
**Path:** `/Users/tomeryud/projects/RAGy/server/services/ai-with-tools.service.js`

This shows how RAGy uses MCP tools with AI providers. Key points:
- Gets tools via `mcpClientManager.getToolsForOpenAI()` or `getToolsForAnthropic()`
- Sends tools to AI provider
- When AI returns tool_call, executes via `mcpClientManager.callTool()`
- Returns result to AI for final response

### RAGy Tech Stack
- **Frontend:** React 18 + Vite
- **Backend:** Express.js (port 3001)
- **Desktop:** Electron
- **MCP SDK:** `@modelcontextprotocol/sdk`

---

## Part 2: Understanding the Old Godot AI Assistant (Reference)

### What is it?

The old Godot AI Assistant is a standalone app with:
- Express.js server with AI integration (multiple providers)
- React frontend for chat UI
- Godot plugin that polls server for tool invocations
- 33 tools for Godot manipulation

**Important:** Do NOT modify this project. Use it only as reference for tool implementations.

### Key Files to Reference

#### Tool Schemas (Copy tool definitions from here)
**Path:** `/Users/tomeryud/godot-ai-assistant/tool_schemas/`

Files:
- `openaiTools.js` - Tool definitions in OpenAI format
- `geminiTools.js` - Tool definitions in Gemini format
- `anthropicTools.js` - Tool definitions in Anthropic format

These contain the 33+ tool definitions with names, descriptions, and parameter schemas. Convert these to MCP format.

#### Tool Implementations in Godot Plugin
**Path:** `/Users/tomeryud/godot-ai-assistant/addons/ai_assistant/tools/`

This contains GDScript implementations for each tool:
- `file_operations/` - read_file, list_dir, search_project
- `scene_operations/` - read_scene, create_scene, add_node, modify_node
- `script_operations/` - create_script, apply_diff_preview

Study these to understand what each tool does and how to implement in the new plugin.

#### Tool Registry (Tool routing logic)
**Path:** `/Users/tomeryud/godot-ai-assistant/addons/ai_assistant/Core/tool_registry.gd`

Shows how tools are registered and routed to handlers.

#### External App Communicator (HTTP polling - replace with WebSocket)
**Path:** `/Users/tomeryud/godot-ai-assistant/addons/ai_assistant/Core/external_app_communicator.gd`

This uses HTTP polling (bad). Replace with WebSocket in new implementation.

### Complete Tool List (33 Tools)

**File System (6 tools):**
1. `list_dir` - List files/folders in a directory
2. `read_file` - Read text file contents
3. `search_project` - Regex/substring search across project
4. `list_scripts` - List all GDScript files
5. `create_script` - Create new GDScript file
6. `open_in_godot` - Open file at specific line in editor

**Scene Operations (10 tools):**
7. `scene_tree_dump` - Get current scene tree structure
8. `read_scene` - Parse .tscn file to get node structure
9. `create_scene` - Create new .tscn file with nodes
10. `add_node` - Add node to existing scene
11. `remove_node` - Remove node from scene
12. `rename_node` - Rename a node
13. `move_node` - Reorder node in hierarchy
14. `modify_node_property` - Change node properties
15. `get_node_properties` - Discover properties for node type
16. `set_collision_shape` - Configure collision shape

**Script Operations (4 tools):**
17. `apply_diff_preview` - Apply surgical code edits (1-10 lines)
18. `validate_script` - Check script syntax
19. `attach_script` - Attach script to node
20. `detach_script` - Remove script from node

**Project Configuration (4 tools):**
21. `get_project_settings` - Access window size, physics settings
22. `get_input_map` - Query input actions and bindings
23. `get_collision_layers` - Access collision layer names
24. `get_render_settings` - Graphics/render configuration

**Debugging (3 tools):**
25. `get_console_log` - Access Godot editor output
26. `get_errors` - Get structured error data
27. `clear_console_log` - Clear console

**Asset Operations (3 tools):**
28. `set_sprite_texture` - Set texture on Sprite2D
29. `generate_2d_asset` - Generate 2D graphics
30. `customize_and_run_workflow` - Run asset workflows

**Workflow (3 tools):**
31. `inspect_runninghub_workflow` - Inspect workflows
32. `search_comfyui_nodes` - Search node library
33. `manage_task_list` - Task management

---

## Part 3: New Architecture

### High-Level Design

```
┌─────────────────────────────────────────────────────────────┐
│  RAGy (or any MCP client)                                   │
│      │                                                      │
│      │ stdio (MCP protocol)                                 │
│      ▼                                                      │
│  ┌─────────────────────────────────────────────────────┐    │
│  │  godot-mcp-server (Node.js)                         │    │
│  │  - Speaks MCP via stdio                             │    │
│  │  - Speaks WebSocket to Godot plugin                 │    │
│  │  - Defines all Godot tools                          │    │
│  │  - Routes tool calls to Godot                       │    │
│  └──────────────────────┬──────────────────────────────┘    │
│                         │                                   │
│                         │ WebSocket (port 6505)             │
│                         │ (bidirectional, real-time)        │
│                         ▼                                   │
│  ┌─────────────────────────────────────────────────────┐    │
│  │  Godot Plugin (minimal)                             │    │
│  │  - Connects via WebSocket                           │    │
│  │  - Receives tool invocation requests                │    │
│  │  - Executes tools in Godot context                  │    │
│  │  - Returns results immediately                      │    │
│  │  - Shows connection status (minimal UI)             │    │
│  └─────────────────────────────────────────────────────┘    │
└─────────────────────────────────────────────────────────────┘
```

### WebSocket Protocol

Messages between MCP server and Godot plugin:

**Tool Invocation (Server → Godot):**
```json
{
  "type": "tool_invoke",
  "id": "unique-request-id",
  "tool": "read_scene",
  "args": {
    "scene_path": "res://scenes/player.tscn"
  }
}
```

**Tool Result (Godot → Server):**
```json
{
  "type": "tool_result",
  "id": "unique-request-id",
  "success": true,
  "result": { "nodes": [...] }
}
```

**Error (Godot → Server):**
```json
{
  "type": "tool_result",
  "id": "unique-request-id",
  "success": false,
  "error": "Scene file not found"
}
```

**Connection Status:**
```json
{ "type": "ping" }
{ "type": "pong" }
{ "type": "godot_ready", "project_path": "/path/to/project" }
```

---

## Part 4: Directory Structure

```
/Users/tomeryud/godot-mcp/
├── PROJECT_PLAN.md                   # This file
│
├── mcp-server/                       # Node.js MCP server
│   ├── package.json
│   ├── src/
│   │   ├── index.js                  # Main entry point
│   │   ├── godot-bridge.js           # WebSocket connection to Godot
│   │   ├── tools/
│   │   │   ├── index.js              # Exports all tools
│   │   │   ├── file-tools.js         # list_dir, read_file, etc.
│   │   │   ├── scene-tools.js        # read_scene, create_scene, etc.
│   │   │   ├── script-tools.js       # apply_diff, validate_script, etc.
│   │   │   ├── project-tools.js      # get_project_settings, etc.
│   │   │   └── debug-tools.js        # get_console_log, get_errors, etc.
│   │   └── utils/
│   │       └── logger.js             # Logging utility
│   └── README.md
│
└── godot-plugin/                     # Godot 4.x plugin
    ├── addons/
    │   └── godot_mcp/
    │       ├── plugin.cfg            # Plugin configuration
    │       ├── plugin.gd             # Main plugin script
    │       ├── mcp_client.gd         # WebSocket client
    │       ├── tool_executor.gd      # Routes and executes tools
    │       ├── tools/
    │       │   ├── file_tools.gd
    │       │   ├── scene_tools.gd
    │       │   ├── script_tools.gd
    │       │   └── project_tools.gd
    │       └── ui/
    │           └── status_indicator.gd  # Minimal connection status
    └── project.godot                 # Test project for development
```

---

## Part 5: Implementation Phases

### Phase 1: Skeleton MCP Server

**Goal:** Working MCP server that RAGy can connect to, with mock tools.

**Files to create:**

1. `mcp-server/package.json`:
```json
{
  "name": "godot-mcp-server",
  "version": "0.1.0",
  "type": "module",
  "main": "src/index.js",
  "scripts": {
    "start": "node src/index.js"
  },
  "dependencies": {
    "@modelcontextprotocol/sdk": "^1.0.0",
    "ws": "^8.18.0"
  }
}
```

2. `mcp-server/src/index.js`:
- Create MCP server using `@modelcontextprotocol/sdk`
- Register 3 mock tools: `list_dir`, `read_file`, `read_scene`
- Return fake data for testing
- NO WebSocket yet (Phase 2)

**Test:**
1. Add to RAGy's mcp-client.js
2. Start RAGy
3. Ask AI: "List the files in my Godot project"
4. Verify mock response received

---

### Phase 2: WebSocket Bridge

**Goal:** MCP server can communicate with Godot via WebSocket.

**Files to create/modify:**

1. `mcp-server/src/godot-bridge.js`:
```javascript
import { WebSocketServer } from 'ws';

class GodotBridge {
  constructor(port = 6505) {
    this.port = port;
    this.godotConnection = null;
    this.pendingRequests = new Map(); // id -> { resolve, reject, timeout }
  }

  start() {
    this.wss = new WebSocketServer({ port: this.port });
    this.wss.on('connection', (ws) => this.handleConnection(ws));
  }

  handleConnection(ws) {
    this.godotConnection = ws;
    ws.on('message', (data) => this.handleMessage(JSON.parse(data)));
    ws.on('close', () => { this.godotConnection = null; });
  }

  async invokeTool(toolName, args) {
    if (!this.godotConnection) {
      throw new Error('Godot not connected');
    }

    const id = crypto.randomUUID();

    return new Promise((resolve, reject) => {
      const timeout = setTimeout(() => {
        this.pendingRequests.delete(id);
        reject(new Error('Tool execution timeout'));
      }, 30000);

      this.pendingRequests.set(id, { resolve, reject, timeout });

      this.godotConnection.send(JSON.stringify({
        type: 'tool_invoke',
        id,
        tool: toolName,
        args
      }));
    });
  }

  handleMessage(message) {
    if (message.type === 'tool_result') {
      const pending = this.pendingRequests.get(message.id);
      if (pending) {
        clearTimeout(pending.timeout);
        this.pendingRequests.delete(message.id);
        if (message.success) {
          pending.resolve(message.result);
        } else {
          pending.reject(new Error(message.error));
        }
      }
    }
  }

  isConnected() {
    return this.godotConnection !== null;
  }
}
```

2. Update `mcp-server/src/index.js`:
- Import GodotBridge
- Start WebSocket server on startup
- Route tool calls through bridge (if connected) or return "not connected" error

**Test:**
1. Start MCP server
2. Connect with `wscat -c ws://localhost:6505`
3. Verify connection established
4. Send fake tool_result, verify handling

---

### Phase 3: Minimal Godot Plugin

**Goal:** Godot plugin connects to MCP server via WebSocket.

**Files to create:**

1. `godot-plugin/addons/godot_mcp/plugin.cfg`:
```ini
[plugin]
name="Godot MCP"
description="MCP server integration for AI assistants"
author="Your Name"
version="0.1.0"
script="plugin.gd"
```

2. `godot-plugin/addons/godot_mcp/plugin.gd`:
```gdscript
@tool
extends EditorPlugin

var mcp_client: MCPClient

func _enter_tree():
    mcp_client = MCPClient.new()
    add_child(mcp_client)
    mcp_client.connect_to_server()

func _exit_tree():
    if mcp_client:
        mcp_client.disconnect_from_server()
        mcp_client.queue_free()
```

3. `godot-plugin/addons/godot_mcp/mcp_client.gd`:
```gdscript
extends Node
class_name MCPClient

signal connected
signal disconnected
signal tool_invoked(id: String, tool_name: String, args: Dictionary)

var socket: WebSocketPeer
var server_url := "ws://localhost:6505"
var is_connected := false

func _ready():
    socket = WebSocketPeer.new()

func _process(_delta):
    if socket.get_ready_state() == WebSocketPeer.STATE_OPEN:
        socket.poll()
        while socket.get_available_packet_count() > 0:
            var packet = socket.get_packet()
            _handle_message(packet.get_string_from_utf8())

func connect_to_server():
    var err = socket.connect_to_url(server_url)
    if err != OK:
        push_error("Failed to connect to MCP server")

func _handle_message(json_string: String):
    var message = JSON.parse_string(json_string)
    if message.type == "tool_invoke":
        tool_invoked.emit(message.id, message.tool, message.args)

func send_result(id: String, success: bool, result = null, error: String = ""):
    var response = {
        "type": "tool_result",
        "id": id,
        "success": success
    }
    if success:
        response["result"] = result
    else:
        response["error"] = error
    socket.send_text(JSON.stringify(response))
```

**Test:**
1. Start MCP server
2. Open Godot project with plugin enabled
3. Verify "Connected" in Godot output
4. Verify MCP server logs connection

---

### Phase 4: First Real Tools (File Operations)

**Goal:** Implement file tools end-to-end.

**Tools to implement:**
- `list_dir` - List directory contents
- `read_file` - Read file contents

**MCP Server side (`mcp-server/src/tools/file-tools.js`):**
```javascript
export const fileTools = [
  {
    name: 'list_dir',
    description: 'List files and folders in a Godot project directory',
    inputSchema: {
      type: 'object',
      properties: {
        path: {
          type: 'string',
          description: 'Directory path (e.g., "res://", "res://scenes/")'
        }
      },
      required: ['path']
    }
  },
  {
    name: 'read_file',
    description: 'Read contents of a file in the Godot project',
    inputSchema: {
      type: 'object',
      properties: {
        path: {
          type: 'string',
          description: 'File path (e.g., "res://scripts/player.gd")'
        },
        start_line: {
          type: 'number',
          description: 'Optional start line (1-indexed)'
        },
        end_line: {
          type: 'number',
          description: 'Optional end line (1-indexed)'
        }
      },
      required: ['path']
    }
  }
];
```

**Godot side (`godot-plugin/addons/godot_mcp/tools/file_tools.gd`):**
```gdscript
extends Node
class_name FileTools

func list_dir(args: Dictionary) -> Dictionary:
    var path = args.get("path", "res://")
    var dir = DirAccess.open(path)
    if dir == null:
        return {"error": "Cannot open directory: " + path}

    var files = []
    var folders = []

    dir.list_dir_begin()
    var file_name = dir.get_next()
    while file_name != "":
        if dir.current_is_dir():
            folders.append(file_name)
        else:
            files.append(file_name)
        file_name = dir.get_next()
    dir.list_dir_end()

    return {"files": files, "folders": folders}

func read_file(args: Dictionary) -> Dictionary:
    var path = args.get("path", "")
    if not FileAccess.file_exists(path):
        return {"error": "File not found: " + path}

    var file = FileAccess.open(path, FileAccess.READ)
    var content = file.get_as_text()
    file.close()

    return {"content": content, "path": path}
```

**Test:**
1. Start MCP server
2. Open Godot with plugin
3. In RAGy, ask: "List the files in my Godot project's root directory"
4. Verify real file listing returned

---

### Phase 5: Scene Tools

**Tools to implement:**
- `read_scene` - Parse .tscn file structure
- `create_scene` - Create new scene
- `add_node` - Add node to scene
- `modify_node_property` - Change node property

Reference the old implementations:
- `/Users/tomeryud/godot-ai-assistant/addons/ai_assistant/tools/scene_operations/`

---

### Phase 6: Script Tools

**Tools to implement:**
- `create_script` - Create new GDScript
- `apply_diff_preview` - Apply code edits
- `validate_script` - Check syntax

Reference:
- `/Users/tomeryud/godot-ai-assistant/addons/ai_assistant/tools/script_operations/`

---

### Phase 7: All Remaining Tools

Port remaining tools from old project:
- Project settings tools
- Debug tools
- Asset tools

---

### Phase 8: RAGy Integration

**Goal:** Add Godot MCP server to RAGy with settings UI.

**Files to modify in RAGy:**

1. `/Users/tomeryud/projects/RAGy/server/mcp/mcp-client.js`:
```javascript
// Add in initialize():
if (settings.godotEnabled) {
  await this.connectToServer('godot', {
    command: 'node',
    args: ['/Users/tomeryud/godot-mcp/mcp-server/src/index.js'],
  });
}
```

2. Add settings for enabling/disabling Godot tools
3. Add UI indicator for Godot connection status

---

## Part 6: Testing Checklist

### Phase 1 Tests
- [ ] MCP server starts without errors
- [ ] RAGy connects to MCP server
- [ ] Mock tools appear in AI tool list
- [ ] AI can call mock tools and get responses

### Phase 2 Tests
- [ ] WebSocket server starts on port 6505
- [ ] External WebSocket client can connect
- [ ] Messages sent/received correctly
- [ ] Timeout handling works

### Phase 3 Tests
- [ ] Plugin loads in Godot without errors
- [ ] Plugin connects to MCP server
- [ ] Connection status updates correctly
- [ ] Reconnection works after disconnect

### Phase 4 Tests
- [ ] `list_dir` returns real directory contents
- [ ] `read_file` returns real file contents
- [ ] Errors handled gracefully
- [ ] Full flow works: RAGy → AI → MCP → Godot → result

### Phase 5-7 Tests
- [ ] Each tool works individually
- [ ] Complex workflows work (create scene, add nodes, add script)
- [ ] Error handling for all edge cases

### Phase 8 Tests
- [ ] Godot tools can be enabled/disabled in RAGy
- [ ] Connection status shows in RAGy UI
- [ ] Graceful handling when Godot not connected

---

## Part 7: Key Technical Details

### MCP Protocol Basics

MCP uses JSON-RPC over stdio (stdin/stdout). The SDK handles this.

**Tool definition format:**
```javascript
{
  name: 'tool_name',
  description: 'What the tool does',
  inputSchema: {
    type: 'object',
    properties: {
      param1: { type: 'string', description: '...' },
      param2: { type: 'number', description: '...' }
    },
    required: ['param1']
  }
}
```

**Tool result format:**
```javascript
{
  content: [
    { type: 'text', text: 'Result as string or JSON' }
  ]
}
```

### Godot 4.x WebSocket API

```gdscript
var socket = WebSocketPeer.new()
socket.connect_to_url("ws://localhost:6505")

# In _process:
socket.poll()
while socket.get_available_packet_count() > 0:
    var data = socket.get_packet().get_string_from_utf8()
    # Handle data

# Send:
socket.send_text(JSON.stringify(message))
```

### Error Handling Strategy

1. **MCP Server errors:** Return error in content with `isError: true`
2. **Godot not connected:** Return clear error message
3. **Tool execution timeout:** 30 second timeout with clear error
4. **Invalid arguments:** Validate and return specific error

---

## Part 8: Commands Reference

### Development Commands

```bash
# Navigate to project
cd /Users/tomeryud/godot-mcp

# Install MCP server dependencies
cd mcp-server && npm install

# Start MCP server standalone (for testing)
cd mcp-server && npm start

# Test WebSocket connection
npx wscat -c ws://localhost:6505
```

### RAGy Commands

```bash
# Navigate to RAGy
cd /Users/tomeryud/projects/RAGy

# Start RAGy (includes MCP servers)
npm run dev
```

---

## Summary

This project creates a clean, modular bridge between Godot and RAGy:

1. **MCP Server (Node.js):** Speaks MCP to RAGy, WebSocket to Godot
2. **Godot Plugin (GDScript):** Minimal, focused on tool execution
3. **Architecture:** Clean separation, reusable, testable

Follow the phases in order, testing each before moving to the next. Use the old godot-ai-assistant as reference for tool implementations but don't modify it.

Start with Phase 1: Create the skeleton MCP server with mock tools.
