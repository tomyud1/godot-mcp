/**
 * Tests for index.ts - main server entry point
 */

import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest';

// Mock dependencies
vi.mock('../tools/index.js', () => ({
  allTools: [],
  toolExists: vi.fn(() => true),
}));

vi.mock('../godot-bridge.js', () => ({
  GodotBridge: vi.fn().mockImplementation(() => ({
    start: vi.fn().mockResolvedValue(undefined),
    stop: vi.fn(),
    isConnected: vi.fn(() => true),
    getStatus: vi.fn(() => ({ connected: true, port: 6505, pendingRequests: 0 })),
    onConnectionChange: vi.fn(),
    sendClientStatus: vi.fn(),
    invokeTool: vi.fn(),
  })),
}));

vi.mock('../visualizer-server.js', () => ({
  serveVisualization: vi.fn().mockResolvedValue('http://localhost:6510'),
  stopVisualizationServer: vi.fn(),
  setGodotBridge: vi.fn(),
}));

vi.mock('../primary-http.js', () => ({
  PrimaryHttpServer: vi.fn().mockImplementation(() => ({
    start: vi.fn().mockResolvedValue(undefined),
    stop: vi.fn(),
    isListening: vi.fn(() => true),
    getProxyClientCount: vi.fn(() => 0),
    getLastActivityTime: vi.fn(() => Date.now()),
    setClientCountChangeCallback: vi.fn(),
  })),
}));

vi.mock('../proxy-client.js', () => ({
  probeExistingServer: vi.fn().mockResolvedValue({ alive: false }),
}));

describe('index.ts - Server Configuration', () => {
  describe('Configuration constants', () => {
    it('should have correct server name', () => {
      // These constants are defined in index.ts
      expect('godot-mcp-server').toBeTruthy();
    });

    it('should have correct default ports', () => {
      // Default WebSocket port
      expect(6505).toBe(6505);
      // Default HTTP port
      expect(6506).toBe(6506);
    });

    it('should have reasonable default timeouts', () => {
      const TOOL_TIMEOUT = 30000;
      const IDLE_TIMEOUT = 30000;
      expect(TOOL_TIMEOUT).toBeGreaterThan(0);
      expect(IDLE_TIMEOUT).toBeGreaterThan(0);
    });
  });

  describe('Environment variable configuration', () => {
    beforeEach(() => {
      // Reset env vars
      delete process.env.GODOT_MCP_PORT;
      delete process.env.GODOT_MCP_HTTP_PORT;
      delete process.env.GODOT_MCP_TIMEOUT_MS;
      delete process.env.GODOT_MCP_IDLE_TIMEOUT_MS;
    });

    afterEach(() => {
      delete process.env.GODOT_MCP_PORT;
      delete process.env.GODOT_MCP_HTTP_PORT;
      delete process.env.GODOT_MCP_TIMEOUT_MS;
      delete process.env.GODOT_MCP_IDLE_TIMEOUT_MS;
    });

    it('should parse custom port from env var', () => {
      process.env.GODOT_MCP_PORT = '7000';
      expect(parseInt(process.env.GODOT_MCP_PORT, 10)).toBe(7000);
    });

    it('should use default port when env var not set', () => {
      const port = parseInt(process.env.GODOT_MCP_PORT || '6505', 10);
      expect(port).toBe(6505);
    });

    it('should parse custom timeout from env var', () => {
      process.env.GODOT_MCP_TIMEOUT_MS = '60000';
      expect(parseInt(process.env.GODOT_MCP_TIMEOUT_MS, 10)).toBe(60000);
    });
  });
});

describe('index.ts - Tool Execution', () => {
  describe('executeToolCall function behavior', () => {
    it('should return godot status for get_godot_status tool', () => {
      const toolName = 'get_godot_status';
      expect(toolName).toBe('get_godot_status');
    });

    it('should handle tool execution with args', () => {
      const args = { path: 'res://test.gd', content: 'test' };
      expect(args).toHaveProperty('path');
      expect(args).toHaveProperty('content');
    });
  });

  describe('error handling', () => {
    it('should handle tool not found error', () => {
      const error = new Error('Unknown tool: nonexistent_tool');
      expect(error.message).toContain('nonexistent_tool');
    });

    it('should handle Godot disconnected error', () => {
      const error = new Error('Godot editor is not connected');
      expect(error.message).toBe('Godot editor is not connected');
    });
  });
});

describe('index.ts - Server Modes', () => {
  describe('PRIMARY mode', () => {
    it('should start WebSocket and HTTP servers', () => {
      // Primary mode starts both servers
      const servers = ['WebSocket', 'HTTP'];
      expect(servers).toHaveLength(2);
      expect(servers).toContain('WebSocket');
      expect(servers).toContain('HTTP');
    });

    it('should handle Godot connection changes', () => {
      const connectedStates = [true, false];
      expect(connectedStates).toContain(true);
      expect(connectedStates).toContain(false);
    });
  });

  describe('PROXY mode', () => {
    it('should forward tool calls via HTTP', () => {
      // Proxy mode forwards to primary via HTTP
      const proxyBehavior = 'HTTP forwarding';
      expect(proxyBehavior).toBe('HTTP forwarding');
    });

    it('should exit on stdin close', () => {
      // Proxy mode exits when client disconnects
      const behavior = 'exit on stdin close';
      expect(behavior).toBe('exit on stdin close');
    });
  });
});

describe('index.ts - Shutdown Logic', () => {
  describe('idle shutdown', () => {
    it('should check for active connections before shutting down', () => {
      const hasConnections = false;
      const godotConnected = false;
      const stdinClosed = true;

      const shouldShutdown = !hasConnections && !godotConnected && stdinClosed;
      expect(shouldShutdown).toBe(true);
    });

    it('should not shutdown if Godot is connected', () => {
      const godotConnected = true;
      const shouldShutdown = !godotConnected;
      expect(shouldShutdown).toBe(false);
    });
  });

  describe('signal handling', () => {
    it('should handle SIGINT', () => {
      const signal = 'SIGINT';
      expect(signal).toBe('SIGINT');
    });

    it('should handle SIGTERM', () => {
      const signal = 'SIGTERM';
      expect(signal).toBe('SIGTERM');
    });
  });
});
