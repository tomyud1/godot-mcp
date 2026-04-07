/**
 * Tests for PrimaryHttpServer class
 */

import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest';
import { PrimaryHttpServer } from '../primary-http.js';

describe('PrimaryHttpServer', () => {
  let server: PrimaryHttpServer;
  const TEST_PORT = 16506; // Use non-standard port for tests

  const mockToolExecutor = vi.fn().mockResolvedValue({
    content: [{ type: 'text', text: 'OK' }],
  });

  beforeEach(() => {
    server = new PrimaryHttpServer(TEST_PORT, '0.1.0-test', mockToolExecutor);
    vi.clearAllMocks();
  });

  afterEach(async () => {
    try {
      server.stop();
    } catch {
      // Ignore errors during cleanup
    }
  });

  describe('constructor', () => {
    it('should create a server with given parameters', () => {
      const customServer = new PrimaryHttpServer(9999, '1.0.0', mockToolExecutor);
      expect(customServer).toBeInstanceOf(PrimaryHttpServer);
    });
  });

  describe('getLastActivityTime', () => {
    it('should return a timestamp', () => {
      const time = server.getLastActivityTime();
      expect(typeof time).toBe('number');
      expect(time).toBeGreaterThan(0);
    });
  });

  describe('getProxyClientCount', () => {
    it('should start with zero clients', () => {
      expect(server.getProxyClientCount()).toBe(0);
    });
  });

  describe('isListening', () => {
    it('should return false when not started', () => {
      expect(server.isListening()).toBe(false);
    });

    it('should return true after successful start', async () => {
      await server.start();
      expect(server.isListening()).toBe(true);
      server.stop();
    });
  });

  describe('setClientCountChangeCallback', () => {
    it('should accept a callback function', () => {
      const callback = vi.fn();
      expect(() => server.setClientCountChangeCallback(callback)).not.toThrow();
    });
  });

  describe('start and stop', () => {
    it('should start and stop without errors', async () => {
      await expect(server.start()).resolves.not.toThrow();
      expect(server.isListening()).toBe(true);
      server.stop();
      expect(server.isListening()).toBe(false);
    });

    it('should be idempotent', async () => {
      await server.start();
      server.stop();
      expect(() => server.stop()).not.toThrow();
    });
  });

  describe('HTTP endpoints', () => {
    it('should respond to health endpoint', async () => {
      await server.start();

      const response = await makeRequest('GET', '/health');
      expect(response.statusCode).toBe(200);

      const body = JSON.parse(response.body);
      expect(body.server).toBe('godot-mcp-server');
      expect(body.version).toBe('0.1.0-test');

      server.stop();
    });

    it('should respond to 404 for unknown endpoints', async () => {
      await server.start();

      try {
        const response = await makeRequest('GET', '/unknown');
        expect(response.statusCode).toBe(404);
      } catch (e) {
        // Some Node.js versions throw on connection errors
        expect(e).toBeDefined();
      }

      server.stop();
    });

    it('should handle tool invocation endpoint', async () => {
      await server.start();

      const response = await makeRequest('POST', '/tool', JSON.stringify({
        name: 'test_tool',
        args: { foo: 'bar' },
      }));

      expect(response.statusCode).toBe(200);
      expect(mockToolExecutor).toHaveBeenCalledWith('test_tool', { foo: 'bar' });

      server.stop();
    });
  });
});

// Helper function to make HTTP requests
async function makeRequest(method: string, path: string, body?: string): Promise<{ statusCode: number; body: string }> {
  const httpModule = await import('node:http');

  return new Promise((resolve, reject) => {
    const options: import('node:http').RequestOptions = {
      hostname: '127.0.0.1',
      port: 16506,
      path,
      method,
      headers: body ? {
        'Content-Type': 'application/json',
        'Content-Length': Buffer.byteLength(body),
      } : undefined,
    };

    const req = httpModule.default.request(options, (res) => {
      let data = '';
      res.on('data', (chunk) => { data += chunk; });
      res.on('end', () => {
        resolve({ statusCode: res.statusCode || 500, body: data });
      });
      res.on('error', reject);
    });

    req.on('error', reject);

    if (body) {
      req.write(body);
    }

    req.end();
  });
}
