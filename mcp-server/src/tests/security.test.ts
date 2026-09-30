/**
 * Integration checks for the Phase 1 hardening. These exercise the real
 * listeners rather than unit-testing helpers, because the properties that
 * matter (a browser cannot open the bridge socket; an unauthenticated caller
 * cannot drive the editor) only exist at the wire level.
 */
import { describe, it, expect, afterAll, beforeAll } from 'vitest';
import { WebSocket } from 'ws';
import http from 'node:http';
import { createBridge, type GodotBridge } from '../godot-bridge.js';
import { PrimaryHttpServer, type ToolExecutor } from '../primary-http.js';

const WS_PORT = 16705;
const HTTP_PORT = 16706;
const TOKEN = 'integration-test-token';

let bridge: GodotBridge;
let primary: PrimaryHttpServer;

const noop: ToolExecutor = async () => ({ content: [{ type: 'text', text: '{"ok":true}' }] });

function post(path: string, body: string, headers: Record<string, string> = {}) {
  return new Promise<{ status: number; body: string }>((resolve, reject) => {
    const data = Buffer.from(body);
    const req = http.request(
      {
        hostname: '127.0.0.1',
        port: HTTP_PORT,
        path,
        method: 'POST',
        headers: { 'Content-Type': 'application/json', 'Content-Length': data.length, ...headers },
      },
      (res) => {
        const chunks: Buffer[] = [];
        res.on('data', (c) => chunks.push(c));
        res.on('end', () => resolve({ status: res.statusCode!, body: Buffer.concat(chunks).toString() }));
      }
    );
    req.on('error', reject);
    req.end(data);
  });
}

/** Open a socket and report whether the handshake was accepted. */
function tryConnect(headers: Record<string, string>): Promise<{ accepted: boolean; error?: string }> {
  return new Promise((resolve) => {
    const ws = new WebSocket(`ws://127.0.0.1:${WS_PORT}`, { headers });
    const done = (accepted: boolean, error?: string) => {
      try { ws.close(); } catch { /* already closed */ }
      resolve({ accepted, error });
    };
    ws.on('open', () => done(true));
    ws.on('error', (err) => done(false, err.message));
    setTimeout(() => done(false, 'timeout'), 4000);
  });
}

beforeAll(async () => {
  bridge = createBridge(WS_PORT, 3000);
  await bridge.start();
  primary = new PrimaryHttpServer(HTTP_PORT, 'test', noop, 0, TOKEN);
  await primary.start();
});

afterAll(() => {
  bridge.stop();
  primary.stop();
});

describe('bridge WebSocket — cross-site hijacking defence', () => {
  it('accepts a handshake with no Origin (how Godot connects)', async () => {
    const res = await tryConnect({});
    expect(res.accepted).toBe(true);
  });

  it('rejects a handshake carrying a browser Origin', async () => {
    const res = await tryConnect({ Origin: 'https://evil.example.com' });
    expect(res.accepted).toBe(false);
  });

  it('rejects an http Origin too', async () => {
    const res = await tryConnect({ Origin: 'http://localhost:3000' });
    expect(res.accepted).toBe(false);
  });

  it('rejects a null Origin', async () => {
    const res = await tryConnect({ Origin: 'null' });
    expect(res.accepted).toBe(false);
  });
});

describe('primary HTTP — token enforcement', () => {
  it('refuses an unauthenticated tool call', async () => {
    const res = await post('/tool', JSON.stringify({ name: 'edit_script', args: {} }));
    expect(res.status).toBe(401);
    expect(JSON.parse(res.body).error).toBe('Unauthorized');
  });

  it('refuses a wrong token', async () => {
    const res = await post('/tool', JSON.stringify({ name: 'read_file', args: {} }), {
      Authorization: 'Bearer not-the-real-token',
    });
    expect(res.status).toBe(401);
  });

  it('refuses an unauthenticated client register', async () => {
    const res = await post('/client/register', '');
    expect(res.status).toBe(401);
  });

  it('accepts a correctly authenticated tool call', async () => {
    const res = await post('/tool', JSON.stringify({ name: 'read_file', args: {} }), {
      Authorization: `Bearer ${TOKEN}`,
    });
    expect(res.status).toBe(200);
    expect(JSON.parse(res.body).content[0].text).toBe('{"ok":true}');
  });

  it('reports a malformed body as 400, not 500', async () => {
    const res = await post('/tool', '{not json', { Authorization: `Bearer ${TOKEN}` });
    expect(res.status).toBe(400);
  });

  it('leaves /health open so proxies can discover the primary', async () => {
    const body = await new Promise<string>((resolve, reject) => {
      http.get({ hostname: '127.0.0.1', port: HTTP_PORT, path: '/health' }, (res) => {
        expect(res.statusCode).toBe(200);
        const chunks: Buffer[] = [];
        res.on('data', (c) => chunks.push(c));
        res.on('end', () => resolve(Buffer.concat(chunks).toString()));
      }).on('error', reject);
    });
    expect(JSON.parse(body).server).toBe('godot-mcp-server');
  });
});
