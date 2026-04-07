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

const MAX_BODY_SIZE = 1024 * 1024; // 1 MB

export interface ToolCallResult {
  content: Array<{ type: string; text: string }>;
  isError?: boolean;
}

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

  constructor(port: number, version: string, executor: ToolExecutor) {
    this.port = port;
    this.serverVersion = version;
    this.executeToolCall = executor;
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

  stop(): void {
    if (this.server) {
      this.server.close();
      this.server = null;
    }
  }

  isListening(): boolean {
    return this.server?.listening || false;
  }

  private async handleRequest(req: http.IncomingMessage, res: http.ServerResponse): Promise<void> {
    res.setHeader('Content-Type', 'application/json');

    try {
      if (req.method === 'GET' && req.url === '/health') {
        this.lastActivityTime = Date.now();
        res.writeHead(200);
        res.end(JSON.stringify({
          server: 'godot-mcp-server',
          version: this.serverVersion,
        }));
        return;
      }

      if (req.method === 'POST' && req.url === '/tool') {
        this.lastActivityTime = Date.now();
        const body = await readBody(req);
        const { name, args } = JSON.parse(body);

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

      if (req.method === 'POST' && req.url === '/client/register') {
        this.proxyClientCount++;
        this.onClientCountChange?.(this.proxyClientCount);
        res.writeHead(200);
        res.end(JSON.stringify({ proxy_clients: this.proxyClientCount }));
        return;
      }

      if (req.method === 'POST' && req.url === '/client/unregister') {
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
