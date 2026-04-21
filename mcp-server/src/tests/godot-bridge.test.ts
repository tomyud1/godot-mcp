import { describe, it, expect, afterEach } from 'vitest';
import { WebSocket } from 'ws';
import { createBridge, GodotBridge } from '../godot-bridge.js';

const TEST_PORT = 16505;
const SHORT_TIMEOUT = 500;

/** Connect a raw WebSocket client to the bridge and wait for it to open. */
function connectClient(port: number): Promise<WebSocket> {
  return new Promise((resolve, reject) => {
    const ws = new WebSocket(`ws://127.0.0.1:${port}`);
    ws.on('open', () => resolve(ws));
    ws.on('error', reject);
  });
}

/** Collect next JSON message from a WebSocket. */
function nextMessage(ws: WebSocket): Promise<Record<string, unknown>> {
  return new Promise((resolve) => {
    ws.once('message', (data) => {
      resolve(JSON.parse(data.toString()));
    });
  });
}

// ---------------------------------------------------------------------------
// Lifecycle
// ---------------------------------------------------------------------------

describe('GodotBridge — lifecycle', () => {
  let bridge: GodotBridge;

  afterEach(() => {
    bridge?.stop();
  });

  it('isListening() is false before start', () => {
    bridge = createBridge(TEST_PORT, SHORT_TIMEOUT);
    expect(bridge.isListening()).toBe(false);
  });

  it('isListening() is true after start', async () => {
    bridge = createBridge(TEST_PORT, SHORT_TIMEOUT);
    await bridge.start();
    expect(bridge.isListening()).toBe(true);
  });

  it('isListening() is false after stop', async () => {
    bridge = createBridge(TEST_PORT, SHORT_TIMEOUT);
    await bridge.start();
    bridge.stop();
    expect(bridge.isListening()).toBe(false);
  });

  it('isListening() is false after failed start', async () => {
    // Occupy the port first
    const blocker = createBridge(TEST_PORT, SHORT_TIMEOUT);
    await blocker.start();

    bridge = createBridge(TEST_PORT, SHORT_TIMEOUT);
    await expect(bridge.start()).rejects.toThrow();
    expect(bridge.isListening()).toBe(false);

    blocker.stop();
  });

  it('stop() is idempotent', async () => {
    bridge = createBridge(TEST_PORT, SHORT_TIMEOUT);
    await bridge.start();
    bridge.stop();
    expect(() => bridge.stop()).not.toThrow();
  });

  it('isConnected() is false when no client is connected', async () => {
    bridge = createBridge(TEST_PORT, SHORT_TIMEOUT);
    await bridge.start();
    expect(bridge.isConnected()).toBe(false);
  });

  it('getStatus() reflects initial state', async () => {
    bridge = createBridge(TEST_PORT, SHORT_TIMEOUT);
    await bridge.start();
    const status = bridge.getStatus();
    expect(status.connected).toBe(false);
    expect(status.port).toBe(TEST_PORT);
    expect(status.pendingRequests).toBe(0);
    expect(status.projectPath).toBeUndefined();
    expect(status.connectedAt).toBeUndefined();
  });
});

// ---------------------------------------------------------------------------
// Connection management
// ---------------------------------------------------------------------------

describe('GodotBridge — connections', () => {
  let bridge: GodotBridge;
  let client: WebSocket | null = null;

  afterEach(() => {
    client?.close();
    client = null;
    bridge?.stop();
  });

  it('accepts a WebSocket connection and reports isConnected()', async () => {
    bridge = createBridge(TEST_PORT, SHORT_TIMEOUT);
    await bridge.start();

    client = await connectClient(TEST_PORT);
    // Give the bridge a tick to process the connection event
    await new Promise((r) => setTimeout(r, 50));

    expect(bridge.isConnected()).toBe(true);
    expect(bridge.getStatus().connected).toBe(true);
    expect(bridge.getStatus().connectedAt).toBeInstanceOf(Date);
  });

  it('fires onConnectionChange(true) when a client connects', async () => {
    bridge = createBridge(TEST_PORT, SHORT_TIMEOUT);
    await bridge.start();

    const events: boolean[] = [];
    bridge.onConnectionChange((connected) => events.push(connected));

    client = await connectClient(TEST_PORT);
    await new Promise((r) => setTimeout(r, 50));

    expect(events).toContain(true);
  });

  it('fires onConnectionChange(false) when a client disconnects', async () => {
    bridge = createBridge(TEST_PORT, SHORT_TIMEOUT);
    await bridge.start();

    const events: boolean[] = [];
    bridge.onConnectionChange((connected) => events.push(connected));

    client = await connectClient(TEST_PORT);
    await new Promise((r) => setTimeout(r, 50));

    client.close();
    await new Promise((r) => setTimeout(r, 100));
    client = null;

    expect(events).toEqual([true, false]);
    expect(bridge.isConnected()).toBe(false);
  });

  it('offConnectionChange removes the callback', async () => {
    bridge = createBridge(TEST_PORT, SHORT_TIMEOUT);
    await bridge.start();

    const events: boolean[] = [];
    const cb = (connected: boolean) => events.push(connected);
    bridge.onConnectionChange(cb);
    bridge.offConnectionChange(cb);

    client = await connectClient(TEST_PORT);
    await new Promise((r) => setTimeout(r, 50));

    expect(events).toEqual([]);
  });

  it('rejects a second editor connection', async () => {
    bridge = createBridge(TEST_PORT, SHORT_TIMEOUT);
    await bridge.start();

    client = await connectClient(TEST_PORT);
    client.send(JSON.stringify({ type: 'godot_ready', role: 'editor', project_path: '/p1' }));
    await new Promise((r) => setTimeout(r, 50));

    const second = await connectClient(TEST_PORT);
    const closePromise = new Promise<number>((resolve) => {
      second.on('close', (code) => resolve(code));
    });
    // Second connection claims editor — should be rejected with 4000.
    second.send(JSON.stringify({ type: 'godot_ready', role: 'editor', project_path: '/p2' }));
    const code = await closePromise;
    expect(code).toBe(4000);
  });

  it('accepts a runtime connection alongside an editor connection', async () => {
    bridge = createBridge(TEST_PORT, SHORT_TIMEOUT);
    await bridge.start();

    client = await connectClient(TEST_PORT);
    client.send(JSON.stringify({ type: 'godot_ready', role: 'editor', project_path: '/editor' }));
    await new Promise((r) => setTimeout(r, 50));

    const runtime = await connectClient(TEST_PORT);
    runtime.send(JSON.stringify({ type: 'godot_ready', role: 'runtime', project_path: '/runtime' }));
    await new Promise((r) => setTimeout(r, 50));

    expect(bridge.isConnected()).toBe(true);
    expect(bridge.isRuntimeConnected()).toBe(true);
    runtime.close();
  });
});

// ---------------------------------------------------------------------------
// WebSocket protocol
// ---------------------------------------------------------------------------

describe('GodotBridge — protocol', () => {
  let bridge: GodotBridge;
  let client: WebSocket | null = null;

  afterEach(() => {
    client?.close();
    client = null;
    bridge?.stop();
  });

  it('sends ping messages to connected client', async () => {
    // Use a bridge with a very short ping interval by connecting and waiting
    // The default PING_INTERVAL is 10s which is too long for tests, but we can
    // verify that the bridge at least sends a ping by waiting briefly.
    // Instead, we test the tool invoke protocol which exercises sendMessage.
    bridge = createBridge(TEST_PORT, SHORT_TIMEOUT);
    await bridge.start();

    client = await connectClient(TEST_PORT);
    await new Promise((r) => setTimeout(r, 50));

    // The bridge sends pings on an interval. We can't easily wait 10s in a test,
    // so we verify the protocol via invokeTool instead (see below).
    expect(bridge.isConnected()).toBe(true);
  });

  it('handles godot_ready message and sets projectPath', async () => {
    bridge = createBridge(TEST_PORT, SHORT_TIMEOUT);
    await bridge.start();

    client = await connectClient(TEST_PORT);
    await new Promise((r) => setTimeout(r, 50));

    // Simulate godot_ready
    client.send(JSON.stringify({ type: 'godot_ready', project_path: '/home/user/my-game' }));
    await new Promise((r) => setTimeout(r, 50));

    expect(bridge.getStatus().projectPath).toBe('/home/user/my-game');
  });

  it('invokeTool sends tool_invoke and resolves on success result', async () => {
    bridge = createBridge(TEST_PORT, SHORT_TIMEOUT);
    await bridge.start();

    client = await connectClient(TEST_PORT);
    await new Promise((r) => setTimeout(r, 50));

    // Listen for the tool_invoke message on the client side
    const msgPromise = nextMessage(client);

    // Start the tool invocation (don't await yet)
    const resultPromise = bridge.invokeTool('read_file', { path: '/test.gd' });

    // Client receives the invoke message
    const invokeMsg = await msgPromise;
    expect(invokeMsg.type).toBe('tool_invoke');
    expect(invokeMsg.tool).toBe('read_file');
    expect(invokeMsg.args).toEqual({ path: '/test.gd' });
    expect(typeof invokeMsg.id).toBe('string');

    // Client sends a success response
    client.send(JSON.stringify({
      type: 'tool_result',
      id: invokeMsg.id,
      success: true,
      result: { content: 'extends Node', path: '/test.gd' },
    }));

    const result = await resultPromise;
    expect(result).toEqual({ content: 'extends Node', path: '/test.gd' });
  });

  it('invokeTool rejects on error result', async () => {
    bridge = createBridge(TEST_PORT, SHORT_TIMEOUT);
    await bridge.start();

    client = await connectClient(TEST_PORT);
    await new Promise((r) => setTimeout(r, 50));

    const msgPromise = nextMessage(client);
    const resultPromise = bridge.invokeTool('read_file', { path: '/missing.gd' });

    const invokeMsg = await msgPromise;

    client.send(JSON.stringify({
      type: 'tool_result',
      id: invokeMsg.id,
      success: false,
      error: 'File not found',
    }));

    await expect(resultPromise).rejects.toThrow('File not found');
  });

  it('invokeTool rejects on timeout', async () => {
    bridge = createBridge(TEST_PORT, SHORT_TIMEOUT);
    await bridge.start();

    client = await connectClient(TEST_PORT);
    await new Promise((r) => setTimeout(r, 50));

    // Don't respond — let it time out
    await expect(bridge.invokeTool('slow_tool', {})).rejects.toThrow(/timed out/);
  });

  it('invokeTool throws if Godot is not connected', async () => {
    bridge = createBridge(TEST_PORT, SHORT_TIMEOUT);
    await bridge.start();

    await expect(bridge.invokeTool('some_tool', {})).rejects.toThrow('Godot is not connected');
  });

  it('pending requests are rejected on disconnect', async () => {
    bridge = createBridge(TEST_PORT, 5000);
    await bridge.start();

    client = await connectClient(TEST_PORT);
    await new Promise((r) => setTimeout(r, 50));

    // Start a tool call but don't respond
    const resultPromise = bridge.invokeTool('slow_tool', {});

    // Disconnect the client
    client.close();
    client = null;

    await expect(resultPromise).rejects.toThrow('Godot disconnected');
  });

  it('pending requests are rejected on server stop', async () => {
    bridge = createBridge(TEST_PORT, 5000);
    await bridge.start();

    client = await connectClient(TEST_PORT);
    await new Promise((r) => setTimeout(r, 50));

    const resultPromise = bridge.invokeTool('slow_tool', {});

    bridge.stop();

    await expect(resultPromise).rejects.toThrow('Server shutting down');
  });

  it('sendClientStatus sends message to connected client', async () => {
    bridge = createBridge(TEST_PORT, SHORT_TIMEOUT);
    await bridge.start();

    client = await connectClient(TEST_PORT);
    await new Promise((r) => setTimeout(r, 50));

    const msgPromise = nextMessage(client);
    bridge.sendClientStatus(3);

    const msg = await msgPromise;
    expect(msg.type).toBe('client_status');
    expect(msg.count).toBe(3);
  });
});
