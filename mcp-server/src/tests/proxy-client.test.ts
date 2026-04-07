/**
 * Tests for proxy-client module
 */

import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest';
import http from 'node:http';
import {
  probeExistingServer,
  registerProxyClient,
  unregisterProxyClient,
  proxyToolCall,
  type ProbeResult,
  type ProxyToolResult
} from '../proxy-client.js';

// Mock http module
vi.mock('node:http');

describe('proxy-client module', () => {
  const TEST_PORT = 16506;

  beforeEach(() => {
    vi.clearAllMocks();
  });

  afterEach(() => {
    vi.restoreAllMocks();
  });

  describe('probeExistingServer', () => {
    it('should return alive: true with version when health check succeeds', async () => {
      const mockResponse = {
        statusCode: 200,
        on: vi.fn((event, callback) => {
          if (event === 'data') {
            callback(Buffer.from('{"server":"godot-mcp-server","version":"0.4.1"}'));
          } else if (event === 'end') {
            callback();
          }
        }),
        resume: vi.fn(),
      };

      vi.mocked(http.get).mockImplementation((_url, options, callback) => {
        if (callback) callback(mockResponse as any);
        return { on: vi.fn(), destroy: vi.fn() } as any;
      });

      const result = await probeExistingServer(TEST_PORT);
      expect(result).toEqual({ alive: true, version: '0.4.1' });
    });

    it('should return alive: false when server returns different name', async () => {
      const mockResponse = {
        statusCode: 200,
        on: vi.fn((event, callback) => {
          if (event === 'data') {
            callback(Buffer.from('{"server":"other-server"}'));
          } else if (event === 'end') {
            callback();
          }
        }),
        resume: vi.fn(),
      };

      vi.mocked(http.get).mockImplementation((_url, options, callback) => {
        if (callback) callback(mockResponse as any);
        return { on: vi.fn(), destroy: vi.fn() } as any;
      });

      const result = await probeExistingServer(TEST_PORT);
      expect(result).toEqual({ alive: false });
    });

    it('should return alive: false on network error', async () => {
      vi.mocked(http.get).mockImplementation(() => {
        throw new Error('ECONNREFUSED');
      });

      const result = await probeExistingServer(TEST_PORT);
      expect(result).toEqual({ alive: false });
    });

    it('should return alive: false on non-200 status', async () => {
      const mockResponse = {
        statusCode: 404,
        on: vi.fn((event, callback) => {
          if (event === 'end') callback();
        }),
        resume: vi.fn(),
      };

      vi.mocked(http.get).mockImplementation((_url, options, callback) => {
        if (callback) callback(mockResponse as any);
        return { on: vi.fn(), destroy: vi.fn() } as any;
      });

      const result = await probeExistingServer(TEST_PORT);
      expect(result).toEqual({ alive: false });
    });

    it('should return alive: false on timeout', async () => {
      const mockReq: any = {
        on: vi.fn(),
        destroy: vi.fn(),
      };

      vi.mocked(http.get).mockImplementation(() => {
        // Simulate timeout
        setTimeout(() => {
          const timeoutCallback = mockReq.on.mock.calls.find((c: any[]) => c[0] === 'timeout');
          if (timeoutCallback) timeoutCallback[1]();
        }, 10);
        return mockReq;
      });

      const result = await probeExistingServer(TEST_PORT);
      expect(result).toEqual({ alive: false });
    });
  });

  describe('registerProxyClient', () => {
    it('should succeed when primary server responds', async () => {
      const mockResponse = {
        statusCode: 200,
        on: vi.fn((event, callback) => {
          if (event === 'data') {
            callback(Buffer.from('{"proxy_clients":1}'));
          } else if (event === 'end') {
            callback();
          }
        }),
        resume: vi.fn(),
      };

      vi.mocked(http.request).mockImplementation((_options: any, callback: any) => {
        callback(mockResponse as any);
        return { on: vi.fn(), destroy: vi.fn(), end: vi.fn() } as any;
      });

      await expect(registerProxyClient(TEST_PORT)).resolves.not.toThrow();
    });

    it('should not throw on error (non-fatal)', async () => {
      vi.mocked(http.request).mockImplementation(() => {
        throw new Error('Connection refused');
      });

      await expect(registerProxyClient(TEST_PORT)).resolves.not.toThrow();
    });
  });

  describe('unregisterProxyClient', () => {
    it('should succeed when primary server responds', async () => {
      const mockResponse = {
        statusCode: 200,
        on: vi.fn((event, callback) => {
          if (event === 'data') {
            callback('{"proxy_clients":0}');
          } else if (event === 'end') {
            const dataCallback = mockResponse.on.mock.calls.find((c: any[]) => c[0] === 'data')?.[1];
            if (dataCallback) dataCallback('{"proxy_clients":0}');
            callback();
          }
        }),
        resume: vi.fn(),
      };

      vi.mocked(http.request).mockImplementation((_options: any, callback: any) => {
        callback(mockResponse as any);
        return { on: vi.fn(), destroy: vi.fn(), end: vi.fn() } as any;
      });

      await expect(unregisterProxyClient(TEST_PORT)).resolves.not.toThrow();
    });

    it('should not throw on error (non-fatal)', async () => {
      vi.mocked(http.request).mockImplementation(() => {
        throw new Error('Connection refused');
      });

      await expect(unregisterProxyClient(TEST_PORT)).resolves.not.toThrow();
    });
  });

  describe('proxyToolCall', () => {
    it('should forward tool call and return result', async () => {
      const mockResponse = {
        statusCode: 200,
        on: vi.fn((event, callback) => {
          if (event === 'data') {
            callback(Buffer.from('{"content":[{"type":"text","text":"success"}]}'));
          } else if (event === 'end') {
            callback();
          }
        }),
        resume: vi.fn(),
      };

      vi.mocked(http.request).mockImplementation((options: any, callback: any) => {
        expect(options.path).toBe('/tool');
        expect(options.method).toBe('POST');
        expect(options.headers['Content-Type']).toBe('application/json');
        if (callback) callback(mockResponse as any);
        return { on: vi.fn(), destroy: vi.fn(), end: vi.fn() } as any;
      });

      const result = await proxyToolCall(TEST_PORT, 'test_tool', { foo: 'bar' }, 30000);
      expect(result).toEqual({
        content: [{ type: 'text', text: 'success' }],
      });
    });

    it('should include tool timeout buffer in request timeout', async () => {
      const mockResponse = {
        statusCode: 200,
        on: vi.fn((event, callback) => {
          if (event === 'data') {
            callback(Buffer.from('{"content":[{}]}'));
          } else if (event === 'end') {
            callback();
          }
        }),
        resume: vi.fn(),
      };

      vi.mocked(http.request).mockImplementation((options: any, callback: any) => {
        expect(options.timeout).toBe(35000); // 30000 + 5000
        if (callback) callback(mockResponse as any);
        return { on: vi.fn(), destroy: vi.fn(), end: vi.fn() } as any;
      });

      await proxyToolCall(TEST_PORT, 'test_tool', {}, 30000);
    });

    it('should throw on network error', async () => {
      vi.mocked(http.request).mockImplementation(() => {
        throw new Error('Network error');
      });

      await expect(proxyToolCall(TEST_PORT, 'test_tool', {}, 30000)).rejects.toThrow('Network error');
    });
  });

  describe('ProbeResult type', () => {
    it('should accept valid probe result', () => {
      const result: ProbeResult = { alive: true, version: '1.0.0' };
      expect(result.alive).toBe(true);
      expect(result.version).toBe('1.0.0');
    });

    it('should accept probe result without version', () => {
      const result: ProbeResult = { alive: false };
      expect(result.alive).toBe(false);
      expect(result.version).toBeUndefined();
    });
  });

  describe('ProxyToolResult type', () => {
    it('should accept successful result', () => {
      const result: ProxyToolResult = {
        content: [{ type: 'text', text: 'test' }],
        isError: false,
      };
      expect(result.content).toHaveLength(1);
      expect(result.isError).toBe(false);
    });

    it('should accept error result', () => {
      const result: ProxyToolResult = {
        content: [{ type: 'text', text: 'error message' }],
        isError: true,
      };
      expect(result.isError).toBe(true);
    });

    it('should allow isError to be undefined', () => {
      const result: ProxyToolResult = {
        content: [{ type: 'text', text: 'test' }],
      };
      expect(result.isError).toBeUndefined();
    });
  });
});
