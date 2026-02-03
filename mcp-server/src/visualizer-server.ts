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
import type { GodotBridge } from './godot-bridge.js';

const __dirname = path.dirname(fileURLToPath(import.meta.url));

let vizServer: http.Server | null = null;
let wss: WebSocketServer | null = null;
let godotBridge: GodotBridge | null = null;
const DEFAULT_PORT = 6510;

/**
 * Set the Godot bridge reference for internal commands.
 */
export function setGodotBridge(bridge: GodotBridge): void {
  godotBridge = bridge;
}

/**
 * Serve the visualization and open the browser.
 * Returns the URL where it's hosted.
 */
export async function serveVisualization(projectData: unknown): Promise<string> {
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
  const htmlPath = path.join(__dirname, 'visualizer.html');
  let html: string;
  try {
    html = fs.readFileSync(htmlPath, 'utf-8');
  } catch {
    throw new Error(`Visualizer HTML template not found at ${htmlPath}`);
  }

  // Inject project data
  const dataJson = JSON.stringify(projectData);
  html = html.replace('"%%PROJECT_DATA%%"', dataJson);

  // Find available port
  const port = await findPort(DEFAULT_PORT);

  // Start server
  return new Promise((resolve, reject) => {
    vizServer = http.createServer((_req, res) => {
      res.writeHead(200, {
        'Content-Type': 'text/html; charset=utf-8',
        'Cache-Control': 'no-cache'
      });
      res.end(html);
    });

    // Add WebSocket server for real-time edits
    wss = new WebSocketServer({ server: vizServer });
    wss.on('connection', handleVisualizerConnection);

    vizServer.on('error', (err) => {
      reject(new Error(`Failed to start visualizer server: ${err.message}`));
    });

    vizServer.listen(port, () => {
      const url = `http://localhost:${port}`;
      console.error(`[visualizer] Serving at ${url}`);
      openBrowser(url);
      resolve(url);
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
