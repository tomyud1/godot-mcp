/**
 * HTTP server for primary mode.
 * Allows proxy instances to forward tool calls and check health.
 *
 * Endpoints:
 *   GET  /health             → { server, version, godot_connected }
 *   POST /tool               → { name, args } → MCP-formatted result
 *   POST /client/register    → increment proxy client count
 *   POST /client/unregister  → decrement proxy client count
 */

import http from 'node:http';
import { isAuthorized } from './auth.js';
import type { ToolCallResult } from './types.js';

const MAX_BODY_SIZE = 1024 * 1024; // 1 MB

export type { ToolCallResult } from './types.js';

export type ToolExecutor = (
  name: string,
  args: Record<string, unknown>
) => Promise<ToolCallResult>;

export class PrimaryHttpServer {
  private server: http.Server | null = null;
  private port: number;
  private serverVersion: string;
  private executeToolCall: ToolExecutor;
  private lastActivityTime = Date.now();
  private proxyClientCount = 0;
  private onClientCountChange: ((count: number) => void) | null = null;

  private toolCount: number;
  private authToken: string | null;

  constructor(port: number, version: string, executor: ToolExecutor, toolCount: number, authToken: string | null) {
    this.port = port;
    this.serverVersion = version;
    this.executeToolCall = executor;
    this.toolCount = toolCount;
    // Required, with no "disabled" mode: a caller that fails to supply a
    // token gets a server that refuses every request rather than one that
    // silently serves the editor to any local process.
    this.authToken = authToken;
  }

  getLastActivityTime(): number {
    return this.lastActivityTime;
  }

  getProxyClientCount(): number {
    return this.proxyClientCount;
  }

  setClientCountChangeCallback(cb: (count: number) => void): void {
    this.onClientCountChange = cb;
  }

  start(): Promise<void> {
    return new Promise((resolve, reject) => {
      this.server = http.createServer((req, res) => this.handleRequest(req, res));

      this.server.on('error', (err) => {
        reject(err);
      });

      this.server.listen(this.port, '127.0.0.1', () => {
        resolve();
      });
    });
  }

  isListening(): boolean {
    return this.server?.listening ?? false;
  }

  stop(): void {
    if (this.server) {
      this.server.close();
      this.server = null;
    }
  }

  private async handleRequest(req: http.IncomingMessage, res: http.ServerResponse): Promise<void> {
    res.setHeader('Content-Type', 'application/json');

    try {
      // Match on the pathname only. The token may legitimately arrive as a
      // `?token=` query parameter, which must not change route matching.
      const route = (req.url ?? '/').split('?')[0];

      // /health stays unauthenticated: proxy instances probe it to discover
      // the primary before they have reason to know the token, and it leaks
      // nothing beyond server name, version and tool count.
      if (req.method === 'GET' && route === '/health') {
        this.lastActivityTime = Date.now();
        res.writeHead(200);
        res.end(JSON.stringify({
          server: 'godot-mcp-server',
          version: this.serverVersion,
          tool_count: this.toolCount,
        }));
        return;
      }

      // Everything past this point can drive the Godot editor, so it requires
      // the shared secret. Fail closed: if no token could be established we
      // refuse rather than serve the API unauthenticated.
      if (req.method === 'POST') {
        const expected = this.authToken;
        if (!expected) {
          res.writeHead(503);
          res.end(JSON.stringify({
            error: 'Authentication unavailable: could not resolve a shared token',
            hint: 'Set GODOT_MCP_TOKEN, or ensure the server can write to its token file.',
          }));
          return;
        }

        if (!isAuthorized(req.headers as Record<string, unknown>, expected, req.url)) {
          res.writeHead(401);
          res.end(JSON.stringify({
            error: 'Unauthorized',
            hint: 'Send `Authorization: Bearer <token>` with the shared GODOT_MCP_TOKEN.',
          }));
          return;
        }

        // Touch the activity clock only for authenticated traffic, so an
        // unauthenticated prober cannot keep an idle server alive forever.
        this.lastActivityTime = Date.now();
      }

      if (req.method === 'POST' && route === '/tool') {
        const body = await readBody(req);

        // A malformed body is the caller's mistake, not a server fault, so it
        // must not be reported as a 500.
        let parsed: { name?: unknown; args?: Record<string, unknown> };
        try {
          parsed = JSON.parse(body) as { name?: unknown; args?: Record<string, unknown> };
        } catch {
          res.writeHead(400);
          res.end(JSON.stringify({ error: 'Request body is not valid JSON' }));
          return;
        }

        const { name, args } = parsed;

        if (typeof name !== 'string') {
          res.writeHead(400);
          res.end(JSON.stringify({ error: 'Missing or invalid "name" field' }));
          return;
        }

        const result = await this.executeToolCall(name, args || {});
        res.writeHead(200);
        res.end(JSON.stringify(result));
        return;
      }

      if (req.method === 'POST' && route === '/client/register') {
        this.proxyClientCount++;
        this.onClientCountChange?.(this.proxyClientCount);
        res.writeHead(200);
        res.end(JSON.stringify({ proxy_clients: this.proxyClientCount }));
        return;
      }

      if (req.method === 'POST' && route === '/client/unregister') {
        this.proxyClientCount = Math.max(0, this.proxyClientCount - 1);
        this.onClientCountChange?.(this.proxyClientCount);
        res.writeHead(200);
        res.end(JSON.stringify({ proxy_clients: this.proxyClientCount }));
        return;
      }

      res.writeHead(404);
      res.end(JSON.stringify({ error: 'Not found' }));
    } catch (err) {
      const message = err instanceof Error ? err.message : String(err);
      console.error(`[primary-http] Request error: ${message}`);
      if (!res.headersSent) {
        res.writeHead(500);
        res.end(JSON.stringify({ error: message }));
      }
    }
  }
}

function readBody(req: http.IncomingMessage): Promise<string> {
  return new Promise((resolve, reject) => {
    const chunks: Buffer[] = [];
    let size = 0;

    req.on('data', (chunk: Buffer) => {
      size += chunk.length;
      if (size > MAX_BODY_SIZE) {
        reject(new Error('Request body too large'));
        req.destroy();
        return;
      }
      chunks.push(chunk);
    });

    req.on('end', () => resolve(Buffer.concat(chunks).toString()));
    req.on('error', reject);
  });
}
