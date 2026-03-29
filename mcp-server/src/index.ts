#!/usr/bin/env node
/**
 * Godot MCP Server
 *
 * An MCP server that provides Godot game engine tools to AI assistants.
 * Works with Claude Desktop, Claude Code, Cursor, or any MCP-compatible client.
 *
 * ## Architecture
 *
 *   AI clients ──(MCP protocol)──▶ this server ──(WebSocket)──▶ Godot plugin
 *
 * The server bridges two protocols:
 * - **MCP side**: Receives tool calls from AI clients via stdio or HTTP
 * - **Godot side**: Routes tool calls to the Godot editor plugin via WebSocket on port 6505
 *
 * ## Transport modes
 *
 * **stdio (default)** — One server process per AI client session. The AI client
 * spawns this process and communicates via stdin/stdout. When the client exits,
 * stdin closes and the server shuts down. Simple but limited to a single session.
 *
 * **--http (daemon mode)** — A persistent process that serves multiple AI client
 * sessions simultaneously over HTTP (Streamable HTTP transport, MCP spec). Each
 * session gets its own MCP Server instance but they all share the same Godot
 * WebSocket bridge. The daemon auto-exits when Godot disconnects and no clients
 * reconnect within the idle timeout (default 30s).
 *
 * ## CLI flags
 *
 * - `--http`      Enable HTTP daemon mode (default: stdio)
 * - `--no-force`  Don't kill existing processes on the WebSocket/HTTP ports
 *
 * ## Environment variables
 *
 * - `GODOT_MCP_HTTP_PORT`      HTTP port for MCP clients in daemon mode (default: 6506)
 * - `GODOT_MCP_IDLE_TIMEOUT_MS` Idle shutdown grace period in ms (default: 30000)
 */

import { Server } from '@modelcontextprotocol/sdk/server/index.js';
import { StdioServerTransport } from '@modelcontextprotocol/sdk/server/stdio.js';
import { StreamableHTTPServerTransport } from '@modelcontextprotocol/sdk/server/streamableHttp.js';
import { createMcpExpressApp } from '@modelcontextprotocol/sdk/server/express.js';
import {
  CallToolRequestSchema,
  ListToolsRequestSchema,
  ErrorCode,
  McpError,
  isInitializeRequest
} from '@modelcontextprotocol/sdk/types.js';

import { randomUUID } from 'node:crypto';
import { execSync } from 'child_process';
import { allTools, toolExists } from './tools/index.js';
import { GodotBridge } from './godot-bridge.js';
import { serveVisualization, stopVisualizationServer, setGodotBridge } from './visualizer-server.js';

// Server metadata
const SERVER_NAME = 'godot-mcp-server';
const SERVER_VERSION = '0.2.8';
const WEBSOCKET_PORT = 6505;
const MCP_HTTP_PORT = parseInt(process.env.GODOT_MCP_HTTP_PORT || '6506', 10);

// CLI args
const cliArgs = process.argv.slice(2);
const noForce = cliArgs.includes('--no-force');
const httpMode = cliArgs.includes('--http');

// Create Godot bridge (WebSocket server) — shared across all sessions
const godotBridge = new GodotBridge(WEBSOCKET_PORT);

// Set the bridge reference for the visualizer server
setGodotBridge(godotBridge);

/**
 * Idle auto-shutdown for HTTP daemon mode.
 *
 * When running as a daemon (--http), the server should not persist indefinitely
 * after all clients disconnect. The shutdown is keyed on Godot presence because
 * without Godot, tool calls return errors — there's nothing to bridge.
 *
 * A grace period (default 30s) allows Godot to reconnect during plugin reloads,
 * project switches, or editor restarts without requiring a new daemon spawn.
 */
const IDLE_SHUTDOWN_MS = parseInt(process.env.GODOT_MCP_IDLE_TIMEOUT_MS || '30000', 10);
let idleShutdownTimer: ReturnType<typeof setTimeout> | null = null;

function checkIdleShutdown(): void {
  if (!httpMode) return;

  const hasGodot = godotBridge.isConnected();

  if (!hasGodot) {
    if (!idleShutdownTimer) {
      console.error(`[${SERVER_NAME}] No Godot connection — shutting down in ${IDLE_SHUTDOWN_MS / 1000}s`);
      idleShutdownTimer = setTimeout(() => {
        if (!godotBridge.isConnected()) {
          console.error(`[${SERVER_NAME}] Idle timeout reached — exiting`);
          shutdown();
        }
      }, IDLE_SHUTDOWN_MS);
    }
  } else if (idleShutdownTimer) {
    console.error(`[${SERVER_NAME}] Godot reconnected — idle shutdown cancelled`);
    clearTimeout(idleShutdownTimer);
    idleShutdownTimer = null;
  }
}

// Log connection changes and check idle state
godotBridge.onConnectionChange((connected, info) => {
  if (connected) {
    console.error(`[${SERVER_NAME}] Godot connected`);
  } else {
    console.error(`[${SERVER_NAME}] Godot disconnected`);
  }
  checkIdleShutdown();
});

/**
 * Create and configure a new MCP Server instance with all tool handlers.
 *
 * In HTTP daemon mode, each client session gets its own Server instance (as
 * required by the MCP SDK's transport model), but they all share the single
 * godotBridge for routing tool calls to Godot. In stdio mode, only one Server
 * is created for the lifetime of the process.
 */
function createMcpServer(): Server {
  const server = new Server(
    { name: SERVER_NAME, version: SERVER_VERSION },
    { capabilities: { tools: {} } }
  );

  server.setRequestHandler(ListToolsRequestSchema, async () => {
  // Add connection status tool dynamically
  const connectionStatusTool = {
    name: 'get_godot_status',
    description: 'Check if Godot editor is connected to the MCP server.',
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
          mode: status.connected ? 'live' : 'waiting',
          project_path: status.projectPath || null,
          connected_at: status.connectedAt?.toISOString() || null,
          pending_requests: status.pendingRequests,
          message: status.connected
            ? `Godot is connected${status.projectPath ? ` (${status.projectPath})` : ''}. Tools will execute in the Godot editor.`
            : 'Godot is not connected. Open a Godot project with the MCP plugin enabled to connect.'
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
      return {
        content: [{
          type: 'text',
          text: JSON.stringify({
            error: 'Godot editor is not connected',
            tool: name,
            hint: 'Open a Godot project with the MCP plugin enabled. The plugin will auto-connect to this server on port ' + WEBSOCKET_PORT + '.'
          }, null, 2)
        }],
        isError: true
      };
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

  return server;
}

/**
 * Kill any process currently listening on the given port.
 * Returns true if a process was killed, false otherwise.
 */
function killProcessOnPort(port: number): boolean {
  try {
    const platform = process.platform;
    let pid: string | undefined;

    if (platform === 'win32') {
      const output = execSync(`netstat -ano | findstr :${port} | findstr LISTENING`, { encoding: 'utf-8', stdio: ['pipe', 'pipe', 'pipe'] });
      const match = output.trim().split('\n')[0]?.match(/\s+(\d+)\s*$/);
      pid = match?.[1];
    } else {
      const output = execSync(`lsof -ti :${port}`, { encoding: 'utf-8', stdio: ['pipe', 'pipe', 'pipe'] });
      pid = output.trim().split('\n')[0];
    }

    if (pid) {
      const pidNum = parseInt(pid, 10);
      if (pidNum === process.pid) return false;
      console.error(`[${SERVER_NAME}] Killing existing process on port ${port} (PID ${pid})...`);
      process.kill(pidNum, 'SIGTERM');
      // Brief wait for the port to be released
      execSync('sleep 1');
      return true;
    }
  } catch {
    // No process on port, or kill failed — either way, proceed
  }
  return false;
}

/**
 * Active HTTP sessions, keyed by MCP session ID.
 *
 * Each session holds a StreamableHTTPServerTransport (handles HTTP ↔ MCP
 * protocol) and a Server (handles tool routing). When a client sends a DELETE
 * or the transport closes, the session is removed and its Server is closed.
 */
interface HttpSession {
  transport: StreamableHTTPServerTransport;
  server: Server;
}
const httpSessions: Record<string, HttpSession> = {};

/**
 * Start the MCP server and WebSocket bridge
 */
async function main() {
  const modeLabel = httpMode ? 'HTTP daemon' : 'stdio';
  console.error(`[${SERVER_NAME}] Starting MCP server v${SERVER_VERSION} (${modeLabel} mode)...`);

  // Always clear the WebSocket port unless --no-force is passed.
  if (!noForce) {
    killProcessOnPort(WEBSOCKET_PORT);
    if (httpMode) {
      killProcessOnPort(MCP_HTTP_PORT);
    }
  }

  // Start WebSocket server for Godot communication
  try {
    await godotBridge.start();
    console.error(`[${SERVER_NAME}] WebSocket server listening on port ${WEBSOCKET_PORT}`);
  } catch (error: unknown) {
    const err = error as NodeJS.ErrnoException;
    if (err.code === 'EADDRINUSE') {
      console.error(`\n[${SERVER_NAME}] ❌ ERROR: Port ${WEBSOCKET_PORT} is already in use!`);
      console.error(`[${SERVER_NAME}] Another process is running on this port and could not be killed.`);
      console.error(`[${SERVER_NAME}] Godot will connect to the OTHER process, not this one.`);
      console.error(`[${SERVER_NAME}]`);
      console.error(`[${SERVER_NAME}] To fix manually:  lsof -ti :${WEBSOCKET_PORT} | xargs kill`);
      console.error(`[${SERVER_NAME}]`);
      console.error(`[${SERVER_NAME}] Godot CANNOT connect to this instance.\n`);
    } else {
      console.error(`[${SERVER_NAME}] Failed to start WebSocket server:`, error);
      console.error(`[${SERVER_NAME}] WebSocket disabled — tools will return errors until Godot connects.`);
    }
  }

  console.error(`[${SERVER_NAME}] Available tools: ${allTools.length + 1}`);
  console.error(`[${SERVER_NAME}] Waiting for Godot editor connection...`);

  if (httpMode) {
    // ── HTTP daemon mode ──────────────────────────────────────────────
    // Serves multiple AI clients simultaneously via Streamable HTTP transport.
    // Each POST /mcp with no session ID + an initialize request creates a new
    // session. Subsequent requests include the mcp-session-id header to reuse
    // the existing session. GET /mcp opens an SSE stream for server-initiated
    // messages. DELETE /mcp terminates a session.
    const MCP_HOST = '127.0.0.1';
    const app = createMcpExpressApp({ host: MCP_HOST });

    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    app.post('/mcp', async (req: any, res: any) => {
      const sessionId = req.headers['mcp-session-id'] as string | undefined;

      try {
        if (sessionId && httpSessions[sessionId]) {
          await httpSessions[sessionId].transport.handleRequest(req, res, req.body);
          return;
        }

        if (!sessionId && isInitializeRequest(req.body)) {
          const mcpServer = createMcpServer();
          const transport = new StreamableHTTPServerTransport({
            sessionIdGenerator: () => randomUUID(),
            onsessioninitialized: (sid) => {
              console.error(`[${SERVER_NAME}] HTTP session initialized: ${sid}`);
              httpSessions[sid] = { transport, server: mcpServer };
              checkIdleShutdown();
            }
          });

          transport.onclose = () => {
            const sid = transport.sessionId;
            if (sid && httpSessions[sid]) {
              console.error(`[${SERVER_NAME}] HTTP session closed: ${sid}`);
              const session = httpSessions[sid];
              delete httpSessions[sid];
              session.server.close();
            }
            checkIdleShutdown();
          };

          await mcpServer.connect(transport);
          await transport.handleRequest(req, res, req.body);
          return;
        }

        res.status(400).json({
          jsonrpc: '2.0',
          error: { code: -32000, message: 'Bad Request: No valid session ID provided' },
          id: null
        });
      } catch (error) {
        console.error(`[${SERVER_NAME}] Error handling MCP request:`, error);
        if (!res.headersSent) {
          res.status(500).json({
            jsonrpc: '2.0',
            error: { code: -32603, message: 'Internal server error' },
            id: null
          });
        }
      }
    });

    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    app.get('/mcp', async (req: any, res: any) => {
      const sessionId = req.headers['mcp-session-id'] as string | undefined;
      if (!sessionId || !httpSessions[sessionId]) {
        res.status(400).send('Invalid or missing session ID');
        return;
      }
      await httpSessions[sessionId].transport.handleRequest(req, res);
    });

    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    app.delete('/mcp', async (req: any, res: any) => {
      const sessionId = req.headers['mcp-session-id'] as string | undefined;
      if (!sessionId || !httpSessions[sessionId]) {
        res.status(400).send('Invalid or missing session ID');
        return;
      }
      await httpSessions[sessionId].transport.handleRequest(req, res);
    });

    app.listen(MCP_HTTP_PORT, MCP_HOST, () => {
      console.error(`[${SERVER_NAME}] HTTP MCP server listening on http://${MCP_HOST}:${MCP_HTTP_PORT}/mcp`);
      console.error(`[${SERVER_NAME}] Multiple AI clients can connect simultaneously`);
      checkIdleShutdown();
    });
  } else {
    // stdio mode — single-session (original behavior)
    const server = createMcpServer();
    const transport = new StdioServerTransport();
    await server.connect(transport);
    console.error(`[${SERVER_NAME}] MCP server connected and ready (stdio)`);
  }
}

// Handle graceful shutdown
let isShuttingDown = false;
async function shutdown() {
  if (isShuttingDown) return;
  isShuttingDown = true;
  console.error(`[${SERVER_NAME}] Shutting down...`);

  for (const sessionId of Object.keys(httpSessions)) {
    try {
      await httpSessions[sessionId].transport.close();
      await httpSessions[sessionId].server.close();
      delete httpSessions[sessionId];
    } catch (error) {
      console.error(`[${SERVER_NAME}] Error closing session ${sessionId}:`, error);
    }
  }

  stopVisualizationServer();
  godotBridge.stop();
  process.exit(0);
}

process.on('SIGINT', shutdown);
process.on('SIGTERM', shutdown);

// In stdio mode, shutdown when the AI client closes stdin.
// In HTTP mode, stdin isn't used — the daemon stays alive until SIGINT/SIGTERM.
if (!httpMode) {
  process.stdin.on('close', shutdown);
}

// Run
main().catch((error) => {
  console.error(`[${SERVER_NAME}] Fatal error:`, error);
  process.exit(1);
});
