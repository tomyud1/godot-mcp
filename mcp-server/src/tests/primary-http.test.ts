import { describe, it, expect, afterEach, vi } from 'vitest';
import http from 'node:http';
import { PrimaryHttpServer, type ToolExecutor } from '../primary-http.js';

let nextPort = 16506;
function getPort() { return nextPort++; }

/** Shared token every test server is constructed with. */
const TOKEN = 'test-token-0123456789';

/** Fire an HTTP request and return { status, body }. */
function request(
  port: number,
  method: string,
  path: string,
  body?: string,
  token: string | null = TOKEN,
): Promise<{ status: number; body: Record<string, unknown> }> {
  return new Promise((resolve, reject) => {
    const opts: http.RequestOptions = {
      hostname: '127.0.0.1',
      port,
      path,
      method,
      headers: {
        ...(body ? { 'Content-Type': 'application/json', 'Content-Length': Buffer.byteLength(body) } : {}),
        ...(token ? { Authorization: `Bearer ${token}` } : {}),
      },
    };
    const req = http.request(opts, (res) => {
      const chunks: Buffer[] = [];
      res.on('data', (c: Buffer) => chunks.push(c));
      res.on('end', () => {
        resolve({
          status: res.statusCode!,
          body: JSON.parse(Buffer.concat(chunks).toString()),
        });
      });
      res.on('error', reject);
    });
    req.on('error', reject);
    if (body) req.write(body);
    req.end();
  });
}

// ---------------------------------------------------------------------------
// Lifecycle
// ---------------------------------------------------------------------------

describe('PrimaryHttpServer — lifecycle', () => {
  let server: PrimaryHttpServer;
  const noop: ToolExecutor = async () => ({ content: [{ type: 'text', text: 'ok' }] });

  afterEach(() => {
    server?.stop();
  });

  it('isListening() is false before start', () => {
    server = new PrimaryHttpServer(getPort(), '0.0.1-test', noop, 0, TOKEN);
    expect(server.isListening()).toBe(false);
  });

  it('isListening() is true after start', async () => {
    const port = getPort();
    server = new PrimaryHttpServer(port, '0.0.1-test', noop, 0, TOKEN);
    await server.start();
    expect(server.isListening()).toBe(true);
  });

  it('isListening() is false after stop', async () => {
    server = new PrimaryHttpServer(getPort(), '0.0.1-test', noop, 0, TOKEN);
    await server.start();
    server.stop();
    expect(server.isListening()).toBe(false);
  });

  it('stop() is idempotent', async () => {
    server = new PrimaryHttpServer(getPort(), '0.0.1-test', noop, 0, TOKEN);
    await server.start();
    server.stop();
    expect(() => server.stop()).not.toThrow();
  });

  it('proxyClientCount starts at 0', () => {
    server = new PrimaryHttpServer(getPort(), '0.0.1-test', noop, 0, TOKEN);
    expect(server.getProxyClientCount()).toBe(0);
  });
});

// ---------------------------------------------------------------------------
// HTTP endpoints
// ---------------------------------------------------------------------------

describe('PrimaryHttpServer — endpoints', () => {
  let server: PrimaryHttpServer;

  afterEach(() => {
    server?.stop();
  });

  it('GET /health returns server info', async () => {
    const port = getPort();
    const executor: ToolExecutor = vi.fn(async () => ({ content: [{ type: 'text', text: 'ok' }] }));
    server = new PrimaryHttpServer(port, '1.2.3', executor, 0, TOKEN);
    await server.start();

    const res = await request(port, 'GET', '/health');
    expect(res.status).toBe(200);
    expect(res.body.server).toBe('godot-mcp-server');
    expect(res.body.version).toBe('1.2.3');
  });

  it('GET /health updates lastActivityTime', async () => {
    const port = getPort();
    const executor: ToolExecutor = vi.fn(async () => ({ content: [{ type: 'text', text: 'ok' }] }));
    server = new PrimaryHttpServer(port, '1.2.3', executor, 0, TOKEN);
    await server.start();

    const before = server.getLastActivityTime();
    await new Promise((r) => setTimeout(r, 20));
    await request(port, 'GET', '/health');
    expect(server.getLastActivityTime()).toBeGreaterThan(before);
  });

  it('POST /tool calls the executor and returns result', async () => {
    const port = getPort();
    const executor: ToolExecutor = vi.fn(async (name, args) => ({
      content: [{ type: 'text', text: JSON.stringify({ name, args }) }],
    }));
    server = new PrimaryHttpServer(port, '1.2.3', executor, 0, TOKEN);
    await server.start();

    const res = await request(port, 'POST', '/tool', JSON.stringify({ name: 'read_file', args: { path: '/a.gd' } }));
    expect(res.status).toBe(200);
    expect(executor).toHaveBeenCalledWith('read_file', { path: '/a.gd' });
  });

  it('POST /tool with missing name returns 400', async () => {
    const port = getPort();
    const executor: ToolExecutor = vi.fn(async () => ({ content: [{ type: 'text', text: 'ok' }] }));
    server = new PrimaryHttpServer(port, '1.2.3', executor, 0, TOKEN);
    await server.start();

    const res = await request(port, 'POST', '/tool', JSON.stringify({ args: {} }));
    expect(res.status).toBe(400);
    expect(res.body.error).toMatch(/name/i);
  });

  it('POST /tool with no args defaults to empty object', async () => {
    const port = getPort();
    const executor: ToolExecutor = vi.fn(async (name, args) => ({
      content: [{ type: 'text', text: JSON.stringify({ name, args }) }],
    }));
    server = new PrimaryHttpServer(port, '1.2.3', executor, 0, TOKEN);
    await server.start();

    await request(port, 'POST', '/tool', JSON.stringify({ name: 'some_tool' }));
    expect(executor).toHaveBeenCalledWith('some_tool', {});
  });

  it('POST /client/register increments proxy client count', async () => {
    const port = getPort();
    const executor: ToolExecutor = vi.fn(async () => ({ content: [{ type: 'text', text: 'ok' }] }));
    server = new PrimaryHttpServer(port, '1.2.3', executor, 0, TOKEN);
    await server.start();

    const res1 = await request(port, 'POST', '/client/register', '');
    expect(res1.body.proxy_clients).toBe(1);

    const res2 = await request(port, 'POST', '/client/register', '');
    expect(res2.body.proxy_clients).toBe(2);

    expect(server.getProxyClientCount()).toBe(2);
  });

  it('POST /client/unregister decrements proxy client count', async () => {
    const port = getPort();
    const executor: ToolExecutor = vi.fn(async () => ({ content: [{ type: 'text', text: 'ok' }] }));
    server = new PrimaryHttpServer(port, '1.2.3', executor, 0, TOKEN);
    await server.start();

    await request(port, 'POST', '/client/register', '');
    await request(port, 'POST', '/client/register', '');

    const res = await request(port, 'POST', '/client/unregister', '');
    expect(res.body.proxy_clients).toBe(1);
    expect(server.getProxyClientCount()).toBe(1);
  });

  it('POST /client/unregister does not go below 0', async () => {
    const port = getPort();
    const executor: ToolExecutor = vi.fn(async () => ({ content: [{ type: 'text', text: 'ok' }] }));
    server = new PrimaryHttpServer(port, '1.2.3', executor, 0, TOKEN);
    await server.start();

    const res = await request(port, 'POST', '/client/unregister', '');
    expect(res.body.proxy_clients).toBe(0);
    expect(server.getProxyClientCount()).toBe(0);
  });

  it('client count change callback fires on register/unregister', async () => {
    const port = getPort();
    const executor: ToolExecutor = vi.fn(async () => ({ content: [{ type: 'text', text: 'ok' }] }));
    server = new PrimaryHttpServer(port, '1.2.3', executor, 0, TOKEN);
    const counts: number[] = [];
    server.setClientCountChangeCallback((c) => counts.push(c));
    await server.start();

    await request(port, 'POST', '/client/register', '');
    await request(port, 'POST', '/client/register', '');
    await request(port, 'POST', '/client/unregister', '');

    expect(counts).toEqual([1, 2, 1]);
  });

  it('unknown route returns 404', async () => {
    const port = getPort();
    const executor: ToolExecutor = vi.fn(async () => ({ content: [{ type: 'text', text: 'ok' }] }));
    server = new PrimaryHttpServer(port, '1.2.3', executor, 0, TOKEN);
    await server.start();

    const res = await request(port, 'GET', '/nope');
    expect(res.status).toBe(404);
  });

  it('executor error returns 500', async () => {
    const port = getPort();
    const failing: ToolExecutor = async () => { throw new Error('boom'); };
    server = new PrimaryHttpServer(port, '1.2.3', failing, 0, TOKEN);
    await server.start();

    const res = await request(port, 'POST', '/tool', JSON.stringify({ name: 'fail_tool' }));
    expect(res.status).toBe(500);
    expect(res.body.error).toBe('boom');
  });
});

// ---------------------------------------------------------------------------
// Authentication
// ---------------------------------------------------------------------------

describe('PrimaryHttpServer — authentication', () => {
  let server: PrimaryHttpServer;

  afterEach(() => {
    server?.stop();
  });

  it('POST /tool without a token returns 401 and does not execute', async () => {
    const port = getPort();
    const executor: ToolExecutor = vi.fn(async () => ({ content: [{ type: 'text', text: 'ok' }] }));
    server = new PrimaryHttpServer(port, '1.2.3', executor, 0, TOKEN);
    await server.start();

    const res = await request(port, 'POST', '/tool', JSON.stringify({ name: 'edit_script' }), null);
    expect(res.status).toBe(401);
    expect(executor).not.toHaveBeenCalled();
  });

  it('POST /tool with a wrong token returns 401', async () => {
    const port = getPort();
    const executor: ToolExecutor = vi.fn(async () => ({ content: [{ type: 'text', text: 'ok' }] }));
    server = new PrimaryHttpServer(port, '1.2.3', executor, 0, TOKEN);
    await server.start();

    const res = await request(port, 'POST', '/tool', JSON.stringify({ name: 'edit_script' }), 'wrong-token');
    expect(res.status).toBe(401);
    expect(executor).not.toHaveBeenCalled();
  });

  it('POST /client/register without a token returns 401', async () => {
    const port = getPort();
    const noop: ToolExecutor = async () => ({ content: [{ type: 'text', text: 'ok' }] });
    server = new PrimaryHttpServer(port, '1.2.3', noop, 0, TOKEN);
    await server.start();

    const res = await request(port, 'POST', '/client/register', '', null);
    expect(res.status).toBe(401);
    expect(server.getProxyClientCount()).toBe(0);
  });

  it('GET /health stays open so proxies can probe before they know the token', async () => {
    const port = getPort();
    const noop: ToolExecutor = async () => ({ content: [{ type: 'text', text: 'ok' }] });
    server = new PrimaryHttpServer(port, '1.2.3', noop, 0, TOKEN);
    await server.start();

    const res = await request(port, 'GET', '/health', undefined, null);
    expect(res.status).toBe(200);
  });

  it('accepts the token as a query parameter as well as a header', async () => {
    const port = getPort();
    const executor: ToolExecutor = vi.fn(async () => ({ content: [{ type: 'text', text: 'ok' }] }));
    server = new PrimaryHttpServer(port, '1.2.3', executor, 0, TOKEN);
    await server.start();

    const res = await request(port, 'POST', `/tool?token=${TOKEN}`, JSON.stringify({ name: 'read_file' }), null);
    expect(res.status).toBe(200);
    expect(executor).toHaveBeenCalled();
  });

  it('fails closed when constructed without a token', async () => {
    const port = getPort();
    const executor: ToolExecutor = vi.fn(async () => ({ content: [{ type: 'text', text: 'ok' }] }));
    server = new PrimaryHttpServer(port, '1.2.3', executor, 0, null);
    await server.start();

    const res = await request(port, 'POST', '/tool', JSON.stringify({ name: 'read_file' }), null);
    expect(res.status).toBe(503);
    expect(executor).not.toHaveBeenCalled();
  });

  it('an unauthenticated request does not keep the idle timer alive', async () => {
    const port = getPort();
    const noop: ToolExecutor = async () => ({ content: [{ type: 'text', text: 'ok' }] });
    server = new PrimaryHttpServer(port, '1.2.3', noop, 0, TOKEN);
    await server.start();

    const before = server.getLastActivityTime();
    await new Promise((r) => setTimeout(r, 20));
    await request(port, 'POST', '/tool', JSON.stringify({ name: 'read_file' }), null);
    expect(server.getLastActivityTime()).toBe(before);
  });
});
