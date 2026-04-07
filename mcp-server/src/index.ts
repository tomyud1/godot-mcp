#!/usr/bin/env node
/**
 * Godot MCP Server
 *
 * An MCP server that provides Godot game engine tools to AI assistants.
 * Works with Claude Desktop, Cursor, Codex, or any MCP-compatible client.
 *
 * Architecture (connect-or-spawn):
 *   When started, the server probes for an existing primary instance.
 *   - If found  → enters PROXY mode (forwards tool calls via HTTP)
 *   - If absent → enters PRIMARY mode (owns Godot bridge + HTTP API)
 *
 * Primary mode:
 *   - WebSocket server on port 6505 for Godot plugin communication
 *   - HTTP server on port 6506 for proxy instances
 *   - MCP protocol via stdio for the launching AI client
 *
 * Proxy mode:
 *   - MCP protocol via stdio for the launching AI client
 *   - Forwards tool calls to the primary via HTTP
 */

import { Server } from '@modelcontextprotocol/sdk/server/index.js';
import { StdioServerTransport } from '@modelcontextprotocol/sdk/server/stdio.js';
import {
  CallToolRequestSchema,
  ListToolsRequestSchema,
  ErrorCode,
  McpError
} from '@modelcontextprotocol/sdk/types.js';

import { execSync } from 'child_process';
import { allTools, toolExists } from './tools/index.js';
import { GodotBridge } from './godot-bridge.js';
import { serveVisualization, stopVisualizationServer, setGodotBridge } from './visualizer-server.js';
import { PrimaryHttpServer, type ToolCallResult } from './primary-http.js';
import { probeExistingServer, proxyToolCall, registerProxyClient, unregisterProxyClient } from './proxy-client.js';

// ---------------------------------------------------------------------------
// Configuration
// ---------------------------------------------------------------------------

const SERVER_NAME = 'godot-mcp-server';
const SERVER_VERSION = '0.4.1';
const WEBSOCKET_PORT = parseInt(process.env.GODOT_MCP_PORT || '6505', 10);
const HTTP_PORT = parseInt(process.env.GODOT_MCP_HTTP_PORT || '6506', 10);
const TOOL_TIMEOUT = parseInt(process.env.GODOT_MCP_TIMEOUT_MS || '30000', 10);
const IDLE_TIMEOUT = parseInt(process.env.GODOT_MCP_IDLE_TIMEOUT_MS || '30000', 10);

const args = process.argv.slice(2);
const noForce = args.includes('--no-force');

// ---------------------------------------------------------------------------
// Tool execution (shared logic used by both primary MCP handler & HTTP API)
// ---------------------------------------------------------------------------

let godotBridge: GodotBridge | null = null;

async function executeToolCall(
  name: string,
  toolArgs: Record<string, unknown>
): Promise<ToolCallResult> {
  if (name === 'get_godot_status') {
    const status = godotBridge!.getStatus();
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

  if (!toolExists(name)) {
    throw new McpError(
      ErrorCode.MethodNotFound,
      `Unknown tool: ${name}. Available tools: ${allTools.map(t => t.name).join(', ')}`
    );
  }

  if (!godotBridge!.isConnected()) {
    return {
      content: [{
        type: 'text',
        text: JSON.stringify({
          error: 'Godot editor is not connected',
          tool: name,
          hint: `Open a Godot project with the MCP plugin enabled. The plugin will auto-connect to this server on port ${WEBSOCKET_PORT}.`
        }, null, 2)
      }],
      isError: true
    };
  }

  try {
    const result = await godotBridge!.invokeTool(name, toolArgs);

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
          args: toolArgs,
          mode: 'live',
          hint: 'The tool call was sent to Godot but failed. Check Godot editor for details.'
        }, null, 2)
      }],
      isError: true
    };
  }
}

// ---------------------------------------------------------------------------
// MCP server factory (creates an MCP Server wired to a tool handler)
// ---------------------------------------------------------------------------

type ToolHandler = (name: string, args: Record<string, unknown>) => Promise<ToolCallResult>;

function createMcpServer(handleTool: ToolHandler): Server {
  const server = new Server(
    { name: SERVER_NAME, version: SERVER_VERSION },
    { capabilities: { tools: {} } }
  );

  server.setRequestHandler(ListToolsRequestSchema, async () => {
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
    const result = await handleTool(name, (args || {}) as Record<string, unknown>);
    return result as { content: Array<{ type: string; text: string }>; isError?: boolean; [key: string]: unknown };
  });

  return server;
}

// ---------------------------------------------------------------------------
// Kill process on port (only used as last resort)
// ---------------------------------------------------------------------------

async function killProcessOnPort(port: number): Promise<boolean> {
  try {
    const platform = process.platform;
    let pid: string | undefined;

    if (platform === 'win32') {
      const output = execSync(
        `netstat -ano | findstr :${port} | findstr LISTENING`,
        { encoding: 'utf-8', stdio: ['pipe', 'pipe', 'pipe'] }
      );
      const match = output.trim().split('\n')[0]?.match(/\s+(\d+)\s*$/);
      pid = match?.[1];
    } else {
      const output = execSync(
        `lsof -ti :${port}`,
        { encoding: 'utf-8', stdio: ['pipe', 'pipe', 'pipe'] }
      );
      pid = output.trim().split('\n')[0];
    }

    if (pid) {
      const pidNum = parseInt(pid, 10);
      if (pidNum === process.pid) return false;
      console.error(`[${SERVER_NAME}] Killing existing process on port ${port} (PID ${pid})...`);
      process.kill(pidNum, 'SIGTERM');
      await new Promise(resolve => setTimeout(resolve, 1500));
      return true;
    }
  } catch {
    // No process on port, or kill failed — proceed
  }
  return false;
}

// ---------------------------------------------------------------------------
// PRIMARY MODE
// ---------------------------------------------------------------------------

async function startPrimary(): Promise<void> {
  console.error(`[${SERVER_NAME}] Starting in PRIMARY mode v${SERVER_VERSION}...`);

  godotBridge = new GodotBridge(WEBSOCKET_PORT, TOOL_TIMEOUT);
  setGodotBridge(godotBridge);

  godotBridge.onConnectionChange((connected) => {
    if (connected) {
      console.error(`[${SERVER_NAME}] Godot connected`);
      cancelIdleShutdown();
      notifyClientStatus(); // send current client count immediately on connect
    } else {
      console.error(`[${SERVER_NAME}] Godot disconnected`);
      maybeStartIdleShutdown();
    }
  });

  // --- Start WebSocket bridge ---
  if (!noForce) {
    await killProcessOnPort(WEBSOCKET_PORT);
  }

  try {
    await godotBridge.start();
    console.error(`[${SERVER_NAME}] WebSocket server listening on port ${WEBSOCKET_PORT}`);
  } catch (error: unknown) {
    const err = error as NodeJS.ErrnoException;
    if (err.code === 'EADDRINUSE') {
      // Race condition: another instance may have just started.
      // Retry probe with delays — the winner needs time to start its HTTP server.
      console.error(`[${SERVER_NAME}] Port ${WEBSOCKET_PORT} in use, re-probing for primary...`);
      for (let attempt = 0; attempt < 3; attempt++) {
        await new Promise(resolve => setTimeout(resolve, 500 * (attempt + 1)));
        const retry = await probeExistingServer(HTTP_PORT);
        if (retry.alive) {
          console.error(`[${SERVER_NAME}] Primary appeared during startup, switching to proxy mode`);
          godotBridge.stop();
          godotBridge = null;
          return startProxy();
        }
      }

      // Genuinely stuck — kill and retry once
      console.error(`[${SERVER_NAME}] No healthy primary found, killing zombie on port ${WEBSOCKET_PORT}...`);
      await killProcessOnPort(WEBSOCKET_PORT);
      try {
        await godotBridge.start();
        console.error(`[${SERVER_NAME}] WebSocket server listening on port ${WEBSOCKET_PORT} (after retry)`);
      } catch {
        console.error(`[${SERVER_NAME}] ❌ Port ${WEBSOCKET_PORT} still unavailable after retry.`);
        console.error(`[${SERVER_NAME}] To fix:  lsof -ti :${WEBSOCKET_PORT} | xargs kill`);
        console.error(`[${SERVER_NAME}] Continuing without Godot bridge — tools will error.`);
      }
    } else {
      console.error(`[${SERVER_NAME}] Failed to start WebSocket server:`, error);
    }
  }

  // --- Track AI client count and push status to Godot ---
  let directClientConnected = true; // stdin is open when we start = 1 direct client

  function notifyClientStatus(): void {
    const total = (directClientConnected ? 1 : 0) + httpServer.getProxyClientCount();
    godotBridge?.sendClientStatus(total);
  }

  // --- Start HTTP server for proxies ---
  const httpServer = new PrimaryHttpServer(HTTP_PORT, SERVER_VERSION, executeToolCall);
  httpServer.setClientCountChangeCallback(() => notifyClientStatus());

  try {
    await httpServer.start();
    console.error(`[${SERVER_NAME}] HTTP bridge listening on port ${HTTP_PORT}`);
  } catch (error: unknown) {
    const err = error as NodeJS.ErrnoException;
    if (err.code === 'EADDRINUSE') {
      await killProcessOnPort(HTTP_PORT);
      try {
        await httpServer.start();
        console.error(`[${SERVER_NAME}] HTTP bridge listening on port ${HTTP_PORT} (after retry)`);
      } catch {
        console.error(`[${SERVER_NAME}] ❌ Port ${HTTP_PORT} unavailable. Proxies won't be able to connect.`);
      }
    } else {
      console.error(`[${SERVER_NAME}] Failed to start HTTP bridge:`, error);
    }
  }

  // --- Verify at least one server is listening ---
  const webSocketListening = godotBridge.getStatus().port > 0;
  const httpListening = httpServer.isListening();

  if (!webSocketListening && !httpListening) {
    console.error(`[${SERVER_NAME}] ❌ Fatal: Neither WebSocket nor HTTP server started.`);
    console.error(`[${SERVER_NAME}] WebSocket server (port ${WEBSOCKET_PORT}): ${webSocketListening ? 'OK' : 'FAILED'}`);
    console.error(`[${SERVER_NAME}] HTTP server (port ${HTTP_PORT}): ${httpListening ? 'OK' : 'FAILED'}`);
    console.error(`[${SERVER_NAME}] Check for port conflicts, permissions, or network issues.`);
    console.error(`[${SERVER_NAME}] Cannot continue without at least one listening server.`);
    godotBridge?.stop();
    httpServer.stop();
    process.exit(1);
  }

  if (!webSocketListening) {
    console.error(`[${SERVER_NAME}] ⚠️  WebSocket server failed to start. Godot connection will not work.`);
  }
  if (!httpListening) {
    console.error(`[${SERVER_NAME}] ⚠️  HTTP server failed to start. Proxy clients will not be able to connect.`);
  }

  console.error(`[${SERVER_NAME}] Available tools: ${allTools.length + 1}`);
  console.error(`[${SERVER_NAME}] Waiting for Godot editor connection...`);

  // --- Connect stdio MCP transport ---
  const server = createMcpServer(executeToolCall);
  const transport = new StdioServerTransport();
  await server.connect(transport);
  console.error(`[${SERVER_NAME}] MCP server connected and ready`);

  // --- Shutdown logic ---
  // In primary mode, stdin close does NOT kill the server.
  // The server stays alive for proxy clients and Godot.
  // Only an idle timeout (no Godot + no HTTP activity) triggers shutdown.
  let stdinClosed = false;

  process.stdin.on('close', () => {
    stdinClosed = true;
    directClientConnected = false;
    console.error(`[${SERVER_NAME}] Direct MCP client disconnected (stdin closed)`);
    notifyClientStatus();
    maybeStartIdleShutdown();
  });

  let idleTimer: NodeJS.Timeout | null = null;

  function maybeStartIdleShutdown(): void {
    if (idleTimer) return; // already scheduled
    if (godotBridge?.isConnected()) return;
    if (!stdinClosed) return;

    const msSinceHttpActivity = Date.now() - httpServer.getLastActivityTime();
    if (msSinceHttpActivity < IDLE_TIMEOUT) {
      // HTTP was recently active — schedule re-check for when the idle window expires
      const recheckIn = IDLE_TIMEOUT - msSinceHttpActivity + 500;
      idleTimer = setTimeout(() => {
        idleTimer = null;
        maybeStartIdleShutdown();
      }, recheckIn);
      return;
    }

    console.error(`[${SERVER_NAME}] No active connections, shutting down in ${IDLE_TIMEOUT / 1000}s...`);
    idleTimer = setTimeout(() => {
      // Re-check before actually exiting
      if (godotBridge?.isConnected()) {
        idleTimer = null;
        maybeStartIdleShutdown();
        return;
      }
      const stillHttpIdle = (Date.now() - httpServer.getLastActivityTime()) > IDLE_TIMEOUT;
      if (!stillHttpIdle) {
        idleTimer = null;
        maybeStartIdleShutdown();
        return;
      }
      shutdown();
    }, IDLE_TIMEOUT);
  }

  function cancelIdleShutdown(): void {
    if (idleTimer) {
      clearTimeout(idleTimer);
      idleTimer = null;
      console.error(`[${SERVER_NAME}] Idle shutdown cancelled — connection active`);
    }
  }

  let isShuttingDown = false;
  function shutdown(): void {
    if (isShuttingDown) return;
    isShuttingDown = true;
    console.error(`[${SERVER_NAME}] Shutting down...`);
    if (idleTimer) clearTimeout(idleTimer);
    stopVisualizationServer();
    httpServer.stop();
    godotBridge?.stop();
    process.exit(0);
  }

  process.on('SIGINT', shutdown);
  process.on('SIGTERM', shutdown);
}

// ---------------------------------------------------------------------------
// PROXY MODE
// ---------------------------------------------------------------------------

async function startProxy(): Promise<void> {
  console.error(`[${SERVER_NAME}] Starting in PROXY mode v${SERVER_VERSION} (primary on port ${HTTP_PORT})...`);

  const handleTool: ToolHandler = async (name, args) => {
    try {
      return await proxyToolCall(HTTP_PORT, name, args, TOOL_TIMEOUT);
    } catch (error) {
      const msg = error instanceof Error ? error.message : String(error);
      return {
        content: [{
          type: 'text',
          text: JSON.stringify({
            error: `Failed to reach primary server: ${msg}`,
            hint: 'The primary godot-mcp-server may have shut down. Restart your AI client to spawn a new one.'
          }, null, 2)
        }],
        isError: true
      };
    }
  };

  const server = createMcpServer(handleTool);
  const transport = new StdioServerTransport();
  await server.connect(transport);
  console.error(`[${SERVER_NAME}] Proxy MCP server connected and ready`);

  await registerProxyClient(HTTP_PORT);

  // In proxy mode, stdin close means our client is gone. Exit cleanly.
  let isShuttingDown = false;
  async function shutdown(): Promise<void> {
    if (isShuttingDown) return;
    isShuttingDown = true;
    console.error(`[${SERVER_NAME}] Proxy shutting down...`);
    await unregisterProxyClient(HTTP_PORT);
    process.exit(0);
  }

  process.stdin.on('close', shutdown);
  process.on('SIGINT', shutdown);
  process.on('SIGTERM', shutdown);
}

// ---------------------------------------------------------------------------
// Entry point
// ---------------------------------------------------------------------------

async function main(): Promise<void> {
  // Step 1: Probe for an existing primary server
  const probe = await probeExistingServer(HTTP_PORT);

  if (probe.alive) {
    console.error(`[${SERVER_NAME}] Found existing primary server (v${probe.version})`);
    return startProxy();
  }

  // Step 2: No primary found — become primary
  return startPrimary();
}

main().catch((error) => {
  console.error(`[${SERVER_NAME}] Fatal error:`, error);
  process.exit(1);
});
