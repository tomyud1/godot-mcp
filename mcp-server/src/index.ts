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

import { execSync, spawn } from 'child_process';
import { existsSync } from 'fs';
import { join } from 'path';
import { allTools, toolExists } from './tools/index.js';
import { GodotBridge } from './godot-bridge.js';
import { serveVisualization, stopVisualizationServer, setGodotBridge } from './visualizer-server.js';

// Server metadata
const SERVER_NAME = 'godot-mcp-server';
const SERVER_VERSION = '0.2.7';
const WEBSOCKET_PORT = 6505;

// CLI args
const args = process.argv.slice(2);
const noForce = args.includes('--no-force');

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

  // Handle run_scene — spawns a headless subprocess, bypasses the bridge
  if (name === 'run_scene') {
    return handleRunScene(toolArgs, godotBridge);
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
 * Locate the Godot executable.
 * Search order:
 *   1. GODOT_PATH env var (explicit override, best for CI)
 *   2. GODOT4_PATH env var (common alias)
 *   3. `godot4` / `godot` on PATH
 *   4. Platform-specific default install locations
 */
function findGodotExecutable(): string | null {
  // Env overrides
  const envPath = process.env.GODOT_PATH || process.env.GODOT4_PATH;
  if (envPath && existsSync(envPath)) return envPath;

  // PATH candidates
  const pathCandidates = ['godot4', 'godot'];
  for (const bin of pathCandidates) {
    try {
      const found = execSync(
        process.platform === 'win32' ? `where ${bin}` : `which ${bin}`,
        { encoding: 'utf-8', stdio: ['pipe', 'pipe', 'pipe'] }
      ).trim().split('\n')[0];
      if (found && existsSync(found)) return found;
    } catch {
      // not on PATH — continue
    }
  }

  // Platform-specific defaults
  if (process.platform === 'darwin') {
    const macPaths = [
      '/Applications/Godot.app/Contents/MacOS/Godot',
      '/Applications/Godot_v4.app/Contents/MacOS/Godot',
    ];
    for (const p of macPaths) {
      if (existsSync(p)) return p;
    }
  } else if (process.platform === 'linux') {
    const linuxPaths = ['/usr/bin/godot4', '/usr/bin/godot', '/usr/local/bin/godot4', '/usr/local/bin/godot'];
    for (const p of linuxPaths) {
      if (existsSync(p)) return p;
    }
  } else if (process.platform === 'win32') {
    const winPaths = [
      'C:\\Program Files\\Godot\\Godot.exe',
      'C:\\Program Files (x86)\\Godot\\Godot.exe',
    ];
    for (const p of winPaths) {
      if (existsSync(p)) return p;
    }
  }

  return null;
}

/**
 * Execute run_scene: spawn a headless Godot subprocess and capture output.
 */
async function handleRunScene(
  toolArgs: Record<string, unknown>,
  bridge: GodotBridge
): Promise<{ content: Array<{ type: string; text: string }>; isError?: boolean }> {
  const scenePath = toolArgs.scene_path as string;
  const extraArgs = (toolArgs.args as string[] | undefined) ?? [];
  const timeoutMs = (toolArgs.timeout_ms as number | undefined) ?? 60000;
  const headless = (toolArgs.headless as boolean | undefined) ?? true;
  const explicitProjectPath = toolArgs.project_path as string | undefined;

  // Resolve project root: explicit param → bridge → error
  const projectPath = explicitProjectPath || bridge.getStatus().projectPath;
  if (!projectPath) {
    return {
      content: [{
        type: 'text',
        text: JSON.stringify({
          error: 'Project path unknown. Either open the Godot editor with the MCP plugin connected, or pass project_path explicitly.',
          hint: 'project_path should be the absolute filesystem path to the directory containing project.godot'
        }, null, 2)
      }],
      isError: true
    };
  }

  const godotBin = findGodotExecutable();
  if (!godotBin) {
    return {
      content: [{
        type: 'text',
        text: JSON.stringify({
          error: 'Godot executable not found.',
          hint: 'Set the GODOT_PATH environment variable to the absolute path of your Godot binary, or ensure `godot4` / `godot` is on your PATH.'
        }, null, 2)
      }],
      isError: true
    };
  }

  // Build argument list:
  //   godot [--headless] --path <project_root> [-s] <scene_path> [extra_args...]
  // .gd scripts use -s (script mode); .tscn scenes are positional arguments.
  const isScript = scenePath.endsWith('.gd');
  const godotArgs: string[] = [];
  if (headless) godotArgs.push('--headless');
  godotArgs.push('--path', projectPath);
  if (isScript) godotArgs.push('-s');
  godotArgs.push(scenePath);
  godotArgs.push(...extraArgs);

  const startTime = Date.now();

  return new Promise((resolve) => {
    let stdout = '';
    let timedOut = false;

    const child = spawn(godotBin, godotArgs, {
      // Merge stderr into stdout so print() and push_error() both appear
      stdio: ['ignore', 'pipe', 'pipe'],
    });

    child.stdout.on('data', (chunk: Buffer) => { stdout += chunk.toString(); });
    child.stderr.on('data', (chunk: Buffer) => { stdout += chunk.toString(); });

    const timer = setTimeout(() => {
      timedOut = true;
      child.kill('SIGTERM');
    }, timeoutMs);

    child.on('close', (code) => {
      clearTimeout(timer);
      const duration_ms = Date.now() - startTime;

      if (timedOut) {
        resolve({
          content: [{
            type: 'text',
            text: JSON.stringify({
              error: `Process timed out after ${timeoutMs}ms`,
              stdout,
              exit_code: null,
              duration_ms
            }, null, 2)
          }],
          isError: true
        });
        return;
      }

      resolve({
        content: [{
          type: 'text',
          text: JSON.stringify({
            stdout,
            exit_code: code,
            duration_ms,
            godot_bin: godotBin,
            command: [godotBin, ...godotArgs].join(' ')
          }, null, 2)
        }]
      });
    });

    child.on('error', (err) => {
      clearTimeout(timer);
      resolve({
        content: [{
          type: 'text',
          text: JSON.stringify({
            error: `Failed to spawn Godot: ${err.message}`,
            godot_bin: godotBin,
            command: [godotBin, ...godotArgs].join(' ')
          }, null, 2)
        }],
        isError: true
      });
    });
  });
}

/**
 * Start the MCP server and WebSocket bridge
 */
async function main() {
  console.error(`[${SERVER_NAME}] Starting MCP server v${SERVER_VERSION}...`);

  // Always clear the port unless --no-force is passed.
  // MCP clients (Claude Desktop, Cursor) often leave zombie server processes
  // when restarting, which block the new instance from binding.
  if (!noForce) {
    killProcessOnPort(WEBSOCKET_PORT);
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
