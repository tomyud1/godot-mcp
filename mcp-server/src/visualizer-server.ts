/**
 * HTTP + WebSocket server for the project visualization.
 * - Serves HTML template with injected project data
 * - WebSocket for real-time edits (internal, not exposed as MCP tools)
 */

import http from 'node:http';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { exec } from 'node:child_process';
import { WebSocketServer, WebSocket } from 'ws';
import type { IncomingMessage } from 'node:http';
import type { GodotBridge } from './godot-bridge.js';
import { createEphemeralToken, isAuthorized } from './auth.js';

const __dirname = path.dirname(fileURLToPath(import.meta.url));

let vizServer: http.Server | null = null;
let wss: WebSocketServer | null = null;
let godotBridge: GodotBridge | null = null;
const DEFAULT_PORT = 6510;

/**
 * Per-session secret for this visualizer instance.
 *
 * The visualizer forwards commands that WRITE to .gd files on disk, so an
 * unauthenticated local page must not be able to drive it. The token is
 * minted per `serveVisualization()` call and carried in the page URL, which
 * is also re-checked on the WebSocket upgrade (browsers cannot set headers
 * on a WS handshake, hence the query parameter).
 */
let sessionToken: string | null = null;

/**
 * Set the Godot bridge reference for internal commands.
 */
export function setGodotBridge(bridge: GodotBridge): void {
  godotBridge = bridge;
}

export interface VisualizationOptions {
  /**
   * Override the per-session token. Defaults to a freshly minted secret.
   * Intended for tests and for embedders that need to pre-share the token.
   */
  token?: string;
  /** Set false to serve without launching a browser (tests, headless use). */
  openBrowser?: boolean;
  /**
   * Override the HTML template location. Defaults to visualizer.html next to
   * the compiled server. Tests point this at a fixture so they do not depend
   * on a prior bundling step.
   */
  templatePath?: string;
}

/**
 * Serve the visualization and open the browser.
 * Returns the base URL where it's hosted (without the session token).
 */
export async function serveVisualization(
  projectData: unknown,
  options: VisualizationOptions = {}
): Promise<string> {
  // Close previous instance if running
  if (vizServer) {
    if (wss) {
      wss.close();
      wss = null;
    }
    vizServer.close();
    vizServer = null;
  }

  // Read HTML template
  const htmlPath = options.templatePath ?? path.join(__dirname, 'visualizer.html');
  let html: string;
  try {
    html = fs.readFileSync(htmlPath, 'utf-8');
  } catch {
    throw new Error(`Visualizer HTML template not found at ${htmlPath}`);
  }

  // Mint a fresh secret for this session before the page references it.
  sessionToken = options.token ?? createEphemeralToken();

  // Inject project data
  const dataJson = JSON.stringify(projectData);
  html = html.replace('"%%PROJECT_DATA%%"', dataJson);

  // Find available port
  const port = await findPort(DEFAULT_PORT);

  // Start server
  return new Promise((resolve, reject) => {
    // Only loopback origins may load the page. Combined with the session
    // token this blocks a hostile site from reading the project map.
    const expectedOrigin = `http://localhost:${port}`;

    vizServer = http.createServer((req, res) => {
      const origin = req.headers.origin;
      if (typeof origin === 'string' && origin !== expectedOrigin && origin !== `http://127.0.0.1:${port}`) {
        res.writeHead(403);
        res.end('Forbidden');
        return;
      }

      res.writeHead(200, {
        'Content-Type': 'text/html; charset=utf-8',
        'Cache-Control': 'no-cache'
      });
      res.end(html);
    });

    // Add WebSocket server for real-time edits
    wss = new WebSocketServer({
      server: vizServer,
      // The token travels as `?token=`; `path` matches on the pathname only,
      // so the query string does not defeat routing.
      path: '/ws',
      verifyClient: (info: { req: IncomingMessage }) =>
        authorizeVisualizerUpgrade(info.req.headers as Record<string, unknown>, info.req.url),
    });
    wss.on('connection', handleVisualizerConnection);

    vizServer.on('error', (err) => {
      reject(new Error(`Failed to start visualizer server: ${err.message}`));
    });

    vizServer.listen(port, () => {
      const baseUrl = `http://localhost:${port}`;
      const url = `${baseUrl}/?token=${sessionToken}`;
      // Deliberately log the base URL, not `url`: stderr from an MCP server
      // is routinely captured in client logs and transcripts, and this token
      // authorizes writes to the project's .gd files.
      console.error(`[visualizer] Serving at ${baseUrl}`);
      if (options.openBrowser !== false) {
        openBrowser(url);
      }
      // The URL carries the session token; the tool response should not echo
      // it back to the agent or it lands in transcripts and logs.
      resolve(baseUrl);
    });
  });
}

/**
 * Handle WebSocket connection from the visualizer.
 * Forwards internal commands to Godot.
 */
function handleVisualizerConnection(ws: WebSocket): void {
  console.error('[visualizer] Browser connected via WebSocket');

  ws.on('message', async (data) => {
    try {
      const message = JSON.parse(data.toString());
      const result = await handleInternalCommand(message);
      ws.send(JSON.stringify({ id: message.id, ...result }));
    } catch (error) {
      const errMsg = error instanceof Error ? error.message : 'Unknown error';
      ws.send(JSON.stringify({ error: errMsg }));
    }
  });

  ws.on('close', () => {
    console.error('[visualizer] Browser disconnected');
  });
}

/**
 * Handle internal commands from the visualizer.
 * These are NOT exposed as MCP tools - they're internal only.
 */
async function handleInternalCommand(message: {
  id?: string;
  command: string;
  args: Record<string, unknown>;
}): Promise<{ ok: boolean; error?: string; [key: string]: unknown }> {
  const { command, args } = message;

  if (!godotBridge) {
    return { ok: false, error: 'Bridge not initialized' };
  }

  if (!godotBridge.isConnected()) {
    return { ok: false, error: 'Godot is not connected' };
  }

  console.error(`[visualizer] Internal command: ${command}`);

  try {
    // Forward to Godot's internal functions via tool invocation
    // The tool name prefix "_internal_" ensures these aren't exposed as MCP tools
    const result = await godotBridge.invokeTool(`visualizer._internal_${command}`, args);
    // Add ok: true since the Godot plugin strips it from the response
    return { ok: true, ...(result as Record<string, unknown>) };
  } catch (error) {
    const errMsg = error instanceof Error ? error.message : 'Unknown error';
    return { ok: false, error: errMsg };
  }
}

/**
 * Authorization check for an incoming visualizer WebSocket upgrade.
 *
 * Exported so the rule can be tested directly. The token is accepted either as
 * a query parameter (how the page carries it — browsers cannot set headers on
 * a WebSocket handshake) or as a bearer header (handy for scripted clients).
 */
export function authorizeVisualizerUpgrade(headers: Record<string, unknown>, url?: string): boolean {
  if (!sessionToken) return false;
  return isAuthorized(headers, sessionToken, url);
}

/**
 * Stop the visualization server if running.
 */
export function stopVisualizationServer(): void {
  if (wss) {
    wss.close();
    wss = null;
  }
  if (vizServer) {
    vizServer.close();
    vizServer = null;
    console.error('[visualizer] Server stopped');
  }
  sessionToken = null;
}

function findPort(startPort: number): Promise<number> {
  return new Promise((resolve) => {
    const server = http.createServer();
    server.listen(startPort, () => {
      server.close(() => resolve(startPort));
    });
    server.on('error', () => {
      resolve(findPort(startPort + 1));
    });
  });
}

function openBrowser(url: string): void {
  const cmd = process.platform === 'darwin' ? 'open'
            : process.platform === 'win32' ? 'start'
            : 'xdg-open';
  exec(`${cmd} ${url}`, (err) => {
    if (err) {
      console.error(`[visualizer] Could not open browser: ${err.message}`);
    }
  });
}
