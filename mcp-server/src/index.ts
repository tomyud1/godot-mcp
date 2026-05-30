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
import { readFileSync } from 'fs';
import { fileURLToPath } from 'url';
import { dirname, resolve as resolvePath } from 'path';
import { allTools, toolExists } from './tools/index.js';
import { GodotBridge } from './godot-bridge.js';
import { registerResources, GUIDES } from './resources.js';
import { serveVisualization, stopVisualizationServer, setGodotBridge } from './visualizer-server.js';
import { PrimaryHttpServer, type ToolCallResult } from './primary-http.js';
import { probeExistingServer, proxyToolCall, registerProxyClient, unregisterProxyClient } from './proxy-client.js';
import { LspClient } from './lsp/client.js';

// ---------------------------------------------------------------------------
// Configuration
// ---------------------------------------------------------------------------

const SERVER_NAME = 'godot-mcp-server';

// Read version from package.json so it stays in sync with the published
// package.  Falls back to a hardcoded string only if the file is unreadable
// (e.g. the file got renamed in a custom build).
const SERVER_VERSION = (() => {
  try {
    const here = dirname(fileURLToPath(import.meta.url));
    // dist/index.js → ../package.json   |   src/index.ts (tsx) → ../package.json
    const pkgPath = resolvePath(here, '..', 'package.json');
    const pkg = JSON.parse(readFileSync(pkgPath, 'utf8')) as { version?: string };
    if (pkg.version) return pkg.version;
  } catch {
    // ignore — fall through to default
  }
  return '0.0.0-dev';
})();
const WEBSOCKET_PORT = parseInt(process.env.GODOT_MCP_PORT || '6505', 10);
const HTTP_PORT = parseInt(process.env.GODOT_MCP_HTTP_PORT || '6506', 10);
const TOOL_TIMEOUT = parseInt(process.env.GODOT_MCP_TIMEOUT_MS || '30000', 10);
const IDLE_TIMEOUT = parseInt(process.env.GODOT_MCP_IDLE_TIMEOUT_MS || '30000', 10);
const LSP_PORT = parseInt(process.env.GODOT_MCP_LSP_PORT || '6005', 10);

// ---------------------------------------------------------------------------
// Process-level safety net
//
// Godot's LSP server restarts with the editor process.  During reconnect
// cycles `vscode-jsonrpc` may produce asynchronous Promise rejections for
// pending requests on a dead socket — these escape our local try/catch.
// This handler catches them before Node.js treats them as uncaught.
// ---------------------------------------------------------------------------
process.on('unhandledRejection', (reason: unknown) => {
  const msg = reason instanceof Error ? reason.message : String(reason);
  // Expected during LSP reconnect (socket-level noise — the retry loop
  // in connectLspWithRetry will recover).  Log once, don't crash.
  if (msg.includes('Socket closed') || msg.includes('ECONN') || msg.includes('EPIPE')) {
    return;
  }
  console.error(`[${SERVER_NAME}] Unhandled rejection: ${msg}`);
  if (reason instanceof Error && reason.stack) console.error(reason.stack);
});

const args = process.argv.slice(2);
const noForce = args.includes('--no-force');

// ---------------------------------------------------------------------------
// Tool execution (shared logic used by both primary MCP handler & HTTP API)
// ---------------------------------------------------------------------------

let godotBridge: GodotBridge | null = null;
let lspClient: LspClient | null = null;

// ---------------------------------------------------------------------------
// LSP tool routing
//
// These five tools are handled locally by the TypeScript server via a
// direct TCP connection to Godot's built-in Language Server Protocol
// server (port 6065 in this project), rather than through the WebSocket
// bridge to the Godot plugin.  This gives us project-wide diagnostics
// with full class-inheritance context.
// ---------------------------------------------------------------------------
const LSP_TOOLS = new Set([
  'validate_script',
  'goto_definition',
  'find_references',
  'get_symbol_info',
  'list_document_symbols',
]);

async function executeLspToolCall(name: string, args: Record<string, unknown>): Promise<ToolCallResult> {
  if (!lspClient || !lspClient.connected) {
    return {
      content: [{ type: 'text', text: JSON.stringify({
        ok: false,
        error: 'Godot Language Server is not available. Enable it in Godot: Editor Settings → Network → Language Server → Enable, verify the port (default 6005, set GODOT_MCP_LSP_PORT to override), then restart the MCP server.',
        hint: `LSP port: ${LSP_PORT}`,
      }, null, 2) }],
      isError: true,
    };
  }

  try {
    let result: unknown;

    switch (name) {
      case 'validate_script': {
        const filePath = String(args.path ?? '');
        const diagnostics = await lspClient.getDiagnostics(filePath);
        const errors = diagnostics.filter(d => d.severity === 1); // 1 = Error
        const warnings = diagnostics.filter(d => d.severity === 2); // 2 = Warning
        result = {
          ok: true,
          valid: errors.length === 0,
          path: filePath,
          diagnostics: diagnostics.map(d => ({
            severity: d.severity === 1 ? 'error' : d.severity === 2 ? 'warning' : d.severity === 3 ? 'info' : 'hint',
            message: d.message,
            line: d.range.start.line,
            column: d.range.start.character,
            endLine: d.range.end.line,
            endColumn: d.range.end.character,
            code: d.code ?? undefined,
            source: d.source ?? 'gdscript',
          })),
          errorCount: errors.length,
          warningCount: warnings.length,
          message: diagnostics.length === 0
            ? 'No issues found.'
            : `Found ${errors.length} error(s) and ${warnings.length} warning(s).`,
        };
        break;
      }
      case 'goto_definition': {
        const filePath = String(args.path ?? '');
        const line = Number(args.line ?? 0);
        const character = Number(args.character ?? 0);
        const def = await lspClient.gotoDefinition(filePath, line, character);
        if (!def) {
          result = { ok: true, path: filePath, line, character, definition: null, message: 'No definition found.' };
        } else if (Array.isArray(def)) {
          result = {
            ok: true, path: filePath, line, character,
            definitions: def.map((loc: unknown) => {
              const l = loc as Record<string, unknown>;
              const isLocationLink = 'targetUri' in l;
              return {
                uri: isLocationLink ? l.targetUri : l.uri,
                line: isLocationLink
                  ? (l.targetRange as { start: { line: number } }).start.line
                  : (l.range as { start: { line: number } }).start.line,
                character: isLocationLink
                  ? (l.targetRange as { start: { character: number } }).start.character
                  : (l.range as { start: { character: number } }).start.character,
              };
            }),
            count: def.length,
          };
        } else {
          result = {
            ok: true, path: filePath, line, character,
            definition: { uri: def.uri, line: def.range.start.line, character: def.range.start.character },
          };
        }
        break;
      }
      case 'find_references': {
        const filePath = String(args.path ?? '');
        const line = Number(args.line ?? 0);
        const character = Number(args.character ?? 0);
        const includeDeclaration = args.include_declaration !== false;
        const refs = await lspClient.findReferences(filePath, line, character, includeDeclaration);
        result = {
          ok: true,
          path: filePath,
          line,
          character,
          references: refs.map(r => ({
            uri: r.uri,
            line: r.range.start.line,
            character: r.range.start.character,
          })),
          count: refs.length,
        };
        break;
      }
      case 'get_symbol_info': {
        const filePath = String(args.path ?? '');
        const line = Number(args.line ?? 0);
        const character = Number(args.character ?? 0);
        const hover = await lspClient.getHover(filePath, line, character);
        if (!hover) {
          result = { ok: true, path: filePath, line, character, symbol: null, message: 'No hover information available.' };
        } else {
          const contents = hover.contents;
          result = {
            ok: true,
            path: filePath,
            line,
            character,
            symbol: {
              contents: Array.isArray(contents) ? contents.map(c => (typeof c === 'string' ? c : c.value)).join('\n') : (typeof contents === 'string' ? contents : contents.value),
              range: hover.range ? {
                start: { line: hover.range.start.line, character: hover.range.start.character },
                end: { line: hover.range.end.line, character: hover.range.end.character },
              } : null,
            },
          };
        }
        break;
      }
      case 'list_document_symbols': {
        const filePath = String(args.path ?? '');
        const symbols = await lspClient.getDocumentSymbols(filePath);
        const flatten = (syms: typeof symbols): Record<string, unknown>[] =>
          syms.map(s => ({
            name: s.name,
            kind: LspClient.symbolKindToString(s.kind),
            detail: s.detail ?? '',
            line: s.range.start.line,
            children: s.children ? flatten(s.children) : [],
          }));
        result = {
          ok: true,
          path: filePath,
          symbols: flatten(symbols),
          count: symbols.length,
        };
        break;
      }
      default:
        throw new Error(`Unknown LSP tool: ${name}`);
    }

    return {
      content: [{ type: 'text', text: JSON.stringify(result, null, 2) }],
    };
  } catch (error) {
    const errorMessage = error instanceof Error ? error.message : String(error);
    return {
      content: [{ type: 'text', text: JSON.stringify({
        ok: false,
        error: errorMessage,
        tool: name,
        hint: 'LSP tool call failed. Ensure Godot editor is running with Language Server enabled.',
      }, null, 2) }],
      isError: true,
    };
  }
}

async function executeToolCall(
  name: string,
  toolArgs: Record<string, unknown>
): Promise<ToolCallResult> {
  if (name === 'get_guide') {
    const slug = typeof toolArgs.slug === 'string' ? toolArgs.slug.trim() : '';
    if (!slug) {
      return {
        content: [{
          type: 'text',
          text: JSON.stringify({
            ok: true,
            guides: GUIDES.map((g) => ({
              slug: g.slug,
              name: g.name,
              description: g.description,
              uri: g.uri,
            })),
            hint: 'Call get_guide again with one of these slugs to read the full markdown.',
          }, null, 2),
        }],
      };
    }
    const guide = GUIDES.find((g) => g.slug === slug || g.uri === slug);
    if (!guide) {
      return {
        content: [{
          type: 'text',
          text: JSON.stringify({
            ok: false,
            error: `Unknown guide slug: ${slug}`,
            available_slugs: GUIDES.map((g) => g.slug),
          }, null, 2),
        }],
        isError: true,
      };
    }
    return {
      content: [{
        type: 'text',
        text: JSON.stringify({
          ok: true,
          slug: guide.slug,
          name: guide.name,
          uri: guide.uri,
          markdown: guide.text,
        }, null, 2),
      }],
    };
  }

  if (name === 'get_godot_status') {
    const status = godotBridge!.getStatus();
    return {
      content: [{
        type: 'text',
        text: JSON.stringify({
          connected: status.connected,
          server_version: SERVER_VERSION,
          websocket_port: status.port,
          lsp_port: LSP_PORT,
          lsp_connected: lspClient?.connected ?? false,
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

  // LSP tools are handled locally without going through the Godot bridge
  if (LSP_TOOLS.has(name)) {
    return executeLspToolCall(name, toolArgs);
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
    // Merge any structured details the tool shipped back (open_in_editor,
    // where, is_active, clamped, requested_ms, …) into the visible response
    // so the agent doesn't lose context on failure.
    const details =
      error && typeof error === 'object' && 'details' in error
        ? (error as { details?: unknown }).details
        : undefined;
    const payload: Record<string, unknown> = {
      error: errorMessage,
      tool: name,
      args: toolArgs,
      mode: 'live',
      hint: 'The tool call was sent to Godot but failed. Check Godot editor for details.',
    };
    if (details && typeof details === 'object') {
      // Spread structured fields at the top level (callers already look for
      // `open_in_editor`, `clamped`, etc. at the root). Drop `ok` since it
      // is always false here and adds no information.
      const { ok: _ok, error: _err, ...rest } = details as Record<string, unknown>;
      Object.assign(payload, rest);
    }
    return {
      content: [{ type: 'text', text: JSON.stringify(payload, null, 2) }],
      isError: true,
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
    { capabilities: { tools: {}, resources: {} } }
  );

  registerResources(server);

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

    const getGuideTool = {
      name: 'get_guide',
      description: `Read a short markdown guide from the server. Same content as the MCP resources/read protocol, exposed as a tool so it works in MCP clients that do not support resources (e.g. Claude Desktop, Cursor chat). Call with no args to list available guides: ${GUIDES.map((g) => g.slug).join(', ')}. Call with {slug: "..."} to get the full markdown. Useful when a workflow is non-obvious (testing a running game, choosing between scene-editing tools, troubleshooting "Runtime helper not connected", etc.).`,
      inputSchema: {
        type: 'object' as const,
        properties: {
          slug: {
            type: 'string',
            description: `Guide slug. Omit to list all available guides. Known slugs: ${GUIDES.map((g) => g.slug).join(', ')}.`,
          },
        },
        required: [] as string[],
      }
    };

    return {
      tools: [
        connectionStatusTool,
        getGuideTool,
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
      // -sTCP:LISTEN is critical: plain `lsof -ti :PORT` also returns PIDs of
      // *clients* with an ESTABLISHED socket to that port. Godot is a client
      // of our WebSocket on 6505, so without this filter a "kill the process
      // on 6505" call can SIGTERM the Godot editor and crash it.
      const output = execSync(
        `lsof -ti :${port} -sTCP:LISTEN`,
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

  // Create LSP client BEFORE WebSocket starts so it exists when the
  // onConnectionChange callback fires.  If Godot connects between
  // wss.listen() and this line the callback would otherwise see a null
  // lspClient and skip LSP setup entirely.
  lspClient = new LspClient(LSP_PORT);

  // ---- LSP retry loop ---------------------------------------------------
  //
  // Godot's built-in LSP server restarts with the editor process, and
  // its TCP port may accept connections before the LSP handshake is
  // ready.  The symptom is "TCP connected → socket closed → sendRequest
  // fails".  We retry with exponential backoff (200 ms → 320 → 512 → …,
  // capped at 5 s, max 8 attempts).  A generation token cancels any
  // in-flight retries when Godot disconnects again.
  // -----------------------------------------------------------------------
  let lspRetryGeneration = 0;

  function connectLspWithRetry() {
    const gen = ++lspRetryGeneration;
    const maxTries = 8;

    const attempt = (delay: number, tries: number) => {
      if (gen !== lspRetryGeneration) return;
      if (!lspClient) return;

      lspClient.connect().then(() => {
        if (gen !== lspRetryGeneration) {
          lspClient!.disconnect().catch(() => {});
          return;
        }
        console.error(`[${SERVER_NAME}] LSP connected on port ${LSP_PORT}`);
      }).catch((err: Error) => {
        if (gen !== lspRetryGeneration) return;
        if (tries >= maxTries) {
          console.error(`[${SERVER_NAME}] LSP unavailable on port ${LSP_PORT} after ${maxTries} attempts`);
          return;
        }
        const nextDelay = Math.min(delay * 1.6, 5_000);
        setTimeout(() => attempt(nextDelay, tries + 1), delay);
      });
    };
    attempt(200, 1);
  }

  godotBridge.onConnectionChange((connected) => {
    if (connected) {
      console.error(`[${SERVER_NAME}] Godot connected`);
      cancelIdleShutdown();
      notifyClientStatus();

      const projectPath = godotBridge?.getStatus().projectPath;

      // LSP lazy-connect: wait until godot_ready delivers the project
      // path, then start the retry loop.  The first onConnectionChange
      // fires on WebSocket open (no projectPath yet); the second fires
      // when godot_ready arrives and godot-bridge.ts re-notifies us.
      if (projectPath && lspClient && !lspClient.connected) {
        lspClient.setProjectRoot(projectPath);
        connectLspWithRetry();
      } else if (lspClient?.connected) {
        if (projectPath) {
          lspClient.setProjectRoot(projectPath);
        }
      }
    } else {
      console.error(`[${SERVER_NAME}] Godot disconnected`);
      ++lspRetryGeneration;                       // cancel retry loop
      if (lspClient?.connected) {
        lspClient.disconnect().catch(() => {});   // release stale LSP TCP socket
      }
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
  const httpServer = new PrimaryHttpServer(HTTP_PORT, SERVER_VERSION, executeToolCall, allTools.length + 2);
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

  // --- Verify servers started ---
  if (!godotBridge.isListening()) {
    console.error(`[${SERVER_NAME}] ❌ Fatal: WebSocket server failed to start. Godot cannot connect.`);
    httpServer.stop();
    process.exit(1);
  }

  if (!httpServer.isListening()) {
    console.error(`[${SERVER_NAME}] ⚠️  HTTP server failed to start. Proxy clients will not work.`);
  }

  console.error(`[${SERVER_NAME}] Available tools: ${allTools.length + 2}`);
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
    lspClient?.disconnect();
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
    const localToolCount = allTools.length + 2; // +1 for get_godot_status, +1 for get_guide
    const primaryStale = probe.version !== SERVER_VERSION
      || (probe.toolCount != null && probe.toolCount !== localToolCount);
    if (primaryStale) {
      console.error(`[${SERVER_NAME}] Replacing outdated primary (v${probe.version}, ${probe.toolCount ?? '?'} tools) with v${SERVER_VERSION} (${localToolCount} tools)...`);
      await killProcessOnPort(HTTP_PORT);
      await killProcessOnPort(WEBSOCKET_PORT);
      await new Promise(resolve => setTimeout(resolve, 500));
      return startPrimary();
    }
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
