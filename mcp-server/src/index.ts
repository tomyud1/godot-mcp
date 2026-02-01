#!/usr/bin/env node
/**
 * Godot MCP Server
 *
 * An MCP server that provides Godot game engine tools to AI assistants.
 * Works with Claude Desktop, RAGy, or any MCP-compatible client.
 *
 * Architecture:
 * - MCP protocol via stdio (for AI client communication)
 * - WebSocket server on port 6505 (for Godot plugin communication)
 *
 * Modes:
 * - Mock mode: Returns fake data when Godot is not connected
 * - Live mode: Routes tool calls to Godot plugin via WebSocket
 */

import { Server } from '@modelcontextprotocol/sdk/server/index.js';
import { StdioServerTransport } from '@modelcontextprotocol/sdk/server/stdio.js';
import {
  CallToolRequestSchema,
  ListToolsRequestSchema,
  ErrorCode,
  McpError
} from '@modelcontextprotocol/sdk/types.js';

import { allTools, getMockToolResponse, toolExists } from './tools/index.js';
import { GodotBridge } from './godot-bridge.js';
import { serveVisualization, stopVisualizationServer, setGodotBridge } from './visualizer-server.js';

// Server metadata
const SERVER_NAME = 'godot-mcp-server';
const SERVER_VERSION = '0.2.0';
const WEBSOCKET_PORT = 6505;

// Create MCP server
const server = new Server(
  { name: SERVER_NAME, version: SERVER_VERSION },
  { capabilities: { tools: {} } }
);

// Create Godot bridge (WebSocket server)
const godotBridge = new GodotBridge(WEBSOCKET_PORT);

// Set the bridge reference for the visualizer server
setGodotBridge(godotBridge);

// Log connection changes
godotBridge.onConnectionChange((connected, info) => {
  if (connected) {
    console.error(`[${SERVER_NAME}] Godot connected`);
  } else {
    console.error(`[${SERVER_NAME}] Godot disconnected`);
  }
});

/**
 * Handle ListTools request - returns all available tools
 */
server.setRequestHandler(ListToolsRequestSchema, async () => {
  // Add connection status tool dynamically
  const connectionStatusTool = {
    name: 'get_godot_status',
    description: 'Check if Godot editor is connected to the MCP server. Use this before attempting Godot operations to see if you\'ll get real or mock data.',
    inputSchema: {
      type: 'object' as const,
      properties: {},
      required: []
    }
  };

  return {
    tools: [
      connectionStatusTool,
      ...allTools.map(tool => ({
        name: tool.name,
        description: tool.description,
        inputSchema: tool.inputSchema
      }))
    ]
  };
});

/**
 * Handle CallTool request - executes a tool
 */
server.setRequestHandler(CallToolRequestSchema, async (request) => {
  const { name, arguments: args } = request.params;
  const toolArgs = (args || {}) as Record<string, unknown>;

  // Handle connection status check
  if (name === 'get_godot_status') {
    const status = godotBridge.getStatus();
    return {
      content: [{
        type: 'text',
        text: JSON.stringify({
          connected: status.connected,
          server_version: SERVER_VERSION,
          websocket_port: status.port,
          mode: status.connected ? 'live' : 'mock',
          project_path: status.projectPath || null,
          connected_at: status.connectedAt?.toISOString() || null,
          pending_requests: status.pendingRequests,
          message: status.connected
            ? `Godot is connected${status.projectPath ? ` (${status.projectPath})` : ''}. Tools will execute in the Godot editor.`
            : 'Godot is not connected. Tools will return mock data. Open a Godot project with the MCP plugin enabled to connect.'
        }, null, 2)
      }]
    };
  }

  // Validate tool exists
  if (!toolExists(name)) {
    throw new McpError(
      ErrorCode.MethodNotFound,
      `Unknown tool: ${name}. Available tools: ${allTools.map(t => t.name).join(', ')}`
    );
  }

  try {
    let result: unknown;

    if (godotBridge.isConnected()) {
      // Live mode: Route to Godot via WebSocket
      try {
        result = await godotBridge.invokeTool(name, toolArgs);
      } catch (error) {
        // If Godot call fails, return error (don't fall back to mock)
        const errorMessage = error instanceof Error ? error.message : String(error);
        return {
          content: [{
            type: 'text',
            text: JSON.stringify({
              error: errorMessage,
              tool: name,
              args: toolArgs,
              mode: 'live',
              hint: 'The tool call was sent to Godot but failed. Check Godot editor for details.'
            }, null, 2)
          }],
          isError: true
        };
      }
    } else {
      // Mock mode: Return fake data
      result = getMockToolResponse(name, toolArgs);
    }

    // Post-processing for visualization tools
    if (name === 'map_project' && result && typeof result === 'object' && 'project_map' in (result as Record<string, unknown>)) {
      try {
        const projectMap = (result as Record<string, unknown>).project_map;
        const url = await serveVisualization(projectMap);
        return {
          content: [{
            type: 'text',
            text: JSON.stringify({
              ...(result as Record<string, unknown>),
              visualization_url: url,
              message: `Project mapped: ${(projectMap as any).total_scripts} scripts, ${(projectMap as any).total_connections} connections. Interactive visualization opened in browser at ${url}`
            }, null, 2)
          }]
        };
      } catch (vizError) {
        // If visualization fails, still return the data
        console.error(`[${SERVER_NAME}] Visualization failed:`, vizError);
      }
    }

    return {
      content: [{
        type: 'text',
        text: JSON.stringify(result, null, 2)
      }]
    };
  } catch (error) {
    const errorMessage = error instanceof Error ? error.message : String(error);
    return {
      content: [{
        type: 'text',
        text: JSON.stringify({
          error: errorMessage,
          tool: name,
          args: toolArgs
        }, null, 2)
      }],
      isError: true
    };
  }
});

/**
 * Start the MCP server and WebSocket bridge
 */
async function main() {
  // Log to stderr (stdout is reserved for MCP protocol)
  console.error(`[${SERVER_NAME}] Starting MCP server v${SERVER_VERSION}...`);

  // Start WebSocket server for Godot communication
  try {
    await godotBridge.start();
    console.error(`[${SERVER_NAME}] WebSocket server listening on port ${WEBSOCKET_PORT}`);
  } catch (error) {
    console.error(`[${SERVER_NAME}] Failed to start WebSocket server:`, error);
    console.error(`[${SERVER_NAME}] Continuing in mock-only mode`);
  }

  console.error(`[${SERVER_NAME}] Available tools: ${allTools.length + 1}`);
  console.error(`[${SERVER_NAME}] Mode: mock (waiting for Godot connection)`);

  // Start MCP server (stdio transport)
  const transport = new StdioServerTransport();
  await server.connect(transport);

  console.error(`[${SERVER_NAME}] MCP server connected and ready`);
}

// Handle graceful shutdown
function shutdown() {
  console.error(`[${SERVER_NAME}] Shutting down...`);
  stopVisualizationServer();
  godotBridge.stop();
  process.exit(0);
}

process.on('SIGINT', shutdown);
process.on('SIGTERM', shutdown);

// Run
main().catch((error) => {
  console.error(`[${SERVER_NAME}] Fatal error:`, error);
  process.exit(1);
});
