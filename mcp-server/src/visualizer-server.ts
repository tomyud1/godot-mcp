/**
 * Lightweight HTTP server to serve the project visualization.
 * Injects project data into the HTML template and opens the browser.
 */

import http from 'node:http';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { exec } from 'node:child_process';

const __dirname = path.dirname(fileURLToPath(import.meta.url));

let vizServer: http.Server | null = null;
const DEFAULT_PORT = 6510;

/**
 * Serve the visualization and open the browser.
 * Returns the URL where it's hosted.
 */
export async function serveVisualization(projectData: unknown): Promise<string> {
  // Close previous instance if running
  if (vizServer) {
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
 * Stop the visualization server if running.
 */
export function stopVisualizationServer(): void {
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
