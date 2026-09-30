import { describe, it, expect, afterEach, beforeAll, vi } from 'vitest';
import { PrimaryHttpServer, type ToolExecutor } from '../primary-http.js';
import {
  probeExistingServer,
  proxyToolCall,
  registerProxyClient,
  unregisterProxyClient,
} from '../proxy-client.js';

const TEST_PORT = 16507;

/**
 * The proxy client reads the shared token from the environment (falling back
 * to the on-disk token file). Setting it here keeps the tests off the real
 * user's token file and makes the proxy and the server agree by construction.
 */
const TOKEN = 'test-token-0123456789';
beforeAll(() => {
  process.env.GODOT_MCP_TOKEN = TOKEN;
});

// ---------------------------------------------------------------------------
// probeExistingServer
// ---------------------------------------------------------------------------

describe('probeExistingServer', () => {
  let server: PrimaryHttpServer;
  const noop: ToolExecutor = async () => ({ content: [{ type: 'text', text: 'ok' }] });

  afterEach(() => {
    server?.stop();
  });

  it('returns alive:true when a primary server is running', async () => {
    server = new PrimaryHttpServer(TEST_PORT, '0.4.1', noop, 0, TOKEN);
    await server.start();

    const probe = await probeExistingServer(TEST_PORT);
    expect(probe.alive).toBe(true);
    expect(probe.version).toBe('0.4.1');
  });

  it('returns alive:false when no server is running', async () => {
    const probe = await probeExistingServer(TEST_PORT);
    expect(probe.alive).toBe(false);
  });
});

// ---------------------------------------------------------------------------
// proxyToolCall
// ---------------------------------------------------------------------------

describe('proxyToolCall', () => {
  let server: PrimaryHttpServer;

  afterEach(() => {
    server?.stop();
  });

  it('forwards a tool call and returns the result', async () => {
    const executor: ToolExecutor = vi.fn(async () => ({
      content: [{ type: 'text', text: '{"ok":true}' }],
    }));
    server = new PrimaryHttpServer(TEST_PORT, '0.4.1', executor, 0, TOKEN);
    await server.start();

    const result = await proxyToolCall(TEST_PORT, 'read_file', { path: '/x.gd' }, 5000);
    expect(result.content[0].text).toBe('{"ok":true}');
    expect(executor).toHaveBeenCalledWith('read_file', { path: '/x.gd' });
  });

  it('rejects when no server is running', async () => {
    await expect(proxyToolCall(TEST_PORT, 'any_tool', {}, 2000)).rejects.toThrow();
  });
});

// ---------------------------------------------------------------------------
// register / unregister
// ---------------------------------------------------------------------------

describe('registerProxyClient / unregisterProxyClient', () => {
  let server: PrimaryHttpServer;
  const noop: ToolExecutor = async () => ({ content: [{ type: 'text', text: 'ok' }] });

  afterEach(() => {
    server?.stop();
  });

  it('register increments and unregister decrements the count', async () => {
    server = new PrimaryHttpServer(TEST_PORT, '0.4.1', noop, 0, TOKEN);
    await server.start();

    await registerProxyClient(TEST_PORT);
    expect(server.getProxyClientCount()).toBe(1);

    await registerProxyClient(TEST_PORT);
    expect(server.getProxyClientCount()).toBe(2);

    await unregisterProxyClient(TEST_PORT);
    expect(server.getProxyClientCount()).toBe(1);
  });

  it('register does not throw when server is down', async () => {
    await expect(registerProxyClient(TEST_PORT)).resolves.not.toThrow();
  });

  it('unregister does not throw when server is down', async () => {
    await expect(unregisterProxyClient(TEST_PORT)).resolves.not.toThrow();
  });
});
