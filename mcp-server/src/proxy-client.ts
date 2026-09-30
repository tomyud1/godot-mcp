/**
 * HTTP client for proxy mode.
 * Communicates with the primary server to forward tool calls and probe health.
 */

import http from 'node:http';
import { getAuthToken } from './auth.js';
import type { ContentBlock } from './types.js';

export interface ProbeResult {
  alive: boolean;
  version?: string;
  toolCount?: number;
}

/**
 * A tool result forwarded from the primary. Content blocks are passed through
 * untouched, so image blocks survive the hop intact.
 */
export interface ProxyToolResult {
  content: ContentBlock[];
  structuredContent?: Record<string, unknown>;
  isError?: boolean;
}

const REQUEST_TIMEOUT = 5000; // 5s for health probes

/**
 * Probe an existing primary server on the given port.
 * Returns { alive: true } if a healthy godot-mcp-server responds.
 */
export async function probeExistingServer(port: number): Promise<ProbeResult> {
  try {
    const body = await httpGet(`http://127.0.0.1:${port}/health`, REQUEST_TIMEOUT);
    const data = JSON.parse(body);
    if (data.server === 'godot-mcp-server') {
      return { alive: true, version: data.version, toolCount: data.tool_count };
    }
    return { alive: false };
  } catch {
    return { alive: false };
  }
}

/**
 * Register this proxy client with the primary (increments AI client count).
 */
export async function registerProxyClient(port: number): Promise<void> {
  try {
    await httpPost(`http://127.0.0.1:${port}/client/register`, '', REQUEST_TIMEOUT);
  } catch {
    // Non-fatal — primary may not support this endpoint yet
  }
}

/**
 * The primary requires a bearer token on every non-health endpoint. Proxies
 * read the same shared secret (env var or token file) as the primary, so no
 * out-of-band handshake is needed.
 */
function authHeader(): Record<string, string> {
  const token = getAuthToken();
  return token ? { Authorization: `Bearer ${token}` } : {};
}

/**
 * Unregister this proxy client from the primary (decrements AI client count).
 */
export async function unregisterProxyClient(port: number): Promise<void> {
  try {
    await httpPost(`http://127.0.0.1:${port}/client/unregister`, '', REQUEST_TIMEOUT);
  } catch {
    // Non-fatal
  }
}

/**
 * Forward a tool call to the primary server.
 * Timeout is generous because Godot tool execution can be slow.
 */
export async function proxyToolCall(
  port: number,
  name: string,
  args: Record<string, unknown>,
  timeoutMs: number
): Promise<ProxyToolResult> {
  const body = JSON.stringify({ name, args });

  const response = await httpPost(
    `http://127.0.0.1:${port}/tool`,
    body,
    timeoutMs + 5000 // extra buffer over the tool timeout
  );

  return JSON.parse(response) as ProxyToolResult;
}

function httpGet(url: string, timeoutMs: number): Promise<string> {
  return new Promise((resolve, reject) => {
    const req = http.get(url, { timeout: timeoutMs }, (res) => {
      if (res.statusCode !== 200) {
        reject(new Error(`HTTP ${res.statusCode}`));
        res.resume();
        return;
      }
      const chunks: Buffer[] = [];
      res.on('data', (chunk: Buffer) => chunks.push(chunk));
      res.on('end', () => resolve(Buffer.concat(chunks).toString()));
      res.on('error', reject);
    });

    req.on('timeout', () => {
      req.destroy();
      reject(new Error('Request timed out'));
    });
    req.on('error', reject);
  });
}

function httpPost(url: string, body: string, timeoutMs: number): Promise<string> {
  return new Promise((resolve, reject) => {
    const parsed = new URL(url);
    const options: http.RequestOptions = {
      hostname: parsed.hostname,
      port: parsed.port,
      path: parsed.pathname,
      method: 'POST',
      timeout: timeoutMs,
      headers: {
        'Content-Type': 'application/json',
        'Content-Length': Buffer.byteLength(body),
        ...authHeader(),
      },
    };

    const req = http.request(options, (res) => {
      if (res.statusCode !== 200) {
        reject(new Error(`HTTP ${res.statusCode}`));
        res.resume();
        return;
      }
      const chunks: Buffer[] = [];
      res.on('data', (chunk: Buffer) => chunks.push(chunk));
      res.on('end', () => resolve(Buffer.concat(chunks).toString()));
      res.on('error', reject);
    });

    req.on('timeout', () => {
      req.destroy();
      reject(new Error('Request timed out'));
    });
    req.on('error', reject);
    req.end(body);
  });
}
